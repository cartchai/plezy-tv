// R4 — periodic background sync (v1.0.13-2.25.0+185), NEW-API tests.
//
// These tests reference the R4 API (`IptvBackgroundSync`,
// `syncSearchIndexForBackground`, `MultiServerManager.
// ensureIptvSearchIndexesSynced`, the playback mirror, the running
// stamp), so this file FAILS TO LOAD on base bc6b9d3af — that is the
// failing-first evidence for the new behaviour; the pre-fix-API
// failing-first tests live in iptv_build_r4_background_sync_test.dart.
//
// No live panel: fakes only (plus one local HTTP server for the UA
// provider override, which the lazy client can only prove on the wire).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/iptv/iptv_background_sync.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/iptv_refusal_log.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:workmanager_platform_interface/workmanager_platform_interface.dart';

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

List<XtreamLiveStream> _liveRows() => const [
      XtreamLiveStream(streamId: 1, name: 'Channel 0', categoryId: '1', epgChannelId: 'ch1'),
      XtreamLiveStream(streamId: 2, name: 'Channel 1', categoryId: '2', epgChannelId: 'ch2'),
    ];

List<XtreamVodStream> _vodRows() => const [
      XtreamVodStream(streamId: 1, name: 'Movie 0', categoryId: '10'),
      XtreamVodStream(streamId: 2, name: 'Movie 1', categoryId: '11'),
    ];

List<XtreamSeries> _seriesRows() => const [
      XtreamSeries(seriesId: 219, name: 'EN - Game Of Thrones (2011)', categoryId: '1219'),
      XtreamSeries(seriesId: 2, name: 'Series 0', categoryId: '1'),
    ];

/// Restores the real HttpClient in the test isolate — the flutter_test
/// binding stubs every HttpClient request with a 400. Same pattern as
/// iptv_build17_guide_category_test.dart.
class _RealHttpOverrides extends HttpOverrides {}

enum _PanelMode { normal, refuse403, transport }

/// A fake panel that counts every request, honours AbortableRequest, and
/// answers each Xtream endpoint from the fixture rows — or refuses (403)
/// or drops the connection (transport failure) on every catalog call.
class _CountingPanel extends http.BaseClient {
  _PanelMode mode = _PanelMode.normal;

  /// Simulated per-category latency: lets an abort land mid-request.
  Duration categoryLatency = Duration.zero;

  int totalRequests = 0;
  String? lastUserAgent;

  void reset() {
    totalRequests = 0;
    lastUserAgent = null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    lastUserAgent = request.headers['user-agent'];
    final uri = request.url;
    final action = uri.queryParameters['action'];
    if (mode == _PanelMode.transport && action != null) {
      throw http.ClientException('Connection closed');
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
    final status = mode == _PanelMode.refuse403 && action != null ? 403 : 200;
    return http.StreamedResponse(
      Stream.value(utf8.encode(_bodyFor(action))),
      status,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }

  String _bodyFor(String? action) {
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
        return jsonEncode(_liveRows().map((r) => r.toJson()).toList());
      case 'get_vod_streams':
        return jsonEncode(_vodRows().map((r) => r.toJson()).toList());
      case 'get_series':
        return jsonEncode(_seriesRows().map((r) => r.toJson()).toList());
      default:
        return '[]';
    }
  }
}

XtreamConnection _xtreamConnection() => XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      createdAt: DateTime.utc(2026, 11, 5),
    );

IptvClient _clientWith(_CountingPanel panel) {
  final client = IptvClient.forConnection(_xtreamConnection());
  client.testXtreamApi = XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    httpClient: panel,
    onRefusal: (entry) => IptvRefusalLog.instance.record(entry),
  );
  addTearDown(client.close);
  return client;
}

/// Fake WorkManager platform: records every registration/cancel so the
/// module's scheduling decisions are observable without a device.
class _FakeWorkmanagerPlatform extends WorkmanagerPlatform with MockPlatformInterfaceMixin {
  int initializeCalls = 0;
  Function? dispatcher;
  final List<({
    String uniqueName,
    String taskName,
    Duration? frequency,
    Duration? flexInterval,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
  })> registerCalls = [];
  int cancelCalls = 0;
  String? cancelledName;

  @override
  Future<void> initialize(
    Function callbackDispatcher, {
    // ignore: deprecated_member_use
    bool isInDebugMode = false,
  }) async {
    initializeCalls++;
    dispatcher = callbackDispatcher;
  }

  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    ForegroundServiceConfig? foregroundServiceConfig,
  }) async {
    registerCalls.add((
      uniqueName: uniqueName,
      taskName: taskName,
      frequency: frequency,
      flexInterval: flexInterval,
      constraints: constraints,
      existingWorkPolicy: existingWorkPolicy,
      backoffPolicy: backoffPolicy,
      backoffPolicyDelay: backoffPolicyDelay,
    ));
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    cancelCalls++;
    cancelledName = uniqueName;
  }
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build_r4_new_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
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

  late _FakeWorkmanagerPlatform fakeWm;
  late WorkmanagerPlatform previousWm;
  setUp(() {
    // Force the Workmanager singleton to construct once (its constructor
    // picks a platform implementation on Linux) BEFORE installing the
    // fake, or the constructor would overwrite the fake.
    Workmanager();
    previousWm = WorkmanagerPlatform.instance;
    fakeWm = _FakeWorkmanagerPlatform();
    WorkmanagerPlatform.instance = fakeWm;
    IptvBackgroundSync.debugForceSupportedPlatform = true;
  });
  tearDown(() {
    WorkmanagerPlatform.instance = previousWm;
    IptvBackgroundSync.debugForceSupportedPlatform = false;
  });

  Future<SharedPreferencesWithCache> prefs() => BaseSharedPreferencesService.sharedCache();

  Future<void> setInterval(int hours) async {
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.iptvCatalogSyncIntervalHours, hours);
  }

  /// Deps wiring a fake panel into the callback's client factory, and
  /// capturing the User-Agent the callback resolved from prefs.
  ({IptvBackgroundSyncDeps deps, String Function() userAgent}) depsFor(_CountingPanel panel) {
    String captured = '';
    final deps = IptvBackgroundSyncDeps(
      connectionLoader: () async => [_xtreamConnection()],
      clientFactory: (connection, {required String userAgent}) {
        captured = userAgent;
        final client = IptvClient.forConnection(connection);
        client.testXtreamApi = XtreamApi(
          serverUrl: 'https://panel.example.com:8080',
          username: 'user',
          password: testPassword,
          httpClient: panel,
          onRefusal: (entry) => IptvRefusalLog.instance.record(entry),
        );
        return client;
      },
    );
    return (deps: deps, userAgent: () => captured);
  }

  /// Seed the disk catalogs for live + movie only (series has no disk
  /// file, so it stays cold), backdated 8 days so both seeded types are
  /// due under the weekly default.
  Future<void> seedLiveAndMovieStale() async {
    final cache = IptvCatalogDiskCache();
    await cache.write('conn-xt-1', IptvCatalogDiskCache.liveDataset,
        jsonEncode(_liveRows().map((r) => r.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.vodDataset,
        jsonEncode(_vodRows().map((r) => r.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.liveCategoriesDataset,
        jsonEncode(_liveCategories().map((c) => c.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.vodCategoriesDataset,
        jsonEncode(_vodCategories().map((c) => c.toJson()).toList()));
    final old = DateTime.now().subtract(const Duration(days: 8));
    await for (final entity in tempDir.list(recursive: true)) {
      if (entity is File) await entity.setLastModified(old);
    }
  }

  Future<bool> waitForSeed(IptvClient client, {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final counts = client.searchIndexState.rowCounts;
      if ((counts[IptvSearchIndex.typeLive] ?? 0) > 0 &&
          (counts[IptvSearchIndex.typeMovie] ?? 0) > 0) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  }

  Future<bool> waitForSeedAll(IptvClient client, {Duration timeout = const Duration(seconds: 10)}) async {
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

  /// Seed all three disk catalogs stale (8 days) and warm the search
  /// index from them, so the background entry point sees warm (due)
  /// types instead of cold ones — the job skips cold types by design
  /// (D8), so a test that expects fetches must warm them first.
  Future<void> warmAllStale() async {
    final cache = IptvCatalogDiskCache();
    await cache.write('conn-xt-1', IptvCatalogDiskCache.liveDataset,
        jsonEncode(_liveRows().map((r) => r.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.vodDataset,
        jsonEncode(_vodRows().map((r) => r.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.seriesDataset,
        jsonEncode(_seriesRows().map((r) => r.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.liveCategoriesDataset,
        jsonEncode(_liveCategories().map((c) => c.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.vodCategoriesDataset,
        jsonEncode(_vodCategories().map((c) => c.toJson()).toList()));
    await cache.write('conn-xt-1', IptvCatalogDiskCache.seriesCategoriesDataset,
        jsonEncode(_seriesCategories().map((c) => c.toJson()).toList()));
    final old = DateTime.now().subtract(const Duration(days: 8));
    await for (final entity in tempDir.list(recursive: true)) {
      if (entity is File) await entity.setLastModified(old);
    }
    final warmer = _clientWith(_CountingPanel());
    warmer.warmUpSeriesCatalog();
    warmer.warmUpVodCatalog();
    warmer.warmUpLiveCatalog();
    expect(await waitForSeedAll(warmer), isTrue);
  }

  Map<String, String> outcomesOf(Map<String, Object?>? record) {
    final connections = record!['connections'] as Map<String, dynamic>;
    final conn = connections['conn-xt-1'] as Map<String, dynamic>;
    return conn.map((k, v) => MapEntry(k, v as String));
  }

  group('R4.1 — registration', () {
    test('registers the periodic task at the weekly default, connected-only', () async {
      await IptvBackgroundSync.ensureRegistered();
      expect(fakeWm.registerCalls, hasLength(1));
      final call = fakeWm.registerCalls.single;
      expect(call.uniqueName, IptvBackgroundSync.uniqueName);
      expect(call.taskName, IptvBackgroundSync.taskName);
      expect(call.frequency, const Duration(hours: 168));
      expect(call.flexInterval, const Duration(hours: 1),
          reason: 'flex puts the run at the END of the interval');
      expect(call.constraints?.networkType, NetworkType.connected,
          reason: 'connected-only, never Wi-Fi-only: the working Trex path is mobile data');
      expect(call.existingWorkPolicy, ExistingPeriodicWorkPolicy.keep);
      expect(call.backoffPolicy, BackoffPolicy.exponential);
      expect(call.backoffPolicyDelay, const Duration(minutes: 15));
      final stored = await prefs();
      expect(stored.getInt(IptvBackgroundSync.registeredHoursPrefsKey), 168);
    });

    test('the flex interval scales with the setting', () {
      expect(IptvBackgroundSync.flexForInterval(6), const Duration(minutes: 15));
      expect(IptvBackgroundSync.flexForInterval(12), const Duration(minutes: 15));
      expect(IptvBackgroundSync.flexForInterval(24), const Duration(hours: 1));
      expect(IptvBackgroundSync.flexForInterval(168), const Duration(hours: 1));
    });

    test('manual-only cancels the task instead of registering it', () async {
      await setInterval(0);
      await IptvBackgroundSync.ensureRegistered();
      expect(fakeWm.registerCalls, isEmpty);
      expect(fakeWm.cancelCalls, 1);
      expect(fakeWm.cancelledName, IptvBackgroundSync.uniqueName);
      final stored = await prefs();
      expect(stored.getInt(IptvBackgroundSync.registeredHoursPrefsKey), 0);
    });

    test('an interval change re-registers with update, not keep', () async {
      await IptvBackgroundSync.ensureRegistered();
      expect(fakeWm.registerCalls.single.existingWorkPolicy, ExistingPeriodicWorkPolicy.keep);
      await IptvBackgroundSync.applyInterval(24);
      expect(fakeWm.registerCalls, hasLength(2));
      final second = fakeWm.registerCalls[1];
      expect(second.frequency, const Duration(hours: 24));
      expect(second.flexInterval, const Duration(hours: 1));
      expect(second.existingWorkPolicy, ExistingPeriodicWorkPolicy.update,
          reason: 'keep would preserve the old weekly spec');
      final stored = await prefs();
      expect(stored.getInt(IptvBackgroundSync.registeredHoursPrefsKey), 24);
    });

    test('initialize passes the callback dispatcher to the platform', () async {
      await IptvBackgroundSync.initialize();
      expect(fakeWm.initializeCalls, 1);
      expect(fakeWm.dispatcher, iptvSyncCallbackDispatcher);
    });

    test('unsupported platforms are a no-op', () async {
      IptvBackgroundSync.debugForceSupportedPlatform = false;
      await IptvBackgroundSync.ensureRegistered();
      expect(fakeWm.registerCalls, isEmpty);
      expect(fakeWm.cancelCalls, 0);
    });
  });

  group('R4.1 — the callback', () {
    test('a transport failure returns retry and records the failure', () async {
      await warmAllStale();
      final panel = _CountingPanel()..mode = _PanelMode.transport;
      final d = depsFor(panel);
      final ok = await IptvBackgroundSync.runOnce(deps: d.deps);
      expect(ok, isFalse, reason: 'transport failure is retryable');
      expect(panel.totalRequests, 3, reason: 'one category call per type, then the failure');
      expect(d.userAgent(), XtreamUserAgent.vlc, reason: 'no UA setting: the VLC default');
      final record = await IptvBackgroundSync.readLastRun();
      expect(record, isNotNull);
      expect(record!['retry'], isTrue);
      expect(record['requests'], 3);
      expect(outcomesOf(record), {
        'live': 'failed',
        'movie': 'failed',
        'series': 'failed',
      });
    });

    test('a 403 returns success, never retries the refusal, and records it', () async {
      await warmAllStale();
      final panel = _CountingPanel()..mode = _PanelMode.refuse403;
      final d = depsFor(panel);
      final ok = await IptvBackgroundSync.runOnce(deps: d.deps);
      expect(ok, isTrue, reason: 'a refusal must never be retried');
      expect(panel.totalRequests, 3);
      final record = await IptvBackgroundSync.readLastRun();
      expect(record!['retry'], isFalse);
      expect(outcomesOf(record), {
        'live': 'failed',
        'movie': 'failed',
        'series': 'failed',
      });
      final log = IptvRefusalLog(
        prefsProvider: BaseSharedPreferencesService.sharedCache,
        networkTypeProvider: () async => 'wifi',
      );
      final entries = await log.loadEntries();
      expect(entries.where((e) => e.statusCode == 403).length, greaterThanOrEqualTo(3));
    });

    test('the callback resolves the UA from prefs, not the default', () async {
      await warmAllStale();
      final p = await prefs();
      await p.setString('iptv_xtream_user_agent', XtreamUserAgent.choiceSmarters);
      final panel = _CountingPanel();
      final d = depsFor(panel);
      final ok = await IptvBackgroundSync.runOnce(deps: d.deps);
      expect(ok, isTrue);
      expect(panel.totalRequests, 6);
      expect(d.userAgent(), XtreamUserAgent.smarters);
      final record = await IptvBackgroundSync.readLastRun();
      expect(record!['requests'], 6);
      expect(outcomesOf(record), {
        'live': 'synced',
        'movie': 'synced',
        'series': 'synced',
      });
    });

    test('a cold type is skipped, not fetched', () async {
      // Warm live + movie from a stale disk (manual-only in the UI
      // isolate, so the warm-up does not sync them itself), then let
      // the callback run at the weekly interval: series has no disk
      // file and no index rows, so it is cold and must be skipped.
      await setInterval(0);
      await seedLiveAndMovieStale();
      final warmer = _clientWith(_CountingPanel());
      warmer.warmUpVodCatalog();
      warmer.warmUpLiveCatalog();
      expect(await waitForSeed(warmer), isTrue);
      await setInterval(168);
      final panel = _CountingPanel();
      final d = depsFor(panel);
      final ok = await IptvBackgroundSync.runOnce(deps: d.deps);
      expect(ok, isTrue);
      expect(panel.totalRequests, 4, reason: 'live + movie only; series is cold');
      final record = await IptvBackgroundSync.readLastRun();
      expect(outcomesOf(record), {
        'live': 'synced',
        'movie': 'synced',
        'series': 'cold',
      });
    });

    test('playing returns retry without fetching', () async {
      await warmAllStale();
      final panel = _CountingPanel();
      final d = depsFor(panel);
      final p = await prefs();
      await p.setBool(IptvBackgroundSync.playbackMirrorPrefsKey, true);
      final ok = await IptvBackgroundSync.runOnce(deps: d.deps);
      expect(ok, isFalse, reason: 'the job must not fetch on top of a live stream');
      expect(panel.totalRequests, 0);
      final record = await IptvBackgroundSync.readLastRun();
      expect(record!['skipped'], 'playing');
      await p.setBool(IptvBackgroundSync.playbackMirrorPrefsKey, false);
      final ok2 = await IptvBackgroundSync.runOnce(deps: d.deps);
      expect(ok2, isTrue);
      expect(panel.totalRequests, 6);
    });

    test('a fresh running stamp skips the run; a stale one does not', () async {
      await warmAllStale();
      final panel = _CountingPanel();
      final d = depsFor(panel);
      final p = await prefs();
      await p.setInt(
        IptvBackgroundSync.runningStampPrefsKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      final skipped = await IptvBackgroundSync.runOnce(deps: d.deps);
      expect(skipped, isTrue, reason: 'the UI isolate is already syncing; the job yields');
      expect(panel.totalRequests, 0);
      final record = await IptvBackgroundSync.readLastRun();
      expect(record!['skipped'], 'already-running');
      await p.setInt(
        IptvBackgroundSync.runningStampPrefsKey,
        DateTime.now().subtract(const Duration(minutes: 31)).millisecondsSinceEpoch,
      );
      final ran = await IptvBackgroundSync.runOnce(deps: d.deps);
      expect(ran, isTrue);
      expect(panel.totalRequests, 6, reason: 'a stamp older than 30 minutes is dead');
    });

    test('no connections is a success with an empty record', () async {
      final deps = IptvBackgroundSyncDeps(
        connectionLoader: () async => <XtreamConnection>[],
      );
      final ok = await IptvBackgroundSync.runOnce(deps: deps);
      expect(ok, isTrue);
      final record = await IptvBackgroundSync.readLastRun();
      expect(record!['connections'], isEmpty);
      expect(record['requests'], 0);
    });

    test('an aborted run returns retry', () async {
      await warmAllStale();
      final panel = _CountingPanel()..categoryLatency = const Duration(seconds: 2);
      final d = depsFor(panel);
      final abort = AbortController();
      final run = IptvBackgroundSync.runOnce(deps: d.deps, abort: abort);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      abort.abort();
      expect(await run, isFalse);
    });
  });

  group('R4.1 — the background entry point', () {
    test('syncSearchIndexForBackground skips cold types', () async {
      await setInterval(0);
      await seedLiveAndMovieStale();
      final warmer = _clientWith(_CountingPanel());
      warmer.warmUpVodCatalog();
      warmer.warmUpLiveCatalog();
      expect(await waitForSeed(warmer), isTrue);
      await setInterval(168);
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      final result = await client.syncSearchIndexForBackground();
      expect(panel.totalRequests, 4, reason: 'live + movie only; series is cold');
      expect(result.rows.keys, containsAll(['live', 'movie']));
      expect(result.skipped['series'], 'cold');
      expect(result.transportFailedTypes, isEmpty);
    });

    test('a transport failure is reported per type', () async {
      await warmAllStale();
      final panel = _CountingPanel()..mode = _PanelMode.transport;
      final client = _clientWith(panel);
      final result = await client.syncSearchIndexForBackground();
      expect(result.skipped, {
        'live': 'failed',
        'movie': 'failed',
        'series': 'failed',
      });
      expect(result.transportFailedTypes, {'live', 'movie', 'series'});
    });

    test('the UA provider override reaches the wire', () async {
      // The lazy client builds its XtreamApi from the override, so the
      // only faithful wire proof is a real local server — the test
      // binding stubs HttpClient, so restore the real one for this test
      // (the iptv_build17 pattern). The types must be warm first or the
      // background entry point skips them cold and sends nothing.
      await warmAllStale();
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      addTearDown(() => HttpOverrides.global = previousOverrides);
      String? seenUa;
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((HttpRequest req) async {
        seenUa ??= req.headers.value('user-agent');
        final action = req.uri.queryParameters['action'];
        String body;
        switch (action) {
          case null:
            body = jsonEncode({'user_info': {'status': 'Active', 'exp_date': '1790000000'}});
          case 'get_live_categories':
            body = jsonEncode(_liveCategories().map((c) => c.toJson()).toList());
          case 'get_vod_categories':
            body = jsonEncode(_vodCategories().map((c) => c.toJson()).toList());
          case 'get_series_categories':
            body = jsonEncode(_seriesCategories().map((c) => c.toJson()).toList());
          case 'get_live_streams':
            body = jsonEncode(_liveRows().map((r) => r.toJson()).toList());
          case 'get_vod_streams':
            body = jsonEncode(_vodRows().map((r) => r.toJson()).toList());
          case 'get_series':
            body = jsonEncode(_seriesRows().map((r) => r.toJson()).toList());
          default:
            body = '[]';
        }
        req.response.headers.contentType = ContentType.json;
        req.response.write(body);
        await req.response.close();
      });
      addTearDown(() => server.close(force: true));
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'http://127.0.0.1:${server.port}',
        username: 'user',
        password: testPassword,
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      addTearDown(client.close);
      client.userAgentProvider = () => 'MarkerUA/1.0';
      final result = await client.syncSearchIndexForBackground();
      // A fetched type lands in `rows`, not `skipped` — `skipped` only
      // records types that were not fetched (cold / up-to-date / failed).
      expect(result.rows.keys, containsAll(['live', 'movie', 'series']));
      expect(result.skipped, isEmpty);
      expect(result.transportFailedTypes, isEmpty);
      expect(seenUa, 'MarkerUA/1.0',
          reason: 'the background isolate sets the UA before the first request');
    });
  });

  group('R4.2 — resume-time due-check', () {
    test('the manager syncs once through the coalesced path, then skips when warm', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      final manager = MultiServerManager();
      addTearDown(manager.dispose);
      manager.debugRegisterIptvClientForTesting(client);
      await Future.wait([
        manager.ensureIptvSearchIndexesSynced(),
        manager.ensureIptvSearchIndexesSynced(),
      ]);
      expect(panel.totalRequests, 6, reason: 'two concurrent calls share one sync');
      panel.reset();
      await manager.ensureIptvSearchIndexesSynced();
      expect(panel.totalRequests, 0, reason: 'the index is fresh now');
    });

    test('a fresh running stamp makes the UI-side sync yield', () async {
      final panel = _CountingPanel();
      final client = _clientWith(panel);
      final p = await prefs();
      await p.setInt(
        IptvBackgroundSync.runningStampPrefsKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      await client.ensureSearchIndexSynced();
      expect(panel.totalRequests, 0, reason: 'the background job is already syncing');
      await p.remove(IptvBackgroundSync.runningStampPrefsKey);
      await client.ensureSearchIndexSynced();
      expect(panel.totalRequests, 6);
    });
  });

  group('R4 — the playback mirror', () {
    test('markPlaying mirrors into prefs; markIdle clears it', () async {
      final activity = IptvPlaybackActivity.instance;
      activity.markPlaying();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!await IptvBackgroundSync.isPlaybackActive()) {
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await IptvBackgroundSync.isPlaybackActive(), isTrue);
      activity.markIdle();
      final deadline2 = DateTime.now().add(const Duration(seconds: 5));
      while (await IptvBackgroundSync.isPlaybackActive()) {
        if (DateTime.now().isAfter(deadline2)) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(await IptvBackgroundSync.isPlaybackActive(), isFalse);
    });
  });
}
