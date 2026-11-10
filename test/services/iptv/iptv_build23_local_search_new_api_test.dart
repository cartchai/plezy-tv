// BUILD #23 — local-only search, NEW-API tests (only compile after the fix).
//
// Covers what the failing-first file cannot (it uses only the pre-fix
// public API): the sync engine and its guards, the interval setting,
// the cache-size display, the FTS matching shape, the Trex-scale
// latency + file-size bench, the scope inversion, and the aggregation
// level (a Plex server alongside Trex, scoped search).
//
// Peer baseline (RESEARCH_OSS_IPTV_SEARCH.md, RESEARCH_TIVIMATE_SEARCH.md):
// TiviMate 0 panel requests during search (local SQLite DB after one
// sync); OpenTV whole-list sync + 6h periodic background sync; Hypnotix
// sync at load + 8h TTL, empty list = cache-miss. This build's sync is
// 6 panel requests (3 category lists + 3 catalogs) per run, default
// once a week, and 0 during search when the index is warm.
//
// No live panel: fakes only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_person.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/data_aggregation_service.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/utils/media_server_http_client.dart' show AbortController;

import '../../test_helpers/prefs.dart';
import '../../test_helpers/media_items.dart';
import 'package:plezy/media/search_hit.dart';

const testPassword = 'pa' 'ss';

const _gotSeriesId = 219;
const _gotCategoryId = '1219';
const _gotName = 'EN - Game Of Thrones (2011)';
const _trexSeriesKey = 'conn-xt-1:iptv:conn-xt-1:series';

/// Small fixture catalogs (same shape as the failing-first file).
List<XtreamCategory> _fixtureLiveCategories() => const [
  XtreamCategory(id: '1', name: '|EN| Live 1'),
  XtreamCategory(id: '2', name: '|FR| Live 2'),
  XtreamCategory(id: '3', name: '|DE| Live 3'),
  XtreamCategory(id: '4', name: '|ES| Live 4'),
  XtreamCategory(id: '5', name: '|IT| Live 5'),
];

List<XtreamCategory> _fixtureVodCategories() => const [
  XtreamCategory(id: '10', name: '|EN| Movies 10'),
  XtreamCategory(id: '11', name: '|FR| Movies 11'),
  XtreamCategory(id: '12', name: '|DE| Movies 12'),
  XtreamCategory(id: '13', name: '|ES| Movies 13'),
  XtreamCategory(id: '14', name: '|IT| Movies 14'),
];

List<XtreamCategory> _fixtureSeriesCategories() => const [
  XtreamCategory(id: '1', name: '|EN| Series 1'),
  XtreamCategory(id: '2', name: '|FR| Series 2'),
  XtreamCategory(id: '3', name: '|DE| Series 3'),
  XtreamCategory(id: '4', name: '|ES| Series 4'),
  XtreamCategory(id: _gotCategoryId, name: '|EN| TOP SERIES'),
];

List<XtreamLiveStream> _fixtureLiveRows() => [
  const XtreamLiveStream(streamId: 1, name: 'Filler Common 0', categoryId: '1', epgChannelId: 'ch1'),
  for (var i = 0; i < 5; i++)
    XtreamLiveStream(streamId: 100 + i, name: 'Live Channel $i', categoryId: '${i + 1}', epgChannelId: 'ch${100 + i}'),
];

List<XtreamVodStream> _fixtureVodRows() => [
  const XtreamVodStream(streamId: 1, name: 'Filler Common 0', categoryId: '10'),
  for (var i = 0; i < 5; i++)
    XtreamVodStream(streamId: 200 + i, name: 'Filler Movie $i', categoryId: '${10 + i}'),
];

List<XtreamSeries> _fixtureSeriesRows() => [
  const XtreamSeries(seriesId: _gotSeriesId, name: _gotName, categoryId: _gotCategoryId),
  const XtreamSeries(seriesId: 2, name: 'Filler Common 0', categoryId: '1'),
  for (var i = 0; i < 4; i++)
    XtreamSeries(seriesId: 300 + i, name: 'Filler Series $i', categoryId: '${i + 1}'),
];

/// A fake panel that serves configurable rows per type (unfiltered +
/// per-category), counts requests by action, and can be switched to
/// empty / partial / oversize shapes for the guard tests.
class _SyncPanel extends http.BaseClient {
  _SyncPanel({
    List<XtreamLiveStream>? liveRows,
    List<XtreamVodStream>? vodRows,
    List<XtreamSeries>? seriesRows,
    List<XtreamCategory>? liveCategories,
    List<XtreamCategory>? vodCategories,
    List<XtreamCategory>? seriesCategories,
  }) : _liveRows = liveRows ?? _fixtureLiveRows(),
       _vodRows = vodRows ?? _fixtureVodRows(),
       _seriesRows = seriesRows ?? _fixtureSeriesRows(),
       _liveCategories = liveCategories ?? _fixtureLiveCategories(),
       _vodCategories = vodCategories ?? _fixtureVodCategories(),
       _seriesCategories = seriesCategories ?? _fixtureSeriesCategories();

  final List<XtreamLiveStream> _liveRows;
  final List<XtreamVodStream> _vodRows;
  final List<XtreamSeries> _seriesRows;
  final List<XtreamCategory> _liveCategories;
  final List<XtreamCategory> _vodCategories;
  final List<XtreamCategory> _seriesCategories;

  /// When true, the unfiltered series call returns [] (empty-response guard).
  bool seriesEmpty = false;

  /// When non-null, the unfiltered series call returns this many rows
  /// (partial-response guard).
  int? seriesPartialCount;

  int totalRequests = 0;
  int categoryListRequests = 0;
  int catalogRequests = 0;
  int userInfoRequests = 0;

  void reset() {
    totalRequests = 0;
    categoryListRequests = 0;
    catalogRequests = 0;
    userInfoRequests = 0;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final uri = request.url;
    final action = uri.queryParameters['action'];
    final categoryId = uri.queryParameters['category_id'];
    if (action == null) userInfoRequests++;
    if (action != null && action.endsWith('_categories')) categoryListRequests++;
    if (action == 'get_live_streams' || action == 'get_vod_streams' || action == 'get_series') {
      if (categoryId == null) catalogRequests++;
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(_bodyFor(action, categoryId))),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }

  String _bodyFor(String? action, String? categoryId) {
    switch (action) {
      case null:
        return jsonEncode({
          'user_info': {'status': 'Active', 'exp_date': '1790000000'},
        });
      case 'get_live_categories':
        return jsonEncode(_liveCategories.map((c) => c.toJson()).toList());
      case 'get_vod_categories':
        return jsonEncode(_vodCategories.map((c) => c.toJson()).toList());
      case 'get_series_categories':
        return jsonEncode(_seriesCategories.map((c) => c.toJson()).toList());
      case 'get_live_streams':
        final rows = categoryId == null ? _liveRows : _liveRows.where((r) => r.categoryId == categoryId).toList();
        return jsonEncode(rows.map((r) => r.toJson()).toList());
      case 'get_vod_streams':
        final rows = categoryId == null ? _vodRows : _vodRows.where((r) => r.categoryId == categoryId).toList();
        return jsonEncode(rows.map((r) => r.toJson()).toList());
      case 'get_series':
        if (categoryId != null) {
          return jsonEncode(_seriesRows.where((r) => r.categoryId == categoryId).map((r) => r.toJson()).toList());
        }
        if (seriesEmpty) return '[]';
        final rows = seriesPartialCount == null ? _seriesRows : _seriesRows.take(seriesPartialCount!).toList();
        return jsonEncode(rows.map((r) => r.toJson()).toList());
      case 'get_series_info':
        return jsonEncode({
          'info': {'name': 'Show'},
          'episodes': <String, dynamic>{},
        });
      default:
        return '[]';
    }
  }
}

/// An XtreamApi whose unfiltered series call throws the oversize
/// exception the getter throws when a body exceeds the 300 MB cap —
/// thrown past _fetchBody, so the sync's `on XtreamCatalogTooLargeException`
/// arm catches it. (A panel that throws from send() gets wrapped by
/// _fetchBody into a generic MediaServerHttpException instead.)
class _OversizeSeriesApi extends XtreamApi {
  _OversizeSeriesApi({required super.serverUrl, required super.username, required super.password, super.httpClient});

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) throw const XtreamCatalogTooLargeException(300000001);
    return super.getSeries(categoryId: categoryId, abortTrigger: abortTrigger);
  }
}

IptvClient _clientWith(_SyncPanel panel) {
  final connection = XtreamConnection(
    id: 'conn-xt-1',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    createdAt: DateTime.utc(2026, 11, 5),
  );
  final client = IptvClient.forConnection(connection);
  client.testXtreamApi = XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    httpClient: panel,
  );
  addTearDown(client.close);
  return client;
}

/// A Plex-shaped fake that ignores excludedLibraryIds (the real
/// PlexClient contract, build #19) and returns one attributed movie.
class _PlexLikeFakeClient implements MediaServerClient {
  _PlexLikeFakeClient({required this.searchResults});

  @override
  final ServerId serverId = ServerId('plex');
  @override
  final String serverName = 'HOME PC';
  @override
  MediaBackend get backend => MediaBackend.plex;

  final List<MediaItem> searchResults;

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async => searchResults;

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async => const [];

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => const [];

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MediaItem _sherlockPlexMovie() => testMediaItem(
  id: 'sherlock-1',
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  title: 'Sherlock Holmes',
  year: 2011,
  serverId: 'plex',
  serverName: 'HOME PC',
  libraryId: '1',
  libraryTitle: 'Movies',
);

double _median(List<int> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd ? sorted[mid].toDouble() : (sorted[mid - 1] + sorted[mid]) / 2;
}

int _p95(List<int> values) {
  final sorted = [...values]..sort();
  return sorted[((sorted.length - 1) * 0.95).round()];
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build23_new_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!await tempDir.exists()) break;
      try {
        await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 2) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  });

  group('Build #23 — sync engine', () {
    test('a sync costs 6 panel requests and the next search costs 0', () async {
      final panel = _SyncPanel();
      final client = _clientWith(panel);
      final progress = <IptvSearchSyncProgress>[];
      final result = await client.syncSearchIndex(force: true, onProgress: progress.add);
      // ignore: avoid_print
      print(
        'BUILD23-sync: requests=${panel.totalRequests} catalog=${panel.catalogRequests} '
        'lists=${panel.categoryListRequests} rows=${result.rows} skipped=${result.skipped}',
      );
      // 3 category lists + 3 unfiltered catalogs — the only panel traffic
      // search ever causes. (TiviMate: one sync, then 0 during search;
      // OpenTV: whole-list sync + 6h background sync.)
      expect(panel.catalogRequests, 3);
      expect(panel.categoryListRequests, 3);
      expect(panel.totalRequests, 6);
      expect(result.rows, {'live': 6, 'movie': 6, 'series': 6});
      expect(result.skipped, isEmpty);
      expect(progress.where((p) => p.phase == 'done').length, 3);
      // The index is warm now: a search costs nothing.
      panel.reset();
      final results = await client.searchItems('game of thrones');
      final diag = client.lastSearchDiagnostics!;
      // ignore: avoid_print
      print(
        'BUILD23-sync-search: titles=${results.map((i) => i.title).toList()} requests=${panel.totalRequests} '
        'series=${diag.series.loadSource}',
      );
      expect(results.map((i) => i.title), contains(_gotName));
      expect(panel.totalRequests, 0);
      expect(diag.series.loadSource, 'index');
      expect(client.searchIndexState.totalRows, 18);
    });

    test('an empty response keeps the old rows (never wipes good data)', () async {
      final panel = _SyncPanel();
      final client = _clientWith(panel);
      await client.syncSearchIndex(force: true);
      expect(client.searchIndexState.rowCounts['series'], 6);
      // The panel now returns [] for series: the sync must keep the old 6.
      panel.seriesEmpty = true;
      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('BUILD23-guard-empty: rows=${result.rows} skipped=${result.skipped}');
      expect(result.skipped['series'], 'empty-response');
      expect(client.searchIndexState.rowCounts['series'], 6);
      final results = await client.searchItems('game of thrones');
      expect(results.map((i) => i.title), contains(_gotName));
    });

    test('a partial response (< half the indexed rows) keeps the old rows', () async {
      // Seed the index with 100 series rows, then the panel returns 10.
      final manySeries = [
        const XtreamSeries(seriesId: _gotSeriesId, name: _gotName, categoryId: _gotCategoryId),
        for (var i = 0; i < 99; i++)
          XtreamSeries(seriesId: 1000 + i, name: 'Bulk Series $i', categoryId: '${(i % 5) + 1}'),
      ];
      final panel = _SyncPanel(seriesRows: manySeries);
      final client = _clientWith(panel);
      await client.syncSearchIndex(force: true);
      expect(client.searchIndexState.rowCounts['series'], 100);
      panel.seriesPartialCount = 10;
      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('BUILD23-guard-partial: rows=${result.rows} skipped=${result.skipped}');
      expect(result.skipped['series'], 'partial');
      expect(client.searchIndexState.rowCounts['series'], 100);
      final results = await client.searchItems('game of thrones');
      expect(results.map((i) => i.title), contains(_gotName));
    });

    test('an oversize response is refused and the old rows stay', () async {
      final panel = _SyncPanel();
      final client = _clientWith(panel);
      await client.syncSearchIndex(force: true);
      expect(client.searchIndexState.rowCounts['series'], 6);
      // The cap itself is a const (300 MB); the getter throws the exact
      // exception when a body exceeds it, past _fetchBody.
      expect(XtreamApi.maxCatalogResponseChars, 300000000);
      client.testXtreamApi = _OversizeSeriesApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
        httpClient: panel,
      );
      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('BUILD23-guard-oversize: rows=${result.rows} skipped=${result.skipped}');
      expect(result.skipped['series'], 'oversize');
      expect(client.searchIndexState.rowCounts['series'], 6);
    });

    test('the sync interval defaults to weekly; a second sync inside it is skipped', () async {
      final settings = await SettingsService.getInstance();
      expect(settings.read(SettingsService.iptvCatalogSyncIntervalHours), 168);
      final panel = _SyncPanel();
      final client = _clientWith(panel);
      await client.syncSearchIndex(force: true);
      panel.reset();
      final result = await client.syncSearchIndex();
      // ignore: avoid_print
      print('BUILD23-interval: requests=${panel.totalRequests} skipped=${result.skipped}');
      expect(panel.totalRequests, 0, reason: 'a sync inside the weekly interval must not touch the panel');
      expect(result.skipped, {'live': 'up-to-date', 'movie': 'up-to-date', 'series': 'up-to-date'});
      // A manual refresh (force) syncs anyway.
      panel.reset();
      final forced = await client.syncSearchIndex(force: true);
      expect(panel.totalRequests, 6);
      expect(forced.skipped, isEmpty);
    });

    test('manual-only interval (0) syncs only on an explicit refresh', () async {
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvCatalogSyncIntervalHours, 0);
      final panel = _SyncPanel();
      final client = _clientWith(panel);
      // The first sync (cold index) runs even on manual-only — there is
      // nothing to search yet.
      final first = await client.syncSearchIndex();
      expect(first.rows, {'live': 6, 'movie': 6, 'series': 6});
      panel.reset();
      final second = await client.syncSearchIndex();
      expect(panel.totalRequests, 0);
      expect(second.skipped, {'live': 'up-to-date', 'movie': 'up-to-date', 'series': 'up-to-date'});
      panel.reset();
      final forced = await client.syncSearchIndex(force: true);
      expect(panel.totalRequests, 6);
      expect(forced.skipped, isEmpty);
    });

    test('the cache size is the real index file size', () async {
      final panel = _SyncPanel();
      final client = _clientWith(panel);
      final index = await IptvSearchIndex.open();
      addTearDown(index.close);
      // Opening the index creates the file (schema, empty tables), so
      // the pre-sync size is the empty-schema size, not 0.
      final emptyBytes = await index.fileSizeBytes();
      await client.syncSearchIndex(force: true);
      final bytes = await index.fileSizeBytes();
      // ignore: avoid_print
      print('BUILD23-cache-size: emptyBytes=$emptyBytes bytes=$bytes (${(bytes / 1024).toStringAsFixed(1)} KB for 18 rows)');
      expect(bytes, greaterThan(emptyBytes));
      expect(bytes, greaterThan(0));
    });
  });

  group('Build #23 — FTS matching shape', () {
    late IptvSearchIndex index;
    setUp(() {
      index = IptvSearchIndex.memory();
      addTearDown(index.close);
      index.replaceType(
        connectionId: 'conn-xt-1',
        type: IptvSearchIndex.typeSeries,
        rows: _fixtureSeriesRows().map(IptvSearchIndexRow.fromSeries).toList(),
        categories: {for (final c in _fixtureSeriesCategories()) c.id: c.name},
        syncStampMs: DateTime.now().millisecondsSinceEpoch,
      );
    });

    test('substring and prefix matching keep working (trigram)', () {
      // 'ame' is a middle substring of 'Game'; 'gam' is a prefix.
      final sub = index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'ame');
      expect(sub.map((r) => r.name), contains(_gotName));
      final prefix = index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'gam');
      expect(prefix.map((r) => r.name), contains(_gotName));
    });

    test('a multi-token query ANDs its tokens', () {
      final rows = index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'game of thrones');
      expect(rows.map((r) => r.name), [_gotName]);
    });

    test('FTS syntax characters in a query never throw', () {
      // 'a&e' is one space-separated token (length 3), so it takes the
      // FTS arm as '"a&e"' — the trigram tokenizer handles the '&'
      // and returns 0 rows, without throwing.
      expect(() => index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'a&e'), returnsNormally);
      expect(index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'a&e'), isEmpty);
      expect(() => index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'c++ "quoted" (paren)'), returnsNormally);
      expect(IptvSearchIndex.ftsPattern('a&e'), '"a&e"');
      expect(IptvSearchIndex.ftsPattern('game of thrones'), '"game" "thrones"');
    });

    test('a query with no token >= 3 chars falls back to a LIKE scan', () {
      // 'of' has no trigrams; the LIKE fallback still finds GoT.
      final rows = index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'of');
      expect(rows.map((r) => r.name), contains(_gotName));
    });
  });

  group('Build #23 — scope inversion', () {
    test('a scoped search still runs the excluded section on the index', () async {
      final panel = _SyncPanel();
      final client = _clientWith(panel);
      await client.syncSearchIndex(force: true);
      panel.reset();
      // Scope to Trex Series (movies excluded): the movies section still
      // answers from the index (global first, free) and the aggregation
      // filters it out — the section is NOT skipped.
      final results = await client.searchItems(
        'Filler Common 0',
        excludedLibraryIds: {'iptv:conn-xt-1:movies'},
      );
      final diag = client.lastSearchDiagnostics!;
      // ignore: avoid_print
      print(
        'BUILD23-inversion: titles=${results.map((i) => i.title).toList()} requests=${panel.totalRequests} '
        'moviesSkipped=${diag.movies.skipped} moviesSource=${diag.movies.loadSource}',
      );
      expect(panel.totalRequests, 0);
      expect(diag.movies.skipped, isFalse, reason: 'the index section runs regardless of scope');
      expect(diag.movies.loadSource, 'index');
      expect(diag.series.loadSource, 'index');
      // The client returns the global pool (movies included); the
      // aggregation is the scope filter, not the client.
      expect(results.map((i) => i.title), contains('Filler Common 0'));
    });
  });

  group('Build #23 — aggregation with a Plex server alongside Trex', () {
    test('a Trex-scoped search drops the leaking Plex movie and costs Trex 0 requests', () async {
      final panel = _SyncPanel();
      final trex = _clientWith(panel);
      await trex.syncSearchIndex(force: true);
      panel.reset();
      final manager = MultiServerManager();
      addTearDown(manager.dispose);
      final plex = _PlexLikeFakeClient(searchResults: [_sherlockPlexMovie()]);
      manager.debugRegisterClientForTesting(trex);
      manager.debugRegisterClientForTesting(plex);
      final service = DataAggregationService(manager);
      final result = await service.searchAcrossServers(
        'game of thrones',
        hiddenLibraryKeys: {'1', '2', 'iptv:conn-xt-1:movies'},
        scopedLibraryKey: _trexSeriesKey,
      );
      final titles = [for (final hit in result.hits) if (hit is MediaSearchHit) hit.item.title];
      // ignore: avoid_print
      print('BUILD23-aggregation: titles=$titles trexRequests=${panel.totalRequests}');
      expect(titles, [_gotName]);
      expect(panel.totalRequests, 0, reason: 'the Trex leg answers from the local index');
    });
  });

  group('Build #23 — Trex-scale latency + file size bench', () {
    test(
      'sync + search at Trex scale (55k live / 200k VOD / 46k series)',
      timeout: const Timeout(Duration(minutes: 5)),
      () async {
        // Trex-scale rows (GoT = series_id 219 in category 1219, the
        // last of 237 series categories, mirroring the real panel).
        final liveRows = [
          for (var i = 0; i < 55000; i++)
            XtreamLiveStream(streamId: 300000 + i, name: 'EN - Channel $i', categoryId: '${(i % 833) + 1}', epgChannelId: 'ch$i'),
        ];
        final vodRows = [
          for (var i = 0; i < 200000; i++)
            XtreamVodStream(streamId: 200000 + i, name: 'Movie Title $i (2020)', categoryId: '${(i % 368) + 1}'),
        ];
        final seriesRows = [
          const XtreamSeries(seriesId: _gotSeriesId, name: _gotName, categoryId: _gotCategoryId),
          for (var i = 0; i < 46526; i++)
            XtreamSeries(seriesId: 100000 + i, name: 'Filler Series $i', categoryId: '${(i % 236) + 1}'),
        ];
        final liveCats = [
          for (var i = 1; i <= 833; i++) XtreamCategory(id: '$i', name: '|EN| Live $i'),
        ];
        final vodCats = [
          for (var i = 1; i <= 368; i++) XtreamCategory(id: '$i', name: '|EN| Movies $i'),
        ];
        final seriesCats = [
          for (var i = 1; i <= 236; i++) XtreamCategory(id: '$i', name: '|EN| Series $i'),
          const XtreamCategory(id: _gotCategoryId, name: '|EN| TOP SERIES'),
        ];
        final panel = _SyncPanel(
          liveRows: liveRows,
          vodRows: vodRows,
          seriesRows: seriesRows,
          liveCategories: liveCats,
          vodCategories: vodCats,
          seriesCategories: seriesCats,
        );
        final client = _clientWith(panel);
        final syncStarted = DateTime.now();
        final result = await client.syncSearchIndex(force: true);
        final syncMs = DateTime.now().difference(syncStarted).inMilliseconds;
        final index = await IptvSearchIndex.open();
        addTearDown(index.close);
        final bytes = await index.fileSizeBytes();
        // ignore: avoid_print
        print(
          'BUILD23-bench-sync: ms=$syncMs requests=${panel.totalRequests} rows=${result.rows} '
          'bytes=$bytes (${(bytes / 1024 / 1024).toStringAsFixed(1)} MB)',
        );
        expect(panel.totalRequests, 6);
        expect(result.rows, {'live': 55000, 'movie': 200000, 'series': 46527});
        expect(client.searchIndexState.totalRows, 301527);
        // Latency: a common needle (matches ~200k movies) vs the rare
        // needle (GoT, 1 series row). 1 warm-up run (discarded — the
        // first search pays the FTS + scorer warm-up) + 10 measured
        // runs, median + p95.
        Future<List<int>> timeSearch(String query, {int runs = 10}) async {
          await client.searchItems(query);
          final times = <int>[];
          for (var i = 0; i < runs; i++) {
            final started = DateTime.now();
            await client.searchItems(query);
            times.add(DateTime.now().difference(started).inMilliseconds);
          }
          return times;
        }

        final commonTimes = await timeSearch('Movie Title');
        final rareTimes = await timeSearch('game of thrones');
        // ignore: avoid_print
        print(
          'BUILD23-bench-search: common median=${_median(commonTimes)}ms p95=${_p95(commonTimes)}ms '
          'rare median=${_median(rareTimes)}ms p95=${_p95(rareTimes)}ms',
        );
        final rareResults = await client.searchItems('game of thrones');
        expect(rareResults.map((i) => i.title), contains(_gotName));
        expect(panel.totalRequests, 6, reason: 'the bench searches must not add panel requests');
        // The search is local-only and must be fast: a rare needle is
        // milliseconds; a common needle (200k matches, 5000 candidates
        // scored + ranked) is ~0.5s median, ~1.2s p95 — the worst case,
        // and still an order of magnitude under the old network heal
        // (29s at cap 8). The common p95 bound is 2s, not 1s: scoring
        // 5000 candidates has a real tail (GC / isolate scheduling).
        expect(_median(rareTimes), lessThan(1000));
        expect(_p95(rareTimes), lessThan(1000));
        expect(_median(commonTimes), lessThan(1000));
        expect(_p95(commonTimes), lessThan(2000));
        // The file size is the real number for the Settings display.
        expect(bytes, greaterThan(0));
      },
    );
  });
  group('Build #23 — startup rule, manager-level bind', () {
    late _SyncPanel panel;
    late MultiServerManager manager;
    IptvClient? boundClient;

    XtreamConnection trexConnection() => XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      createdAt: DateTime.utc(2026, 11, 5),
    );

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await SettingsService.getInstance();
      await StorageService.getInstance();
      panel = _SyncPanel();
      manager = MultiServerManager();
      addTearDown(manager.dispose);
      boundClient = null;
      IptvClient.debugClientFactory = (connection) {
        final client = IptvClient.xtream(xtreamConnection: connection as XtreamConnection);
        client.testXtreamApi = XtreamApi(
          serverUrl: 'https://panel.example.com:8080',
          username: 'user',
          password: testPassword,
          httpClient: panel,
        );
        boundClient = client;
        return client;
      };
    });

    tearDown(() {
      IptvClient.debugClientFactory = null;
    });

    /// Warm the index + disk exactly as a real week of use would: one
    /// manual sync, then the panel counter is reset so the bind below
    /// is measured on its own.
    Future<void> warmIndexAndDisk() async {
      final client = _clientWith(panel);
      await client.syncSearchIndex(force: true);
      expect(client.searchIndexState.totalRows, 18);
      panel.reset();
    }

    test('a cold start with a warm index makes 0 catalog requests', () async {
      await warmIndexAndDisk();
      // The bind is the app start: warm-ups + ensureSearchIndexSynced
      // + the health probe. The warm-ups are disk-only and the sync
      // skips (last sync minutes ago, weekly interval), so the only
      // panel traffic is the single getUserInfo health probe.
      expect(await manager.addIptvConnection(trexConnection()), isTrue);
      // The warm-ups and the sync check are fire-and-forget: give them
      // time to land (or not land) before asserting.
      await Future<void>.delayed(const Duration(seconds: 2));
      final catalogRequests = panel.totalRequests - panel.userInfoRequests;
      // ignore: avoid_print
      print(
        'BUILD23-startup-bind-warm: total=${panel.totalRequests} userInfo=${panel.userInfoRequests} '
        'catalog=$catalogRequests',
      );
      expect(catalogRequests, 0, reason: 'a warm start must not talk to Trex for the catalog at all');
      expect(panel.userInfoRequests, 1, reason: 'the health probe is the only allowed panel call at startup');
      // And the bound client searches from the warm index, still 0.
      final bound = boundClient!;
      panel.reset();
      final results = await bound.searchItems('game of thrones');
      expect(results.map((i) => i.title), contains(_gotName));
      expect(panel.totalRequests, 0);
    });

    test('a due weekly refresh still runs in the background at startup', () async {
      await warmIndexAndDisk();
      // Backdate the index's last sync to 8 days ago (past the weekly
      // default) by rewriting each type with the same rows and an old
      // sync stamp — the sync must then run on the next bind.
      final index = await IptvSearchIndex.open();
      final oldStamp = DateTime.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch;
      index.replaceType(
        connectionId: 'conn-xt-1',
        type: IptvSearchIndex.typeLive,
        rows: _fixtureLiveRows().map(IptvSearchIndexRow.fromLive).toList(),
        categories: {for (final c in _fixtureLiveCategories()) c.id: c.name},
        syncStampMs: oldStamp,
      );
      index.replaceType(
        connectionId: 'conn-xt-1',
        type: IptvSearchIndex.typeMovie,
        rows: _fixtureVodRows().map(IptvSearchIndexRow.fromMovie).toList(),
        categories: {for (final c in _fixtureVodCategories()) c.id: c.name},
        syncStampMs: oldStamp,
      );
      index.replaceType(
        connectionId: 'conn-xt-1',
        type: IptvSearchIndex.typeSeries,
        rows: _fixtureSeriesRows().map(IptvSearchIndexRow.fromSeries).toList(),
        categories: {for (final c in _fixtureSeriesCategories()) c.id: c.name},
        syncStampMs: oldStamp,
      );
      index.close();
      panel.reset();
      expect(await manager.addIptvConnection(trexConnection()), isTrue);
      // The bind itself must not wait on the sync — it returns after
      // the health probe while the sync runs in the background. Poll
      // for the sync's 6 requests (3 category lists + 3 catalogs).
      var waitedMs = 0;
      while (panel.totalRequests - panel.userInfoRequests < 6 && waitedMs < 30000) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        waitedMs += 200;
      }
      final catalogRequests = panel.totalRequests - panel.userInfoRequests;
      // ignore: avoid_print
      print(
        'BUILD23-startup-bind-due: total=${panel.totalRequests} userInfo=${panel.userInfoRequests} '
        'catalog=$catalogRequests waitedMs=$waitedMs',
      );
      expect(catalogRequests, 6, reason: 'the due weekly refresh is 3 category lists + 3 catalogs, in the background');
      // The refresh also refreshed the disk catalog (the sync is the
      // disk's only writer now): its fetchedAt is minutes old.
      final disk = await const IptvCatalogDiskCache().read('conn-xt-1', IptvCatalogDiskCache.seriesDataset);
      expect(disk, isNotNull);
      expect(DateTime.now().difference(disk!.fetchedAt), lessThan(const Duration(minutes: 2)));
      // And the bound client searches from the refreshed index, 0 more.
      final bound = boundClient!;
      panel.reset();
      final results = await bound.searchItems('game of thrones');
      expect(results.map((i) => i.title), contains(_gotName));
      expect(panel.totalRequests, 0);
    });
  });}
