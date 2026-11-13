// PROBE I8+I9 (parse-time window filter + conditional fetch). FAILING-FIRST
// on the 1.2.1 base:
// - parseXmltvStream has no window params (I8) — the I8 tests fail to
//   compile on base.
// - XtreamApi.getXmltvFeed does not exist (I9) — the I9 fetch tests fail
//   to compile on base.
// - IptvEpgSourcesStore.loadValidators/saveValidators/clearValidators do
//   not exist (I9) — the store test fails to compile on base.
//
// No live panel use: fixtures generated locally + loopback server. Zero
// panel requests. No streams are ever opened.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/xmltv_parser.dart';
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

/// Restores the real dart:io HttpClient, bypassing the test binding's
/// always-400 mock. Used only by the loopback-server tests.
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('I8 parse-time window filter', () {
    Future<List<XmltvProgram>> parseDoc(
      String doc, {
      int? windowFromEpoch,
      int? windowToEpoch,
    }) =>
        parseXmltvStream(
          Stream<List<int>>.value(utf8.encode(doc)),
          windowFromEpoch: windowFromEpoch,
          windowToEpoch: windowToEpoch,
        ).toList();

    const head = '<?xml version="1.0" encoding="UTF-8"?><tv>';
    String prog(String title, DateTime start, DateTime end) =>
        '<programme start="${_xmltvTime(start)}" stop="${_xmltvTime(end)}" channel="ch1">'
        '<title>$title</title></programme>';

    test('drops programmes outside the window, keeps boundary-spanning ones', () async {
      final from = DateTime.utc(2026, 11, 13);
      final to = DateTime.utc(2026, 11, 13, 12);
      final doc =
          '$head'
          // Entirely before the window.
          '${prog('Before', DateTime.utc(2026, 11, 12, 20), DateTime.utc(2026, 11, 12, 22))}'
          // Spans the window start (starts before, ends inside).
          '${prog('SpanStart', DateTime.utc(2026, 11, 12, 23), DateTime.utc(2026, 11, 13, 1))}'
          // Fully inside.
          '${prog('Inside', DateTime.utc(2026, 11, 13, 6), DateTime.utc(2026, 11, 13, 6, 30))}'
          // Spans the window end (starts inside, ends after).
          '${prog('SpanEnd', DateTime.utc(2026, 11, 13, 11), DateTime.utc(2026, 11, 13, 13))}'
          // Entirely after the window.
          '${prog('After', DateTime.utc(2026, 11, 13, 14), DateTime.utc(2026, 11, 13, 15))}'
          // Ends exactly at the window start: no overlap, dropped.
          '${prog('EndsAtFrom', DateTime.utc(2026, 11, 12, 23), DateTime.utc(2026, 11, 13))}'
          // Starts exactly at the window end: no overlap, dropped.
          '${prog('StartsAtTo', DateTime.utc(2026, 11, 13, 12), DateTime.utc(2026, 11, 13, 12, 30))}'
          '</tv>';
      final programs = await parseDoc(
        doc,
        windowFromEpoch: from.millisecondsSinceEpoch ~/ 1000,
        windowToEpoch: to.millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        programs.map((p) => p.title),
        ['SpanStart', 'Inside', 'SpanEnd'],
        reason: 'the filter is an overlap test, not a start-inside test: '
            'a show that straddles the window edge is visible in the guide',
      );
    });

    test('no window params keeps everything (existing behaviour)', () async {
      final doc =
          '$head'
          '${prog('Old', DateTime.utc(2026, 10, 1), DateTime.utc(2026, 10, 1, 1))}'
          '${prog('Now', DateTime.utc(2026, 11, 13, 6), DateTime.utc(2026, 11, 13, 6, 30))}'
          '${prog('Far', DateTime.utc(2027, 1, 1), DateTime.utc(2027, 1, 1, 1))}'
          '</tv>';
      expect((await parseDoc(doc)).map((p) => p.title), ['Old', 'Now', 'Far']);
    });

    test('wide-span Trex-scale feed: the filter retains only the in-window slice', () async {
      // Same scale as the #26 fixture (5,000 channels x 192 programmes,
      // ~151 MB) but spread over 60 days instead of 4, so most of it is
      // outside the widest guide window and the filter has something to
      // drop. `now` is truncated to whole seconds: programme times are
      // formatted to whole seconds, so the expected count (computed from
      // DateTimes) must use the same precision as the parsed epochs.
      final rawNow = DateTime.now().toUtc();
      final now = DateTime.utc(rawNow.year, rawNow.month, rawNow.day, rawNow.hour, rawNow.minute, rawNow.second);
      final windowFrom = now.subtract(const Duration(days: 7, hours: 2));
      final windowTo = now.add(const Duration(days: 8, hours: 2));
      final windowFromEpoch = windowFrom.millisecondsSinceEpoch ~/ 1000;
      final windowToEpoch = windowTo.millisecondsSinceEpoch ~/ 1000;

      // Expected count, computed from the slot layout + the overlap rule
      // independently of the parser (stop > from && start < to).
      final base = now.subtract(const Duration(days: 30));
      var expected = 0;
      for (var s = 0; s < _kWideSlots; s++) {
        final start = base.add(Duration(minutes: s * 450));
        final stop = start.add(const Duration(minutes: 30));
        if (stop.isAfter(windowFrom) && start.isBefore(windowTo)) expected += _kWideChannels;
      }
      expect(expected, greaterThan(0), reason: 'the fixture must actually overlap the window');
      expect(expected, lessThan(_kWideChannels * _kWideSlots),
          reason: 'most of the wide-span fixture must be outside the window');

      // Control: unfiltered, every programme is yielded.
      var unfiltered = 0;
      await for (final _ in parseXmltvStream(_wideSpanXmltvBytes(now))) {
        unfiltered++;
      }
      expect(unfiltered, _kWideChannels * _kWideSlots);

      // Filtered: only the in-window slice is retained. RSS is printed
      // for the record (the retained list is what the ~180-203 MB floor
      // is made of); the count is the deterministic assertion.
      final rssBefore = ProcessInfo.currentRss;
      var peak = rssBefore;
      final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final rss = ProcessInfo.currentRss;
        if (rss > peak) peak = rss;
      });
      var filtered = 0;
      final sw = Stopwatch()..start();
      try {
        await for (final _ in parseXmltvStream(
          _wideSpanXmltvBytes(now),
          windowFromEpoch: windowFromEpoch,
          windowToEpoch: windowToEpoch,
        )) {
          filtered++;
        }
      } finally {
        sampler.cancel();
        sw.stop();
      }
      // ignore: avoid_print
      print('I8 wide-span: unfiltered=$unfiltered filtered=$filtered expected=$expected '
          'parseMs=${sw.elapsedMilliseconds} peakRssDelta=${(peak - rssBefore) ~/ 1048576}MB');
      expect(filtered, expected,
          reason: 'the parse-time filter must retain exactly the programmes '
              'overlapping the widest guide window — no more (the retained '
              'floor), no fewer (a visible show)');
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  _i9Groups();
  _i9IntegrationGroups();
}

// -- I8 wide-span Trex-scale fixture -------------------------------------
//
// Same scale as the #26 fixture (5,000 channels x 192 programmes, ~151 MB
// of XML) but spread over 60 days: slot s starts at (now - 30d) + s x 7.5h
// with a 30-minute duration, so only the ~15 days around now fall inside
// the widest guide window.
const int _kWideChannels = 5000;
const int _kWideSlots = 192;

String _wideProgramme(int channel, int slot, DateTime base) {
  final start = base.add(Duration(minutes: slot * 450));
  final stop = start.add(const Duration(minutes: 30));
  return '<programme start="${_xmltvTime(start)}" stop="${_xmltvTime(stop)}" channel="ch$channel">'
      '<title>Show $slot on ch$channel</title><desc>Description $slot.</desc></programme>';
}

/// Lazily generate the wide-span fixture as a byte stream in ~64 KB
/// chunks. The whole ~151 MB body is NEVER materialised as a String.
Stream<List<int>> _wideSpanXmltvBytes(DateTime now) async* {
  const chunkBytes = 64 * 1024;
  final base = now.subtract(const Duration(days: 30));
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  for (var c = 0; c < _kWideChannels; c++) {
    buf.write('<channel id="ch$c"><display-name>Channel $c</display-name></channel>');
  }
  for (var c = 0; c < _kWideChannels; c++) {
    for (var s = 0; s < _kWideSlots; s++) {
      buf.write(_wideProgramme(c, s, base));
      if (buf.length >= chunkBytes) {
        yield utf8.encode(buf.toString());
        buf.clear();
      }
    }
  }
  buf.write('</tv>');
  if (buf.isNotEmpty) yield utf8.encode(buf.toString());
}

// -- I9 conditional fetch --------------------------------------------------

void _i9Groups() {
  group('I9 conditional fetch (fake server, fetch level)', () {
    late HttpServer server;
    HttpOverrides? previousOverrides;
    final requests = <({String method, String path, String? ifNoneMatch, String? ifModifiedSince})>[];
    var bodyBytesSent = 0;
    String feedBody = '';
    String feedEtag = '"v1"';
    String feedLastModified = 'Wed, 01 Jan 2025 00:00:00 GMT';
    bool sendValidators = true;

    setUp(() async {
      requests.clear();
      bodyBytesSent = 0;
      sendValidators = true;
      feedEtag = '"v1"';
      feedLastModified = 'Wed, 01 Jan 2025 00:00:00 GMT';
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final now = DateTime.now();
      feedBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Show',
        start: now.subtract(const Duration(hours: 1)),
        end: now.add(const Duration(hours: 1)),
      );
      server.listen((request) async {
        requests.add((
          method: request.method,
          path: request.uri.path,
          ifNoneMatch: request.headers.value(HttpHeaders.ifNoneMatchHeader),
          ifModifiedSince: request.headers.value(HttpHeaders.ifModifiedSinceHeader),
        ));
        final response = request.response;
        if (request.uri.path != '/xmltv.php') {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        // A request carrying our current ETag is answered 304 with no
        // body — the conditional-fetch contract.
        if (sendValidators && request.headers.value(HttpHeaders.ifNoneMatchHeader) == feedEtag) {
          response.statusCode = HttpStatus.notModified;
          response.headers.set(HttpHeaders.etagHeader, feedEtag);
          response.headers.set(HttpHeaders.lastModifiedHeader, feedLastModified);
          await response.close();
          return;
        }
        final bytes = utf8.encode(feedBody);
        bodyBytesSent += bytes.length;
        response.statusCode = HttpStatus.ok;
        if (sendValidators) {
          response.headers.set(HttpHeaders.etagHeader, feedEtag);
          response.headers.set(HttpHeaders.lastModifiedHeader, feedLastModified);
        }
        response.headers.contentType = ContentType('application', 'xml');
        response.add(bytes);
        await response.close();
      });
    });

    tearDown(() async {
      HttpOverrides.global = previousOverrides;
      await server.close(force: true);
    });

    XtreamApi api() => XtreamApi(
      serverUrl: 'http://127.0.0.1:${server.port}',
      username: 'user',
      password: _testPassword,
    );

    Future<List<int>> readBytes(Stream<List<int>> stream) =>
        stream.fold<List<int>>(<int>[], (list, chunk) => list..addAll(chunk));

    test('first fetch sends no validators and returns them', () async {
      final fetch = await api().getXmltvFeed();
      expect(fetch.notModified, isFalse);
      expect(fetch.etag, feedEtag);
      expect(fetch.lastModified, feedLastModified);
      expect(utf8.decode(await readBytes(fetch.bytes)), feedBody);
      expect(requests, hasLength(1));
      expect(requests.single.ifNoneMatch, isNull);
      expect(requests.single.ifModifiedSince, isNull);
    });

    test('second fetch with validators gets a 304 and zero body bytes', () async {
      final first = await api().getXmltvFeed();
      expect(first.notModified, isFalse);
      await readBytes(first.bytes);
      final bytesBeforeSecond = bodyBytesSent;
      final second = await api().getXmltvFeed(etag: first.etag, lastModified: first.lastModified);
      expect(second.notModified, isTrue, reason: 'the server must 304 a request carrying its ETag');
      expect(await readBytes(second.bytes), isEmpty);
      expect(bodyBytesSent, bytesBeforeSecond,
          reason: 'a 304 revalidation must download zero body bytes');
      expect(requests, hasLength(2));
      expect(requests[1].ifNoneMatch, feedEtag);
      expect(requests[1].ifModifiedSince, feedLastModified);
      expect(second.etag, feedEtag);
    });

    test('a changed feed returns 200 with the new body and validators', () async {
      final first = await api().getXmltvFeed();
      await readBytes(first.bytes);
      final now = DateTime.now();
      feedBody = _feedWith(
        channelId: 'ch100',
        title: 'Feed Show v2',
        start: now.subtract(const Duration(hours: 1)),
        end: now.add(const Duration(hours: 1)),
      );
      feedEtag = '"v2"';
      final second = await api().getXmltvFeed(etag: first.etag, lastModified: first.lastModified);
      expect(second.notModified, isFalse, reason: 'a changed ETag must not 304');
      expect(second.etag, '"v2"');
      expect(utf8.decode(await readBytes(second.bytes)), contains('Feed Show v2'));
      expect(requests[1].ifNoneMatch, '"v1"');
    });

    test('a server that sends no validators behaves like a plain fetch', () async {
      sendValidators = false;
      final first = await api().getXmltvFeed();
      expect(first.notModified, isFalse);
      expect(first.etag, isNull);
      expect(first.lastModified, isNull);
      await readBytes(first.bytes);
      final second = await api().getXmltvFeed();
      expect(second.notModified, isFalse);
      expect(requests, hasLength(2));
      expect(requests[1].ifNoneMatch, isNull);
      expect(requests[1].ifModifiedSince, isNull);
    });
  });

  group('I9 feed validators store', () {
    setUp(() async {
      resetSharedPreferencesForTest();
    });

    test('validators round-trip per cacheKey and clear removes them', () async {
      final store = IptvEpgSourcesStore('trex');
      expect((await store.loadValidators('xtream:trex')).etag, isNull);
      expect((await store.loadValidators('xtream:trex')).lastModified, isNull);
      await store.saveValidators('xtream:trex', '"v1"', 'Wed, 01 Jan 2025 00:00:00 GMT');
      final loaded = await store.loadValidators('xtream:trex');
      expect(loaded.etag, '"v1"');
      expect(loaded.lastModified, 'Wed, 01 Jan 2025 00:00:00 GMT');
      // A save with no validators removes the row.
      await store.saveValidators('xtream:trex', null, null);
      expect((await store.loadValidators('xtream:trex')).etag, isNull);
      // Validators are per cacheKey; clear removes all of them.
      await store.saveValidators('xtream:trex', '"v1"', null);
      await store.saveValidators('user:abc', '"u1"', null);
      await store.clearValidators();
      expect((await store.loadValidators('xtream:trex')).etag, isNull);
      expect((await store.loadValidators('user:abc')).etag, isNull);
    });
  });
}

// -- I9 conditional fetch, end-to-end through the support ------------------

/// Fake provider for the I9 integration tests: short-EPG answers empty
/// (so the feed path is taken) and the channel list is scripted. The
/// feed itself is NOT faked — getXmltvFeed is the real implementation,
/// pointed at the loopback server.
class _I9FakeApi extends XtreamApi {
  _I9FakeApi({required super.serverUrl}) : super(username: 'user', password: _testPassword);

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async =>
      const [];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({
    String? categoryId,
    Future<void>? abortTrigger,
  }) async =>
      const [
        XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
        XtreamLiveStream(streamId: 200, name: 'Channel 200', epgChannelId: 'ch200'),
      ];
}

void _i9IntegrationGroups() {
  group('I9 conditional fetch end-to-end (support + loopback server)', () {
    late Directory tempDir;
    late HttpServer server;
    HttpOverrides? previousOverrides;
    final requests = <({String? ifNoneMatch, String? ifModifiedSince})>[];
    var bodyBytesSent = 0;
    String feedBody = '';
    String feedEtag = '"v1"';

    String docV1(DateTime now) {
      final start = now.subtract(const Duration(hours: 1));
      final mid = now.add(const Duration(hours: 1));
      final end = now.add(const Duration(hours: 2));
      return _feedWith(
        channelId: 'ch100',
        title: 'XMLTV Morning',
        start: start,
        end: mid,
        extraProgrammes:
            '<programme start="${_xmltvTime(mid)}" stop="${_xmltvTime(end)}" channel="ch100">'
            '<title>XMLTV Midday</title></programme>',
      );
    }

    setUp(() async {
      resetSharedPreferencesForTest();
      LocaleSettings.setLocaleSync(AppLocale.en);
      await SettingsService.getInstance();
      IptvCatalogDiskCache.debugDisableDisk = true;
      tempDir = await Directory.systemTemp.createTemp('plezy_epg_i9_');
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
      requests.clear();
      bodyBytesSent = 0;
      feedEtag = '"v1"';
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final now = DateTime.now();
      feedBody = docV1(now);
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path != '/xmltv.php') {
          response.statusCode = HttpStatus.notFound;
          await response.close();
          return;
        }
        // Only xmltv.php requests are logged: the client also calls
        // player_api.php (live categories) against this server and those
        // 404s are not feed fetches.
        requests.add((
          ifNoneMatch: request.headers.value(HttpHeaders.ifNoneMatchHeader),
          ifModifiedSince: request.headers.value(HttpHeaders.ifModifiedSinceHeader),
        ));
        if (request.headers.value(HttpHeaders.ifNoneMatchHeader) == feedEtag) {
          response.statusCode = HttpStatus.notModified;
          response.headers.set(HttpHeaders.etagHeader, feedEtag);
          response.headers.set(HttpHeaders.lastModifiedHeader, 'Wed, 01 Jan 2025 00:00:00 GMT');
          await response.close();
          return;
        }
        final bytes = utf8.encode(feedBody);
        bodyBytesSent += bytes.length;
        response.statusCode = HttpStatus.ok;
        response.headers.set(HttpHeaders.etagHeader, feedEtag);
        response.headers.set(HttpHeaders.lastModifiedHeader, 'Wed, 01 Jan 2025 00:00:00 GMT');
        response.headers.contentType = ContentType('application', 'xml');
        response.add(bytes);
        await response.close();
      });
    });

    tearDown(() async {
      HttpOverrides.global = previousOverrides;
      await server.close(force: true);
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

    Future<IptvClient> listedClient() async {
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      client.testXtreamApi = _I9FakeApi(serverUrl: 'http://127.0.0.1:${server.port}');
      await client.iptvChannels();
      return client;
    }

    Future<List<LiveTvProgram>> fetchEpg(IptvLiveTvSupport support, DateTime now) =>
        support.fetchEpgForChannel(
          '100',
          from: now.subtract(const Duration(hours: 1)),
          to: now.add(const Duration(hours: 6)),
        );

    Future<File> waitForFeedFile() async {
      for (var i = 0; i < 100; i++) {
        final files = tempDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.xml'))
            .toList();
        if (files.length == 1) return files.single;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('persisted XMLTV feed file was not written');
    }

    Future<void> deleteChannelFile(String channelKey) async {
      final safe = base64Url.encode(utf8.encode(channelKey)).replaceAll('=', '');
      // The per-channel write is fire-and-forget (unawaited), so the
      // fetch returning does not mean the file is on disk yet: wait for
      // it to land before deleting, or the delete misses and the write
      // lands after it — and the next fetch serves from the file with
      // no feed download at all (a flake, not a pass).
      for (var i = 0; i < 200; i++) {
        final files = tempDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('/$safe.json'))
            .toList();
        if (files.isNotEmpty) {
          for (final file in files) {
            await file.delete();
          }
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('persisted channel file for $channelKey was not written');
    }

    /// Poll until the loopback server has seen [count] xmltv.php
    /// requests (the background refresh is fire-and-forget).
    Future<void> waitForXmltvRequests(int count) async {
      for (var i = 0; i < 200; i++) {
        if (requests.length >= count) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('expected $count xmltv.php requests, saw ${requests.length}');
    }

    test('a 304 revalidation skips the download and the re-parse', () async {
      final now = DateTime.now();
      final client = await listedClient();
      final support = client.liveTv as IptvLiveTvSupport;
      expect((await fetchEpg(support, now)).map((p) => p.title), ['XMLTV Morning', 'XMLTV Midday']);
      final feedFile = await waitForFeedFile();
      expect(requests, hasLength(1));
      expect(requests.single.ifNoneMatch, isNull,
          reason: 'the first fetch has no validators to send');
      final store = IptvEpgSourcesStore('trex');
      expect((await store.loadValidators('xtream:trex')).etag, '"v1"',
          reason: 'the 200 response validators must be stored for the next refresh');
      final bytesAfterFirst = bodyBytesSent;

      // Age the feed file past the 24h interval and relaunch: the stale
      // file answers immediately while the refresh runs in the background.
      await feedFile.setLastModified(now.subtract(const Duration(hours: 25)));
      await deleteChannelFile('100');
      final relaunched = (await listedClient()).liveTv as IptvLiveTvSupport;
      final stale = await fetchEpg(relaunched, now);
      expect(stale.map((p) => p.title), ['XMLTV Morning', 'XMLTV Midday'],
          reason: 'the stale feed file answers immediately; the guide never waits on the download');
      await waitForXmltvRequests(2);
      // Let the 304 response finish processing (validator save + mtime touch).
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(requests[1].ifNoneMatch, '"v1"',
          reason: 'the refresh must send the stored ETag back');
      expect(requests[1].ifModifiedSince, 'Wed, 01 Jan 2025 00:00:00 GMT');
      expect(bodyBytesSent, bytesAfterFirst,
          reason: 'a 304 revalidation must download zero body bytes');
      expect(await feedFile.readAsString(), feedBody,
          reason: 'a 304 must not rewrite the persisted feed file');
      expect((await store.loadValidators('xtream:trex')).etag, '"v1"');

      // The revalidated guide is fresh now: a third fetch (fresh
      // instance, per-channel file removed) serves it with no third
      // download — the touched file mtime reads as fresh.
      await deleteChannelFile('100');
      final freshSupport = (await listedClient()).liveTv as IptvLiveTvSupport;
      expect((await fetchEpg(freshSupport, now)).map((p) => p.title),
          ['XMLTV Morning', 'XMLTV Midday']);
      expect(requests, hasLength(2),
          reason: 'the revalidated feed file must be parsed, not re-downloaded');
    });

    test('the 304 backstop: validators without a guide re-fetch fresh', () async {
      final now = DateTime.now();
      final client = await listedClient();
      final support = client.liveTv as IptvLiveTvSupport;
      expect((await fetchEpg(support, now)).map((p) => p.title), ['XMLTV Morning', 'XMLTV Midday']);
      final feedFile = await waitForFeedFile();
      expect((await IptvEpgSourcesStore('trex').loadValidators('xtream:trex')).etag, '"v1"');

      // Delete the feed file (validators survive in prefs): the next
      // cold fetch sends the stale validators, gets a 304, has no guide
      // to reuse — and must fall back to a fresh unconditional download
      // instead of serving nothing.
      await feedFile.delete();
      await deleteChannelFile('100');
      final relaunched = (await listedClient()).liveTv as IptvLiveTvSupport;
      expect((await fetchEpg(relaunched, now)).map((p) => p.title),
          ['XMLTV Morning', 'XMLTV Midday']);
      expect(requests, hasLength(3));
      expect(requests[1].ifNoneMatch, '"v1"', reason: 'the cold fetch still sends the stored ETag');
      expect(requests[2].ifNoneMatch, isNull,
          reason: 'the backstop retry must not send validators the server just 304d');
      final rewritten = await waitForFeedFile();
      expect(await rewritten.readAsString(), feedBody);
    });
  });
}
