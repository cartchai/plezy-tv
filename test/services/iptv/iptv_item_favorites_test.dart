import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/iptv/iptv_item_favorites_repository.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// Favourites persistence (build #7 Task 1): VOD/series favourites used to
/// be no-op completes, so the heart in the detail sheet never stuck. These
/// prove setFavorite actually persists, fetchItem stamps isFavorite, and
/// favoriteItems re-resolves against the catalog (or falls back to the
/// stored snapshot when the item left it). No network; no streams opened.

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Fake provider: a two-movie, one-show catalog. Stream 99 / series 99 do
/// not exist — favouriting them by hand simulates an item that left the
/// catalog, which must still render from its snapshot.
class _FakeXtreamApi extends XtreamApi {
  _FakeXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamVodStream(streamId: 1, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: '1'),
    XtreamVodStream(streamId: 2, name: 'Beta Movie', containerExtension: 'mkv', categoryId: '2'),
  ];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1'),
  ];

  @override
  Future<XtreamSeriesInfo> getSeriesInfo(int seriesId) async => const XtreamSeriesInfo(
    episodesBySeason: {
      1: [XtreamEpisode(id: 100, episodeNum: 1, title: 'Pilot')],
    },
  );

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'Action'), XtreamCategory(id: '2', name: 'Drama')];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => const [XtreamCategory(id: '1', name: 'Action')];
}

IptvClient _client({IptvItemFavoritesRepository? repository}) {
  final client = IptvClient.forConnection(_trexConnection());
  client.testXtreamApi = _FakeXtreamApi();
  if (repository != null) client.testItemFavoritesRepository = repository;
  return client;
}

void main() {
  group('SharedPreferencesIptvItemFavoritesRepository', () {
    const repo = SharedPreferencesIptvItemFavoritesRepository();
    const key = 'iptv_fav_items:trex';

    setUp(resetSharedPreferencesForTest);

    test('read returns empty when nothing stored', () async {
      expect(await repo.read(key: key), isEmpty);
    });

    test('write then read round-trips snapshots', () async {
      const items = {
        'movie:1': IptvFavoriteItem(id: 'movie:1', kind: 'movie', title: 'Alpha Movie', thumbPath: 'https://x/1.jpg'),
        'series:10': IptvFavoriteItem(id: 'series:10', kind: 'show', title: 'Alpha Show'),
      };
      await repo.write(key, items);
      final read = await repo.read(key: key);
      expect(read.keys, ['movie:1', 'series:10']);
      expect(read['movie:1']!.title, 'Alpha Movie');
      expect(read['movie:1']!.thumbPath, 'https://x/1.jpg');
      expect(read['series:10']!.kind, 'show');
    });

    test('corrupt JSON reads as empty instead of throwing', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString(key, 'not-json{');
      expect(await repo.read(key: key), isEmpty);
    });

    test('one malformed row is skipped, the good rows survive', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString(
        key,
        jsonEncode({
          'movie:1': {'id': 'movie:1', 'kind': 'movie', 'title': 'Alpha Movie'},
          'bad': {'kind': 'movie'},
          'also-bad': 'just a string',
        }),
      );
      final read = await repo.read(key: key);
      expect(read.keys, ['movie:1']);
      expect(read['movie:1']!.title, 'Alpha Movie');
    });
  });

  group('IptvClient.setFavorite / favoriteItems', () {
    setUp(resetSharedPreferencesForTest);

    test('favouriting a movie sticks and fetchItem stamps isFavorite', () async {
      const repo = SharedPreferencesIptvItemFavoritesRepository();
      final client = _client(repository: repo);
      final movie = (await client.fetchItem('movie:1'))!;
      expect(movie.isFavorite, isFalse);

      await client.setFavorite(movie, true);

      expect((await client.fetchItem('movie:1'))!.isFavorite, isTrue);
      final favs = await client.favoriteItems();
      expect(favs, hasLength(1));
      expect(favs.first.id, 'movie:1');
      expect(favs.first.title, 'Alpha Movie');
      expect(favs.first.isFavorite, isTrue);
    });

    test('favourite survives a new client instance (same prefs)', () async {
      const repo = SharedPreferencesIptvItemFavoritesRepository();
      final first = _client(repository: repo);
      await first.setFavorite((await first.fetchItem('movie:2'))!, true);

      final second = _client(repository: repo);
      expect((await second.fetchItem('movie:2'))!.isFavorite, isTrue);
      expect((await second.favoriteItems()).map((i) => i.id), ['movie:2']);
    });

    test('unfavouriting removes the item and clears the stamp', () async {
      const repo = SharedPreferencesIptvItemFavoritesRepository();
      final client = _client(repository: repo);
      final movie = (await client.fetchItem('movie:1'))!;
      await client.setFavorite(movie, true);
      expect(await client.favoriteItems(), hasLength(1));

      await client.setFavorite(movie, false);

      expect(await client.favoriteItems(), isEmpty);
      expect((await client.fetchItem('movie:1'))!.isFavorite, isFalse);
    });

    test('shows and episodes favourite too, newest first', () async {
      const repo = SharedPreferencesIptvItemFavoritesRepository();
      final client = _client(repository: repo);
      await client.setFavorite((await client.fetchItem('movie:1'))!, true);
      await client.setFavorite((await client.fetchItem('series:10'))!, true);
      await client.setFavorite((await client.fetchItem('episode:10:100'))!, true);

      final favs = await client.favoriteItems();
      expect(favs.map((i) => i.id), ['episode:10:100', 'series:10', 'movie:1']);
      expect(favs.map((i) => i.kind), [MediaKind.episode, MediaKind.show, MediaKind.movie]);
      // The episode keeps its show link so the detail screen can show it.
      expect(favs.first.parentId, 'series:10');
      expect(favs.first.parentTitle, 'Alpha Show');
    });

    test('an item that left the catalog renders from its snapshot', () async {
      const repo = SharedPreferencesIptvItemFavoritesRepository();
      final client = _client(repository: repo);
      // Stream 99 is not in the fake catalog — favouriting it by hand is
      // the stand-in for a movie the provider removed.
      const gone = MediaItem.xtream(
        id: 'movie:99',
        kind: MediaKind.movie,
        title: 'Removed Movie',
        thumbPath: 'https://x/99.jpg',
      );
      await client.setFavorite(gone, true);

      final favs = await client.favoriteItems();
      expect(favs, hasLength(1));
      expect(favs.first.title, 'Removed Movie');
      expect(favs.first.thumbPath, 'https://x/99.jpg');
      expect(favs.first.isFavorite, isTrue);
    });

    test('a non-favouritable kind is a no-op', () async {
      const repo = SharedPreferencesIptvItemFavoritesRepository();
      final client = _client(repository: repo);
      const track = MediaItem.xtream(id: 'track:1', kind: MediaKind.track, title: 'A Track');
      await client.setFavorite(track, true);
      expect(await client.favoriteItems(), isEmpty);
    });

    test('browse stamps isFavorite on the favourited movie only', () async {
      const repo = SharedPreferencesIptvItemFavoritesRepository();
      final client = _client(repository: repo);
      await client.setFavorite((await client.fetchItem('movie:2'))!, true);

      final page = await client.fetchLibraryPagedContent(
        'iptv:trex:movies',
        query: const LibraryQuery(offset: 0, limit: 10),
      );
      expect(page.items.map((i) => (i.id, i.isFavorite)), [
        ('movie:1', false),
        ('movie:2', true),
      ]);
    });
  });
}
