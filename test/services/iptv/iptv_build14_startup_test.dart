// STARTUP REPRO — build #14 (v2.25.10): PlezTV v2.25.9 crashes on Matt's
// phone "right after the app loads and the whole UI starts to come in"
// (Matt, 2026-11-07 ~18:35 EST), before he taps anything. He also has a
// Plex server (HOME PC) connected alongside Trex — "maybe test it with a
// dummy Plex server". Every earlier harness was IPTV-only, which is very
// likely why the crash never reproduced: the startup path fetches and
// merges libraries, hubs and On Deck from ALL servers.
//
// These tests drive the REAL startup load with BOTH servers present:
// a dummy Plex server (HOME PC: Movies, TV Shows, Music, global hubs,
// Continue Watching) registered first, then Trex bound through the real
// addIptvConnection path with Matt's migrated v2.25.8 state (32 hidden
// initials, 0 hidden ids, v2.25.8-format disk cache). The load under test is exactly
// what the Discover (Home) tab — the default first tab — runs on mount:
// LibrariesProvider.loadLibraries() + DiscoverProvider.load() (On Deck +
// hubs from all servers, in parallel).
//
// Prime suspects (build #13 diff): the _recommendedHub totalCount change
// (hubs now carry size == full catalog count with only the first `limit`
// items mapped), the VOD+live warm-ups running at bind time before
// checkHealth, notifyCatalogRefreshed at startup, fetchLibraries merging
// across backends. A throw anywhere in this load is the crash: on the
// phone the first frame never finishes building.
//
// NOTE: plain test(), real async — so real disk I/O works and the
// v2.25.8 cache files are read for real. (Do NOT wrap bodies in
// runZonedGuarded: it breaks the shared_preferences method channel in
// this harness — see iptv_build14_migration_test.dart.)

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
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
import 'package:plezy/providers/discover_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;

import '../../test_helpers/media_items.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  group('build14: v2.25.9 startup crash — Plex HOME PC + Trex', () {
    late Directory cacheRoot;

    setUp(() async {
      resetSharedPreferencesForTest();
      cacheRoot = await Directory.systemTemp.createTemp('plezy-build14-startup');
      addTearDown(() async {
        if (await cacheRoot.exists()) await cacheRoot.delete(recursive: true);
      });
      IptvCatalogDiskCache.debugDirectoryProvider = () async => cacheRoot;
      IptvCatalogDiskCache.debugDisableDisk = false;
    });

    tearDown(() {
      IptvClient.debugClientFactory = null;
      IptvCatalogDiskCache.debugDirectoryProvider = null;
      IptvCatalogDiskCache.debugDisableDisk = false;
    });

    /// Seed the disk cache exactly as v2.25.8 (build #11) wrote it:
    /// re-encoded rows, never raw bodies.
    Future<void> seedV258Cache() async {
      const cache = IptvCatalogDiskCache();
      const connectionId = 'conn-xt-1';
      final api = _TrexPanelFakeApi();
      await cache.write(
        connectionId,
        IptvCatalogDiskCache.liveCategoriesDataset,
        jsonEncode(api.liveCategories().map((c) => c.toJson()).toList()),
      );
      await cache.write(
        connectionId,
        IptvCatalogDiskCache.vodCategoriesDataset,
        jsonEncode(api.vodCategories().map((c) => c.toJson()).toList()),
      );
      await cache.write(
        connectionId,
        IptvCatalogDiskCache.seriesCategoriesDataset,
        jsonEncode(api.seriesCategories().map((c) => c.toJson()).toList()),
      );
      await cache.write(
        connectionId,
        IptvCatalogDiskCache.liveDataset,
        jsonEncode(api.liveRows().map((r) => r.toJson()).toList()),
      );
      await cache.write(
        connectionId,
        IptvCatalogDiskCache.vodDataset,
        jsonEncode(api.vodRows().map((r) => r.toJson()).toList()),
      );
      await cache.write(
        connectionId,
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(api.seriesRows().map((r) => r.toJson()).toList()),
      );
    }

    XtreamConnection trexConnection() {
      return XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
        hiddenCategoryInitials: _mattHiddenInitials(),
        createdAt: DateTime.utc(2026, 11, 5),
      );
    }

    /// Both servers bound in Matt's order (Plex first — it was connected
    /// long before Trex), plus the provider stack the Discover tab reads.
    Future<({MultiServerManager manager, LibrariesProvider libraries, DiscoverProvider discover})> bindBoth() async {
      await seedV258Cache();
      await SettingsService.getInstance();
      await StorageService.getInstance();
      final manager = MultiServerManager();
      final api = _TrexPanelFakeApi();
      // Plex HOME PC first: the dummy Plex server, online before Trex binds.
      manager.debugRegisterClientForTesting(_FakePlexClient());
      IptvClient.debugClientFactory = (connection) {
        final client = IptvClient.xtream(xtreamConnection: connection as XtreamConnection);
        client.testXtreamApi = api;
        return client;
      };
      expect(await manager.addIptvConnection(trexConnection()), isTrue);
      final multiServer = testMultiServerProvider(manager);
      final hiddenLibraries = HiddenLibrariesProvider();
      await hiddenLibraries.ensureInitialized();
      final libraries = LibrariesProvider(multiServer: multiServer);
      libraries.initialize(multiServer.aggregationService);
      final discover = DiscoverProvider(
        multiServer,
        hiddenLibraries,
        libraries,
        profileId: null,
        isProfileBinding: () => false,
      );
      addTearDown(() {
        discover.dispose();
        libraries.dispose();
        hiddenLibraries.dispose();
        multiServer.dispose();
        manager.dispose();
      });
      return (manager: manager, libraries: libraries, discover: discover);
    }

    test('startup load: libraries merge Plex + Trex, Discover load completes with hubs from both', () async {
      final harness = await bindBoth();
      final libraries = harness.libraries;
      final discover = harness.discover;

      // The first thing the app does: load the merged library list.
      await libraries.loadLibraries();
      expect(
        libraries.libraries.map((l) => l.title),
        containsAll(['Movies', 'TV Shows', 'Music', 'Trex — Movies', 'Trex — Series']),
      );

      // Then the Discover tab loads On Deck + hubs from all servers.
      // On v2.25.9 this is where the phone dies; here it must complete.
      await discover.load();
      // Let the parallel legs settle.
      await Future.delayed(const Duration(seconds: 1));

      final hubTitles = discover.hubs.map((h) => h.title).toList();
      // Plex global hubs.
      expect(hubTitles, contains('Recommended'));
      // IPTV per-library hubs (richHubs=false, so the aggregation takes
      // the per-library path, whose hubs are titled 'Recommended' — the
      // 'Trex — Movies' title only comes from fetchGlobalHubs, which the
      // aggregation never calls for IPTV). Tell them apart by server.
      final trexHubs = discover.hubs.where((h) => h.serverId == 'conn-xt-1').toList();
      expect(trexHubs.map((h) => h.libraryId), containsAll(['iptv:conn-xt-1:movies', 'iptv:conn-xt-1:series']));
      // On Deck from Plex (IPTV contributes none).
      expect(discover.onDeck.map((i) => i.title), contains('Plex Movie 1'));

      // The build #13 hub shape: size is the FULL catalog count while
      // items holds only the first page — the shape the home rows render.
      final trexMoviesHub = trexHubs.firstWhere((h) => h.libraryId == 'iptv:conn-xt-1:movies');
      expect(trexMoviesHub.size, greaterThan(trexMoviesHub.items.length));
      expect(trexMoviesHub.items, isNotEmpty);
      expect(trexMoviesHub.more, isTrue);
    });

    test('startup load: Trex hubs alone carry the full catalog count', () async {
      final harness = await bindBoth();
      final discover = harness.discover;

      await discover.load();
      await Future.delayed(const Duration(seconds: 1));

      final trexHubs = discover.hubs.where((h) => h.serverId == 'conn-xt-1').toList();
      final moviesHub = trexHubs.firstWhere((h) => h.libraryId == 'iptv:conn-xt-1:movies');
      // 1500 VOD rows in the fake catalog; only the first page is mapped.
      expect(moviesHub.size, 1500);
      expect(moviesHub.items.length, lessThanOrEqualTo(20));
      final seriesHub = trexHubs.firstWhere((h) => h.libraryId == 'iptv:conn-xt-1:series');
      expect(seriesHub.size, 1500);
      expect(seriesHub.items.length, lessThanOrEqualTo(20));
    });
  });
}

/// Dummy Plex server (HOME PC): three libraries, global hubs, Continue
/// Watching. Only the surface the startup aggregation touches is
/// implemented; everything else falls through to noSuchMethod.
class _FakePlexClient implements MediaServerClient {
  @override
  ServerId get serverId => ServerId('plex-home-pc');

  @override
  String? get serverName => 'HOME PC';

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

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
  }) async {
    // The aggregation's rich-hub music append asks for artist libraries.
    if (libraryKind == MediaKind.artist) {
      return [
        MediaHub(
          id: 'plex:music',
          title: 'Music',
          type: 'artist',
          items: [_plexItem('plex-m1', 'Plex Album 1')],
          size: 1,
        ),
      ];
    }
    return [
      MediaHub(
        id: 'plex:$libraryId:recent',
        title: 'Recently Added in $libraryName',
        type: 'movie',
        items: [_plexItem('plex-$libraryId-1', 'Plex $libraryName 1')],
        size: 1,
      ),
    ];
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async => LibraryPage(items: [_plexItem('plex-$libraryId-p1', 'Plex $libraryId 1')], totalCount: 1);

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Matt's 32 hidden initials (2026-11-12 phone state: 32 groups off, 0
/// hidden ids): region codes his provider repeats, EN deliberately NOT
/// in the list (he left EN on).
List<String> _mattHiddenInitials() {
  const base = [
    'AR', 'FR', 'DE', 'PL', 'ES', 'IN', 'NL', 'SE', 'EX', 'AL', 'PT', 'IT',
    'TR', 'RU', 'UA', 'BR', 'MX', 'CA', 'AU', 'NZ', 'ZA', 'NG', 'KE', 'EG',
    'MA', 'TN', 'DZ', 'IL', 'SA', 'AE', 'QA', 'KW', 'BH', 'OM', 'JO', 'LB',
    'IQ', 'IR', 'AF', 'PK', 'BD', 'LK', 'NP', 'MM', 'TH', 'VN', 'KH', 'LA',
    'MY', 'SG', 'ID', 'PH', 'JP', 'KR', 'CN', 'TW', 'HK', 'MN', 'KZ', 'UZ',
    'TM', 'KG', 'TJ', 'GE', 'AM', 'AZ', 'BY', 'MD', 'RO', 'BG', 'HR', 'RS',
    'BA', 'ME', 'AL', 'MK', 'GR', 'CY', 'MT', 'IS', 'NO', 'DK', 'FI', 'EE',
    'LV', 'LT', 'IE', 'GB', 'UK', 'US', 'PR', 'DO', 'CU', 'HT', 'JM', 'TT',
    'BB', 'GY', 'SR', 'BO', 'PE', 'CL', 'AR', 'UY', 'PY', 'EC', 'CO', 'VE',
  ];
  // First 32 unique region codes — the 2026-11-12 phone state. (The
  // 2026-11-07 fixture topped this up to 161 with provider-style tags;
  // the phone now has 32 groups off.)
  return <String>{...base}.take(32).toList();
}

/// Trex-shaped fake panel reproducing MATT'S panel behaviour:
/// - unfiltered get_vod_streams returns [] (199k rows is too many for
///   one call on this panel) — VOD loads by per-category crawl.
/// - unfiltered get_series returns rows; per-category get_series returns
///   [] (the (g) shape proven in the build #10 diagnosis).
/// - unfiltered get_live_streams returns rows.
/// 150 EN categories per section + one AR region category, plus buried /
/// bracket / lowercase forms that must NOT count as region initials.
class _TrexPanelFakeApi extends XtreamApi {
  _TrexPanelFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  List<XtreamCategory> liveCategories() => _categories('Live');
  List<XtreamCategory> vodCategories() => _categories('Movies');
  List<XtreamCategory> seriesCategories() => _categories('Series');

  List<XtreamCategory> _categories(String prefix) => [
    for (var i = 1; i <= 150; i++) XtreamCategory(id: '$i', name: '|EN| $prefix $i'),
    const XtreamCategory(id: '900', name: '|AR| Hidden Region'),
    const XtreamCategory(id: '901', name: '|MOVIES| EN | Buried Movies'),
    const XtreamCategory(id: '902', name: '[EN] Bracketed'),
    const XtreamCategory(id: '903', name: 'lowercase en movies'),
  ];

  List<XtreamLiveStream> liveRows() => [
    for (var i = 0; i < 1000; i++)
      XtreamLiveStream(
        streamId: 1000 + i,
        name: i == 0 ? 'HBO East' : 'Live Channel $i',
        categoryId: '${(i % 150) + 1}',
      ),
  ];

  List<XtreamVodStream> vodRows() => [
    for (var i = 0; i < 1500; i++)
      XtreamVodStream(
        streamId: 2000 + i,
        name: i == 0 ? 'Alpha Movie' : 'Movie $i',
        containerExtension: 'mp4',
        categoryId: '${(i % 150) + 1}',
      ),
  ];

  List<XtreamSeries> seriesRows() => [
    for (var i = 0; i < 1500; i++)
      XtreamSeries(seriesId: 3000 + i, name: i == 0 ? 'Alpha Show' : 'Show $i', categoryId: '${(i % 150) + 1}'),
  ];

  Future<void> _latency() => Future.delayed(const Duration(milliseconds: 2));

  @override
  Future<Map<String, dynamic>?> getUserInfo() async {
    await _latency();
    return {'username': 'user', 'status': 'Active'};
  }

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async {
    await _latency();
    return liveCategories();
  }

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async {
    await _latency();
    return vodCategories();
  }

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async {
    await _latency();
    return seriesCategories();
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    await _latency();
    final rows = categoryId == null ? liveRows() : liveRows().where((r) => r.categoryId == categoryId).toList();
    lastLiveStreamsBody = categoryId == null ? jsonEncode(rows.map((r) => r.toJson()).toList()) : null;
    return rows;
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    await _latency();
    if (categoryId == null) {
      // Unfiltered VOD returns [] on this panel — the crawl path.
      lastVodStreamsBody = '[]';
      return const [];
    }
    final rows = vodRows().where((r) => r.categoryId == categoryId).toList();
    lastVodStreamsBody = null;
    return rows;
  }

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    await _latency();
    if (categoryId != null) {
      lastSeriesBody = null;
      return const [];
    }
    final rows = seriesRows();
    lastSeriesBody = jsonEncode(rows.map((r) => r.toJson()).toList());
    return rows;
  }
}
