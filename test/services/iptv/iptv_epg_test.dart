import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/xmltv_parser.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

/// EPG layer tests (build #6): the per-channel lazy fetch behind the
/// guide, the settings that bound it, and the XMLTV parser behind the
/// M3U path. No network except a loopback server for the M3U test; no
/// streams are ever opened (EPG calls are API calls).
///
/// One honest limit, documented here and in IPTV_EPG_NOTES.md: the EPG
/// cache is in-memory, so it starts cold on every launch — "update on app
/// start" has no observable effect yet (the first fetch after launch is
/// always fresh). The pref is read and the force-refresh path exists, so
/// it takes effect once the cache is persisted.

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: 'pass',
  createdAt: DateTime.utc(2026, 11, 6),
);

XtreamEpgProgram _epg({
  String id = 'p1',
  String title = 'Show',
  required DateTime start,
  required DateTime end,
  String? channelId,
}) => XtreamEpgProgram(
  id: id,
  title: title,
  description: '',
  startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
  stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
  channelId: channelId,
);

/// Fake provider: scripted short-EPG listings per stream id, with a call
/// counter so the tests can prove the cache/interval behaviour. The
/// `channelId` on the listings is deliberately wrong ('provider-ch') —
/// the mapper must use the channel key it asked for, not the API's id.
class _EpgFakeApi extends XtreamApi {
  _EpgFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pass');

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Set<String> failing = {};
  final Map<String, int> calls = {};

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => const [
    XtreamLiveStream(
      streamId: 100,
      name: 'Trex News',
      categoryId: '1',
      tvArchive: true,
      tvArchiveDuration: 86400,
    ),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout}) async {
    calls[streamId] = (calls[streamId] ?? 0) + 1;
    if (failing.contains(streamId)) throw StateError('provider down');
    return scripted[streamId] ?? const [];
  }
}

/// Restores the real dart:io HttpClient, bypassing the test binding's
/// always-400 mock. Used only by the loopback-server M3U tests. The
/// inherited createHttpClient already returns a real client; the subclass
/// exists because HttpOverrides is abstract.
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _EpgFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    api = _EpgFakeApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    support = client.liveTv as IptvLiveTvSupport;
  });

  Future<void> setPrefs({
    int? daysToLoad,
    int? intervalHours,
    int? pastDays,
    bool? updateOnStart,
    int? offsetMinutes,
  }) async {
    final settings = await SettingsService.getInstance();
    if (daysToLoad != null) await settings.write(SettingsService.iptvEpgDaysToLoad, daysToLoad);
    if (intervalHours != null) {
      await settings.write(SettingsService.iptvEpgUpdateIntervalHours, intervalHours);
    }
    if (pastDays != null) await settings.write(SettingsService.iptvEpgPastDays, pastDays);
    if (updateOnStart != null) {
      await settings.write(SettingsService.iptvEpgUpdateOnStart, updateOnStart);
    }
    if (offsetMinutes != null) {
      await settings.write(SettingsService.iptvEpgTimeOffsetMinutes, offsetMinutes);
    }
  }

  DateTime nowFn() => DateTime.now();

  test('maps short-EPG listings onto the requested channel key', () async {
    final now = nowFn();
    api.scripted['100'] = [
      _epg(id: 'a', title: 'Morning News', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1)), channelId: 'provider-ch'),
      _epg(id: 'b', title: 'Midday', start: now.add(const Duration(hours: 1)), end: now.add(const Duration(hours: 2)), channelId: 'provider-ch'),
    ];

    final programs = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );

    expect(programs, hasLength(2));
    expect(programs[0].title, 'Morning News');
    expect(programs[0].channelIdentifier, '100');
    expect(programs[0].beginsAt, now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);
    expect(programs[0].endsAt, now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);
    expect(programs[1].title, 'Midday');
    expect(api.calls['100'], 1);
  });

  test('days window bounds the fetch: listings outside it never appear', () async {
    await setPrefs(daysToLoad: 1, pastDays: 1);
    final now = nowFn();
    api.scripted['100'] = [
      _epg(id: 'old', title: 'Two days ago', start: now.subtract(const Duration(days: 2)), end: now.subtract(const Duration(days: 2)).add(const Duration(hours: 1))),
      _epg(id: 'now', title: 'Now', start: now.subtract(const Duration(minutes: 30)), end: now.add(const Duration(minutes: 30))),
      _epg(id: 'far', title: 'Two days out', start: now.add(const Duration(days: 2)), end: now.add(const Duration(days: 2)).add(const Duration(hours: 1))),
    ];

    // Ask for a WIDER window than the settings allow — the settings
    // window, not the request, must bound the result.
    final programs = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(days: 2)),
      to: now.add(const Duration(days: 3)),
    );

    expect(programs.map((p) => p.title), ['Now']);
  });

  test('interval gates refreshes and Update now busts the cache', () async {
    await setPrefs(intervalHours: 24);
    final now = nowFn();
    api.scripted['100'] = [
      _epg(start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 6));

    await support.fetchEpgForChannel('100', from: from, to: to);
    await support.fetchEpgForChannel('100', from: from, to: to);
    expect(api.calls['100'], 1, reason: 'second fetch inside the interval must use the cache');

    await support.refreshEpgCache();
    final afterUpdate = await support.fetchEpgForChannel('100', from: from, to: to);
    expect(api.calls['100'], 2, reason: 'Update now must bust the cache');
    expect(afterUpdate, hasLength(1));
  });

  test('manual-only interval never expires the cache on its own', () async {
    await setPrefs(intervalHours: 0);
    final now = nowFn();
    api.scripted['100'] = [
      _epg(start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 6));

    await support.fetchEpgForChannel('100', from: from, to: to);
    await support.fetchEpgForChannel('100', from: from, to: to);
    expect(api.calls['100'], 1);
  });

  test('Clear guide empties it and stays empty until a refresh', () async {
    final now = nowFn();
    api.scripted['100'] = [
      _epg(start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 6));

    expect(await support.fetchEpgForChannel('100', from: from, to: to), hasLength(1));
    expect(api.calls['100'], 1);

    await support.clearEpgCache();
    expect(await support.fetchEpgForChannel('100', from: from, to: to), isEmpty);
    expect(api.calls['100'], 1, reason: 'Clear must not trigger a refetch');

    await support.refreshEpgCache();
    expect(await support.fetchEpgForChannel('100', from: from, to: to), hasLength(1));
    expect(api.calls['100'], 2);
  });

  test('per-channel failure fails open and never takes the guide down', () async {
    final now = nowFn();
    api.failing.add('101');
    api.scripted['100'] = [
      _epg(start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];
    final from = now.subtract(const Duration(hours: 1));
    final to = now.add(const Duration(hours: 6));

    expect(await support.fetchEpgForChannel('101', from: from, to: to), isEmpty);
    expect(await support.fetchEpgForChannel('100', from: from, to: to), hasLength(1));
  });

  test('time offset shifts displayed programs', () async {
    await setPrefs(offsetMinutes: 60);
    final now = nowFn();
    final start = now.subtract(const Duration(hours: 1));
    api.scripted['100'] = [_epg(start: start, end: now.add(const Duration(hours: 1)))];

    final programs = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 2)),
      to: now.add(const Duration(hours: 6)),
    );

    expect(programs, hasLength(1));
    expect(programs[0].beginsAt, start.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000);
  });

  test('empty title falls back to Unknown Program', () async {
    final now = nowFn();
    api.scripted['100'] = [
      _epg(id: 'x', title: '', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];

    final programs = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );

    expect(programs, hasLength(1));
    expect(programs[0].title, 'Unknown Program');
  });

  test('update-on-start fetch still loads (in-memory cache starts cold)', () async {
    await setPrefs(updateOnStart: true);
    final now = nowFn();
    api.scripted['100'] = [
      _epg(start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];

    final programs = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );

    expect(programs, hasLength(1));
    expect(api.calls['100'], 1);
  });

  group('parseXmltv', () {
    test('decodes programmes, converts offsets to UTC, skips malformed rows', () {
      const body = '''
<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="ch1"><display-name>Channel One</display-name></channel>
  <programme start="20261106120000 +0000" stop="20261106130000 +0000" channel="ch1">
    <title>Noon News</title><desc>Top stories</desc>
  </programme>
  <programme start="20261106130000 +0200" stop="20261106140000 +0200" channel="ch1">
    <title>Afternoon</title>
  </programme>
  <programme start="bogus" stop="20261106150000 +0000" channel="ch1"><title>Bad</title></programme>
  <programme start="20261106140000 +0000" stop="20261106150000 +0000" channel="ch2">
    <title>Other Channel</title>
  </programme>
</tv>''';

      final programs = parseXmltv(body);

      expect(programs, hasLength(3));
      expect(programs[0].title, 'Noon News');
      expect(programs[0].description, 'Top stories');
      expect(programs[0].startEpoch, DateTime.utc(2026, 11, 6, 12).millisecondsSinceEpoch ~/ 1000);
      // 13:00 +0200 is 11:00 UTC.
      expect(programs[1].startEpoch, DateTime.utc(2026, 11, 6, 11).millisecondsSinceEpoch ~/ 1000);
      expect(programs[1].stopEpoch, DateTime.utc(2026, 11, 6, 12).millisecondsSinceEpoch ~/ 1000);
      expect(programs[2].channelId, 'ch2');
    });

    test('throws when the document itself does not parse', () {
      expect(() => parseXmltv('<tv><programme'), throwsA(anything));
    });
  });

  group('M3U XMLTV path', () {
    late HttpServer server;
    HttpOverrides? previousOverrides;

    String xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

    /// The test binding mocks every HttpClient to answer 400. This group
    /// serves a real loopback server, so it restores the real client for
    /// its duration (playlist fetch + XMLTV fetch both go through it).
    setUp(() async {
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/playlist.m3u') {
          response.headers.contentType = ContentType.text;
          response.write(
            '#EXTM3U\n'
            '#EXTINF:-1 tvg-id="ch1" tvg-name="Channel One" group-title="News",Channel One\n'
            'http://example.com/ch1.m3u8\n'
            '#EXTINF:-1 tvg-name="No Id" group-title="News",No Id\n'
            'http://example.com/noid.m3u8\n',
          );
        } else if (request.uri.path == '/epg.xml') {
          final now = DateTime.now();
          response.headers.contentType = ContentType.text;
          response.write(
            '<tv>'
            '<programme start="${xmltvTime(now.subtract(const Duration(hours: 1)))}" '
            'stop="${xmltvTime(now.add(const Duration(hours: 1)))}" channel="ch1">'
            '<title>Channel One Show</title><desc>Guide via XMLTV</desc>'
            '</programme>'
            '<programme start="${xmltvTime(now)}" '
            'stop="${xmltvTime(now.add(const Duration(hours: 1)))}" channel="other">'
            '<title>Not This Channel</title>'
            '</programme>'
            '</tv>',
          );
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      HttpOverrides.global = previousOverrides;
    });

    test('XMLTV guide loads for the tvg-id channel only', () async {
      final port = server.port;
      final connection = M3uConnection(
        id: 'm3u1',
        name: 'Test M3U',
        playlistUrl: 'http://127.0.0.1:$port/playlist.m3u',
        epgUrl: 'http://127.0.0.1:$port/epg.xml',
        createdAt: DateTime.utc(2026, 11, 6),
      );
      final m3uClient = IptvClient.m3u(m3uConnection: connection);
      final channels = await m3uClient.iptvChannels();
      expect(channels.map((c) => c.key), contains('ch1'));

      final m3uSupport = m3uClient.liveTv as IptvLiveTvSupport;
      final now = DateTime.now();
      final programs = await m3uSupport.fetchEpgForChannel(
        'ch1',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 6)),
      );

      expect(programs, hasLength(1));
      expect(programs[0].title, 'Channel One Show');
      expect(programs[0].summary, 'Guide via XMLTV');
      expect(programs[0].channelIdentifier, 'ch1');
    });

    test('M3U without an EPG URL degrades gracefully to an empty guide', () async {
      final port = server.port;
      final connection = M3uConnection(
        id: 'm3u1',
        name: 'Test M3U',
        playlistUrl: 'http://127.0.0.1:$port/playlist.m3u',
        createdAt: DateTime.utc(2026, 11, 6),
      );
      final m3uClient = IptvClient.m3u(m3uConnection: connection);
      await m3uClient.iptvChannels();

      final m3uSupport = m3uClient.liveTv as IptvLiveTvSupport;
      final now = DateTime.now();
      expect(
        await m3uSupport.fetchEpgForChannel(
          'ch1',
          from: now.subtract(const Duration(hours: 1)),
          to: now.add(const Duration(hours: 6)),
        ),
        isEmpty,
      );
    });
  });
}
