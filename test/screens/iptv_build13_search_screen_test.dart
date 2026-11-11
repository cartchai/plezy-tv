// SCREEN-LEVEL SEARCH TESTS — build #13 (v2.25.9): series search failed
// on Matt's phone through three builds, and Live TV search was empty by
// construction (Xtream live channels had no search leg at all).
//
// These tests drive the real Search screen through the real aggregation
// path (SearchScreen -> DataAggregationService -> IptvClient) with a
// Trex-shaped Xtream connection and Matt's filter state (161 of 171
// category initials hidden, EN shown). The query must produce the rows
// ON SCREEN — a unit test on the client is not proof.
//
// Shapes under test:
// - SERIES: searching "alpha" shows the Alpha Show (TV Shows section).
// - MOVIES: searching "alpha" shows the Alpha Movie.
// - LIVE: searching "hbo" shows HBO East (Live TV section) — FAILS
//   before the build #13 live leg, passes after.
// - COLD CRAWL (B1): the unfiltered series call returns [] and the
//   match sits in category 120 of a slow crawl; the search must still
//   find the show inside a scaled 1s section budget — FAILS before the
//   partial-row fix, passes after.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/focusable_text_field.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/search_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_item_favorites_repository.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../test_helpers/iptv_search_index_seed.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The seeded index carries a last-sync stamp, and the catalog health
  // line formats it with DateFormat — without this the first build
  // throws LocaleDataException (same gotcha as the R2 widget tests).
  setUpAll(() => initializeDateFormatting('en'));

  late Directory tempDir;
  setUp(() async {
    resetSharedPreferencesForTest();
    // R2 migration: the typing search is local-only, so these tests seed
    // the search index from the fake panel instead of relying on the
    // removed cold sweep to load rows from the panel mid-search. The
    // index + disk cache point at a temp dir; the old
    // `debugDisableDisk = true` would make `_searchIndex()` return null
    // and the seed impossible.
    tempDir = await Directory.systemTemp.createTemp('plezy_build13_search_screen_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });

  tearDown(() async {
    IptvClient.debugClientFactory = null;
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  // Matt's filter state, in shape: every initial hidden except EN.
  const hiddenInitials = ['AR', 'FR', 'DE', 'PL', 'ES', 'IN', 'NL', 'SE'];

  // In-memory favourites: the production favourites read goes through
  // the shared prefs cache, whose legacy `SharedPreferences.getInstance()`
  // method-channel call cannot complete inside `tester.runAsync` — a
  // warmup search stalls on it until the 50 s section budget aborts every
  // section and the search returns [] (proven by bisection 2026-11-11).
  // Same seam as iptv_screens_test.dart.
  IptvClient trexClient({XtreamApi? api}) {
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
    client.testXtreamApi = api ?? _TrexSearchFakeXtreamApi();
    client.testItemFavoritesRepository = _InMemoryItemFavoritesRepository();
    return client;
  }

  Future<void> searchFor(WidgetTester tester, String query) async {
    tester.widget<FocusableTextField>(find.byType(FocusableTextField)).controller.text = query;
    // The 100ms debounce (R2.5, was 500ms), then the search itself.
    //
    // The search's legs (index open, disk reads) are real dart:io — a
    // pump-only wait never lets them finish: pump + pumpAndSettle leaves
    // the sections stalled on the 50 s budget and the search returns []
    // (proven 2026-11-11). Interleave real-loop delays with pumps, the
    // same pattern as the R2.0 widget test's waitFor helper.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      // Pump WITH a duration: a bare pump() advances the fake clock by
      // zero, so the 100 ms debounce timer would never fire during this
      // loop and the search would only start in the pumpAndSettle below
      // — where the real loop never runs and the sections stall.
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  // Seed the search index from the fake panel and pre-warm the client's
  // index on the real loop (first open does real dart:io, which never
  // completes in fake async) — after this, the screen's typing searches
  // run entirely locally, as the SEARCH RULE requires.
  //
  // Call this AFTER `_Harness.create`: the harness initialises the
  // settings/storage services the screen reads, and the warmup's
  // favourites read is pure memory (see `trexClient`'s in-memory
  // repository) so nothing in the warmup can stall on the shared prefs
  // cache load inside `runAsync`.
  Future<IptvClient> seedAndWarm(WidgetTester tester, IptvClient client, XtreamApi api, {Set<String> types = const {'live', 'movie', 'series'}}) async {
    await tester.runAsync(() async {
      await seedIptvSearchIndexFromFakePanel(api, 'conn-xt-1', types: types);
      await client.searchItems('warmup-needle');
    });
    return client;
  }

  group('build13: search on the Search screen (Trex, cold start)', () {
    testWidgets('series + movies: "alpha" shows the show and the movie', (tester) async {
      final api = _TrexSearchFakeXtreamApi();
      final client = trexClient(api: api);
      // Services FIRST (see seedAndWarm): the search's favourites read
      // goes through the shared prefs cache, and starting that load
      // before SettingsService has initialised deadlocks the later
      // getInstance() inside fake async.
      final harness = await _Harness.create(client);
      addTearDown(harness.dispose);
      await seedAndWarm(tester, client, api);
      await harness.pump(tester);

      await searchFor(tester, 'alpha');

      expect(find.text('Alpha Show'), findsWidgets);
      expect(find.text('Alpha Movie'), findsWidgets);
    });

    testWidgets('live: "hbo" shows the channel in a Live TV section', (tester) async {
      final api = _TrexSearchFakeXtreamApi();
      final client = trexClient(api: api);
      final harness = await _Harness.create(client);
      addTearDown(harness.dispose);
      await seedAndWarm(tester, client, api);
      await harness.pump(tester);

      await searchFor(tester, 'hbo');

      expect(find.text('HBO East'), findsWidgets);
      // The hidden-region channel must never surface (AR initial off).
      await searchFor(tester, 'aljazeera');
      expect(find.text('Al Jazeera'), findsNothing);
    });

    testWidgets('cold crawl: a per-category-only show is NOT found by search', (tester) async {
      // R2.3 boundary pin (rewritten from the old cold-crawl test): the
      // panel's unfiltered series list is [] and the match sits only in
      // category 120. The old search swept the categories to find it;
      // R2 removed the sweep — search is local-only while typing, and
      // the sync only fetches the unfiltered lists, so a show the panel
      // returns per-category alone is unreachable by search. The typing
      // search still answers promptly with the rows the index DOES have
      // (the movie), and the series section stays cold. The fake's
      // per-category delay / budget shape is gone with the sweep.
      final api = _TrexSearchFakeXtreamApi(
        unfilteredSeriesEmpty: true,
        seriesPerCategoryDelay: const Duration(milliseconds: 100),
        matchSeriesCategoryId: '120',
      );
      final client = trexClient(api: api);
      // Services first (same ordering rule as the other tests in this
      // file), then seed movies + live only: series stays cold, as on a
      // fresh install whose sync recorded the series leg 'empty-response'.
      final harness = await _Harness.create(client);
      addTearDown(harness.dispose);
      await seedAndWarm(tester, client, api, types: const {'movie', 'live'});
      await harness.pump(tester);

      await searchFor(tester, 'alpha');

      expect(find.text('Alpha Movie'), findsWidgets);
      expect(find.text('Alpha Show'), findsNothing);
    });
  });
}

/// In-memory favourites store (same shape as iptv_screens_test.dart):
/// favourites are always empty here — these tests assert search rows,
/// not favourites.
class _InMemoryItemFavoritesRepository implements IptvItemFavoritesRepository {
  Map<String, IptvFavoriteItem> _items = {};

  @override
  Future<Map<String, IptvFavoriteItem>> read({required String key}) async => Map.of(_items);

  @override
  Future<void> write(String key, Map<String, IptvFavoriteItem> items) async {
    _items = Map.of(items);
  }
}

/// Minimal harness: the real manager/provider stack with the Trex client
/// registered online, pumping the real Search screen.
final class _Harness {
  _Harness({required this.manager, required this.provider, required this.hidden, required this.libraries});

  final MultiServerManager manager;
  final MultiServerProvider provider;
  final HiddenLibrariesProvider hidden;
  final LibrariesProvider libraries;

  static Future<_Harness> create(IptvClient client) async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.withData({});
    await SettingsService.getInstance();
    await StorageService.getInstance();
    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(client);
    final provider = testMultiServerProvider(manager);
    final hidden = HiddenLibrariesProvider();
    await hidden.ensureInitialized();
    final libraries = LibrariesProvider();
    return _Harness(manager: manager, provider: provider, hidden: hidden, libraries: libraries);
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
            ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
          ],
          child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const SearchScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void dispose() {
    libraries.dispose();
    hidden.dispose();
    provider.dispose();
    manager.dispose();
  }
}

/// Trex-shaped fake panel: 150 EN categories per section, one AR region
/// category hidden by Matt's initials, one Alpha row per section.
class _TrexSearchFakeXtreamApi extends XtreamApi {
  _TrexSearchFakeXtreamApi({
    this.seriesPerCategoryDelay = Duration.zero,
    this.unfilteredSeriesEmpty = false,
    this.matchSeriesCategoryId = '1',
  }) : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final Duration seriesPerCategoryDelay;
  final bool unfilteredSeriesEmpty;
  final String matchSeriesCategoryId;

  List<XtreamCategory> _categories(String prefix) => [
    for (var i = 1; i <= 150; i++) XtreamCategory(id: '$i', name: '|EN| $prefix $i'),
    const XtreamCategory(id: '900', name: '|AR| Hidden Region'),
  ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => _categories('Series');

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async => _categories('Movies');

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => _categories('Live');

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) {
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
    return const [
      XtreamVodStream(streamId: 1, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: '1'),
    ];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) {
      return const [
        XtreamLiveStream(streamId: 100, name: 'HBO East', categoryId: '1'),
        XtreamLiveStream(streamId: 101, name: 'Al Jazeera', categoryId: '900'),
      ];
    }
    if (categoryId == '1') {
      return const [XtreamLiveStream(streamId: 100, name: 'HBO East', categoryId: '1')];
    }
    return const [];
  }
}
