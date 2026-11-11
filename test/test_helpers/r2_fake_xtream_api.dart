// R2 (v1.0.11) shared fake panel — a counting XtreamApi for the
// search-rule tests. No live panel: fakes only (panel.example.com).
//
// Counts every panel request by shape so the tests can prove the
// SEARCH RULE (typing = 0 requests in every state; Enter = one
// coalesced sync, 6 requests, no per-category sweep requests):
// * [totalRequests] — every method call (one call = one panel request).
// * [categoryListRequests] — get*Categories calls.
// * [catalogRequests] — unfiltered get_live_streams / get_vod_streams /
//   get_series calls.
// * [perCategoryRequests] — the same calls WITH a category_id (the
//   sweep's shape — must stay 0 after R2.3).
// * [userInfoRequests] — getUserInfo calls.
//
// Failure modes (set before the call under test):
// * [failCatalogs] — every catalog + category fetch throws a
//   connectionTimeout, like Matt's manual refresh on 2026-11-11 (the
//   panel answers nothing at all).
// * [failOnceClosedTypes] — the first unfiltered fetch of each named
//   type ('live' | 'movie' | 'series') throws a connectionError
//   ("connection closed while receiving data") and then succeeds —
//   the R2.4 retry shape.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

const r2TestPassword = 'pa' 'ss';

const r2GotSeriesId = 219;
const r2GotCategoryId = '1219';
const r2GotName = 'EN - Game Of Thrones (2011)';

List<XtreamCategory> r2FixtureLiveCategories() => const [
  XtreamCategory(id: '1', name: '|EN| Live 1'),
  XtreamCategory(id: '2', name: '|FR| Live 2'),
  XtreamCategory(id: '3', name: '|DE| Live 3'),
  XtreamCategory(id: '4', name: '|ES| Live 4'),
  XtreamCategory(id: '5', name: '|IT| Live 5'),
];

List<XtreamCategory> r2FixtureVodCategories() => const [
  XtreamCategory(id: '10', name: '|EN| Movies 10'),
  XtreamCategory(id: '11', name: '|FR| Movies 11'),
  XtreamCategory(id: '12', name: '|DE| Movies 12'),
  XtreamCategory(id: '13', name: '|ES| Movies 13'),
  XtreamCategory(id: '14', name: '|IT| Movies 14'),
];

List<XtreamCategory> r2FixtureSeriesCategories() => const [
  XtreamCategory(id: '1', name: '|EN| Series 1'),
  XtreamCategory(id: '2', name: '|FR| Series 2'),
  XtreamCategory(id: '3', name: '|DE| Series 3'),
  XtreamCategory(id: '4', name: '|ES| Series 4'),
  XtreamCategory(id: r2GotCategoryId, name: '|EN| TOP SERIES'),
];

List<XtreamLiveStream> r2FixtureLiveRows() => [
  const XtreamLiveStream(streamId: 1, name: 'Filler Common 0', categoryId: '1', epgChannelId: 'ch1'),
  for (var i = 0; i < 5; i++)
    XtreamLiveStream(streamId: 100 + i, name: 'Live Channel $i', categoryId: '${i + 1}', epgChannelId: 'ch${100 + i}'),
];

List<XtreamVodStream> r2FixtureVodRows() => [
  const XtreamVodStream(streamId: 1, name: 'Filler Common 0', categoryId: '10'),
  for (var i = 0; i < 5; i++)
    XtreamVodStream(streamId: 200 + i, name: 'Filler Movie $i', categoryId: '${10 + i}'),
];

List<XtreamSeries> r2FixtureSeriesRows() => [
  const XtreamSeries(seriesId: r2GotSeriesId, name: r2GotName, categoryId: r2GotCategoryId),
  const XtreamSeries(seriesId: 2, name: 'Filler Common 0', categoryId: '1'),
  for (var i = 0; i < 4; i++)
    XtreamSeries(seriesId: 300 + i, name: 'Filler Series $i', categoryId: '${i + 1}'),
];

class R2FakeXtreamApi extends XtreamApi {
  R2FakeXtreamApi({
    List<XtreamLiveStream>? liveRows,
    List<XtreamVodStream>? vodRows,
    List<XtreamSeries>? seriesRows,
    List<XtreamCategory>? liveCategories,
    List<XtreamCategory>? vodCategories,
    List<XtreamCategory>? seriesCategories,
  }) : _liveRows = liveRows ?? r2FixtureLiveRows(),
       _vodRows = vodRows ?? r2FixtureVodRows(),
       _seriesRows = seriesRows ?? r2FixtureSeriesRows(),
       _liveCategories = liveCategories ?? r2FixtureLiveCategories(),
       _vodCategories = vodCategories ?? r2FixtureVodCategories(),
       _seriesCategories = seriesCategories ?? r2FixtureSeriesCategories(),
       super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: r2TestPassword);

  final List<XtreamLiveStream> _liveRows;
  final List<XtreamVodStream> _vodRows;
  final List<XtreamSeries> _seriesRows;
  final List<XtreamCategory> _liveCategories;
  final List<XtreamCategory> _vodCategories;
  final List<XtreamCategory> _seriesCategories;

  int totalRequests = 0;
  int categoryListRequests = 0;
  int catalogRequests = 0;
  int perCategoryRequests = 0;
  int userInfoRequests = 0;

  /// When true, every catalog + category fetch throws a connection
  /// timeout (the panel answers nothing).
  bool failCatalogs = false;

  /// When true, only the unfiltered catalog fetches throw a connection
  /// timeout — the category lists still answer (R2.3: the sync attempts
  /// the full 6 requests and records every type failed).
  bool failCatalogFetches = false;

  /// Ordered log of request shapes, for debugging the request contract
  /// ('user-info', 'live-categories', 'vod-catalog', 'series-cat:1219', …).
  final List<String> requestLog = [];

  /// Types whose FIRST unfiltered catalog fetch throws a connection
  /// error ("connection closed while receiving data") and then
  /// succeeds. 'live' | 'movie' | 'series'.
  Set<String> failOnceClosedTypes = {};
  final Set<String> _closedFailed = {};

  void resetCounts() {
    totalRequests = 0;
    categoryListRequests = 0;
    catalogRequests = 0;
    perCategoryRequests = 0;
    userInfoRequests = 0;
    requestLog.clear();
    _closedFailed.clear();
  }

  Never _catalogTimeout() => throw MediaServerHttpException(
    type: MediaServerHttpErrorType.connectionTimeout,
    message: 'Future not completed',
  );

  Never _connectionClosed() => throw MediaServerHttpException(
    type: MediaServerHttpErrorType.connectionError,
    message: 'Connection closed while receiving data',
  );

  void _maybeFailOnce(String type) {
    if (failOnceClosedTypes.contains(type) && _closedFailed.add(type)) {
      _connectionClosed();
    }
  }

  @override
  Future<Map<String, dynamic>?> getUserInfo() async {
    totalRequests++;
    userInfoRequests++;
    requestLog.add('user-info');
    return {
      'user_info': {'status': 'Active', 'exp_date': '1790000000', 'max_connections': '1'},
    };
  }

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async {
    totalRequests++;
    categoryListRequests++;
    requestLog.add('live-categories');
    if (failCatalogs) _catalogTimeout();
    return _liveCategories;
  }

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async {
    totalRequests++;
    categoryListRequests++;
    requestLog.add('vod-categories');
    if (failCatalogs) _catalogTimeout();
    return _vodCategories;
  }

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async {
    totalRequests++;
    categoryListRequests++;
    requestLog.add('series-categories');
    if (failCatalogs) _catalogTimeout();
    return _seriesCategories;
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    totalRequests++;
    requestLog.add(categoryId == null ? 'live-catalog' : 'live-cat:$categoryId');
    if (categoryId == null) {
      catalogRequests++;
      if (failCatalogs || failCatalogFetches) _catalogTimeout();
      _maybeFailOnce(IptvSearchIndex.typeLive);
      // The real XtreamApi stores the raw body for the sync (which
      // writes it to the index + disk); a fake that returns rows without
      // it makes the sync skip the type as 'empty-response'.
      lastLiveStreamsBody = jsonEncode(_liveRows.map((r) => r.toJson()).toList());
      return _liveRows;
    }
    perCategoryRequests++;
    if (failCatalogs) _catalogTimeout();
    return _liveRows.where((r) => r.categoryId == categoryId).toList();
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    totalRequests++;
    requestLog.add(categoryId == null ? 'vod-catalog' : 'vod-cat:$categoryId');
    if (categoryId == null) {
      catalogRequests++;
      if (failCatalogs || failCatalogFetches) _catalogTimeout();
      _maybeFailOnce(IptvSearchIndex.typeMovie);
      lastVodStreamsBody = jsonEncode(_vodRows.map((r) => r.toJson()).toList());
      return _vodRows;
    }
    perCategoryRequests++;
    if (failCatalogs) _catalogTimeout();
    return _vodRows.where((r) => r.categoryId == categoryId).toList();
  }

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    totalRequests++;
    requestLog.add(categoryId == null ? 'series-catalog' : 'series-cat:$categoryId');
    if (categoryId == null) {
      catalogRequests++;
      if (failCatalogs || failCatalogFetches) _catalogTimeout();
      _maybeFailOnce(IptvSearchIndex.typeSeries);
      lastSeriesBody = jsonEncode(_seriesRows.map((r) => r.toJson()).toList());
      return _seriesRows;
    }
    perCategoryRequests++;
    if (failCatalogs) _catalogTimeout();
    return _seriesRows.where((r) => r.categoryId == categoryId).toList();
  }
}

/// A real [IptvClient] wired to [R2FakeXtreamApi] (fake panel only).
IptvClient r2ClientWith(R2FakeXtreamApi api) {
  final connection = XtreamConnection(
    id: 'conn-xt-1',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: r2TestPassword,
    createdAt: DateTime.utc(2026, 11, 5),
  );
  final client = IptvClient.forConnection(connection);
  client.testXtreamApi = api;
  addTearDown(client.close);
  return client;
}

/// Seed all six disk files (catalogs + category lists) from the small
/// fixtures — the shape the phone has after a normal browse.
Future<void> r2SeedDisk() async {
  final cache = IptvCatalogDiskCache();
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.liveDataset,
    jsonEncode(r2FixtureLiveRows().map((r) => r.toJson()).toList()),
  );
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.vodDataset,
    jsonEncode(r2FixtureVodRows().map((r) => r.toJson()).toList()),
  );
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.seriesDataset,
    jsonEncode(r2FixtureSeriesRows().map((r) => r.toJson()).toList()),
  );
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.liveCategoriesDataset,
    jsonEncode(r2FixtureLiveCategories().map((c) => c.toJson()).toList()),
  );
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.vodCategoriesDataset,
    jsonEncode(r2FixtureVodCategories().map((c) => c.toJson()).toList()),
  );
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.seriesCategoriesDataset,
    jsonEncode(r2FixtureSeriesCategories().map((c) => c.toJson()).toList()),
  );
}

/// Warm the index for movies + live only (series stays cold): the shape
/// of Matt's phone on 2026-11-11, where the series index never got rows.
/// The stamps are 8 days old (past the weekly interval), so a sync is
/// DUE for every type.
Future<void> r2WarmMoviesAndLiveOnly() async {
  final staleMs = DateTime.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch;
  final index = await IptvSearchIndex.open();
  index.replaceType(
    connectionId: 'conn-xt-1',
    type: IptvSearchIndex.typeMovie,
    rows: r2FixtureVodRows().map(IptvSearchIndexRow.fromMovie).toList(),
    categories: {for (final c in r2FixtureVodCategories()) c.id: c.name},
    syncStampMs: staleMs,
  );
  index.replaceType(
    connectionId: 'conn-xt-1',
    type: IptvSearchIndex.typeLive,
    rows: r2FixtureLiveRows().map(IptvSearchIndexRow.fromLive).toList(),
    categories: {for (final c in r2FixtureLiveCategories()) c.id: c.name},
    syncStampMs: staleMs,
  );
  index.close();
}

/// Push every disk file's mtime back by [age], so the files read as
/// fetched that long ago (the seed stamps the index with the disk
/// file's age — a backdated disk makes the type DUE for the sync).
Future<void> r2BackdateDisk(Directory tempDir, Duration age) async {
  final files = await tempDir.list(recursive: true).where((e) => e.path.endsWith('.json')).toList();
  expect(files, isNotEmpty, reason: 'the disk catalogs must be seeded before backdating');
  for (final file in files) {
    await (file as File).setLastModified(DateTime.now().subtract(age));
  }
}

/// Poll until [condition] holds or [timeout] expires.
Future<void> r2WaitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Poll until the panel request count has been stable for ~500 ms (the
/// fire-and-forget sync has landed or will never come), or the timeout
/// expires. Returns the stable count.
Future<int> r2WaitForQuiescent(R2FakeXtreamApi api, {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  var last = api.totalRequests;
  var stablePolls = 0;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (api.totalRequests == last) {
      if (++stablePolls >= 5) return api.totalRequests;
    } else {
      last = api.totalRequests;
      stablePolls = 0;
    }
  }
  return api.totalRequests;
}
