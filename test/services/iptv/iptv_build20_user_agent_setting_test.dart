// BUILD #20 — Xtream User-Agent: configured values flow through.
//
// Companion to iptv_build20_user_agent_test.dart (which proves the default
// failing-first on the pre-fix API). These tests exercise the NEW API the
// fix adds — a fixed `userAgent`, a per-request `userAgentProvider`, and
// [XtreamUserAgent.resolve] for the Settings choice — so they only compile
// once the fix lands.
//
// No live panel: fakes only.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

String? _userAgentOf(http.BaseRequest request) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == 'user-agent') return entry.value;
  }
  return null;
}

void main() {
  group('Build #20 — configured Xtream User-Agent', () {
    test('a fixed UA is sent instead of the default', () async {
      final captured = <http.BaseRequest>[];
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        userAgent: 'IPTVSmartersPro',
        httpClient: MockClient((request) async {
          captured.add(request);
          return http.Response(
            jsonEncode({
              'user_info': {'status': 'Active'},
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);

      await api.getUserInfo();
      await api.getLiveCategories();

      expect(captured.length, 2);
      for (final request in captured) {
        expect(_userAgentOf(request), 'IPTVSmartersPro', reason: '${request.url}');
      }
    });

    test('the provider is re-read per request, so a setting change applies to the next request', () async {
      var current = 'VLC';
      final captured = <http.BaseRequest>[];
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        userAgentProvider: () => current,
        httpClient: MockClient((request) async {
          captured.add(request);
          return http.Response(
            jsonEncode({
              'user_info': {'status': 'Active'},
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);

      await api.getUserInfo();
      expect(_userAgentOf(captured.single), 'VLC');

      // The user changes Settings → IPTV → Xtream User-Agent; no client
      // rebuild, no restart — the next request must carry the new value.
      current = 'MyCustomAgent/1.0';
      await api.getUserInfo();
      expect(_userAgentOf(captured.last), 'MyCustomAgent/1.0');
    });

    test('the provider wins over a fixed UA', () async {
      final captured = <http.BaseRequest>[];
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        userAgent: 'IPTVSmartersPro',
        userAgentProvider: () => 'VLC',
        httpClient: MockClient((request) async {
          captured.add(request);
          return http.Response(
            jsonEncode({
              'user_info': {'status': 'Active'},
            }),
            200,
          );
        }),
      );
      addTearDown(api.close);

      await api.getUserInfo();
      expect(_userAgentOf(captured.single), 'VLC');
    });

    test('resolve maps every stored choice, with VLC as the fallback', () {
      expect(XtreamUserAgent.resolve('vlc', ''), 'VLC');
      expect(XtreamUserAgent.resolve('smarters', ''), 'IPTVSmartersPro');
      expect(XtreamUserAgent.resolve('browser', ''), 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');
      expect(XtreamUserAgent.resolve('custom', 'MyAgent/2.0'), 'MyAgent/2.0');
      // A blank custom value and an unknown stored choice must never
      // produce an empty UA — both fall back to VLC.
      expect(XtreamUserAgent.resolve('custom', ''), 'VLC');
      expect(XtreamUserAgent.resolve('custom', '   '), 'VLC');
      expect(XtreamUserAgent.resolve('something-else', ''), 'VLC');
      // Custom text is trimmed: a stray space must not ship as a UA.
      expect(XtreamUserAgent.resolve('custom', '  MyAgent/2.0  '), 'MyAgent/2.0');
    });
  });
}
