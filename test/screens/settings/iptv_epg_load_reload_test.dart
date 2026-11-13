import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/iptv_epg_sources_screen.dart';
import 'package:plezy/screens/settings/iptv_settings_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

/// Widget probe for the Reload TV details tap (PlezTV 1.2.1, base
/// bc97412c7) — Matt's phone verdict 2026-11-13 ~12:27 EST: tapping
/// "Reload TV details" shows nothing. No live panel use — fakes only.

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
/// `failLiveStreams` makes the channel-list re-fetch throw, like a 403
/// on get_live_streams.
class _FakeXtreamApi extends XtreamApi {
  _FakeXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'hunter-9');

  List<XtreamLiveStream> liveStreams = [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
  ];

  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  bool failLiveStreams = false;
  // 1.2.3: slow the feed down so the spinner tests (W2/W3) can observe
  // the working indicator mid-reload. Zero by default (W1 stays fast).
  Duration xmltvDelay = Duration.zero;

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'General')];

  @override
  Future<Map<String, dynamic>?> getUserInfo() async => {'status': 'Active'};

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (failLiveStreams) throw StateError('get_live_streams unavailable (HTTP 403)');
    return liveStreams;
  }

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async => const [];

  @override
  Stream<List<int>> getXmltvStream({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async* {
    yield utf8.encode(await getXmltv(timeout: timeout, abortTrigger: abortTrigger));
  }

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    if (xmltvDelay > Duration.zero) await Future<void>.delayed(xmltvDelay);
    return xmltvBody;
  }
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
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_load_widget_');
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

  testWidgets('W1 tapping Reload TV details with a failing channel list shows a report', (tester) async {
    // Desired: the tap ALWAYS ends in a report — counts on success, the
    // failure named on failure. On base, _reloadTvDetails() has no
    // try/catch: reloadTvDetails() throws at refreshLiveChannelsFromNetwork
    // (get_live_streams 403) before any result exists, the error escapes
    // the unawaited future, and no dialog is ever built — the tap looks
    // dead. This is Matt's exact phone report (12:27 EST).
    api.failLiveStreams = true;
    await pumpSourcesScreen(tester);

    expect(find.text(t.iptv.epgReloadTvDetails), findsOneWidget);
    await tester.tap(find.text(t.iptv.epgReloadTvDetails));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      find.byType(AlertDialog),
      findsOneWidget,
      reason: 'Reload TV details must always end in a report dialog — on a failing channel-list re-fetch it must name the failure, not show nothing',
    );
  });

  testWidgets('W2 Reload shows a spinner while it runs and clears it when the report appears', (tester) async {
    // Matt, 2026-11-13 ~12:43 EST: "Reload must show visible working
    // feedback WHILE it runs — a spinner/progress indicator on the
    // tap/row — so he knows the tap did something before the report
    // appears." The feed is slowed down so the working state is
    // observable: one pump after the tap the spinner is up and no
    // dialog exists yet; once the feed lands the report appears and
    // the spinner is gone.
    api.xmltvDelay = const Duration(milliseconds: 500);
    await pumpSourcesScreen(tester);

    expect(find.text(t.iptv.epgReloadTvDetails), findsOneWidget);
    await tester.tap(find.text(t.iptv.epgReloadTvDetails));
    await tester.pump();

    expect(
      find.byType(CircularProgressIndicator),
      findsWidgets,
      reason: 'the Reload row must show a spinner while the list + feeds load',
    );
    expect(find.byType(AlertDialog), findsNothing, reason: 'no report yet — the reload is still running');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget, reason: 'the reload ends in the report dialog');
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'the spinner clears when the report appears — it must not keep spinning behind the dialog',
    );
  });

  testWidgets('W3 Update now shows a spinner while it refreshes, then a report naming the feed', (tester) async {
    // Same working-feedback requirement as W2, for Update now (1.2.3
    // RC2: it attempts a real refresh). The feed is slowed down so the
    // working state is observable; the report names the feed outcome
    // (here: the empty feed loaded, so no guide data) instead of a
    // "Guide updated" snackbar.
    CredentialVault.resetKeyForTesting();
    await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
    api.xmltvDelay = const Duration(milliseconds: 500);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final registry = _FakeConnectionRegistry(db);
    await registry.upsert(_trexConnection());
    final provider = await providerWithClient();
    // Tall viewport so the EPG group (Update now) is built, not below
    // the fold — same as pumpSourcesScreen above.
    tester.view.physicalSize = const Size(840, 4000);
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

    expect(find.text(t.iptv.epgUpdateNow), findsOneWidget);
    await tester.ensureVisible(find.text(t.iptv.epgUpdateNow));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.iptv.epgUpdateNow));
    await tester.pump();

    expect(
      find.byType(CircularProgressIndicator),
      findsWidgets,
      reason: 'the Update now row must show a spinner while the feed downloads',
    );
    expect(find.byType(AlertDialog), findsNothing, reason: 'no report yet — the refresh is still running');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget, reason: 'Update now ends in a report dialog, not a snackbar');
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'the spinner clears when the report appears',
    );
    expect(
      find.text(t.iptv.epgFeedOutcomeLoadedEmpty(source: 'Provider guide')),
      findsOneWidget,
      reason: 'the report names the feed outcome — the empty feed loaded, so there is no guide data',
    );
  });
}
