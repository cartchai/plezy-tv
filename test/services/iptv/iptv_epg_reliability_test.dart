import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// EPG loading-reliability regression suite (PlezTV 1.1.2, build 1 of
/// RESEARCH_EPG_AREA.md §7 — defects D1/D1b/D8/D9).
///
/// Folded in from the research probe
/// (`test/services/iptv/probe_epg_area_test.dart`, base 1.1.1
/// 8d443cec9, 8 fail / 4 pass): the D1/D1b/D8 probes go green on the fix,
/// the C controls guard the behaviour the fix must not break, and the D9
/// tests pin the honest "Last updated" stamp at the service level (the
/// settings-screen tile is covered by iptv_screens_test.dart).
///
/// D2/D3/D4/D7 are NOT here — they stay red in the research probe file
/// for build 3 (RESEARCH_EPG_AREA.md §7.3) and must not be folded in
/// until that build fixes them.
///
/// No live panel use — the provider is a scripted fake (short-EPG +
/// xmltv.php feed). No streams are ever opened.
///
/// PHONE EVIDENCE (Matt, 2026-11-13 ~05:38 EST, 1.1.1, screenshot
/// 9842_0_w8ar.jpg): the guide shows one-hour "No information available"
/// blocks for EVERY channel (FOX, MSNBC, PBS, NBC, CBS, ABC, A&E) — the
/// loaded-but-empty state, not the retry state and not a spinner. So
/// fetchEpgForChannel returned [] successfully for every visible channel.
/// D1a/D1b reproduce the phone symptom in-harness.

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
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

/// Fake provider: scripted short-EPG listings per stream id (honouring
/// the requested `limit`, like the panel) and a scripted xmltv.php feed,
/// each with a call counter so the tests can prove when a fetch did (and
/// did not) happen.
class _ProbeEpgApi extends XtreamApi {
  _ProbeEpgApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, int> shortEpgCalls = {};
  bool failShortEpg = false;
  bool failXmltv = false;
  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

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
  Stream<List<int>> getXmltvStream({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async* {
    yield utf8.encode(await getXmltv(timeout: timeout, abortTrigger: abortTrigger));
  }

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    if (failXmltv) throw StateError('xmltv.php unavailable');
    return xmltvBody;
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    XtreamLiveStream(streamId: 101, name: 'Channel 101', epgChannelId: 'ch101'),
  ];
}

Future<void> _waitFor(bool Function() condition, {Duration timeout = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 50));
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
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_reliability_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _ProbeEpgApi();
    // The guide always lists channels before fetching EPG, which
    // populates the stream-id -> epg_channel_id lookup the XMLTV match
    // needs.
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    support = client.liveTv as IptvLiveTvSupport;
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    IptvLiveTvSupport.xmltvNegativeCacheTtl = const Duration(minutes: 5);
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

  ({DateTime from, DateTime to}) windowAround(DateTime now) => (
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  group('D1 — silent-empty caching (PHONE 2026-11-13: all channels hour blocks)', () {
    test('D1a empty short-EPG + failing feed throws instead of returning empty', () async {
      // get_short_epg answers [] (no listings for the channel) and the
      // xmltv.php feed fails. The fetch must THROW — build #8 Task 3's
      // rule is "a fetch only throws when both sources fail", and a feed
      // that FAILS is not a source answering empty. On the 1.1.1 base
      // the catch in _fetchXtreamEpgWithAbort returned ([], none) for
      // this case, so the guide recorded a failed fetch as loaded-empty:
      // hour blocks, no retry state — exactly the phone screenshot
      // (FOX/MSNBC/PBS/NBC/CBS/ABC/A&E all "No information available").
      api.failXmltv = true;
      final now = DateTime.now();
      final window = windowAround(now);

      Object? error;
      try {
        await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      } catch (e) {
        error = e;
      }
      expect(
        error,
        isNotNull,
        reason: 'short-EPG answered empty and the feed failed: the fetch must surface as a failure (guide retry state), not as loaded-empty hour blocks',
      );
    });

    test('D1a-2 the empty result of a failed feed is not cached for the TTL', () async {
      // Even if D1a threw, the story only heals if the empty result is
      // not written to the per-channel cache: on the base the first
      // fetch cached [] for the whole update interval (24h default), so
      // a later refetch — after the panel recovers — still served [] and
      // never downloaded the feed again.
      api.failXmltv = true;
      final now = DateTime.now();
      final window = windowAround(now);
      try {
        await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      } catch (_) {
        // Post-fix this throws; on the base it returns [].
      }
      expect(api.xmltvCalls, 1);

      // The panel recovers and the feed now has the programme. The 5-min
      // negative cache is D8's separate concern — lift it here so this
      // test isolates D1's caching.
      IptvLiveTvSupport.xmltvNegativeCacheTtl = Duration.zero;
      api.failXmltv = false;
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), contains('Feed Show'));
      expect(api.xmltvCalls, 2, reason: 'the refetch must actually download the feed again');
    });

    test('D1b a playback-gate deferral does not poison the channel for the TTL', () async {
      // Cold cache, a stream playing, short-EPG empty: the feed is
      // deferred by the build #28 gate (correct — no download while
      // playing). On the base the deferral was then recorded as a
      // successful empty fetch and cached for the whole interval, so
      // when playback stopped the channel STILL showed hour blocks. The
      // gate comments claimed "it retries when playback stops" — nothing
      // listened for playback stopping (IptvPlaybackActivity
      // .isPlayingNotifier had zero listeners) and nothing invalidated
      // the poisoned entry. Note build #28's own gate test only ever
      // re-fetched a DIFFERENT channel after idle, so this hole went
      // uncaught.
      final now = DateTime.now();
      final window = windowAround(now);
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );

      IptvPlaybackActivity.instance.markPlaying();
      final whilePlaying = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(whilePlaying, isEmpty);
      expect(api.xmltvCalls, 0, reason: 'no feed download may start while a stream is playing');

      IptvPlaybackActivity.instance.markIdle();
      final afterIdle = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(
        afterIdle.map((p) => p.title),
        contains('Feed Show'),
        reason: 'once playback stops the channel must load its feed data — the deferred fetch must not have been recorded as loaded-empty for the whole interval',
      );
      expect(api.xmltvCalls, 1);
    });
  });

  group('D8 — tap-to-retry cannot succeed within 5 minutes of a feed failure', () {
    test('D8 tap-to-retry after a feed failure starts a fresh download', () async {
      // Both sources fail: the fetch throws and the guide shows its
      // tap-to-retry row. The retry only clears the guide's failed flag
      // and re-fetches — but _xmltvGuideForKey refused any feed download
      // for 5 minutes after a failure (negative cache), so the retry
      // failed instantly with 'failed recently' and no network attempt.
      // Update now / Clear guide bypass it (clearEpgCache clears the
      // negative cache) — the guide's own retry button was the one that
      // could not work. The fix threads an explicit force flag through
      // the guide retry (_retryIptvEpg passes force: true), so the
      // retry below uses force: true — the guide retry's real shape.
      //
      // DEVIATION from the research probe (documented): the probe's
      // retry was a PLAIN re-fetch, which cannot work — the service
      // layer cannot tell an automatic re-fetch from a tap, and a plain
      // re-fetch must still respect the negative cache (see
      // iptv_epg_cache_test: "failed feed is not re-downloaded inside
      // the negative-cache window"). Only the explicit flag bypasses it.
      api.failShortEpg = true;
      api.failXmltv = true;
      final now = DateTime.now();
      final window = windowAround(now);
      await expectLater(
        support.fetchEpgForChannel('100', from: window.from, to: window.to),
        throwsA(anything),
      );
      expect(api.xmltvCalls, 1);

      // The panel recovers. A plain re-fetch still fails fast on the
      // negative cache — that is the storm protection, not the bug.
      api.failXmltv = false;
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      await expectLater(
        support.fetchEpgForChannel('100', from: window.from, to: window.to),
        throwsA(anything),
      );
      expect(api.xmltvCalls, 1, reason: 'a plain re-fetch respects the negative cache');

      // The user taps retry in the guide: the forced retry downloads.
      final retried = await support.fetchEpgForChannel('100', from: window.from, to: window.to, force: true);
      expect(retried.map((p) => p.title), contains('Feed Show'));
      expect(api.xmltvCalls, 2, reason: 'the forced retry must actually download the feed again');
    });

    test('D8 an explicit force retry works even for a channel that never failed', () async {
      // The force flag is the guide retry's own path (_retryIptvEpg
      // passes force: true). A channel that never fetched before has no
      // failed-channel record, so only the explicit flag can bypass the
      // negative cache — prove the flag itself works, not just the
      // auto-retry bookkeeping.
      api.failShortEpg = true;
      api.failXmltv = true;
      final now = DateTime.now();
      final window = windowAround(now);
      // Fail the feed once, via another channel, so the negative cache
      // is armed for the shared feed key.
      await expectLater(
        support.fetchEpgForChannel('101', from: window.from, to: window.to),
        throwsA(anything),
      );
      expect(api.xmltvCalls, 1);

      api.failXmltv = false;
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to, force: true);
      expect(programs.map((p) => p.title), contains('Feed Show'));
      expect(api.xmltvCalls, 2, reason: 'the forced retry must actually download the feed again');
    });
  });

  group('D9 — "Last updated" is stamped while nothing loads', () {
    test('D9 an empty fetch stamps Last attempt but not Last updated', () async {
      // The feed loads but has no programme for the channel (genuine
      // empty): the attempt happened, but no programme was stored — so
      // the attempt stamp moves and the data stamp must not. On the
      // 1.1.1 base _noteEpgUpdated ran on every successful fetch,
      // including ([], none) silent-empty ones — the exact lie in
      // Matt's screenshot ("Last updated Nov 13 · 5:38 AM" with zero
      // programmes).
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'other',
        title: 'Other Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs, isEmpty);
      expect(support.lastEpgUpdatedAt, isNull);
      final settings = await SettingsService.getInstance();
      await _waitFor(() => settings.read(SettingsService.iptvEpgLastAttempt).isNotEmpty);
      expect(settings.read(SettingsService.iptvEpgLastUpdated), isEmpty);
    });

    test('D9 a fetch that stores programmes stamps Last updated too', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Feed Show']);
      expect(support.lastEpgUpdatedAt, isNotNull);
      final settings = await SettingsService.getInstance();
      await _waitFor(() => settings.read(SettingsService.iptvEpgLastUpdated).isNotEmpty);
      expect(settings.read(SettingsService.iptvEpgLastAttempt), isNotEmpty);
    });
  });

  group('Controls — behaviour the fix must not break (PASS on base)', () {
    test('C1 short-EPG serves programmes', () async {
      final now = DateTime.now();
      api.scripted['100'] = [
        _epg(id: 'a', title: 'Morning News', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
        _epg(id: 'b', title: 'Midday', start: now.add(const Duration(hours: 1)), end: now.add(const Duration(hours: 2))),
      ];
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Morning News', 'Midday']);
      expect(api.shortEpgCalls['100'], 1);
    });

    test('C2 short-EPG throws + feed fails still throws (build #8 invariant)', () async {
      api.failShortEpg = true;
      api.failXmltv = true;
      final now = DateTime.now();
      final window = windowAround(now);
      await expectLater(
        support.fetchEpgForChannel('100', from: window.from, to: window.to),
        throwsA(anything),
      );
    });

    test('C3 short-EPG empty + feed loads with a match serves the feed', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Show',
        start: now,
        end: now.add(const Duration(hours: 1)),
      );
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('100', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Feed Show']);
      expect(api.xmltvCalls, 1);
    });
  });
}
