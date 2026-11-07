import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/screens/settings/edit_iptv_connection_screen.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/focusable_list_tile.dart';

import '../../test_helpers/prefs.dart';

/// Edit-screen tests for the separated categories (build #6, Task D).
///
/// The screen fetches categories over HTTP, so the tests point its
/// `debugHttpClient` seam at a MockClient: three category endpoints for
/// Xtream (note id '1' appears in all three lists — the shared-disabled-
/// set proof) and a playlist with two groups for M3U. No real sockets:
/// real socket I/O does not survive the widget test binding's faked
/// timers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    EditIptvConnectionScreen.debugHttpClient = MockClient((request) async {
      final action = request.url.queryParameters['action'];
      if (request.url.path == '/player_api.php' && action != null) {
        final categories = switch (action) {
          'get_live_categories' => [
            {'category_id': '1', 'category_name': 'News'},
            {'category_id': '2', 'category_name': 'Sports'},
          ],
          'get_vod_categories' => [
            {'category_id': '1', 'category_name': 'Action'},
            {'category_id': '3', 'category_name': 'Drama'},
          ],
          'get_series_categories' => [
            {'category_id': '1', 'category_name': 'Action'},
            {'category_id': '4', 'category_name': 'Comedy'},
          ],
          _ => <Map<String, String>>[],
        };
        return http.Response(jsonEncode(categories), 200);
      }
      if (request.url.path == '/playlist.m3u') {
        return http.Response(
          '#EXTM3U\n'
          '#EXTINF:-1 tvg-id="a1" group-title="News",Channel A\n'
          'http://example.com/a.m3u8\n'
          '#EXTINF:-1 tvg-id="a2" group-title="Sports",Channel B\n'
          'http://example.com/b.m3u8\n'
          '#EXTINF:-1 tvg-id="a3" group-title="News",Channel C\n'
          'http://example.com/c.m3u8\n',
          200,
        );
      }
      return http.Response('not found', 404);
    });
    // The initials checklist creates its own client via forConnection — the
    // factory seam points it at a fake-backed client (EN ×11, NF ×9), so
    // the section can be tested without the network. M3U connections get a
    // plain client (their playlist fetch fails in tests, as it would for a
    // real unreachable playlist, and the checklist shows its failed state).
    IptvClient.debugClientFactory = (connection) {
      if (connection is XtreamConnection) {
        final client = IptvClient.xtream(xtreamConnection: connection);
        client.testXtreamApi = _InitialsFakeXtreamApi();
        return client;
      }
      return IptvClient.m3u(m3uConnection: connection as M3uConnection);
    };
  });

  tearDown(() {
    EditIptvConnectionScreen.debugHttpClient = null;
    IptvClient.debugClientFactory = null;
  });

  XtreamConnection trexConnection() => XtreamConnection(
    id: 'trex',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: 'pass',
    createdAt: DateTime.utc(2026, 11, 6),
  );

  M3uConnection m3uConnection() => M3uConnection(
    id: 'm3u1',
    name: 'Test M3U',
    playlistUrl: 'https://example.com/playlist.m3u',
    createdAt: DateTime.utc(2026, 11, 6),
  );

  Future<void> pumpScreen(WidgetTester tester, Connection connection) async {
    // Tall viewport: the section list is a lazy sliver list, and the tests
    // assert on rows in every section at once.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 2000);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: EditIptvConnectionScreen(connection: connection),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder sectionHeader(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byType(FocusableListTile),
  );

  Finder categoryTile(String name) => find.ancestor(
    of: find.text(name),
    matching: find.byType(FocusableSwitchListTile),
  );

  bool tileValue(WidgetTester tester, Finder tile) =>
      tester.widget<FocusableSwitchListTile>(tile).value;

  testWidgets('Xtream renders Live TV, Movies and TV Series as separate sections', (tester) async {
    await pumpScreen(tester, trexConnection());

    expect(sectionHeader('Live TV'), findsOneWidget);
    expect(sectionHeader('Movies'), findsOneWidget);
    expect(sectionHeader('TV Series'), findsOneWidget);
    expect(find.text('News'), findsOneWidget);
    expect(find.text('Sports'), findsOneWidget);
    // 'Action' lives in both Movies and TV Series.
    expect(find.text('Action'), findsNWidgets(2));
    expect(find.text('Drama'), findsOneWidget);
    expect(find.text('Comedy'), findsOneWidget);
  });

  testWidgets('each section collapses and expands on its own', (tester) async {
    await pumpScreen(tester, trexConnection());

    await tester.tap(sectionHeader('Movies'));
    await tester.pumpAndSettle();
    expect(find.text('Drama'), findsNothing);
    expect(find.text('Action'), findsOneWidget, reason: 'only the TV Series copy remains');
    expect(find.text('News'), findsOneWidget, reason: 'Live TV untouched');
    expect(find.text('Comedy'), findsOneWidget, reason: 'TV Series untouched');

    await tester.tap(sectionHeader('Movies'));
    await tester.pumpAndSettle();
    expect(find.text('Drama'), findsOneWidget);
    expect(find.text('Action'), findsNWidgets(2));
  });

  testWidgets('toggling a shared category id updates every section', (tester) async {
    await pumpScreen(tester, trexConnection());

    // Id '1' is News (Live TV), Action (Movies) and Action (TV Series).
    await tester.tap(categoryTile('News'));
    await tester.pumpAndSettle();

    expect(tileValue(tester, categoryTile('News')), isFalse);
    expect(tileValue(tester, categoryTile('Action').at(0)), isFalse);
    expect(tileValue(tester, categoryTile('Action').at(1)), isFalse);
    expect(tileValue(tester, categoryTile('Drama')), isTrue);
    expect(tileValue(tester, categoryTile('Comedy')), isTrue);

    // Show all / Hide all work across all three sections at once.
    // (There are two "Hide all" buttons on the screen now — the header's
    // and the initials checklist's — so scope to the header's, first.)
    await tester.tap(find.text(t.connections.iptvFilterHideAll).first);
    await tester.pumpAndSettle();
    expect(tileValue(tester, categoryTile('News')), isFalse);
    expect(tileValue(tester, categoryTile('Sports')), isFalse);
    expect(tileValue(tester, categoryTile('Drama')), isFalse);

    await tester.tap(find.text(t.connections.iptvFilterShowAll).first);
    await tester.pumpAndSettle();
    expect(tileValue(tester, categoryTile('News')), isTrue);
    expect(tileValue(tester, categoryTile('Drama')), isTrue);
    expect(tileValue(tester, categoryTile('Action').at(0)), isTrue);
  });

  testWidgets('collapsed state survives leaving the screen', (tester) async {
    await pumpScreen(tester, trexConnection());
    await tester.tap(sectionHeader('Movies'));
    await tester.pumpAndSettle();
    expect(find.text('Drama'), findsNothing);

    // A fresh instance of the screen reads the persisted preference.
    await pumpScreen(tester, trexConnection());
    expect(find.text('Drama'), findsNothing);
    expect(find.text('News'), findsOneWidget);
    expect(find.text('Comedy'), findsOneWidget);
  });

  testWidgets('M3U groups live in a single Groups section', (tester) async {
    await pumpScreen(tester, m3uConnection());

    expect(sectionHeader('Groups'), findsOneWidget);
    expect(find.text('Live TV'), findsNothing);
    expect(find.text('Movies'), findsNothing);
    expect(find.text('TV Series'), findsNothing);
    expect(find.text('News'), findsOneWidget);
    expect(find.text('Sports'), findsOneWidget);
  });

  testWidgets('Category initials section lives with the category groupings (build #8 Task 4, redesigned build #10)', (tester) async {
    await pumpScreen(tester, trexConnection());

    // After the category sections, grouped with them — not a separate
    // screen. Only the initials that keep repeating are offered.
    expect(sectionHeader(t.connections.iptvFilterInitials), findsOneWidget);
    expect(find.text('EN (11)'), findsOneWidget);
    expect(find.text('NF (9)'), findsOneWidget);
    expect(find.textContaining('ES'), findsNothing);

    // Toggling an initial updates only its own switch; the edit screen
    // persists on Save, so this asserts the deferred state, not the
    // registry.
    await tester.tap(categoryTile('NF (9)'));
    await tester.pumpAndSettle();
    expect(tileValue(tester, categoryTile('NF (9)')), isFalse);
    expect(tileValue(tester, categoryTile('EN (11)')), isTrue);

    // The section collapses and expands on its own, like the categories.
    await tester.tap(sectionHeader(t.connections.iptvFilterInitials));
    await tester.pumpAndSettle();
    expect(find.text('NF (9)'), findsNothing);
    expect(find.text('News'), findsOneWidget, reason: 'Live TV untouched');

    await tester.tap(sectionHeader(t.connections.iptvFilterInitials));
    await tester.pumpAndSettle();
    expect(find.text('NF (9)'), findsOneWidget);
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
