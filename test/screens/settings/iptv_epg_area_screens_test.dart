// Widget tests for the EPG area (v1.2.0, §3.1/§3.2).
//
// Proves the Settings → IPTV → EPG sources row exists per connection and
// opens the sources screen (provider guide + added source + status chip),
// that the add dialog reports a validation failure instead of a silent
// add, that the Assign screen lists the provider feed's channels and
// assigns one on tap, that Channels without guide lists the unmatched
// channel with its reason, and that the settings screen gains the Update
// time tile and the playlist-change switch. No live panel: fakes only.
// `debugDisablePersistedEpg` is on so no async directory listing runs
// inside fake async.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/iptv_epg_assign_screen.dart';
import 'package:plezy/screens/settings/iptv_epg_no_guide_screen.dart';
import 'package:plezy/screens/settings/iptv_epg_sources_screen.dart';
import 'package:plezy/screens/settings/iptv_settings_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: 'hunter-9',
  createdAt: DateTime.utc(2026, 11, 6),
);

class _FakeConnectionRegistry extends ConnectionRegistry {
  _FakeConnectionRegistry(super.db);

  @override
  Stream<List<Connection>> watchConnections() => Stream.value([_trexConnection()]);
}

/// Minimal fake API: canned live streams + a canned xmltv.php feed.
class _FakeXtreamApi extends XtreamApi {
  _FakeXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'hunter-9');

  List<XtreamLiveStream> liveStreams = [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
  ];

  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'General')];

  @override
  Future<Map<String, dynamic>?> getUserInfo() async => {'status': 'Active'};

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async =>
      liveStreams;

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async => const [];

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(xmltvBody)),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async =>
      xmltvBody;
}

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

String _feedWith({required String channelId, required String title}) {
  // The programme sits in the probe window (now ± 1h): a fixed date
  // expires as the days pass and the channel silently loses its guide
  // (1.2.8: the Nov 13 date expired Nov 14 06:00 UTC, failing the
  // without-guide test with no code change behind it).
  final now = DateTime.now();
  return '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '<channel id="$channelId"><display-name>$channelId</display-name></channel>'
      '<programme start="${_xmltvTime(now.subtract(const Duration(hours: 1)))}" stop="${_xmltvTime(now.add(const Duration(hours: 1)))}" channel="$channelId">'
      '<title>$title</title></programme></tv>';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory epgTempDir;
  late _FakeXtreamApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    await StorageService.getInstance();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_area_widget_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvLiveTvSupport.debugDisablePersistedEpg = true;
    IptvCatalogDiskCache.debugDisableDisk = true;
    api = _FakeXtreamApi();
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugDisablePersistedEpg = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  IptvClient trexClient() {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    return client;
  }

  Future<MultiServerProvider> providerWithClient() async {
    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(trexClient());
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });
    return provider;
  }

  Future<void> pumpSourcesScreen(WidgetTester tester) async {
    final provider = await providerWithClient();
    tester.view.physicalSize = const Size(840, 4000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider<MultiServerProvider>.value(value: provider)],
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: IptvEpgSourcesScreen(connection: _trexConnection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpAssignScreen(WidgetTester tester, IptvLiveTvSupport support) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: monoTheme(MonoPalette.dark),
        home: IptvEpgAssignScreen(support: support, channelKey: '101', channelName: 'Channel 101'),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('EPG sources screen', () {
    testWidgets('shows the provider guide and a pre-seeded added source', (tester) async {
      await tester.runAsync(
        () => IptvEpgSourcesStore('trex').saveUserSources([
          const IptvEpgSourceConfig(
            id: 'user_x',
            kind: IptvEpgSourceConfig.kindXmltv,
            url: 'https://example.com/epg.xml',
            name: 'My EPG',
          ),
        ]),
      );
      await pumpSourcesScreen(tester);

      expect(find.text(t.iptv.epgProviderSource), findsOneWidget);
      expect(find.text('My EPG'), findsOneWidget);
      expect(find.text('https://example.com/epg.xml'), findsOneWidget);
      // Never fetched: the chip says it needs a refresh.
      // Neither source has ever fetched: both chips read "Needs refresh".
      expect(find.text(t.iptv.epgSourceStatusNeedsRefresh), findsNWidgets(2));
      expect(find.text(t.iptv.epgAddedSourcesFirst), findsOneWidget);
      expect(find.text(t.iptv.epgReloadTvDetails), findsOneWidget);
      expect(find.text(t.iptv.epgNoGuideTitle), findsOneWidget);
    });

    testWidgets('add dialog reports a bad URL instead of adding silently', (tester) async {
      await pumpSourcesScreen(tester);

      await tester.tap(find.byTooltip(t.iptv.epgAddSource));
      await tester.pumpAndSettle();
      expect(find.text(t.iptv.epgAddSourceTitle), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'not a url');
      await tester.tap(find.text(t.iptv.epgAddSource));
      await tester.pumpAndSettle();
      // The validation failure is shown in the dialog; nothing is added.
      expect(find.textContaining('Not a valid http(s) URL'), findsOneWidget);
      expect(find.text(t.iptv.epgAddSourceTitle), findsOneWidget);
    });
  });

  group('Assign screen', () {
    testWidgets('lists the provider feed channels and assigns one on tap', (tester) async {
      api.xmltvBody = _feedWith(channelId: 'ch100', title: 'Show A');
      final client = trexClient();
      final support = client.liveTv as IptvLiveTvSupport;
      await tester.runAsync(() => client.iptvChannels());
      await pumpAssignScreen(tester, support);

      expect(find.text('ch100'), findsOneWidget);
      await tester.tap(find.text('ch100'));
      await tester.pumpAndSettle();

      final mapping = await tester.runAsync(() => support.epgAssignmentFor('101'));
      expect(mapping, isNotNull);
      expect(mapping!.xmltvId, 'ch100');
      expect(mapping.sourceId, IptvEpgSourceConfig.providerId);
    });

    testWidgets('search filters the list locally', (tester) async {
      api.xmltvBody = _feedWith(channelId: 'ch100', title: 'Show A');
      final client = trexClient();
      final support = client.liveTv as IptvLiveTvSupport;
      await tester.runAsync(() => client.iptvChannels());
      await pumpAssignScreen(tester, support);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text(t.iptv.epgAssignEmpty), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'ch1');
      await tester.pumpAndSettle();
      expect(find.text('ch100'), findsOneWidget);
    });
  });

  group('Channels without guide screen', () {
    testWidgets('lists the unmatched channel with its reason', (tester) async {
      api.xmltvBody = _feedWith(channelId: 'ch100', title: 'Show A');
      final client = trexClient();
      final support = client.liveTv as IptvLiveTvSupport;
      // No runAsync pre-load here: the screen's own channelsWithoutGuide
      // call is the first (fresh) load. A memo future completed inside
      // runAsync never resolves when awaited again in fake async, so a
      // pre-load + screen load hangs the pump.
      await tester.pumpWidget(
        MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: IptvEpgNoGuideScreen(support: support),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Channel 101'), findsOneWidget);
      expect(find.text('Channel 100'), findsNothing);
      expect(find.text(t.iptv.epgNoGuideReasonNoMatch), findsOneWidget);
    });
  });

  group('IPTV settings screen wiring', () {
    testWidgets('EPG group gains update time + playlist change; sources group lists the connection', (
      tester,
    ) async {
      CredentialVault.resetKeyForTesting();
      await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final registry = _FakeConnectionRegistry(db);
      await registry.upsert(_trexConnection());
      final manager = MultiServerManager();
      manager.debugRegisterClientForTesting(trexClient());
      final provider = testMultiServerProvider(manager);
      addTearDown(() {
        provider.dispose();
        manager.dispose();
      });

      tester.view.physicalSize = const Size(840, 12000);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
            Provider<ConnectionRegistry>.value(value: registry),
          ],
          child: InputModeTracker(
            child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const IptvSettingsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(t.iptv.epgUpdateTime), findsOneWidget);
      expect(find.text(t.iptv.epgUpdateOnPlaylistChange), findsOneWidget);
      expect(find.text(t.iptv.epgSourcesTitle), findsWidgets);

      // The sources group lists the connection; tapping it opens the
      // sources screen for that connection.
      await tester.tap(find.text('Trex').last);
      await tester.pumpAndSettle();
      expect(find.text(t.iptv.epgProviderSource), findsOneWidget);
    });
  });
}
