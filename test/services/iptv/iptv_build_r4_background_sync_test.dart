// R4 — periodic background sync (v1.0.13-2.25.0+185).
//
// FAILING-FIRST on base bc6b9d3af. These tests use ONLY the pre-fix
// public API, so they compile and run on base:
//
// - "a warm UI client sees rows a headless sync wrote" FAILS on base
//   for the right product reason: the UI client's memoized browse
//   catalog predates the background run and is served until restart.
//   The fix invalidates the memo when the index's lastSync stamp
//   advanced past the stamp recorded when the memo was populated.
// - "catalog sync runs in a raw background isolate" is the research
//   probe ported as a feasibility pin: it PASSES on base (the engine
//   already runs headless) and pins the request contract — 6 requests
//   cold, 0 warm.
//
// No live panel: the panel is a real local HTTP server on 127.0.0.1
// (a fake http client cannot cross isolates as an object, so the
// headless run talks HTTP exactly as the real panel would be reached).
// The new-API tests (registration, callback semantics, cold-type skip,
// playback mirror, resume due-check, interval change, Settings tile)
// live in iptv_build_r4_background_sync_new_api_test.dart and only
// compile after the fix.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';

List<XtreamCategory> _liveCategories() => const [
      XtreamCategory(id: '1', name: '|EN| Live 1'),
      XtreamCategory(id: '2', name: '|FR| Live 2'),
    ];

List<XtreamCategory> _vodCategories() => const [
      XtreamCategory(id: '10', name: '|EN| Movies 10'),
      XtreamCategory(id: '11', name: '|FR| Movies 11'),
    ];

List<XtreamCategory> _seriesCategories() => const [
      XtreamCategory(id: '1', name: '|EN| Series 1'),
      XtreamCategory(id: '1219', name: '|EN| TOP SERIES'),
    ];

List<XtreamLiveStream> _liveRows(int version) => [
      XtreamLiveStream(streamId: 1, name: 'V$version Channel 0', categoryId: '1', epgChannelId: 'ch1'),
      XtreamLiveStream(streamId: 2, name: 'V$version Channel 1', categoryId: '2', epgChannelId: 'ch2'),
    ];

List<XtreamVodStream> _vodRows(int version) => [
      XtreamVodStream(streamId: 1, name: 'V$version Movie 0', categoryId: '10'),
      XtreamVodStream(streamId: 2, name: 'V$version Movie 1', categoryId: '11'),
    ];

List<XtreamSeries> _seriesRows(int version) => [
      XtreamSeries(seriesId: 219, name: 'V$version Series 0', categoryId: '1219'),
      XtreamSeries(seriesId: 2, name: 'V$version Series 1', categoryId: '1'),
    ];

/// The panel the local server answers from. The version is mutable in
/// the test isolate so the headless run can fetch a NEWER catalog than
/// the one the UI client warmed from — the shape of a background sync
/// landing while the app is open.
class _VersionedPanel {
  int version = 1;
  int requests = 0;

  String bodyFor(String? action) {
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
        return jsonEncode(_liveRows(version).map((r) => r.toJson()).toList());
      case 'get_vod_streams':
        return jsonEncode(_vodRows(version).map((r) => r.toJson()).toList());
      case 'get_series':
        return jsonEncode(_seriesRows(version).map((r) => r.toJson()).toList());
      default:
        return '[]';
    }
  }
}

/// Runs in a RAW isolate: no SettingsService (interval falls back to
/// the 168 h default, UA falls back to VLC), no MultiServerManager, no
/// plugin registration. The temp dir path is passed in because static
/// debug providers do not transfer across isolates. (Top-level tear-off
/// + explicit arg: a closure here would share the test function's
/// context, which holds the unsendable HttpServer.)
Future<Map<String, int>> _headlessSync(Map<String, Object> args) async {
  final tempPath = args['tempPath'] as String;
  final port = args['port'] as int;
  IptvSearchIndex.debugDirectoryProvider = () async => Directory(tempPath);
  IptvCatalogDiskCache.debugDirectoryProvider = () async => Directory(tempPath);
  final connection = XtreamConnection(
    id: 'conn-xt-1',
    name: 'Trex',
    serverUrl: 'http://127.0.0.1:$port',
    username: 'user',
    password: testPassword,
    createdAt: DateTime.utc(2026, 11, 5),
  );
  final client = IptvClient.forConnection(connection);
  try {
    await client.ensureSearchIndexSynced();
    final index = await IptvSearchIndex.open();
    try {
      final counts = index.rowCounts('conn-xt-1');
      final last = index.lastSync('conn-xt-1');
      return <String, int>{
        'live': counts[IptvSearchIndex.typeLive] ?? -1,
        'movie': counts[IptvSearchIndex.typeMovie] ?? -1,
        'series': counts[IptvSearchIndex.typeSeries] ?? -1,
        'syncedTypes': last.values.whereType<DateTime>().length,
      };
    } finally {
      index.close();
    }
  } finally {
    client.close();
  }
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build_r4_');
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

  Future<HttpServer> bindServer(_VersionedPanel panel) async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((HttpRequest req) async {
      panel.requests++;
      req.response.headers.contentType = ContentType.json;
      req.response.write(panel.bodyFor(req.uri.queryParameters['action']));
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));
    return server;
  }

  /// Seed the disk catalogs + category files with [version] rows, then
  /// backdate every file 8 days: the warm-up seed stamps the index with
  /// the disk file's real fetchedAt (M1), so the index reads STALE and
  /// a background sync is due — the shape of a phone whose catalog
  /// hasn't synced since last week.
  Future<void> seedDisk(int version) async {
    final cache = IptvCatalogDiskCache();
    await cache.write('conn-xt-1', IptvCatalogDiskCache.liveDataset,
        jsonEncode(_liveRows(version).map((r) => r.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.vodDataset,
        jsonEncode(_vodRows(version).map((r) => r.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.seriesDataset,
        jsonEncode(_seriesRows(version).map((r) => r.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.liveCategoriesDataset,
        jsonEncode(_liveCategories().map((c) => c.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.vodCategoriesDataset,
        jsonEncode(_vodCategories().map((c) => c.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.seriesCategoriesDataset,
        jsonEncode(_seriesCategories().map((c) => c.toJson()).toList()));
    final old = DateTime.now().subtract(const Duration(days: 8));
    // The files live two levels down (<dir>/iptv_catalog/<conn>/<dataset>.json).
    await for (final entity in tempDir.list(recursive: true)) {
      if (entity is File) await entity.setLastModified(old);
    }
  }

  IptvClient clientFor(int port) {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'http://127.0.0.1:$port',
      username: 'user',
      password: testPassword,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    addTearDown(client.close);
    return client;
  }

  /// Wait until the warm-up seed has landed all three types in the
  /// index (row counts > 0). Returns false on timeout.
  Future<bool> waitForSeed(IptvClient client, {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final counts = client.searchIndexState.rowCounts;
      if ((counts[IptvSearchIndex.typeLive] ?? 0) > 0 &&
          (counts[IptvSearchIndex.typeMovie] ?? 0) > 0 &&
          (counts[IptvSearchIndex.typeSeries] ?? 0) > 0) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  group('R4 — the UI isolate sees a background run\'s rows', () {
    test('a warm UI client sees rows a headless sync wrote, without a rebind', () async {
      final panel = _VersionedPanel();
      final server = await bindServer(panel);
      await seedDisk(1);
      // Manual-only in the UI isolate: the R1 due-refresh must not fire
      // while the test warms the client, or the UI isolate would sync
      // v1 itself and stamp the index fresh before the headless run.
      // (The headless isolate has no SettingsService, so it reads the
      // 168 h default and treats the stale index as due.)
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvCatalogSyncIntervalHours, 0);
      final client = clientFor(server.port);
      client.warmUpSeriesCatalog();
      client.warmUpVodCatalog();
      client.warmUpLiveCatalog();
      expect(await waitForSeed(client), isTrue, reason: 'warm-up seed lands all three types');
      final before = await client.iptvChannels();
      expect(before.map((c) => c.title), contains('V1 Channel 0'));
      expect(before.map((c) => c.title), isNot(contains('V2 Channel 0')));

      // The background run: the panel now serves v2, the stale index is
      // due, the headless sync fetches all three types.
      panel.version = 2;
      final requestsBefore = panel.requests;
      final result = await compute(
        _headlessSync,
        <String, Object>{'tempPath': tempDir.path, 'port': server.port},
      );
      expect(result['live'], 2);
      expect(result['movie'], 2);
      expect(result['series'], 2);
      expect(result['syncedTypes'], 3);
      expect(panel.requests - requestsBefore, 6,
          reason: '3 category lists + 3 catalogs in the background run');

      // Same client, no rebind: the browse must show the new rows.
      final after = await client.iptvChannels();
      // ignore: avoid_print
      print('R4-memo: before=${before.map((c) => c.title).toList()} after=${after.map((c) => c.title).toList()}');
      expect(after.map((c) => c.title), contains('V2 Channel 0'),
          reason: 'the background run wrote v2; a warm browse must not serve the stale v1 memo');
      expect(after.map((c) => c.title), isNot(contains('V1 Channel 0')));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('catalog sync runs in a raw background isolate (probe pin)', () async {
      final panel = _VersionedPanel();
      final server = await bindServer(panel);
      // 1. Cold index: the headless sync fetches all three types.
      final cold = await compute(
        _headlessSync,
        <String, Object>{'tempPath': tempDir.path, 'port': server.port},
      );
      expect(cold['live'], 2);
      expect(cold['movie'], 2);
      expect(cold['series'], 2);
      expect(cold['syncedTypes'], 3);
      expect(panel.requests, 6, reason: '3 category lists + 3 catalogs');

      // 2. Warm index, synced seconds ago: a second headless run is a no-op.
      final before = panel.requests;
      final warm = await compute(
        _headlessSync,
        <String, Object>{'tempPath': tempDir.path, 'port': server.port},
      );
      expect(warm['live'], 2);
      expect(warm['movie'], 2);
      expect(warm['series'], 2);
      expect(panel.requests, before, reason: 'due check skips every type');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
