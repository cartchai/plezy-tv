// R5 REGRESSION — the splash wait tracks the slowest bind leg.
//
// Ported from the R5 research probe
// (`~/workspace/tmp_work/plezy-tv-research-r5-splash/probe_splash_bind_test.dart`,
// base 0b05c77b3). The probe's third test (the splash wait is uncapped with
// network up) is NOT ported here: its assertion moved to
// `test/screens/startup_bind_recovery_test.dart`, which now pins the 15 s
// cap instead.
//
// What these two tests pin: the IPTV bind leg is a single health probe
// (`getUserInfo`) whose only bound is the 30 s `_fetchBody` timeout — the
// leg tracks probe latency 1:1, and a hung probe settles at 30 s failing
// OPEN (the last-known health starts online). The R5 cap (15 s) is measured
// against these legs, so a future timeout change shows up here first.
//
// Fake panel only, tiny fixtures, real `MultiServerManager.addIptvConnection`.
// No live panel use, no streams opened (Trex ban stands).

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
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';

/// Fake panel serving tiny fixtures instantly — except the no-action
/// player_api.php call (getUserInfo, the health probe), which is delayed
/// by [userInfoDelay] or never answers when [hangUserInfo] is true.
class _SlowPanel extends http.BaseClient {
  _SlowPanel({this.userInfoDelay = Duration.zero, this.hangUserInfo = false});

  final Duration userInfoDelay;
  final bool hangUserInfo;
  int userInfoRequests = 0;
  int totalRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final uri = request.url;
    final action = uri.queryParameters['action'];
    if (action == null) {
      userInfoRequests++;
      if (hangUserInfo) {
        // Never completes: the caller's .timeout(30s) is the only bound.
        await Completer<void>().future;
      }
      if (userInfoDelay > Duration.zero) {
        await Future<void>.delayed(userInfoDelay);
      }
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(_bodyFor(action))),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }

  String _bodyFor(String? action) {
    switch (action) {
      case null:
        return jsonEncode({
          'user_info': {'status': 'Active', 'exp_date': '1790000000', 'max_connections': '1'},
        });
      case 'get_live_categories':
        return jsonEncode([
          {'category_id': '1', 'category_name': '|EN| Live 1'},
        ]);
      case 'get_vod_categories':
        return jsonEncode([
          {'category_id': '10', 'category_name': '|EN| Movies 10'},
        ]);
      case 'get_series_categories':
        return jsonEncode([
          {'category_id': '1219', 'category_name': '|EN| TOP SERIES'},
        ]);
      case 'get_live_streams':
        return jsonEncode([
          {'stream_id': 1, 'name': 'Ch 1', 'category_id': '1'},
        ]);
      case 'get_vod_streams':
        return jsonEncode([
          {'stream_id': 1, 'name': 'Movie 1', 'category_id': '10'},
        ]);
      case 'get_series':
        return jsonEncode([
          {'series_id': 219, 'name': 'EN - Game Of Thrones (2011)', 'category_id': '1219'},
        ]);
      default:
        return '[]';
    }
  }
}

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'conn-xt-1',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: testPassword,
  createdAt: DateTime.utc(2026, 11, 5),
);

void main() {
  late Directory tempDir;
  late MultiServerManager manager;
  late _SlowPanel panel;

  setUp(() async {
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
    await StorageService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_r5_bind_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    manager = MultiServerManager();
    addTearDown(manager.dispose);
  });

  tearDown(() async {
    IptvClient.debugClientFactory = null;
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  void installPanel(_SlowPanel p) {
    panel = p;
    IptvClient.debugClientFactory = (connection) {
      final client = IptvClient.xtream(xtreamConnection: connection as XtreamConnection);
      client.testXtreamApi = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
        httpClient: panel,
      );
      return client;
    };
  }

  test('R5: bind leg tracks a slow health probe 1:1 (8 s delay)', () async {
    installPanel(_SlowPanel(userInfoDelay: const Duration(seconds: 8)));
    final stopwatch = Stopwatch()..start();
    var done = false;
    final bind = manager.addIptvConnection(_trexConnection()).then((v) {
      done = true;
      return v;
    });
    // After 2 s the bind is still in flight — the splash would still be up.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(done, isFalse, reason: 'bind must still be waiting on the slow probe at +2s');
    final ok = await bind;
    stopwatch.stop();
    expect(ok, isTrue);
    expect(panel.userInfoRequests, 1, reason: 'the health probe is the only awaited panel call');
    expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(7500));
    expect(stopwatch.elapsedMilliseconds, lessThan(12000));
  });

  test(
    'R5: a hung health probe settles at the 30 s fetch timeout, failing open',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      installPanel(_SlowPanel(hangUserInfo: true));
      final stopwatch = Stopwatch()..start();
      final ok = await manager.addIptvConnection(_trexConnection());
      stopwatch.stop();
      expect(panel.userInfoRequests, 1);
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(28000));
      expect(stopwatch.elapsedMilliseconds, lessThan(36000));
      // Fails OPEN: _lastHealthStatus starts online, so the first transient
      // probe failure still binds healthy — the splash waits ~30 s and then
      // proceeds as if the server were fine. The R5 cap cuts that wait to
      // 15 s; this test pins the leg the cap is measured against.
      expect(ok, isTrue);
    },
  );
}
