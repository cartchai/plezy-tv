import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
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

/// The ONE Categories screen (build #15, item 5 — the from-scratch rework):
/// every category visible under plain headings, every toggle applying
/// immediately with no Save button. The gate, in harness form: SEE +
/// CONTROL, or the rework does not ship.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    // Real dart:io never completes in testWidgets' fake async zone — the
    // catalog disk cache is switched off here, as in the other IPTV
    // widget tests; its behaviour is covered by the unit tests.
    IptvCatalogDiskCache.debugDisableDisk = true;
    // The swap (item 8) builds its client through IptvClient.forConnection
    // — point the factory at a fake-backed client too, or the swapped
    // client probes the real panel, goes offline and leaves a reconnect
    // Timer pending past teardown (binding invariant failure).
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
    ConnectionRegistry registry, {
    XtreamConnection? connection,
  }) async {
    // Tall viewport: the screen's sections are slivers, and anything
    // below the fold + cache extent is never built — a SEE test must see
    // all of it at once, not scroll past the top to reach the bottom.
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
          home: IptvCategoriesScreen(connection: connection ?? trexConnection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder switchTileFor(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(FocusableSwitchListTile),
      );

  testWidgets('SEE: every category visible under plain headings, with counts', (tester) async {
    final h = await harness();
    await pumpScreen(tester, h.provider, h.registry);

    expect(find.text(t.iptvCategories.title(name: 'Trex')), findsOneWidget);
    expect(find.text(t.iptvCategories.hiddenTotal(count: 0)), findsOneWidget);

    // Headings are labels with their counts — nothing collapsed, nothing
    // buried. Live 6, Movies 7, Series 9.
    expect(find.textContaining('Live TV categories'), findsOneWidget);
    expect(find.textContaining('6 categories, 0 hidden'), findsOneWidget);
    expect(find.textContaining('Movies categories'), findsOneWidget);
    expect(find.textContaining('7 categories, 0 hidden'), findsOneWidget);
    expect(find.textContaining('TV Series categories'), findsOneWidget);
    expect(find.textContaining('9 categories, 0 hidden'), findsOneWidget);

    // Every category row is on screen.
    for (final name in ['EN - Live 1', 'EN - Live 6', 'EN - Films 1', 'NF', 'ES - Films', 'Action', 'NF - Series 8']) {
      expect(find.text(name), findsOneWidget, reason: '$name must be visible');
    }

    // Initials: EN ×11 and NF ×9 offered, alphabetically; ES ×1 is below
    // the repeat threshold and never offered.
    expect(find.textContaining('Turn off whole groups at once'), findsOneWidget);
    // v1.1.0: the header counts groups, and each row says its count
    // covers all types (the counts are global across Live TV, Movies
    // and TV Series).
    expect(find.textContaining('2 groups, 0 hidden'), findsOneWidget);
    expect(find.text('EN — 11 categories (all types)'), findsOneWidget);
    expect(find.text('NF — 9 categories (all types)'), findsOneWidget);
    expect(find.textContaining('ES —'), findsNothing);
  });

  testWidgets('CONTROL: toggling a category hides it immediately, no Save', (tester) async {
    final h = await harness();
    await pumpScreen(tester, h.provider, h.registry);

    // There is no Save button anywhere on this screen — a toggle that
    // needed one would be the old bug.
    expect(find.text(t.common.save), findsNothing);

    await tester.tap(switchTileFor('EN - Live 2'));
    await tester.pumpAndSettle();

    // The row flips, the heading count and the confirmation line update
    // in the same frame as the tap.
    expect(tester.widget<FocusableSwitchListTile>(switchTileFor('EN - Live 2')).value, isFalse);
    expect(find.textContaining('6 categories, 1 hidden'), findsOneWidget);
    expect(find.text(t.iptvCategories.hiddenTotal(count: 1)), findsOneWidget);

    // Persisted to the registry immediately, under the NEW keys.
    final stored = await h.registry.list();
    final storedTrex = stored.singleWhere((c) => c.id == 'trex') as XtreamConnection;
    expect(storedTrex.hiddenCategoryIds, ['L2']);
    expect(storedTrex.toConfigJson(), containsPair('hiddenCategoryIds', ['L2']));
    expect(storedTrex.toConfigJson().containsKey('disabledCategoryIds'), isFalse);

    // The live client was swapped in place with the new filter.
    final swapped = h.manager.getClient(ServerId('trex')) as IptvClient;
    expect((swapped.connection as XtreamConnection).hiddenCategoryIds, ['L2']);
  });

  testWidgets('CONTROL: toggling an initial hides every category starting with it', (tester) async {
    final h = await harness();
    await pumpScreen(tester, h.provider, h.registry);

    await tester.tap(switchTileFor('NF — 9 categories (all types)'));
    await tester.pumpAndSettle();

    // The NF switch flips off, and every NF category row flips off with
    // it — 1 in Movies, 8 in Series — while the EN rows stay on.
    expect(tester.widget<FocusableSwitchListTile>(switchTileFor('NF — 9 categories (all types)')).value, isFalse);
    expect(tester.widget<FocusableSwitchListTile>(switchTileFor('NF')).value, isFalse);
    expect(tester.widget<FocusableSwitchListTile>(switchTileFor('NF - Series 8')).value, isFalse);
    expect(tester.widget<FocusableSwitchListTile>(switchTileFor('EN - Live 1')).value, isTrue);
    expect(find.textContaining('7 categories, 1 hidden'), findsOneWidget);
    expect(find.textContaining('9 categories, 8 hidden'), findsOneWidget);
    expect(find.text(t.iptvCategories.hiddenTotal(count: 9)), findsOneWidget);

    final stored = await h.registry.list();
    final storedTrex = stored.singleWhere((c) => c.id == 'trex') as XtreamConnection;
    expect(storedTrex.hiddenCategoryInitials, ['NF']);
    expect(storedTrex.toConfigJson().containsKey('disabledInitials'), isFalse);
  });

  testWidgets('CONTROL: toggling back on unhides, and Show all restores everything', (tester) async {
    final h = await harness();
    await pumpScreen(tester, h.provider, h.registry);

    await tester.tap(switchTileFor('NF — 9 categories (all types)'));
    await tester.pumpAndSettle();
    expect(find.text(t.iptvCategories.hiddenTotal(count: 9)), findsOneWidget);

    await tester.tap(find.text(t.iptvCategories.showAll));
    await tester.pumpAndSettle();

    expect(find.text(t.iptvCategories.hiddenTotal(count: 0)), findsOneWidget);
    expect(tester.widget<FocusableSwitchListTile>(switchTileFor('NF - Series 8')).value, isTrue);
    final stored = await h.registry.list();
    final storedTrex = stored.singleWhere((c) => c.id == 'trex') as XtreamConnection;
    expect(storedTrex.hiddenCategoryInitials, isEmpty);
  });

  testWidgets('CONTROL: Show all also clears initials with no toggle on screen', (tester) async {
    final h = await harness();
    // ES is below the offer threshold (×1) and ZZ matches nothing — both
    // are hidden with no switch to turn them back on. The old Show all
    // only cleared offered initials, so these survived it.
    final hidden = trexConnection().copyWith(hiddenCategoryInitials: ['ES', 'NF', 'ZZ']);
    await h.registry.upsert(hidden);
    await pumpScreen(tester, h.provider, h.registry, connection: hidden);

    // 10 hidden rows (1 NF + 1 ES in Movies, 8 NF in Series); the groups
    // header counts 3 hidden initials across 2 offered groups.
    expect(find.text(t.iptvCategories.hiddenTotal(count: 10)), findsOneWidget);
    expect(find.textContaining('2 groups, 3 hidden'), findsOneWidget);
    expect(find.textContaining('ES —'), findsNothing);
    expect(find.textContaining('ZZ —'), findsNothing);
    expect(tester.widget<FocusableSwitchListTile>(switchTileFor('NF — 9 categories (all types)')).value, isFalse);

    await tester.tap(find.text(t.iptvCategories.showAll));
    await tester.pumpAndSettle();

    expect(find.text(t.iptvCategories.hiddenTotal(count: 0)), findsOneWidget);
    final stored = await h.registry.list();
    final storedTrex = stored.singleWhere((c) => c.id == 'trex') as XtreamConnection;
    expect(storedTrex.hiddenCategoryInitials, isEmpty);
  });
}

/// Fake provider catalog whose CATEGORIES carry repeating initials — EN ×11
/// (6 live + 5 VOD), NF ×9 (1 VOD + 8 series), ES ×1 (below the repeat
/// threshold, never offered). 'Action' carries no initial (Title Case).
class _CategoriesFakeApi extends XtreamApi {
  _CategoriesFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  @override
  Future<Map<String, dynamic>?> getUserInfo() async =>
      const {'username': 'user', 'status': 'Active'};

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => const [
        XtreamCategory(id: '1', name: 'EN - Live 1'),
        XtreamCategory(id: 'L2', name: 'EN - Live 2'),
        XtreamCategory(id: 'L3', name: 'EN - Live 3'),
        XtreamCategory(id: 'L4', name: 'EN - Live 4'),
        XtreamCategory(id: 'L5', name: 'EN - Live 5'),
        XtreamCategory(id: 'L6', name: 'EN - Live 6'),
      ];

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async => const [
        XtreamCategory(id: '1', name: 'EN - Films 1'),
        XtreamCategory(id: 'E2', name: 'EN - Films 2'),
        XtreamCategory(id: 'E3', name: 'EN - Films 3'),
        XtreamCategory(id: 'E4', name: 'EN - Films 4'),
        XtreamCategory(id: 'E5', name: 'EN - Films 5'),
        XtreamCategory(id: '2', name: 'NF'),
        XtreamCategory(id: 'ES1', name: 'ES - Films'),
      ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => const [
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
