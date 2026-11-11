import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/library_filter_result.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/libraries/libraries_screen.dart';
import 'package:plezy/screens/libraries/tabs/library_browse_tab.dart';
import 'package:plezy/screens/libraries/tabs/library_recommended_tab.dart';
import 'package:plezy/screens/livetv/live_tv_screen.dart';
import 'package:plezy/screens/auth_screen.dart';
import 'package:plezy/screens/settings/about_screen.dart';
import 'package:plezy/screens/settings/iptv_settings_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_item_favorites_repository.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/download_fixtures.dart';
import '../../test_helpers/library_tab_scaffold.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

/// Pre-ship screen tests for the Plezy TV IPTV flows (the build #4 lesson:
/// unit tests + analyze passed while the real flows were broken on Matt's
/// phone). Every test pumps the ACTUAL screen with a fake Plex client and a
/// REAL [IptvClient] backed by a fake Xtream catalog — no network — and
/// asserts exactly what Matt checks on his phone:
///
/// - Libraries: "Trex — Live TV" must NOT appear; Movies + Series must.
/// - Movies / Series library: Recommended AND Browse must show items, not
///   "Unable to load Recommended".
/// - Live TV: the source picker must offer HOME PC and Trex, and picking
///   each must show that source's channels.
/// - Settings → IPTV: the settings screen renders the Trex connection.
const _trexMoviesLibrary = MediaLibrary(
  id: 'iptv:trex:movies',
  backend: MediaBackend.xtream,
  title: 'Trex — Movies',
  kind: MediaKind.movie,
  serverId: 'trex',
  serverName: 'Trex',
);

const _trexSeriesLibrary = MediaLibrary(
  id: 'iptv:trex:series',
  backend: MediaBackend.xtream,
  title: 'Trex — Series',
  kind: MediaKind.show,
  serverId: 'trex',
  serverName: 'Trex',
);

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: 'pass',
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Fake provider catalog: two movies, one series, two live channels (one
/// with catch-up), a handful of categories. Mirrors the stage-2 fake.
class _FakeXtreamApi extends XtreamApi {
  _FakeXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pass');

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (failCatalogs) _catalogTimeout();
    return const [
      XtreamVodStream(streamId: 1, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: '1'),
      XtreamVodStream(streamId: 2, name: 'Beta Movie', containerExtension: 'mkv', categoryId: '2'),
    ];
  }

  /// When true, the unfiltered series call never answers — the diagnostics
  /// probe hangs, so a test can prove the "Last search" row does not wait
  /// for it (build #14, UI-2). Per-category calls still answer.
  bool hangUnfilteredSeries = false;

  /// When true, every catalog + category fetch throws a timeout — the
  /// panel answers nothing, like Matt's manual refresh on 2026-11-11
  /// (v1.0.10: the sync dialog must report the failure, not "Catalog
  /// synced").
  bool failCatalogs = false;

  Never _catalogTimeout() => throw MediaServerHttpException(
    type: MediaServerHttpErrorType.connectionTimeout,
    message: 'Future not completed',
  );

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    if (failCatalogs) _catalogTimeout();
    if (hangUnfilteredSeries && categoryId == null) {
      return Completer<List<XtreamSeries>>().future;
    }
    return const [
      XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1'),
    ];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (failCatalogs) _catalogTimeout();
    return const [
      XtreamLiveStream(
        streamId: 100,
        name: 'Trex News',
        categoryId: '1',
        tvArchive: true,
        tvArchiveDuration: 86400,
      ),
      XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
    ];
  }

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async {
    if (failCatalogs) _catalogTimeout();
    return const [XtreamCategory(id: '1', name: 'Action'), XtreamCategory(id: '2', name: 'Drama')];
  }

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async {
    if (failCatalogs) _catalogTimeout();
    return const [XtreamCategory(id: '1', name: 'Action')];
  }

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async {
    if (failCatalogs) _catalogTimeout();
    return const [XtreamCategory(id: '1', name: 'News')];
  }

  // EPG: the guide fetches these for every visible channel. The real
  // implementations hit the network (xmltv.php has a 120s timeout), so
  // they must be stubbed here — a real HTTP call never completes inside
  // `testWidgets`' fake async zone and the guide's loading indicator
  // would spin `pumpAndSettle` into its timeout.
  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async =>
      '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async => const [];
}

/// In-memory favourites store for widget tests. The production store
/// reads SharedPreferences, whose platform round-trip never completes
/// inside `testWidgets`' fake async zone when the read is started from a
/// widget load — the tab would spin its loading indicator forever. This
/// store completes synchronously (a plain async function), so the item
/// load finishes on pumps. Persistence itself is covered by the unit
/// tests in `iptv_item_favorites_test.dart`.
class _InMemoryItemFavoritesRepository implements IptvItemFavoritesRepository {
  Map<String, IptvFavoriteItem> _items = {};

  @override
  Future<Map<String, IptvFavoriteItem>> read({required String key}) async => Map.of(_items);

  @override
  Future<void> write(String key, Map<String, IptvFavoriteItem> items) async {
    _items = Map.of(items);
  }
}

/// The REAL IptvClient, pointed at the fake catalog. Anything this client
/// gets wrong, the tests catch.
IptvClient _trexClient() {
  final client = IptvClient.xtream(xtreamConnection: _trexConnection());
  client.testXtreamApi = _FakeXtreamApi();
  client.testItemFavoritesRepository = _InMemoryItemFavoritesRepository();
  return client;
}

/// Minimal Plex stand-in: two libraries, two live channels, everything else
/// unimplemented (throws, like the existing fakes).
class _FakePlexClient implements MediaServerClient {
  _FakePlexClient(this.liveTv);

  @override
  final LiveTvSupport liveTv;

  @override
  ServerId get serverId => ServerId('home-pc');

  @override
  String get serverName => 'HOME PC';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => const [
    MediaLibrary(
      id: 'plex-movies',
      backend: MediaBackend.plex,
      title: 'Movies',
      kind: MediaKind.movie,
      serverId: 'home-pc',
      serverName: 'HOME PC',
    ),
    MediaLibrary(
      id: 'plex-shows',
      backend: MediaBackend.plex,
      title: 'TV Shows',
      kind: MediaKind.show,
      serverId: 'home-pc',
      serverName: 'HOME PC',
    ),
  ];

  @override
  void close() {}

  /// The Libraries screen auto-selects the first library and loads its
  /// Recommended content through these — without them the fake hits
  /// noSuchMethod and the whole screen degrades to an error state.
  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  }) async => const [];

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async => const LibraryPage(items: [], totalCount: 0);

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async =>
      LibraryFilterResult.empty;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePlexLiveTv implements LiveTvSupport {
  @override
  LiveTvDvrSupport? get dvr => null;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<LiveTvChannel>> fetchChannels({String? lineup}) async => [
    LiveTvChannel(key: '1000', number: '1000', title: 'A&E US Eastern', serverId: 'home-pc'),
    LiveTvChannel(key: '1001', number: '1001', title: 'ABC (KABC) Los Angeles', serverId: 'home-pc'),
  ];

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) async => const [];

  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async => null;

  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => 'server://home-pc/plex';

  @override
  String get favoriteStoreKey => 'plex:home-pc';

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({
    bool migrate = true,
    void Function()? checkCurrent,
  }) async => const [];

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) async {}
}

/// Registry with a fake live stream: the real Drift `watchConnections()`
/// stream schedules a zero-duration close timer when its StreamBuilder
/// unmounts, which the test framework flags as a pending timer. The screen
/// under test only needs the connection list, so the stream is a fixed
/// value while `list()` / `upsert()` still hit the real in-memory DB.
/// (Same pattern as profile_detail_screen_test's `_FakeConnectionRegistry`.)
class _FakeConnectionRegistry extends ConnectionRegistry {
  _FakeConnectionRegistry(super.db);

  @override
  Stream<List<Connection>> watchConnections() => Stream.value([_trexConnection()]);
}

/// Pump the Live TV screen until it stops changing, yielding to the REAL
/// event loop between frames. The guide's EPG fetch reads the persisted
/// cache from disk (real dart:io) and `pumpAndSettle` never yields to real
/// async, so a plain `pumpAndSettle` times out while the fetch is still
/// in flight even though the screen would settle fine. This mirrors the
/// frame-by-frame pumping the screen actually needs (a few frames after
/// the file I/O lands).
Future<void> pumpLiveTvSettled(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
  }
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory epgTempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    await StorageService.getInstance();
    // The persisted EPG cache resolves its directory through
    // path_provider, whose platform channel has no mock in widget tests
    // — a guide fetch would hang on it forever. Point it at a temp dir
    // (same seam the EPG cache unit tests use). The catalog disk cache
    // (build #11) is switched off in widget tests instead: its real
    // dart:io never completes in testWidgets' fake async zone, and its
    // behaviour is covered by the unit tests — see `debugDisableDisk`.
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_screens_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  testWidgets('Libraries screen lists Trex Movies + Series but no Trex Live TV library', (tester) async {
    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(_FakePlexClient(_FakePlexLiveTv()));
    manager.debugRegisterClientForTesting(_trexClient());
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });

    final libraries = LibrariesProvider();
    libraries.initialize(provider.aggregationService);
    // initialize() only stores the service — the app shell normally triggers
    // the load via syncToOnlineServers when servers come online. Drive the
    // real load here so the screen shows what the aggregation fetch returns.
    await libraries.loadLibraries();
    final hiddenLibraries = HiddenLibrariesProvider();
    await hiddenLibraries.ensureInitialized();
    addTearDown(() {
      libraries.dispose();
      hiddenLibraries.dispose();
    });

    // Phone viewport: the library list lives in the app-bar dropdown (on
    // wide layouts it moves to MainScreen's side nav, which this screen
    // doesn't render standalone). physicalSize is in physical pixels, so
    // 840x1800 at ratio 2 == 420x900 logical.
    tester.view.physicalSize = const Size(840, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final downloads = NoSyncRulesDownloadProvider();
    addTearDown(downloads.dispose);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibraries),
          ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: OverlaySheetHost(child: FocusScope(child: LibrariesScreen(onLibrarySelected: (_) {}))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The selected library (Plex Movies) is the dropdown title.
    expect(find.text('Movies'), findsWidgets);

    // Open the library dropdown: every library must be listed there.
    await tester.tap(find.byTooltip(t.libraries.selectLibrary));
    await tester.pumpAndSettle();

    // Plex still works.
    expect(find.text('TV Shows'), findsWidgets);
    // IPTV on-demand libraries are present…
    expect(find.text('Trex — Movies'), findsWidgets);
    expect(find.text('Trex — Series'), findsWidgets);
    // …and live TV is NOT a library.
    expect(find.text('Trex — Live TV'), findsNothing);
  });

  testWidgets('Movies Recommended tab loads items instead of "Unable to load Recommended"', (tester) async {
    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(_trexClient());
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });

    await pumpLibraryTab(
      tester,
      provider: provider,
      tab: const LibraryRecommendedTab(library: _trexMoviesLibrary),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alpha Movie'), findsWidgets);
    expect(find.text('Beta Movie'), findsWidgets);
    expect(find.textContaining('Unable to load'), findsNothing);
  });

  testWidgets('Movies Browse tab loads items', (tester) async {
    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(_trexClient());
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });

    await pumpLibraryTab(
      tester,
      provider: provider,
      tab: const LibraryBrowseTab(library: _trexMoviesLibrary, canGroupByFolders: false),
    );
    await pumpRequestFrames(tester);
    await tester.pumpAndSettle();

    expect(find.text('Alpha Movie'), findsWidgets);
    expect(find.text('Beta Movie'), findsWidgets);
    expect(find.textContaining('Unable to load'), findsNothing);
  });

  testWidgets('Series Recommended tab loads items', (tester) async {
    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(_trexClient());
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });

    await pumpLibraryTab(
      tester,
      provider: provider,
      tab: const LibraryRecommendedTab(library: _trexSeriesLibrary),
    );
    await tester.pumpAndSettle();

    expect(find.text('Alpha Show'), findsWidgets);
    expect(find.textContaining('Unable to load'), findsNothing);
  });

  testWidgets('Series Browse tab loads items', (tester) async {
    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(_trexClient());
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });

    await pumpLibraryTab(
      tester,
      provider: provider,
      tab: const LibraryBrowseTab(library: _trexSeriesLibrary, canGroupByFolders: false),
    );
    await pumpRequestFrames(tester);
    await tester.pumpAndSettle();

    expect(find.text('Alpha Show'), findsWidgets);
    expect(find.textContaining('Unable to load'), findsNothing);
  });

  testWidgets('Live TV picker offers HOME PC and Trex and switches channels', (tester) async {
    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(_FakePlexClient(_FakePlexLiveTv()));
    manager.debugRegisterClientForTesting(_trexClient());
    final provider = testMultiServerProvider(manager);
    provider.debugSetLiveTvServersForTesting([
      LiveTvServerInfo(serverId: 'home-pc', dvrKey: 'plex-dvr', lineup: 'HOME PC - My Guide'),
      LiveTvServerInfo(serverId: 'trex', dvrKey: 'xtream', lineup: null),
    ]);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: ChangeNotifierProvider<MultiServerProvider>.value(
            value: provider,
            child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const LiveTvScreen()),
          ),
        ),
      ),
    );
    // The EPG fetch reads the persisted cache from disk (real dart:io),
    // which never completes inside `testWidgets`' fake async zone on a
    // plain pump — use the real-async settle helper, not pumpAndSettle.
    await pumpLiveTvSettled(tester);

    // The source picker is there with both sources.
    expect(find.text(t.liveTv.allSources), findsOneWidget);
    expect(find.text('HOME PC'), findsWidgets);
    expect(find.text('Trex'), findsWidgets);
    // All sources: both guides' channels render.
    expect(find.text('A&E US Eastern'), findsWidgets);
    expect(find.text('Trex News'), findsWidgets);

    // Pick Trex: only Trex channels remain.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Trex'));
    await pumpLiveTvSettled(tester);
    expect(find.text('Trex News'), findsWidgets);
    expect(find.text('Trex Sports'), findsWidgets);
    expect(find.text('A&E US Eastern'), findsNothing);
    expect(find.text('ABC (KABC) Los Angeles'), findsNothing);

    // Pick HOME PC: only Plex channels remain.
    await tester.tap(find.widgetWithText(ChoiceChip, 'HOME PC'));
    await pumpLiveTvSettled(tester);
    expect(find.text('A&E US Eastern'), findsWidgets);
    expect(find.text('ABC (KABC) Los Angeles'), findsWidgets);
    expect(find.text('Trex News'), findsNothing);
    expect(find.text('Trex Sports'), findsNothing);
  });

  testWidgets('IPTV settings screen renders the Trex connection', (tester) async {
    CredentialVault.resetKeyForTesting();
    await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final registry = _FakeConnectionRegistry(db);
    await registry.upsert(_trexConnection());

    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(_trexClient());
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });

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

    expect(find.text('Trex'), findsWidgets);
    expect(find.textContaining('Xtream Codes'), findsWidgets);
    expect(find.text(t.iptv.refreshPlaylists), findsOneWidget);
  });

  testWidgets('manual refresh that fails every type says the sync failed, not "Catalog synced" (v1.0.10)', (tester) async {
    // Matt, 2026-11-11: manual Refresh playlists with the panel timing
    // out showed Live/Movies/Series "failed" and "Catalog synced"
    // underneath. Per-type failures land in the sync result's skipped
    // map, not as a throw, so the dialog used to report success whenever
    // the sync itself returned.
    CredentialVault.resetKeyForTesting();
    await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final registry = _FakeConnectionRegistry(db);
    await registry.upsert(_trexConnection());

    // The sync needs a real search index on disk, or it short-circuits
    // to all-'failed' without ever calling the panel — point it at a
    // temp dir so the per-type fetch path actually runs. The file-level
    // setUp switches the disk cache off for every test (its real dart:io
    // never completes in fake async); this test re-enables it, because
    // without the index the sync never reaches the fetch that must fail.
    // The sync fails at the fetch, before any disk-cache write, and the
    // index open itself is yielded to via runAsync below.
    IptvCatalogDiskCache.debugDisableDisk = false;
    final tempDir = (await tester.runAsync<Directory>(
      () => Directory.systemTemp.createTemp('plezy_sync_dialog_test_'),
    ))!;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    addTearDown(() async {
      IptvSearchIndex.debugDirectoryProvider = null;
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    final api = _FakeXtreamApi()..failCatalogs = true;
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    client.testItemFavoritesRepository = _InMemoryItemFavoritesRepository();

    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(client);
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });

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

    // The sync dialog opens from the "Sync catalog now" row (the
    // "Refresh playlists" row only clears the playlist cache + EPG and
    // shows a snackbar — tapping it instead silently tests nothing).
    // The row sits in the Playlist section, below the fold on the test
    // viewport — scroll it into view first, then tap (the #20 lesson:
    // a tap right after scrollUntilVisible reads a stale centre).
    await tester.scrollUntilVisible(find.text(t.iptv.catalogSyncNow), 200);
    await tester.pump();
    await tester.tap(find.text(t.iptv.catalogSyncNow));
    await tester.pump();

    // The sync runs real sqlite + panel work on the real event loop —
    // yield to it, then pump, until the dialog reports the outcome.
    for (var i = 0; i < 40 && find.text(t.iptv.catalogSyncFailed).evaluate().isEmpty; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    }
    expect(find.text(t.iptv.catalogSyncFailed), findsOneWidget);
    expect(find.text(t.iptv.catalogSyncDone), findsNothing);
    expect(find.text('failed'), findsWidgets);
  });

  testWidgets('Last search shows while the series probe is still running', (tester) async {
    CredentialVault.resetKeyForTesting();
    await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final registry = _FakeConnectionRegistry(db);
    await registry.upsert(_trexConnection());

    // Build the bound client by hand (same fake as _trexClient) so the
    // test can hang the probe on the SAME api the search ran against.
    final api = _FakeXtreamApi();
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    client.testItemFavoritesRepository = _InMemoryItemFavoritesRepository();

    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(client);
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });

    // Run a search first, so the bound client has a last-search record.
    await tester.runAsync(() => client.searchItems('Alpha Show'));
    expect(client.lastSearchDiagnostics, isNotNull);

    // Now hang the probe: the diagnostics section's series check never
    // lands (build #14, UI-2 — the row used to wait on it).
    api.hangUnfilteredSeries = true;

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

    // Expand the diagnostics section (lazy sliver list: scroll it into
    // view first). One pump after the tap: the probe is still spinning.
    await tester.scrollUntilVisible(find.text(t.iptv.catalogDiagnosticsTitle), 200);
    await tester.tap(find.text(t.iptv.catalogDiagnosticsTitle));
    await tester.pump();

    // The Last search readout renders synchronously from the in-memory
    // getter — visible now, while the probe is still spinning. (The
    // record stores the query lower-cased, as searched.)
    expect(find.text(t.iptv.lastSearchTitle), findsOneWidget);
    expect(find.textContaining('alpha show'), findsWidgets);
    expect(find.text(t.iptv.catalogDiagnosticsLoading), findsOneWidget);

    // Let the probe's 10s timeouts fire so no fake-async timer is left
    // pending at teardown (the hanging getSeries never answers on its own).
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
  });

  testWidgets('IPTV settings screen renders the EPG section and its actions work', (tester) async {
    CredentialVault.resetKeyForTesting();
    await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final registry = _FakeConnectionRegistry(db);
    await registry.upsert(_trexConnection());

    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(_trexClient());
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });

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

    // The EPG / TV guide section (TiviMate model) with its defaults. The
    // screen is a lazy sliver list, so scroll each row into view first.
    await tester.scrollUntilVisible(find.text(t.iptv.epgSection), 200);
    expect(find.text(t.iptv.epgSection), findsOneWidget);
    expect(find.text(t.iptv.epgDaysToLoad), findsOneWidget);
    expect(find.text('3 days'), findsOneWidget);
    expect(find.text(t.iptv.epgUpdateInterval), findsOneWidget);
    expect(find.text('Every 24 hours'), findsOneWidget);
    expect(find.text(t.iptv.epgPastDays), findsOneWidget);
    expect(find.text('1 day'), findsOneWidget);
    expect(find.text(t.iptv.epgUpdateOnStart), findsOneWidget);
    expect(find.text(t.iptv.epgTimeOffset), findsOneWidget);
    expect(find.text('No offset'), findsOneWidget);
    await tester.scrollUntilVisible(find.text(t.iptv.epgUpdateNow), 200);
    expect(find.text(t.iptv.epgUpdateNow), findsOneWidget);
    await tester.scrollUntilVisible(find.text(t.iptv.epgClearGuide), 200);
    expect(find.text(t.iptv.epgClearGuide), findsOneWidget);
    await tester.scrollUntilVisible(find.text(t.iptv.epgLastUpdated), 200);
    expect(find.text(t.iptv.epgLastUpdated), findsOneWidget);
    expect(find.text(t.iptv.epgNeverUpdated), findsOneWidget);

    // Update now + Clear guide announce themselves.
    await tester.ensureVisible(find.text(t.iptv.epgUpdateNow));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.iptv.epgUpdateNow));
    await tester.pumpAndSettle();
    expect(find.text(t.iptv.epgUpdated), findsOneWidget);
    await tester.ensureVisible(find.text(t.iptv.epgClearGuide));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.iptv.epgClearGuide));
    // The "Guide updated" snackbar is still showing; the "Guide cleared"
    // one queues behind it — let the first expire before asserting.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text(t.iptv.epgCleared), findsOneWidget);
  });

  group('First-run IPTV onboarding', () {
    testWidgets('Auth screen offers M3U and Xtream Codes and opens their add screens', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: const AuthScreen(initializeServices: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // IPTV sits alongside Plex / Jellyfin / Emby on first start — not
      // buried behind a Plex sign-in.
      expect(find.text(t.auth.signInWithPlex), findsWidgets);
      expect(find.text(t.addServer.connectToM3uCard), findsOneWidget);
      expect(find.text(t.addServer.connectToXtreamCard), findsOneWidget);

      // Tapping Xtream opens its add form (name + server + username + password).
      await tester.tap(find.text(t.addServer.connectToXtreamCard));
      await tester.pumpAndSettle();
      expect(find.text(t.addServer.addXtreamTitle), findsOneWidget);
      expect(find.text(t.addServer.serverUrl), findsOneWidget);
      expect(find.text(t.addServer.username), findsOneWidget);
      expect(find.text(t.addServer.password), findsOneWidget);

      // Back out, then M3U opens its add form (name + playlist URL).
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.addServer.connectToM3uCard));
      await tester.pumpAndSettle();
      expect(find.text(t.addServer.addM3uTitle), findsOneWidget);
      expect(find.text(t.addServer.playlistUrl), findsOneWidget);
    });
  });

  group('PlezTV rename + About changelog', () {
    test('English strings call the app PlezTV and carry the changelog', () async {
      final strings = await AppLocale.en.build();
      expect(strings.app.title, 'PlezTV');
      expect(strings.about.changelogTitle, "What's new");
      expect(strings.about.changelog2251, hasLength(9));
      expect(strings.about.changelog2251, contains('Blue app icon'));
      expect(strings.about.changelog2251, contains('Movies and Series Recommended now loads'));
      expect(strings.about.changelog2250, hasLength(4));
      expect(strings.about.changelog2250.first, contains('First PlezTV release'));
    });

    testWidgets('About screen shows PlezTV and the changelog, newest first', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const AboutScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('PlezTV'), findsWidgets);
      expect(find.text("What's new"), findsOneWidget);
      expect(find.text('Version 2.25.1'), findsOneWidget);
      expect(find.text('Version 2.25.0'), findsOneWidget);
      expect(find.text('Blue app icon'), findsOneWidget);
      // Newest first: the 2.25.1 heading sits above the 2.25.0 heading.
      final first = tester.getTopLeft(find.text('Version 2.25.1')).dy;
      final second = tester.getTopLeft(find.text('Version 2.25.0')).dy;
      expect(first, lessThan(second));
      // Build #28: every shipped version has a changelog entry — the
      // 1.0.9 entry was missing and nothing caught it. The newest entry
      // sits above the previous one.
      expect(find.text('Version 1.0.9-2.25.0'), findsOneWidget);
      expect(find.text('Version 1.0.8-2.25.0'), findsOneWidget);
      final newest = tester.getTopLeft(find.text('Version 1.0.9-2.25.0')).dy;
      final previous = tester.getTopLeft(find.text('Version 1.0.8-2.25.0')).dy;
      expect(newest, lessThan(previous));
      // R2 (v1.0.11): same guard for the new version — it must be present
      // and sit above 1.0.10.
      expect(find.text('Version 1.0.11-2.25.0'), findsOneWidget);
      expect(find.text('Version 1.0.10-2.25.0'), findsOneWidget);
      final newest11 = tester.getTopLeft(find.text('Version 1.0.11-2.25.0')).dy;
      final previous10 = tester.getTopLeft(find.text('Version 1.0.10-2.25.0')).dy;
      expect(newest11, lessThan(previous10));
      // R5 (v1.0.12): same guard for the new version — it must be present
      // and sit above 1.0.11.
      expect(find.text('Version 1.0.12-2.25.0'), findsOneWidget);
      final newest12 = tester.getTopLeft(find.text('Version 1.0.12-2.25.0')).dy;
      expect(newest12, lessThan(newest11));
    });
  });
}
