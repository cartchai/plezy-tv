import 'dart:async';

/// Zap debounce (build #28, OwnTV's shape).
///
/// A 500 ms wait on rapid presses, 0 ms for isolated presses: rapid
/// presses collapse into ONE tune instead of one tune per press, so a held
/// key cannot open a stream per step on a one-connection panel (OwnTV
/// measured thirteen streams in 3.6 s from tuning on every step of a held
/// key, and the panel locked the account for about two minutes). The
/// accumulated [delta] is the net channel move, so up-up-down collapses
/// to a single +1 tune.
///
/// The timer and the clock are injected so tests can drive them without
/// real time; production uses [Timer.new] and [DateTime.now].
class LiveZapDebouncer {
  LiveZapDebouncer({
    required this.onExecute,
    this.onDrop,
    this.delay = const Duration(milliseconds: 500),
    DateTime Function()? now,
    Timer Function(Duration duration, void Function() callback)? timerFactory,
  }) : _now = now ?? DateTime.now,
       _timerFactory = timerFactory ?? Timer.new;

  /// Fired once per tune with the net channel delta.
  final void Function(int totalDelta) onExecute;

  /// Fired when a pending tune is discarded because its net delta is
  /// zero (up then down): no tune runs, so callers waiting on the tune
  /// must be released. Build #28: without this, a caller awaiting a
  /// switch that collapses to nothing waits forever.
  final void Function()? onDrop;

  /// The rapid-press window (OwnTV: 500 ms; OpenTV: 350 ms).
  final Duration delay;

  final DateTime Function() _now;
  final Timer Function(Duration duration, void Function() callback) _timerFactory;

  DateTime? _lastExecutedAt;
  Timer? _timer;
  int _pendingDelta = 0;

  /// Whether a tune is waiting out the delay.
  bool get hasPending => _timer != null;

  /// Request a channel move of [delta]. An isolated press (no pending
  /// tune, and the last tune is at least [delay] old) executes at once;
  /// a rapid press accumulates into the pending tune and restarts the
  /// delay, so only the final net move tunes.
  void request(int delta) {
    final now = _now();
    if (_timer == null && (_lastExecutedAt == null || now.difference(_lastExecutedAt!) >= delay)) {
      _lastExecutedAt = now;
      onExecute(delta);
      return;
    }
    _pendingDelta += delta;
    _timer?.cancel();
    _timer = _timerFactory(delay, () {
      _timer = null;
      final total = _pendingDelta;
      _pendingDelta = 0;
      // A net-zero move (up then down) is no tune at all: executing it
      // would re-open the channel already playing. The last real tune
      // stays the reference for the next isolated-press check. Callers
      // waiting on the dropped tune are released via [onDrop].
      if (total == 0) {
        onDrop?.call();
        return;
      }
      _lastExecutedAt = _now();
      onExecute(total);
    });
  }

  /// Drop a pending tune (screen going away). A tune already executed is
  /// unaffected.
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pendingDelta = 0;
  }
}
