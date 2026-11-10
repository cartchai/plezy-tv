import 'dart:async';

/// Wait-for-release barrier (build #28).
///
/// On a one-connection panel the old stream's slot is still counted until
/// its socket dies, so opening the next stream before the old one is
/// released stacks two streams on the only session (HTTP 458) — OwnTV
/// measured exactly this on a real one-connection panel ("thirteen
/// streams in 3.6 s… locked the account for about two minutes") and fixed
/// it with a barrier queued behind the player's stop, bounded by a
/// 1,500 ms cap. No peer opens the next stream while the previous one is
/// still closing; PlezTV did, by design (the zap kept the old session
/// alive until the replacement was open).
///
/// The barrier is per player instance (the full player and the mini-player
/// each hold one): [release] stops the current stream and waits for the
/// release to complete, bounded by [releaseTimeout]; [waitForRelease]
/// lets any other open wait on a release already in flight, so no new
/// open can start while a previous stream's release is still in flight
/// (past the cap, the open proceeds anyway — the cap is the bound, not a
/// guarantee the panel has already reclaimed the slot).
///
/// A stop that fails — or throws — never blocks the next open: the zap
/// must degrade to the old behaviour, not hang on a dead player.
class LiveStreamReleaseGate {
  LiveStreamReleaseGate({this.releaseTimeout = const Duration(milliseconds: 1500)});

  /// OwnTV's cap (`MPV_RELEASE_TIMEOUT_MS = 1_500L`): the longest a zap
  /// waits for the old stream's socket to die before opening the next one.
  final Duration releaseTimeout;

  Future<void>? _inFlight;

  /// Stop the current stream (via [stop]) and wait for the release to
  /// complete, bounded by [releaseTimeout]. Releases serialize: a second
  /// call waits for the first instead of double-stopping — within the cap.
  /// Past the cap the wait times out and the second call runs stop() again
  /// while the first is still in flight (benign: the player's stop is
  /// idempotent, and the in-cap case is unit-tested).
  Future<void> release(Future<void> Function() stop) async {
    await waitForRelease();
    Future<void> stopping;
    try {
      stopping = stop();
    } catch (_) {
      // A stop that cannot even start must never block the next open.
      return;
    }
    _inFlight = stopping;
    try {
      await stopping.timeout(releaseTimeout);
    } on TimeoutException {
      // Cap hit: the old socket may still be closing, but the zap has
      // waited long enough — proceed so a slow stop cannot stall zapping.
    } catch (_) {
      // A failed stop must never block the next open.
    } finally {
      if (identical(_inFlight, stopping)) _inFlight = null;
    }
  }

  /// Wait for a release already in flight, bounded by [releaseTimeout].
  /// Returns immediately when no release is running.
  Future<void> waitForRelease() async {
    final inFlight = _inFlight;
    if (inFlight == null) return;
    try {
      await inFlight.timeout(releaseTimeout);
    } on TimeoutException {
      // Cap hit: the caller proceeds; the release continues in the
      // background and the next release() call still waits on it.
    } catch (_) {
      // A failed release is already settled for the waiter.
    }
  }
}
