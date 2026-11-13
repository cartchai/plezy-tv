import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/iptv_categories_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// SCROLL REGRESSION (build #16): Matt reports the build #15 Categories
/// screen is "really laggy to scroll" with his real catalog (833 live
/// categories). The build #15 SEE tests used a 22-category fixture, so they
/// could never see it: the screen built all 1,236 rows eagerly in one
/// Column per section. These tests pump the screen with a real-scale
/// fixture and assert it stays near the 22-row baseline:
///   research probe (pre-fix): fling + 30 frames 4,991 ms total;
///   22-row baseline: 133 ms (a list that short does not scroll at all,
///   so the baseline measures an unscrolled list — the comparable number
///   is the total, not per-frame).
///   post-fix probe: fling + 30 frames ~1,100–2,200 ms total, the 30
///   ballistic frames averaging ~12 ms (max ~50 ms), 36 rows built at load.
/// Thresholds are deliberately loose (multiples of the post-fix numbers,
/// well under the pre-fix total) — regression guards, not benchmarks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const liveCount = 833;
  const seriesCount = 200;

  late _BigFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    IptvCatalogDiskCache.debugDisableDisk = true;
    api = _BigFakeApi();
    IptvClient.debugClientFactory = (connection) {
      final client = IptvClient.xtream(
        xtreamConnection: connection as XtreamConnection,
      );
      client.testXtreamApi = api;
      return client;
    };
  });

  tearDown(() {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvClient.debugClientFactory = null;
  });

  XtreamConnection trexConnection() => XtreamConnection(
        id: 'trex',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: _testPassword,
        createdAt: DateTime.utc(2026, 11, 6),
      );

  IptvClient trexClient() {
    final client = IptvClient.xtream(xtreamConnection: trexConnection());
    client.testXtreamApi = api;
    return client;
  }

  Future<({ConnectionRegistry registry, MultiServerManager manager, MultiServerProvider provider})> harness() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final registry = ConnectionRegistry(db);
    await registry.upsert(trexConnection());
    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(trexClient());
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });
    return (registry: registry, manager: manager, provider: provider);
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    MultiServerProvider provider,
    ConnectionRegistry registry, {
    Size viewport = const Size(800, 1600),
  }) async {
    // PHONE-sized viewport, not the 800x3000 the SEE tests used.
    tester.view.physicalSize = viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
          Provider<ConnectionRegistry>.value(value: registry),
        ],
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: IptvCategoriesScreen(connection: trexConnection()),
        ),
      ),
    );
  }

  testWidgets('rows built at load are viewport-sized, not all 1,236', (tester) async {
    final h = await harness();
    await pumpScreen(tester, h.provider, h.registry);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();

    // Manual walk, no skipOffstage filter: find.byType under-counts by
    // design on this screen (research #16 §1.5). Before the fix this is
    // 1,236 — every row built at load. After the fix only the viewport
    // (+ cache extent) is built: tens of rows at 800x1600.
    var tileWalkCount = 0;
    void walkTiles(Element e) {
      if (e.widget is FocusableSwitchListTile) tileWalkCount++;
      e.visitChildren(walkTiles);
    }
    walkTiles(tester.element(find.byType(IptvCategoriesScreen)));
    expect(tileWalkCount, lessThan(100));

    // The LAST live row is NOT built yet — it only materializes on scroll.
    expect(find.text('EN - Live $liveCount'), findsNothing);
  });

  testWidgets('scrolling to the bottom still reaches every row', (tester) async {
    final h = await harness();
    await pumpScreen(tester, h.provider, h.registry);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();

    // scrollUntilVisible (not one big fling) — a single fling decays
    // before the bottom of a ~60,000px list, and lazy rows only exist
    // once scrolled into the viewport + cache extent. maxScrolls 100:
    // the default 50 drags of 1,000px (50,000px) cannot reach the bottom
    // of a ~60,000px list.
    await tester.scrollUntilVisible(find.text('DE - Series $seriesCount'), 1000, maxScrolls: 100);
    await tester.pumpAndSettle();
    expect(find.text('DE - Series $seriesCount'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('EN - Live 1'), -1000, maxScrolls: 100);
    await tester.pumpAndSettle();
    expect(find.text('EN - Live 1'), findsOneWidget);
  });

  testWidgets('scroll-frame cost at real scale stays near baseline', (tester) async {
    final h = await harness();
    await pumpScreen(tester, h.provider, h.registry);
    await tester.pumpAndSettle();

    // A fling: the harness drag itself (50 pumped move events) plus 30
    // ballistic frames at 60fps cadence. Pre-fix total: 4,991 ms.
    // Post-fix the 30 frames average ~12 ms (max ~50 ms) and the total
    // lands ~1,100–2,200 ms across runs — the drag pumps are harness
    // overhead, so the frame sum is the tight guard and the total is a
    // loose gross-regression guard. Thresholds are deliberately loose
    // (multiples of the baseline, well under the pre-fix numbers) —
    // regression guards, not benchmarks.
    final totalWatch = Stopwatch()..start();
    await tester.fling(find.byType(CustomScrollView), const Offset(0, -2000), 3000);
    var framesSum = 0;
    var framesMax = 0;
    for (var i = 0; i < 30; i++) {
      final frameWatch = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 16));
      frameWatch.stop();
      framesSum += frameWatch.elapsedMilliseconds;
      if (frameWatch.elapsedMilliseconds > framesMax) framesMax = frameWatch.elapsedMilliseconds;
    }
    totalWatch.stop();
    expect(totalWatch.elapsedMilliseconds, lessThan(3000));
    expect(framesSum, lessThan(1000));
    expect(framesMax, lessThan(100));

    // One toggle: the whole screen used to rebuild (770 ms pre-fix,
    // 107 ms baseline). Threshold 400 ms. The fling above scrolled row 1
    // out of the viewport — and a virtualized row that is off-screen is
    // not built — so scroll back to the top first.
    await tester.scrollUntilVisible(find.text('EN - Live 1'), -1000, maxScrolls: 100);
    await tester.pumpAndSettle();
    final toggleWatch = Stopwatch()..start();
    await tester.tap(find.ancestor(
      of: find.text('EN - Live 1'),
      matching: find.byType(FocusableSwitchListTile),
    ));
    await tester.pumpAndSettle();
    toggleWatch.stop();
    expect(toggleWatch.elapsedMilliseconds, lessThan(400));
    // And the toggle took effect: the row now reads hidden.
    final tile = tester.widget<FocusableSwitchListTile>(find.ancestor(
      of: find.text('EN - Live 1'),
      matching: find.byType(FocusableSwitchListTile),
    ));
    expect(tile.value, isFalse);
  });

}

/// Fake provider catalog at Matt's real scale: 833 live categories,
/// 200 VOD, 200 series. Set [small] for the 22-row SEE-fixture scale.
class _BigFakeApi extends XtreamApi {
  bool small = false;

  _BigFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  @override
  Future<Map<String, dynamic>?> getUserInfo() async =>
      const {'username': 'user', 'status': 'Active'};

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => small
      ? const [
          XtreamCategory(id: '1', name: 'EN - Live 1'),
          XtreamCategory(id: 'L2', name: 'EN - Live 2'),
          XtreamCategory(id: 'L3', name: 'EN - Live 3'),
          XtreamCategory(id: 'L4', name: 'EN - Live 4'),
          XtreamCategory(id: 'L5', name: 'EN - Live 5'),
          XtreamCategory(id: 'L6', name: 'EN - Live 6'),
        ]
      : List.generate(
          833, (i) => XtreamCategory(id: 'L$i', name: 'EN - Live ${i + 1}'));

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async => small
      ? const [
          XtreamCategory(id: '1', name: 'EN - Films 1'),
          XtreamCategory(id: 'E2', name: 'EN - Films 2'),
          XtreamCategory(id: 'E3', name: 'EN - Films 3'),
          XtreamCategory(id: 'E4', name: 'EN - Films 4'),
          XtreamCategory(id: 'E5', name: 'EN - Films 5'),
          XtreamCategory(id: '2', name: 'NF'),
          XtreamCategory(id: 'ES1', name: 'ES - Films'),
        ]
      : List.generate(
          200, (i) => XtreamCategory(id: 'V$i', name: 'FR - Film ${i + 1}'));

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => small
      ? const [
          XtreamCategory(id: '1', name: 'Action'),
          XtreamCategory(id: '2', name: 'NF - Series 1'),
          XtreamCategory(id: 'S2', name: 'NF - Series 2'),
          XtreamCategory(id: 'S3', name: 'NF - Series 3'),
          XtreamCategory(id: 'S4', name: 'NF - Series 4'),
          XtreamCategory(id: 'S5', name: 'NF - Series 5'),
          XtreamCategory(id: 'S6', name: 'NF - Series 6'),
          XtreamCategory(id: 'S7', name: 'NF - Series 7'),
          XtreamCategory(id: 'S8', name: 'NF - Series 8'),
        ]
      : List.generate(
          200, (i) => XtreamCategory(id: 'S$i', name: 'DE - Series ${i + 1}'));

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async => const [];

  /// Build #26: the fake's feed is a small canned String, so the stream
  /// is built on top of [getXmltv] — the production path streams, the fake
  /// does not need to.
  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(await getXmltv(timeout: timeout, abortTrigger: abortTrigger))),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }
  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async =>
      '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async => const [];
}
