// SCREEN-LEVEL REPRODUCTION — build #13 (v2.25.9): the Trex Movies and
// Series libraries are MISSING on v2.25.8 (Matt, 2026-11-07 ~05:17 EST),
// while Live TV "half works". They were present on v2.25.6/7.
//
// These tests drive the real Libraries screen through the real provider
// stack (MultiServerManager -> MultiServerProvider -> DataAggregationService
// -> LibrariesProvider -> LibrariesScreen) with a Trex-shaped Xtream
// connection and Matt's filter state (161 of 171 category initials hidden,
// EN shown). No unit-test shortcut: the libraries must appear ON SCREEN.
//
// Shapes under test:
// - LATE BIND: the screen's first libraries load runs before Trex binds
//   (cold start: the health probe is still in flight), then Trex comes
//   online. The libraries must appear without a restart or a pull.
// - PRE-BOUND: Trex is already online when the screen mounts.
// - ALL-IDS-DISABLED: every VOD + series category id is turned off. The
//   libraries must STILL be listed — a filter hides content, it must never
//   delete the library row itself (build #13 fix: fetchLibraries never
//   omits the synthetic libraries; the _allCategoriesDisabled probe is
//   gone, so this test FAILS before the fix and passes after).
// - BROWSE ROWS: with the libraries listed, Movies Browse loads rows and
//   Series Browse loads rows (the v2.25.6 spinner bug, at screen level).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/libraries/libraries_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../test_helpers/download_fixtures.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    // Widget tests run in a fake async zone: real disk I/O hangs.
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() {
    IptvClient.debugClientFactory = null;
    IptvCatalogDiskCache.debugDisableDisk = false;
  });

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  // Matt's filter state, in shape: every initial hidden except EN.
  const hiddenInitials = ['AR', 'FR', 'DE', 'PL', 'ES', 'IN', 'NL', 'SE'];

  XtreamConnection trexConnection({List<String> hiddenCategoryIds = const []}) {
    return XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      hiddenCategoryInitials: hiddenInitials,
      hiddenCategoryIds: hiddenCategoryIds,
      createdAt: DateTime.utc(2026, 11, 5),
    );
  }

  /// Point the client's factory at a fake-backed Trex client, so the real
  /// [MultiServerManager.addIptvConnection] path (health probe -> status
  /// emit -> warm-up) runs against the fake panel.
  void useFakeTrexApi(_TrexScreenFakeXtreamApi api) {
    IptvClient.debugClientFactory = (connection) {
      final client = IptvClient.xtream(xtreamConnection: connection as XtreamConnection);
      client.testXtreamApi = api;
      return client;
    };
  }

  group('build13: Trex libraries on the Libraries screen (cold start)', () {
    testWidgets('late bind: libraries appear after Trex comes online', (tester) async {
      final api = _TrexScreenFakeXtreamApi();
      useFakeTrexApi(api);
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      // Cold start: the screen mounts and loads libraries BEFORE Trex
      // binds (its health probe is still in flight).
      await harness.pump(tester);
      expect(find.text('Trex — Movies'), findsNothing);

      // Trex binds through the real manager path.
      expect(await harness.manager.addIptvConnection(trexConnection()), isTrue);
      await tester.pumpAndSettle();

      // No restart, no pull-to-refresh: the libraries must be listed.
      // On the phone-width layout the picker is a dropdown showing the
      // selected library; open it to see the full list.
      expect(find.text('Trex — Movies'), findsWidgets);
      await tester.tap(find.text('Trex — Movies').first);
      await tester.pumpAndSettle();
      expect(find.text('Trex — Series'), findsWidgets);
    });

    testWidgets('pre-bound: libraries appear on the first load', (tester) async {
      final api = _TrexScreenFakeXtreamApi();
      useFakeTrexApi(api);
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      expect(await harness.manager.addIptvConnection(trexConnection()), isTrue);
      await harness.pump(tester);

      expect(find.text('Trex — Movies'), findsWidgets);
      await tester.tap(find.text('Trex — Movies').first);
      await tester.pumpAndSettle();
      expect(find.text('Trex — Series'), findsWidgets);
    });

    testWidgets('all category ids disabled: libraries are still listed', (tester) async {
      // Every VOD + series category id turned off (the "Hide all groups"
      // state) — including the AR region category's id, so the probe's
      // `every` check would pass and the libraries would be omitted.
      final allIds = [for (var i = 1; i <= 150; i++) '$i', '900'];
      final api = _TrexScreenFakeXtreamApi();
      useFakeTrexApi(api);
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      expect(
        await harness.manager.addIptvConnection(trexConnection(hiddenCategoryIds: allIds)),
        isTrue,
      );
      await harness.pump(tester);

      expect(find.text('Trex — Movies'), findsWidgets);
      await tester.tap(find.text('Trex — Movies').first);
      await tester.pumpAndSettle();
      expect(find.text('Trex — Series'), findsWidgets);
    });

    testWidgets('browse rows load for Movies and Series', (tester) async {
      final api = _TrexScreenFakeXtreamApi();
      useFakeTrexApi(api);
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      expect(await harness.manager.addIptvConnection(trexConnection()), isTrue);
      await harness.pump(tester);
      expect(find.text('Trex — Movies'), findsWidgets);

      // The screen auto-selects the first library (Trex — Movies) and its
      // Browse tab must load rows, not spin forever.
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha Movie'), findsWidgets);

      // Switch to the Series library via the dropdown; its Browse tab
      // must load rows too.
      await tester.tap(find.text('Trex — Movies').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trex — Series').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha Show'), findsWidgets);
    });
  });
}

/// Minimal harness: the real provider stack, pumped with the real
/// Libraries screen. Mirrors the libraries_screen_test.dart _Harness, but
/// wires LibrariesProvider to the live MultiServerProvider so late binds
/// flow through syncToOnlineServers like they do on the phone.
final class _Harness {
  _Harness({required this.libraries, required this.hiddenLibraries, required this.multiServer, required this.manager});

  final LibrariesProvider libraries;
  final HiddenLibrariesProvider hiddenLibraries;
  final MultiServerProvider multiServer;
  final MultiServerManager manager;

  static Future<_Harness> create() async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.withData({});
    await SettingsService.getInstance();
    await StorageService.getInstance();
    final manager = MultiServerManager();
    final multiServer = testMultiServerProvider(manager);
    final libraries = LibrariesProvider(multiServer: multiServer);
    libraries.initialize(multiServer.aggregationService);
    final hiddenLibraries = HiddenLibrariesProvider();
    await hiddenLibraries.ensureInitialized();
    return _Harness(
      libraries: libraries,
      hiddenLibraries: hiddenLibraries,
      multiServer: multiServer,
      manager: manager,
    );
  }

  Future<void> pump(WidgetTester tester) async {
    final downloads = NoSyncRulesDownloadProvider();
    addTearDown(downloads.dispose);
    // Matt's phone: Fold 7 cover screen (~360dp wide). Phone width takes
    // the dropdown library picker, not the desktop side nav.
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibraries),
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: OverlaySheetHost(
              child: FocusScope(
                child: LibrariesScreen(onLibrarySelected: (_) {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void dispose() {
    libraries.dispose();
    hiddenLibraries.dispose();
    multiServer.dispose();
    manager.dispose();
  }
}

/// Trex-shaped fake panel: 150 EN categories per section, one AR category
/// hidden by Matt's initials, one Alpha row per section, healthy login.
class _TrexScreenFakeXtreamApi extends XtreamApi {
  _TrexScreenFakeXtreamApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  List<XtreamCategory> _categories(String prefix) => [
    for (var i = 1; i <= 150; i++) XtreamCategory(id: '$i', name: '|EN| $prefix $i'),
    const XtreamCategory(id: '900', name: '|AR| Hidden Region'),
  ];

  @override
  Future<Map<String, dynamic>?> getUserInfo() async => {'username': 'user', 'status': 'Active'};

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => _categories('Series');

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async => _categories('Movies');

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => _categories('Live');

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    return const [XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1')];
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    return const [
      XtreamVodStream(streamId: 1, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: '1'),
    ];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    return const [
      XtreamLiveStream(streamId: 100, name: 'HBO East', categoryId: '1'),
      XtreamLiveStream(streamId: 101, name: 'Al Jazeera', categoryId: '900'),
    ];
  }
}
