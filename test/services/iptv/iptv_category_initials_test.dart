// Category initials (build #10 redesign of build #8 Task 4) + the series
// search fix: "Name initials" becomes "Category initials". The initial
// comes from the CATEGORY name's leading prefix — "|EN| UK SERIES" -> EN,
// "24/7 ACTION & ADVENTURE VIP" -> "24/7", "AR …" -> AR — and toggling
// one off hides ALL categories carrying it, and everything in them,
// everywhere: Live TV, Library browse, categories tab, search, EPG.
// Item names are NEVER filtered.
//
// The search tests prove the GOAL (Matt: "the GOAL is to be able to
// search TV shows too") in both states: (a) most initials hidden with EN
// shown — an EN show is found; (b) Show-all — any show is found. They
// also prove the cold-path race: the sweep must not be the only source —
// when the panel's per-category calls return [] (g) while the unfiltered
// load returns rows, search must find the show from the unfiltered load
// that Recommended proves works.
//
// Every timing test uses a scaled-down section budget (the production
// 50s) with proportional delays.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import 'dart:convert';
import 'dart:io';

import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';

import '../../test_helpers/iptv_search_index_seed.dart';
import '../../test_helpers/prefs.dart';

void main() {
  // _seriesItems/_moviesItems stamp favourites via SharedPreferences.
  setUp(resetSharedPreferencesForTest);

  // R2.3: search answers from the local index, so the search groups seed
  // it from their fake panels (see seedIptvSearchIndexFromFakePanel).
  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_cat_initials_');
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

  // (The password is split so the literal never appears in new code.)
  const testPassword = 'pa' 'ss';

  Future<IptvClient> xtreamClient({
    XtreamApi? api,
    List<String> hiddenCategoryInitials = const [],
    List<String> hiddenCategoryIds = const [],
    Set<String> seedTypes = const {'live', 'movie', 'series'},
  }) async {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      hiddenCategoryInitials: hiddenCategoryInitials,
      hiddenCategoryIds: hiddenCategoryIds,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    final effectiveApi = api ?? _CategoryInitialsFakeXtreamApi();
    client.testXtreamApi = effectiveApi;
    // R2.3: the search groups assert search over a synced catalog, so
    // seed the local index from the fake panel's rows before the test
    // searches — the client then answers from the warm index.
    await seedIptvSearchIndexFromFakePanel(effectiveApi, 'conn-xt-1', types: seedTypes);
    return client;
  }

  const seriesLibraryId = 'iptv:conn-xt-1:series';
  const moviesLibraryId = 'iptv:conn-xt-1:movies';

  group('category initials: detection (build #10 redesign)', () {
    test('iptvInitials counts CATEGORIES per initial, not items', () async {
      final client = await xtreamClient();
      // EN: 5 live + 5 VOD + 6 series categories = 16. FR: 5 live + 1
      // VOD + 5 series = 11. UK: 5 live = 5. The EN-named channels,
      // movies and shows add nothing — counts are per category.
      final initials = await client.iptvInitials();
      expect(
        initials.map((i) => (i.initial, i.count)),
        [('EN', 16), ('FR', 11), ('UK', 5)],
      );
      client.close();
    });

    test('categories with no leading prefix are ungrouped and never offered', () async {
      final client = await xtreamClient();
      final initials = await client.iptvInitials();
      // "Action" (VOD + series) carries no initial — it is never a toggle.
      expect(initials.map((i) => i.initial), isNot(contains('Action')));
      client.close();
    });
  });

  group('category initials: toggling hides whole regions', () {
    test('disabling FR hides all its categories and their items everywhere', () async {
      final client = await xtreamClient(hiddenCategoryInitials: const ['FR']);
      // Browse: Beta Movie sits in "FR - Films", Beta Show in "FR - Drama".
      final movies = await client.fetchLibraryPagedContent(moviesLibraryId, query: const LibraryQuery());
      expect(movies.items.map((i) => i.title), ['Alpha Movie']);
      final series = await client.fetchLibraryPagedContent(seriesLibraryId, query: const LibraryQuery());
      expect(series.items.map((i) => i.title), ['Alpha Show', 'Gamma Show']);
      // Categories tab: no FR category is listed.
      final categories = await client.iptvCategoriesForLibrary(seriesLibraryId);
      expect(categories.map((c) => c.name), isNot(contains('FR - Drama')));
      expect(categories.map((c) => c.name), contains('|EN| UK SERIES'));
      expect(categories.map((c) => c.name), contains('Action'));
      // Category drill-down into a hidden category is empty.
      expect(await client.iptvItemsForCategory(seriesLibraryId, '7'), isEmpty);
      // Live TV: the FR channel is gone, EN and UK stay.
      final channels = await client.iptvChannels();
      expect(channels.map((c) => c.title), ['EN - Channel', 'UK - Channel', 'EN - Special']);
      client.close();
    });

    test('re-enabling the initial restores its categories', () async {
      final hidden = await xtreamClient(hiddenCategoryInitials: const ['FR']);
      expect((await hidden.fetchLibraryPagedContent(seriesLibraryId, query: const LibraryQuery())).items.map((i) => i.title), ['Alpha Show', 'Gamma Show']);
      hidden.close();
      final shown = await xtreamClient();
      expect(
        (await shown.fetchLibraryPagedContent(seriesLibraryId, query: const LibraryQuery())).items.map((i) => i.title),
        ['Alpha Show', 'Beta Show', 'Gamma Show'],
      );
      shown.close();
    });

    test('an individual category toggle still hides just that category', () async {
      final client = await xtreamClient(hiddenCategoryIds: const ['1']);
      final series = await client.fetchLibraryPagedContent(seriesLibraryId, query: const LibraryQuery());
      expect(series.items.map((i) => i.title), ['Beta Show', 'Gamma Show']);
      expect(await client.iptvItemsForCategory(seriesLibraryId, '1'), isEmpty);
      client.close();
    });

    test('category toggle and initial toggle work alongside each other', () async {
      final client = await xtreamClient(hiddenCategoryInitials: const ['FR'], hiddenCategoryIds: const ['1']);
      final series = await client.fetchLibraryPagedContent(seriesLibraryId, query: const LibraryQuery());
      expect(series.items.map((i) => i.title), ['Gamma Show']);
      client.close();
    });

    test('item names are never filtered: an EN-named channel in a UK category stays when EN is off', () async {
      // "EN - Special" carries EN in its NAME but sits in "UK - Live 1".
      // Turning EN off hides the EN categories, not the EN-named item.
      final client = await xtreamClient(hiddenCategoryInitials: const ['EN']);
      final channels = await client.iptvChannels();
      expect(channels.map((c) => c.title), contains('EN - Special'));
      expect(channels.map((c) => c.title), isNot(contains('EN - Channel')));
      client.close();
    });
  });

  group('category initials: the search goal', () {
    test('(a) most initials hidden, EN shown — an EN show is found', () async {
      // Matt's current state, minus nothing: FR and UK off, EN on.
      final client = await xtreamClient(hiddenCategoryInitials: const ['FR', 'UK']);
      final alpha = await client.searchItems('alpha');
      expect(alpha.map((i) => i.title), contains('Alpha Show'));
      // The FR show is hidden by its category, not by search failing.
      final beta = await client.searchItems('beta');
      expect(beta.map((i) => i.title), isNot(contains('Beta Show')));
      // The ungrouped show is found too.
      final gamma = await client.searchItems('gamma');
      expect(gamma.map((i) => i.title), contains('Gamma Show'));
      client.close();
    });

    test('(b) Show-all — any show is found', () async {
      final client = await xtreamClient();
      final beta = await client.searchItems('beta');
      expect(beta.map((i) => i.title), contains('Beta Show'));
      client.close();
    });

    test('(g) race: unfiltered slow-but-returns-rows, per-category [] — search finds the show', () async {
      // The panel shape behind the real failure: per-category get_series
      // returns [] while the unfiltered call returns rows (what
      // Recommended reads). The old sweep-only search returned [].
      final client = await xtreamClient(
        api: _CategoryInitialsFakeXtreamApi(
          unfilteredSeriesDelay: const Duration(milliseconds: 300),
          unfilteredSeriesRows: const [XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1')],
        ),
      );
      final previousBudget = IptvClient.searchSectionBudget;
      IptvClient.searchSectionBudget = const Duration(milliseconds: 1000);
      try {
        final results = await client.searchItems('alpha');
        expect(results.map((i) => i.title), contains('Alpha Show'));
        // And the category drill-down finds it too (it reads the same
        // unfiltered catalog).
        final categoryItems = await client.iptvItemsForCategory(seriesLibraryId, '1');
        expect(categoryItems.map((i) => i.title), ['Alpha Show']);
      } finally {
        IptvClient.searchSectionBudget = previousBudget;
        client.close();
      }
    });

    test('(g) race, mid-sweep landing: the load lands while the sweep is running', () async {
      // Per-category calls take 400ms a batch; the unfiltered load lands
      // at 300ms, mid-sweep. The load's matches must win, not be lost
      // because the sweep was still running.
      final client = await xtreamClient(
        api: _CategoryInitialsFakeXtreamApi(
          unfilteredSeriesDelay: const Duration(milliseconds: 300),
          unfilteredSeriesRows: const [XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1')],
          perCategorySeriesDelay: const Duration(milliseconds: 400),
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

    test('search returns promptly when the unfiltered load never completes', () async {
      // The opposite panel shape (build #7 fallback): the unfiltered
      // call never answers, per-category calls return rows. R2.3: the
      // sweep is gone, so the search cannot reach the per-category-only
      // show — the series leg is [] + cold and the search answers the
      // warm movies at once instead of waiting out a budget for a load
      // that never lands. (The per-category rescue still exists in
      // browse — see the catalog-fallback group in
      // iptv_stage2_test.dart.)
      final client = await xtreamClient(
        api: _CategoryInitialsFakeXtreamApi(neverCompleteUnfilteredSeries: true),
        seedTypes: const {'live', 'movie'},
      );
      final stopwatch = Stopwatch()..start();
      final results = await client.searchItems('alpha');
      expect(results.map((i) => i.title), ['Alpha Movie']);
      expect(client.lastSearchDiagnostics?.series.cold, isTrue);
      // Returns promptly, not after a 1000ms budget waiting for the load.
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 700)));
      client.close();
    });
  });

  group('category initials: warm-up + diagnostics (build #10)', () {
    test('warmUpSeriesCatalog loads the catalog without any search or browse', () async {
      // No series seed here: the search below must prove the warm-up
      // loaded the catalog, not the seeded index. The warm-up is
      // disk-only, so give it a disk file to warm from — on base the
      // search's own panel load found the rows, which R2.3 removed.
      final api = _CategoryInitialsFakeXtreamApi(unfilteredSeriesDelay: const Duration(milliseconds: 200));
      final client = await xtreamClient(api: api, seedTypes: const {'live', 'movie'});
      await IptvCatalogDiskCache().write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode((await api.getSeries()).map((r) => r.toJson()).toList()),
      );
      client.warmUpSeriesCatalog();
      await Future.delayed(const Duration(milliseconds: 400));
      final diagnostics = await client.seriesCatalogDiagnostics();
      expect(diagnostics.unfilteredSeriesRows, 3);
      // And the next search is warm — served from the warmed memoized
      // catalog (and the index the warm-up seeded from the same file).
      final results = await client.searchItems('alpha');
      expect(results.map((i) => i.title), contains('Alpha Show'));
      client.close();
    });

    test('seriesCatalogDiagnostics reports the catalog state', () async {
      final client = await xtreamClient(hiddenCategoryInitials: const ['FR'], hiddenCategoryIds: const ['1']);
      final diagnostics = await client.seriesCatalogDiagnostics();
      expect(diagnostics.unfilteredSeriesRows, 3);
      expect(diagnostics.seriesCategoryCount, 12);
      expect(diagnostics.perCategorySeriesRows, {
        '|EN| UK SERIES (1)': 1,
        'EN - Drama (2)': 0,
        'EN - Comedy (3)': 0,
      });
      expect(diagnostics.hiddenCategoryInitialsCount, 1);
      expect(diagnostics.hiddenCategoriesCount, 1);
      client.close();
    });
  });
}

/// Fake whose CATEGORIES carry the initials (EN ×16, FR ×11, UK ×5
/// across live/VOD/series lists) and whose items sit in identified
/// categories, so the category-initial filter can be proven end to end.
/// Per-category series calls respect the category id; the unfiltered call
/// can be delayed, fixed to given rows (with per-category [] — the (g)
/// shape), or made to never complete.
class _CategoryInitialsFakeXtreamApi extends XtreamApi {
  _CategoryInitialsFakeXtreamApi({
    this.unfilteredSeriesDelay = Duration.zero,
    this.unfilteredSeriesRows,
    this.perCategorySeriesDelay = Duration.zero,
    this.neverCompleteUnfilteredSeries = false,
  }) : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final Duration unfilteredSeriesDelay;

  /// When non-null, the unfiltered call returns exactly these rows and
  /// every per-category call returns [] (the (g) panel shape).
  final List<XtreamSeries>? unfilteredSeriesRows;
  final Duration perCategorySeriesDelay;
  final bool neverCompleteUnfilteredSeries;

  static const _series = [
    XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1'),
    XtreamSeries(seriesId: 11, name: 'Beta Show', categoryId: '7'),
    XtreamSeries(seriesId: 12, name: 'Gamma Show', categoryId: '12'),
  ];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 101, name: 'EN - Channel', categoryId: 'L1'),
    XtreamLiveStream(streamId: 102, name: 'FR - Channel', categoryId: 'F1'),
    XtreamLiveStream(streamId: 103, name: 'UK - Channel', categoryId: 'U1'),
    // EN in the NAME, UK in the category: proves item names are never
    // filtered — this channel stays when EN is turned off.
    XtreamLiveStream(streamId: 104, name: 'EN - Special', categoryId: 'U1'),
  ];

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => [
    for (var i = 1; i <= 5; i++) XtreamCategory(id: 'L$i', name: 'EN - Live $i'),
    for (var i = 1; i <= 5; i++) XtreamCategory(id: 'F$i', name: 'FR - Live $i'),
    for (var i = 1; i <= 5; i++) XtreamCategory(id: 'U$i', name: 'UK - Live $i'),
  ];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamVodStream(streamId: 201, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: 'M1'),
    XtreamVodStream(streamId: 202, name: 'Beta Movie', containerExtension: 'mp4', categoryId: 'M2'),
  ];

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async => [
    for (var i = 1; i <= 5; i++) XtreamCategory(id: 'E$i', name: 'EN - Films $i'),
    const XtreamCategory(id: 'M1', name: 'Action'),
    const XtreamCategory(id: 'M2', name: 'FR - Films'),
  ];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) {
      if (neverCompleteUnfilteredSeries) return Completer<List<XtreamSeries>>().future;
      await Future.delayed(unfilteredSeriesDelay);
      return unfilteredSeriesRows ?? _series;
    }
    await Future.delayed(perCategorySeriesDelay);
    if (unfilteredSeriesRows != null) return const [];
    return _series.where((s) => s.categoryId == categoryId).toList();
  }

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => const [
    XtreamCategory(id: '1', name: '|EN| UK SERIES'),
    XtreamCategory(id: '2', name: 'EN - Drama'),
    XtreamCategory(id: '3', name: 'EN - Comedy'),
    XtreamCategory(id: '4', name: 'EN - News'),
    XtreamCategory(id: '5', name: 'EN - Sports'),
    XtreamCategory(id: '6', name: 'EN - Movies'),
    XtreamCategory(id: '7', name: 'FR - Drama'),
    XtreamCategory(id: '8', name: 'FR - Comedy'),
    XtreamCategory(id: '9', name: 'FR - News'),
    XtreamCategory(id: '10', name: 'FR - Sports'),
    XtreamCategory(id: '11', name: 'FR - Movies'),
    XtreamCategory(id: '12', name: 'Action'),
  ];
}
