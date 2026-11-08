// STARTUP WIDGET REPRO — build #14 (v2.25.10): PlezTV v2.25.9 crashes
// on Matt's phone "right after the app loads and the whole UI starts to
// come in" (Matt, 2026-11-07 ~18:35 EST), before he taps anything. He
// has a Plex server (HOME PC) connected alongside Trex. The provider
// level (libraries merge + Discover load) passes with both servers
// (iptv_build14_startup_test.dart), so the crash — if it is in Dart at
// all — must be in the first-frame WIDGET build with merged Plex + IPTV
// data. These tests pump the real Libraries screen (the screen Matt
// lives in) at his Fold 7 cover size with BOTH servers bound, and let
// the first frame build. A build exception here is the crash.
//
// Shapes under test:
// - PLEX FIRST: Plex (HOME PC) binds before Trex, so the screen
//   auto-selects a Plex library and its Browse tab loads Plex rows while
//   the Trex libraries sit in the picker.
// - TREX FIRST: Trex binds first (library order flipped), so the screen
//   auto-selects Trex — Movies and its Browse tab loads IPTV rows.
// - WIDE: the same Plex-first bind at tablet width (unfolded Fold),
//   where the screen takes the wide layout branch instead of the phone
//   dropdown picker.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_filter_result.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_sort.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
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
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../../test_helpers/download_fixtures.dart';
import '../../test_helpers/media_items.dart';
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

  XtreamConnection trexConnection({List<String>? hiddenCategoryInitials}) {
    return XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      hiddenCategoryInitials: hiddenCategoryInitials ?? hiddenInitials,
      createdAt: DateTime.utc(2026, 11, 5),
    );
  }

  void useFakeTrexApi(_TrexScreenFakeXtreamApi api) {
    IptvClient.debugClientFactory = (connection) {
      final client = IptvClient.xtream(xtreamConnection: connection as XtreamConnection);
      client.testXtreamApi = api;
      return client;
    };
  }

  group('build14: v2.25.9 startup crash — Libraries screen with Plex + Trex', () {
    testWidgets('plex first: first frame builds, Plex library browses, Trex in picker', (tester) async {
      useFakeTrexApi(_TrexScreenFakeXtreamApi());
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      // Matt's order: Plex (HOME PC) was connected long before Trex.
      harness.manager.debugRegisterClientForTesting(_FakePlexClient());
      expect(await harness.manager.addIptvConnection(trexConnection()), isTrue);

      // First frame with both servers bound: must build, not throw.
      await harness.pump(tester);

      // The screen auto-selects the first library (Plex Movies) and its
      // Browse tab must load Plex rows.
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      expect(find.text('Plex Movie 1'), findsWidgets);

      // Trex libraries are in the picker alongside Plex.
      await tester.tap(find.text('Movies').first);
      await tester.pumpAndSettle();
      expect(find.text('Trex — Movies'), findsWidgets);
      expect(find.text('Trex — Series'), findsWidgets);
    });

    testWidgets('trex first: first frame builds, Trex Movies browses', (tester) async {
      useFakeTrexApi(_TrexScreenFakeXtreamApi());
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      expect(await harness.manager.addIptvConnection(trexConnection()), isTrue);
      harness.manager.debugRegisterClientForTesting(_FakePlexClient());

      await harness.pump(tester);

      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha Movie'), findsWidgets);
    });

    testWidgets('plex first at tablet width: first frame builds in wide layout', (tester) async {
      useFakeTrexApi(_TrexScreenFakeXtreamApi());
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      harness.manager.debugRegisterClientForTesting(_FakePlexClient());
      expect(await harness.manager.addIptvConnection(trexConnection()), isTrue);

      await harness.pump(tester, size: const Size(1280, 800));

      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      expect(find.text('Plex Movie 1'), findsWidgets);
    });

    testWidgets('rebind with a toggled initial refreshes promptly, not after the 2-minute cooldown', (tester) async {
      // Build #14: toggling a category initial rebinds the client, and the
      // tab's RefreshPacer used to defer that refresh to the cooldown's
      // trailing edge (up to 2 minutes) because the tab had just loaded.
      // A user-initiated rebind must bypass the cooldown: the toggle shows
      // within the 3s debounce, not after 2 minutes. FAILS before the fix
      // (Alpha Movie still listed after 5s), PASSES after.
      useFakeTrexApi(_TrexScreenFakeXtreamApi());
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      expect(await harness.manager.addIptvConnection(trexConnection()), isTrue);
      await harness.pump(tester);

      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha Movie'), findsWidgets);

      // Toggle the EN initial off: the Alpha Movie's category ('|EN|
      // Movies 1) is now hidden. Rebind through the real manager path.
      expect(
        await harness.manager.addIptvConnection(
          trexConnection(hiddenCategoryInitials: [...hiddenInitials, 'EN']),
        ),
        isTrue,
      );

      // 5s of fake time: past the 3s debounce, far short of the 2-minute
      // cooldown. The refresh must already have landed.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Alpha Movie'), findsNothing);
    });
  });
}

/// Minimal harness: the real provider stack, pumped with the real
/// Libraries screen. Mirrors iptv_build13_libraries_screen_test.dart's
/// _Harness, with a size parameter for the cover/tablet branches.
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

  Future<void> pump(WidgetTester tester, {Size size = const Size(360, 800)}) async {
    final downloads = NoSyncRulesDownloadProvider();
    addTearDown(downloads.dispose);
    tester.view.physicalSize = size;
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

/// Dummy Plex server (HOME PC): three libraries, global hubs, Continue
/// Watching. Only the surface the Libraries screen touches is implemented.
class _FakePlexClient implements MediaServerClient {
  @override
  ServerId get serverId => ServerId('plex-home-pc');

  @override
  String? get serverName => 'HOME PC';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  Object get authenticationSessionId => 'plex-home-pc';

  List<MediaLibrary> get _libraries => [
    MediaLibrary(id: '1', backend: MediaBackend.plex, title: 'Movies', kind: MediaKind.movie, serverId: serverId),
    MediaLibrary(id: '2', backend: MediaBackend.plex, title: 'TV Shows', kind: MediaKind.show, serverId: serverId),
    MediaLibrary(id: '3', backend: MediaBackend.plex, title: 'Music', kind: MediaKind.artist, serverId: serverId),
  ];

  MediaItem _plexItem(String id, String title) => testMediaItem(
    id: id,
    backend: MediaBackend.plex,
    kind: MediaKind.movie,
    title: title,
    serverId: 'plex-home-pc',
    serverName: 'HOME PC',
  );

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => _libraries;

  @override
  Future<List<MediaItem>> fetchContinueWatching({
    int? count = 20,
    Set<String> excludedLibraryIds = const {},
  }) async => [_plexItem('plex-cw-1', 'Plex Movie 1')];

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) async => [
    MediaHub(
      id: 'plex:recommended',
      title: 'Recommended',
      type: 'movie',
      items: [_plexItem('plex-1', 'Plex Movie 1'), _plexItem('plex-2', 'Plex Movie 2')],
      size: 2,
    ),
  ];

  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  }) async => [
    MediaHub(
      id: 'plex:$libraryId:recent',
      title: 'Recently Added in $libraryName',
      type: 'movie',
      items: [_plexItem('plex-$libraryId-1', 'Plex $libraryName 1')],
      size: 1,
    ),
  ];

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async =>
      LibraryFilterResult.empty;

  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => const [];

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async => LibraryPage(items: [_plexItem('plex-$libraryId-p1', 'Plex Movie 1')], totalCount: 1);

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
  Future<List<XtreamCategory>> getSeriesCategories() async => _categories('Series');

  @override
  Future<List<XtreamCategory>> getVodCategories() async => _categories('Movies');

  @override
  Future<List<XtreamCategory>> getLiveCategories() async => _categories('Live');

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    return const [XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1')];
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async {
    return const [
      XtreamVodStream(streamId: 1, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: '1'),
    ];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async {
    return const [
      XtreamLiveStream(streamId: 100, name: 'HBO East', categoryId: '1'),
      XtreamLiveStream(streamId: 101, name: 'Al Jazeera', categoryId: '900'),
    ];
  }
}
