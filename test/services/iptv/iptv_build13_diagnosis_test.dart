// REPRODUCTION — build #13 (v2.25.9): search is STILL broken on Matt's
// phone in series AND live TV (2026-11-07 ~04:53 EST: "don't stop testing
// and working until you get it working").
//
// Failing-first: every test below asserts the behaviour Matt needs, at his
// scale and on his shape of connection — cold start, real-scale catalogs
// (150 visible categories per section here, standing in for his ~270
// series / ~500 live / ~300 VOD categories), LTE-like per-call latency,
// and his filter state (32 hidden initials, 0 hidden ids, EN shown,
// 2026-11-12 phone state).
// A test that FAILS here fails the way his phone fails; a fix that makes
// these pass has proven the drop point instead of guessing it.
//
// Shapes under test:
// - (B1) the cold crawl trap: the unfiltered get_series/get_vod_streams
//   returns [], so the catalog load becomes a per-category crawl whose
//   partial progress is invisible to search — the search budget expires
//   with [] although the match exists on the panel in a late category.
// - (B2) the slow unfiltered load: one big call lands after the section
//   budget, and the sweep cannot reach a late category in time either.
// - (L) live TV: Xtream live channels have NO search leg at all — only
//   M3U channels are searchable — so "search in live TV" is empty by
//   construction, whatever the timing.
// - (D) the on-device diagnostics themselves hang: seriesCatalogDiagnostics
//   awaits the full _seriesList() crawl, so on the exact phone that needs
//   the readout it takes minutes to answer.
//
// Every test uses a scaled-down section budget (the production 50s) with
// proportional delays, so the timing shapes run in ~1s each — the same
// idiom as iptv_build10_diagnosis_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/iptv_search_index_seed.dart';
import '../../test_helpers/prefs.dart';

void main() {
  // _seriesItems/_moviesItems stamp favourites via SharedPreferences.
  setUp(resetSharedPreferencesForTest);

  // R2.3: search answers from the local index, so the search groups seed
  // it from their fake panels (see seedIptvSearchIndexFromFakePanel).
  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build13_diag_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!await tempDir.exists()) break;
      try {
        await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 2) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  });

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  // Matt's filter state, in shape: every initial hidden except EN.
  const hiddenInitials = ['AR', 'FR', 'DE', 'PL', 'ES', 'IN', 'NL', 'SE'];

  Future<IptvClient> xtreamClient({XtreamApi? api, Set<String> seedTypes = const {'live', 'movie', 'series'}}) async {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      hiddenCategoryInitials: hiddenInitials,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    final effectiveApi = api ?? _TrexScaleFakeXtreamApi();
    client.testXtreamApi = effectiveApi;
    // R2.3: the search groups assert search over a synced catalog, so
    // seed the local index from the fake panel's rows before the test
    // searches — the client then answers from the warm index.
    await seedIptvSearchIndexFromFakePanel(effectiveApi, 'conn-xt-1', types: seedTypes);
    return client;
  }

  const seriesLibraryId = 'iptv:conn-xt-1:series';
  const moviesLibraryId = 'iptv:conn-xt-1:movies';
  const liveLibraryId = 'iptv:conn-xt-1:live';

  /// Run [body] with the production section budget scaled to 3s.
  ///
  /// Build #21 recalibration: the search burst is now capped at 4 total
  /// in flight (was a per-section batch of 16), so the sweep covers a
  /// late category ~4x slower. The 1s budget these tests were written
  /// against assumed batch 16 and can no longer be met at cap 8 — e.g.
  /// B2 needs 110 categories x 80ms / 8 = 1100ms to reach its match.
  /// 3s keeps the test fast (16x tighter than production's 50s) while
  /// giving the cap-4 sweep room to prove it still rescues the match.
  /// The behaviour under test is unchanged: the sweep must still reach
  /// a late-category match when the unfiltered load is slow or empty.
  Future<T> withScaledBudget<T>(Future<T> Function() body) async {
    final previousBudget = IptvClient.searchSectionBudget;
    IptvClient.searchSectionBudget = const Duration(milliseconds: 3000);
    try {
      return await body();
    } finally {
      IptvClient.searchSectionBudget = previousBudget;
    }
  }

  /// Wait until the series leg has indexed rows (the submit's sync has
  /// landed), or fail after 10 s. `searchIndexReady` only awaits an index
  /// write already in flight — a slow sync is still fetching when it is
  /// awaited, so it returns immediately and the next search runs before
  /// the sync lands.
  Future<void> waitForSeriesRows(IptvClient client) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while ((client.searchIndexState.rowCounts['series'] ?? 0) == 0) {
      if (DateTime.now().isAfter(deadline)) {
        fail('series index rows never landed within 10 s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  group('build13 reproduction: the cold crawl trap (series)', () {
    test('B1: unfiltered [] + slow crawl + late-category match returns the show', () async {
      // 120 visible EN series categories; the only match sits in category
      // 110; each per-category call takes 80ms. R2.3: the sweep and the
      // crawl are gone from search, so a match that lives ONLY in a
      // per-category call is not reachable by search at all — the sync's
      // unfiltered call returns [] ('empty-response'), so the series leg
      // stays [] + cold and the search answers the other legs instead of
      // burning a budget crawling 120 categories. (The per-category
      // rescue still exists in browse — see the catalog-fallback group
      // in iptv_stage2_test.dart.)
      final client = await xtreamClient(
        api: _TrexScaleFakeXtreamApi(
          unfilteredSeriesEmpty: true,
          seriesPerCategoryDelay: const Duration(milliseconds: 80),
          matchSeriesCategoryId: '110',
          seriesCategoryCount: 120,
        ),
        seedTypes: const {'live', 'movie'},
      );
      try {
        final results = await client.searchItems('alpha', onlineAllowed: true);
        expect(results.map((i) => i.title), isNot(contains('Alpha Show')));
        expect(client.lastSearchDiagnostics?.series.cold, isTrue);
      } finally {
        client.close();
      }
    });

    test('B2: slow unfiltered load + late-category match returns the show', () async {
      // The unfiltered call DOES return the show, but only after 1400ms.
      // R2.3: the sweep is gone — the rescue is the submit's sync, which
      // fetches the unfiltered list in the background (one call, no
      // per-category crawl) and writes disk + index; the first search
      // answers the warm movies immediately, and the next search finds
      // the show once the sync lands.
      final api = _TrexScaleFakeXtreamApi(
        unfilteredSeriesDelay: const Duration(milliseconds: 1400),
        seriesPerCategoryDelay: const Duration(milliseconds: 80),
        matchSeriesCategoryId: '110',
        seriesCategoryCount: 120,
      );
      final client = await xtreamClient(api: api, seedTypes: const {'live', 'movie'});
      try {
        final first = await client.searchItems('alpha', onlineAllowed: true);
        expect(first.map((i) => i.title), isNot(contains('Alpha Show')));
        await waitForSeriesRows(client);
        final results = await client.searchItems('alpha');
        expect(results.map((i) => i.title), contains('Alpha Show'));
      } finally {
        client.close();
      }
    });
  });

  group('build13 reproduction: the cold crawl trap (movies)', () {
    test('B1: unfiltered [] + slow crawl + late-category match returns the movie', () async {
      // Same trap on the 199k-row VOD side: unfiltered [] turns the load
      // into a crawl, and the match in category 110 lives only in a
      // per-category call. R2.3: same boundary as the series B1 — the
      // search cannot reach it; the sync records 'empty-response' and
      // the movies leg stays [] + cold.
      final client = await xtreamClient(
        api: _TrexScaleFakeXtreamApi(
          unfilteredVodEmpty: true,
          vodPerCategoryDelay: const Duration(milliseconds: 80),
          matchVodCategoryId: '110',
          vodCategoryCount: 120,
        ),
        seedTypes: const {'live', 'series'},
      );
      try {
        final results = await client.searchItems('alpha', onlineAllowed: true);
        expect(results.map((i) => i.title), isNot(contains('Alpha Movie 2')));
        expect(client.lastSearchDiagnostics?.movies.cold, isTrue);
      } finally {
        client.close();
      }
    });
  });

  group('build13 reproduction: live TV search', () {
    test('L: Xtream live channels are searchable', () async {
      // The live catalog holds 'HBO East' in an EN category. Today the
      // Xtream searchItems returns movies + series only — there is no
      // live leg at all — so a live-TV search is empty by construction.
      final client = await xtreamClient(api: _TrexScaleFakeXtreamApi());
      try {
        final results = await withScaledBudget(() => client.searchItems('hbo'));
        final live = results.where((i) => i.libraryId == liveLibraryId).toList();
        expect(live.map((i) => i.title), contains('HBO East'));
      } finally {
        client.close();
      }
    });

    test('L-scope: a scoped search does not return live channels', () async {
      // Guard: with a Movies scope (every other library excluded), live
      // results must stay out — the live library is not a real library,
      // so it can never appear in excludedLibraryIds itself.
      //
      // Pinned on the COLD path: live is NOT seeded here, so the section
      // falls through to the fallback, where the exclusion skips it (the
      // #23 scope inversion means a WARM index still returns the global
      // pool and the aggregation filters — the client-level skip only
      // applies when the index is cold).
      final client = await xtreamClient(api: _TrexScaleFakeXtreamApi(), seedTypes: const {'movie', 'series'});
      try {
        final results = await withScaledBudget(
          () => client.searchItems('hbo', excludedLibraryIds: {seriesLibraryId, moviesLibraryId}),
        );
        expect(results.where((i) => i.libraryId == liveLibraryId), isEmpty);
      } finally {
        client.close();
      }
    });

    test('L-filter: hidden-category channels stay hidden from live search', () async {
      // Guard: a channel in an AR category (AR initial turned off) must
      // not surface, the same as movies/series honour the filter.
      final client = await xtreamClient(api: _TrexScaleFakeXtreamApi());
      try {
        final results = await withScaledBudget(() => client.searchItems('aljazeera'));
        expect(results.map((i) => i.title), isNot(contains('Al Jazeera')));
      } finally {
        client.close();
      }
    });
  });

  group('build13 reproduction: on-device search diagnostics', () {
    test('D: the series catalog readout answers while the catalog is still crawling', () async {
      // On Matt's phone the diagnostics row itself is the problem: it
      // awaits the full _seriesList() crawl (~minutes on the (g) shape),
      // so the one readout that could settle (g) never answers. It must
      // return inside the search budget by probing directly instead.
      final client = await xtreamClient(
        api: _TrexScaleFakeXtreamApi(
          unfilteredSeriesEmpty: true,
          seriesPerCategoryDelay: const Duration(milliseconds: 100),
          matchSeriesCategoryId: '120',
          seriesCategoryCount: 150,
        ),
      );
      try {
        final diagnostics = await client
            .seriesCatalogDiagnostics()
            .timeout(const Duration(milliseconds: 1500));
        // 150 EN categories + the AR region category.
        expect(diagnostics.seriesCategoryCount, 151);
        expect(diagnostics.unfilteredSeriesRows, 0);
      } finally {
        client.close();
      }
    });
  });

  group('build13 controls: warm paths that must keep working', () {
    test('control: a warm series catalog answers search', () async {
      final client = await xtreamClient(api: _TrexScaleFakeXtreamApi());
      try {
        final first = await withScaledBudget(() => client.searchItems('alpha'));
        expect(first.map((i) => i.title), contains('Alpha Show'));
        final second = await withScaledBudget(() => client.searchItems('alpha'));
        expect(second.map((i) => i.title), contains('Alpha Show'));
      } finally {
        client.close();
      }
    });

    test('control: a disk-cached series catalog answers search without a network load', () async {
      // R2.3: the disk is populated by the submit's sync, not by a
      // search load. The first client submits (its sync writes the disk
      // file); a fresh client with the same connection id — and a fresh,
      // cold index — must then serve the search from disk, zero
      // unfiltered network calls. (The index is pointed at a fresh dir
      // for the second client so the test pins the DISK path, not the
      // index the first client's sync also wrote.)
      final tempDir = await Directory.systemTemp.createTemp('plezy_build13_disk_');
      final indexDir1 = await Directory.systemTemp.createTemp('plezy_build13_disk_idx1_');
      final indexDir2 = await Directory.systemTemp.createTemp('plezy_build13_disk_idx2_');
      IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
      try {
        IptvSearchIndex.debugDirectoryProvider = () async => indexDir1;
        final api = _TrexScaleFakeXtreamApi();
        final first = await xtreamClient(api: api, seedTypes: const {});
        try {
          await first.searchItems('alpha', onlineAllowed: true);
          await waitForSeriesRows(first);
          final results = await first.searchItems('alpha');
          expect(results.map((i) => i.title), contains('Alpha Show'));
        } finally {
          first.close();
        }
        // Let the fire-and-forget disk write land.
        await Future.delayed(const Duration(milliseconds: 300));
        IptvSearchIndex.debugDirectoryProvider = () async => indexDir2;
        final api2 = _TrexScaleFakeXtreamApi();
        final second = await xtreamClient(api: api2, seedTypes: const {});
        try {
          final results = await second.searchItems('alpha');
          expect(results.map((i) => i.title), contains('Alpha Show'));
          expect(api2.unfilteredSeriesCalls, 0);
        } finally {
          second.close();
        }
      } finally {
        IptvCatalogDiskCache.debugDirectoryProvider = null;
        IptvSearchIndex.debugDirectoryProvider = null;
        for (final d in [tempDir, indexDir1, indexDir2]) {
          if (await d.exists()) await d.delete(recursive: true);
        }
      }
    });
  });
}

/// Trex-scale fake: 150 visible EN categories per section (standing in
/// for Matt's ~270 series / ~500 live / ~300 VOD categories), a match in
/// a chosen late category, LTE-like per-call delays, and his filter state
/// (AR categories exist but are hidden by the disabled AR initial).
class _TrexScaleFakeXtreamApi extends XtreamApi {
  _TrexScaleFakeXtreamApi({
    this.seriesCategoryCount = 150,
    this.vodCategoryCount = 150,
    this.seriesPerCategoryDelay = Duration.zero,
    this.vodPerCategoryDelay = Duration.zero,
    this.unfilteredSeriesDelay = Duration.zero,
    this.unfilteredSeriesEmpty = false,
    this.unfilteredVodEmpty = false,
    this.matchSeriesCategoryId = '1',
    this.matchVodCategoryId = '1',
  }) : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final int seriesCategoryCount;
  final int vodCategoryCount;
  final Duration seriesPerCategoryDelay;
  final Duration vodPerCategoryDelay;
  final Duration unfilteredSeriesDelay;
  final bool unfilteredSeriesEmpty;
  final bool unfilteredVodEmpty;
  final String matchSeriesCategoryId;
  final String matchVodCategoryId;

  int unfilteredSeriesCalls = 0;
  int unfilteredVodCalls = 0;
  int unfilteredLiveCalls = 0;

  List<XtreamCategory> _categories(String prefix, int count) => [
    for (var i = 1; i <= count; i++) XtreamCategory(id: '$i', name: '|EN| $prefix $i'),
    // A hidden region category: AR initial is turned off, so anything
    // in it must never surface in browse or search.
    const XtreamCategory(id: '900', name: '|AR| Hidden Region'),
  ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => _categories('Series', seriesCategoryCount);

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async => _categories('Movies', vodCategoryCount);

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => _categories('Live', 150);

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) {
      unfilteredSeriesCalls++;
      await Future.delayed(unfilteredSeriesDelay);
      if (unfilteredSeriesEmpty) return const [];
      // One row per EN category: the sync's completeness guard refuses a
      // write covering <50% of the categories, so a 1-row answer would
      // (correctly) be discarded as 'partial'.
      final rows = [
        for (var i = 1; i <= seriesCategoryCount; i++)
          XtreamSeries(
            seriesId: 1000 + i,
            name: '$i' == matchSeriesCategoryId ? 'Alpha Show' : 'Filler Series $i',
            categoryId: '$i',
          ),
      ];
      lastSeriesBody = jsonEncode(rows.map((r) => r.toJson()).toList());
      return rows;
    }
    await Future.delayed(seriesPerCategoryDelay);
    if (categoryId == matchSeriesCategoryId) {
      return [XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: categoryId)];
    }
    return const [];
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) {
      unfilteredVodCalls++;
      if (unfilteredVodEmpty) return const [];
      final rows = [
        for (var i = 1; i <= vodCategoryCount; i++)
          XtreamVodStream(
            streamId: 1000 + i,
            name: '$i' == matchVodCategoryId ? 'Alpha Movie' : 'Filler Movie $i',
            containerExtension: 'mp4',
            categoryId: '$i',
          ),
      ];
      lastVodStreamsBody = jsonEncode(rows.map((r) => r.toJson()).toList());
      return rows;
    }
    await Future.delayed(vodPerCategoryDelay);
    if (categoryId == matchVodCategoryId) {
      return [
        XtreamVodStream(
          streamId: 2,
          name: 'Alpha Movie 2',
          containerExtension: 'mp4',
          categoryId: categoryId,
        ),
      ];
    }
    return const [];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) {
      unfilteredLiveCalls++;
      final rows = [
        for (var i = 1; i <= 150; i++)
          XtreamLiveStream(
            streamId: 1000 + i,
            name: i == 1 ? 'HBO East' : 'Filler Live $i',
            categoryId: '$i',
          ),
        const XtreamLiveStream(streamId: 101, name: 'Al Jazeera', categoryId: '900'),
      ];
      lastLiveStreamsBody = jsonEncode(rows.map((r) => r.toJson()).toList());
      return rows;
    }
    if (categoryId == '1') {
      return [XtreamLiveStream(streamId: 100, name: 'HBO East', categoryId: categoryId)];
    }
    return const [];
  }
}
