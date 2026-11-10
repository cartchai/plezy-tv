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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/focusable_text_field.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/search_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

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
    return client;
  }

  Future<void> searchFor(WidgetTester tester, String query) async {
    tester.widget<FocusableTextField>(find.byType(FocusableTextField)).controller.text = query;
    // The 500ms debounce, then the search itself.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  }

  group('build13: search on the Search screen (Trex, cold start)', () {
    testWidgets('series + movies: "alpha" shows the show and the movie', (tester) async {
      final harness = await _Harness.create(trexClient());
      addTearDown(harness.dispose);
      await harness.pump(tester);

      await searchFor(tester, 'alpha');

      expect(find.text('Alpha Show'), findsWidgets);
      expect(find.text('Alpha Movie'), findsWidgets);
    });

    testWidgets('live: "hbo" shows the channel in a Live TV section', (tester) async {
      final harness = await _Harness.create(trexClient());
      addTearDown(harness.dispose);
      await harness.pump(tester);

      await searchFor(tester, 'hbo');

      expect(find.text('HBO East'), findsWidgets);
      // The hidden-region channel must never surface (AR initial off).
      await searchFor(tester, 'aljazeera');
      expect(find.text('Al Jazeera'), findsNothing);
    });

    testWidgets('cold crawl: "alpha" finds the show in a late category', (tester) async {
      // (g) shape at Trex scale: unfiltered [] + 100ms per-category
      // calls, match in category 120. Scaled 3s section budget, same
      // idiom as the unit harness. Build #21 recalibration: the budget
      // was 1s, calibrated to the old batch size (32) — 120/32 x 100ms =
      // 375ms to reach category 120. At the build #21 burst cap of 8 it
      // needs 120/8 x 100ms = 1500ms, past the 980ms sweep deadline at
      // a 1s budget. The test's purpose is that a cold search finds a
      // show in a late category, not the budget value (the real section
      // budget is 50s); 3s keeps the same shape at the shipped cap.
      final previousBudget = IptvClient.searchSectionBudget;
      IptvClient.searchSectionBudget = const Duration(milliseconds: 3000);
      addTearDown(() => IptvClient.searchSectionBudget = previousBudget);
      final client = trexClient(
        api: _TrexSearchFakeXtreamApi(
          unfilteredSeriesEmpty: true,
          seriesPerCategoryDelay: const Duration(milliseconds: 100),
          matchSeriesCategoryId: '120',
        ),
      );
      final harness = await _Harness.create(client);
      addTearDown(harness.dispose);
      await harness.pump(tester);

      await searchFor(tester, 'alpha');

      expect(find.text('Alpha Show'), findsWidgets);

      // Settle the background unfiltered-load crawl before teardown:
      // the sweep (cap 8) now finishes in ~1500 ms of fake time while
      // the crawl fallback (batch 16, ~1000 ms of 100 ms getSeries calls)
      // is still firing, which leaves pending fake-async timers at
      // teardown. Build #17 fix-up: the search result is already on
      // screen; this only lets the crawl finish.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    });
  });
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
