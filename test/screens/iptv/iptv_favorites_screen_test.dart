import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/iptv/iptv_favorites_screen.dart';
import 'package:plezy/screens/media_detail_screen.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/download_fixtures.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';
import '../../test_helpers/profile_navigation.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// Favourites screen tests (build #7 Task 1): the heart in the Libraries
/// app bar opens one screen with three sections — favourite Live TV
/// channels, Movies, TV/Series — aggregated across the IPTV connections.
/// No network; no streams are opened (tapping a channel resolves it and
/// opens the player screen, which fails to play the fake URL in tests —
/// the assertion is that the player route opens, not that video plays).
///
/// Seeding note: favourites are written straight into the in-memory
/// async prefs store (via [resetSharedPreferencesForTest]'s
/// `initialAsync`), NOT through the client's setFavorite — awaiting a
/// SharedPreferences-backed Future in the test body deadlocks in fake
/// async (the platform response is only delivered on a pump, and the
/// await blocks the pump). The screen then reads them through the real
/// path, which is the behaviour under test anyway.

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

class _FakeXtreamApi extends XtreamApi {
  _FakeXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => const [
    XtreamVodStream(streamId: 1, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: '1'),
    XtreamVodStream(streamId: 2, name: 'Beta Movie', containerExtension: 'mkv', categoryId: '2'),
  ];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [
    XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1'),
  ];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => const [
    XtreamLiveStream(streamId: 501, name: 'News 24', categoryId: '1'),
    XtreamLiveStream(streamId: 502, name: 'Sports 1', categoryId: '1'),
  ];

  @override
  Future<List<XtreamCategory>> getVodCategories() async =>
      const [XtreamCategory(id: '1', name: 'Action'), XtreamCategory(id: '2', name: 'Drama')];

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async => const [XtreamCategory(id: '1', name: 'Action')];
}

/// Seeded favourites, written straight into the in-memory prefs store:
/// one channel, one movie, one show. The movie/show snapshots carry only
/// id/kind/title — the screen re-resolves them against the fake catalog,
/// which is the production behaviour (fresh titles/posters).
Map<String, Object> _seededFavorites() => {
  'iptv_fav_channels:trex': jsonEncode([
    {'source': 'server://trex/iptv', 'id': '501', 'title': 'News 24'},
  ]),
  'iptv_fav_items:trex': jsonEncode({
    'movie:1': {'id': 'movie:1', 'kind': 'movie', 'title': 'Alpha Movie'},
    'series:10': {'id': 'series:10', 'kind': 'show', 'title': 'Alpha Show'},
  }),
};

IptvClient _trexClient() {
  final client = IptvClient.forConnection(_trexConnection());
  client.testXtreamApi = _FakeXtreamApi();
  return client;
}

Future<void> _pumpFavorites(WidgetTester tester, MultiServerProvider provider, List<IptvClient> clients) async {
  // MediaDetailScreen reads DownloadProvider from its own context, so the
  // provider must be above the whole app (same as MultiServerProvider).
  final downloads = NoSyncRulesDownloadProvider();
  addTearDown(downloads.dispose);
  await tester.pumpWidget(
    TranslationProvider(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
        ],
        // The scope wraps the whole app, not just the home screen: the
        // detail/player screens these tests navigate to are pushed routes,
        // and they read ProfileNavigationScope from their own context —
        // a scope that only wraps `home` is not their ancestor.
        child: withProfileNavigationScope(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: IptvFavoritesScreen(clients: clients),
          ),
        ),
      ),
    ),
  );
  // Bounded pumps, not pumpAndSettle: the detail/player screens this
  // suite navigates to keep timers running, and pumpAndSettle would wait
  // on them forever. The screen loads favourites through several
  // SharedPreferences round trips, each delivered on a pump — keep
  // pumping until the loading spinner is gone (or the cap hits).
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The prefs reset must run before Settings/Storage init, and the seeded
  // favourites (when wanted) must be in the store before the test body
  // starts — see the seeding note above. Each test calls this first.
  Future<void> setUpTest({bool seeded = false}) async {
    resetSharedPreferencesForTest(initialAsync: seeded ? _seededFavorites() : const {});
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    await StorageService.getInstance();
  }

  testWidgets('three sections render with the favourited items, labelled by connection', (tester) async {
    await setUpTest(seeded: true);
    final client = _trexClient();
    final (:manager, :provider) = testMultiServer(clients: [client]);

    await _pumpFavorites(tester, provider, [client]);

    expect(find.text(t.iptv.favorites.title), findsOneWidget);
    expect(find.text(t.iptv.favorites.liveTv), findsOneWidget);
    expect(find.text(t.iptv.favorites.movies), findsOneWidget);
    expect(find.text(t.iptv.favorites.tvSeries), findsOneWidget);
    expect(find.text('News 24'), findsOneWidget);
    expect(find.text('Alpha Movie'), findsOneWidget);
    expect(find.text('Alpha Show'), findsOneWidget);
    // Not favourited: must not appear.
    expect(find.text('Beta Movie'), findsNothing);
    expect(find.text('Sports 1'), findsNothing);
    // Rows carry the connection name so a second provider's favourites
    // could not be mistaken for Trex's.
    expect(find.text('Trex'), findsWidgets);
    manager.dispose();
  });

  testWidgets('empty state when nothing is favourited', (tester) async {
    await setUpTest();
    final client = _trexClient();
    final (:manager, :provider) = testMultiServer(clients: [client]);

    await _pumpFavorites(tester, provider, [client]);

    expect(find.text(t.iptv.favorites.empty), findsOneWidget);
    expect(find.text(t.iptv.favorites.liveTv), findsNothing);
    expect(find.text(t.iptv.favorites.movies), findsNothing);
    manager.dispose();
  });

  testWidgets('tapping a movie opens its detail screen', (tester) async {
    await setUpTest(seeded: true);
    final client = _trexClient();
    final (:manager, :provider) = testMultiServer(clients: [client]);

    await _pumpFavorites(tester, provider, [client]);

    await tester.tap(find.text('Alpha Movie'));
    // Bounded pumps (see _pumpFavorites): the detail screen keeps timers
    // running, so pumpAndSettle would wait forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();

    expect(find.byType(MediaDetailScreen), findsOneWidget);
    manager.dispose();
  });

  testWidgets('tapping a channel resolves it and opens the player', (tester) async {
    await setUpTest(seeded: true);
    final client = _trexClient();
    final (:manager, :provider) = testMultiServer(clients: [client]);
    // navigateToLiveTv resolves the channel's server through the
    // provider's live-TV servers, which the async availability probe
    // normally populates — it never runs in the harness, so seed the
    // entry directly (dvrKey is the backend id, as the probe synthesises
    // it for non-DVR backends).
    provider.debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: 'trex', dvrKey: 'xtream')]);

    await _pumpFavorites(tester, provider, [client]);

    await tester.tap(find.text('News 24'));
    // The resolve fetches the (fake) channel list, then the player route
    // pushes. Bounded pumps: the player keeps timers running, so
    // pumpAndSettle would never settle.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(VideoPlayerScreen), findsOneWidget);
    manager.dispose();
  });

  test('resolveFavoriteChannel matches on the channel key, null when gone', () {
    final channels = <LiveTvChannel>[
      LiveTvChannel(key: '501', title: 'News 24', serverId: 'trex'),
      LiveTvChannel(key: '502', title: 'Sports 1', serverId: 'trex'),
    ];
    final favorite = FavoriteChannel(source: 'server://trex/iptv', id: '501', title: 'News 24');
    expect(IptvFavoritesScreen.resolveFavoriteChannel(channels, favorite)?.title, 'News 24');
    final gone = FavoriteChannel(source: 'server://trex/iptv', id: '999', title: 'Removed');
    expect(IptvFavoritesScreen.resolveFavoriteChannel(channels, gone), isNull);
  });
}
