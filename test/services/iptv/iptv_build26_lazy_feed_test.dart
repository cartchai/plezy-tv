// PROBE 26-P2 (R3 — the guide re-download fix). FAILING-FIRST on base.
//
// The gap: `_fetchXtreamEpg` starts the shared `xmltv.php` feed download
// unconditionally, in the background, on EVERY stale channel fetch — even
// when per-channel `get_short_epg` already answered the row. The feed is
// then downloaded (~150 MB at Trex scale) and whole-document parsed
// (`compute(parseXmltv, body)`) for nobody. The correct rule (R3): the
// feed is fetched lazily — only when short-EPG misses/empty for a channel,
// or when the feed itself is the only source — and never on a browse/bind
// when a fresh guide already answers.
//
// This probe seeds a STALE persisted feed file (25 h old, past the 24 h
// default interval) and scripts short-EPG to answer for the channel.
// On base the stale feed triggers a background refresh download:
// `xmltvCalls` becomes 1 and this test FAILS. After the fix it stays 0.
//
// NOTE: the existing test `get_short_epg serves the channel; the xmltv.php
// feed still loads in the background` (iptv_epg_cache_test.dart) PINS the
// wasteful behaviour as expected — the fix must REPLACE that expectation
// (short-EPG serves the row; the feed loads only when short-EPG misses),
// not delete the coverage silently.
//
// No live panel use: fake Xtream API + temp dir only. Zero panel requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

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
}) =>
    XtreamEpgProgram(
      id: id,
      title: title,
      description: '',
      startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
      stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
      channelId: 'provider-ch',
    );

/// Fake provider: scripted short-EPG + a counted `xmltv.php` feed.
class _LazyFeedFakeApi extends XtreamApi {
  _LazyFeedFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, int> calls = {};
  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  /// 26.8: when true, getShortEpg never answers unless its abort trigger
  /// fires — the first-paint timeout must abort the underlying request.
  bool hangShortEpg = false;
  var shortEpgAborted = false;

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId,
      {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    calls[streamId] = (calls[streamId] ?? 0) + 1;
    if (hangShortEpg) {
      final trigger = abortTrigger;
      if (trigger != null) {
        await trigger.timeout(const Duration(seconds: 10));
        shortEpgAborted = true;
      } else {
        await Future<void>.delayed(const Duration(seconds: 30));
      }
      return const [];
    }
    return scripted[streamId] ?? const [];
  }

  /// Build #26: the fake's feed is a small canned String, so the stream
  /// is built on top of [getXmltv] — the production path streams, the fake
  /// does not need to.
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
    return xmltvBody;
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
        XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
        XtreamLiveStream(streamId: 200, name: 'Channel 200', epgChannelId: 'ch200'),
      ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _LazyFeedFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg26_lazy_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _LazyFeedFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
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

  Future<IptvLiveTvSupport> listedSupport() async {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    return client.liveTv as IptvLiveTvSupport;
  }

  /// Seed a persisted feed file for 'xtream:trex' with [mtime].
  Future<void> seedPersistedFeed({required String body, required DateTime mtime}) async {
    final cacheKey = 'xtream:trex';
    final safe = base64Url.encode(utf8.encode(cacheKey)).replaceAll('=', '');
    final connDir = base64Url.encode(utf8.encode('trex')).replaceAll('=', '');
    final file = File('${tempDir.path}/iptv_epg/$connDir/feed_$safe.xml');
    await file.parent.create(recursive: true);
    await file.writeAsString(body);
    await file.setLastModified(mtime);
  }

  /// A small feed doc with one programme for ch100 inside [now]'s window.
  String feedDoc(DateTime now) {
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final start = stamp(now.subtract(const Duration(hours: 1)));
    final stop = stamp(now.add(const Duration(hours: 1)));
    return '<?xml version="1.0" encoding="UTF-8"?><tv>'
        '<programme start="$start" stop="$stop" channel="ch100">'
        '<title>Feed Show</title></programme></tv>';
  }

  test('26-P2: short-EPG answers the row, so a stale feed is NOT re-downloaded', () async {
    final now = DateTime.now();
    // A small but real feed, 25 h old (past the 24 h default interval).
    await seedPersistedFeed(
      body: feedDoc(now),
      mtime: now.subtract(const Duration(hours: 25)),
    );
    // Short-EPG answers for the channel.
    api.scripted['100'] = [
      _epg(id: 'a', title: 'Morning News', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];

    final support = await listedSupport();
    final programs = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );
    expect(programs.map((p) => p.title), ['Morning News']);
    expect(api.calls['100'], 1);

    // The feed refresh (if any) starts in the background behind the fetch
    // — give it time to start, then assert it never did.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(
      api.xmltvCalls,
      0,
      reason: 'short-EPG answered the row; the stale feed must not be '
          're-downloaded (R3 lazy feed — fetch only when short-EPG misses)',
    );
  });

  test('26-P2b: short-EPG misses, so the stale feed IS re-downloaded (control)', () async {
    // Control: the same stale feed, but short-EPG has nothing — the feed
    // must still be fetched. Guards the P2 fix against "never fetch".
    final now = DateTime.now();
    await seedPersistedFeed(
      body: feedDoc(now),
      mtime: now.subtract(const Duration(hours: 25)),
    );
    // No scripted short-EPG: it answers empty.
    final support = await listedSupport();
    final programs = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );
    // The stale feed still serves its programme for the window.
    expect(programs.map((p) => p.title), ['Feed Show']);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(api.xmltvCalls, 1,
        reason: 'short-EPG missed, so the stale feed must be refreshed');
  });

  test('26.7: a picked day past the settings window still shows its programmes', () async {
    // The day picker offers today + 7 days, but the fetch window used to
    // be [now - pastDays, now + daysToLoad] (4 days) — days +4...+7 could
    // never show data. The fix widens the fetch window to the requested
    // day; the feed already holds the data, so no extra download.
    final now = DateTime.now();
    final day = now.add(const Duration(days: 6));
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final start = stamp(day);
    final mid = stamp(day.add(const Duration(hours: 1)));
    final end = stamp(day.add(const Duration(hours: 2)));
    await seedPersistedFeed(
      body: '<?xml version="1.0" encoding="UTF-8"?><tv>'
          '<programme start="$start" stop="$mid" channel="ch100"><title>Day Six Morning</title></programme>'
          '<programme start="$mid" stop="$end" channel="ch100"><title>Day Six Midday</title></programme></tv>',
      mtime: now,
    );
    // Short-EPG empty: the feed must serve the day.
    final support = await listedSupport();
    final programs = await support.fetchEpgForChannel(
      '100',
      from: day,
      to: day.add(const Duration(hours: 6)),
    );
    expect(programs.map((p) => p.title), ['Day Six Morning', 'Day Six Midday']);
    expect(api.xmltvCalls, 0, reason: 'the fresh persisted feed answers; no download');
  });

  test('26.8: the first-paint timeout aborts the short-EPG socket', () async {
    final now = DateTime.now();
    api.xmltvBody = feedDoc(now);
    api.hangShortEpg = true;
    IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(milliseconds: 100);
    try {
      final support = await listedSupport();
      final stopwatch = Stopwatch()..start();
      final programs = await support.fetchEpgForChannel(
        '100',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 6)),
      );
      stopwatch.stop();
      // The feed serves the channel once short-EPG gives up fast.
      expect(programs.map((p) => p.title), ['Feed Show']);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
      // The hanging short-EPG call must have been aborted, not left to
      // run its 60 s timeout unobserved — poll briefly for the fake to
      // record the abort.
      var aborted = false;
      for (var i = 0; i < 200 && !aborted; i++) {
        aborted = api.shortEpgAborted;
        if (!aborted) await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(aborted, isTrue, reason: 'the first-paint timeout must abort the underlying request');
    } finally {
      IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(seconds: 15);
    }
  });

  test('26.6: per-channel files older than the update interval are pruned', () async {
    final now = DateTime.now();
    api.scripted['100'] = [
      _epg(id: 'a', title: 'Morning News', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];
    api.scripted['200'] = [
      _epg(id: 'c', title: 'Sports', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];
    final support = await listedSupport();
    fetch(String key) => support.fetchEpgForChannel(
          key,
          from: now.subtract(const Duration(hours: 1)),
          to: now.add(const Duration(hours: 6)),
        );
    await fetch('100');
    await fetch('200');
    File channelFile(String key) {
      final safe = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
      final connDir = base64Url.encode(utf8.encode('trex')).replaceAll('=', '');
      return File('${tempDir.path}/iptv_epg/$connDir/$safe.json');
    }

    final file200 = channelFile('200');
    // The per-channel write is fire-and-forget: wait until its content
    // has actually landed before aging the file, or the write can reset
    // the mtime after the aging.
    var written = false;
    for (var i = 0; i < 200 && !written; i++) {
      written = file200.existsSync() && (await file200.readAsString()).contains('Sports');
      if (!written) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(written, isTrue);
    // Age channel 200's file past the 24 h default interval.
    await file200.setLastModified(now.subtract(const Duration(hours: 25)));
    // Force a refetch of 100 on a fresh instance (update-on-start): the
    // refetch writes 100's file and prunes stale ones.
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.iptvEpgUpdateOnStart, true);
    final fresh = await listedSupport();
    await fresh.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );
    // The prune is fire-and-forget — poll until 200's file is gone.
    var pruned = false;
    for (var i = 0; i < 200 && !pruned; i++) {
      pruned = !file200.existsSync();
      if (!pruned) await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(pruned, isTrue, reason: 'a per-channel file older than the interval must be pruned');
    expect(channelFile('100').existsSync(), isTrue, reason: 'the fresh file must survive the prune');
  });

  test('26.3: a fresh persisted feed is stream-parsed on cold start', () async {
    // ~38k programmes / ~6 MB: big enough to prove the persisted file is
    // streamed (not readAsString + isolate parse), small enough to stay
    // fast. The full 151 MB / 960k case is the P1 probe (parser) + the P3
    // measurement recorded in FORK §34.
    final now = DateTime.now();
    final doc = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    for (var c = 1; c < 200; c++) {
      for (var s = 0; s < 192; s++) {
        final start = DateTime.utc(2026, 1, 1).add(Duration(minutes: 30 * s));
        final stop = start.add(const Duration(minutes: 30));
        doc.write('<programme start="${stamp(start)}" stop="${stamp(stop)}" channel="ch$c">'
            '<title>Filler $s on ch$c</title></programme>');
      }
    }
    // ch100's programmes land inside the fetch window.
    for (var i = 0; i < 4; i++) {
      final start = now.subtract(const Duration(hours: 1)).add(Duration(hours: i + 1));
      final stop = start.add(const Duration(minutes: 30));
      doc.write('<programme start="${stamp(start)}" stop="${stamp(stop)}" channel="ch100">'
          '<title>In Window ${i + 1}</title></programme>');
    }
    doc.write('</tv>');
    await seedPersistedFeed(body: doc.toString(), mtime: now);
    // Short-EPG empty: the persisted feed must serve the channel.
    final support = await listedSupport();
    final programs = await support.fetchEpgForChannel(
      '100',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );
    expect(programs.map((p) => p.title), ['In Window 1', 'In Window 2', 'In Window 3', 'In Window 4']);
    expect(api.xmltvCalls, 0, reason: 'the fresh persisted feed must be parsed, not re-downloaded');
  });
}
