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

    test('on-demand 403 retries once before the not-allowed dialog', () {
      // PlezTV cannot tell a UA-block 403 from a transient 403, so one
      // bounded retry with backoff is the honest shape: it still ends in the
      // access-denied dialog when the refusal persists.
      expect(resolve(statuses: {403}), PlaybackFailureAction.retryTransient);
      expect(
        resolve(statuses: {403}, transientAttempts: maxTransientPlaybackRetries),
        PlaybackFailureAction.playbackNotAllowedDialog,
        reason: 'a persistent 403 still surfaces as access-denied, not offline',
      );
    });

    test('a 403 outranks a co-latched 404 or 500 for the retry too', () {
      expect(resolve(statuses: {403, 404}), PlaybackFailureAction.retryTransient);
      expect(resolve(statuses: {403, 500}), PlaybackFailureAction.retryTransient);
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

    test('live TV keeps its ladder: no transient branch pre-empts it', () {
      expect(resolve(statuses: {403}, isLive: true), PlaybackFailureAction.liveRetry);
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
}
