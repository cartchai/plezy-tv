import 'package:flutter/gestures.dart';

/// Converts pointer-scroll events (Quest thumbstick ticks / mouse wheel)
/// into selection moves on the TV Discover rail.
///
/// The rail's vertical list is `NeverScrollableScrollPhysics` and moves
/// only when the selection changes, so a scroll event over Discover has no
/// consumer: the list rejects it and the rows scroll directly without
/// moving the selection or the spotlight. This bridge is the missing
/// consumer — scoped to the rail only, because every other TV screen is a
/// real scrollable where the event should scroll directly.
///
/// Accumulator shape copied from [AppleTvRemoteTouchService]
/// (`lib/services/apple_tv_remote_touch_service.dart`):
/// - per-axis progress against thresholds derived from the focused item's
///   geometry (supplied by [stepThresholds]);
/// - a repeat cooldown after each step, with re-anchoring, so one sustained
///   thumbstick hold steps at a steady cadence instead of banking dozens of
///   moves from a single push;
/// - axis hysteresis, so incidental drift on the other axis does not
///   zig-zag an established direction.
///
/// One scroll event emits at most one step; the remainder is discarded
/// (re-anchored), like the touch service. Direction follows the scroll
/// delta: positive dy scrolls down the hubs, positive dx steps right
/// along the row.
class TvRailScrollBridge {
  TvRailScrollBridge({
    required this.onMoveHub,
    required this.onMoveItem,
    required this.stepThresholds,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Called with ±1 for a vertical (hub) step. Positive is down.
  final void Function(int delta) onMoveHub;

  /// Called with ±1 for a horizontal (item) step. Positive is right.
  final void Function(int delta) onMoveItem;

  /// Step travel per axis, in logical pixels, derived from the focused
  /// item's geometry. The caller supplies the geometry; non-finite or
  /// non-positive values disable stepping on that axis.
  final ({double horizontal, double vertical}) Function() stepThresholds;

  final DateTime Function() _now;

  /// Cooldown between steps, mirroring the touch service's repeat interval:
  /// travel during the cooldown never counts toward the next step.
  static const Duration stepCooldown = Duration(milliseconds: 60);

  /// How much more progress the other axis needs to take over mid-gesture.
  static const double axisSwitchDominanceRatio = 1.5;

  double _progressX = 0;
  double _progressY = 0;
  _BridgeAxis? _lastStepAxis;
  DateTime? _lastStepAt;

  /// Handles a pointer-signal event; ignores anything that is not a scroll
  /// event. Safe to call from a `Listener.onPointerSignal`.
  void handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final now = _now();
    final lastStepAt = _lastStepAt;
    if (lastStepAt != null && now.difference(lastStepAt) < stepCooldown) {
      // Travel during the repeat cooldown never counts toward the next
      // step: re-anchor (zero the accumulators) so a sustained hold's
      // deceleration tail is discarded instead of banked. A deliberate
      // continuous hold still repeats because it covers a fresh step
      // threshold after each cooldown expires.
      _progressX = 0;
      _progressY = 0;
      return;
    }
    _progressX += event.scrollDelta.dx;
    _progressY += event.scrollDelta.dy;
    final axis = _resolveAxis(stepThresholds());
    if (axis == null) return;
    if (axis == _BridgeAxis.vertical) {
      onMoveHub(_progressY.sign.toInt());
    } else {
      onMoveItem(_progressX.sign.toInt());
    }
    _progressX = 0;
    _progressY = 0;
    _lastStepAxis = axis;
    _lastStepAt = now;
  }

  /// Drops accumulated travel without touching the cooldown or the axis
  /// memory. Call when the selection moved through another path (D-pad,
  /// hover, click) so stale scroll progress cannot fire a step for a
  /// gesture that ended before that move.
  void discardPendingProgress() {
    _progressX = 0;
    _progressY = 0;
  }

  /// Full reset: progress, axis memory and cooldown.
  void reset() {
    discardPendingProgress();
    _lastStepAxis = null;
    _lastStepAt = null;
  }

  /// Resolves which axis, if any, covered a full step, with hysteresis so
  /// incidental drift does not zig-zag an established direction. Mirrors
  /// the touch service's `_resolveSwipeAxis`, simplified: scroll events
  /// re-anchor on every step, so total progress and segment progress are
  /// the same numbers.
  _BridgeAxis? _resolveAxis(({double horizontal, double vertical}) thresholds) {
    final progressX = _axisProgress(_progressX, thresholds.horizontal);
    final progressY = _axisProgress(_progressY, thresholds.vertical);
    if (progressX < 1 && progressY < 1) return null;

    final candidate = progressX >= progressY ? _BridgeAxis.horizontal : _BridgeAxis.vertical;
    final lastAxis = _lastStepAxis;
    if (lastAxis == null || candidate == lastAxis) return candidate;

    final candidateProgress = candidate == _BridgeAxis.horizontal ? progressX : progressY;
    final lastProgress = lastAxis == _BridgeAxis.horizontal ? progressX : progressY;
    if (candidateProgress >= lastProgress * axisSwitchDominanceRatio) return candidate;
    return lastProgress >= 1 ? lastAxis : null;
  }

  static double _axisProgress(double accumulated, double threshold) {
    if (!threshold.isFinite || threshold <= 0) return 0;
    return accumulated.abs() / threshold;
  }
}

enum _BridgeAxis { horizontal, vertical }
