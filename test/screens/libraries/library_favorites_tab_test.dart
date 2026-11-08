import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/screens/libraries/libraries_screen.dart';
import 'package:plezy/screens/libraries/tabs/library_favorites_tab.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_item_favorites_repository.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/library_tab_scaffold.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

const _testPassword = 'pa' 'ss';

final _moviesLibrary = MediaLibrary(
  id: 'iptv:conn-xt-1:movies',
  backend: MediaBackend.xtream,
  title: 'Trex — Movies',
  kind: MediaKind.movie,
  serverId: 'conn-xt-1',
  serverName: 'Trex',
);

final _seriesLibrary = MediaLibrary(
  id: 'iptv:conn-xt-1:series',
  backend: MediaBackend.xtream,
  title: 'Trex — Series',
  kind: MediaKind.show,
  serverId: 'conn-xt-1',
  serverName: 'Trex',
);

final _plexLibrary = MediaLibrary(
  id: 'plex:home-pc:movies',
  backend: MediaBackend.plex,
  title: 'Movies',
  kind: MediaKind.movie,
  serverId: 'home-pc',
  serverName: 'HOME PC',
);

/// Fake Xtream API returning a canned catalog (no network).
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
}

/// In-memory favourites store: the real repo reads SharedPreferences,
/// whose async platform channel never completes inside `testWidgets`'
/// fake async zone when started from a widget load. Persistence is
/// covered by the unit tests in `iptv_item_favorites_test.dart`.
class _InMemoryItemFavoritesRepository implements IptvItemFavoritesRepository {
  Map<String, IptvFavoriteItem> _items = {};

  @override
  Future<Map<String, IptvFavoriteItem>> read({required String key}) async => Map.of(_items);

  @override
  Future<void> write(String key, Map<String, IptvFavoriteItem> items) async {
    _items = Map.of(items);
  }
}

IptvClient _client(_InMemoryItemFavoritesRepository repo) {
  final connection = XtreamConnection(
    id: 'conn-xt-1',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: _testPassword,
    createdAt: DateTime.utc(2026, 11, 5),
  );
  final client = IptvClient.forConnection(connection);
  client.testXtreamApi = _FakeXtreamApi();
  client.testItemFavoritesRepository = repo;
  return client;
}

Future<IptvClient> _pumpTab(
  WidgetTester tester, {
  required MediaLibrary library,
  required _InMemoryItemFavoritesRepository repo,
}) async {
  final client = _client(repo);
  addTearDown(client.close);
  final harness = testMultiServer(clients: [client]);
  await pumpLibraryTab(
    tester,
    provider: harness.provider,
    // A fresh key per pump: without one, re-pumping the same tab type
    // reuses the old State (and its already-loaded items) instead of
    // mounting a fresh tab that reloads from the store.
    tab: LibraryFavoritesTab(key: UniqueKey(), library: library, isActive: true),
  );
  await pumpRequestFrames(tester);
  await tester.pump();
  return client;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    // The catalog disk cache (build #11) is switched off here: its real
    // dart:io never completes in testWidgets' fake async zone, and its
    // behaviour is covered by the unit tests — see `debugDisableDisk`.
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() {
    IptvCatalogDiskCache.debugDisableDisk = false;
  });

  test('Favourites sits after Categories for IPTV, and Plex gets neither', () {
    expect(
      visibleLibraryTabs(_moviesLibrary),
      [
        LibraryTabType.recommended,
        LibraryTabType.browse,
        LibraryTabType.categories,
        LibraryTabType.favorites,
        LibraryTabType.playlists,
      ],
    );
    expect(visibleLibraryTabs(_plexLibrary), isNot(contains(LibraryTabType.favorites)));
    expect(visibleLibraryTabs(_plexLibrary), isNot(contains(LibraryTabType.categories)));
  });

  testWidgets('Movies Favourites tab shows only favourited movies', (tester) async {
    final repo = _InMemoryItemFavoritesRepository();
    await repo.write('iptv_fav_items:conn-xt-1', {
      'movie:1': const IptvFavoriteItem(
        id: 'movie:1',
        kind: 'movie',
        title: 'Alpha Movie',
        libraryId: 'iptv:conn-xt-1:movies',
      ),
      'series:10': const IptvFavoriteItem(
        id: 'series:10',
        kind: 'show',
        title: 'Alpha Show',
        libraryId: 'iptv:conn-xt-1:series',
      ),
    });
    await _pumpTab(tester, library: _moviesLibrary, repo: repo);

    expect(find.text('Alpha Movie'), findsOneWidget);
    expect(find.text('Alpha Show'), findsNothing);
  });

  testWidgets('Series Favourites tab shows only favourited shows', (tester) async {
    final repo = _InMemoryItemFavoritesRepository();
    await repo.write('iptv_fav_items:conn-xt-1', {
      'movie:1': const IptvFavoriteItem(
        id: 'movie:1',
        kind: 'movie',
        title: 'Alpha Movie',
        libraryId: 'iptv:conn-xt-1:movies',
      ),
      'series:10': const IptvFavoriteItem(
        id: 'series:10',
        kind: 'show',
        title: 'Alpha Show',
        libraryId: 'iptv:conn-xt-1:series',
      ),
    });
    await _pumpTab(tester, library: _seriesLibrary, repo: repo);

    expect(find.text('Alpha Show'), findsOneWidget);
    expect(find.text('Alpha Movie'), findsNothing);
  });

  testWidgets('empty Favourites tab explains the long-press gesture', (tester) async {
    await _pumpTab(tester, library: _moviesLibrary, repo: _InMemoryItemFavoritesRepository());

    expect(find.text(t.libraries.noFavorites), findsOneWidget);
    expect(find.text('Alpha Movie'), findsNothing);
  });

  testWidgets('removing a favourite takes it off the tab', (tester) async {
    final repo = _InMemoryItemFavoritesRepository();
    const movie = MediaItem.xtream(
      id: 'movie:1',
      kind: MediaKind.movie,
      title: 'Alpha Movie',
      libraryId: 'iptv:conn-xt-1:movies',
    );
    final client = await _pumpTab(tester, library: _moviesLibrary, repo: repo);
    expect(find.text(t.libraries.noFavorites), findsOneWidget);

    // The long-press path: setFavorite writes, and the tab picks it up
    // on its next load with no restart.
    await client.setFavorite(movie, true);
    await _pumpTab(tester, library: _moviesLibrary, repo: repo);
    expect(find.text('Alpha Movie'), findsOneWidget);

    await client.setFavorite(movie, false);
    await _pumpTab(tester, library: _moviesLibrary, repo: repo);
    expect(find.text('Alpha Movie'), findsNothing);
    expect(find.text(t.libraries.noFavorites), findsOneWidget);
  });
}
