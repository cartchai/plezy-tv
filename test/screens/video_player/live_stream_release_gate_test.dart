import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player/live_stream_release_gate.dart';

/// Wait-for-release barrier (build #28): on a one-connection panel the old
/// stream's slot is still counted until its socket dies, so the next open
/// must wait for the previous stream's release (bounded) instead of
/// stacking two streams on the only session (HTTP 458). OwnTV's shape:
/// a barrier queued behind the player's stop, bounded by a 1,500 ms cap.
void main() {
  group('LiveStreamReleaseGate', () {
    test('release awaits the stop before returning', () async {
      final gate = LiveStreamReleaseGate();
      var stopped = false;
      final stopStarted = Completer<void>();
      final allowStop = Completer<void>();
      final releaseDone = Completer<void>();
      unawaited(
        gate
            .release(() async {
              stopStarted.complete();
              await allowStop.future;
              stopped = true;
            })
            .then((_) => releaseDone.complete()),
      );
      await stopStarted.future;
      expect(stopped, isFalse, reason: 'the release must not return before the stop completes');
      expect(releaseDone.isCompleted, isFalse);
      allowStop.complete();
      await releaseDone.future;
      expect(stopped, isTrue);
    });

    test('release proceeds after the cap when the stop never completes', () async {
      final gate = LiveStreamReleaseGate(releaseTimeout: const Duration(milliseconds: 100));
      final started = DateTime.now();
      // A stop that never completes: the zap must not hang on it.
      await gate.release(() => Completer<void>().future);
      final elapsed = DateTime.now().difference(started);
      expect(elapsed.inMilliseconds, greaterThanOrEqualTo(90), reason: 'the cap bounds the wait');
      expect(elapsed.inMilliseconds, lessThan(5000), reason: 'the cap must fire, not hang');
    });

    test('release swallows a stop error: a failed stop never blocks the next open', () async {
      final gate = LiveStreamReleaseGate();
      await gate.release(() => Future<void>.error(StateError('stop failed')));
      // Returns normally: no throw.
    });

    test('release swallows a stop that throws synchronously', () async {
      final gate = LiveStreamReleaseGate();
      await gate.release(() => throw StateError('stop threw'));
      // Returns normally: no throw.
    });

    test('waitForRelease returns immediately when nothing is in flight', () async {
      final gate = LiveStreamReleaseGate();
      await gate.waitForRelease();
      // Returns normally and immediately.
    });

    test('waitForRelease awaits a release already in flight', () async {
      final gate = LiveStreamReleaseGate();
      final stopStarted = Completer<void>();
      final allowStop = Completer<void>();
      var stopped = false;
      final releaseFuture = gate.release(() async {
        stopStarted.complete();
        await allowStop.future;
        stopped = true;
      });
      await stopStarted.future;
      var waited = false;
      final waitFuture = gate.waitForRelease().then((_) => waited = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(waited, isFalse, reason: 'the wait must not return before the in-flight stop completes');
      allowStop.complete();
      await releaseFuture;
      await waitFuture;
      expect(stopped, isTrue);
      expect(waited, isTrue);
    });

    test('a second release waits for the first instead of double-stopping', () async {
      final gate = LiveStreamReleaseGate();
      final order = <String>[];
      final allowFirst = Completer<void>();
      final first = gate.release(() async {
        order.add('first-stop');
        await allowFirst.future;
        order.add('first-done');
      });
      // Give the first release a chance to start its stop.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      var secondStarted = false;
      final second = gate.release(() async {
        secondStarted = true;
        order.add('second-stop');
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(secondStarted, isFalse, reason: 'the second release must queue behind the first');
      allowFirst.complete();
      await first;
      await second;
      expect(order, ['first-stop', 'first-done', 'second-stop']);
    });
  });
}
