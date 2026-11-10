import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/screens/video_player/playback_failure_action.dart';

PlaybackFailureAction resolve({
  String? cause,
  Set<int> statuses = const <int>{},
  Set<int> transientStatuses = const <int>{},
  int transientAttempts = 0,
  bool isLive = false,
  bool liveRetrying = false,
  int liveFallbackLevel = 0,
  bool liveRetryFailed = false,
}) {
  return resolvePlaybackFailureAction(
    cause: cause,
    fatalHttpStatuses: statuses,
    transientHttpStatuses: transientStatuses,
    transientRetryAttempts: transientAttempts,
    isLive: isLive,
    liveRetrying: liveRetrying,
    liveFallbackLevel: liveFallbackLevel,
    liveRetryFailed: liveRetryFailed,
  );
}

void main() {
  group('transient retry (build #24)', () {
    test('429 is a transient status, never a fatal one', () {
      expect(transientPlaybackHttpStatuses, contains(429));
      expect(fatalPlaybackHttpStatuses, isNot(contains(429)));
    });

    test('on-demand 429 retries once with backoff instead of failing', () {
      expect(
        resolve(transientStatuses: {429}),
        PlaybackFailureAction.retryTransient,
        reason: 'a rate limit is the panel asking the client to wait, not a refusal',
      );
    });

    test('on-demand 403 goes straight to the not-allowed dialog, never retries', () {
      // Build #28: a 403 is a refusal of this account or connection, not a
      // transient failure — re-hitting it reads as an attack (refused
      // player_api.php calls count toward the panel's flood limit), and no
      // peer retries one. 429 stays the transient case.
      expect(resolve(statuses: {403}), PlaybackFailureAction.playbackNotAllowedDialog);
      expect(
        resolve(statuses: {403}, transientAttempts: maxTransientPlaybackRetries),
        PlaybackFailureAction.playbackNotAllowedDialog,
        reason: 'a persistent 403 still surfaces as access-denied, not offline',
      );
    });

    test('a 403 outranks a co-latched 404 or 500 for the dialog', () {
      expect(resolve(statuses: {403, 404}), PlaybackFailureAction.playbackNotAllowedDialog);
      expect(resolve(statuses: {403, 500}), PlaybackFailureAction.playbackNotAllowedDialog);
      expect(
        resolve(statuses: {403, 500}, transientAttempts: maxTransientPlaybackRetries),
        PlaybackFailureAction.playbackNotAllowedDialog,
      );
    });

    test('a 429 with the budget spent is fatal, with no dialog of its own', () {
      expect(
        resolve(transientStatuses: {429}, transientAttempts: maxTransientPlaybackRetries),
        PlaybackFailureAction.fatal,
      );
    });

    test('a 500 alone never retries: a limit rejection is not cleared by one', () {
      expect(resolve(statuses: {500}), PlaybackFailureAction.serverLimitDialog);
      expect(resolve(statuses: {404}), PlaybackFailureAction.mediaUnreadableDialog);
    });

    test('live TV keeps its ladder for transient failures — but never for a 403', () {
      // Build #28: a refused live stream goes terminal (access-denied
      // dialog) with no re-open; the ladder only rides out transient
      // failures (429, a rolled-off segment's 404, a failed open).
      expect(resolve(statuses: {403}, isLive: true), PlaybackFailureAction.playbackNotAllowedDialog);
      expect(resolve(transientStatuses: {429}, isLive: true), PlaybackFailureAction.liveRetry);
    });
  });

  group('retry backoff', () {
    test('the transient retry waits one second', () {
      expect(transientRetryBackoff, const Duration(seconds: 1));
      expect(maxTransientPlaybackRetries, 1, reason: 'one automatic retry per open, then the terminal path');
    });

    test('the live ladder backs off 1 s, then 2 s', () {
      expect(liveRetryBackoff(1), const Duration(seconds: 1));
      expect(liveRetryBackoff(2), const Duration(seconds: 2));
      expect(liveRetryBackoff(3), const Duration(seconds: 2), reason: 'the ladder is capped at two levels');
    });
  });

  group('ladder refill after a playback restart (build #28)', () {
    test('a restart after a 403 does not refill the ladder', () {
      // A refused stream cannot be re-opened again after any restart: the
      // ladder refill that proves "this level works" only applies when the
      // restart was not preceded by a refusal.
      expect(shouldRefillLiveLadderAfterRestart({403}), isFalse);
      expect(shouldRefillLiveLadderAfterRestart({403, 404}), isFalse);
    });

    test('a restart without a refusal refills the ladder', () {
      expect(shouldRefillLiveLadderAfterRestart(const {}), isTrue);
      expect(
        shouldRefillLiveLadderAfterRestart({404}),
        isTrue,
        reason: 'live TV deliberately climbs its ladder on a 404 (a segment rolled off)',
      );
      expect(shouldRefillLiveLadderAfterRestart({500}), isTrue);
    });
  });
}
