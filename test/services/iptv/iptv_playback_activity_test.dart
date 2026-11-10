
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';

/// Playback-activity signal (build #28): background panel work (catalog
/// sync, catalog refresh, the whole-guide download) must not run while a
/// stream is playing — it waits for idle instead, like OwnTV's workers
/// (CatalogSyncWorker awaits idle before running).
void main() {
  group('IptvPlaybackActivity', () {
    late IptvPlaybackActivity activity;

    setUp(() {
      IptvPlaybackActivity.debugResetInstance();
      activity = IptvPlaybackActivity.instance;
    });

    tearDown(() {
      IptvPlaybackActivity.debugResetInstance();
    });

    test('starts idle', () {
      expect(activity.isPlaying, isFalse);
    });

    test('markPlaying / markIdle flip the signal', () {
      activity.markPlaying();
      expect(activity.isPlaying, isTrue);
      activity.markIdle();
      expect(activity.isPlaying, isFalse);
    });

    test('waitForIdle completes immediately when idle', () async {
      await activity.waitForIdle();
      // Returns without waiting.
    });

    test('waitForIdle completes when playback stops', () async {
      activity.markPlaying();
      var waited = false;
      final waiting = activity.waitForIdle().then((_) => waited = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(waited, isFalse, reason: 'the wait must not return while a stream is playing');
      activity.markIdle();
      await waiting;
      expect(waited, isTrue);
    });

    test('every waiter completes when playback stops', () async {
      activity.markPlaying();
      final first = activity.waitForIdle();
      final second = activity.waitForIdle();
      activity.markIdle();
      await Future.wait([first, second]);
      // Both complete: no waiter is left behind.
    });

    test('a wait started after idle returns immediately', () async {
      activity.markPlaying();
      activity.markIdle();
      await activity.waitForIdle();
    });
  });
}
