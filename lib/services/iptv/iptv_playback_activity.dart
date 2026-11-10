import 'dart:async';

import 'package:flutter/foundation.dart';

/// Whether a stream is currently playing (build #28).
///
/// Background panel work — the weekly catalog sync, the catalog
/// background refresh, the whole-guide (`xmltv.php`) download — must not
/// run while a stream is playing: on a one-connection line it stacks on
/// top of the viewing traffic and tips a borderline account over the
/// flood threshold. OwnTV's rule, which its workers follow literally
/// (`awaitIdle()` before running; the backfill drain pauses while a
/// `WatchSession` is active).
///
/// The full player screen marks playing at its first rendered frame and
/// idle when it leaves (dispose / fatal error); the mini-player marks
/// playing while its tune is active and idle when it stops. Background
/// work checks [isPlaying] before starting, and [waitForIdle] when it
/// has already started — a sync that began before playback pauses
/// between catalog types and resumes when playback stops, instead of
/// being abandoned mid-sync.
class IptvPlaybackActivity {
  IptvPlaybackActivity();

  static IptvPlaybackActivity? _instance;

  /// The app-wide activity signal. The UI and the background workers
  /// share it.
  static IptvPlaybackActivity get instance => _instance ??= IptvPlaybackActivity();

  @visibleForTesting
  static void debugResetInstance() => _instance = null;

  /// True while a stream is playing. Listened to by background work
  /// waiting for idle.
  final ValueNotifier<bool> isPlayingNotifier = ValueNotifier(false);

  bool get isPlaying => isPlayingNotifier.value;

  void markPlaying() => isPlayingNotifier.value = true;

  void markIdle() => isPlayingNotifier.value = false;

  /// Completes when no stream is playing — immediately when already
  /// idle, otherwise when the next [markIdle] lands. Every waiter
  /// completes; a waiter added while idle never waits.
  Future<void> waitForIdle() {
    if (!isPlaying) return Future.value();
    final completer = Completer<void>();
    void listener() {
      if (!isPlayingNotifier.value && !completer.isCompleted) completer.complete();
    }

    isPlayingNotifier.addListener(listener);
    if (!isPlaying) {
      isPlayingNotifier.removeListener(listener);
      return Future.value();
    }
    return completer.future.whenComplete(() => isPlayingNotifier.removeListener(listener));
  }
}
