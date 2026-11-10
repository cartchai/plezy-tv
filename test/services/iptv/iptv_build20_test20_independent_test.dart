// INDEPENDENT TESTER probe for build #20 (Trex 403 User-Agent fix).
//
// Written by the tester, not the builder. Uses its own capturing client,
// its own endpoint assertions, the real SettingsService read path, and the
// real settings export/import round-trip. No live panel: fakes only.
//
// What it proves that the builder's tests do not:
//   * Every Xtream endpoint (by URL, not just by count) carries a
//     User-Agent on the wire, and none carries a Dart/ UA.
//   * The Settings -> resolve -> wire chain with the REAL SettingsService:
//     default VLC; a setting change applies to the NEXT request; custom
//     text flows through; blank/unknown resolve to VLC.
//   * The two new prefs survive a settings export/import round-trip.
//   * A fake 403 still maps to HealthStatus.accessDenied AND the banner
//     string the phone shows ("refused access for this account").

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_export_service.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

/// Minimal valid payload per endpoint, keyed the same way the app routes.
Future<http.Response> _answer(http.Request request) async {
  final path = request.url.path;
  if (path.endsWith('xmltv.php')) return http.Response('<tv></tv>', 200);
  if (path.endsWith('get.php')) return http.Response('#EXTM3U', 200);
  switch (request.url.queryParameters['action']) {
    case null:
      return http.Response(jsonEncode({'user_info': {'status': 'Active'}}), 200);
    case 'get_live_categories':
    case 'get_vod_categories':
    case 'get_series_categories':
      return http.Response(jsonEncode([{'category_id': '1', 'category_name': 'News'}]), 200);
    case 'get_live_streams':
      return http.Response(
        jsonEncode([{'stream_id': 1, 'name': 'Ch 1', 'category_id': '1', 'tv_archive': 0, 'tv_archive_duration': 0}]),
        200,
      );
    case 'get_vod_streams':
      return http.Response(jsonEncode([{'stream_id': 2, 'name': 'Movie 1', 'category_id': '1'}]), 200);
    case 'get_series':
      return http.Response(jsonEncode([{'series_id': 3, 'name': 'Show 1', 'category_id': '1'}]), 200);
    case 'get_series_info':
      return http.Response(
        jsonEncode({'info': {'name': 'Show 1'}, 'episodes': {'1': [{'id': 10, 'episode_num': 1, 'title': 'E1'}]}}),
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

/// The User-Agent a request actually carried (header names are matched
/// case-insensitively, as on the wire).
String? _uaOf(http.Request request) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == 'user-agent') return entry.value;
  }
  return null;
}

/// Short label for a request, for failure messages.
String _label(http.Request request) {
  final action = request.url.queryParameters['action'];
  return action ?? request.url.pathSegments.last;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocaleSync(AppLocale.en);

  setUp(() => resetSharedPreferencesForTest());

  group('Tester probe #20 — every Xtream request carries a UA', () {
    test('all 12 endpoints send VLC by default, never a Dart/ UA', () async {
      final seen = <http.Request>[];
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        httpClient: MockClient((request) async {
          seen.add(request);
          return _answer(request);
        }),
      );
      addTearDown(api.close);

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

      // Assert by endpoint identity, not just by count: the list must be
      // exactly the 12 calls the app makes, each with its own URL.
      final labels = seen.map(_label).toList();
      expect(labels, [
        'player_api.php',
        'get_live_categories',
        'get_vod_categories',
        'get_series_categories',
        'get_live_streams',
        'get_vod_streams',
        'get_series',
        'get_series_info',
        'get_simple_data_table',
        'get_short_epg',
        'xmltv.php',
        'get.php',
      ]);
      for (final request in seen) {
        final ua = _uaOf(request);
        expect(ua, isNotNull, reason: '${_label(request)} carries no User-Agent');
        expect(ua, 'VLC', reason: _label(request));
        expect(ua, isNot(startsWith('Dart/')), reason: _label(request));
      }
    });

    test('the real SettingsService drives the wire UA, per request', () async {
      final settings = await SettingsService.getInstance();
      final seen = <http.Request>[];
      // This closure is the same wiring IptvClient uses (provider re-read
      // per request through XtreamUserAgent.resolve).
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        userAgentProvider: () => XtreamUserAgent.resolve(
          settings.read(SettingsService.iptvXtreamUserAgent),
          settings.read(SettingsService.iptvXtreamUserAgentCustom),
        ),
        httpClient: MockClient((request) async {
          seen.add(request);
          return _answer(request);
        }),
      );
      addTearDown(api.close);

      // Default (nothing stored): VLC.
      expect(settings.read(SettingsService.iptvXtreamUserAgent), 'vlc');
      await api.getUserInfo();
      expect(_uaOf(seen.single), 'VLC');

      // Change the setting: the NEXT request carries the new value, with
      // no client rebuild.
      await settings.write(SettingsService.iptvXtreamUserAgent, 'smarters');
      await api.getUserInfo();
      expect(_uaOf(seen.last), 'IPTVSmartersPro');

      await settings.write(SettingsService.iptvXtreamUserAgent, 'browser');
      await api.getUserInfo();
      expect(_uaOf(seen.last), 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');

      // Custom text flows through.
      await settings.write(SettingsService.iptvXtreamUserAgent, 'custom');
      await settings.write(SettingsService.iptvXtreamUserAgentCustom, 'MyAgent/9');
      await api.getUserInfo();
      expect(_uaOf(seen.last), 'MyAgent/9');

      // Blank custom text falls back to VLC (never an empty UA).
      await settings.write(SettingsService.iptvXtreamUserAgentCustom, '   ');
      await api.getUserInfo();
      expect(_uaOf(seen.last), 'VLC');

      // An unknown stored choice falls back to VLC.
      await settings.write(SettingsService.iptvXtreamUserAgent, 'bogus-choice');
      await api.getUserInfo();
      expect(_uaOf(seen.last), 'VLC');
    });

    test('resolve: choice wins over custom text; keys are exact', () {
      // A stored custom value is ignored unless the choice is 'custom'.
      expect(XtreamUserAgent.resolve('vlc', 'MyAgent/9'), 'VLC');
      // Choice keys are lowercase exact — an uppercase key is unknown.
      expect(XtreamUserAgent.resolve('VLC', ''), 'VLC');
      expect(XtreamUserAgent.resolve('SMARTERS', ''), 'VLC');
    });

    test('a fake 403 still maps to accessDenied and the banner string', () async {
      final denying = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        httpClient: MockClient((_) async => http.Response('Forbidden', 403)),
      );
      addTearDown(denying.close);

      await expectLater(
        denying.getUserInfo(),
        throwsA(
          isA<MediaServerHttpException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having((e) => e.message, 'message', 'Xtream access denied'),
        ),
      );

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

      // The banner the phone renders for that state.
      expect(t.connections.accessDeniedOne(name: 'Trex'), 'Trex refused access for this account');
    });
  });

  group('Tester probe #20 — new prefs survive settings export/import', () {
    test('round-trip of iptv_xtream_user_agent + custom', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString('iptv_xtream_user_agent', 'browser');
      await prefs.setString('iptv_xtream_user_agent_custom', 'MyAgent/9');

      final exported = SettingsExportService.buildExportMap(prefs, currentUserUuid: 'alice');
      final map = exported['prefs'] as Map<String, dynamic>;
      expect(map['iptv_xtream_user_agent'], {'type': 'string', 'value': 'browser'});
      expect(map['iptv_xtream_user_agent_custom'], {'type': 'string', 'value': 'MyAgent/9'});

      await prefs.clear();
      final result = await SettingsExportService.applyImportMap(exported, prefs, currentUserUuid: 'bob');
      expect(result.keysSkipped, 0);
      expect(prefs.getString('iptv_xtream_user_agent'), 'browser');
      expect(prefs.getString('iptv_xtream_user_agent_custom'), 'MyAgent/9');
    });

    test('defaults round-trip as VLC when nothing is stored', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final exported = SettingsExportService.buildExportMap(prefs, currentUserUuid: 'alice');
      final map = exported['prefs'] as Map<String, dynamic>;
      // Unset prefs are not exported; the app default (vlc) applies on read.
      expect(map, isNot(contains('iptv_xtream_user_agent')));
      final settings = await SettingsService.getInstance();
      expect(settings.read(SettingsService.iptvXtreamUserAgent), 'vlc');
      expect(XtreamUserAgent.resolve(settings.read(SettingsService.iptvXtreamUserAgent), ''), 'VLC');
    });
  });
}
