import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player/live_zap_debouncer.dart';

/// Zap debounce (build #28, OwnTV's shape): 500 ms wait on rapid presses,
/// 0 ms for isolated presses — rapid presses collapse into one tune instead
/// of one tune per press, so a held key cannot open a stream per step on a
/// one-connection panel (OwnTV measured thirteen streams in 3.6 s).
class _FakeTimer implements Timer {
  _FakeTimer(this._callback);

  final void Function() _callback;
  bool _cancelled = false;

  @override
  void cancel() => _cancelled = true;

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;

  void fire() {
    if (_cancelled) return;
    _cancelled = true;
    _callback();
  }
}

void main() {
  group('LiveZapDebouncer', () {
    late DateTime now;
    late List<_FakeTimer> timers;
    late List<int> executed;

    setUp(() {
      now = DateTime(2026, 11, 10, 8, 0, 0);
      timers = <_FakeTimer>[];
      executed = <int>[];
    });

    LiveZapDebouncer debouncer() => LiveZapDebouncer(
      delay: const Duration(milliseconds: 500),
      now: () => now,
      timerFactory: (duration, callback) {
        final timer = _FakeTimer(callback);
        timers.add(timer);
        return timer;
      },
      onExecute: (delta) => executed.add(delta),
    );

    test('an isolated press executes immediately', () {
      final d = debouncer();
      d.request(1);
      expect(executed, [1]);
      expect(timers, isEmpty, reason: 'no timer for an isolated press');
    });

    test('a rapid second press is deferred, not executed', () {
      final d = debouncer();
      d.request(1);
      expect(executed, [1]);
      now = now.add(const Duration(milliseconds: 100));
      d.request(1);
      expect(executed, [1], reason: 'the rapid press must not tune immediately');
      expect(timers, hasLength(1));
    });

    test('rapid presses collapse into one tune with the accumulated delta', () {
      final d = debouncer();
      d.request(1);
      now = now.add(const Duration(milliseconds: 100));
      d.request(1);
      now = now.add(const Duration(milliseconds: 100));
      d.request(1);
      expect(executed, [1]);
      expect(timers, hasLength(2), reason: 'each rapid press cancels the old timer and starts a new one');
      expect(timers.first.isActive, isFalse, reason: 'the superseded timer never fires');
      expect(timers.last.isActive, isTrue);
      timers.last.fire();
      expect(executed, [1, 2], reason: '+1 +1 collapses to one tune of +2');
    });

    test('a net-zero burst tunes nothing', () {
      final d = debouncer();
      d.request(1);
      now = now.add(const Duration(milliseconds: 100));
      d.request(1);
      now = now.add(const Duration(milliseconds: 100));
      d.request(-1);
      timers.last.fire();
      expect(executed, [1], reason: 'up then down nets zero — re-opening the channel already playing is not a tune');
    });

    test('a net-zero burst fires onDrop so waiting callers are released', () {
      var dropped = 0;
      final d = LiveZapDebouncer(
        delay: const Duration(milliseconds: 500),
        now: () => now,
        timerFactory: (duration, callback) {
          final timer = _FakeTimer(callback);
          timers.add(timer);
          return timer;
        },
        onExecute: (delta) => executed.add(delta),
        onDrop: () => dropped++,
      );
      d.request(1);
      now = now.add(const Duration(milliseconds: 100));
      d.request(1);
      now = now.add(const Duration(milliseconds: 100));
      d.request(-1);
      timers.last.fire();
      expect(executed, [1]);
      expect(dropped, 1, reason: 'the dropped tune must release its callers instead of hanging them');
    });

    test('a press after the delay executes immediately again', () {
      final d = debouncer();
      d.request(1);
      now = now.add(const Duration(milliseconds: 600));
      d.request(-1);
      expect(executed, [1, -1]);
      expect(timers, isEmpty);
    });

    test('dispose cancels the pending tune', () {
      final d = debouncer();
      d.request(1);
      now = now.add(const Duration(milliseconds: 100));
      d.request(1);
      expect(timers, hasLength(1));
      d.dispose();
      timers.single.fire();
      expect(executed, [1], reason: 'the disposed debouncer must not tune');
    });
  });
}
