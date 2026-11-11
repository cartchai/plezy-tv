// BUILD #21 — searching puts the app into OFFLINE mode and disconnects Trex.
//
// THE PHONE FAILURE (v1.0.3-2.25.0, 2026-11-09 ~23:12 EST):
//   * Searching puts the app into OFFLINE mode and disconnects Trex.
//   * Searching also takes forever: a cold/stale search heals mid-search,
//     sweeping all 237 series categories.
//
// WHAT THE RESEARCH PROVED (RESEARCH_SEARCH_OFFLINE.md — code, not guesses):
//   * The search itself never touches health state. The disconnect comes
//     from `IptvClient.checkHealth`, which maps EVERY failure except
//     401/403 to `HealthStatus.offline` — timeout, 429, 500, socket error,
//     DNS — catch-all, no retry, no transient/dead distinction.
//   * The search's heal burst (32 concurrent category calls per section,
//     3 sections concurrently = ~96 in flight against a max_connections=1
//     panel, orphaned requests outliving the 50s section budget) makes
//     the probe fail. On 1.0.2 the burst is all-403; on 1.0.3 it can still
//     429/timeout — and one such failure flips the server offline.
//   * Aggravators: the offline verdict is composite (Trex-refused +
//     Plex-offline on mobile data = whole app enters the offline shell),
//     and `reconnectOfflineServers` has NO IPTV branch, so a flipped Trex
//     stays offline until a manual reconnect.
//   * Matt (2026-11-09 ~23:25 EST): "Do as few requests as you can, make
//     it comparable to other apps. I think that's why Trex blocks me from
//     time to time, they're seeing all those requests." The burst cap is
//     therefore 8 (the top of Matt's low-end range, 4-8), orphans are
//     hard-cancelled, and no health probe fires while a search is in
//     flight. Cap 4 was tried first and REJECTED: the build #19 P4-fast
//     probe (1s per call, 232 categories to sweep) needs 58s at cap 4 —
//     past the 49s sweep deadline — so the heal misses Game of Thrones
//     on a slow panel. Cap 8 passes it in 29s. See the cap comment in
//     iptv_client.dart for the full justification.
//
// THE FIX (build #21, v1.0.4-2.25.0+176):
//   1. Split health verdict: timeouts / 429s / 5xx / socket errors are
//      transient — keep last-known-online until 3 consecutive failures,
//      then publish offline. 401 stays authError, 403 stays accessDenied.
//   2. Bound the burst: one semaphore of 8 shared by the three sections
//      AND by concurrent searches on the client; orphaned requests are
//      hard-cancelled (AbortableRequest) when a section's budget expires
//      or a new keystroke cancels the search. Cap 8 is written as the
//      literal `8` in the assertions below (not
//      `IptvClient.searchBurstCap`, which is new in the fix) so this
//      file compiles on base for the failing-first run. The reach test
//      (R1) proves 8 still reaches the last category.
//   3. IPTV branch in `reconnectOfflineServers` so a flipped Trex
//      recovers on its own.
//   4. Composite verdict: "no server online AND at least one refused"
//      shows the refusal banner, not the offline shell.
//   5. A health probe during a search is deferred (coalesced to one
//      probe after the search) instead of adding a concurrent request.
//
// These tests FAIL on 652db5f90 and PASS on the fix. They use only the
// pre-fix public API, so they can run failing-first on base. The new-API
// test (the deferred-probe callback firing) lives in
// iptv_build21_deferred_probe_test.dart and only compiles after the fix.
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
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';

/// The Trex — Series scope: exclude the Movies library (live is excluded
/// whenever the set is non-empty), so only the series section runs and the
/// request counts are the series leg's alone.
const _seriesOnlyScope = {'iptv:conn-xt-1:movies'};

enum _UserInfoMode { ok, timeout, socket, tooManyRequests, forbidden, unauthorized }

/// A fake panel (http.Client) that counts every request, tracks peak
/// concurrency, honours AbortableRequest.abortTrigger, and answers each
/// Xtream endpoint with a minimal valid payload.
///
/// Counts are split so the burst cap can be asserted exactly: the cap
/// governs the per-category sweep calls (the burst); the category list
/// and the unfiltered load are single, memoized, cache-warming requests
/// outside it.
class _CountingPanel extends http.BaseClient {
  _CountingPanel({
    required this.categories,
    this.categoryLatency = const Duration(milliseconds: 100),
    this.unfilteredSeriesRows = const [],
    this.unfilteredSeriesLatency = Duration.zero,
    this.userInfoMode = _UserInfoMode.ok,
    this.seriesRowForCategory,
  });

  final List<XtreamCategory> categories;
  final Duration categoryLatency;
  final List<XtreamSeries> unfilteredSeriesRows;
  final Duration unfilteredSeriesLatency;
  _UserInfoMode userInfoMode;
  final List<XtreamSeries> Function(String categoryId)? seriesRowForCategory;

  int totalRequests = 0;
  int categoryRequests = 0;
  int userInfoRequests = 0;
  int maxConcurrentCategory = 0;
  int maxConcurrentOverall = 0;
  int abortedRequests = 0;
  final List<String> abortedCategoryIds = [];
  int _inFlightCategory = 0;
  int _inFlightOverall = 0;

  int _requestsAtMark = 0;
  void mark() => _requestsAtMark = totalRequests;
  int get requestsAfterMark => totalRequests - _requestsAtMark;

  /// Zero the counters (after the warm-up) so the asserted search is
  /// measured alone.
  void reset() {
    totalRequests = 0;
    categoryRequests = 0;
    userInfoRequests = 0;
    maxConcurrentCategory = 0;
    maxConcurrentOverall = 0;
    abortedRequests = 0;
    abortedCategoryIds.clear();
    _inFlightCategory = 0;
    _inFlightOverall = 0;
    _requestsAtMark = 0;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final uri = request.url;
    final action = uri.queryParameters['action'];
    final categoryId = uri.queryParameters['category_id'];
    final isCategory = categoryId != null;
    if (isCategory) categoryRequests++;
    if (action == null) userInfoRequests++;
    _inFlightOverall++;
    if (_inFlightOverall > maxConcurrentOverall) maxConcurrentOverall = _inFlightOverall;
    if (isCategory) {
      _inFlightCategory++;
      if (_inFlightCategory > maxConcurrentCategory) maxConcurrentCategory = _inFlightCategory;
    }
    try {
      // The health probe's failure modes (no latency — the probe is one
      // fast round trip; the failure is the point, not the wait).
      if (action == null) {
        switch (userInfoMode) {
          case _UserInfoMode.timeout:
            throw TimeoutException('panel timed out');
          case _UserInfoMode.socket:
            throw const SocketException('panel unreachable');
          case _UserInfoMode.ok:
          case _UserInfoMode.tooManyRequests:
          case _UserInfoMode.forbidden:
          case _UserInfoMode.unauthorized:
            break;
        }
      }
      final latency = isCategory
          ? categoryLatency
          : (action == 'get_series' ? unfilteredSeriesLatency : Duration.zero);
      final abortTrigger = request is http.AbortableRequest ? request.abortTrigger : null;
      if (abortTrigger != null && latency > Duration.zero) {
        // Race the response delay against the abort: a section whose
        // budget expired (or a cancelled search) must stop the socket,
        // not just abandon the future.
        final outcome = await Future.any([
          Future<void>.delayed(latency).then((_) => 'done'),
          abortTrigger.then((_) => 'aborted'),
        ]);
        if (outcome == 'aborted') {
          abortedRequests++;
          if (categoryId != null) abortedCategoryIds.add(categoryId);
          throw http.RequestAbortedException(uri);
        }
      } else if (latency > Duration.zero) {
        await Future<void>.delayed(latency);
      }
      final body = _bodyFor(action, categoryId);
      final status = _statusFor(action);
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        status,
        request: request,
        headers: {'content-type': 'application/json'},
      );
    } finally {
      _inFlightOverall--;
      if (isCategory) _inFlightCategory--;
    }
  }

  String _bodyFor(String? action, String? categoryId) {
    switch (action) {
      case null:
        return jsonEncode({
          'user_info': {'status': 'Active', 'exp_date': '1790000000'},
        });
      case 'get_live_categories':
      case 'get_vod_categories':
      case 'get_series_categories':
        return jsonEncode(
          categories.map((c) => {'category_id': c.id, 'category_name': c.name}).toList(),
        );
      case 'get_series':
        if (categoryId != null) {
          final rows = seriesRowForCategory?.call(categoryId) ??
              [XtreamSeries(seriesId: 90000 + int.parse(categoryId), name: 'Swept Filler $categoryId', categoryId: categoryId)];
          return jsonEncode(rows.map((r) => r.toJson()).toList());
        }
        return jsonEncode(unfilteredSeriesRows.map((r) => r.toJson()).toList());
      case 'get_live_streams':
      case 'get_vod_streams':
        return '[]';
      case 'get_series_info':
        return jsonEncode({
          'info': {'name': 'Show'},
          'episodes': <String, dynamic>{},
        });
      default:
        return '[]';
    }
  }

  int _statusFor(String? action) {
    if (action == null) {
      return switch (userInfoMode) {
        _UserInfoMode.tooManyRequests => 429,
        _UserInfoMode.forbidden => 403,
        _UserInfoMode.unauthorized => 401,
        _ => 200,
      };
    }
    return 200;
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

/// Seed the series disk file with rows in categories 1-5 only (plus the
/// warm-up match), so a no-match search heals the missing categories.
Future<void> _seedSeriesDisk() async {
  final cache = IptvCatalogDiskCache();
  final rows = [
    for (var i = 0; i < 5; i++)
      XtreamSeries(seriesId: 1000 + i, name: 'Filler Series $i', categoryId: '${i + 1}'),
  ];
  await cache.write(
    'conn-xt-1',
    IptvCatalogDiskCache.seriesDataset,
    jsonEncode(rows.map((r) => r.toJson()).toList()),
  );
}

/// Warm the series catalog WITHOUT triggering the heal: the throwaway
/// query matches a seeded row, so the warm filter returns it and the
/// 0-match sweep never fires. (Build #19's warmSeriesNoHeal shape.)
Future<void> _warmSeriesNoHeal(IptvClient client) async {
  client.warmUpSeriesCatalog();
  await client.searchItems('Filler Series 0', excludedLibraryIds: _seriesOnlyScope);
}

/// Wait until the panel request count has been stable for ~300 ms (the
/// fire-and-forget submit sync has landed or will never come).
Future<void> _waitForPanelQuiescent(_CountingPanel panel) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  var last = panel.totalRequests;
  var stableSince = DateTime.now();
  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (panel.totalRequests != last) {
      last = panel.totalRequests;
      stableSince = DateTime.now();
    } else if (DateTime.now().difference(stableSince) > const Duration(milliseconds: 300)) {
      return;
    }
    if (DateTime.now().isAfter(deadline)) throw StateError('panel never went quiescent');
  }
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build21_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    IptvClient.searchSectionBudget = const Duration(seconds: 50);
    // Fire-and-forget catalog writes can still be in flight when a test
    // ends; retry the delete after a settle delay instead of failing
    // the test on teardown (build #19's fix-up pattern).
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

  group('Build #21 — search must not disconnect Trex', () {
    test('transient probe failures stay online until the 3rd in a row', () async {
      final panel = _CountingPanel(categories: const [], userInfoMode: _UserInfoMode.timeout);
      final client = _clientWith(panel);

      expect(await client.checkHealth(), HealthStatus.online, reason: '1st timeout keeps last-known-online');
      expect(await client.checkHealth(), HealthStatus.online, reason: '2nd timeout keeps last-known-online');
      expect(await client.checkHealth(), HealthStatus.offline, reason: '3rd consecutive timeout publishes offline');
      // A success resets the streak: one failure after a success is online again.
      panel.userInfoMode = _UserInfoMode.ok;
      expect(await client.checkHealth(), HealthStatus.online);
      panel.userInfoMode = _UserInfoMode.timeout;
      expect(await client.checkHealth(), HealthStatus.online, reason: 'streak reset by the success');
      expect(panel.userInfoRequests, 5, reason: 'every probe made a request — none was suppressed');
    });

    test('429 is transient like a timeout; 403 stays access denied; 401 stays auth error', () async {
      final panel = _CountingPanel(categories: const [], userInfoMode: _UserInfoMode.tooManyRequests);
      final client = _clientWith(panel);

      expect(await client.checkHealth(), HealthStatus.online, reason: '1st 429 keeps last-known-online');
      expect(await client.checkHealth(), HealthStatus.online, reason: '2nd 429 keeps last-known-online');
      expect(await client.checkHealth(), HealthStatus.offline, reason: '3rd consecutive 429 publishes offline');
      panel.userInfoMode = _UserInfoMode.forbidden;
      expect(await client.checkHealth(), HealthStatus.accessDenied, reason: '403 is definitive, not transient');
      panel.userInfoMode = _UserInfoMode.unauthorized;
      expect(await client.checkHealth(), HealthStatus.authError, reason: '401 is definitive, not transient');
    });

    test('a no-match search makes zero panel requests — no burst at all', () async {
      // R2.3: the heal sweep is gone, so the burst cap is moot — a
      // no-match search over the seeded disk serves local rows only.
      // 24 categories, rows only in 1-5: before, the heal swept 6..24
      // (19 calls); now the search makes no call at all, and the repair
      // moved to the submit's sync — one unfiltered fetch per type, never
      // a per-category call.
      final panel = _CountingPanel(
        categories: [for (var i = 1; i <= 24; i++) XtreamCategory(id: '$i', name: 'Category $i')],
        categoryLatency: const Duration(milliseconds: 100),
      );
      final client = _clientWith(panel);
      await _seedSeriesDisk();
      await _warmSeriesNoHeal(client);
      panel.reset();

      final results = await client.searchItems('zz-no-match-zz', excludedLibraryIds: _seriesOnlyScope);
      expect(results, isEmpty);
      expect(panel.totalRequests, 0, reason: 'typing search is local-only');
      expect(panel.categoryRequests, 0);
      expect(panel.maxConcurrentCategory, 0);
      // A submit repairs through the sync: 6 requests (category list +
      // unfiltered fetch per type), zero per-category calls.
      await client.searchItems('zz-no-match-zz', onlineAllowed: true, excludedLibraryIds: _seriesOnlyScope);
      await _waitForPanelQuiescent(panel);
      expect(panel.categoryRequests, 0, reason: 'the sync fetches the unfiltered list, never per-category');
      expect(panel.totalRequests, 6, reason: 'one category list + one unfiltered fetch per type');
      expect(panel.maxConcurrentCategory, 0);
      // ignore: avoid_print
      print(
        'BUILD21-B1 burst: maxConcurrentCategory=${panel.maxConcurrentCategory} '
        'categoryRequests=${panel.categoryRequests} '
        'totalRequests=${panel.totalRequests}',
      );
    });

    test('a row that lives only in a per-category call is not found by search', () async {
      // R2.3: the sweep is gone, so GoT in cat-237 (reachable only via a
      // per-category call) is not found by search — the submit's sync
      // fetches the unfiltered list (50 fillers, no GoT) once and never
      // crawls. The 20 s unfiltered latency is dropped to 2 s: the sync
      // just waits for the one call; there is no sweep race to time.
      // (The sync also refuses the 50-filler list as 'partial' — 1 of 237
      // categories covered — so the index stays cold; the boundary is the
      // same either way.)
      final categories = [
        for (var i = 1; i <= 237; i++) XtreamCategory(id: 'cat-$i', name: 'Category $i'),
      ];
      final panel = _CountingPanel(
        categories: categories,
        categoryLatency: const Duration(milliseconds: 250),
        unfilteredSeriesLatency: const Duration(seconds: 2),
        unfilteredSeriesRows: [
          for (var i = 0; i < 50; i++)
            XtreamSeries(seriesId: 50000 + i, name: 'Load Filler $i', categoryId: 'cat-1'),
        ],
        seriesRowForCategory: (id) => id == 'cat-237'
            ? [const XtreamSeries(seriesId: 219, name: 'EN - Game Of Thrones (2011)', categoryId: 'cat-237')]
            : [
                XtreamSeries(
                  seriesId: 60000 + int.parse(id.substring(4)),
                  name: 'Swept Filler $id',
                  categoryId: id,
                ),
              ],
      );
      final client = _clientWith(panel);
      final first = await client.searchItems(
        'game of thrones',
        onlineAllowed: true,
        excludedLibraryIds: _seriesOnlyScope,
      );
      expect(
        first.map((m) => m.title),
        isNot(contains('EN - Game Of Thrones (2011)')),
      );
      await _waitForPanelQuiescent(panel);
      expect(panel.categoryRequests, 0, reason: 'the sync never crawls per-category');
      expect(panel.maxConcurrentCategory, 0);
      final second = await client.searchItems(
        'game of thrones',
        excludedLibraryIds: _seriesOnlyScope,
      );
      expect(
        second.map((m) => m.title),
        isNot(contains('EN - Game Of Thrones (2011)')),
        reason: 'the unfiltered list has no GoT and nothing crawls for it',
      );
      // ignore: avoid_print
      print(
        'BUILD21-R1 reach: GoT not found (per-category-only); '
        'maxConcurrentCategory=${panel.maxConcurrentCategory} categoryRequests=${panel.categoryRequests}',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a search over a slow panel returns promptly with zero requests — nothing to cancel', () async {
      // R2.3: the search never calls the panel, so a 5 s panel latency
      // cannot stall it and there is nothing to abort — the old
      // budget/hard-cancel machinery has nothing to cancel from the
      // search path. (The sync still waits for the panel on a submit;
      // this test pins the typing path only.)
      final panel = _CountingPanel(
        categories: [for (var i = 1; i <= 24; i++) XtreamCategory(id: '$i', name: 'Category $i')],
        categoryLatency: const Duration(seconds: 5),
      );
      final client = _clientWith(panel);
      await _seedSeriesDisk();
      await _warmSeriesNoHeal(client);
      panel.reset();

      final stopwatch = Stopwatch()..start();
      final results = await client.searchItems('zz-no-match-zz', excludedLibraryIds: _seriesOnlyScope);
      final elapsed = stopwatch.elapsed;
      expect(results, isEmpty);
      // The search returned on local data, not on the 5s call latency.
      expect(elapsed, lessThan(const Duration(seconds: 5)));
      expect(panel.totalRequests, 0);
      // Nothing was started, so nothing was aborted.
      expect(panel.abortedRequests, 0, reason: 'nothing was started, nothing to abort');
      // No orphan tail: after the search returned, no new requests start.
      panel.mark();
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(panel.requestsAfterMark, 0, reason: 'a local search must stop generating panel traffic');
      // ignore: avoid_print
      print(
        'BUILD21-O1 orphan: elapsed=${elapsed.inMilliseconds}ms aborted=${panel.abortedRequests} '
        'tail=${panel.requestsAfterMark}',
      );
    });

    test('a health probe during a search makes no panel request', () async {
      // R2.3: the search makes no panel requests at all, so a probe
      // issued while one is in flight has no search traffic to collide
      // with — it makes at most its own request and returns
      // last-known-online. (Whether the #21 deferral suppresses even
      // that one request depends on microtask timing now that the search
      // is local and fast, so the bound is <= 1, not exactly 0.)
      final panel = _CountingPanel(
        categories: [for (var i = 1; i <= 24; i++) XtreamCategory(id: '$i', name: 'Category $i')],
        categoryLatency: const Duration(seconds: 2),
      );
      final client = _clientWith(panel);
      await _seedSeriesDisk();
      await _warmSeriesNoHeal(client);
      panel.reset();

      final search = client.searchItems('zz-no-match-zz', excludedLibraryIds: _seriesOnlyScope);
      final health = await client.checkHealth();
      expect(health, HealthStatus.online, reason: 'the probe returns last-known-online while searching');
      expect(
        panel.userInfoRequests,
        lessThanOrEqualTo(1),
        reason: 'a probe during a search makes at most its own request',
      );
      expect(panel.categoryRequests, 0, reason: 'the search made no panel requests');
      await search;
      // ignore: avoid_print
      print('BUILD21-P1 defer: userInfoAfter=${panel.userInfoRequests}');
    });

    test('two keystrokes make zero panel requests and leave no orphan tail', () async {
      // R2.3: searches are local — two concurrent keystrokes share
      // nothing on the panel because neither calls it. The burst cap is
      // moot and the orphan tail is gone by construction. (The abort
      // controllers are dropped: there is no burst to cancel any more.)
      final panel = _CountingPanel(
        categories: [for (var i = 1; i <= 24; i++) XtreamCategory(id: '$i', name: 'Category $i')],
        categoryLatency: const Duration(milliseconds: 300),
      );
      final client = _clientWith(panel);
      await _seedSeriesDisk();
      await _warmSeriesNoHeal(client);
      panel.reset();

      final first = client.searchItems('zz-no-match-zz', excludedLibraryIds: _seriesOnlyScope);
      final second = client.searchItems('zz-no-match-zz', excludedLibraryIds: _seriesOnlyScope);
      final results = await Future.wait([first, second]);
      expect(results[1], isEmpty);
      expect(panel.totalRequests, 0, reason: 'typing searches are local-only');
      expect(panel.maxConcurrentCategory, 0);
      // No orphan tail after both searches settle.
      panel.mark();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(panel.requestsAfterMark, 0);
      // ignore: avoid_print
      print(
        'BUILD21-C1 keystrokes: maxConcurrent=${panel.maxConcurrentCategory} '
        'categoryRequests=${panel.categoryRequests} '
        'total=${panel.totalRequests} aborted=${panel.abortedRequests}',
      );
    });

    test('reconnectOfflineServers re-probes a flipped Trex and brings it back', () async {
      final panel = _CountingPanel(categories: const [], userInfoMode: _UserInfoMode.ok);
      final client = _clientWith(panel);
      final manager = MultiServerManager();
      addTearDown(manager.dispose);
      manager.debugRegisterClientForTesting(client, online: false);
      expect(manager.isServerOnline(ServerId('conn-xt-1')), isFalse);

      final userInfoBefore = panel.userInfoRequests;
      await manager.reconnectOfflineServers();
      expect(
        panel.userInfoRequests,
        greaterThan(userInfoBefore),
        reason: 'the reconnect sweep must actually probe Trex (before: no IPTV branch, no probe)',
      );
      expect(manager.isServerOnline(ServerId('conn-xt-1')), isTrue);
      // ignore: avoid_print
      print(
        'BUILD21-M1 reconnect: userInfo $userInfoBefore->${panel.userInfoRequests} '
        'online=${manager.isServerOnline(ServerId('conn-xt-1'))}',
      );
    });
  });
}
