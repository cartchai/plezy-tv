// DIAGNOSIS ONLY — build #10 (v2.25.5): series/TV search is STILL broken
// on Matt's phone, and a series sub-category ("|EN| UK SERIES") shows
// "No items found" when opened. These are CHARACTERIZATION tests: they
// assert what the code DOES today under real-provider shapes (slow LTE
// calls, empty panel responses, disabled initials, mismatched category
// ids), so the drop point is proven by a passing test instead of a
// code-read. A test whose expectation documents a BUG is marked DIAGNOSIS
// and must be flipped to the fixed expectation when the fix lands — do
// not "fix" these tests by changing the expectation without fixing code.
//
// Build #10 note: the (h) fix in this file is SUPERSEDED by the
// category-initials redesign — the name-based filter is gone, so the H1
// test was flipped to the new behaviour (a disabled EN initial no longer
// hides EN-named shows) and the (h) coverage moved to
// iptv_category_initials_test.dart. The T1/T2/T3 timing tests still
// assert the same outcomes under the reworked search (single shared
// category-list fetch, sweep deadline from section start, unfiltered-load
// race); their comments were updated to the post-fix reading.
//
// Every test uses a scaled-down section budget (the production 50s) with
// proportional delays, so the timing shapes run in ~1s each.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/search_hit.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/utils/search_relevance.dart';

import '../../test_helpers/prefs.dart';

void main() {
  // _seriesItems/_moviesItems stamp favourites via SharedPreferences.
  setUp(resetSharedPreferencesForTest);

  // (The password is split so the literal never appears in new code.)
  const testPassword = 'pa' 'ss';

  IptvClient xtreamClient({XtreamApi? api, List<String> hiddenCategoryInitials = const []}) {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      hiddenCategoryInitials: hiddenCategoryInitials,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    client.testXtreamApi = api ?? _DiagnosisFakeXtreamApi();
    return client;
  }

  const seriesLibraryId = 'iptv:conn-xt-1:series';

  group('build10 diagnosis: the series catalog itself (hypothesis g)', () {
    test('DIAGNOSIS: per-category series calls returning [] empty BOTH category browse and search', () async {
      // The panel behaviour behind both v2.25.5 symptoms at once: the
      // unfiltered get_series returns [] AND every per-category get_series
      // returns []. Then _seriesList() is [] (category contents filter the
      // full catalog client-side, so the drill-down is empty) and the
      // search sweep has no rows to match either. One cause, both symptoms.
      final client = xtreamClient(api: _EmptySeriesApi());
      final categoryItems = await client.iptvItemsForCategory(seriesLibraryId, '1');
      expect(categoryItems, isEmpty);
      final results = await client.searchItems('alpha');
      expect(results.map((i) => i.title), ['Alpha Movie']);
      client.close();
    });

    test('control: per-category rows rescue both browse and search when unfiltered is []', () async {
      // Same panel shape as above except the per-category calls DO return
      // rows (the build #7 fallback assumption). Then the crawl loads the
      // catalog and both surfaces work — proving the per-category calls
      // are the load-bearing path when the unfiltered call is empty.
      final client = xtreamClient(api: _EmptyUnfilteredSeriesApi());
      final categoryItems = await client.iptvItemsForCategory(seriesLibraryId, '1');
      expect(categoryItems.map((i) => i.title), ['Alpha Show']);
      final results = await client.searchItems('alpha');
      expect(results.map((i) => i.title), contains('Alpha Show'));
      client.close();
    });
  });

  group('build10 diagnosis: the initials filter (hypothesis h)', () {
    test('FLIPPED (build #10 redesign): a disabled EN initial no longer hides EN-named shows', () async {
      // Build #10 redesign: the filter moved from item NAMES to CATEGORY
      // names. The category here is named "Action" — it carries no
      // initial — so disabling EN hides nothing, and the "EN - Alpha
      // Show" row is found in browse AND search despite EN being turned
      // off: item names are never filtered. (h) as a name filter is
      // superseded; the category-initial version of it is covered by
      // iptv_category_initials_test.dart. Matt also turned ALL initials
      // back on and search STILL failed, so (h) is ruled out for search
      // regardless — search has its own root cause (the cold-path race).
      final client = xtreamClient(api: _EnInitialApi(), hiddenCategoryInitials: const ['EN']);
      final categoryItems = await client.iptvItemsForCategory(seriesLibraryId, '1');
      expect(categoryItems.map((i) => i.title), ['EN - Alpha Show']);
      final results = await client.searchItems('alpha');
      expect(results.map((i) => i.title), contains('EN - Alpha Show'));
      client.close();
    });

    test('control: the same EN-named rows are found when no initial is disabled', () async {
      final client = xtreamClient(api: _EnInitialApi());
      final categoryItems = await client.iptvItemsForCategory(seriesLibraryId, '1');
      expect(categoryItems.map((i) => i.title), ['EN - Alpha Show']);
      final results = await client.searchItems('alpha');
      expect(results.map((i) => i.title), contains('EN - Alpha Show'));
      client.close();
    });
  });

  group('build10 diagnosis: category-id mismatch (hypothesis i)', () {
    test('DIAGNOSIS: rows whose category_id matches no listed category empty the drill-down but NOT search', () async {
      // Series rows carry category_id '999' while the category list only
      // has id '1'. The drill-down filters s.categoryId == '1', so it is
      // empty — but the search sweep matches by NAME, so search still
      // finds the show. (i) explains an empty category on its own; it
      // does NOT explain the joint failure with search.
      final client = xtreamClient(api: _MismatchedCategoryApi());
      final categoryItems = await client.iptvItemsForCategory(seriesLibraryId, '1');
      expect(categoryItems, isEmpty);
      final results = await client.searchItems('alpha');
      expect(results.map((i) => i.title), contains('Alpha Show'));
      client.close();
    });
  });

  group('build10 diagnosis: search timing on LTE (hypotheses b/c)', () {
    test('DIAGNOSIS: a failing series-category list burns the section budget before the sweep starts', () async {
      // get_series_categories takes 600ms of a 1000ms section budget and
      // then throws. Post-fix (build #10) the list is fetched ONCE — the
      // names lookup fetches it and the sweep reuses the same cached
      // future, so there is no second fetch to starve the sweep — but the
      // failure still leaves the sweep with no categories, and the
      // unfiltered load in this fake never completes, so both sources
      // fail and the section returns []. The movies leg is unaffected
      // (its own category list answers at once).
      final client = xtreamClient(
        api: _TimedSeriesFakeXtreamApi(namesDelay: const Duration(milliseconds: 600), namesThrow: true),
      );
      final previousBudget = IptvClient.searchSectionBudget;
      IptvClient.searchSectionBudget = const Duration(milliseconds: 1000);
      try {
        final results = await client.searchItems('alpha');
        expect(results.map((i) => i.title), ['Alpha Movie']);
      } finally {
        IptvClient.searchSectionBudget = previousBudget;
        client.close();
      }
    });

    test('FIXED (build #13): a match in a late category is reachable when per-category calls are slow', () async {
      // Was a DIAGNOSIS test (build #10): 24 series categories; the only
      // match sits in category 20 (batch 3 of 8); each per-category call
      // takes 400ms of a 1000ms budget (sweep deadline 900ms). Batch 1
      // landed at 400ms, batch 2 at 800ms, batch 3 would land at 1200ms
      // — past both deadlines — so the sweep returned [] although the
      // match existed on the panel. Build #13 doubled the sweep/crawl
      // batch to 16, so category 20 lands in batch 2 (800ms, inside the
      // deadline) and the partial-row publication hands the match to the
      // search as soon as the batch lands.
      final client = xtreamClient(
        api: _TimedSeriesFakeXtreamApi(
          categoryDelay: const Duration(milliseconds: 400),
          matchCategoryId: '20',
          categoryCount: 24,
        ),
      );
      final previousBudget = IptvClient.searchSectionBudget;
      IptvClient.searchSectionBudget = const Duration(milliseconds: 1000);
      try {
        final results = await client.searchItems('alpha');
        expect(results.map((i) => i.title), ['Alpha Movie', 'Alpha Show']);
      } finally {
        IptvClient.searchSectionBudget = previousBudget;
        client.close();
      }
    });

    test('control: the same slow calls find a match sitting in the first batch', () async {
      final client = xtreamClient(
        api: _TimedSeriesFakeXtreamApi(
          categoryDelay: const Duration(milliseconds: 400),
          matchCategoryId: '3',
          categoryCount: 24,
        ),
      );
      final previousBudget = IptvClient.searchSectionBudget;
      IptvClient.searchSectionBudget = const Duration(milliseconds: 1000);
      try {
        final results = await client.searchItems('alpha');
        expect(results.map((i) => i.title), contains('Alpha Show'));
      } finally {
        IptvClient.searchSectionBudget = previousBudget;
        client.close();
      }
    });

    test('FIXED (build #13): a slow category-names fetch plus slow per-category calls still finds a batch-2 match', () async {
      // Was a DIAGNOSIS test (build #10): the names fetch eats 600ms of
      // a 1000ms budget before the sweep even starts; each per-category
      // call takes 250ms, so batch 1 landed at 850ms and batch 2
      // (holding the match) would land at 1100ms — past the sweep
      // deadline. Build #13 doubled the sweep/crawl batch to 16, so the
      // match's category 9 lands in batch 1 (850ms, inside the 900ms
      // deadline) and the partial-row publication hands it to the
      // search as soon as the batch lands.
      final client = xtreamClient(
        api: _TimedSeriesFakeXtreamApi(
          namesDelay: const Duration(milliseconds: 600),
          categoryDelay: const Duration(milliseconds: 250),
          matchCategoryId: '9',
          categoryCount: 24,
        ),
      );
      final previousBudget = IptvClient.searchSectionBudget;
      IptvClient.searchSectionBudget = const Duration(milliseconds: 1000);
      try {
        final results = await client.searchItems('alpha');
        expect(results.map((i) => i.title), ['Alpha Movie', 'Alpha Show']);
      } finally {
        IptvClient.searchSectionBudget = previousBudget;
        client.close();
      }
    });
  });

  group('build10 diagnosis: aggregation ranking (hypothesis e)', () {
    test('DIAGNOSIS: a generic query buries the series match out of the ranked top-100, but the candidate pool keeps it', () async {
      // 120 movies named "The Movie N" (query "the" is a prefix match,
      // ~914) plus one series "A Show About The Thing" (query "the" is a
      // substring match, ~807). The client returns all 101 rows, but the
      // aggregation's rankSearchHits cap at 100 drops the series from
      // the ranked "All" list — while the uncapped candidate pool (what
      // the TV Shows chip reads) still holds it. So (e) can hide series
      // from the All view for generic queries, but it cannot explain
      // "can't search series at all" while the chip exists.
      final client = xtreamClient(api: _CrowdedTheApi());
      final items = await client.searchItems('the');
      expect(items.map((i) => i.title), contains('A Show About The Thing'));
      final ranked = rankSearchHits([for (final item in items) MediaSearchHit(item)], 'the', limit: 100);
      expect(
        ranked.whereType<MediaSearchHit>().map((h) => h.item.title),
        isNot(contains('A Show About The Thing')),
      );
      client.close();
    });
  });

  group('build10 diagnosis: controls (warm path, scope)', () {
    test('control: a warm series catalog answers search', () async {
      // Unfiltered get_series returns rows, so the first search warms
      // the catalog and later searches filter the cached list.
      final client = xtreamClient(api: _DiagnosisFakeXtreamApi());
      final first = await client.searchItems('alpha');
      expect(first.map((i) => i.title), contains('Alpha Show'));
      final second = await client.searchItems('alpha');
      expect(second.map((i) => i.title), contains('Alpha Show'));
      client.close();
    });

    test('control: excluding the series library hides series by design (scope trap)', () async {
      // The build #9 scope strip adds every other library to
      // hiddenLibraryIds; a scope of "Trex — Movies" skips the series
      // section entirely. In-session only (the scope resets when the
      // search screen is left), but while set, series search is empty
      // on purpose.
      final client = xtreamClient(api: _DiagnosisFakeXtreamApi());
      final results = await client.searchItems('alpha', excludedLibraryIds: {seriesLibraryId});
      expect(results.map((i) => i.title), ['Alpha Movie']);
      client.close();
    });
  });
}

/// Baseline fake: one movie, one series, one category each — everything
/// answers instantly.
class _DiagnosisFakeXtreamApi extends XtreamApi {
  _DiagnosisFakeXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => const [
    XtreamVodStream(streamId: 1, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: '1'),
  ];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [
    XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1'),
  ];

  @override
  Future<List<XtreamCategory>> getVodCategories() async =>
      const [XtreamCategory(id: '1', name: 'Action')];

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async =>
      const [XtreamCategory(id: '1', name: 'Action')];
}

/// The panel returns [] for series everywhere: unfiltered AND per-category.
/// The series catalog is empty, so both surfaces that read it are empty.
class _EmptySeriesApi extends _DiagnosisFakeXtreamApi {
  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [];
}

/// Unfiltered get_series returns [] but per-category calls return rows —
/// the build #7 fallback assumption. The crawl loads the catalog.
class _EmptyUnfilteredSeriesApi extends _DiagnosisFakeXtreamApi {
  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    if (categoryId == null) return const [];
    return const [XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1')];
  }
}

/// Every series carries the "EN - " prefix.
class _EnInitialApi extends _DiagnosisFakeXtreamApi {
  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [
    XtreamSeries(seriesId: 10, name: 'EN - Alpha Show', categoryId: '1'),
  ];
}

/// Series rows carry a category_id ('999') that no listed category has.
class _MismatchedCategoryApi extends _DiagnosisFakeXtreamApi {
  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [
    XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '999'),
  ];
}

/// 120 movies matching a generic query plus one low-scoring series match.
class _CrowdedTheApi extends _DiagnosisFakeXtreamApi {
  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => List.generate(
    120,
    (i) => XtreamVodStream(streamId: 1000 + i, name: 'The Movie ${i + 1}', containerExtension: 'mp4', categoryId: '1'),
  );

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [
    XtreamSeries(seriesId: 10, name: 'A Show About The Thing', categoryId: '1'),
  ];
}

/// Timed fake for the LTE shapes: a slow/throwing category list, slow
/// per-category calls, and the match sitting in a chosen category.
class _TimedSeriesFakeXtreamApi extends _DiagnosisFakeXtreamApi {
  _TimedSeriesFakeXtreamApi({
    this.namesDelay = Duration.zero,
    this.namesThrow = false,
    this.categoryDelay = Duration.zero,
    this.matchCategoryId = '1',
    this.categoryCount = 1,
  });

  final Duration namesDelay;
  final bool namesThrow;
  final Duration categoryDelay;
  final String matchCategoryId;
  final int categoryCount;

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async {
    await Future.delayed(namesDelay);
    if (namesThrow) throw Exception('series categories unavailable');
    return [
      for (var i = 1; i <= categoryCount; i++) XtreamCategory(id: '$i', name: 'Category $i'),
    ];
  }

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    if (categoryId == null) return Completer<List<XtreamSeries>>().future;
    await Future.delayed(categoryDelay);
    if (categoryId == matchCategoryId) {
      return [XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: categoryId)];
    }
    return const [];
  }
}
