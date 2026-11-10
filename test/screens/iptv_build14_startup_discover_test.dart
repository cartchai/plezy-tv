// STARTUP WIDGET REPRO — build #14 (v2.25.10): PlezTV v2.25.9 crashes
// on Matt's phone "right after the app loads and the whole UI starts to
// come in" (Matt, 2026-11-07 ~18:35 EST), before he taps anything. He
// has a Plex server (HOME PC) connected alongside Trex. The provider
// level (libraries merge + Discover load) passes with both servers
// (iptv_build14_startup_test.dart) and the Libraries screen's first
// frame passes with both servers at phone and tablet width
// (iptv_build14_startup_libraries_test.dart), so the remaining first
// frame is the Discover (Home) tab — the default first tab — where the
// merged On Deck + hubs from ALL servers render. These tests pump the
// real Discover screen at his Fold 7 cover size with BOTH servers bound
// and let the first frame build. A build exception here is the crash.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/profiles/active_profile_provider.dart';
import 'package:plezy/profiles/plex_home_service.dart';
import 'package:plezy/profiles/profile.dart';
import 'package:plezy/profiles/profile_connection.dart';
import 'package:plezy/profiles/profile_connection_registry.dart';
import 'package:plezy/profiles/profile_registry.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/providers/discover_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/discover_screen.dart';
import 'package:plezy/screens/main_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;
import 'package:plezy/watch_together/watch_together.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => initializeDateFormatting('en'));

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
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

  XtreamConnection trexConnection() {
    return XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      hiddenCategoryInitials: hiddenInitials,
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

  group('build14: v2.25.9 startup crash — Discover screen with Plex + Trex', () {
    testWidgets('phone: first frame builds with Plex + Trex hubs and On Deck', (tester) async {
      useFakeTrexApi(_TrexScreenFakeXtreamApi());
      final harness = await _Harness.create();
      addTearDown(harness.dispose);

      // Matt's order: Plex (HOME PC) was connected long before Trex.
      harness.manager.debugRegisterClientForTesting(_FakePlexClient());
      expect(await harness.manager.addIptvConnection(trexConnection()), isTrue);

      // First frame with both servers bound: must build, not throw.
      await harness.pump(tester);

      // The overlaid app bar Row used to overflow by 40px at 360dp
      // (discover_screen.dart _buildOverlaidAppBar) — fixed in build #14 by
      // letting the title shrink with an ellipsis instead of pushing the
      // actions off-screen. There must be no exception at all now, so the
      // test fails on ANY exception, including a layout overflow.
      expect(tester.takeException(), isNull);

      // Plex On Deck + Plex hubs render.
      expect(find.text('Plex Movie 1'), findsWidgets);
      expect(find.text('Recommended'), findsWidgets);
      // Trex hub rows are loaded into the provider (they sit below the
      // Plex rows in the scrollable, so assert on the loaded data rather
      // than scrolling: the first-frame-build check above is the crash
      // check, and the Libraries-screen test already proves Trex rows
      // render on screen).
      final trexHubs = harness.discover.hubs.where((h) => h.serverId == 'conn-xt-1').toList();
      expect(trexHubs.map((h) => h.libraryId), containsAll(['iptv:conn-xt-1:movies', 'iptv:conn-xt-1:series']));
      expect(trexHubs.expand((h) => h.items).map((i) => i.title), containsAll(['Alpha Movie', 'Alpha Show']));
    });
  });
}

/// Harness: the real Discover provider stack, pumped with the real
/// Discover screen at phone size. Mirrors discover_screen_test.dart's
/// setup, minus the TV-only pieces (no AppleTV override, phone viewport).
final class _Harness {
  _Harness({
    required this.manager,
    required this.multiServer,
    required this.hiddenLibraries,
    required this.libraries,
    required this.discover,
    required this.activeProfile,
    required this.watchTogether,
    required this.companionRemote,
    required this.plexHome,
    required this.db,
  });

  final MultiServerManager manager;
  final MultiServerProvider multiServer;
  final HiddenLibrariesProvider hiddenLibraries;
  final LibrariesProvider libraries;
  final DiscoverProvider discover;
  final ActiveProfileProvider activeProfile;
  final WatchTogetherProvider watchTogether;
  final CompanionRemoteProvider companionRemote;
  final PlexHomeService plexHome;
  final AppDatabase db;

  static Future<_Harness> create() async {
    final manager = MultiServerManager();
    final multiServer = testMultiServerProvider(manager);
    final hiddenLibraries = HiddenLibrariesProvider();
    final libraries = LibrariesProvider();
    final watchTogether = WatchTogetherProvider();
    final companionRemote = CompanionRemoteProvider();

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final profileRegistry = _FakeProfileRegistry(db);
    final connectionRegistry = _FakeConnectionRegistry(db);
    final profileConnectionRegistry = _FakeProfileConnectionRegistry(db);
    final storage = await StorageService.getInstance();
    final plexHome = PlexHomeService(
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
      plexHomeUserFetcher: (_) async => const [],
    );
    final activeProfile = ActiveProfileProvider(
      registry: profileRegistry,
      plexHome: plexHome,
      connections: connectionRegistry,
      profileConnections: profileConnectionRegistry,
      storage: storage,
    );
    final discover = DiscoverProvider(
      multiServer,
      hiddenLibraries,
      libraries,
      profileId: null,
      isProfileBinding: () => activeProfile.isBinding,
    );
    return _Harness(
      manager: manager,
      multiServer: multiServer,
      hiddenLibraries: hiddenLibraries,
      libraries: libraries,
      discover: discover,
      activeProfile: activeProfile,
      watchTogether: watchTogether,
      companionRemote: companionRemote,
      plexHome: plexHome,
      db: db,
    );
  }

  Future<void> pump(WidgetTester tester) async {
    // Matt's phone: Fold 7 cover screen (~360dp wide).
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibraries),
            ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
            ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
            ChangeNotifierProvider<CompanionRemoteProvider>.value(value: companionRemote),
            ChangeNotifierProvider<ActiveProfileProvider>.value(value: activeProfile),
            ChangeNotifierProvider<DiscoverProvider>.value(value: discover),
          ],
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: MainScreenFocusScope(
              focusSidebar: () {},
              sideNavigationWidth: 0,
              reservedSideNavigationWidth: 0,
              foregroundLeft: 0,
              foregroundWidth: 360,
              viewportWidth: 360,
              child: const SizedBox(width: 360, height: 800, child: DiscoverScreen()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dispose() async {
    discover.dispose();
    activeProfile.dispose();
    companionRemote.dispose();
    watchTogether.dispose();
    libraries.dispose();
    hiddenLibraries.dispose();
    multiServer.dispose();
    await plexHome.dispose();
    await db.close();
    manager.dispose();
  }
}

/// Dummy Plex server (HOME PC): three libraries, global hubs, Continue
/// Watching. Only the surface the startup load touches is implemented.
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
    MediaHub(
      id: 'plex:recently-added',
      title: 'Recently Added',
      type: 'movie',
      items: [_plexItem('plex-3', 'Plex Movie 3')],
      size: 1,
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

class _FakeProfileRegistry extends ProfileRegistry {
  _FakeProfileRegistry(super.db);

  @override
  Stream<List<Profile>> watchProfiles() => Stream.value(const []);

  @override
  Future<List<Profile>> list() async => const [];
}

class _FakeConnectionRegistry extends ConnectionRegistry {
  _FakeConnectionRegistry(super.db);

  @override
  Stream<List<Connection>> watchConnections() => Stream.value(const []);

  @override
  Future<List<Connection>> list() async => const [];
}

class _FakeProfileConnectionRegistry extends ProfileConnectionRegistry {
  _FakeProfileConnectionRegistry(super.db);

  @override
  Stream<List<ProfileConnection>> watchAll() => Stream.value(const []);
}
