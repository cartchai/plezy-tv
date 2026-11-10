// BUILD #21 — deferred health probe (new-API test).
//
// The failing-first half (a probe during a search makes no request) lives
// in iptv_build21_search_offline_test.dart and uses only the pre-fix API.
// THIS file tests the new API — `IptvClient.onDeferredHealthProbe` — so it
// only compiles (and only runs) after the fix lands:
//
//   * A probe that arrives while a search is in flight is deferred, not
//     dropped: the client fires `onDeferredHealthProbe` ONCE, coalesced,
//     when the search ends, however many probes arrived mid-search.
//   * The deferred probe is exactly ONE panel request (the manager
//     re-probes this one connection; see MultiServerManager._probeIptvHealth).
//
// No live panel: fakes only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';

const _seriesOnlyScope = {'iptv:conn-xt-1:movies'};

/// Minimal fake panel: counts getUserInfo calls, answers the category list,
/// and delays per-category series calls so a search is in flight long
/// enough for probes to arrive mid-search.
class _ProbeCountingPanel extends http.BaseClient {
  int userInfoRequests = 0;
  int categoryRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    final action = uri.queryParameters['action'];
    if (action == null) {
      userInfoRequests++;
      return _json({'user_info': {'status': 'Active', 'exp_date': '1790000000'}});
    }
    if (action == 'get_series_categories') {
      return _json([
        for (var i = 1; i <= 24; i++) {'category_id': '$i', 'category_name': 'Category $i'},
      ]);
    }
    if (action == 'get_series' && uri.queryParameters['category_id'] != null) {
      categoryRequests++;
      await Future<void>.delayed(const Duration(seconds: 1));
      final id = uri.queryParameters['category_id']!;
      return _json([
        {'series_id': 90000 + int.parse(id), 'name': 'Swept Filler $id', 'category_id': id},
      ]);
    }
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

IptvClient _clientWith(_ProbeCountingPanel panel) {
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

Future<void> _waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build21_defer_');
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

  group('Build #21 — deferred health probe (new API)', () {
    test('two probes mid-search coalesce to one deferred probe after the search', () async {
      final panel = _ProbeCountingPanel();
      final client = _clientWith(panel);
      // Seed rows in categories 1-5 only, warm without healing (same
      // shape as the failing-first file), so the asserted search heals.
      final cache = IptvCatalogDiskCache();
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode([
          for (var i = 0; i < 5; i++)
            XtreamSeries(seriesId: 1000 + i, name: 'Filler Series $i', categoryId: '${i + 1}').toJson(),
        ]),
      );
      client.warmUpSeriesCatalog();
      await client.searchItems('Filler Series 0', excludedLibraryIds: _seriesOnlyScope);
      expect(panel.userInfoRequests, 0, reason: 'no probe has run yet');

      var callbackCount = 0;
      client.onDeferredHealthProbe = (c) {
        callbackCount++;
        // Stand-in for the manager's _probeIptvHealth: re-probe this
        // one connection and apply the verdict.
        unawaited(c.checkHealth());
      };

      final search = client.searchItems('zz-no-match-zz', excludedLibraryIds: _seriesOnlyScope);
      await _waitFor(() => panel.categoryRequests > 0);
      // Two probes arrive while the search is in flight.
      expect(await client.checkHealth(), HealthStatus.online);
      expect(await client.checkHealth(), HealthStatus.online);
      expect(panel.userInfoRequests, 0, reason: 'both mid-search probes were deferred, not sent');
      await search;
      // Let the deferred probe (fire-and-forget from the search's finally)
      // land.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(callbackCount, 1, reason: 'two deferred probes coalesce to one callback');
      expect(panel.userInfoRequests, 1, reason: 'the deferred probe is exactly one panel request');
      // ignore: avoid_print
      print('BUILD21-D1 defer: callbacks=$callbackCount userInfoRequests=${panel.userInfoRequests}');
    });
  });
}
