// BUILD #23 — startup rule, FAILING-FIRST tests (pre-fix API only).
//
// Matt's rule (2026-11-10 ~03:06 EST): the app must NOT reload
// everything from Trex every time it starts. On startup it opens from
// the local synced catalog file only — no whole-catalog re-download,
// no re-talk to Trex on launch. The ONLY panel traffic for the catalog
// is the scheduled refresh (default once a week) and the manual
// refresh button.
//
// These tests use ONLY the pre-fix public API (disk seeding, warm-ups,
// searchItems) so they compile and run on base d937a1797 — and FAIL
// there: on the base, the startup warm-ups call the catalog loaders,
// whose stale-disk background refresh re-downloads all three catalogs
// (3 unfiltered requests) the moment the 24h TTL lapses. On the fix
// the warm-ups are disk-only, so a start with a warm (even stale) disk
// costs 0 catalog requests.
//
// The manager-level bind (warm index -> 0 requests; due weekly refresh
// -> 6 requests in the background) is in
// iptv_build23_local_search_new_api_test.dart — it needs the #23 sync
// API, so it only compiles on the fix.
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
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';

const _gotSeriesId = 219;
const _gotCategoryId = '1219';
const _gotName = 'EN - Game Of Thrones (2011)';

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

/// A fake panel serving the fixture catalogs and counting the
/// UNFILTERED catalog loads (the whole-catalog re-download) separately
/// from the small category lists. The category lists are NOT counted
/// here: the search's cold path fetches them (they are the sweep's
/// lifeline — build #19's heal crawls them), and the index path reads
/// them from the index instead, so they cost 0 when the index is warm
/// (see the manager-level test in the new-API file). What this test
/// pins is the warm-up: it must never re-download the whole catalog.
class _CountingPanel extends http.BaseClient {
  /// Unfiltered get_live_streams / get_vod_streams / get_series — the
  /// whole catalog, 55k / 200k / 46k rows at Trex scale.
  int unfilteredCatalogRequests = 0;
  int categoryListRequests = 0;
  int totalRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final uri = request.url;
    final action = uri.queryParameters['action'];
    final categoryId = uri.queryParameters['category_id'];
    if ((action == 'get_live_streams' || action == 'get_vod_streams' || action == 'get_series') && categoryId == null) {
      unfilteredCatalogRequests++;
    }
    if (action != null && action.endsWith('_categories')) categoryListRequests++;
    return http.StreamedResponse(
      Stream.value(utf8.encode(_bodyFor(action, uri.queryParameters['category_id']))),
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
        final rows = categoryId == null ? _seriesRows() : _seriesRows().where((r) => r.categoryId == categoryId).toList();
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

IptvClient _clientWith(_CountingPanel panel) {
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

/// Seed the disk catalog, then backdate every file's mtime so the
/// catalog reads as STALE (older than the 24h TTL). The disk cache
/// takes fetchedAt from the file's modification time, so this is the
/// state Matt's phone is in on any start more than a day after the
/// last catalog fetch.
Future<void> _seedStaleDisk(Directory tempDir) async {
  const cache = IptvCatalogDiskCache();
  const connectionId = 'conn-xt-1';
  await cache.write(
    connectionId,
    IptvCatalogDiskCache.liveCategoriesDataset,
    jsonEncode(_liveCategories().map((c) => c.toJson()).toList()),
  );
  await cache.write(
    connectionId,
    IptvCatalogDiskCache.vodCategoriesDataset,
    jsonEncode(_vodCategories().map((c) => c.toJson()).toList()),
  );
  await cache.write(
    connectionId,
    IptvCatalogDiskCache.seriesCategoriesDataset,
    jsonEncode(_seriesCategories().map((c) => c.toJson()).toList()),
  );
  await cache.write(
    connectionId,
    IptvCatalogDiskCache.liveDataset,
    jsonEncode(_liveRows().map((r) => r.toJson()).toList()),
  );
  await cache.write(
    connectionId,
    IptvCatalogDiskCache.vodDataset,
    jsonEncode(_vodRows().map((r) => r.toJson()).toList()),
  );
  await cache.write(
    connectionId,
    IptvCatalogDiskCache.seriesDataset,
    jsonEncode(_seriesRows().map((r) => r.toJson()).toList()),
  );
  final staleAt = DateTime.now().subtract(const Duration(days: 2));
  await for (final entity in tempDir.list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.json')) {
      await entity.setLastModified(staleAt);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build23_startup_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
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

  group('Build #23 — startup must not reload the catalog', () {
    test('a start with a stale disk costs 0 catalog requests', () async {
      await _seedStaleDisk(tempDir);
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      // The manager calls these three at bind, before the health probe.
      client.warmUpSeriesCatalog();
      client.warmUpVodCatalog();
      client.warmUpLiveCatalog();
      // The stale-disk background refresh is fire-and-forget: give it
      // time to land (on the base it fires 3 unfiltered fetches).
      await Future<void>.delayed(const Duration(seconds: 2));
      final results = await client.searchItems('game of thrones');
      // ignore: avoid_print
      print(
        'BUILD23-startup: warmUp+search unfiltered=${panel.unfilteredCatalogRequests} '
        'categoryLists=${panel.categoryListRequests} total=${panel.totalRequests} '
        'titles=${results.map((i) => i.title).toList()}',
      );
      // On the base this is 3 (one unfiltered refresh per type) — the
      // whole catalog re-downloaded on every start once the TTL lapses.
      // On the fix the warm-ups are disk-only: 0.
      expect(panel.unfilteredCatalogRequests, 0, reason: 'startup must open from the local file, not re-download the catalog');
      expect(results.map((i) => i.title), contains(_gotName));
    });

    test('a start with a fresh disk also costs 0 catalog requests', () async {
      // Control: a fresh disk never refreshed even on the base, so this
      // passes on both — it pins that the warm-up serves the disk.
      const cache = IptvCatalogDiskCache();
      const connectionId = 'conn-xt-1';
      await cache.write(
        connectionId,
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(_seriesRows().map((r) => r.toJson()).toList()),
      );
      await cache.write(
        connectionId,
        IptvCatalogDiskCache.vodDataset,
        jsonEncode(_vodRows().map((r) => r.toJson()).toList()),
      );
      await cache.write(
        connectionId,
        IptvCatalogDiskCache.liveDataset,
        jsonEncode(_liveRows().map((r) => r.toJson()).toList()),
      );
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      client.warmUpSeriesCatalog();
      client.warmUpVodCatalog();
      client.warmUpLiveCatalog();
      await Future<void>.delayed(const Duration(seconds: 1));
      final results = await client.searchItems('game of thrones');
      // ignore: avoid_print
      print(
        'BUILD23-startup-fresh: unfiltered=${panel.unfilteredCatalogRequests} '
        'categoryLists=${panel.categoryListRequests} '
        'titles=${results.map((i) => i.title).toList()}',
      );
      expect(panel.unfilteredCatalogRequests, 0);
      expect(results.map((i) => i.title), contains(_gotName));
    });
  });
}
