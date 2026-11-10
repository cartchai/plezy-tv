import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/models/livetv_capture_buffer.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/screens/video_player/live_channel_pretune.dart';

class _FakeSession implements LiveTvPlaybackSession {
  _FakeSession(this.url);

  final String url;
  var discarded = false;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.retainSession;

  @override
  CaptureBuffer? get captureBuffer => null;

  @override
  bool get canTimeShift => false;

  @override
  LiveProgramInfo get program => LiveProgramInfo.none;

  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  Map<String, String> get streamHeaders => const {'Accept-Language': 'en'};

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) => Future.value(null);

  @override
  Future<void> discard() async {
    discarded = true;
  }

  @override
  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio}) =>
      Future.value(this);

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) => Future.value(url);
}

List<LiveTvChannel> _channels() => [
  LiveTvChannel(key: 'ch-1', title: 'Channel 1', serverId: 'srv-1'),
  LiveTvChannel(key: 'ch-2', title: 'Channel 2', serverId: 'srv-1'),
  LiveTvChannel(key: 'ch-3', title: 'Channel 3', serverId: 'srv-1'),
  LiveTvChannel(key: 'ch-4', title: 'Channel 4', serverId: 'srv-1'),
];

void main() {
  group('LiveChannelPretuner', () {
    test('refresh pre-tunes only the neighbours of the current channel', () {
      fakeAsync((async) {
        final started = <String>[];
        final sessions = <String, _FakeSession>{};
        final pretuner = LiveChannelPretuner(
          startSession: (channel) async {
            started.add(channel.key);
            return sessions.putIfAbsent(channel.key, () => _FakeSession('http://example.invalid/${channel.key}.m3u8'));
          },
          resolveUrl: (session) => session.streamUrlAt(),
          discardSession: (session) => session.discard(),
          now: () => DateTime(2026, 1, 1).add(async.elapsed),
        );
        addTearDown(pretuner.dispose);

        // Current channel is ch-2 (index 1): neighbours are ch-1 and ch-3.
        pretuner.refresh(_channels(), 1);
        async.flushMicrotasks();

        expect(started, unorderedEquals(['ch-1', 'ch-3']));
        expect(pretuner.take('ch-1'), isNotNull);
        expect(pretuner.take('ch-3'), isNotNull);
        expect(pretuner.take('ch-2'), isNull, reason: 'the current channel is never pre-tuned');
        expect(pretuner.take('ch-4'), isNull, reason: 'only adjacent channels are pre-tuned');
      });
    });

    test('take consumes the entry: a second take returns null', () {
      fakeAsync((async) {
        final pretuner = LiveChannelPretuner(
          startSession: (channel) async => _FakeSession('http://example.invalid/${channel.key}.m3u8'),
          resolveUrl: (session) => session.streamUrlAt(),
          discardSession: (session) => session.discard(),
          now: () => DateTime(2026, 1, 1).add(async.elapsed),
        );
        addTearDown(pretuner.dispose);

        pretuner.refresh(_channels(), 0);
        async.flushMicrotasks();

        final first = pretuner.take('ch-2');
        expect(first, isNotNull);
        expect(first!.streamUrl, 'http://example.invalid/ch-2.m3u8');
        expect(pretuner.take('ch-2'), isNull, reason: 'a consumed entry cannot be zapped to twice');
      });
    });

    test('a tune that completes after the viewer moved on is discarded', () {
      fakeAsync((async) {
        final sessions = <String, _FakeSession>{};
        final pretuner = LiveChannelPretuner(
          startSession: (channel) async {
            // A slow session negotiation: the viewer zaps away while it runs.
            await Future<void>.delayed(const Duration(milliseconds: 250));
            return sessions.putIfAbsent(channel.key, () => _FakeSession('http://example.invalid/${channel.key}.m3u8'));
          },
          resolveUrl: (session) => session.streamUrlAt(),
          discardSession: (session) => session.discard(),
          now: () => DateTime(2026, 1, 1).add(async.elapsed),
        );
        addTearDown(pretuner.dispose);

        pretuner.refresh(_channels(), 0);
        async.elapse(const Duration(milliseconds: 100));
        // The viewer zapped to ch-4 before the ch-2 tune finished: ch-2 is
        // no longer a neighbour of the current channel.
        pretuner.refresh(_channels(), 3);
        async.elapse(const Duration(milliseconds: 500));

        expect(pretuner.take('ch-2'), isNull, reason: 'ch-2 is no longer a neighbour of ch-4');
        expect(sessions['ch-2']!.discarded, isTrue, reason: 'the stale tune must not leak its session');
        expect(pretuner.take('ch-3'), isNotNull, reason: 'the new neighbour still pre-tunes');
      });
    });

    test('an expired entry is discarded on take instead of served stale', () {
      fakeAsync((async) {
        final session = _FakeSession('http://example.invalid/ch-2.m3u8');
        final pretuner = LiveChannelPretuner(
          startSession: (channel) async => session,
          resolveUrl: (session) => session.streamUrlAt(),
          discardSession: (session) => session.discard(),
          entryTtl: const Duration(seconds: 60),
          now: () => DateTime(2026, 1, 1).add(async.elapsed),
        );
        addTearDown(pretuner.dispose);

        pretuner.refresh(_channels(), 0);
        async.flushMicrotasks();
        expect(pretuner.take('ch-2'), isNotNull);

        pretuner.refresh(_channels(), 0);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 61));

        expect(pretuner.take('ch-2'), isNull, reason: 'a 60 s-old tune is stale');
        expect(session.discarded, isTrue);
      });
    });

    test('a probed 403 marks the neighbour dead; a probe failure does not', () {
      fakeAsync((async) {
        var probeStatus = 403;
        var probeShouldThrow = false;
        final pretuner = LiveChannelPretuner(
          startSession: (channel) async => _FakeSession('http://example.invalid/${channel.key}.m3u8'),
          resolveUrl: (session) => session.streamUrlAt(),
          discardSession: (session) => session.discard(),
          shouldProbe: (_) => true,
          probePlaylist: (url, headers) async {
            if (probeShouldThrow) throw StateError('probe could not run');
            return probeStatus;
          },
          now: () => DateTime(2026, 1, 1).add(async.elapsed),
        );
        addTearDown(pretuner.dispose);

        pretuner.refresh(_channels(), 0);
        async.flushMicrotasks();
        final dead = pretuner.take('ch-2');
        expect(dead, isNotNull);
        expect(dead!.probeStatus, 403);
        expect(dead.isDead, isTrue, reason: 'a refused playlist must fail the zap fast, not open mpv onto it');

        // A 200 means the neighbour is alive.
        probeStatus = 200;
        pretuner.refresh(_channels(), 0);
        async.flushMicrotasks();
        final alive = pretuner.take('ch-2');
        expect(alive, isNotNull);
        expect(alive!.isDead, isFalse);

        // A probe that could not run (timeout, DNS) is inconclusive: the zap
        // still opens normally rather than trusting an absent verdict.
        probeShouldThrow = true;
        pretuner.refresh(_channels(), 0);
        async.flushMicrotasks();
        final unknown = pretuner.take('ch-2');
        expect(unknown, isNotNull);
        expect(unknown!.probeStatus, isNull);
        expect(unknown.isDead, isFalse);
      });
    });

    test('a probed 404 marks the neighbour dead; a probed 429 does not', () {
      fakeAsync((async) {
        var probeStatus = 404;
        final pretuner = LiveChannelPretuner(
          startSession: (channel) async => _FakeSession('http://example.invalid/${channel.key}.m3u8'),
          resolveUrl: (session) => session.streamUrlAt(),
          discardSession: (session) => session.discard(),
          shouldProbe: (_) => true,
          probePlaylist: (url, headers) async => probeStatus,
          now: () => DateTime(2026, 1, 1).add(async.elapsed),
        );
        addTearDown(pretuner.dispose);

        pretuner.refresh(_channels(), 0);
        async.flushMicrotasks();
        expect(pretuner.take('ch-2')!.isDead, isTrue);

        // 429 is transient (rate limit), not a refusal: the zap opens and the
        // stream retry policy owns it.
        probeStatus = 429;
        pretuner.refresh(_channels(), 0);
        async.flushMicrotasks();
        expect(pretuner.take('ch-2')!.isDead, isFalse);
      });
    });

    test('dispose discards every held session', () {
      fakeAsync((async) {
        final sessions = <_FakeSession>[];
        final pretuner = LiveChannelPretuner(
          startSession: (channel) async {
            final session = _FakeSession('http://example.invalid/${channel.key}.m3u8');
            sessions.add(session);
            return session;
          },
          resolveUrl: (session) => session.streamUrlAt(),
          discardSession: (session) => session.discard(),
          now: () => DateTime(2026, 1, 1).add(async.elapsed),
        );

        pretuner.refresh(_channels(), 1);
        async.flushMicrotasks();
        expect(sessions, hasLength(2));

        pretuner.dispose();
        expect(sessions.every((session) => session.discarded), isTrue);
        expect(pretuner.take('ch-1'), isNull);
      });
    });

    test('a pre-tuned zap skips the session-start round trip', () {
      fakeAsync((async) {
        // The session negotiation costs 250 ms per zap on the cold path.
        final pretuner = LiveChannelPretuner(
          startSession: (channel) async {
            await Future<void>.delayed(const Duration(milliseconds: 250));
            return _FakeSession('http://example.invalid/${channel.key}.m3u8');
          },
          resolveUrl: (session) => session.streamUrlAt(),
          discardSession: (session) => session.discard(),
          now: () => DateTime(2026, 1, 1).add(async.elapsed),
        );
        addTearDown(pretuner.dispose);

        pretuner.refresh(_channels(), 0);
        async.elapse(const Duration(milliseconds: 250));

        // The zap itself: take() is synchronous — no session start, no URL
        // resolution, no wait. The cold path would pay another 250 ms here.
        final elapsedBefore = async.elapsed;
        final entry = pretuner.take('ch-2');
        expect(entry, isNotNull);
        expect(entry!.streamUrl, 'http://example.invalid/ch-2.m3u8');
        expect(async.elapsed, elapsedBefore, reason: 'a pre-tuned zap must cost no time at all');
      });
    });

    test('a failed pre-tune never blocks the zap: the cold path still works', () {
      fakeAsync((async) {
        final pretuner = LiveChannelPretuner(
          startSession: (channel) async => throw StateError('session negotiation failed'),
          resolveUrl: (session) => session.streamUrlAt(),
          discardSession: (session) => session.discard(),
          now: () => DateTime(2026, 1, 1).add(async.elapsed),
        );
        addTearDown(pretuner.dispose);

        pretuner.refresh(_channels(), 0);
        async.flushMicrotasks();

        expect(pretuner.take('ch-2'), isNull, reason: 'no entry: the zap falls back to a cold start');
      });
    });
  });
}
