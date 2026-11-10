import '../../mpv/models.dart';

/// Highest fallback level the live-TV ladder will climb before giving up.
const int maxLiveFallbackLevel = 2;

/// What the player screen should do about one playback error.
enum PlaybackFailureAction {
  /// Server refused this account or connection with HTTP 403.
  playbackNotAllowedDialog,

  /// Server rejected the session with HTTP 500 — a bandwidth/transcoding limit.
  serverLimitDialog,

  /// Server could not read the file behind the item (HTTP 404).
  mediaUnreadableDialog,

  /// Server kept refusing the stream with HTTP 503 for the whole open phase.
  serverBusyDialog,

  /// A live retry already owns the player and its error UI.
  ignore,

  /// Climb one rung of the live-TV fallback ladder.
  liveRetry,

  /// Live ladder is exhausted and its last retry failed.
  liveInterrupted,

  /// Re-open the stream once after a backoff: a transient refusal (429)
  /// deserves one retry before the terminal path. The failure view stays
  /// down until the retry also fails, so the viewer never sees a flash of
  /// the error for a failure the retry clears. 403 is never retried (build
  /// #28): a refusal of this account or connection re-hit reads as an
  /// attack — refused panel calls count toward the flood limit — and no
  /// careful peer retries one.
  retryTransient,

  /// Show the raw player error and leave the route.
  fatal,
}

/// How many automatic transient retries one open gets. One: a second retry
/// would only re-knock on a door the panel already refused twice.
const int maxTransientPlaybackRetries = 1;

/// The wait before the one automatic transient retry. Short on purpose: the
/// panel asked the client to wait, and a second is enough for a rate-limit
/// window to clear without leaving the viewer on a spinner.
const Duration transientRetryBackoff = Duration(seconds: 1);

/// The wait before a live-ladder retry at [fallbackLevel]. A panel that just
/// refused the stream (403/429) needs a beat to recover, and an immediate
/// re-open reads as another knock on a closed door. Level 1 waits 1 s, level
/// 2 (the ladder's last rung) waits 2 s.
Duration liveRetryBackoff(int fallbackLevel) =>
    fallbackLevel <= 1 ? const Duration(seconds: 1) : const Duration(seconds: 2);

/// Whether a playback restart refills the live ladder (build #28). A restart
/// proves the current ladder level works — unless the restart follows a
/// refusal: a refused stream must never be re-opened again after any
/// restart, so a 403 latched on the dead open keeps the ladder spent.
bool shouldRefillLiveLadderAfterRestart(Set<int> fatalHttpStatuses) =>
    !fatalHttpStatuses.contains(403);

/// Decides what [cause] plus the statuses seen on this open mean for playback.
///
/// Pure so the policy is testable without a live player screen, mirroring
/// [runLiveStreamRetry]. [fatalHttpStatuses] is the set of
/// [fatalPlaybackHttpStatuses] entries the player's log stream reported.
///
/// Live TV deliberately diverges on 404: an HLS segment that has rolled off the
/// playlist, or a transcode session restarting under us, answers 404 mid-stream,
/// and the bounded ladder exists to ride that out. Only on-demand playback
/// treats 404 as terminal, where it does mean the file is unreadable. 403 is
/// terminal for both (build #28): a refusal of this account or connection is
/// not something a retry clears — re-hitting it reads as an attack, and the
/// panel's flood filter counts refused requests. It outranks every other
/// status latched on the same open — until the server lets this account
/// stream, what it says about the file or session is moot. 500 stays terminal
/// for both — a limit rejection is not something a retry clears. 503 arrives
/// only as the open-phase watchdog's cause tag (it never latches into
/// [fatalHttpStatuses]); by then the reconnect loop has had its chances, so
/// on-demand playback surfaces it while live TV keeps its ladder.
///
/// An audio-output failure is checked first: the device stopped taking audio,
/// so a latched status or the live ladder would only re-open a stream into the
/// same dead output.
///
/// A transient refusal gets one bounded retry before the terminal path — but
/// only on-demand, and only for 429. Live TV already rides its fallback
/// ladder, which owns retries (with backoff) there. 429 is the transient
/// case proper — the panel asking the client to wait, not refusing the
/// account — and it is never latched as fatal, so with the budget spent it
/// falls through to the raw error below. 458 stays ladder-eligible on live
/// TV: it is the transient line-busy signal ("458 is TRANSIENT" — a slot
/// that has not cleared yet), and the ladder's backoff gives the ghost slot
/// time to expire, so a retry after the wait can succeed where a 403 retry
/// never could.
///
/// [PlayerError.openTimedOut] and [PlayerError.streamInitFailed] name no
/// status and no device fault, so they take the default path like any other
/// failed open: live TV climbs its ladder (a different stream may well decode),
/// on-demand playback is fatal.
PlaybackFailureAction resolvePlaybackFailureAction({
  required String? cause,
  required Set<int> fatalHttpStatuses,
  Set<int> transientHttpStatuses = const <int>{},
  int transientRetryAttempts = 0,
  required bool isLive,
  required bool liveRetrying,
  required int liveFallbackLevel,
  required bool liveRetryFailed,
}) {
  if (cause == PlayerError.audioOutputFailed) return PlaybackFailureAction.fatal;

  // Build #28: a 403 is a refusal of this account or connection — never a
  // retry, on-demand or live. Re-hitting a refusal reads as an attack
  // (refused panel calls count toward the flood limit), so the stream goes
  // straight to the access-denied dialog, never "offline", with no re-open.
  if (fatalHttpStatuses.contains(403)) return PlaybackFailureAction.playbackNotAllowedDialog;

  if (!isLive && transientRetryAttempts < maxTransientPlaybackRetries && transientHttpStatuses.contains(429)) {
    return PlaybackFailureAction.retryTransient;
  }

  if (cause == PlayerError.serverHttp500 || fatalHttpStatuses.contains(500)) {
    return PlaybackFailureAction.serverLimitDialog;
  }

  if (!isLive && (cause == PlayerError.serverHttp404 || fatalHttpStatuses.contains(404))) {
    return PlaybackFailureAction.mediaUnreadableDialog;
  }

  if (!isLive && cause == PlayerError.serverHttp503) {
    return PlaybackFailureAction.serverBusyDialog;
  }

  if (isLive) {
    if (liveRetrying) return PlaybackFailureAction.ignore;
    if (liveFallbackLevel < maxLiveFallbackLevel) return PlaybackFailureAction.liveRetry;
    if (liveRetryFailed) return PlaybackFailureAction.liveInterrupted;
  }

  return PlaybackFailureAction.fatal;
}
