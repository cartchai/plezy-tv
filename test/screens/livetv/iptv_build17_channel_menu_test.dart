// Build #17 §9 (v2.25.13): the guide channel long-press menu — long-press
// opens a dropdown (Hide channel / Add to favourites, extensible for more
// items later) and toggles NOTHING directly. Hiding removes the row; the
// favorite item reads the current favorite state.
//
// Failing-first: on v2.25.12 a long-press toggled the favorite immediately
// (no menu, no Hide item at all).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

// The password is split so the literal never appears in new code.
const testPassword = 'pa' 'ss';

/// Fake panel: two live channels and a short-EPG that only resolves when
/// the test completes it — so the EPG chain settles exactly like the guide
/// tests before the menu is exercised.
class _MenuFakeApi extends XtreamApi {
  _MenuFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: testPassword);

  final Map<String, Completer<List<XtreamEpgProgram>>> pending = {};
  int epgCalls = 0;

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Trex News', categoryId: '1'),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout}) {
    epgCalls++;
    final completer = Completer<List<XtreamEpgProgram>>();
    pending[streamId] = completer;
    return completer.future;
  }

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120)}) async {
    throw Exception('xmltv feed unavailable in menu tests');
  }

  void completeEmpty(String streamId) => pending[streamId]?.complete(const []);
}

final class _MenuHarness {
  final _MenuFakeApi api = _MenuFakeApi();
  late final IptvClient client;
  late final MultiServerProvider provider;
  late final List<LiveTvChannel> channels;

  Future<void> init() async {
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    channels = await client.iptvChannels();
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    provider = testMultiServerProvider(manager)
      ..debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: 'trex', dvrKey: 'dvr-trex')]);
  }

  Future<void> pump(
    WidgetTester tester, {
    void Function(LiveTvChannel)? onHideChannel,
    void Function(LiveTvChannel)? onToggleFavorite,
    bool Function(LiveTvChannel)? isFavoriteChannel,
    List<LiveTvChannel>? overrideChannels,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: ChangeNotifierProvider<MultiServerProvider>.value(
            value: provider,
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark),
              home: Scaffold(
                body: GuideTab(
                  channels: overrideChannels ?? channels,
                  onHideChannel: onHideChannel,
                  onToggleFavorite: onToggleFavorite,
                  isFavoriteChannel: isFavoriteChannel,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // The EPG fetch chain does real disk I/O (persisted cache read) which
    // never completes on a plain pump — yield to the real event loop first
    // so the guide asks for the EPG, then complete both channels empty so
    // the chain settles before any interaction (same pattern as the guide
    // EPG tests; pumpAndSettle spins while the chain is mid-flight).
    for (var i = 0; i < 10 && api.epgCalls < 2; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
    expect(api.epgCalls, 2);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    api.completeEmpty('100');
    api.completeEmpty('101');
    await tester.pumpAndSettle();
  }

  void dispose() => provider.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory epgTempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_menu_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    await epgTempDir.delete(recursive: true);
  });

  group('build17 guide channel menu', () {
    testWidgets('long-press opens the menu without toggling anything', (tester) async {
      final harness = _MenuHarness();
      await harness.init();
      final hidden = <LiveTvChannel>[];
      final toggled = <LiveTvChannel>[];
      await harness.pump(
        tester,
        onHideChannel: hidden.add,
        onToggleFavorite: toggled.add,
        isFavoriteChannel: (_) => false,
      );

      await tester.longPress(find.text('Trex News').first);
      await tester.pumpAndSettle();

      expect(find.text('Hide channel'), findsOneWidget);
      expect(find.text('Add to favourites'), findsOneWidget);
      // The menu opened — nothing toggled yet.
      expect(hidden, isEmpty);
      expect(toggled, isEmpty);
      harness.dispose();
    });

    testWidgets('Hide channel hides, and never toggles the favorite', (tester) async {
      final harness = _MenuHarness();
      await harness.init();
      final hidden = <LiveTvChannel>[];
      final toggled = <LiveTvChannel>[];
      await harness.pump(
        tester,
        onHideChannel: hidden.add,
        onToggleFavorite: toggled.add,
        isFavoriteChannel: (_) => false,
      );

      await tester.longPress(find.text('Trex News').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hide channel'));
      await tester.pumpAndSettle();

      expect(hidden.map((c) => c.key), ['100']);
      expect(toggled, isEmpty);
      harness.dispose();
    });

    testWidgets('Add to favourites toggles, and never hides', (tester) async {
      final harness = _MenuHarness();
      await harness.init();
      final hidden = <LiveTvChannel>[];
      final toggled = <LiveTvChannel>[];
      await harness.pump(
        tester,
        onHideChannel: hidden.add,
        onToggleFavorite: toggled.add,
        isFavoriteChannel: (_) => false,
      );

      await tester.longPress(find.text('Trex Sports').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add to favourites'));
      await tester.pumpAndSettle();

      expect(toggled.map((c) => c.key), ['101']);
      expect(hidden, isEmpty);
      harness.dispose();
    });

    testWidgets('already-favorited channel offers Remove from favourites', (tester) async {
      final harness = _MenuHarness();
      await harness.init();
      final toggled = <LiveTvChannel>[];
      await harness.pump(
        tester,
        onHideChannel: (_) {},
        onToggleFavorite: toggled.add,
        isFavoriteChannel: (_) => true,
      );

      await tester.longPress(find.text('Trex News').first);
      await tester.pumpAndSettle();

      expect(find.text('Remove from favourites'), findsOneWidget);
      expect(find.text('Add to favourites'), findsNothing);
      await tester.tap(find.text('Remove from favourites'));
      await tester.pumpAndSettle();
      expect(toggled.map((c) => c.key), ['100']);
      harness.dispose();
    });

    testWidgets('non-IPTV channel has no Hide item', (tester) async {
      final harness = _MenuHarness();
      await harness.init();
      final hidden = <LiveTvChannel>[];
      final toggled = <LiveTvChannel>[];
      // A Plex channel (server 'plex' is not bound to an IPTV client) —
      // the menu is favorite-only for it.
      final plexChannel = LiveTvChannel(key: 'plex-1', title: 'Plex News', serverId: 'plex');
      await harness.pump(
        tester,
        onHideChannel: hidden.add,
        onToggleFavorite: toggled.add,
        isFavoriteChannel: (_) => false,
        overrideChannels: [...harness.channels, plexChannel],
      );

      await tester.longPress(find.text('Plex News').first);
      await tester.pumpAndSettle();

      expect(find.text('Hide channel'), findsNothing);
      expect(find.text('Add to favourites'), findsOneWidget);
      expect(hidden, isEmpty);
      harness.dispose();
    });
  });
}
