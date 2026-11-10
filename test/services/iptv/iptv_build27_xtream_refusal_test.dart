// Failing-first tests for build #27 (refusal recorder, v1.0.8).
//
// Proves the Xtream API client hands every refusal — 403, 429, 401,
// timeout, socket error — to the refusal recorder with the response
// headers and body attached, that a cancelled request is NOT recorded,
// and that no credential ever lands in a recorded entry. On the base
// (2643073f9) these tests fail to compile: `XtreamApi` has no
// `onRefusal` hook and `IptvRefusalEntry` does not exist. No live
// panel: MockClient only. Credentials below are fake.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/iptv/iptv_refusal_log.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

XtreamApi _api({
  required http.Client client,
  List<IptvRefusalEntry>? captured,
  String? userAgent,
}) {
  return XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'alice-7',
    password: 'hunter-9',
    httpClient: client,
    userAgent: userAgent,
    onRefusal: captured == null ? null : (entry) async => captured.add(entry),
  );
}

void main() {
  test('403 with Cloudflare headers + body is recorded with cf-ray and body', () async {
    final captured = <IptvRefusalEntry>[];
    final api = _api(
      captured: captured,
      client: MockClient(
        (_) async => http.Response(
          '<html><title>Just a moment...</title></html>',
          403,
          headers: {'cf-ray': '8a1b2c3d4e5f6789-IAD', 'server': 'cloudflare'},
        ),
      ),
    );
    await expectLater(api.getUserInfo(), throwsA(isA<Exception>()));
    expect(captured, hasLength(1));
    final entry = captured.single;
    expect(entry.statusCode, 403);
    expect(entry.failureKind, 'http');
    expect(entry.headers['cf-ray'], '8a1b2c3d4e5f6789-IAD');
    expect(entry.headers['server'], 'cloudflare');
    expect(entry.bodySnippet, contains('Just a moment...'));
    expect(entry.action, 'player_api.php');
    expect(entry.userAgent, 'VLC');
    final json = jsonEncode(entry.toJson());
    expect(json, isNot(contains('alice-7')));
    expect(json, isNot(contains('hunter-9')));
  });

  test('403 with a panel JSON error body keeps the body', () async {
    final captured = <IptvRefusalEntry>[];
    final api = _api(
      captured: captured,
      client: MockClient(
        (_) async => http.Response('{"error": "USER_AGENT_BAN"}', 403, headers: {'server': 'nginx'}),
      ),
    );
    await expectLater(api.getLiveCategories(), throwsA(isA<Exception>()));
    expect(captured, hasLength(1));
    expect(captured.single.statusCode, 403);
    expect(captured.single.bodySnippet, contains('USER_AGENT_BAN'));
    expect(captured.single.action, 'player_api.php?action=get_live_categories');
  });

  test('429 with retry-after is recorded with the header', () async {
    final captured = <IptvRefusalEntry>[];
    final api = _api(
      captured: captured,
      client: MockClient((_) async => http.Response('Slow down', 429, headers: {'retry-after': '120'})),
    );
    await expectLater(api.getVodCategories(), throwsA(isA<Exception>()));
    expect(captured, hasLength(1));
    expect(captured.single.statusCode, 429);
    expect(captured.single.headers['retry-after'], '120');
  });

  test('401 is recorded', () async {
    final captured = <IptvRefusalEntry>[];
    final api = _api(
      captured: captured,
      client: MockClient((_) async => http.Response('Unauthorized', 401)),
    );
    await expectLater(api.getUserInfo(), throwsA(isA<Exception>()));
    expect(captured, hasLength(1));
    expect(captured.single.statusCode, 401);
  });

  test('timeout is recorded with no HTTP status', () async {
    final captured = <IptvRefusalEntry>[];
    final api = _api(
      captured: captured,
      client: MockClient((_) async => throw TimeoutException('timed out')),
    );
    await expectLater(api.getUserInfo(), throwsA(isA<Exception>()));
    expect(captured, hasLength(1));
    expect(captured.single.statusCode, isNull);
    expect(captured.single.failureKind, 'timeout');
  });

  test('socket error is recorded as a connection failure', () async {
    final captured = <IptvRefusalEntry>[];
    final api = _api(
      captured: captured,
      client: MockClient((_) async => throw const SocketException('Connection refused')),
    );
    await expectLater(api.getUserInfo(), throwsA(isA<Exception>()));
    expect(captured, hasLength(1));
    expect(captured.single.statusCode, isNull);
    expect(captured.single.failureKind, 'connection');
  });

  test('a cancelled request is NOT a refusal and is not recorded', () async {
    final captured = <IptvRefusalEntry>[];
    final abort = Completer<void>();
    final api = _api(
      captured: captured,
      client: MockClient((request) async {
        // The search-abort path: the client raises the abort error the
        // AbortableRequest surfaces when its trigger fires.
        abort.complete();
        throw http.RequestAbortedException(request.url);
      }),
    );
    await expectLater(
      api.getLiveStreams(abortTrigger: abort.future),
      throwsA(isA<Exception>()),
    );
    expect(captured, isEmpty);
  });

  test('the XMLTV feed refusal is recorded with action xmltv.php', () async {
    final captured = <IptvRefusalEntry>[];
    final api = _api(
      captured: captured,
      client: MockClient((_) async => http.Response('Forbidden', 403)),
    );
    await expectLater(api.getXmltv(), throwsA(isA<Exception>()));
    expect(captured, hasLength(1));
    expect(captured.single.action, 'xmltv.php');
    expect(captured.single.statusCode, 403);
  });

  test('the configured User-Agent is the one recorded', () async {
    final captured = <IptvRefusalEntry>[];
    final api = _api(
      captured: captured,
      userAgent: 'IPTVSmartersPro',
      client: MockClient((_) async => http.Response('Forbidden', 403)),
    );
    await expectLater(api.getUserInfo(), throwsA(isA<Exception>()));
    expect(captured.single.userAgent, 'IPTVSmartersPro');
  });

  test('a body echoing the request URL is redacted before recording', () async {
    final captured = <IptvRefusalEntry>[];
    final api = _api(
      captured: captured,
      client: MockClient(
        (request) async => http.Response('Forbidden for ${request.url}', 403),
      ),
    );
    await expectLater(api.getUserInfo(), throwsA(isA<Exception>()));
    expect(captured, hasLength(1));
    final json = jsonEncode(captured.single.toJson());
    expect(json, isNot(contains('alice-7')));
    expect(json, isNot(contains('hunter-9')));
    expect(captured.single.action, 'player_api.php');
  });

  test('no onRefusal hook means no recording and the same throw', () async {
    final api = _api(client: MockClient((_) async => http.Response('Forbidden', 403)));
    await expectLater(api.getUserInfo(), throwsA(isA<Exception>()));
  });
}
