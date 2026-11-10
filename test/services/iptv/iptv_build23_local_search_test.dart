// BUILD #23 — local-only search (v1.0.6-2.25.0+178).
//
// THE PHONE FAILURE (v1.0.3-2.25.0, 2026-11-09 ~23:12 EST): searching
// puts the app into OFFLINE mode and disconnects Trex, and search takes
// forever. Build #21 capped the mid-search heal burst at 8 concurrent
// requests and made it cancellable — but a cold/stale search STILL makes
// panel requests (up to 237 category calls + 3 loads + 3 lists), and
// Matt's read on it was "the app is basically causing a [DDoS] attack".
// His own proposal (2026-11-09 ~00:40 EST): "what if it runs a download
// of all the details to keep into a file it can check once a week and
// that way search is faster."
//
// THE FIX (build #23): the whole catalog (live channels, VOD movies,
// series) is synced once into a local SQLite FTS5 trigram index, and
// search queries that index — ZERO panel requests during a search when
// the index is warm. The sync runs in the background (default once a
// week, changeable, plus a manual refresh) and the warm-up seeds the
// index from the disk catalog, so the index is warm within seconds of
// an upgrade with no network at all. Peers: TiviMate searches a local
// SQLite DB after one sync (0 requests during search); OpenTV syncs
// whole lists + 6h background sync; Hypnotix syncs at load + 8h TTL —
// every peer makes ZERO panel requests during a search. Only this
// build closes that gap.
//
// These tests FAIL on d937a1797 and PASS on the fix. They use only the
// pre-fix public API (disk seeding, warm-ups, searchItems, the
// diagnostics' loadSource), so they can run failing-first on base:
// the warm-up seeds the index from disk as a side effect, and the poll
// below waits for the search to start answering from the index
// (`loadSource == 'index'`). On base the index never exists, so the
// poll times out and the test fails there. The new-API tests (sync
// engine, guards, interval setting, cache size, latency bench) live in
// iptv_build23_local_search_new_api_test.dart and only compile after
// the fix.
//
// No live panel: fakes only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';

/// GoT — the needle the phone must find: series_id 219, category 1219
/// (the LAST of the fixture's 5 series categories, mirroring the real
/// panel where 1219 is last of 237).
const _gotSeriesId = 219;
const _gotCategoryId = '1219';
const _gotName = 'EN - Game Of Thrones (2011)';

/// Small fixture catalogs: 5 categories per type, a row named
/// 'Filler Common 0' in EACH type (so one unscoped throwaway search
/// exercises all three sections and the poll can see all three go
/// index), and GoT in the last series category.
List<XtreamCategory> _liveCategories() => const [
  XtreamCategory(id: '1', name: '|EN| Live 1'),
  XtreamCategory(id: '2', name: '|FR| Live 2'),
  XtreamCategory(id: '3', name: '|DE| Live 3'),
  XtreamCategory(id: '4', name: '|ES| Live 4'),
  XtreamCategory(id: '5', name: '|IT| Live 5'),
];

List<XtreamCategory> _vodCategories() => const [
  XtreamCategory(id: '10', name: '|EN| Movies 10'),
  XtreamCategory(id: '11', name: '|FR| Movies 11'),
  XtreamCategory(id: '12', name: '|DE| Movies 12'),
  XtreamCategory(id: '13', name: '|ES| Movies 13'),
  XtreamCategory(id: '14', name: '|IT| Movies 14'),
];

List<XtreamCategory> _seriesCategories() => const [
  XtreamCategory(id: '1', name: '|EN| Series 1'),
  XtreamCategory(id: '2', name: '|FR| Series 2'),
  XtreamCategory(id: '3', name: '|DE| Series 3'),
  XtreamCategory(id: '4', name: '|ES| Series 4'),
  XtreamCategory(id: _gotCategoryId, name: '|EN| TOP SERIES'),
];

List<XtreamLiveStream> _liveRows() => [
  const XtreamLiveStream(streamId: 1, name: 'Filler Common 0', categoryId: '1', epgChannelId: 'ch1'),
  for (var i = 0; i < 5; i++)
    XtreamLiveStream(streamId: 100 + i, name: 'Live Channel $i', categoryId: '${i + 1}', epgChannelId: 'ch${100 + i}'),
];

List<XtreamVodStream> _vodRows() => [
  const XtreamVodStream(streamId: 1, name: 'Filler Common 0', categoryId: '10'),
  for (var i = 0; i < 5; i++)
    XtreamVodStream(streamId: 200 + i, name: 'Filler Movie $i', categoryId: '${10 + i}'),
];

List<XtreamSeries> _seriesRows() => [
  const XtreamSeries(seriesId: _gotSeriesId, name: _gotName, categoryId: _gotCategoryId),
  const XtreamSeries(seriesId: 2, name: 'Filler Common 0', categoryId: '1'),
  for (var i = 0; i < 4; i++)
    XtreamSeries(seriesId: 300 + i, name: 'Filler Series $i', categoryId: '${i + 1}'),
];

/// A fake panel that counts every request, honours AbortableRequest, and
/// answers each Xtream endpoint from the fixture rows above — the
/// unfiltered calls return the whole list, a per-category call returns
/// that category's rows.
class _CountingPanel extends http.BaseClient {
  _CountingPanel();

  /// Simulated per-category latency (always zero unless a test sets it):
  /// lets an abort land mid-request so orphan cancellation is observable.
  Duration categoryLatency = Duration.zero;

  int totalRequests = 0;
  int liveRequests = 0;
  int vodRequests = 0;
  int seriesRequests = 0;
  int categoryRequests = 0;

  void reset() {
    totalRequests = 0;
    liveRequests = 0;
    vodRequests = 0;
    seriesRequests = 0;
    categoryRequests = 0;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final uri = request.url;
    final action = uri.queryParameters['action'];
    final categoryId = uri.queryParameters['category_id'];
    if (categoryId != null) categoryRequests++;
    switch (action) {
      case 'get_live_streams':
        liveRequests++;
      case 'get_vod_streams':
        vodRequests++;
      case 'get_series':
        seriesRequests++;
    }
    final abortTrigger = request is http.AbortableRequest ? request.abortTrigger : null;
    if (abortTrigger != null && categoryLatency > Duration.zero) {
      final outcome = await Future.any([
        Future<void>.delayed(categoryLatency).then((_) => 'done'),
        abortTrigger.then((_) => 'aborted'),
      ]);
      if (outcome == 'aborted') throw http.RequestAbortedException(uri);
    } else if (categoryLatency > Duration.zero) {
      await Future<void>.delayed(categoryLatency);
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
        return jsonEncode(_liveCategories().map((c) => c.toJson()).toList());
      case 'get_vod_categories':
        return jsonEncode(_vodCategories().map((c) => c.toJson()).toList());
      case 'get_series_categories':
        return jsonEncode(_seriesCategories().map((c) => c.toJson()).toList());
      case 'get_live_streams':
        final rows = categoryId == null ? _liveRows() : _liveRows().where((r) => r.categoryId == categoryId).toList();
        return jsonEncode(rows.map((r) => r.toJson()).toList());
      case 'get_vod_streams':
        final rows = categoryId == null ? _vodRows() : _vodRows().where((r) => r.categoryId == categoryId).toList();
        return jsonEncode(rows.map((r) => r.toJson()).toList());
      case 'get_series':
        final rows = categoryId == null
            ? _seriesRows()
            : _seriesRows().where((r) => r.categoryId == categoryId).toList();
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

IptvClient _clientWith(_CountingPanel panel, {List<String> hiddenInitials = const []}) {
  final connection = XtreamConnection(
    id: 'conn-xt-1',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    hiddenCategoryInitials: hiddenInitials,
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

/// Seed the disk catalogs + category files (the shape the phone has
/// after a normal browse): all three types, every category represented,
/// so the warm-up seed has a complete source to build the index from.
Future<void> _seedDisk() async {
  final cache = IptvCatalogDiskCache();
  await cache.write('conn-xt-1', IptvCatalogDiskCache.liveDataset, jsonEncode(_liveRows().map((r) => r.toJson()).toList()));
  await cache.write('conn-xt-1', IptvCatalogDiskCache.vodDataset, jsonEncode(_vodRows().map((r) => r.toJson()).toList()));
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.seriesDataset,
    jsonEncode(_seriesRows().map((r) => r.toJson()).toList()),
  );
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.liveCategoriesDataset,
    jsonEncode(_liveCategories().map((c) => c.toJson()).toList()),
  );
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.vodCategoriesDataset,
    jsonEncode(_vodCategories().map((c) => c.toJson()).toList()),
  );
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.seriesCategoriesDataset,
    jsonEncode(_seriesCategories().map((c) => c.toJson()).toList()),
  );
}

/// Warm all three catalogs the way the bind does. The warm-up also
/// seeds the search index from disk (build #23) — fire-and-forget, so
/// this only starts it; [_waitForIndex] waits for it to land.
void _warmAll(IptvClient client) {
  client.warmUpSeriesCatalog();
  client.warmUpVodCatalog();
  client.warmUpLiveCatalog();
}

/// Wait until a throwaway search answers from the index in ALL three
/// sections (`loadSource == 'index'`). The throwaway query matches the
/// 'Filler Common 0' row seeded in every type, so the warm path returns
/// it with no sweep before the seed lands and the index path returns it
/// after — the poll itself never pays a sweep either way. Returns false
/// on timeout (on base the index never exists, so this is the
/// failing-first signal).
Future<bool> _waitForIndex(IptvClient client, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await client.searchItems('Filler Common 0');
    final diag = client.lastSearchDiagnostics;
    if (diag != null &&
        diag.movies.loadSource == 'index' &&
        diag.series.loadSource == 'index' &&
        diag.live.loadSource == 'index') {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build23_');
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

  group('Build #23 — search must be local-only when the index is warm', () {
    test('a warm search for a title that matches nothing makes 0 panel requests', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      await _seedDisk();
      _warmAll(client);
      final warm = await _waitForIndex(client);
      // ignore: avoid_print
      print('BUILD23-warm-no-match: indexWarm=$warm panelRequests=${panel.totalRequests}');
      expect(warm, isTrue, reason: 'the warm-up seed must build the index from the disk catalog');
      panel.reset();
      final results = await client.searchItems('zz-no-match-zz');
      final diag = client.lastSearchDiagnostics!;
      // ignore: avoid_print
      print(
        'BUILD23-warm-no-match: results=${results.length} requests=${panel.totalRequests} '
        'movies=${diag.movies.loadSource} series=${diag.series.loadSource} live=${diag.live.loadSource}',
      );
      expect(results, isEmpty);
      expect(panel.totalRequests, 0, reason: 'a warm search must not touch the panel at all — no heal sweep');
      expect(diag.movies.loadSource, 'index');
      expect(diag.series.loadSource, 'index');
      expect(diag.live.loadSource, 'index');
    });

    test('Game of Thrones is found from the index with 0 panel requests', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      await _seedDisk();
      _warmAll(client);
      final warm = await _waitForIndex(client);
      expect(warm, isTrue, reason: 'the warm-up seed must build the index from the disk catalog');
      panel.reset();
      final results = await client.searchItems('game of thrones');
      final diag = client.lastSearchDiagnostics!;
      // ignore: avoid_print
      print(
        'BUILD23-got: titles=${results.map((i) => i.title).toList()} requests=${panel.totalRequests} '
        'series=${diag.series.loadSource} seriesRows=${diag.series.loadRows}',
      );
      expect(results.map((i) => i.title), contains(_gotName));
      expect(panel.totalRequests, 0, reason: 'GoT must come from the local index, not a panel sweep');
      expect(diag.series.loadSource, 'index');
    });

    test('a Trex-scoped search still finds only Trex series, with 0 panel requests', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      await _seedDisk();
      _warmAll(client);
      final warm = await _waitForIndex(client);
      expect(warm, isTrue, reason: 'the warm-up seed must build the index from the disk catalog');
      panel.reset();
      // Scope to the Trex Series library (build #19's scopedLibraryKey
      // shape): the client returns the global index result and the
      // aggregation filters — but at the client level the series leg
      // must still answer from the index with no panel traffic.
      final results = await client.searchItems(
        'game of thrones',
        excludedLibraryIds: {'iptv:conn-xt-1:movies'},
      );
      final diag = client.lastSearchDiagnostics!;
      // ignore: avoid_print
      print(
        'BUILD23-scoped: titles=${results.map((i) => i.title).toList()} requests=${panel.totalRequests} '
        'series=${diag.series.loadSource}',
      );
      expect(results.map((i) => i.title), contains(_gotName));
      expect(panel.totalRequests, 0);
      expect(diag.series.loadSource, 'index');
    });

    test('a hidden category still hides its rows when the search answers from the index', () async {
      // Hide the FR initial: the FR filler rows (Live 2, Movies 11,
      // Series 2) must not match, while the EN GoT row still does.
      final panel = _CountingPanel();
      final client = _clientWith(panel, hiddenInitials: const ['FR']);
      await _seedDisk();
      _warmAll(client);
      final warm = await _waitForIndex(client);
      expect(warm, isTrue, reason: 'the warm-up seed must build the index from the disk catalog');
      panel.reset();
      final results = await client.searchItems('Filler');
      // ignore: avoid_print
      print(
        'BUILD23-hidden: titles=${results.map((i) => i.title).toList()} requests=${panel.totalRequests} '
        'hiddenMatches=${client.lastSearchDiagnostics!.series.hiddenMatches}',
      );
      expect(panel.totalRequests, 0);
      // The FR rows are hidden by their category initial; the EN/DE/ES/IT
      // filler rows still match.
      expect(results.map((i) => i.title), isNot(contains('Filler Series 1')));
      expect(results.map((i) => i.title), contains('Filler Series 0'));
    });
  });
}
