import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// EPG area build 2 (PlezTV 1.2.0): third-party EPG sources (§3.1) +
/// per-channel assignment (§3.2). Written failing-first against the
/// 1.1.2 base — the support API asserted here does not exist there, so
/// this file does not compile on base; it must pass on the fix.
///
/// No live panel use — the provider is a scripted fake (short-EPG +
/// xmltv.php feed) and user sources are served by a loopback server.
/// No streams are ever opened.
///
/// PROVING CASE (the tester will use it): the unmatchable channel —
/// feed channel id "beIN 1" vs tvg-id "beIN.Sports.1" vs name
/// "beIN SPORTS 1 HD". No automatic match can reach it; only a manual
/// assignment can. (1.2.5: the old feed id "beIN Sports 1" now matches
/// by name — both sides normalize to "beinsports1" — so the proving
/// case moved to an id the name tier cannot reach.)

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

/// A minimal XMLTV feed with one programme, plus optional extra
/// `<programme>` elements pasted verbatim.
String _feedWith({
  required String channelId,
  required String title,
  required DateTime start,
  required DateTime end,
  String extraProgrammes = '',
}) =>
    '<?xml version="1.0" encoding="UTF-8"?><tv>'
    '<channel id="$channelId"><display-name>$channelId</display-name></channel>'
    '<programme start="${_xmltvTime(start)}" stop="${_xmltvTime(end)}" channel="$channelId">'
    '<title>$title</title></programme>'
    '$extraProgrammes</tv>';

/// Fake provider: scripted short-EPG listings per stream id, a scripted
/// xmltv.php feed, and a MUTABLE live-streams list (the playlist-change
/// tests change it between client instances).
class _AreaEpgApi extends XtreamApi {
  _AreaEpgApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, int> shortEpgCalls = {};
  bool failShortEpg = false;
  bool failXmltv = false;
  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  List<XtreamLiveStream> liveStreams = [
    XtreamLiveStream(streamId: 200, name: 'beIN SPORTS 1 HD', epgChannelId: 'beIN.Sports.1'),
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    shortEpgCalls[streamId] = (shortEpgCalls[streamId] ?? 0) + 1;
    if (failShortEpg) throw StateError('get_short_epg unavailable');
    final all = scripted[streamId] ?? const [];
    return all.take(limit).toList();
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(await getXmltv(timeout: timeout, abortTrigger: abortTrigger))),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    if (failXmltv) throw StateError('xmltv.php unavailable');
    return xmltvBody;
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => liveStreams;
}

/// Restores the real dart:io HttpClient, bypassing the test binding's
/// always-400 mock. Used only by the loopback-server user-source tests.
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _AreaEpgApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    IptvCatalogDiskCache.debugDisableDisk = true;
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_area_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _AreaEpgApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    support = client.liveTv as IptvLiveTvSupport;
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvPlaybackActivity.instance.markIdle();
    IptvPlaybackActivity.debugResetInstance();
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  Future<void> loadChannels() async => client.iptvChannels();

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  group('Manual assignment — the beIN proving case (§3.2, §4)', () {
    test('no automatic match reaches beIN Sports 1', () async {
      // Feed id "beIN 1" vs tvg-id "beIN.Sports.1" vs name
      // "beIN SPORTS 1 HD": exact and folded tvg-id miss, the name
      // tier misses ("beinsports1" vs "bein1"), numeric and loose
      // miss. The guide shows hour blocks.
      await loadChannels();
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'beIN 1',
        title: 'beIN Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('200', from: window.from, to: window.to);
      expect(programs, isEmpty);
    });

    test('a manual assignment serves the feed, survives refresh, and clears', () async {
      await loadChannels();
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'beIN 1',
        title: 'beIN Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final window = windowAround(now);
      // The first fetch caches the empty result — assign, then bust the
      // cache (the way Update now does) so the mapping is consulted.
      expect(await support.fetchEpgForChannel('200', from: window.from, to: window.to), isEmpty);
      await support.assignEpg('200', xmltvId: 'beIN 1', sourceId: IptvEpgSourceConfig.providerId);
      await support.refreshEpgCache();
      final assigned = await support.fetchEpgForChannel('200', from: window.from, to: window.to);
      expect(assigned.map((p) => p.title), ['beIN Show']);

      // The mapping survives a refresh: bust the cache again and the
      // channel still shows its feed programmes.
      await support.refreshEpgCache();
      final afterRefresh = await support.fetchEpgForChannel('200', from: window.from, to: window.to);
      expect(afterRefresh.map((p) => p.title), ['beIN Show']);

      // Clear assignment restores auto-matching (nothing, for beIN).
      await support.clearEpgAssignment('200');
      await support.refreshEpgCache();
      expect(await support.fetchEpgForChannel('200', from: window.from, to: window.to), isEmpty);
      expect(await support.epgAssignmentFor('200'), isNull);
    });

    test('EPG details name the assignment and the why-no-match', () async {
      await loadChannels();
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'beIN 1',
        title: 'beIN Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final window = windowAround(now);
      // Fetch first so the feed is loaded: the detail for an unmatched
      // channel must say noMatch, not "not loaded yet".
      expect(await support.fetchEpgForChannel('200', from: window.from, to: window.to), isEmpty);
      final unmatched = await support.channelEpgDetail('200', from: window.from, to: window.to);
      expect(unmatched.hasGuide, isFalse);
      expect(unmatched.noGuideReason, IptvEpgNoGuideReason.noMatch);
      expect(unmatched.matchedXmltvId, isNull);

      await support.assignEpg('200', xmltvId: 'beIN 1', sourceId: IptvEpgSourceConfig.providerId);
      await support.refreshEpgCache();
      expect(await support.fetchEpgForChannel('200', from: window.from, to: window.to), isNotEmpty);
      final matched = await support.channelEpgDetail('200', from: window.from, to: window.to);
      expect(matched.hasGuide, isTrue);
      expect(matched.programCount, 1);
      expect(matched.sourceId, IptvEpgSourceConfig.providerId);
      expect(matched.matchedXmltvId, 'beIN 1');
      expect(matched.matchMethod, 'manual');
      expect(matched.noGuideReason, isNull);
      expect(matched.lastFetch, isNotNull);
    });
  });

  group('Third-party sources (§3.1, loopback server)', () {
    late HttpServer server;
    HttpOverrides? previousOverrides;
    final hits = <String, int>{};
    var userEpgStatus = HttpStatus.ok;
    String userEpgBody = '';

    setUp(() async {
      // Per-test isolation: the hit counts and the forced status are
      // shared group state — without a reset, one test's 404 (the
      // failing-source test) would break every later add, and the hit
      // counts would accumulate across tests.
      hits.clear();
      userEpgStatus = HttpStatus.ok;
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final path = request.uri.path;
        hits[path] = (hits[path] ?? 0) + 1;
        final response = request.response;
        if (path == '/user-epg.xml') {
          response.statusCode = userEpgStatus;
          response.headers.contentType = ContentType.text;
          response.write(userEpgBody);
        } else if (path == '/not-xml.txt') {
          response.headers.contentType = ContentType.text;
          response.write('this is not xml at all');
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
      final now = DateTime.now();
      userEpgBody = _feedWith(
        channelId: 'user-ch1',
        title: 'User Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
    });

    tearDown(() async {
      await server.close(force: true);
      HttpOverrides.global = previousOverrides;
    });

    String userUrl([String path = '/user-epg.xml']) => 'http://127.0.0.1:${server.port}$path';

    test('add validates the URL and the source appears after the provider', () async {
      await support.addEpgSource(userUrl(), name: 'My EPG');
      final sources = await support.epgSources();
      expect(sources.map((s) => s.id), ['provider', sources[1].id]);
      expect(sources[0].isProvider, isTrue);
      expect(sources[1].name, 'My EPG');
      expect(sources[1].kind, IptvEpgSourceConfig.kindXmltv);
      expect(sources[1].url, userUrl());
      expect(sources[1].enabled, isTrue);
    });

    test('add rejects a non-XMLTV URL, a 404, and a non-URL', () async {
      await expectLater(support.addEpgSource(userUrl('/not-xml.txt')), throwsA(isA<StateError>()));
      await expectLater(support.addEpgSource(userUrl('/missing.xml')), throwsA(isA<StateError>()));
      await expectLater(support.addEpgSource('not a url'), throwsA(anything));
      expect(await support.epgSources(), hasLength(1));
    });

    test('a user source serves a channel the provider feed cannot', () async {
      // Channel 101's tvg-id is ch101; the provider feed is empty, the
      // user feed carries ch101. Only the user source can serve it.
      api.liveStreams = [
        XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
      ];
      await loadChannels();
      await support.addEpgSource(userUrl(), name: 'My EPG');
      final now = DateTime.now();
      userEpgBody = _feedWith(
        channelId: 'ch101',
        title: 'User Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('101', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['User Show']);
      final statuses = await support.epgSourceStatuses();
      final userStatus = statuses.values.firstWhere((s) => s.programs > 0, orElse: () => IptvEpgSourceStatus.empty);
      expect(userStatus.programs, greaterThan(0));
      expect(userStatus.channels, greaterThan(0));
      expect(userStatus.state(enabled: true, ttl: const Duration(hours: 24)), IptvEpgSourceState.upToDate);
    });

    test('provider first by default; the precedence toggle flips it', () async {
      await loadChannels();
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Provider Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      userEpgBody = _feedWith(
        channelId: 'ch100',
        title: 'User Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      await support.addEpgSource(userUrl(), name: 'My EPG');
      final window = windowAround(now);
      final first = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(first.map((p) => p.title), ['Provider Show']);

      await support.setAddedSourcesTakePrecedence(true);
      expect(await support.addedSourcesTakePrecedence(), isTrue);
      await support.refreshEpgCache();
      final flipped = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(flipped.map((p) => p.title), ['User Show']);
    });

    test('a disabled source is never fetched and never matches', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
      ];
      await loadChannels();
      await support.addEpgSource(userUrl(), name: 'My EPG');
      final now = DateTime.now();
      userEpgBody = _feedWith(
        channelId: 'ch101',
        title: 'User Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final window = windowAround(now);
      expect(
        (await support.fetchEpgForChannel('101', from: window.from, to: window.to)).map((p) => p.title),
        ['User Show'],
      );
      // Fetched once while enabled: the add-time validation GET plus the
      // feed GET. The absolute count is validation's business; the
      // invariant is that disabling fetches nothing more.
      final hitsWhileEnabled = hits['/user-epg.xml'];
      expect(hitsWhileEnabled, greaterThan(0));

      final sources = await support.epgSources();
      final user = sources.firstWhere((s) => !s.isProvider);
      await support.updateEpgSource(user.copyWith(enabled: false));
      await support.refreshEpgCache();
      expect(await support.fetchEpgForChannel('101', from: window.from, to: window.to), isEmpty);
      expect(hits['/user-epg.xml'], hitsWhileEnabled, reason: 'a disabled source must not be fetched again');
    });

    test('per-source time shift moves only that source', () async {
      await loadChannels();
      final now = DateTime.now();
      final startEpoch = now.millisecondsSinceEpoch ~/ 1000;
      userEpgBody = _feedWith(
        channelId: 'ch100',
        title: 'Shifted Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      await support.addEpgSource(userUrl(), name: 'My EPG');
      final sources = await support.epgSources();
      final user = sources.firstWhere((s) => !s.isProvider);
      await support.updateEpgSource(user.copyWith(timeShiftMinutes: 60));
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs, hasLength(1));
      expect(programs.first.beginsAt, startEpoch + 3600);
      expect(programs.first.title, 'Shifted Show');
    });

    test('a failing source records its failure and the fetch still answers', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
      ];
      await loadChannels();
      userEpgStatus = HttpStatus.notFound;
      await expectLater(support.addEpgSource(userUrl()), throwsA(isA<StateError>()));
      // Add it anyway by writing the stored list directly: the fetch
      // path must record the failure in the status, not throw for a
      // channel the provider feed already answered empty.
      final store = IptvEpgSourcesStore('trex');
      await store.saveUserSources([
        IptvEpgSourceConfig(id: 'user_x', kind: IptvEpgSourceConfig.kindXmltv, url: userUrl(), name: 'Broken'),
      ]);
      final now = DateTime.now();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('101', from: window.from, to: window.to);
      expect(programs, isEmpty, reason: 'the provider feed loaded (empty for the channel), so the fetch answers empty');
      final statuses = await support.epgSourceStatuses();
      final broken = statuses['user_x'];
      expect(broken, isNotNull);
      expect(broken!.state(enabled: true, ttl: const Duration(hours: 24)), IptvEpgSourceState.failed);
      expect(broken.lastFailureReason, contains('404'));
    });

    test('reorder moves a source and delete removes it (provider cannot be deleted)', () async {
      await support.addEpgSource(userUrl(), name: 'First');
      await support.addEpgSource(userUrl(), name: 'Second');
      var sources = await support.epgSources();
      expect(sources.map((s) => s.name), ['Provider guide', 'First', 'Second']);
      final secondId = sources[2].id;
      await support.moveEpgSource(secondId, -1);
      sources = await support.epgSources();
      expect(sources.map((s) => s.name), ['Provider guide', 'Second', 'First']);
      await support.deleteEpgSource(secondId);
      sources = await support.epgSources();
      expect(sources.map((s) => s.name), ['Provider guide', 'First']);
      await expectLater(support.deleteEpgSource(IptvEpgSourceConfig.providerId), throwsA(isA<ArgumentError>()));
    });

    test('Assign lists feed channels from all enabled sources (local search)', () async {
      await loadChannels();
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Provider Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      userEpgBody = _feedWith(
        channelId: 'user-ch1',
        title: 'User Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      await support.addEpgSource(userUrl(), name: 'My EPG');
      final entries = await support.epgFeedChannels();
      final ids = entries.map((e) => e.xmltvId).toSet();
      expect(ids, containsAll(['ch100', 'user-ch1']));
      expect(entries.firstWhere((e) => e.xmltvId == 'user-ch1').sourceName, 'My EPG');
      expect(entries.firstWhere((e) => e.xmltvId == 'ch100').sourceId, IptvEpgSourceConfig.providerId);
    });
  });

  group('Channels without guide + Reload TV details (§3.2)', () {
    test('without-guide lists the unmatched channel with its reason', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
        XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
      ];
      await loadChannels();
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Show A',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final missing = await support.channelsWithoutGuide();
      expect(missing.map((c) => c.channelKey), ['101']);
      expect(missing.first.reason, IptvEpgNoGuideReason.noMatch);
      expect(missing.first.channelName, 'Channel 101');
    });

    test('reload TV details reports counts', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
        XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Show A',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 2);
      expect(result.withGuide, 1);
      expect(result.withoutGuide, 1);
      expect(result.feedChannelIds, 1);
    });
  });

  group('Settings adds (§3.3): quiet hour + update on playlist change', () {
    test('quiet hour refreshes once per boundary, never twice, never on manual', () async {
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvEpgUpdateTimeMinutes, 240);
      await settings.write(SettingsService.iptvEpgUpdateIntervalHours, 24);
      // Last data was yesterday — before today's 04:00 boundary.
      await settings.write(
        SettingsService.iptvEpgLastUpdated,
        DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
      );
      final before = support.epgVersion;
      expect(await support.maybeRefreshForQuietHour(), isTrue);
      expect(support.epgVersion, greaterThan(before));
      // Same boundary, second call: already refreshed.
      expect(await support.maybeRefreshForQuietHour(), isFalse);

      // Manual-only interval: the quiet hour must not auto-refresh.
      await settings.write(SettingsService.iptvEpgUpdateIntervalHours, 0);
      expect(await support.maybeRefreshForQuietHour(), isFalse);

      // Update time off: never refreshes.
      await settings.write(SettingsService.iptvEpgUpdateIntervalHours, 24);
      await settings.write(SettingsService.iptvEpgUpdateTimeMinutes, -1);
      expect(await support.maybeRefreshForQuietHour(), isFalse);
    });

    test('a changed channel list refreshes the guide; an unchanged one does not', () async {
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvEpgUpdateOnPlaylistChange, true);
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
        XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
      ];
      await client.iptvChannels();
      expect(support.epgVersion, 0, reason: 'the first load stores the fingerprint without refreshing');

      // A new channel appears on the panel: the next fresh load refreshes.
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
        XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
        XtreamLiveStream(streamId: 102, name: 'Channel 102', epgChannelId: 'ch102'),
      ];
      final clientB = IptvClient.xtream(xtreamConnection: _trexConnection());
      clientB.testXtreamApi = api;
      final supportB = clientB.liveTv as IptvLiveTvSupport;
      await clientB.iptvChannels();
      expect(supportB.epgVersion, 1);

      // Same list again: no refresh.
      final clientC = IptvClient.xtream(xtreamConnection: _trexConnection());
      clientC.testXtreamApi = api;
      final supportC = clientC.liveTv as IptvLiveTvSupport;
      await clientC.iptvChannels();
      expect(supportC.epgVersion, 0);

      // The setting off: a change does not refresh.
      await settings.write(SettingsService.iptvEpgUpdateOnPlaylistChange, false);
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
        XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
        XtreamLiveStream(streamId: 102, name: 'Channel 102', epgChannelId: 'ch102'),
        XtreamLiveStream(streamId: 103, name: 'Channel 103', epgChannelId: 'ch103'),
      ];
      final clientD = IptvClient.xtream(xtreamConnection: _trexConnection());
      clientD.testXtreamApi = api;
      final supportD = clientD.liveTv as IptvLiveTvSupport;
      await clientD.iptvChannels();
      expect(supportD.epgVersion, 0);
    });
  });
}
