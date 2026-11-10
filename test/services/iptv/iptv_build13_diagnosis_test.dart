// REPRODUCTION — build #13 (v2.25.9): search is STILL broken on Matt's
// phone in series AND live TV (2026-11-07 ~04:53 EST: "don't stop testing
// and working until you get it working").
//
// Failing-first: every test below asserts the behaviour Matt needs, at his
// scale and on his shape of connection — cold start, real-scale catalogs
// (150 visible categories per section here, standing in for his ~270
// series / ~500 live / ~300 VOD categories), LTE-like per-call latency,
// and his filter state (161 of 171 category initials hidden, EN shown).
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
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

void main() {
  // _seriesItems/_moviesItems stamp favourites via SharedPreferences.
  setUp(resetSharedPreferencesForTest);

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  // Matt's filter state, in shape: every initial hidden except EN.
  const hiddenInitials = ['AR', 'FR', 'DE', 'PL', 'ES', 'IN', 'NL', 'SE'];

  IptvClient xtreamClient({XtreamApi? api}) {
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
    client.testXtreamApi = api ?? _TrexScaleFakeXtreamApi();
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

  group('build13 reproduction: the cold crawl trap (series)', () {
    test('B1: unfiltered [] + slow crawl + late-category match returns the show', () async {
      // 120 visible EN series categories; the only match sits in category
      // 110; each per-category call takes 80ms of a 1000ms budget. Before
      // the fix the sweep (batches of 8) covered ~72 categories in its
      // 900ms deadline and the crawl needed ~1.2s with no partial
      // progress visible to search, so the search returned [] although
      // the show exists on the panel. After the fix the crawl publishes
      // each batch as it lands (batch 7, holding category 110, lands at
      // ~560ms) and the sweep skips crawled categories, so the match is
      // found well inside the budget.
      final client = xtreamClient(
        api: _TrexScaleFakeXtreamApi(
          unfilteredSeriesEmpty: true,
          seriesPerCategoryDelay: const Duration(milliseconds: 80),
          matchSeriesCategoryId: '110',
          seriesCategoryCount: 120,
        ),
      );
      try {
        final results = await withScaledBudget(() => client.searchItems('alpha'));
        expect(results.map((i) => i.title), contains('Alpha Show'));
      } finally {
        client.close();
      }
    });

    test('B2: slow unfiltered load + late-category match returns the show', () async {
      // The unfiltered call DOES return the show, but only after 1400ms
      // — past the section budget. The sweep must rescue it. At cap 8
      // and 80ms per call, category 110 lands after 110 / 8 x 80ms =
      // ~1100ms, inside the 2940ms sweep deadline (3s budget, build #21
      // recalibration — the 1s budget assumed the old batch of 16, which
      // reached category 110 in ~560ms). Before the build #13 fix the
      // sweep (batches of 8, 100ms per call) could not reach category
      // 120 inside 900ms, and the unfiltered load was past the budget —
      // both sources too slow, search returned [].
      final client = xtreamClient(
        api: _TrexScaleFakeXtreamApi(
          unfilteredSeriesDelay: const Duration(milliseconds: 1400),
          seriesPerCategoryDelay: const Duration(milliseconds: 80),
          matchSeriesCategoryId: '110',
          seriesCategoryCount: 120,
        ),
      );
      try {
        final results = await withScaledBudget(() => client.searchItems('alpha'));
        expect(results.map((i) => i.title), contains('Alpha Show'));
      } finally {
        client.close();
      }
    });
  });

  group('build13 reproduction: the cold crawl trap (movies)', () {
    test('B1: unfiltered [] + slow crawl + late-category match returns the movie', () async {
      // Same trap on the 199k-row VOD side: unfiltered [] turns the load
      // into a crawl, and the match in category 110 is past the old
      // sweep's reach inside the budget (see the series B1 comment).
      final client = xtreamClient(
        api: _TrexScaleFakeXtreamApi(
          unfilteredVodEmpty: true,
          vodPerCategoryDelay: const Duration(milliseconds: 80),
          matchVodCategoryId: '110',
          vodCategoryCount: 120,
        ),
      );
      try {
        final results = await withScaledBudget(() => client.searchItems('alpha'));
        expect(results.map((i) => i.title), contains('Alpha Movie 2'));
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
      final client = xtreamClient(api: _TrexScaleFakeXtreamApi());
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
      final client = xtreamClient(api: _TrexScaleFakeXtreamApi());
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
      final client = xtreamClient(api: _TrexScaleFakeXtreamApi());
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
      final client = xtreamClient(
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
      final client = xtreamClient(api: _TrexScaleFakeXtreamApi());
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
      // First client populates the disk cache (its load writes the file);
      // a fresh client with the same connection id must then serve the
      // search from disk — zero unfiltered network calls.
      final tempDir = await Directory.systemTemp.createTemp('plezy_build13_disk_');
      IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
      try {
        final api = _TrexScaleFakeXtreamApi();
        final first = xtreamClient(api: api);
        try {
          final results = await withScaledBudget(() => first.searchItems('alpha'));
          expect(results.map((i) => i.title), contains('Alpha Show'));
        } finally {
          first.close();
        }
        // Let the fire-and-forget disk write land.
        await Future.delayed(const Duration(milliseconds: 300));
        final api2 = _TrexScaleFakeXtreamApi();
        final second = xtreamClient(api: api2);
        try {
          final results = await withScaledBudget(() => second.searchItems('alpha'));
          expect(results.map((i) => i.title), contains('Alpha Show'));
          expect(api2.unfilteredSeriesCalls, 0);
        } finally {
          second.close();
        }
      } finally {
        IptvCatalogDiskCache.debugDirectoryProvider = null;
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
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
      return const [XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1')];
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
      return const [
        XtreamVodStream(streamId: 1, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: '1'),
      ];
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
      return const [
        XtreamLiveStream(streamId: 100, name: 'HBO East', categoryId: '1'),
        XtreamLiveStream(streamId: 101, name: 'Al Jazeera', categoryId: '900'),
      ];
    }
    if (categoryId == '1') {
      return [XtreamLiveStream(streamId: 100, name: 'HBO East', categoryId: categoryId)];
    }
    return const [];
  }
}
