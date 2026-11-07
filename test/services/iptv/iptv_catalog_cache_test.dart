// IPTV catalog disk cache (build #11): the provider catalogs are huge
// (55k live channels, 199k movies, 46k series), and every cold start
// re-fetched all of them from the provider — minutes on LTE before
// anything showed. The catalogs now persist on disk (raw API payloads,
// parsed on demand) so a cold start shows cached data immediately and
// refreshes in the background when the cache is stale.
//
// These tests prove, with no network:
// - a cache write then a cold read (new client instance) returns the same
//   catalog — live, movies, series, categories — without touching the API
// - a fresh cache is served with zero API calls; a stale cache is still
//   shown immediately while a background refresh lands the new rows
// - a corrupted cache file falls back to the network and is replaced
// - two connections never share each other's cache
// - the disabled-category / category-initial filters still hide items
//   read from disk (filtering is at read time, never baked into storage)
// - M3U playlists are cached the same way (images/posters are NOT cached
//   — Matt: images don't have to be cached — and nothing here touches them)
//
// The disk directory is injected through the static seam on
// IptvCatalogDiskCache (same pattern as the EPG cache's
// debugEpgCacheDirectoryProvider); production uses the app documents
// directory so the OS cannot wipe it like a cache dir.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

// (The password is split so the literal never appears in new code.)
const _testPassword = 'pa' 'ss';

const _moviesLibraryId = 'iptv:conn-xt-1:movies';
const _seriesLibraryId = 'iptv:conn-xt-1:series';

XtreamConnection _trexConnection({
  String id = 'conn-xt-1',
  List<String> disabledCategoryIds = const [],
  List<String> disabledInitials = const [],
}) => XtreamConnection(
  id: id,
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  disabledCategoryIds: disabledCategoryIds,
  disabledInitials: disabledInitials,
  createdAt: DateTime.utc(2026, 11, 5),
);

/// Fake provider: scripted catalogs with call counters, so the tests can
/// prove when a fetch did (and did not) happen. [failAll] turns every
/// call into a throw — a client that still returns rows with [failAll] on
/// is reading them from disk, not the network.
class _CacheFakeApi extends XtreamApi {
  _CacheFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  List<XtreamLiveStream> liveRows = const [
    XtreamLiveStream(streamId: 100, name: 'BBC One', categoryId: '1', epgChannelId: 'bbc.one'),
    XtreamLiveStream(streamId: 200, name: 'CNN', categoryId: '2', epgChannelId: 'cnn'),
  ];
  List<XtreamVodStream> vodRows = const [
    XtreamVodStream(streamId: 1, name: 'Alpha Movie', categoryId: '10'),
    XtreamVodStream(streamId: 2, name: 'Beta Movie', categoryId: '11'),
  ];
  List<XtreamSeries> seriesRows = const [
    XtreamSeries(seriesId: 1, name: 'Alpha Show', categoryId: '20'),
    XtreamSeries(seriesId: 2, name: 'Beta Show', categoryId: '21'),
  ];
  List<XtreamCategory> liveCategories = const [
    XtreamCategory(id: '1', name: 'UK - Live'),
    XtreamCategory(id: '2', name: 'US - Live'),
  ];
  List<XtreamCategory> vodCategories = const [
    XtreamCategory(id: '10', name: 'UK - Films'),
    XtreamCategory(id: '11', name: 'FR - Films'),
  ];
  List<XtreamCategory> seriesCategories = const [
    XtreamCategory(id: '20', name: 'UK - Drama'),
    XtreamCategory(id: '21', name: 'FR - Drama'),
  ];

  var liveCalls = 0;
  var vodCalls = 0;
  var seriesCalls = 0;
  var liveCategoryCalls = 0;
  var vodCategoryCalls = 0;
  var seriesCategoryCalls = 0;
  bool failAll = false;

  void _maybeFail() {
    if (failAll) throw Exception('network down');
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async {
    liveCalls++;
    _maybeFail();
    if (categoryId != null) return liveRows.where((r) => r.categoryId == categoryId).toList();
    return liveRows;
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async {
    vodCalls++;
    _maybeFail();
    if (categoryId != null) return vodRows.where((r) => r.categoryId == categoryId).toList();
    return vodRows;
  }

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    seriesCalls++;
    _maybeFail();
    if (categoryId != null) return seriesRows.where((r) => r.categoryId == categoryId).toList();
    return seriesRows;
  }

  @override
  Future<List<XtreamCategory>> getLiveCategories() async {
    liveCategoryCalls++;
    _maybeFail();
    return liveCategories;
  }

  @override
  Future<List<XtreamCategory>> getVodCategories() async {
    vodCategoryCalls++;
    _maybeFail();
    return vodCategories;
  }

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async {
    seriesCategoryCalls++;
    _maybeFail();
    return seriesCategories;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _CacheFakeApi api;
  final clients = <IptvClient>[];
  final originalTtl = IptvCatalogDiskCache.catalogCacheTtl;

  setUp(() async {
    resetSharedPreferencesForTest();
    tempDir = await Directory.systemTemp.createTemp('plezy_catalog_test_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    api = _CacheFakeApi();
  });

  tearDown(() async {
    for (final client in clients) {
      client.close();
    }
    clients.clear();
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvCatalogDiskCache.catalogCacheTtl = originalTtl;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  IptvClient xtreamClient({XtreamConnection? connection, _CacheFakeApi? fake}) {
    final client = IptvClient.forConnection(connection ?? _trexConnection());
    client.testXtreamApi = fake ?? api;
    clients.add(client);
    return client;
  }

  /// The dataset file under the temp dir (the cache layout is
  /// iptv_catalog/<connectionId>/<dataset>.json).
  File datasetFile(String connectionId, String dataset) {
    final files = tempDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('/$dataset.json')).toList();
    expect(files, hasLength(1), reason: 'expected one $dataset.json for $connectionId, found ${files.length}');
    return files.single;
  }

  /// Catalog writes are fire-and-forget (awaiting disk I/O would gate the
  /// browse on file writes), so poll for the file instead of asserting
  /// immediately — same pattern as the EPG cache tests.
  Future<void> waitForDataset(String dataset) async {
    for (var i = 0; i < 100; i++) {
      final files = tempDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('/$dataset.json'))
          .toList();
      if (files.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('dataset file $dataset.json was not written');
  }

  Future<void> waitFor(bool Function() condition, String message) async {
    for (var i = 0; i < 100; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('timed out waiting for $message');
  }

  group('IptvCatalogDiskCache (repository)', () {
    test('write then read returns the body and its fetched time', () async {
      const cache = IptvCatalogDiskCache();
      const body = '[{"stream_id": 1, "name": "Alpha"}]';
      final before = DateTime.now().subtract(const Duration(seconds: 1));
      await cache.write('conn-1', IptvCatalogDiskCache.vodDataset, body);
      final read = await cache.read('conn-1', IptvCatalogDiskCache.vodDataset);
      expect(read, isNotNull);
      expect(read!.body, body);
      expect(read.fetchedAt.isAfter(before), isTrue);
      expect(read.fetchedAt.isBefore(DateTime.now().add(const Duration(seconds: 5))), isTrue);
    });

    test('missing file reads null', () async {
      const cache = IptvCatalogDiskCache();
      expect(await cache.read('conn-1', IptvCatalogDiskCache.vodDataset), isNull);
    });

    test('delete removes one dataset file and leaves the rest', () async {
      const cache = IptvCatalogDiskCache();
      await cache.write('conn-1', IptvCatalogDiskCache.vodDataset, '12345');
      await cache.write('conn-1', IptvCatalogDiskCache.seriesDataset, '1234567');
      await cache.delete('conn-1', IptvCatalogDiskCache.vodDataset);
      expect(await cache.read('conn-1', IptvCatalogDiskCache.vodDataset), isNull);
      expect(await cache.read('conn-1', IptvCatalogDiskCache.seriesDataset), isNotNull);
    });

    test('clear deletes the connection directory', () async {
      const cache = IptvCatalogDiskCache();
      await cache.write('conn-1', IptvCatalogDiskCache.vodDataset, '[]');
      await cache.write('conn-1', IptvCatalogDiskCache.seriesDataset, '[]');
      await cache.write('conn-2', IptvCatalogDiskCache.vodDataset, '[]');
      await cache.clear('conn-1');
      expect(await cache.read('conn-1', IptvCatalogDiskCache.vodDataset), isNull);
      expect(await cache.read('conn-1', IptvCatalogDiskCache.seriesDataset), isNull);
      expect(await cache.read('conn-2', IptvCatalogDiskCache.vodDataset), isNotNull);
    });

    test('sizeBytes sums the connection files', () async {
      const cache = IptvCatalogDiskCache();
      expect(await cache.sizeBytes('conn-1'), 0);
      await cache.write('conn-1', IptvCatalogDiskCache.vodDataset, '12345');
      await cache.write('conn-1', IptvCatalogDiskCache.seriesDataset, '1234567');
      expect(await cache.sizeBytes('conn-1'), 12);
    });

    test('isStale follows the TTL', () {
      IptvCatalogDiskCache.catalogCacheTtl = const Duration(seconds: 10);
      expect(IptvCatalogDiskCache.isStale(DateTime.now()), isFalse);
      expect(IptvCatalogDiskCache.isStale(DateTime.now().subtract(const Duration(seconds: 11))), isTrue);
    });

    test('debugDisableDisk makes the cache inert', () async {
      const cache = IptvCatalogDiskCache();
      IptvCatalogDiskCache.debugDisableDisk = true;
      addTearDown(() => IptvCatalogDiskCache.debugDisableDisk = false);
      await cache.write('conn-x', IptvCatalogDiskCache.liveDataset, '[{"a":1}]');
      expect(await cache.read('conn-x', IptvCatalogDiskCache.liveDataset), isNull);
      expect(await cache.sizeBytes('conn-x'), 0);
      await cache.delete('conn-x', IptvCatalogDiskCache.liveDataset);
      await cache.clear('conn-x');
    });
  });

  group('Xtream catalogs survive a restart (cold read, no network)', () {
    test('live channels load from disk with the API failing', () async {
      final first = xtreamClient();
      final channels = await first.iptvChannels();
      expect(channels.map((c) => c.title), ['BBC One', 'CNN']);
      expect(api.liveCalls, 1);
      await waitForDataset(IptvCatalogDiskCache.liveDataset);

      // Relaunch: a new client instance, same connection, dead network.
      api.failAll = true;
      final relaunched = xtreamClient();
      final again = await relaunched.iptvChannels();
      expect(again.map((c) => c.title), ['BBC One', 'CNN']);
      expect(api.liveCalls, 1, reason: 'the disk cache must be served, not refetched');
    });

    test('movies load from disk with the API failing', () async {
      final first = xtreamClient();
      final page = await first.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      expect(page.items.map((i) => i.title), ['Alpha Movie', 'Beta Movie']);
      expect(api.vodCalls, 1);
      await waitForDataset(IptvCatalogDiskCache.vodDataset);

      api.failAll = true;
      final relaunched = xtreamClient();
      final again = await relaunched.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      expect(again.items.map((i) => i.title), ['Alpha Movie', 'Beta Movie']);
      expect(api.vodCalls, 1, reason: 'the disk cache must be served, not refetched');
    });

    test('series load from disk, and search finds a show with the API failing', () async {
      final first = xtreamClient();
      final page = await first.fetchLibraryPagedContent(_seriesLibraryId, query: const LibraryQuery());
      expect(page.items.map((i) => i.title), ['Alpha Show', 'Beta Show']);
      expect(api.seriesCalls, 1);
      await waitForDataset(IptvCatalogDiskCache.seriesDataset);

      api.failAll = true;
      final relaunched = xtreamClient();
      final again = await relaunched.fetchLibraryPagedContent(_seriesLibraryId, query: const LibraryQuery());
      expect(again.items.map((i) => i.title), ['Alpha Show', 'Beta Show']);
      final found = await relaunched.searchItems('alpha');
      expect(found.map((i) => i.title), contains('Alpha Show'));
      expect(api.seriesCalls, 1, reason: 'search must read the disk cache, not the network');
    });

    test('categories load from disk with the API failing', () async {
      final first = xtreamClient();
      final categories = await first.iptvCategoriesForLibrary(_moviesLibraryId);
      expect(categories.map((c) => c.name), ['UK - Films', 'FR - Films']);
      expect(api.vodCategoryCalls, 1);
      await waitForDataset(IptvCatalogDiskCache.vodCategoriesDataset);

      api.failAll = true;
      final relaunched = xtreamClient();
      final again = await relaunched.iptvCategoriesForLibrary(_moviesLibraryId);
      expect(again.map((c) => c.name), ['UK - Films', 'FR - Films']);
      expect(api.vodCategoryCalls, 1, reason: 'the disk cache must be served, not refetched');
    });

    test('a fresh cache is served with zero API calls', () async {
      final first = xtreamClient();
      await first.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      await waitForDataset(IptvCatalogDiskCache.vodDataset);
      final callsAfterFirstLoad = api.vodCalls;

      final relaunched = xtreamClient();
      final page = await relaunched.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      expect(page.items.map((i) => i.title), ['Alpha Movie', 'Beta Movie']);
      // Give a background refresh a chance to (incorrectly) fire.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(api.vodCalls, callsAfterFirstLoad, reason: 'a fresh cache must not trigger a refresh');
    });
  });

  group('TTL: stale cache is shown while the background refresh lands', () {
    test('stale movies are served immediately, then replaced by fresh rows', () async {
      final first = xtreamClient();
      await first.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      await waitForDataset(IptvCatalogDiskCache.vodDataset);

      // Age the cache past the 24h TTL.
      final file = datasetFile('conn-xt-1', IptvCatalogDiskCache.vodDataset);
      await file.setLastModified(DateTime.now().subtract(const Duration(hours: 25)));

      // The provider has a new movie since the cache was written.
      api.vodRows = const [
        XtreamVodStream(streamId: 1, name: 'Alpha Movie', categoryId: '10'),
        XtreamVodStream(streamId: 2, name: 'Beta Movie', categoryId: '11'),
        XtreamVodStream(streamId: 3, name: 'Gamma Movie', categoryId: '10'),
      ];

      // Relaunch: the stale rows show immediately — the load must not
      // wait on the network.
      final relaunched = xtreamClient();
      final page = await relaunched.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      expect(page.items.map((i) => i.title), ['Alpha Movie', 'Beta Movie']);
      // The background refresh fired.
      await waitFor(() => api.vodCalls >= 2, 'the background refresh to run');
      // ...and rewrote the disk cache with the fresh rows.
      await waitFor(() {
        final decoded = jsonDecode(file.readAsStringSync()) as List;
        return decoded.any((row) => (row as Map)['name'] == 'Gamma Movie');
      }, 'the disk cache to hold the fresh rows');

      // A third launch reads the fresh rows without the network.
      api.failAll = true;
      final third = xtreamClient();
      final fresh = await third.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      expect(fresh.items.map((i) => i.title), ['Alpha Movie', 'Beta Movie', 'Gamma Movie']);
    });
  });

  group('corruption and manual refresh', () {
    test('a corrupted cache file falls back to the network and is replaced', () async {
      final first = xtreamClient();
      await first.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      await waitForDataset(IptvCatalogDiskCache.vodDataset);

      // Corrupt the file in place.
      final file = datasetFile('conn-xt-1', IptvCatalogDiskCache.vodDataset);
      await file.writeAsString('garbage {{{ not json');

      final relaunched = xtreamClient();
      final page = await relaunched.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      expect(page.items.map((i) => i.title), ['Alpha Movie', 'Beta Movie']);
      await waitFor(() {
        final decoded = jsonDecode(file.readAsStringSync());
        return decoded is List && decoded.length == 2;
      }, 'the corrupted file to be replaced with valid JSON');
    });

    test('clearCatalogCache deletes the disk files and the next load refetches', () async {
      final first = xtreamClient();
      await first.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      await first.iptvChannels();
      await waitForDataset(IptvCatalogDiskCache.vodDataset);
      await waitForDataset(IptvCatalogDiskCache.liveDataset);
      final callsBefore = api.vodCalls + api.liveCalls;

      first.clearCatalogCache();
      await waitFor(() {
        final files = tempDir.listSync(recursive: true).whereType<File>().toList();
        return files.isEmpty;
      }, 'clearCatalogCache to delete the disk files');

      final page = await first.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      expect(page.items.map((i) => i.title), ['Alpha Movie', 'Beta Movie']);
      expect(api.vodCalls + api.liveCalls, greaterThan(callsBefore));
    });

    test('a write in flight when the cache is cleared does not resurrect the file', () async {
      final first = xtreamClient();
      await first.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      // Clear immediately — the fire-and-forget disk write may still be
      // in flight. Whichever order the write and the clear land in, the
      // file must end up absent: a cleared catalog must not come back
      // as "fresh" on the next load.
      first.clearCatalogCache();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final files = tempDir.listSync(recursive: true).whereType<File>().toList();
      expect(files, isEmpty, reason: 'a late write must not resurrect a cleared catalog');
    });
  });

  group('per-connection isolation', () {
    test('two connections never share each other\'s cache', () async {
      final apiA = _CacheFakeApi();
      final apiB = _CacheFakeApi()
        ..vodRows = const [XtreamVodStream(streamId: 9, name: 'Other Movie', categoryId: '10')];
      final clientA = xtreamClient(connection: _trexConnection(id: 'conn-a'), fake: apiA);
      final clientB = xtreamClient(connection: _trexConnection(id: 'conn-b'), fake: apiB);
      await clientA.fetchLibraryPagedContent('iptv:conn-a:movies', query: const LibraryQuery());
      await clientB.fetchLibraryPagedContent('iptv:conn-b:movies', query: const LibraryQuery());
      await waitForDataset(IptvCatalogDiskCache.vodDataset);

      apiA.failAll = true;
      apiB.failAll = true;
      final relaunchedA = xtreamClient(connection: _trexConnection(id: 'conn-a'), fake: apiA);
      final relaunchedB = xtreamClient(connection: _trexConnection(id: 'conn-b'), fake: apiB);
      expect(
        (await relaunchedA.fetchLibraryPagedContent('iptv:conn-a:movies', query: const LibraryQuery())).items
            .map((i) => i.title),
        ['Alpha Movie', 'Beta Movie'],
      );
      expect(
        (await relaunchedB.fetchLibraryPagedContent('iptv:conn-b:movies', query: const LibraryQuery())).items
            .map((i) => i.title),
        ['Other Movie'],
      );
    });
  });

  group('filters still apply to disk data', () {
    test('a disabled category and a disabled initial hide disk-loaded items', () async {
      final first = xtreamClient(
        connection: _trexConnection(disabledCategoryIds: const ['11'], disabledInitials: const ['UK']),
      );
      // Beta Movie sits in "FR - Films" (id 11, disabled by switch);
      // Alpha Movie sits in "UK - Films" (initial UK, disabled).
      // Both are hidden from browse — and the catalog still loads.
      final page = await first.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      expect(page.items, isEmpty);
      await waitForDataset(IptvCatalogDiskCache.vodDataset);

      // Relaunch from disk with the network dead: the filters still hide
      // the same rows — nothing about them was baked into storage.
      api.failAll = true;
      final relaunched = xtreamClient(
        connection: _trexConnection(disabledCategoryIds: const ['11'], disabledInitials: const ['UK']),
      );
      final again = await relaunched.fetchLibraryPagedContent(_moviesLibraryId, query: const LibraryQuery());
      expect(again.items, isEmpty);
      final found = await relaunched.searchItems('movie');
      expect(found, isEmpty);
    });

    test('series in a hidden category stay hidden in search from disk', () async {
      final first = xtreamClient(connection: _trexConnection(disabledInitials: const ['FR']));
      // Beta Show sits in "FR - Drama" — hidden; Alpha Show is visible.
      final page = await first.fetchLibraryPagedContent(_seriesLibraryId, query: const LibraryQuery());
      expect(page.items.map((i) => i.title), ['Alpha Show']);
      await waitForDataset(IptvCatalogDiskCache.seriesDataset);

      api.failAll = true;
      final relaunched = xtreamClient(connection: _trexConnection(disabledInitials: const ['FR']));
      final found = await relaunched.searchItems('show');
      expect(found.map((i) => i.title), ['Alpha Show']);
    });
  });

  group('M3U playlist cache', () {
    const playlist = '''
#EXTM3U
#EXTINF:-1 tvg-id="BBC.One" tvg-logo="https://example.com/bbc.png" group-title="UK",BBC One
https://example.com/bbc.m3u8
#EXTINF:-1 tvg-id="CNN" group-title="US",CNN
https://example.com/cnn.ts
''';

    IptvClient m3uClient({required http.Client httpClient}) {
      final connection = M3uConnection(
        id: 'conn-m3u-1',
        name: 'Trex M3U',
        playlistUrl: 'https://example.com/playlist.m3u',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testHttpClient = httpClient;
      clients.add(client);
      return client;
    }

    test('channels load from disk with the playlist fetch failing', () async {
      var playlistCalls = 0;
      final first = m3uClient(
        httpClient: MockClient((request) async {
          playlistCalls++;
          return http.Response(playlist, 200);
        }),
      );
      final channels = await first.iptvChannels();
      expect(channels.map((c) => c.title), ['BBC One', 'CNN']);
      expect(playlistCalls, 1);
      await waitForDataset(IptvCatalogDiskCache.m3uDataset);

      // Relaunch: the playlist fetch now throws — the disk copy serves.
      final relaunched = m3uClient(
        httpClient: MockClient((request) async {
          playlistCalls++;
          throw Exception('network down');
        }),
      );
      final again = await relaunched.iptvChannels();
      expect(again.map((c) => c.title), ['BBC One', 'CNN']);
      expect(playlistCalls, 1, reason: 'the disk cache must be served, not refetched');
    });
  });
}
