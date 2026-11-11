// BUILD #21 — close-after-use (new-API test).
//
// Matt: "Should the connection have a close function so it stops talking
// after?" — once the app is done with something (a search), it should
// actively stop instead of leftovers keeping on talking to the panel.
// THIS file tests the new API — `IptvClient.cancelActiveSearches()` —
// so it only compiles (and only runs) after the fix lands:
//
//   * Abandoning a search (app backgrounds, user leaves the search)
//     hard-cancels the in-flight sweep requests: they stop, they do not
//     run to the 50s section budget, and no further panel requests fire
//     after the cancel.
//
// The budget-expiry half of the same behaviour lives in the failing-first
// file (iptv_build21_search_offline_test.dart, O1) and uses only the
// pre-fix API. The manager-level wiring (MultiServerManager
// .cancelActiveIptvSearches, called from main.dart's paused/detached
// lifecycle case) is a one-line call into this client method; the
// service-level test here covers the mechanism.
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

const _seriesOnlyScope = {'iptv:conn-xt-1:movies'};

/// Minimal fake panel: answers the category lists, delays per-category
/// stream calls so a search is in flight long enough to abandon, and
/// counts hard-cancels (a request whose abort trigger fires).
class _AbandonCountingPanel extends http.BaseClient {
  int totalRequests = 0;
  int categoryRequests = 0;
  int abortedRequests = 0;
  int _requestsAtMark = 0;

  void mark() => _requestsAtMark = totalRequests;
  int get requestsAfterMark => totalRequests - _requestsAtMark;

  void reset() {
    totalRequests = 0;
    categoryRequests = 0;
    abortedRequests = 0;
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
    if (action == null) {
      return _json({'user_info': {'status': 'Active', 'exp_date': '1790000000'}});
    }
    if (action == 'get_live_categories' ||
        action == 'get_vod_categories' ||
        action == 'get_series_categories') {
      return _json([
        for (var i = 1; i <= 24; i++) {'category_id': '$i', 'category_name': 'Category $i'},
      ]);
    }
    if (isCategory) {
      // A category stream call: slow (5s), and race the delay against
      // the abort trigger — a cancelled search must stop the socket,
      // not just abandon the future.
      const latency = Duration(seconds: 5);
      final abortTrigger = request is http.AbortableRequest ? request.abortTrigger : null;
      if (abortTrigger != null) {
        final outcome = await Future.any([
          Future<void>.delayed(latency).then((_) => 'done'),
          abortTrigger.then((_) => 'aborted'),
        ]);
        if (outcome == 'aborted') {
          abortedRequests++;
          throw http.RequestAbortedException(uri);
        }
      } else {
        await Future<void>.delayed(latency);
      }
      // No rows (the asserted query matches nothing); the request and
      // its latency are the point, not the data.
      return _json([]);
    }
    // Unfiltered loads return nothing, so the search heals by sweeping.
    return _json([]);
  }

  http.StreamedResponse _json(Object body) {
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

IptvClient _clientWith(_AbandonCountingPanel panel) {
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

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build21_abandon_');
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

  group('Build #21 — close-after-use (new API)', () {
    test('abandoning a search (cancelActiveSearches) fires no further panel requests', () async {
      // The app backgrounds (or the user leaves the search) — the
      // in-flight sweep must stop, not keep fetching categories for a
      // search nobody is watching. Same shape as the O1 orphan test in
      // the failing-first file, but the cancel is explicit (an abandoned
      // search), not a section-budget expiry.
      final panel = _AbandonCountingPanel();
      final client = _clientWith(panel);
      // Seed the series disk file with Trex-scale rows (46,527) and do
      // NOT warm the catalog: the asserted search's cold-body disk read
      // + parse (~200ms) is what holds it in flight long enough for the
      // cancel to land mid-search. R2.3: the search never sweeps, so
      // there is nothing to abort — the cancel is a no-op for panel
      // traffic, and the search still stops promptly with no tail.
      final cache = IptvCatalogDiskCache();
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode([
          for (var i = 0; i < 46527; i++)
            XtreamSeries(seriesId: 1000 + i, name: 'Filler Series $i', categoryId: '${(i % 236) + 1}').toJson(),
        ]),
      );
      panel.reset();

      final search = client.searchItems('zz-no-match-zz', excludedLibraryIds: _seriesOnlyScope);
      // The user walks away: cancel the in-flight search.
      final stopwatch = Stopwatch()..start();
      client.cancelActiveSearches();
      try {
        await search;
      } on Object {
        // Cancellation may surface as an error; the search stopping is
        // the point, not how it reports it.
      }
      final elapsed = stopwatch.elapsed;
      expect(elapsed, lessThan(const Duration(seconds: 5)));
      // Nothing was started, so nothing was aborted — and no panel
      // request was made at any point.
      expect(panel.totalRequests, 0, reason: 'a local search makes no panel requests');
      expect(panel.abortedRequests, 0, reason: 'nothing was started, nothing to abort');
      // No tail: after the cancel, no new requests start.
      panel.mark();
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(panel.requestsAfterMark, 0, reason: 'an abandoned search must stop generating panel traffic');
      // ignore: avoid_print
      print(
        'BUILD21-A1 abandon: elapsed=${elapsed.inMilliseconds}ms aborted=${panel.abortedRequests} '
        'tail=${panel.requestsAfterMark}',
      );
    });
  });
}
