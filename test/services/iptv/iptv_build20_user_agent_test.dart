// BUILD #20 — Trex refuses PlezTV (HTTP 403) while TiviMate works.
//
// THE PHONE FAILURE (v1.0.2-2.25.0, 2026-11-09 ~20:47 EST, screenshot
// ~/workspace/user/files/9663_0_vy01.jpg):
//   * Discover shows the banner "trex refused access for this account" and
//     "Unable to load Discover" — on BOTH home WiFi and mobile data (LTE).
//   * TiviMate works with the SAME account on the SAME phone/network.
//   * The panel answers HTTP 403 to PlezTV's player_api.php calls.
//
// WHAT THE RESEARCH PROVED (RESEARCH_TREX_REFUSAL.md — code, not guesses):
//   * XtreamApi sends NO User-Agent of its own, so the panel sees Dart's
//     default `Dart/3.13 (dart:io)` — a distinctive, non-player signature.
//   * Xtream panels enforce per-user allowed-UA lists and global blocked-UA
//     patterns as a first-class feature (USER_AGENT_BAN / EMPTY_UA); setting
//     the UA to `VLC` is the #1 documented 403 fix.
//   * The fix: send `User-Agent: VLC` (configurable in Settings → IPTV)
//     on EVERY Xtream request, through both choke points (_fetchBody and
//     _getText). The 403 → HealthStatus.accessDenied mapping is UNCHANGED.
//
// These tests FAIL on ac3ddcbda (no UA header is sent at all) and pass
// once the fix lands. They use only the pre-fix public API, so they can
// run failing-first on base. The new-API tests (fixed UA, provider
// re-read, choice resolution) live in
// iptv_build20_user_agent_setting_test.dart and only compile after the fix.
//
// No live panel: fakes only.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

/// Captures every outgoing request and answers each Xtream endpoint with a
/// minimal valid payload, so the test drives the real client code paths.
class _CapturingClient extends MockClient {
  final List<http.BaseRequest> captured = [];

  _CapturingClient() : super(_handler);

  // The handler needs the captured list, so routing goes through a static
  // that the instance wires up via [captured] below.
  static Future<http.Response> _handler(http.Request request) async {
    return _route(request);
  }

  static Future<http.Response> _route(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('xmltv.php')) {
      return http.Response('<tv></tv>', 200);
    }
    if (path.endsWith('get.php')) {
      return http.Response('#EXTM3U', 200);
    }
    final action = request.url.queryParameters['action'];
    switch (action) {
      case null:
        return http.Response(
          jsonEncode({
            'user_info': {'status': 'Active', 'exp_date': '1790000000'},
          }),
          200,
        );
      case 'get_live_categories':
      case 'get_vod_categories':
      case 'get_series_categories':
        return http.Response(
          jsonEncode([
            {'category_id': '1', 'category_name': 'News'},
          ]),
          200,
        );
      case 'get_live_streams':
        return http.Response(
          jsonEncode([
            {'stream_id': 1, 'name': 'Ch 1', 'category_id': '1', 'tv_archive': 0, 'tv_archive_duration': 0},
          ]),
          200,
        );
      case 'get_vod_streams':
        return http.Response(
          jsonEncode([
            {'stream_id': 2, 'name': 'Movie 1', 'category_id': '1'},
          ]),
          200,
        );
      case 'get_series':
        return http.Response(
          jsonEncode([
            {'series_id': 3, 'name': 'Show 1', 'category_id': '1'},
          ]),
          200,
        );
      case 'get_series_info':
        return http.Response(
          jsonEncode({
            'info': {'name': 'Show 1'},
            'episodes': {
              '1': [
                {'id': 10, 'episode_num': 1, 'title': 'E1'},
              ],
            },
          }),
          200,
        );
      case 'get_simple_data_table':
        return http.Response(jsonEncode({}), 200);
      case 'get_short_epg':
        return http.Response(jsonEncode({'epg_listings': []}), 200);
      default:
        return http.Response('[]', 200);
    }
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    captured.add(request);
    return super.send(request);
  }
}

/// The User-Agent on one captured request, looked up case-insensitively
/// (package:http lowercases header names on the wire; the fake keeps them
/// as the client set them).
String? _userAgentOf(http.BaseRequest request) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == 'user-agent') return entry.value;
  }
  return null;
}

void main() {
  group('Build #20 — Xtream User-Agent', () {
    test('default UA is VLC on every Xtream call, never a Dart/ UA', () async {
      final capturing = _CapturingClient();
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        httpClient: capturing,
      );
      addTearDown(api.close);

      // Every public call the app makes against the panel — login, all
      // three category lists, all three catalog lists, series detail,
      // simple data table, short EPG, the XMLTV feed and the M3U export.
      await api.getUserInfo();
      await api.getLiveCategories();
      await api.getVodCategories();
      await api.getSeriesCategories();
      await api.getLiveStreams();
      await api.getVodStreams();
      await api.getSeries();
      await api.getSeriesInfo(3);
      await api.getSimpleDataTable();
      await api.getShortEpg('1');
      await api.getXmltv();
      await api.getM3u();

      expect(capturing.captured.length, 12);
      for (final request in capturing.captured) {
        final ua = _userAgentOf(request);
        expect(ua, isNotNull, reason: '${request.url} carries no User-Agent');
        expect(ua, 'VLC', reason: '${request.url}');
        expect(ua, isNot(startsWith('Dart/')), reason: '${request.url}');
      }
      // Belt and braces: no request anywhere in the run carried a Dart UA.
      expect(capturing.captured.map(_userAgentOf).where((ua) => ua != null && ua.startsWith('Dart/')), isEmpty);
    });

    test('403 still surfaces as access denied (control — passes on base)', () async {
      final denying = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        httpClient: MockClient((_) async => http.Response('Forbidden', 403)),
      );
      addTearDown(denying.close);

      // The client-level contract: a 403 is 'Xtream access denied'.
      await expectLater(
        denying.getUserInfo(),
        throwsA(
          isA<MediaServerHttpException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.message, 'message', 'Xtream access denied'),
        ),
      );

      // The app-level contract: that exception maps to
      // HealthStatus.accessDenied — the state behind the
      // "refused access for this account" banner. The fix changes the
      // request, not this mapping.
      final connection = XtreamConnection(
        id: 'test-trex',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final client = IptvClient.forConnection(connection);
      addTearDown(client.close);
      client.testXtreamApi = denying;
      expect(await client.checkHealth(), HealthStatus.accessDenied);
    });
  });
}
