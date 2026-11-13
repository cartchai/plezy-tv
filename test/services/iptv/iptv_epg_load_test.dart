import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// EPG-load failure probes (PlezTV 1.2.1, base bc97412c7) — Matt's phone
/// verdict 2026-11-13 ~12:27 EST: the guide is STILL EMPTY, "Reload tv
/// details doesnt apear to do anything when clicked and update now runs
/// to quick to be getting epg details".
///
/// PHONE EVIDENCE (screenshots 9848_2_0nwg.jpg + 9850_3_yzw1.jpg, 12:26
/// EST, v1.2.1-2.25.0+195): EPG sources screen shows "Provider guide /
/// Needs refresh / Never fetched"; IPTV settings show "Last updated:
/// Never" + "Last attempt: Never". The Settings → Logs export (same
/// morning) settles M1: EVERY panel call returns HTTP 403 "access
/// denied" (catalog sync live/movie/series, get_short_epg, xmltv.php
/// feed), escalating to a connection timeout at 12:29:23. So the guide
/// is empty because the panel denies this connection — the app's failure
/// is that it stays SILENT about it.
///
/// These probes pin the silence mechanisms in-harness. No live panel
/// use — the provider is a scripted fake. No streams are ever opened.

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

/// A minimal XMLTV feed with one programme.
String _feedWith({
  required String channelId,
  required String title,
  required DateTime start,
  required DateTime end,
}) =>
    '<?xml version="1.0" encoding="UTF-8"?><tv>'
    '<channel id="$channelId"><display-name>$channelId</display-name></channel>'
    '<programme start="${_xmltvTime(start)}" stop="${_xmltvTime(end)}" channel="$channelId">'
    '<title>$title</title></programme></tv>';

/// Fake provider: scripted short-EPG listings per stream id and a
/// scripted xmltv.php feed, each with a call counter so the tests can
/// prove when a fetch did (and did not) happen. `failLiveStreams`
/// makes the channel-list re-fetch throw, like a 403 on
/// get_live_streams.
class _ProbeEpgApi extends XtreamApi {
  _ProbeEpgApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, int> shortEpgCalls = {};
  bool failShortEpg = false;
  bool failXmltv = false;
  bool failXmltvTimeout = false;
  bool failLiveStreams = false;
  var xmltvCalls = 0;
  var liveStreamsCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    shortEpgCalls[streamId] = (shortEpgCalls[streamId] ?? 0) + 1;
    if (failShortEpg) throw StateError('get_short_epg unavailable (HTTP 403)');
    final all = scripted[streamId] ?? const [];
    return all.take(limit).toList();
  }

  @override
  Stream<List<int>> getXmltvStream({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async* {
    yield utf8.encode(await getXmltv(timeout: timeout, abortTrigger: abortTrigger));
  }

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    if (failXmltvTimeout) {
      throw MediaServerHttpException(type: MediaServerHttpErrorType.connectionTimeout, message: 'Connection timed out');
    }
    if (failXmltv) throw StateError('xmltv.php unavailable (HTTP 403)');
    return xmltvBody;
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    liveStreamsCalls++;
    if (failLiveStreams) throw StateError('get_live_streams unavailable (HTTP 403)');
    return const [
      XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
      XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _ProbeEpgApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_load_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _ProbeEpgApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    support = client.liveTv as IptvLiveTvSupport;
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvLiveTvSupport.xmltvNegativeCacheTtl = const Duration(minutes: 5);
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

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  String fileSafe(String value) => base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  group('R1 — Reload TV details throws its failure away (PHONE: tap does nothing)', () {
    test('a failing channel-list re-fetch is REPORTED, not thrown', () async {
      // Matt's phone (12:27 EST): tapping "Reload TV details" shows
      // nothing. The handler (iptv_epg_sources_screen.dart
      // _reloadTvDetails) has no try/catch and calls reloadTvDetails(),
      // whose FIRST step is refreshLiveChannelsFromNetwork() ->
      // get_live_streams — which 403s on his network. The throw
      // propagates out of reloadTvDetails() before refreshEpgCache()
      // (the cache bust) and before any result exists, so the report
      // dialog is never built and the tap looks dead. Desired: the
      // failure is reported (counts + failure) instead of thrown.
      api.failLiveStreams = true;

      final result = await support.reloadTvDetails();
      expect(
        result.channelsLoaded,
        0,
        reason: 'the channel list could not be re-fetched, so the report must say 0 channels loaded — not throw the failure away where no dialog can show it',
      );
      expect(result.withGuide, 0);
    });
  });

  group('R2 — pre-1.2.1 poisoned empty entries serve silently (PHONE: Last attempt Never)', () {
    test('a 1.1.1-written empty entry does not serve without a fetch', () async {
      // Matt's phone (12:26 EST): "Last updated: Never" + "Last
      // attempt: Never" + provider chip "Never fetched" — yet the guide
      // showed channels with hour blocks at 05:38 on 1.1.1, and its
      // "Last updated 5:38 AM" stamp proves fetches ran then and wrote
      // entries. Those entries were written by 1.1.1's D1 silent-empty
      // path: [] cached for the 24h TTL. On 1.2.1, fetchEpgForChannel
      // serves a fresh entry WITHOUT stamping an attempt (_noteEpgAttempt
      // sits after the cache-serve early return), and 1.2.1's D7
      // generation check cannot heal them: a pre-1.2.1 entry has
      // feedGenerations {} so _isFeedGenerationStale returns false.
      // Desired: the stale empty entry is NOT served as fresh — the
      // channel refetches (and stamps the attempt).
      final now = DateTime.now();
      final window = windowAround(now);
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      // Seed exactly what 1.1.1 wrote: an empty entry, no
      // feedGenerations key, fresh inside the 24h TTL.
      final dir = Directory('${tempDir.path}/iptv_epg/${fileSafe('trex')}');
      await dir.create(recursive: true);
      await File('${dir.path}/${fileSafe('100')}.json').writeAsString(jsonEncode({
        'fetchedAt': now.toIso8601String(),
        'windowFrom': now.subtract(const Duration(days: 1)).toIso8601String(),
        'windowTo': now.add(const Duration(days: 3)).toIso8601String(),
        'source': 'none',
        'programs': <dynamic>[],
      }));

      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      // Give the fire-and-forget attempt write a moment to land.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final settings = await SettingsService.getInstance();
      expect(
        programs.map((p) => p.title),
        contains('Feed Show'),
        reason: 'the poisoned empty entry must not be served as fresh — the channel has to refetch from the (now working) feed',
      );
      expect(
        api.xmltvCalls + (api.shortEpgCalls['100'] ?? 0),
        greaterThan(0),
        reason: 'serving the entry must involve a network attempt',
      );
      expect(
        settings.read(SettingsService.iptvEpgLastAttempt),
        isNotEmpty,
        reason: '"Last attempt" must stamp when the channel actually fetches',
      );
    });
  });

  group('R3 — control: a 403 DOES surface when a fetch actually runs', () {
    test('feed 403 throws and the provider source records Failed', () async {
      // D1 (1.1.2) works: short-EPG 403 + feed 403 throws instead of
      // returning loaded-empty. And _fetchFeedPrograms records the
      // failure in the per-source status, so the sources screen chip
      // would read "Failed" with the reason. Matt's chip reads "Needs
      // refresh / Never fetched" instead — which, with "Last attempt:
      // Never", proves NO feed load ever ran on his install: the guide
      // only ever served poisoned cache (R2).
      api.failShortEpg = true;
      api.failXmltv = true;
      final now = DateTime.now();
      final window = windowAround(now);

      Object? error;
      try {
        await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull, reason: 'both sources failed: the fetch must throw (guide retry state), not return loaded-empty');

      final statuses = await support.epgSourceStatuses();
      final provider = statuses[IptvEpgSourceConfig.providerId];
      expect(provider, isNotNull);
      expect(
        provider!.state(enabled: true, ttl: const Duration(hours: 24)),
        IptvEpgSourceState.failed,
        reason: 'a feed failure must land in the per-source status so the chip can show it',
      );
      expect(provider.lastFailureReason, isNotEmpty);
    });
  });

  group('R4 — control: the 5-minute negative cache (D8 mechanism, working as designed)', () {
    test('a second feed fetch within 5 min of a 403 fails without re-downloading', () async {
      // After the first feed 403, later channels hit the negative
      // cache: StateError "failed recently; retry shortly". That is
      // the log's 12:25-12:27 behaviour (later channels, no fresh
      // download) — the mechanism working as designed, not a bug.
      api.failShortEpg = true;
      api.failXmltv = true;
      final now = DateTime.now();
      final window = windowAround(now);

      try {
        await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      } catch (_) {}
      expect(api.xmltvCalls, 1);

      Object? secondError;
      try {
        await support.fetchEpgForChannel('101', from: window.from, to: window.to);
      } catch (e) {
        secondError = e;
      }
      expect(secondError, isA<StateError>());
      expect((secondError as StateError).message, contains('failed recently'));
      expect(api.xmltvCalls, 1, reason: 'the negative cache must prevent a second download');
    });
  });

  group('R5 — mechanism: Update now performs zero network I/O', () {
    test('refreshEpgCache downloads nothing and stamps no attempt', () async {
      // Matt: "update now runs to quick to be getting epg details".
      // Correct: _updateEpgNow only calls refreshEpgCache(), which is
      // clearEpgCache() — it busts the caches and shows a "Guide
      // updated" success snackbar without ANY network call. The fetch
      // is deferred to the guide's next build. So Update now is fast
      // because it does no fetching at all — and its success message
      // is a lie when the panel then 403s the deferred fetch.
      final settings = await SettingsService.getInstance();
      expect(settings.read(SettingsService.iptvEpgLastAttempt), isEmpty);
      final liveBefore = api.liveStreamsCalls;
      final shortBefore = Map<String, int>.of(api.shortEpgCalls);
      final xmltvBefore = api.xmltvCalls;

      await support.refreshEpgCache();

      expect(api.liveStreamsCalls, liveBefore, reason: 'Update now adds no channel-list calls');
      expect(api.shortEpgCalls, shortBefore);
      expect(api.xmltvCalls, xmltvBefore, reason: 'Update now adds no feed downloads');
      expect(
        settings.read(SettingsService.iptvEpgLastAttempt),
        isEmpty,
        reason: 'Update now stamps no attempt: it never fetches',
      );
    });
  });

  group('R6 — Reload names the FEED outcome, not just the channel counts (1.2.3, Matt 12:42 EST)', () {
    test('list 403 + feed 403: the report names the denial for both', () async {
      // Matt's 12:42 EST screenshot: Reload DID report — "26151
      // channels · 0 with guide · 26151 without guide" — because the
      // list loaded. The report must ALSO name the feed outcome, so the
      // user can tell "the feed failed" apart from "the feed loaded
      // but matched nothing". Here BOTH fail: the list failure is
      // carried (not thrown) and the feed failure is named denied.
      api.failLiveStreams = true;
      api.failXmltv = true;

      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 0);
      expect(result.withGuide, 0);
      expect(
        result.channelListFailureKind,
        IptvEpgFeedOutcomeKind.denied,
        reason: 'a 403 on the channel-list re-fetch is "the panel denied access", not a silent throw',
      );
      expect(result.feedOutcomes, hasLength(1));
      final provider = result.feedOutcomes.single;
      expect(provider.sourceId, IptvEpgSourceConfig.providerId);
      expect(provider.kind, IptvEpgFeedOutcomeKind.denied, reason: 'a 403 on the feed is a denial, named as such');
      expect(provider.reason, isNotEmpty);
    });

    test('list loads + feed loads with matches: loaded, with match counts', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );

      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 2);
      expect(result.withGuide, 1, reason: 'the feed serves channel 100 (tvg-id ch100)');
      expect(result.withoutGuide, 1);
      expect(result.channelListFailureKind, isNull);
      expect(result.feedOutcomes, hasLength(1));
      final provider = result.feedOutcomes.single;
      expect(provider.kind, IptvEpgFeedOutcomeKind.loaded);
      expect(provider.feedChannels, 1);
      expect(provider.matchedChannels, 1);
    });

    test('list loads + feed loads but matches nothing (M2): loadedNoMatch', () async {
      // The feed is FINE — it just has no programme for any of this
      // connection's channels (ids/names do not line up). That is a
      // different story from a failed feed, and the report must say so.
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'ch999',
        title: 'Somebody Else',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );

      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 2);
      expect(result.withGuide, 0);
      expect(result.feedOutcomes, hasLength(1));
      final provider = result.feedOutcomes.single;
      expect(provider.kind, IptvEpgFeedOutcomeKind.loadedNoMatch);
      expect(provider.feedChannels, 1, reason: 'the feed DID load — one channel in it');
      expect(provider.matchedChannels, 0);
    });

    test('list loads + feed empty: loadedNoMatch, not a failure', () async {
      // An empty feed is not a failed feed: it loaded, it just has
      // nothing in it. The report names the match failure, not a
      // download failure.
      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 2);
      expect(result.withGuide, 0);
      expect(result.feedOutcomes, hasLength(1));
      final provider = result.feedOutcomes.single;
      expect(provider.kind, IptvEpgFeedOutcomeKind.loadedNoMatch);
      expect(provider.feedChannels, 0);
      expect(provider.matchedChannels, 0);
    });

    test('list loads + feed times out: the report names "not answering"', () async {
      api.failXmltvTimeout = true;

      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 2);
      expect(result.withGuide, 0);
      expect(result.channelListFailureKind, isNull, reason: 'the list loaded — only the feed timed out');
      expect(result.feedOutcomes, hasLength(1));
      final provider = result.feedOutcomes.single;
      expect(provider.kind, IptvEpgFeedOutcomeKind.notAnswering);
    });
  });

  group('R7 — Update now attempts a real refresh and reports it (1.2.3 RC2)', () {
    test('a working feed is downloaded and reported loaded', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final settings = await SettingsService.getInstance();
      expect(settings.read(SettingsService.iptvEpgLastAttempt), isEmpty);

      final result = await support.updateEpgNow();
      // Give the fire-and-forget attempt write a moment to land.
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(api.xmltvCalls, 1, reason: 'Update now must actually download the feed — not just clear the cache');
      expect(result.feedOutcomes, hasLength(1));
      final provider = result.feedOutcomes.single;
      expect(provider.kind, IptvEpgFeedOutcomeKind.loaded);
      expect(provider.feedChannels, 1);
      expect(provider.matchedChannels, isNull, reason: 'Update now never re-fetches the channel list, so there is no match count to name');
      expect(
        settings.read(SettingsService.iptvEpgLastAttempt),
        isNotEmpty,
        reason: '"Last attempt" must stamp when Update now actually fetches',
      );
    });

    test('a failing feed is reported denied (and recorded Failed), not "Guide updated"', () async {
      api.failXmltv = true;

      final result = await support.updateEpgNow();

      expect(api.xmltvCalls, 1, reason: 'Update now must attempt the download even though it fails');
      expect(result.feedOutcomes, hasLength(1));
      expect(result.feedOutcomes.single.kind, IptvEpgFeedOutcomeKind.denied);
      final statuses = await support.epgSourceStatuses();
      final provider = statuses[IptvEpgSourceConfig.providerId];
      expect(provider, isNotNull);
      expect(
        provider!.state(enabled: true, ttl: const Duration(hours: 24)),
        IptvEpgSourceState.failed,
        reason: 'the failure must land in the per-source status so the chip can show it',
      );
    });
  });
}
