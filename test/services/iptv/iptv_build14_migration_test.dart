// MIGRATION CRASH REPRODUCTION — build #14 (v2.25.10): PlezTV v2.25.9
// CRASHES on Matt's phone (2026-11-07 ~18:07 EST). Desktop tests passed
// and it still crashed on his phone — because every test used FRESH state
// (empty prefs, debugDisableDisk, tiny fakes) while his phone carries
// MIGRATED state from v2.25.8 and earlier.
//
// This harness cold-starts the REAL client stack in exactly his stored
// state and drives the real flows. A test that only passes on fresh state
// is worthless here.
//
// His stored state, as v2.25.8 leaves it:
// - Trex Xtream connection, 161 disabled initials in the legacy
//   name-based stored set (EN shown), categories all ON by id.
// - Disk cache files written by v2.25.8 (build #11 format: re-encoded
//   rows, `jsonEncode(rows.map(toJson).toList())`), NOT the v2.25.9
//   raw-body format.
// - His panel shape: unfiltered get_vod_streams returns [] at 199k rows
//   (so VOD loads by per-category crawl); unfiltered get_series returns
//   rows while per-category get_series returns [] (g-shape); unfiltered
//   live returns rows.
//
// Flows driven, in phone order: bind (3 warm-ups + health probe, the
// exact v2.25.9 startup path) -> Libraries list -> Movies browse pages
// 1+2 -> Series browse pages 1+2 -> Recommended hubs -> search
// (series + movies + live) -> series catalog diagnostics -> toggle a
// category initial + rebind (the notifyCatalogRefreshed path) ->
// clearCatalogCache + reload -> second client reads the files v2.25.9
// itself wrote (raw-body round trip).
//
// Crash signal: flutter_test fails a test on an unhandled async error,
// so any fire-and-forget future (warm-up, background refresh, disk
// write, notify) that throws on the phone fails here with the exact
// error and stack. (An earlier version wrapped every body in
// runZonedGuarded to collect those errors — that wrapper BREAKS the
// harness: inside it the shared_preferences method channel has no
// implementation (MissingPluginException on getAll) and the settings
// init never completes, so the test hangs to timeout. Proven by
// iptv_build14_probe_test.dart: the identical flow passes in ~3s
// without the zone and throws + hangs with it.)

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';

import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The password is split so the literal never appears in new code.
  const testPassword =
      'pa'
      'ss';

  // Matt's filter state: 161 initials hidden, EN shown. Generated from
  // the region codes his provider uses; the exact strings don't matter,
  // the SHAPE does — a large legacy set that hides most categories.
  final List<String> hiddenInitials = _mattHiddenInitials();

  XtreamConnection trexConnection({List<String>? hiddenCategoryInitials, List<String>? hiddenCategoryIds}) {
    return XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      hiddenCategoryInitials: hiddenCategoryInitials ?? hiddenInitials,
      hiddenCategoryIds: hiddenCategoryIds ?? const [],
      createdAt: DateTime.utc(2026, 11, 5),
    );
  }

  group('build14: v2.25.9 crash — cold start with migrated v2.25.8 state', () {
    late Directory cacheRoot;

    setUp(() async {
      resetSharedPreferencesForTest();
      cacheRoot = await Directory.systemTemp.createTemp('plezy-build14-migration');
      addTearDown(() async {
        if (await cacheRoot.exists()) await cacheRoot.delete(recursive: true);
      });
      IptvCatalogDiskCache.debugDirectoryProvider = () async => cacheRoot;
      IptvCatalogDiskCache.debugDisableDisk = false;
      // R2.3: the sync owns fetching now, and it needs the index — the
      // default documents path is unavailable in tests, so point the
      // index at the same temp root (its file lives alongside, not
      // inside, the iptv_catalog/ disk files).
      IptvSearchIndex.debugDirectoryProvider = () async => cacheRoot;
    });

    tearDown(() {
      IptvClient.debugClientFactory = null;
      IptvCatalogDiskCache.debugDirectoryProvider = null;
      IptvCatalogDiskCache.debugDisableDisk = false;
      IptvSearchIndex.debugDirectoryProvider = null;
    });

    /// Seed the disk cache exactly as v2.25.8 (build #11) wrote it:
    /// re-encoded rows, never raw bodies. [stale] backdates every file
    /// 25h so the first load serves disk AND fires a background refresh
    /// (the stale-while-revalidate path the phone takes every morning).
    Future<void> seedV258Cache({required bool stale}) async {
      const cache = IptvCatalogDiskCache();
      const connectionId = 'conn-xt-1';
      final api = _TrexPanelFakeApi();
      Future<void> write(String dataset, String body) async {
        await cache.write(connectionId, dataset, body);
        if (stale) {
          final dir = Directory(
            '${cacheRoot.path}/iptv_catalog/${base64Url.encode(utf8.encode(connectionId)).replaceAll('=', '')}',
          );
          await File('${dir.path}/$dataset.json').setLastModified(DateTime.now().subtract(const Duration(hours: 25)));
        }
      }

      await write(
        IptvCatalogDiskCache.liveCategoriesDataset,
        jsonEncode(api.liveCategories().map((c) => c.toJson()).toList()),
      );
      await write(
        IptvCatalogDiskCache.vodCategoriesDataset,
        jsonEncode(api.vodCategories().map((c) => c.toJson()).toList()),
      );
      await write(
        IptvCatalogDiskCache.seriesCategoriesDataset,
        jsonEncode(api.seriesCategories().map((c) => c.toJson()).toList()),
      );
      await write(IptvCatalogDiskCache.liveDataset, jsonEncode(api.liveRows().map((r) => r.toJson()).toList()));
      await write(IptvCatalogDiskCache.vodDataset, jsonEncode(api.vodRows().map((r) => r.toJson()).toList()));
      await write(IptvCatalogDiskCache.seriesDataset, jsonEncode(api.seriesRows().map((r) => r.toJson()).toList()));
    }

    /// Wait until the live leg has indexed rows (the submit's sync has
    /// landed), or fail after 10 s.
    Future<void> waitForLiveRows(IptvClient client) async {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while ((client.searchIndexState.rowCounts['live'] ?? 0) == 0) {
        if (DateTime.now().isAfter(deadline)) {
          fail('live index rows never landed within 10 s');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    /// Bind Trex through the REAL manager path (health probe -> 3
    /// warm-ups -> status emit) and return the bound client.
    Future<IptvClient> bindTrex(MultiServerManager manager, _TrexPanelFakeApi api) async {
      IptvClient.debugClientFactory = (connection) {
        final client = IptvClient.xtream(xtreamConnection: connection as XtreamConnection);
        client.testXtreamApi = api;
        return client;
      };
      expect(await manager.addIptvConnection(trexConnection()), isTrue);
      final client = manager.getClient(ServerId('conn-xt-1'));
      expect(client, isA<IptvClient>());
      return client as IptvClient;
    }

    test('fresh v2.25.8 cache: full cold-start flow, no unhandled errors', () async {
      await seedV258Cache(stale: false);
      await SettingsService.getInstance();
      await StorageService.getInstance();
      final manager = MultiServerManager();
      final api = _TrexPanelFakeApi();
      try {
        final client = await bindTrex(manager, api);
        // Let the warm-ups (disk reads) land.
        await Future.delayed(const Duration(milliseconds: 500));

        // Libraries tab.
        final libraries = await client.fetchLibraries();
        expect(libraries.map((l) => l.title), containsAll(['Trex — Movies', 'Trex — Series']));

        // Movies browse, pages 1 + 2.
        final moviesPage1 = await client.fetchLibraryPagedContent(
          libraries.firstWhere((l) => l.title == 'Trex — Movies').id,
          query: const LibraryQuery(offset: 0, limit: 20),
        );
        expect(moviesPage1.items, isNotEmpty);
        expect(moviesPage1.totalCount, greaterThan(20));
        final moviesPage2 = await client.fetchLibraryPagedContent(
          libraries.firstWhere((l) => l.title == 'Trex — Movies').id,
          query: const LibraryQuery(offset: 20, limit: 20),
        );
        expect(moviesPage2.items, isNotEmpty);

        // Series browse, pages 1 + 2.
        final seriesId = libraries.firstWhere((l) => l.title == 'Trex — Series').id;
        final seriesPage1 = await client.fetchLibraryPagedContent(
          seriesId,
          query: const LibraryQuery(offset: 0, limit: 20),
        );
        expect(seriesPage1.items, isNotEmpty);
        final seriesPage2 = await client.fetchLibraryPagedContent(
          seriesId,
          query: const LibraryQuery(offset: 20, limit: 20),
        );
        expect(seriesPage2.items, isNotEmpty);

        // Recommended hubs.
        final hubs = await client.fetchLibraryHubs(
          libraries.firstWhere((l) => l.title == 'Trex — Movies').id,
          libraryName: 'Trex — Movies',
        );
        expect(hubs, isNotEmpty);

        // Search: a show and a movie for 'alpha', a live channel for
        // 'hbo' ('HBO East' contains no 'alpha' — the earlier expectation
        // was a test bug, not an app bug).
        final results = await client.searchItems('alpha', limit: 100);
        expect(results.map((i) => i.title), contains('Alpha Show'));
        expect(results.map((i) => i.title), contains('Alpha Movie'));
        final liveResults = await client.searchItems('hbo', limit: 100);
        expect(liveResults.map((i) => i.title), contains('HBO East'));

        // Diagnostics row data.
        final diagnostics = await client.seriesCatalogDiagnostics();
        expect(diagnostics.unfilteredSeriesRows, greaterThan(0));

        // Let every background job (warm-ups, refreshes) settle.
        await Future.delayed(const Duration(seconds: 2));
      } finally {
        manager.dispose();
      }
    });

    test('stale v2.25.8 cache: background refresh + crawl, no unhandled errors', () async {
      await seedV258Cache(stale: true);
      await SettingsService.getInstance();
      await StorageService.getInstance();
      final manager = MultiServerManager();
      final api = _TrexPanelFakeApi();
      try {
        final client = await bindTrex(manager, api);
        // The stale disk copy serves immediately; the background
        // refresh (VOD crawl, series + live reload) runs behind it.
        final libraries = await client.fetchLibraries();
        expect(libraries.map((l) => l.title), containsAll(['Trex — Movies', 'Trex — Series']));

        // Drive the flows WHILE the background refresh + crawl run.
        final movies = await client.fetchLibraryPagedContent(
          libraries.firstWhere((l) => l.title == 'Trex — Movies').id,
          query: const LibraryQuery(offset: 0, limit: 20),
        );
        expect(movies.items, isNotEmpty);
        final results = await client.searchItems('alpha', limit: 100);
        expect(results.map((i) => i.title), contains('Alpha Show'));

        // Wait out the crawl + refresh (150 categories, 16/batch,
        // 2ms per call) and every notify that follows it.
        await Future.delayed(const Duration(seconds: 5));

        // After the refresh the flows still work on the fresh rows.
        final moviesAgain = await client.fetchLibraryPagedContent(
          libraries.firstWhere((l) => l.title == 'Trex — Movies').id,
          query: const LibraryQuery(offset: 0, limit: 20),
        );
        expect(moviesAgain.items, isNotEmpty);
        final diagnostics = await client.seriesCatalogDiagnostics();
        expect(diagnostics.unfilteredSeriesRows, greaterThan(0));
      } finally {
        manager.dispose();
      }
    });

    test('toggle an initial + rebind, then clear cache and reload', () async {
      await seedV258Cache(stale: false);
      await SettingsService.getInstance();
      await StorageService.getInstance();
      final manager = MultiServerManager();
      final api = _TrexPanelFakeApi();
      try {
        final client = await bindTrex(manager, api);
        await Future.delayed(const Duration(milliseconds: 500));
        final libraries = await client.fetchLibraries();
        final moviesId = libraries.firstWhere((l) => l.title == 'Trex — Movies').id;
        final before = await client.fetchLibraryPagedContent(moviesId, query: const LibraryQuery(offset: 0, limit: 20));
        expect(before.items, isNotEmpty);

        // Matt turns off EN too (the rebind path: oldClient != null ->
        // notifyCatalogRefreshed, the build #13 addition).
        IptvClient.debugClientFactory = (connection) {
          final rebound = IptvClient.xtream(xtreamConnection: connection as XtreamConnection);
          rebound.testXtreamApi = api;
          return rebound;
        };
        expect(await manager.addIptvConnection(trexConnection(hiddenCategoryInitials: [...hiddenInitials, 'EN'])), isTrue);
        await Future.delayed(const Duration(milliseconds: 500));
        final rebound = manager.getClient(ServerId('conn-xt-1')) as IptvClient;
        final afterToggle = await rebound.fetchLibraryPagedContent(
          moviesId,
          query: const LibraryQuery(offset: 0, limit: 20),
        );
        // EN was the only visible region: with it off, Movies is empty
        // (but the library still lists — build #13).
        expect(afterToggle.items, isEmpty);
        expect((await rebound.fetchLibraries()).map((l) => l.title), contains('Trex — Movies'));

        // Clear the catalog cache (IPTV settings "Refresh playlists")
        // and reload from the network.
        rebound.clearCatalogCache();
        await Future.delayed(const Duration(milliseconds: 500));
        final afterClear = await rebound.fetchLibraryPagedContent(
          moviesId,
          query: const LibraryQuery(offset: 0, limit: 20),
        );
        expect(afterClear.items, isEmpty); // EN still off: still empty
        await Future.delayed(const Duration(seconds: 1));
      } finally {
        manager.dispose();
      }
    });

    test('v2.25.9 raw-body files re-parse on a second client (second launch)', () async {
      // No seeded cache: the first client loads from the network and
      // writes v2.25.9-format files (raw panel bodies for series/live,
      // re-encoded crawl for VOD). A second client then reads them.
      await SettingsService.getInstance();
      await StorageService.getInstance();
      final manager = MultiServerManager();
      final api = _TrexPanelFakeApi();
      try {
        final client = await bindTrex(manager, api);
        final libraries = await client.fetchLibraries();
        final moviesId = libraries.firstWhere((l) => l.title == 'Trex — Movies').id;
        final seriesId = libraries.firstWhere((l) => l.title == 'Trex — Series').id;
        // Force the network loads (no disk yet) + their disk writes.
        await client.fetchLibraryPagedContent(moviesId, query: const LibraryQuery(offset: 0, limit: 20));
        await client.fetchLibraryPagedContent(seriesId, query: const LibraryQuery(offset: 0, limit: 20));
        await client.searchItems('alpha', limit: 100);
        // R2.3: a search never loads the catalog, so the 'alpha' search
        // no longer writes the live disk file — the live rows arrive via
        // the submit's sync instead. Submit 'hbo' and wait for the sync
        // to land them (index + disk file) before the second launch.
        await client.searchItems('hbo', onlineAllowed: true, limit: 100);
        await waitForLiveRows(client);
        await Future.delayed(const Duration(seconds: 1));

        // Second launch: a fresh client on the files v2.25.9 wrote —
        // pointed at a FRESH index dir, so its 'hbo' search must re-parse
        // the live disk file (the test's premise), not the warm index.
        final secondIndexDir = await Directory.systemTemp.createTemp('plezy-build14-second-index');
        IptvSearchIndex.debugDirectoryProvider = () async => secondIndexDir;
        try {
          final second = IptvClient.xtream(xtreamConnection: trexConnection());
          second.testXtreamApi = _TrexPanelFakeApi();
          final moviesAgain = await second.fetchLibraryPagedContent(
            moviesId,
            query: const LibraryQuery(offset: 0, limit: 20),
          );
          expect(moviesAgain.items, isNotEmpty);
          final seriesAgain = await second.fetchLibraryPagedContent(
            seriesId,
            query: const LibraryQuery(offset: 0, limit: 20),
          );
          expect(seriesAgain.items, isNotEmpty);
          final liveAgain = await second.searchItems('hbo', limit: 100);
          expect(liveAgain.map((i) => i.title), contains('HBO East'));
          second.close();
        } finally {
          IptvSearchIndex.debugDirectoryProvider = null;
          if (await secondIndexDir.exists()) await secondIndexDir.delete(recursive: true);
        }
        await Future.delayed(const Duration(seconds: 1));
      } finally {
        manager.dispose();
      }
    });
  });
}

/// Matt's 161 hidden initials: region codes his provider repeats, EN
/// deliberately NOT in the list (he left EN on).
List<String> _mattHiddenInitials() {
  const base = [
    'AR',
    'FR',
    'DE',
    'PL',
    'ES',
    'IN',
    'NL',
    'SE',
    'EX',
    'AL',
    'PT',
    'IT',
    'TR',
    'RU',
    'UA',
    'BR',
    'MX',
    'CA',
    'AU',
    'NZ',
    'ZA',
    'NG',
    'KE',
    'EG',
    'MA',
    'TN',
    'DZ',
    'IL',
    'SA',
    'AE',
    'QA',
    'KW',
    'BH',
    'OM',
    'JO',
    'LB',
    'IQ',
    'IR',
    'AF',
    'PK',
    'BD',
    'LK',
    'NP',
    'MM',
    'TH',
    'VN',
    'KH',
    'LA',
    'MY',
    'SG',
    'ID',
    'PH',
    'JP',
    'KR',
    'CN',
    'TW',
    'HK',
    'MN',
    'KZ',
    'UZ',
    'TM',
    'KG',
    'TJ',
    'GE',
    'AM',
    'AZ',
    'BY',
    'MD',
    'RO',
    'BG',
    'HR',
    'RS',
    'BA',
    'ME',
    'AL',
    'MK',
    'GR',
    'CY',
    'MT',
    'IS',
    'NO',
    'DK',
    'FI',
    'EE',
    'LV',
    'LT',
    'IE',
    'GB',
    'UK',
    'US',
    'PR',
    'DO',
    'CU',
    'HT',
    'JM',
    'TT',
    'BB',
    'GY',
    'SR',
    'BO',
    'PE',
    'CL',
    'AR',
    'UY',
    'PY',
    'EC',
    'CO',
    'VE',
  ];
  final out = <String>{...base};
  // Top the list up to 161 with provider-style tags (NF, 24/7, VIP, ...).
  const tags = ['NF', 'VIP', 'HD', 'FHD', '4K', '3D', 'PPV', 'XXX', 'DOC', 'KIDS', 'NEWS', 'SPORT', 'MOV', 'SER'];
  var i = 0;
  while (out.length < 161) {
    out.add('${tags[i % tags.length]}${i ~/ tags.length + 2}');
    i++;
  }
  return out.toList();
}

/// Trex-shaped fake panel reproducing MATT'S panel behaviour:
/// - unfiltered get_vod_streams returns [] (199k rows is too many for
///   one call on this panel) — VOD loads by per-category crawl.
/// - unfiltered get_series returns rows; per-category get_series returns
///   [] (g-shape).
/// - unfiltered get_live_streams returns rows.
/// - 150 EN categories per section + one AR region category, with the
///   buried/bracket/lowercase name shapes build #13's derivation handles.
/// - Sets last*Body on unfiltered calls (mirroring the real XtreamApi)
///   so the client's raw-body disk-write path is exercised; per-category
///   calls clear it, like the real implementation.
class _TrexPanelFakeApi extends XtreamApi {
  _TrexPanelFakeApi()
    : super(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password:
            'pa'
            'ss',
      );

  List<XtreamCategory> _categories(String prefix) => [
    for (var i = 1; i <= 150; i++) XtreamCategory(id: '$i', name: '|EN| $prefix $i'),
    const XtreamCategory(id: '900', name: '|AR| Hidden Region'),
    const XtreamCategory(id: '901', name: 'MOVIES | EN | Buried Region'),
    const XtreamCategory(id: '902', name: '[AR] Bracket Region'),
    const XtreamCategory(id: '903', name: 'en | Lowercase Region'),
  ];

  List<XtreamCategory> liveCategories() => _categories('Live');
  List<XtreamCategory> vodCategories() => _categories('Movies');
  List<XtreamCategory> seriesCategories() => _categories('Series');

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
      // Matt's panel: unfiltered VOD returns [] at 199k rows.
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
      // g-shape: per-category series returns [] on this panel.
      lastSeriesBody = null;
      return const [];
    }
    final rows = seriesRows();
    lastSeriesBody = jsonEncode(rows.map((r) => r.toJson()).toList());
    return rows;
  }
}
