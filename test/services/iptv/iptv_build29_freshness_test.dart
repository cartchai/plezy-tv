// BUILD v1.0.10 — one freshness rule (R1/M3) + seed stamps real age (M1)
// + FTS rank order (M2).
//
// THE PHONE FAILURES (deep audit, 2026-11-10, base 7fd694f65):
// * M2 — FTS returns rows in insertion order, not rank order, so the
//   100-row per-section cap can cut the exact match: search for a popular
//   title drops the exact title entirely. Verified with sqlite3 on the
//   same FTS5 trigram shape.
// * M1 — the disk seed stamps stale data as freshly synced
//   (syncStampMs: nowMs), so the weekly sync then does nothing for a
//   week and search silently serves old titles stamped as fresh.
// * M3/R1 — the 24 h disk TTL and the 168 h sync interval disagree, and
//   every stale-disk browse load fires _refreshCatalogInBackground, a
//   full re-download that bypasses the #23 sync guards and never writes
//   the index. Disk, memory and index diverge by design; a partial panel
//   answer can clobber a good disk file through this side door (live has
//   no partial guard at all — M4), and the memoized category futures
//   never learn the synced names (M5).
//
// THE FIX: ORDER BY rank in the FTS arm (+ a bounded query limit) and a
// bound on the LIKE arm; the seed stamps each disk file's real fetchedAt;
// the browse refresh is routed through syncSearchIndex — one fetch feeds
// disk + index under the guards, and the disk TTL follows the sync
// interval (manual-only interval 0 means no automatic refresh at all).
// The sync also publishes the synced categories into the memoized
// futures (and clears the derived names futures), and notifies the
// library views when a sync publishes fresh rows.
//
// These tests use only the pre-fix public API, so they FAIL on base
// b98804227 and PASS on the fix. No live panel: fakes only.

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
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';

const _gotSeriesId = 219;
const _gotCategoryId = '1219';
const _gotName = 'EN - Game Of Thrones (2011)';
/// The bare title the M2 regression test uses (see the M2 group note):
/// the audit's probe shape, where ORDER BY rank puts the exact match
/// first. The real Trex title is [_gotName].
const _m2ExactName = 'game of thrones';

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
/// per-category) and counts requests by action.
class _SyncPanel extends http.BaseClient {
  _SyncPanel({
    List<XtreamLiveStream>? liveRows,
    List<XtreamVodStream>? vodRows,
    List<XtreamSeries>? seriesRows,
    List<XtreamCategory>? liveCategories,
    List<XtreamCategory>? vodCategories,
    List<XtreamCategory>? seriesCategories,
  }) : _liveRows = liveRows ?? _liveRowsDefault(),
       _vodRows = vodRows ?? _vodRowsDefault(),
       _seriesRows = seriesRows ?? _seriesRowsDefault(),
       _liveCategories = liveCategories ?? _liveCategoriesDefault(),
       _vodCategories = vodCategories ?? _vodCategoriesDefault(),
       _seriesCategories = seriesCategories ?? _seriesCategoriesDefault();

  static List<XtreamLiveStream> _liveRowsDefault() => _fixtureLiveRows();
  static List<XtreamVodStream> _vodRowsDefault() => _fixtureVodRows();
  static List<XtreamSeries> _seriesRowsDefault() => _fixtureSeriesRows();
  static List<XtreamCategory> _liveCategoriesDefault() => _fixtureLiveCategories();
  static List<XtreamCategory> _vodCategoriesDefault() => _fixtureVodCategories();
  static List<XtreamCategory> _seriesCategoriesDefault() => _fixtureSeriesCategories();

  final List<XtreamLiveStream> _liveRows;
  final List<XtreamVodStream> _vodRows;
  final List<XtreamSeries> _seriesRows;
  final List<XtreamCategory> _liveCategories;
  final List<XtreamCategory> _vodCategories;
  final List<XtreamCategory> _seriesCategories;

  int totalRequests = 0;
  int catalogRequests = 0;
  int categoryListRequests = 0;
  int liveRequests = 0;
  int userInfoRequests = 0;

  void reset() {
    totalRequests = 0;
    catalogRequests = 0;
    categoryListRequests = 0;
    liveRequests = 0;
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
      if (action == 'get_live_streams' && categoryId == null) liveRequests++;
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
        final rows = categoryId == null ? _seriesRows : _seriesRows.where((r) => r.categoryId == categoryId).toList();
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

/// Seed all six disk files (catalogs + category lists) from the small
/// fixtures — the shape the phone has after a normal browse.
Future<void> _seedDisk() async {
  final cache = IptvCatalogDiskCache();
  await cache.write('conn-xt-1', IptvCatalogDiskCache.liveDataset, jsonEncode(_fixtureLiveRows().map((r) => r.toJson()).toList()));
  await cache.write('conn-xt-1', IptvCatalogDiskCache.vodDataset, jsonEncode(_fixtureVodRows().map((r) => r.toJson()).toList()));
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.seriesDataset,
    jsonEncode(_fixtureSeriesRows().map((r) => r.toJson()).toList()),
  );
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.liveCategoriesDataset,
    jsonEncode(_fixtureLiveCategories().map((c) => c.toJson()).toList()),
  );
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.vodCategoriesDataset,
    jsonEncode(_fixtureVodCategories().map((c) => c.toJson()).toList()),
  );
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.seriesCategoriesDataset,
    jsonEncode(_fixtureSeriesCategories().map((c) => c.toJson()).toList()),
  );
}

/// Push every disk catalog/category file's mtime back by [age], so the
/// files read as fetched that long ago.
Future<void> _backdateDisk(Directory tempDir, Duration age) async {
  final files = await tempDir.list(recursive: true).where((e) => e.path.endsWith('.json')).toList();
  expect(files, isNotEmpty, reason: 'the disk catalogs must be seeded before backdating');
  for (final file in files) {
    await (file as File).setLastModified(DateTime.now().subtract(age));
  }
}

/// Browse every catalog + category list the way the app does: live
/// channels, the Discover hubs (VOD + series catalogs), and the three
/// category lists. Each loader serves its disk rows and (on the old
/// code) fires its own background refresh when the disk is stale.
Future<void> _browseAll(IptvClient client) async {
  await client.iptvChannels();
  await client.fetchGlobalHubs();
  await client.liveCategories();
  await client.vodCategories();
  await client.seriesCategories();
}

/// Poll until the panel request count has been stable for ~500 ms (the
/// fire-and-forget refresh/sync has landed or will never come), or the
/// timeout expires. Returns the stable count.
Future<int> _waitForQuiescent(
  _SyncPanel panel, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  var last = panel.totalRequests;
  var stablePolls = 0;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (panel.totalRequests == last) {
      if (++stablePolls >= 5) return panel.totalRequests;
    } else {
      last = panel.totalRequests;
      stablePolls = 0;
    }
  }
  return panel.totalRequests;
}

Future<void> _waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build29_');
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

  group('Build v1.0.10 — M2: FTS rank order', () {
    // The regression test for M2 lives at the INDEX level (the layer
    // M2 changes). The exact row is the bare title 'game of thrones'
    // — the shape the audit probed with sqlite3 ("exact `game of
    // thrones` first only with ORDER BY rank").
    //
    // NOTE on scope (measured 2026-11-10, sqlite3 probe on the exact
    // query shape): a CLIENT-level version of this test — the real Trex
    // title 'EN - Game Of Thrones (2011)' against 250 shorter 'zzzz
    // game of thrones N' rows — cannot pass with rank order alone, so
    // there is deliberately no client-level M2 test here. BM25 scores
    // by document length, so the longer decorated title ranks 251st of
    // 251 (rank -1.878e-06 vs -1.984e-06..-2.062e-06 for the zzzz rows)
    // and the 200-row SQL cap still cuts it; the caller's 0–1000
    // scorer has the same length bias (a contains match scores 800 +
    // closeness, shorter wins), so no near-match count separates base
    // from fix at the client level either. The exact-match guarantee
    // for decorated titles against shorter near-matches is R2's scorer
    // work, not M2's SQL order. What M2 owns is the SQL order + cap,
    // proven by the test below.
    test('the FTS arm returns best-ranked rows first, capped in SQL', () async {
      final index = IptvSearchIndex.memory();
      addTearDown(index.close);
      final rows = [
        for (var i = 0; i < 250; i++)
          IptvSearchIndexRow.fromSeries(
            XtreamSeries(seriesId: 1000 + i, name: 'zzzz game of thrones $i', categoryId: '1'),
          ),
        IptvSearchIndexRow.fromSeries(const XtreamSeries(seriesId: _gotSeriesId, name: _m2ExactName, categoryId: _gotCategoryId)),
      ];
      index.replaceType(
        connectionId: 'conn-xt-1',
        type: IptvSearchIndex.typeSeries,
        rows: rows,
        categories: {for (final c in _fixtureSeriesCategories()) c.id: c.name},
        syncStampMs: DateTime.now().millisecondsSinceEpoch,
      );
      final found = index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'game of thrones');
      // ignore: avoid_print
      print('BUILD29-m2-rank: first=${found.isEmpty ? '<none>' : found.first.name} count=${found.length}');
      expect(found.length, lessThanOrEqualTo(200), reason: 'the query limit is pushed into SQL, not applied after materializing everything');
      expect(found.first.name, _m2ExactName, reason: 'ORDER BY rank puts the exact match first — on base the first row is a zzzz row');
    });

    test('the LIKE fallback for short tokens is bounded', () async {
      final index = IptvSearchIndex.memory();
      addTearDown(index.close);
      final rows = [
        for (var i = 0; i < 300; i++)
          IptvSearchIndexRow.fromSeries(XtreamSeries(seriesId: 2000 + i, name: 'King of Thieves $i', categoryId: '1')),
      ];
      index.replaceType(
        connectionId: 'conn-xt-1',
        type: IptvSearchIndex.typeSeries,
        rows: rows,
        categories: {for (final c in _fixtureSeriesCategories()) c.id: c.name},
        syncStampMs: DateTime.now().millisecondsSinceEpoch,
      );
      // 'of' has no token >= 3 chars, so this takes the LIKE arm — on
      // base it has no LIMIT at all and materializes all 300 rows.
      final found = index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'of');
      // ignore: avoid_print
      print('BUILD29-m2-like: count=${found.length}');
      expect(found.length, lessThanOrEqualTo(200), reason: 'the LIKE arm must be bounded like the FTS arm');
      expect(found.map((r) => r.name), contains('King of Thieves 0'));
    });
  });

  group('Build v1.0.10 — M1: the seed stamps the disk file real age', () {
    test('a seed from an 8-day-old disk stamps 8 days, so the sync that follows actually fires', () async {
      final panel = _SyncPanel();
      final client = _clientWith(panel);
      await _seedDisk();
      await _backdateDisk(tempDir, const Duration(days: 8));
      await client.seedSearchIndexFromDisk();
      final lastSync = client.searchIndexState.lastSync[IptvSearchIndex.typeSeries];
      // ignore: avoid_print
      print('BUILD29-m1-stamp: lastSync=$lastSync age=${lastSync == null ? 'null' : DateTime.now().difference(lastSync)}');
      expect(lastSync, isNotNull, reason: 'the seed must stamp every type it seeds');
      final age = DateTime.now().difference(lastSync!);
      expect(age.inDays, greaterThanOrEqualTo(7), reason: 'the stamp must be the disk file real age, not now');
      expect(age.inDays, lessThanOrEqualTo(9));
      // And the sync that follows must NOT skip: 8 days > the weekly
      // interval, so all three types fetch (6 requests). On base the
      // seed stamped now, so the sync skips everything as up-to-date.
      panel.reset();
      final result = await client.syncSearchIndex();
      // ignore: avoid_print
      print('BUILD29-m1-sync: requests=${panel.totalRequests} skipped=${result.skipped} rows=${result.rows}');
      expect(panel.totalRequests, 6, reason: 'a stale disk must still sync — the seed must not lie about its age');
      expect(result.skipped, isEmpty);
    });
  });

  group('Build v1.0.10 — M3: one freshness rule', () {
    test('a browse with a stale disk but a fresh index makes 0 panel requests', () async {
      final panel = _SyncPanel();
      final client = _clientWith(panel);
      await _seedDisk();
      // Two days old: stale under the old 24 h disk TTL, but fresh
      // under the weekly sync interval — the index the seed stamps
      // from this disk is 2 days old, so no sync is due.
      await _backdateDisk(tempDir, const Duration(days: 2));
      await client.seedSearchIndexFromDisk();
      expect(client.searchIndexState.lastSync[IptvSearchIndex.typeSeries], isNotNull);
      panel.reset();
      await _browseAll(client);
      await Future<void>.delayed(const Duration(seconds: 1));
      // ignore: avoid_print
      print('BUILD29-m3a: requests=${panel.totalRequests} catalog=${panel.catalogRequests} lists=${panel.categoryListRequests}');
      expect(
        panel.totalRequests,
        0,
        reason: 'browse serves the disk and refreshes only when the sync interval says so — on base each loader fires its own background refresh',
      );
    });

    test('a browse with a stale disk AND a due index runs one sync, not a refresh plus a sync', () async {
      final panel = _SyncPanel();
      final client = _clientWith(panel);
      await _seedDisk();
      await _backdateDisk(tempDir, const Duration(days: 8));
      // Stamp the index 8 days old directly (bypassing the seed, so
      // the stamp is old on base too): the bind sync is due, and the
      // browse must join it instead of firing its own refreshes.
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
      // The bind fires its sync in the background, exactly as the app
      // does at startup; the browse happens at the same time.
      unawaited(client.ensureSearchIndexSynced());
      await _browseAll(client);
      final total = await _waitForQuiescent(panel);
      // ignore: avoid_print
      print('BUILD29-m3b: total=$total catalog=${panel.catalogRequests} lists=${panel.categoryListRequests}');
      expect(
        total,
        6,
        reason: 'one sync (3 catalogs + 3 lists) feeds disk + index — on base the bind sync (6) plus the browse refreshes (6) fetch the same catalogs twice',
      );
      expect(panel.catalogRequests, 3);
      expect(panel.categoryListRequests, 3);
      // And the search now answers from the refreshed index.
      final results = await client.searchItems('game of thrones');
      expect(results.map((i) => i.title), contains(_gotName));
      expect(panel.totalRequests, 6, reason: 'the search after the browse must stay local-only');
    });

    test('manual-only interval (0) means a browse never refreshes', () async {
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvCatalogSyncIntervalHours, 0);
      final panel = _SyncPanel();
      final client = _clientWith(panel);
      await _seedDisk();
      await _backdateDisk(tempDir, const Duration(days: 8));
      await client.seedSearchIndexFromDisk();
      panel.reset();
      await _browseAll(client);
      await Future<void>.delayed(const Duration(seconds: 1));
      // ignore: avoid_print
      print('BUILD29-m3c: requests=${panel.totalRequests}');
      expect(
        panel.totalRequests,
        0,
        reason: 'manual-only means no automatic refresh at all — on base the browse refresh ignores the interval and fires anyway',
      );
      // A manual refresh still syncs.
      panel.reset();
      final forced = await client.syncSearchIndex(force: true);
      expect(panel.totalRequests, 6);
      expect(forced.skipped, isEmpty);
    });

    test('a partial live list never overwrites a good disk file (M4, live gains the guard)', () async {
      // 100 live rows on disk (8 days old, so the sync is due); the
      // panel answers the unfiltered live call with 10 rows.
      final diskLive = [
        for (var i = 0; i < 100; i++)
          XtreamLiveStream(streamId: 400000 + i, name: 'Live Channel $i', categoryId: '${(i % 5) + 1}', epgChannelId: 'ch$i'),
      ];
      final panelLive = [
        for (var i = 0; i < 10; i++)
          XtreamLiveStream(streamId: 500000 + i, name: 'New Live Channel $i', categoryId: '1', epgChannelId: 'new$i'),
      ];
      final cache = IptvCatalogDiskCache();
      await cache.write('conn-xt-1', IptvCatalogDiskCache.liveDataset, jsonEncode(diskLive.map((r) => r.toJson()).toList()));
      await cache.write('conn-xt-1', IptvCatalogDiskCache.vodDataset, jsonEncode(_fixtureVodRows().map((r) => r.toJson()).toList()));
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(_fixtureSeriesRows().map((r) => r.toJson()).toList()),
      );
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.liveCategoriesDataset,
        jsonEncode(_fixtureLiveCategories().map((c) => c.toJson()).toList()),
      );
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.vodCategoriesDataset,
        jsonEncode(_fixtureVodCategories().map((c) => c.toJson()).toList()),
      );
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesCategoriesDataset,
        jsonEncode(_fixtureSeriesCategories().map((c) => c.toJson()).toList()),
      );
      await _backdateDisk(tempDir, const Duration(days: 8));
      final panel = _SyncPanel(liveRows: panelLive);
      final client = _clientWith(panel);
      await client.seedSearchIndexFromDisk();
      expect(client.searchIndexState.rowCounts[IptvSearchIndex.typeLive], 100);
      panel.reset();
      await client.iptvChannels();
      // The live fetch must have happened (the sync ran); give the
      // guarded-out write a moment to (not) land.
      await _waitFor(() => panel.liveRequests > 0);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final disk = await cache.read('conn-xt-1', IptvCatalogDiskCache.liveDataset);
      final diskRows = jsonDecode(disk!.body) as List<dynamic>;
      // ignore: avoid_print
      print('BUILD29-m4: liveRequests=${panel.liveRequests} diskRows=${diskRows.length}');
      expect(
        diskRows.length,
        100,
        reason: 'a 10-row partial live list must not overwrite the 100-row good disk file — on base the live refresh has no guard and writes the 10 rows',
      );
      // The index keeps the old rows too: the old channels still search.
      final results = await client.searchItems('Live Channel 42');
      expect(results.map((i) => i.title), contains('Live Channel 42'));
    });

    test('the sync publishes fresh categories into the memoized futures (M5)', () async {
      final panel = _SyncPanel(
        liveCategories: const [
          XtreamCategory(id: '1', name: '|EN| Live RENAMED'),
          XtreamCategory(id: '2', name: '|FR| Live 2'),
          XtreamCategory(id: '3', name: '|DE| Live 3'),
          XtreamCategory(id: '4', name: '|ES| Live 4'),
          XtreamCategory(id: '5', name: '|IT| Live 5'),
        ],
      );
      final client = _clientWith(panel);
      await _seedDisk();
      // Populate the memoized futures from the disk (old names).
      final before = await client.liveCategories();
      expect(before.map((c) => c.name), contains('|EN| Live 1'));
      final result = await client.syncSearchIndex(force: true);
      expect(result.skipped, isEmpty);
      // ignore: avoid_print
      print('BUILD29-m5: after sync live=${(await client.liveCategories()).map((c) => c.name).toList()}');
      expect(
        (await client.liveCategories()).map((c) => c.name),
        contains('|EN| Live RENAMED'),
        reason: 'the synced categories must reach the memoized futures without a restart — on base the sync never touches them',
      );
      expect((await client.liveCategories()).map((c) => c.name), isNot(contains('|EN| Live 1')));
    });
  });
}
