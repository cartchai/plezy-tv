// FAILING-FIRST — build #17 §4 (v2.25.13): Matt wants to collapse the
// Live TV / Movies / Series sections on the Trex categories screen so
// he can reach the categories he wants faster. No collapse exists yet:
// every section is always fully expanded (1,236 rows on his account).
//
// The fix: tapping a section header collapses it to the header alone
// (SliverList itemCount = 1 — rows simply not built, so the build #16
// virtualization holds), the collapsed header keeps showing its hidden
// count, and the collapsed state persists per connection in
// `iptv_categories_collapsed:<connectionId>` across relaunches.

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

const _testPassword = 'pa' 'ss';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    IptvCatalogDiskCache.debugDisableDisk = true;
    IptvClient.debugClientFactory = (connection) {
      final client = IptvClient.xtream(
        xtreamConnection: connection as XtreamConnection,
      );
      client.testXtreamApi = _CategoriesFakeApi();
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
    client.testXtreamApi = _CategoriesFakeApi();
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
    ConnectionRegistry registry,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
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
    await tester.pumpAndSettle();
  }

  Finder switchTileFor(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byType(FocusableSwitchListTile),
  );

  Finder headerFor(String heading) => find.textContaining(heading);

  group('build17 categories collapse', () {
    testWidgets('tapping the Live TV header collapses it to the header alone', (tester) async {
      final h = await harness();
      await pumpScreen(tester, h.provider, h.registry);

      // Baseline: 6 live + 7 movies + 9 series + 2 initial rows.
      expect(find.byType(FocusableSwitchListTile), findsNWidgets(24));
      expect(find.text('EN - Live 1'), findsOneWidget);

      await tester.tap(headerFor('Live TV categories'));
      await tester.pumpAndSettle();

      // The Live TV rows are gone — the section is header-only — while
      // Movies and Series are untouched.
      expect(find.text('EN - Live 1'), findsNothing);
      expect(find.text('EN - Live 6'), findsNothing);
      expect(find.text('EN - Films 1'), findsOneWidget);
      expect(find.text('NF - Series 8'), findsOneWidget);
      expect(find.byType(FocusableSwitchListTile), findsNWidgets(18));
      // The collapsed header keeps showing its count.
      expect(find.textContaining('Live TV categories'), findsOneWidget);
      expect(find.textContaining('6 categories, 0 hidden'), findsOneWidget);
    });

    testWidgets('collapsed state survives a relaunch, and expanding restores the rows', (tester) async {
      final h = await harness();
      await pumpScreen(tester, h.provider, h.registry);

      await tester.tap(headerFor('Movies categories'));
      await tester.pumpAndSettle();
      expect(find.text('EN - Films 1'), findsNothing);

      // Relaunch: a fresh screen over the same preferences.
      await pumpScreen(tester, h.provider, h.registry);
      expect(find.text('EN - Films 1'), findsNothing);
      expect(find.text('EN - Live 1'), findsOneWidget);
      expect(find.textContaining('7 categories, 0 hidden'), findsOneWidget);

      await tester.tap(headerFor('Movies categories'));
      await tester.pumpAndSettle();
      expect(find.text('EN - Films 1'), findsOneWidget);
      expect(find.byType(FocusableSwitchListTile), findsNWidgets(24));
    });

    testWidgets('toggling an initial while its section is collapsed updates the collapsed header count', (tester) async {
      final h = await harness();
      await pumpScreen(tester, h.provider, h.registry);

      await tester.tap(headerFor('Live TV categories'));
      await tester.pumpAndSettle();
      expect(find.text('EN - Live 1'), findsNothing);

      // EN covers all 6 Live TV categories: turning it off hides them
      // all, and the collapsed header's count follows without expanding.
      await tester.tap(switchTileFor('EN — 11 categories'));
      await tester.pumpAndSettle();

      expect(find.text('EN - Live 1'), findsNothing);
      expect(find.textContaining('6 categories, 6 hidden'), findsOneWidget);
      expect(find.text(t.iptvCategories.hiddenTotal(count: 11)), findsOneWidget);
    });

    testWidgets('collapsing one section never collapses another', (tester) async {
      final h = await harness();
      await pumpScreen(tester, h.provider, h.registry);

      await tester.tap(headerFor('TV Series categories'));
      await tester.pumpAndSettle();

      expect(find.text('NF - Series 8'), findsNothing);
      expect(find.text('EN - Live 1'), findsOneWidget);
      expect(find.text('EN - Films 1'), findsOneWidget);
    });
  });
}

/// Same fake catalog as the categories screen tests: Live 6, Movies 7,
/// Series 9; initials EN ×11, NF ×9.
class _CategoriesFakeApi extends XtreamApi {
  _CategoriesFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  @override
  Future<Map<String, dynamic>?> getUserInfo() async =>
      const {'username': 'user', 'status': 'Active'};

  @override
  Future<List<XtreamCategory>> getLiveCategories() async => const [
    XtreamCategory(id: '1', name: 'EN - Live 1'),
    XtreamCategory(id: 'L2', name: 'EN - Live 2'),
    XtreamCategory(id: 'L3', name: 'EN - Live 3'),
    XtreamCategory(id: 'L4', name: 'EN - Live 4'),
    XtreamCategory(id: 'L5', name: 'EN - Live 5'),
    XtreamCategory(id: 'L6', name: 'EN - Live 6'),
  ];

  @override
  Future<List<XtreamCategory>> getVodCategories() async => const [
    XtreamCategory(id: '1', name: 'EN - Films 1'),
    XtreamCategory(id: 'E2', name: 'EN - Films 2'),
    XtreamCategory(id: 'E3', name: 'EN - Films 3'),
    XtreamCategory(id: 'E4', name: 'EN - Films 4'),
    XtreamCategory(id: 'E5', name: 'EN - Films 5'),
    XtreamCategory(id: '2', name: 'NF'),
    XtreamCategory(id: 'ES1', name: 'ES - Films'),
  ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async => const [
    XtreamCategory(id: '1', name: 'Action'),
    XtreamCategory(id: '2', name: 'NF - Series 1'),
    XtreamCategory(id: 'S2', name: 'NF - Series 2'),
    XtreamCategory(id: 'S3', name: 'NF - Series 3'),
    XtreamCategory(id: 'S4', name: 'NF - Series 4'),
    XtreamCategory(id: 'S5', name: 'NF - Series 5'),
    XtreamCategory(id: 'S6', name: 'NF - Series 6'),
    XtreamCategory(id: 'S7', name: 'NF - Series 7'),
    XtreamCategory(id: 'S8', name: 'NF - Series 8'),
  ];
}
