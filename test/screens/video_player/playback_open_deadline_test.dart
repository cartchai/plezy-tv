import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/screens/video_player/playback_open_deadline.dart';
import 'package:plezy/services/playback_open_outcome.dart';

/// A player whose load-scoped streams the test drives directly. [close] ends
/// every stream at once, like a disposed player closing its controllers.
/// (Same shape as the harness in test/services/playback_open_outcome_test.dart.)
class _StreamPlayer implements Player {
  final started = StreamController<void>.broadcast();
  final primaryReady = StreamController<void>.broadcast();
  final loaded = StreamController<void>.broadcast();
  final restarted = StreamController<void>.broadcast();
  final failed = StreamController<void>.broadcast();
  final switched = StreamController<void>.broadcast();
  final progress = StreamController<void>.broadcast();

  @override
  late final PlayerStreams streams = PlayerStreams(
    playing: const Stream.empty(),
    completed: const Stream.empty(),
    buffering: const Stream.empty(),
    position: const Stream.empty(),
    duration: const Stream.empty(),
    seekable: const Stream.empty(),
    buffer: const Stream.empty(),
    volume: const Stream.empty(),
    rate: const Stream.empty(),
    tracks: const Stream.empty(),
    track: const Stream.empty(),
    log: const Stream.empty(),
    error: const Stream.empty(),
    audioDevice: const Stream.empty(),
    audioDevices: const Stream.empty(),
    bufferRanges: const Stream.empty(),
    playbackRestart: restarted.stream,
    fileStarted: started.stream,
    fileLoaded: loaded.stream,
    fileLoadFailed: failed.stream,
    primaryMediaReady: primaryReady.stream,
    demuxerProgress: progress.stream,
    backendSwitched: switched.stream,
  );

  Future<void> close() => Future.wait([
    started.close(),
    primaryReady.close(),
    loaded.close(),
    restarted.close(),
    failed.close(),
    switched.close(),
    progress.close(),
  ]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('openDeadlineFor', () {
    test('live TV gives up in 10 seconds, not 30', () {
      // A dead channel held the spinner for half a minute (audit finding #2).
      // Ten seconds is the live budget: long enough for a slow HLS playlist
      // fetch and demux, short enough that a dead channel surfaces promptly.
      expect(openDeadlineFor(isLive: true), const Duration(seconds: 10));
    });

    test('on-demand playback keeps the 30 second budget', () {
      // VOD opens negotiate and buffer more before the first frame; the
      // 30 s budget stays.
      expect(openDeadlineFor(isLive: false), const Duration(seconds: 30));
    });
  });

  group('deadline timing', () {
    test('a live load with no progress after file-started fails at 10 s', () {
      fakeAsync((async) {
        final player = _StreamPlayer();
        var fired = false;
        final outcome = PlaybackOpenOutcome.armForTesting(
          player,
          deadline: openDeadlineFor(isLive: true),
          onDeadline: () => fired = true,
        );
        addTearDown(() {
          outcome.abort('test done');
          player.close();
        });

        // The load started, then stopped moving: no file-loaded, no demuxer
        // progress, no failure, no death.
        player.started.add(null);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 9));
        expect(fired, isFalse, reason: 'the live deadline must not fire early');

        async.elapse(const Duration(seconds: 1));
        expect(fired, isTrue, reason: 'a dead live channel must surface at 10 s, not 30 s');
      });
    });

    test('an on-demand load with no progress is still given 30 s', () {
      fakeAsync((async) {
        final player = _StreamPlayer();
        var fired = false;
        final outcome = PlaybackOpenOutcome.armForTesting(
          player,
          deadline: openDeadlineFor(isLive: false),
          onDeadline: () => fired = true,
        );
        addTearDown(() {
          outcome.abort('test done');
          player.close();
        });

        player.started.add(null);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 10));
        expect(fired, isFalse, reason: 'the VOD deadline must not fire at the live budget');

        async.elapse(const Duration(seconds: 20));
        expect(fired, isTrue, reason: 'a dead VOD open still fails, at 30 s');
      });
    });
  });
}
