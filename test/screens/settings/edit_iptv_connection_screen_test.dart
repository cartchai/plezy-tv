import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/edit_iptv_connection_screen.dart';
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
  });

  tearDown(() {
    EditIptvConnectionScreen.debugHttpClient = null;
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
    await tester.tap(find.text(t.connections.iptvFilterHideAll));
    await tester.pumpAndSettle();
    expect(tileValue(tester, categoryTile('News')), isFalse);
    expect(tileValue(tester, categoryTile('Sports')), isFalse);
    expect(tileValue(tester, categoryTile('Drama')), isFalse);

    await tester.tap(find.text(t.connections.iptvFilterShowAll));
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
}
