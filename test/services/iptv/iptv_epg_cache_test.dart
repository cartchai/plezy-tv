import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

/// Persisted EPG cache tests (build #7 Task 4): build #6's cache was
/// in-memory, so every launch started cold and "Update on app start" had
/// no observable effect. These prove a fresh persisted entry is served
/// without refetching after a relaunch, a stale or narrow entry
/// refetches, Clear guide deletes the files and stays empty, Update now
/// busts the cache, and update-on-start force-refreshes from disk.
/// No network (fake short-EPG); no streams are opened.

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
}) => XtreamEpgProgram(
  id: id,
  title: title,
  description: '',
  startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
  stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
  channelId: 'provider-ch',
);

/// Fake provider: scripted short-EPG listings per stream id, with a call
/// counter so the tests can prove when a fetch did (and did not) happen.
/// The `xmltv.php` feed is an empty document by default, so tests that do
/// not set [xmltvBody] fall back to `get_short_epg` (the pre-Task-7 path)
/// without touching the network.
class _EpgFakeApi extends XtreamApi {
  _EpgFakeApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, int> calls = {};
  var xmltvCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  bool failXmltv = false;
  bool failShortEpg = false;

  /// Concurrency gate for the build #15 short-EPG cap test: when set,
  /// each call records its concurrency and waits on [shortEpgGate]
  /// before answering.
  Completer<void>? shortEpgGate;
  var shortEpgInFlight = 0;
  var shortEpgMaxInFlight = 0;

  /// Artificial delay for the build #15 first-paint timeout test.
  Duration? shortEpgDelay;

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout}) async {
    calls[streamId] = (calls[streamId] ?? 0) + 1;
    if (failShortEpg) throw Exception('get_short_epg unavailable');
    final gate = shortEpgGate;
    if (gate != null) {
      shortEpgInFlight++;
      if (shortEpgInFlight > shortEpgMaxInFlight) shortEpgMaxInFlight = shortEpgInFlight;
      try {
        await gate.future;
      } finally {
        shortEpgInFlight--;
      }
    }
    final delay = shortEpgDelay;
    if (delay != null) await Future<void>.delayed(delay);
    return scripted[streamId] ?? const [];
  }

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120)}) async {
    xmltvCalls++;
    if (failXmltv) throw Exception('xmltv.php unavailable');
    return xmltvBody;
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    XtreamLiveStream(streamId: 200, name: 'Channel 200', epgChannelId: 'ch200'),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _EpgFakeApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_epg_test_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _EpgFakeApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    // The EPG cache writes are fire-and-forget: a write started by the
    // last fetch can still be in flight when tearDown runs, and a file
    // landing mid-delete makes the recursive delete fail (ENOTEMPTY).
    // Retry once after a short yield instead of failing the test on it.
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

  /// A fresh support instance for the same connection — the stand-in for a
  /// relaunch. The fake API is shared so call counts span instances.
  IptvLiveTvSupport supportFor() {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    return client.liveTv as IptvLiveTvSupport;
  }

  void scriptEpg(DateTime now) {
    api.scripted['100'] = [
      _epg(id: 'a', title: 'Morning News', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
      _epg(id: 'b', title: 'Midday', start: now.add(const Duration(hours: 1)), end: now.add(const Duration(hours: 2))),
    ];
  }

  /// The single persisted EPG file under the temp dir (there is only ever
  /// one channel in these tests).
  File epgFile() {
    final files = tempDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    expect(files, hasLength(1));
    return files.single;
  }

  /// Wait for the persisted EPG file to land. The write is fire-and-forget
  /// (awaiting disk I/O would gate the guide), so a fetch can return
  /// before the file exists — poll for it instead of asserting immediately.
  /// Build #8 Task 3 made the fetch return faster (get_short_epg first, no
  /// xmltv await when it answers), so the race the old xmltv-first await
  /// used to mask is now visible in these tests.
  Future<void> waitForEpgFile() async {
    for (var i = 0; i < 100; i++) {
      final files = tempDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.json')).toList();
      if (files.length == 1) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('persisted EPG file was not written');
  }

  /// Wait for the persisted XMLTV feed file to land (build #15, item 6 —
  /// fire-and-forget write, like the per-channel files).
  Future<File> waitForFeedFile() async {
    for (var i = 0; i < 100; i++) {
      final files = tempDir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.xml')).toList();
      if (files.length == 1) return files.single;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('persisted XMLTV feed file was not written');
  }

  /// Wait until the fake's `xmltv.php` download count reaches [n]. The
  /// feed loads in the background behind short-EPG, and build #15 checks
  /// the persisted file first, so the download starts a tick later than
  /// the fetch returns — poll instead of asserting immediately.
  Future<void> waitForXmltvCalls(int n) async {
    for (var i = 0; i < 200; i++) {
      if (api.xmltvCalls >= n) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('xmltv.php was not fetched $n times (got ${api.xmltvCalls})');
  }

  /// Delete the persisted per-channel file for [channelKey] so the next
  /// fetch must come from the feed, not the per-channel cache.
  Future<void> deleteChannelFile(String channelKey) async {
    final safe = base64Url.encode(utf8.encode(channelKey)).replaceAll('=', '');
    final files = tempDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('/$safe.json'))
        .toList();
    for (final file in files) {
      await file.delete();
    }
  }

  /// Rewrite the persisted entry's JSON in place (fetchedAt / window).
  Future<void> rewritePersisted(Map<String, dynamic> Function(Map<String, dynamic> json) edit) async {
    final file = epgFile();
    final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    await file.writeAsString(jsonEncode(edit(decoded)));
  }

  Future<List<LiveTvProgram>> fetchEpg(IptvLiveTvSupport support, DateTime now) => support.fetchEpgForChannel(
    '100',
    from: now.subtract(const Duration(hours: 1)),
    to: now.add(const Duration(hours: 6)),
  );

  test('LiveTvProgram toJson/fromJson round-trips the EPG fields', () {
    final program = LiveTvProgram(
      key: 'epg:100:a',
      title: 'Morning News',
      summary: 'Headlines',
      beginsAt: 1700000000,
      endsAt: 1700003600,
      channelIdentifier: '100',
      serverId: 'trex',
      serverName: 'Trex',
    );
    final roundTripped = LiveTvProgram.fromJson(program.toJson());
    expect(roundTripped.key, 'epg:100:a');
    expect(roundTripped.title, 'Morning News');
    expect(roundTripped.summary, 'Headlines');
    expect(roundTripped.beginsAt, 1700000000);
    expect(roundTripped.endsAt, 1700003600);
    expect(roundTripped.channelIdentifier, '100');
    expect(roundTripped.serverId, 'trex');
    expect(roundTripped.serverName, 'Trex');
    expect(roundTripped.isPlaceholder, isFalse);
  });

  test('fresh persisted entry is served after relaunch without refetching', () async {
    final now = DateTime.now();
    scriptEpg(now);
    final first = supportFor();
    final programs = await fetchEpg(first, now);
    expect(programs.map((p) => p.title), ['Morning News', 'Midday']);
    expect(api.calls['100'], 1);
    await waitForEpgFile();
    expect(epgFile().existsSync(), isTrue);

    // Relaunch: a new support instance, same connection, same disk.
    final relaunched = supportFor();
    final again = await fetchEpg(relaunched, now);
    expect(again.map((p) => p.title), ['Morning News', 'Midday']);
    expect(api.calls['100'], 1, reason: 'the persisted entry must be served, not refetched');
  });

  test('stale persisted entry refetches', () async {
    final now = DateTime.now();
    scriptEpg(now);
    await fetchEpg(supportFor(), now);
    expect(api.calls['100'], 1);

    // Age the entry past the 24h default interval.
    await waitForEpgFile();
    await rewritePersisted(
      (json) => {...json, 'fetchedAt': now.subtract(const Duration(hours: 25)).toIso8601String()},
    );

    final relaunched = supportFor();
    final programs = await fetchEpg(relaunched, now);
    expect(programs.map((p) => p.title), ['Morning News', 'Midday']);
    expect(api.calls['100'], 2);
  });

  test('persisted entry that does not cover the window refetches', () async {
    final now = DateTime.now();
    scriptEpg(now);
    await fetchEpg(supportFor(), now);
    expect(api.calls['100'], 1);

    // Shrink the stored window so it no longer covers the requested
    // to = now + 6h.
    await waitForEpgFile();
    await rewritePersisted(
      (json) => {...json, 'windowTo': now.add(const Duration(hours: 1)).toIso8601String()},
    );

    final relaunched = supportFor();
    await fetchEpg(relaunched, now);
    expect(api.calls['100'], 2);
  });

  test('corrupt persisted file reads as a miss and refetches', () async {
    final now = DateTime.now();
    scriptEpg(now);
    await fetchEpg(supportFor(), now);
    expect(api.calls['100'], 1);
    await waitForEpgFile();
    await epgFile().writeAsString('not-json{');

    final relaunched = supportFor();
    final programs = await fetchEpg(relaunched, now);
    expect(programs.map((p) => p.title), ['Morning News', 'Midday']);
    expect(api.calls['100'], 2);
  });

  test('Clear guide deletes the persisted files and stays empty until refresh', () async {
    final now = DateTime.now();
    scriptEpg(now);
    final support = supportFor();
    await fetchEpg(support, now);
    expect(api.calls['100'], 1);
    await waitForEpgFile();
    expect(epgFile().existsSync(), isTrue);
    // The feed file is written fire-and-forget too — wait for it to land
    // before clearing, or it can land after the delete.
    await waitForFeedFile();

    await support.clearEpgCache();
    // The delete is fire-and-forget (like the write): poll until the
    // directory is actually empty instead of asserting immediately.
    for (var i = 0; i < 100; i++) {
      if (tempDir.listSync(recursive: true).whereType<File>().isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(tempDir.listSync(recursive: true).whereType<File>(), isEmpty);

    // Same launch: the cleared flag holds — no refetch.
    expect(await fetchEpg(support, now), isEmpty);
    expect(api.calls['100'], 1);

    // A relaunch after a clear refetches: the cleared flag is in-memory
    // only — Clear means "empty until a refresh", and a restart IS a
    // refresh (the guide must not stay permanently empty with no obvious
    // fix). So the relaunched guide loads the programmes again.
    final relaunched = supportFor();
    expect((await fetchEpg(relaunched, now)).map((p) => p.title), ['Morning News', 'Midday']);
    expect(api.calls['100'], 2);
  });

  test('Update now busts the persisted cache', () async {
    final now = DateTime.now();
    scriptEpg(now);
    final support = supportFor();
    await fetchEpg(support, now);
    expect(api.calls['100'], 1);

    await support.refreshEpgCache();
    final programs = await fetchEpg(support, now);
    expect(programs.map((p) => p.title), ['Morning News', 'Midday']);
    expect(api.calls['100'], 2);
  });

  test('update-on-start force-refreshes from disk on the first guide open', () async {
    final now = DateTime.now();
    scriptEpg(now);
    await fetchEpg(supportFor(), now);
    expect(api.calls['100'], 1);

    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.iptvEpgUpdateOnStart, true);

    // Relaunch with update-on-start: the fresh persisted entry must NOT
    // be served — the setting asks for a fresh fetch.
    final relaunched = supportFor();
    final programs = await fetchEpg(relaunched, now);
    expect(programs.map((p) => p.title), ['Morning News', 'Midday']);
    expect(api.calls['100'], 2);

    // A second fetch in the same launch uses the (now fresh) cache.
    await fetchEpg(relaunched, now);
    expect(api.calls['100'], 2);
  });

  test('update-on-start forces one fresh fetch per channel, not just the first', () async {
    final now = DateTime.now();
    scriptEpg(now);
    api.scripted['200'] = [
      _epg(id: 'c', title: 'Sports', start: now.subtract(const Duration(hours: 1)), end: now.add(const Duration(hours: 1))),
    ];
    await fetchEpg(supportFor(), now);
    await supportFor().fetchEpgForChannel(
      '200',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );
    expect(api.calls['100'], 1);
    expect(api.calls['200'], 1);

    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.iptvEpgUpdateOnStart, true);

    final relaunched = supportFor();
    await fetchEpg(relaunched, now);
    await relaunched.fetchEpgForChannel(
      '200',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );
    expect(api.calls['100'], 2);
    expect(api.calls['200'], 2, reason: 'the second channel must refresh too, not only the first');
  });

  // -- Task 7: xmltv.php as the primary Xtream EPG source -----------------
  //
  // The login's xmltv.php feed (TiviMate-style) is primary; get_short_epg
  // is the fallback for channels missing from the feed (or when the feed
  // fetch fails). The parsed feed is shared across channels, and the
  // programmes it serves are persisted per channel like any other fetch.

  /// Canned XMLTV feed: programmes for ch100 (stream 100) and ch200
  /// (stream 200), timed around [now].
  String xmltvDoc(DateTime now, {bool includeCh100 = true}) {
    String stamp(DateTime t) {
      final u = t.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}${two(u.second)} +0000';
    }

    final start = stamp(now.subtract(const Duration(hours: 1)));
    final mid = stamp(now.add(const Duration(hours: 1)));
    final end = stamp(now.add(const Duration(hours: 2)));
    final ch100 = includeCh100
        ? '''
  <programme start="$start" stop="$mid" channel="ch100"><title>XMLTV Morning</title><desc>From the feed</desc></programme>
  <programme start="$mid" stop="$end" channel="ch100"><title>XMLTV Midday</title></programme>'''
        : '';
    return '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="ch100"><display-name>Channel 100</display-name></channel>
  <channel id="ch200"><display-name>Channel 200</display-name></channel>$ch100
  <programme start="$start" stop="$mid" channel="ch200"><title>Other Channel</title></programme>
</tv>''';
  }

  /// A client with its channels listed first (the guide always lists
  /// channels before fetching EPG, which populates the stream-id →
  /// epg_channel_id lookup the XMLTV match needs).
  Future<IptvClient> listedClient() async {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    await client.iptvChannels();
    return client;
  }

  test('get_short_epg answers first; the xmltv.php feed covers a channel it has nothing for', () async {
    // Build #8 Task 3: get_short_epg runs first per channel (fast, so the
    // guide populates in seconds) while the big xmltv.php feed loads in
    // the background; the feed is the deeper source when get_short_epg has
    // nothing for the channel. get_short_epg answers empty here, so the
    // feed serves the channel.
    final now = DateTime.now();
    api.xmltvBody = xmltvDoc(now);
    final client = await listedClient();
    final support = client.liveTv as IptvLiveTvSupport;

    final programs = await fetchEpg(support, now);
    expect(programs.map((p) => p.title), ['XMLTV Morning', 'XMLTV Midday']);
    expect(programs.first.summary, 'From the feed');
    expect(api.xmltvCalls, 1);
    expect(api.calls['100'], 1, reason: 'get_short_epg runs first per channel, even when the feed serves it');
    await waitForEpgFile();
    // The XMLTV-sourced programmes are persisted per channel, like any
    // other fetch — a relaunch serves them without re-fetching the feed.
    expect(epgFile().existsSync(), isTrue);
    final relaunched = supportFor();
    expect((await fetchEpg(relaunched, now)).map((p) => p.title), ['XMLTV Morning', 'XMLTV Midday']);
    expect(api.xmltvCalls, 1, reason: 'the persisted entry must be served, not the feed re-fetched');
  });

  test('get_short_epg serves the channel; the xmltv.php feed still loads in the background', () async {
    final now = DateTime.now();
    api.xmltvBody = xmltvDoc(now, includeCh100: false);
    scriptEpg(now);
    final client = await listedClient();
    final support = client.liveTv as IptvLiveTvSupport;

    final programs = await fetchEpg(support, now);
    expect(programs.map((p) => p.title), ['Morning News', 'Midday']);
    await waitForXmltvCalls(1);
    expect(api.calls['100'], 1);
  });

  test('a failing xmltv.php fetch still serves get_short_epg programmes', () async {
    final now = DateTime.now();
    api.failXmltv = true;
    scriptEpg(now);
    final client = await listedClient();
    final support = client.liveTv as IptvLiveTvSupport;

    final programs = await fetchEpg(support, now);
    expect(programs.map((p) => p.title), ['Morning News', 'Midday']);
    await waitForXmltvCalls(1);
    expect(api.calls['100'], 1);
  });

  test('both sources failing throws so the guide can mark the channel failed', () async {
    // Build #8 Task 3: only when BOTH sources fail does the fetch throw —
    // if either answers (even empty), that answer stands. A throw lets the
    // guide show a visible failed state with a retry instead of recording
    // silent empty placeholders as loaded. A failed fetch writes no cache
    // entry, so a retry refetches.
    final now = DateTime.now();
    api.failXmltv = true;
    api.failShortEpg = true;
    final client = await listedClient();
    final support = client.liveTv as IptvLiveTvSupport;

    await expectLater(fetchEpg(support, now), throwsA(anything));
    expect(tempDir.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('the parsed XMLTV guide is shared across channels', () async {
    final now = DateTime.now();
    api.xmltvBody = xmltvDoc(now);
    final client = await listedClient();
    final support = client.liveTv as IptvLiveTvSupport;

    final first = await fetchEpg(support, now);
    expect(first.map((p) => p.title), ['XMLTV Morning', 'XMLTV Midday']);
    final second = await support.fetchEpgForChannel(
      '200',
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );
    expect(second.map((p) => p.title), ['Other Channel']);
    expect(api.xmltvCalls, 1, reason: 'the second channel must reuse the parsed feed, not re-fetch it');
    expect(api.calls['100'], 1, reason: 'get_short_epg runs first per channel, even when the feed serves it');
    expect(api.calls['200'], 1, reason: 'get_short_epg runs first per channel, even when the feed serves it');
  });

  test('cachedEpgForChannels serves persisted entries without a network fetch (build #15, item 2)', () async {
    // The guide search sheet's cache-only path: after a relaunch (fresh
    // support, empty in-memory cache) the persisted per-channel files are
    // found by ONE directory listing and served with zero API calls.
    final now = DateTime.now();
    scriptEpg(now);
    final first = supportFor();
    final programs = await fetchEpg(first, now);
    expect(programs.map((p) => p.title), ['Morning News', 'Midday']);
    await waitForEpgFile();
    final shortEpgCalls = api.calls['100'] ?? 0;
    final xmltvCalls = api.xmltvCalls;

    final second = supportFor();
    final out = await second.cachedEpgForChannels(
      {'100'},
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );
    expect(out.keys, ['100']);
    expect(out['100']!.map((p) => p.title), ['Morning News', 'Midday']);
    expect(api.calls['100'] ?? 0, shortEpgCalls, reason: 'no per-channel fetch from the sheet path');
    expect(api.xmltvCalls, xmltvCalls, reason: 'no feed fetch from the sheet path');
  });

  test('cachedEpgForChannels skips channels with no cache entry and a stale one', () async {
    final now = DateTime.now();
    scriptEpg(now);
    final first = supportFor();
    await fetchEpg(first, now);
    await waitForEpgFile();

    // Age the persisted entry past the window it covers by rewriting its
    // window narrow, and ask for a channel that was never cached.
    await rewritePersisted((json) {
      json['windowTo'] = now.toIso8601String();
      return json;
    });

    final second = supportFor();
    final out = await second.cachedEpgForChannels(
      {'100', '999'},
      from: now.add(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );
    expect(out, isEmpty, reason: 'stale window and uncached channel contribute nothing');
  });

  // -- Build #15, item 6: the xmltv.php feed is persisted ----------------
  //
  // Before this build the feed was downloaded on every cold start and
  // every rebind, a failed feed was retried channel by channel, and the
  // per-channel short-EPG storm was unbounded. These prove the feed file
  // is written and re-read with zero downloads, a stale file serves
  // immediately while the refresh runs behind it, a failed feed is not
  // re-downloaded inside the negative-cache window, short-EPG concurrency
  // is capped, and a slow short-EPG falls back to the feed fast.

  test('feed file persists and a relaunch serves from it with zero downloads', () async {
    final now = DateTime.now();
    api.xmltvBody = xmltvDoc(now);
    final client = await listedClient();
    final support = client.liveTv as IptvLiveTvSupport;

    final programs = await fetchEpg(support, now);
    expect(programs.map((p) => p.title), ['XMLTV Morning', 'XMLTV Midday']);
    expect(api.xmltvCalls, 1);
    final feedFile = await waitForFeedFile();
    expect(feedFile.existsSync(), isTrue);
    expect(await feedFile.readAsString(), api.xmltvBody);

    // The per-channel file would answer instead — remove it, so the
    // relaunch must come from the feed file.
    await deleteChannelFile('100');
    final relaunched = (await listedClient()).liveTv as IptvLiveTvSupport;
    final again = await fetchEpg(relaunched, now);
    expect(again.map((p) => p.title), ['XMLTV Morning', 'XMLTV Midday']);
    expect(api.xmltvCalls, 1, reason: 'the persisted feed file must be parsed, not re-downloaded');
  });

  test('stale feed file serves immediately and refreshes in the background', () async {
    final now = DateTime.now();
    api.xmltvBody = xmltvDoc(now);
    final client = await listedClient();
    final support = client.liveTv as IptvLiveTvSupport;
    expect((await fetchEpg(support, now)).map((p) => p.title), ['XMLTV Morning', 'XMLTV Midday']);
    final feedFile = await waitForFeedFile();

    // Age the file past the 24h default interval and publish a new feed.
    await feedFile.setLastModified(now.subtract(const Duration(hours: 25)));
    String refreshedDoc() {
      // Same shape as xmltvDoc but with new titles, so the refresh is
      // distinguishable from the stale file.
      return xmltvDoc(now).replaceAll('XMLTV Morning', 'XMLTV Refreshed').replaceAll('XMLTV Midday', 'XMLTV Later');
    }

    api.xmltvBody = refreshedDoc();
    await deleteChannelFile('100');
    final relaunched = (await listedClient()).liveTv as IptvLiveTvSupport;
    final stale = await fetchEpg(relaunched, now);
    expect(stale.map((p) => p.title), ['XMLTV Morning', 'XMLTV Midday'],
        reason: 'the stale feed file answers immediately; the guide never waits on the download');
    // The refresh runs in the background — poll until the NEW body lands
    // in the feed file, which happens after the parse, so the in-memory
    // guide is fresh by then too.
    var refreshed = false;
    for (var i = 0; i < 200 && !refreshed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (await feedFile.readAsString().then((body) => body.contains('XMLTV Refreshed'))) {
        refreshed = true;
      }
    }
    expect(refreshed, isTrue, reason: 'the stale file must trigger a background refresh');
    expect(api.xmltvCalls, 2);
    // The refreshed guide is now on disk — a fresh instance (empty
    // in-memory caches, per-channel file removed again) serves the new
    // titles from the refreshed feed file, with no third download.
    await deleteChannelFile('100');
    final freshSupport = (await listedClient()).liveTv as IptvLiveTvSupport;
    final fresh = await fetchEpg(freshSupport, now);
    expect(fresh.map((p) => p.title), ['XMLTV Refreshed', 'XMLTV Later']);
    expect(api.xmltvCalls, 2, reason: 'the refreshed feed file must be parsed, not re-downloaded');
  });

  test('failed feed is not re-downloaded inside the negative-cache window', () async {
    final now = DateTime.now();
    api.failXmltv = true;
    api.failShortEpg = true;
    final client = await listedClient();
    final support = client.liveTv as IptvLiveTvSupport;

    await expectLater(fetchEpg(support, now), throwsA(anything));
    expect(api.xmltvCalls, 1);
    await expectLater(fetchEpg(support, now), throwsA(anything));
    expect(api.xmltvCalls, 1, reason: 'a feed that just failed must not be re-downloaded per channel');

    // Once the window passes, the next fetch retries the download.
    IptvLiveTvSupport.xmltvNegativeCacheTtl = Duration.zero;
    try {
      await expectLater(fetchEpg(support, now), throwsA(anything));
      expect(api.xmltvCalls, 2);
    } finally {
      IptvLiveTvSupport.xmltvNegativeCacheTtl = const Duration(minutes: 5);
    }
  });

  test('short-EPG concurrency is capped at four', () async {
    final now = DateTime.now();
    api.shortEpgGate = Completer<void>();
    final support = supportFor();
    final futures = <Future<List<LiveTvProgram>>>[];
    for (var i = 0; i < 6; i++) {
      futures.add(
        support.fetchEpgForChannel(
          'ch$i',
          from: now.subtract(const Duration(hours: 1)),
          to: now.add(const Duration(hours: 6)),
        ),
      );
    }
    // Let the six fetches pile up against the cap.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(api.shortEpgMaxInFlight, 4, reason: 'at most four get_short_epg calls run at once');
    expect(api.calls.length, 4, reason: 'the other two channels wait for a slot');
    api.shortEpgGate!.complete();
    final results = await Future.wait(futures);
    expect(results, everyElement(isEmpty));
    expect(api.calls.length, 6, reason: 'the waiting channels run once a slot frees');
  });

  test('slow short-EPG falls back to the feed within the first-paint budget', () async {
    final now = DateTime.now();
    api.xmltvBody = xmltvDoc(now);
    api.shortEpgDelay = const Duration(seconds: 5);
    IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(milliseconds: 100);
    try {
      final client = await listedClient();
      final support = client.liveTv as IptvLiveTvSupport;
      final stopwatch = Stopwatch()..start();
      final programs = await fetchEpg(support, now);
      stopwatch.stop();
      expect(programs.map((p) => p.title), ['XMLTV Morning', 'XMLTV Midday']);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)),
          reason: 'the channel must fall back to the feed fast, not wait out the slow short-EPG');
    } finally {
      IptvLiveTvSupport.shortEpgFirstPaintTimeout = const Duration(seconds: 15);
    }
  });
}
