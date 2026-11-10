// Failing-first tests for build #28 (block fixes, v1.0.9).
//
// The fixes do not exist on the base (6fe84db64): these tests reference
// the new API, so they fail to compile there and pass on the fix. No
// live panel: fakes only. Credentials below are fake ('user' / 'pa' 'ss')
// and must never appear in a stored entry.
//
// Covers the client half of #28:
//   * max_connections is cached by the health probe, and the IPTV session
//     requires release-before-open on a single-connection panel.
//   * a refused panel is not re-probed on every resume (refusal-log
//     backoff).
//   * background work (weekly sync, stale-disk catalog refresh) waits
//     while a stream is playing, and can be cancelled when the app
//     backgrounds.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/iptv_refusal_log.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/connection/connection.dart';

import '../../test_helpers/prefs.dart';

XtreamCategory _cat(String id, String name) => XtreamCategory(id: id, name: name);

List<XtreamCategory> _liveCategories() => [_cat('1', 'EN'), _cat('2', 'FR')];
List<XtreamCategory> _vodCategories() => [_cat('1', 'Movies'), _cat('2', 'Docs')];
List<XtreamCategory> _seriesCategories() => [_cat('1', 'Series'), _cat('1219', '|EN| TOP SERIES')];

const _gotSeriesId = 219;
const _gotName = 'EN - Game Of Thrones (2011)';

List<XtreamLiveStream> _liveRows() => [
  const XtreamLiveStream(streamId: 11, name: 'EN - News', categoryId: '1'),
  const XtreamLiveStream(streamId: 12, name: 'FR - News', categoryId: '2'),
];
List<XtreamVodStream> _vodRows() => [
  const XtreamVodStream(streamId: 21, name: 'Filler Movie 0', categoryId: '1'),
  const XtreamVodStream(streamId: 22, name: 'Filler Movie 1', categoryId: '2'),
];
List<XtreamSeries> _seriesRows() => [
  const XtreamSeries(seriesId: _gotSeriesId, name: _gotName, categoryId: '1219'),
  const XtreamSeries(seriesId: 2, name: 'Filler Common 0', categoryId: '1'),
];

/// A fake panel that counts every request, honours AbortableRequest, and
/// answers each Xtream endpoint from the fixture rows above. The
/// `user_info` reply carries [maxConnections] when set, the way a real
/// panel reports the line's connection limit.
class _CountingPanel extends http.BaseClient {
  _CountingPanel();

  String? maxConnections;
  Duration categoryLatency = Duration.zero;

  int totalRequests = 0;
  int liveRequests = 0;
  int userInfoRequests = 0;

  void reset() {
    totalRequests = 0;
    liveRequests = 0;
    userInfoRequests = 0;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final uri = request.url;
    final action = uri.queryParameters['action'];
    final categoryId = uri.queryParameters['category_id'];
    switch (action) {
      case 'get_live_streams':
        liveRequests++;
      case 'get_vod_streams':
      case 'get_series':
    }
    if (action == null) userInfoRequests++;
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
          'user_info': {
            'status': 'Active',
            'exp_date': '1790000000',
            if (maxConnections != null) 'max_connections': maxConnections,
          },
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
    password: 'pa' 'ss',
    createdAt: DateTime.utc(2026, 11, 5),
  );
  final client = IptvClient.forConnection(connection);
  client.testXtreamApi = XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: 'pa' 'ss',
    httpClient: panel,
  );
  addTearDown(client.close);
  return client;
}

Future<void> _waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

IptvRefusalLog _log() {
  return IptvRefusalLog(
    prefsProvider: BaseSharedPreferencesService.sharedCache,
    networkTypeProvider: () async => 'wifi',
  );
}

IptvRefusalEntry _refusal({int? statusCode = 403, DateTime? timestamp}) {
  return IptvRefusalEntry(
    timestamp: timestamp ?? DateTime.now(),
    connectionId: 'conn-xt-1',
    connectionName: 'Trex',
    action: 'player_api.php?action=get_live_categories',
    statusCode: statusCode,
    failureKind: 'http',
    headers: const {'cf-ray': 'abc123'},
    bodySnippet: 'Forbidden',
    userAgent: 'VLC',
    network: 'wifi',
  );
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  Duration savedTtl = IptvCatalogDiskCache.catalogCacheTtl;
  Duration savedBackoff = IptvClient.refusalProbeBackoff;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build28_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    savedTtl = IptvCatalogDiskCache.catalogCacheTtl;
    savedBackoff = IptvClient.refusalProbeBackoff;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    IptvCatalogDiskCache.catalogCacheTtl = savedTtl;
    IptvClient.refusalProbeBackoff = savedBackoff;
    IptvPlaybackActivity.instance.markIdle();
    IptvPlaybackActivity.debugResetInstance();
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

  group('Build #28 — max_connections is cached by the health probe', () {
    test('checkHealth caches max_connections = 1 and the line is single-connection', () async {
      final panel = _CountingPanel()..maxConnections = '1';
      final client = _clientWith(panel);
      expect(client.maxConnections, isNull);
      expect(client.isSingleConnection, isTrue, reason: 'unknown means wait — a one-connection line is the common Xtream shape');
      await client.checkHealth();
      expect(panel.userInfoRequests, 1);
      expect(client.maxConnections, 1);
      expect(client.isSingleConnection, isTrue);
    });

    test('a 5-connection panel is not single-connection', () async {
      final panel = _CountingPanel()..maxConnections = '5';
      final client = _clientWith(panel);
      await client.checkHealth();
      expect(client.maxConnections, 5);
      expect(client.isSingleConnection, isFalse);
    });

    test('no max_connections in the reply means unknown — wait for release', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      await client.checkHealth();
      expect(client.maxConnections, isNull);
      expect(client.isSingleConnection, isTrue);
    });

    test('the IPTV session requires release-before-open on a single-connection panel only', () async {
      final single = _CountingPanel()..maxConnections = '1';
      final singleClient = _clientWith(single);
      await singleClient.checkHealth();
      final singleSession = IptvLiveTvPlaybackSession(
        client: singleClient,
        channelKey: 'ch-1',
        liveUrl: 'https://panel.example.com/live/user/pa' 'ss/1.m3u8',
        archiveDurationSeconds: 0,
      );
      expect(singleSession.requiresReleaseBeforeOpen, isTrue);

      final multi = _CountingPanel()..maxConnections = '5';
      final multiClient = _clientWith(multi);
      await multiClient.checkHealth();
      final multiSession = IptvLiveTvPlaybackSession(
        client: multiClient,
        channelKey: 'ch-1',
        liveUrl: 'https://panel.example.com/live/user/pa' 'ss/1.m3u8',
        archiveDurationSeconds: 0,
      );
      expect(multiSession.requiresReleaseBeforeOpen, isFalse);
    });
  });

  group('Build #28 — a refused panel is not re-probed on every resume', () {
    test('a recent 403 in the refusal log skips the probe: zero panel calls', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      final log = _log();
      await log.record(_refusal());
      client.testRefusalLog = log;
      final status = await client.checkHealth();
      expect(panel.totalRequests, 0, reason: 'the probe must not fire while the panel has refused us recently');
      expect(status, HealthStatus.online, reason: 'last known verdict, unchanged — the backoff only skips the call');
    });

    test('after the backoff window the probe runs again', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      IptvClient.refusalProbeBackoff = const Duration(milliseconds: 200);
      final log = _log();
      await log.record(_refusal(timestamp: DateTime.now().subtract(const Duration(seconds: 1))));
      client.testRefusalLog = log;
      final status = await client.checkHealth();
      expect(panel.userInfoRequests, 1, reason: 'the refusal is older than the window, so the probe may run');
      expect(status, HealthStatus.online);
    });

    test('with no refusal recorded the probe runs', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      final status = await client.checkHealth();
      expect(panel.userInfoRequests, 1);
      expect(status, HealthStatus.online);
    });

    test('a 429 in the log does not back off the probe', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      final log = _log();
      await log.record(_refusal(statusCode: 429));
      client.testRefusalLog = log;
      final status = await client.checkHealth();
      expect(panel.userInfoRequests, 1, reason: 'only a 403 (access denied) backs off the probe; a 429 is rate-limiting, not a refusal');
      expect(status, HealthStatus.online);
    });
  });

  group('Build #28 — background work waits while a stream is playing', () {
    test('the weekly sync makes no panel calls while playing, then syncs when playback stops', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      IptvPlaybackActivity.instance.markPlaying();
      final sync = client.syncSearchIndex();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(panel.totalRequests, 0, reason: 'the sync must not fetch while a stream is playing');
      IptvPlaybackActivity.instance.markIdle();
      final result = await sync;
      // 3 category lists + 3 unfiltered catalogs.
      expect(panel.totalRequests, 6);
      expect(result.totalRows, greaterThan(0));
    });

    test('a forced (manual) refresh is not gated by playback', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      IptvPlaybackActivity.instance.markPlaying();
      final result = await client.syncSearchIndex(force: true);
      expect(panel.totalRequests, 6, reason: 'an explicit manual refresh is the user asking — it is not gated');
      expect(result.totalRows, greaterThan(0));
      IptvPlaybackActivity.instance.markIdle();
    });

    test('a stale-disk browse does not re-download while playing, then fetches when idle', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      final cache = IptvCatalogDiskCache();
      await cache.write('conn-xt-1', IptvCatalogDiskCache.liveDataset, jsonEncode(_liveRows().map((r) => r.toJson()).toList()));
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.liveCategoriesDataset,
        jsonEncode(_liveCategories().map((c) => c.toJson()).toList()),
      );
      // Any disk entry is stale with a zero TTL.
      IptvCatalogDiskCache.catalogCacheTtl = Duration.zero;
      IptvPlaybackActivity.instance.markPlaying();
      final channels = await client.iptvChannels();
      expect(channels, hasLength(2), reason: 'the stale disk rows are still served while the refresh waits');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(panel.liveRequests, 0, reason: 'the stale-disk refresh must not fetch while a stream is playing');
      IptvPlaybackActivity.instance.markIdle();
      await _waitFor(() => panel.liveRequests > 0);
      expect(panel.liveRequests, 1);
    });

    test('cancelBackgroundWork aborts an in-flight sync', () async {
      final panel = _CountingPanel()..categoryLatency = const Duration(seconds: 2);
      final client = _clientWith(panel);
      final sync = client.syncSearchIndex();
      await _waitFor(() => panel.totalRequests > 0);
      final requestsAtCancel = panel.totalRequests;
      client.cancelBackgroundWork();
      try {
        await sync;
      } on Object {
        // The aborted sync stops with an error; the stopping is the
        // point, not how it reports it.
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(panel.totalRequests, requestsAtCancel, reason: 'no further panel calls after the background cancel');
    });
  });
}
