import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';
import 'package:plezy/widgets/iptv_initials_checklist.dart';

import '../test_helpers/prefs.dart';

/// Widget tests for the initials checklist (build #8 Task 4, redesigned
/// build #10: category initials).
///
/// The checklist creates its own client via [IptvClient.forConnection], so
/// the tests point the client's `debugClientFactory` seam at a client
/// backed by a fake Xtream catalog — no network. The fake's CATEGORIES
/// carry repeating initials (EN ×11, NF ×9, ES ×1, so only EN and NF are
/// offered); item names are irrelevant to detection now.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    IptvClient.debugClientFactory = (connection) {
      final client = IptvClient.xtream(xtreamConnection: connection as XtreamConnection);
      client.testXtreamApi = _InitialsFakeXtreamApi();
      return client;
    };
  });

  tearDown(() {
    IptvClient.debugClientFactory = null;
  });

  XtreamConnection trexConnection() => XtreamConnection(
    id: 'trex',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: 'pa' 'ss',
    createdAt: DateTime.utc(2026, 11, 6),
  );

  Future<void> pumpChecklist(
    WidgetTester tester, {
    Set<String> disabled = const {},
    required void Function(Set<String> next) onDisabledChanged,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: Scaffold(
              body: IptvInitialsChecklist(
                connection: trexConnection(),
                disabled: disabled,
                onDisabledChanged: onDisabledChanged,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder initialTile(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byType(FocusableSwitchListTile),
  );

  bool tileValue(WidgetTester tester, Finder tile) => tester.widget<FocusableSwitchListTile>(tile).value;

  testWidgets('detected initials render with counts, one-offs never offered', (tester) async {
    await pumpChecklist(tester, onDisabledChanged: (_) {});

    expect(find.text('EN (11)'), findsOneWidget);
    expect(find.text('NF (9)'), findsOneWidget);
    expect(find.textContaining('ES'), findsNothing);
  });

  testWidgets('toggling an initial off reports the new disabled set', (tester) async {
    var reported = <String>{};
    await pumpChecklist(tester, onDisabledChanged: (next) => reported = next);

    await tester.tap(initialTile('NF (9)'));
    await tester.pumpAndSettle();

    expect(reported, {'NF'});
    expect(tileValue(tester, initialTile('EN (11)')), isTrue);
  });

  testWidgets('Hide all / Show all cover every detected initial', (tester) async {
    var reported = <String>{};
    await pumpChecklist(tester, onDisabledChanged: (next) => reported = next);

    await tester.tap(find.text(t.connections.iptvFilterHideAll));
    await tester.pumpAndSettle();
    expect(reported, {'EN', 'NF'});

    await tester.tap(find.text(t.connections.iptvFilterShowAll));
    await tester.pumpAndSettle();
    expect(reported, isEmpty);
  });

  testWidgets('a disabled initial renders switched off', (tester) async {
    await pumpChecklist(tester, disabled: const {'NF'}, onDisabledChanged: (_) {});

    expect(tileValue(tester, initialTile('NF (9)')), isFalse);
    expect(tileValue(tester, initialTile('EN (11)')), isTrue);
  });

  testWidgets('initials list in alphabetical order, not most-common first', (tester) async {
    // UK is the most common here (13) but alphabetically last; EN (11) and
    // FR (8) come first. The counts stay attached to their initial.
    IptvClient.debugClientFactory = (connection) {
      final client = IptvClient.xtream(xtreamConnection: connection as XtreamConnection);
      client.testXtreamApi = _AlphabeticalFakeXtreamApi();
      return client;
    };
    await pumpChecklist(tester, onDisabledChanged: (_) {});

    final tiles = tester.widgetList<FocusableSwitchListTile>(find.byType(FocusableSwitchListTile)).toList();
    final labels = [for (final tile in tiles) (tile.title as Text).data];
    expect(labels, ['EN (11)', 'FR (8)', 'UK (13)']);
  });
}

/// Fake whose CATEGORIES carry repeating initials — EN ×11 (6 live + 5
/// VOD categories), NF ×9 (1 VOD + 8 series categories), ES ×1 (never
/// offered). Item names still carry the old "EN - …" / "NF - …" prefixes
/// on purpose: they must not affect detection.
class _InitialsFakeXtreamApi extends XtreamApi {
  _InitialsFakeXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => [
    for (var i = 1; i <= 5; i++) XtreamLiveStream(streamId: 100 + i, name: 'EN - Channel $i', categoryId: '1'),
    const XtreamLiveStream(streamId: 200, name: 'ES - Channel', categoryId: '1'),
  ];

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
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => [
    for (var i = 1; i <= 5; i++)
      XtreamVodStream(streamId: 300 + i, name: 'EN - Movie $i', containerExtension: 'mp4', categoryId: '1'),
    const XtreamVodStream(streamId: 400, name: 'NF - Movie', containerExtension: 'mp4', categoryId: '2'),
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
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => [
    for (var i = 1; i <= 6; i++) XtreamSeries(seriesId: 500 + i, name: 'NF - Show $i', categoryId: '2'),
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

/// Fake where the most-common order is NOT alphabetical: UK ×13, EN ×11,
/// FR ×8 (category counts). The checklist must still render EN, FR, UK
/// (build #10).
class _AlphabeticalFakeXtreamApi extends XtreamApi {
  _AlphabeticalFakeXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => [
    for (var i = 1; i <= 6; i++) XtreamLiveStream(streamId: 100 + i, name: 'UK - Channel $i', categoryId: '1'),
    for (var i = 1; i <= 5; i++) XtreamLiveStream(streamId: 200 + i, name: 'EN - Channel $i', categoryId: '1'),
  ];

  @override
  Future<List<XtreamCategory>> getLiveCategories() async => const [
    XtreamCategory(id: '1', name: 'UK - Live 1'),
    XtreamCategory(id: 'U2', name: 'UK - Live 2'),
    XtreamCategory(id: 'U3', name: 'UK - Live 3'),
    XtreamCategory(id: 'U4', name: 'UK - Live 4'),
    XtreamCategory(id: 'U5', name: 'UK - Live 5'),
    XtreamCategory(id: 'U6', name: 'UK - Live 6'),
    XtreamCategory(id: 'E1', name: 'EN - Live 1'),
    XtreamCategory(id: 'E2', name: 'EN - Live 2'),
    XtreamCategory(id: 'E3', name: 'EN - Live 3'),
    XtreamCategory(id: 'E4', name: 'EN - Live 4'),
    XtreamCategory(id: 'E5', name: 'EN - Live 5'),
  ];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => [
    for (var i = 1; i <= 6; i++)
      XtreamVodStream(streamId: 300 + i, name: 'UK - Movie $i', containerExtension: 'mp4', categoryId: '1'),
    for (var i = 1; i <= 6; i++)
      XtreamVodStream(streamId: 400 + i, name: 'EN - Movie $i', containerExtension: 'mp4', categoryId: '1'),
  ];

  @override
  Future<List<XtreamCategory>> getVodCategories() async => const [
    XtreamCategory(id: '1', name: 'UK - Films 1'),
    XtreamCategory(id: 'U2', name: 'UK - Films 2'),
    XtreamCategory(id: 'U3', name: 'UK - Films 3'),
    XtreamCategory(id: 'U4', name: 'UK - Films 4'),
    XtreamCategory(id: 'U5', name: 'UK - Films 5'),
    XtreamCategory(id: 'U6', name: 'UK - Films 6'),
    XtreamCategory(id: 'U7', name: 'UK - Films 7'),
    XtreamCategory(id: 'E1', name: 'EN - Films 1'),
    XtreamCategory(id: 'E2', name: 'EN - Films 2'),
    XtreamCategory(id: 'E3', name: 'EN - Films 3'),
    XtreamCategory(id: 'E4', name: 'EN - Films 4'),
    XtreamCategory(id: 'E5', name: 'EN - Films 5'),
    XtreamCategory(id: 'E6', name: 'EN - Films 6'),
    XtreamCategory(id: '2', name: 'FR'),
  ];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => [
    for (var i = 1; i <= 6; i++) XtreamSeries(seriesId: 500 + i, name: 'FR - Show $i', categoryId: '2'),
  ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async => const [
    XtreamCategory(id: '1', name: 'Action'),
    XtreamCategory(id: '2', name: 'FR - Series 1'),
    XtreamCategory(id: 'F2', name: 'FR - Series 2'),
    XtreamCategory(id: 'F3', name: 'FR - Series 3'),
    XtreamCategory(id: 'F4', name: 'FR - Series 4'),
    XtreamCategory(id: 'F5', name: 'FR - Series 5'),
    XtreamCategory(id: 'F6', name: 'FR - Series 6'),
    XtreamCategory(id: 'F7', name: 'FR - Series 7'),
  ];
}
