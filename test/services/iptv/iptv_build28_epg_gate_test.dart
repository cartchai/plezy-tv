// Failing-first tests for build #28 (block fixes, v1.0.9) — EPG half.
//
// The EPG fixes do not exist on the base (6fe84db64): these tests
// reference the new API, so they fail to compile there and pass on the
// fix. No live panel: a fake XtreamApi only. Credentials below are fake
// ('user' / 'pa' 'ss') and must never appear in a stored entry.
//
// Covers:
//   * the whole-guide XMLTV feed does not START while a stream is
//     playing (and starts again when playback stops).
//   * a per-channel short-EPG fetch stops when its row scrolls away
//     (cancelEpgFetchForChannel) instead of running to completion.
//   * a background cancel stops an in-flight feed download
//     (cancelBackgroundWork) without poisoning the feed's negative cache.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
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

MediaServerHttpException _cancelled() =>
    MediaServerHttpException(type: MediaServerHttpErrorType.cancelled, message: 'cancelled');

/// A fake XtreamApi that honours the abort trigger (build #28): the
/// short-EPG and the feed each race their scripted answer against the
/// trigger, so a cancel stops the wait instead of running to completion.
class _AbortableEpgApi extends XtreamApi {
  _AbortableEpgApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  final Map<String, int> shortEpgCalls = {};
  var xmltvCalls = 0;
  var xmltvAborted = false;
  Duration shortEpgDelay = Duration.zero;
  Duration xmltvDelay = Duration.zero;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    shortEpgCalls[streamId] = (shortEpgCalls[streamId] ?? 0) + 1;
    final answer = Future<List<XtreamEpgProgram>>.delayed(shortEpgDelay, () => scripted[streamId] ?? const []);
    if (abortTrigger == null) return answer;
    return Future.any([answer, abortTrigger.then((_) => throw _cancelled())]);
  }

  /// Build #26: the fake's feed is a small canned String, so the stream
  /// is built on top of [getXmltv] — the production path streams, the fake
  /// does not need to.
  @override
  Stream<List<int>> getXmltvStream({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async* {
    yield utf8.encode(await getXmltv(timeout: timeout, abortTrigger: abortTrigger));
  }
  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    xmltvCalls++;
    final answer = Future<String>.delayed(xmltvDelay, () => xmltvBody);
    if (abortTrigger == null) return answer;
    return Future.any([
      answer,
      abortTrigger.then((_) {
        xmltvAborted = true;
        throw _cancelled();
      }),
    ]);
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
    XtreamLiveStream(streamId: 200, name: 'Channel 200', epgChannelId: 'ch200'),
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
  late _AbortableEpgApi api;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_build28_epg_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
    api = _AbortableEpgApi();
  });

  tearDown(() async {
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
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

  IptvLiveTvSupport supportFor() {
    final client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    return client.liveTv as IptvLiveTvSupport;
  }

  group('Build #28 — the guide feed waits while a stream is playing', () {
    test('the xmltv.php feed does not start while playing, and starts when playback stops', () async {
      final support = supportFor();
      final now = DateTime.now();
      IptvPlaybackActivity.instance.markPlaying();
      final programs = await support.fetchEpgForChannel(
        '100',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 6)),
      );
      expect(programs, isEmpty);
      expect(api.xmltvCalls, 0, reason: 'no feed download may start while a stream is playing');
      IptvPlaybackActivity.instance.markIdle();
      // A different channel (no cached entry from the playing fetch).
      await support.fetchEpgForChannel(
        '200',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 6)),
      );
      expect(api.xmltvCalls, 1, reason: 'the feed starts once playback stops');
    });
  });

  group('Build #28 — EPG fetches stop when nobody watches them', () {
    test('a scrolled-away row stops its short-EPG fetch instead of running to completion', () async {
      final support = supportFor();
      api.shortEpgDelay = const Duration(seconds: 2);
      final now = DateTime.now();
      final fetch = support.fetchEpgForChannel(
        '100',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 6)),
      );
      await _waitFor(() => (api.shortEpgCalls['100'] ?? 0) > 0);
      // The row scrolled away.
      final stopwatch = Stopwatch()..start();
      support.cancelEpgFetchForChannel('100');
      Object? thrown;
      try {
        await fetch;
      } on Object catch (e) {
        thrown = e;
      }
      final elapsed = stopwatch.elapsed;
      expect(thrown, isNotNull, reason: 'the cancelled fetch surfaces instead of returning a stale answer');
      expect(
        thrown is MediaServerHttpException && thrown.isCancellation,
        isTrue,
        reason: 'the cancellation is a cancellation, not a failure',
      );
      expect(elapsed, lessThan(const Duration(seconds: 1)), reason: 'the fetch stops promptly, not after the 2s delay');
    });

    test('a background cancel stops an in-flight feed download without poisoning the negative cache', () async {
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      client.testXtreamApi = api;
      final support = client.liveTv as IptvLiveTvSupport;
      api.xmltvDelay = const Duration(seconds: 5);
      final now = DateTime.now();
      final fetch = support.fetchEpgForChannel(
        '100',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 6)),
      );
      await _waitFor(() => api.xmltvCalls > 0);
      final stopwatch = Stopwatch()..start();
      client.cancelBackgroundWork();
      final programs = await fetch;
      final elapsed = stopwatch.elapsed;
      expect(programs, isEmpty, reason: 'short-EPG answered empty, so the cancelled feed yields an empty guide');
      expect(api.xmltvAborted, isTrue, reason: 'the feed download itself was aborted, not merely un-awaited');
      expect(elapsed, lessThan(const Duration(seconds: 2)), reason: 'the fetch returns promptly, not after the 5s feed delay');
      // The cancelled feed must not poison the negative cache: the SAME
      // support fetching another channel (no per-channel entry yet)
      // starts the feed again instead of refusing for 120 s. A fresh
      // support would prove nothing — its negative cache is empty.
      api.xmltvDelay = Duration.zero;
      await support.fetchEpgForChannel(
        '200',
        from: now.subtract(const Duration(hours: 1)),
        to: now.add(const Duration(hours: 6)),
      );
      expect(api.xmltvCalls, 2, reason: 'the feed downloads again after a cancellation — no 120 s negative cache');
    });
  });
}
