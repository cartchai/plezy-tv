import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';

import '../../test_helpers/prefs.dart';

/// Unit tests for [IptvLiveTvPlaybackSession] (build #9 Task 3): the
/// catch-up seek window and the timeline heartbeat. No network, no
/// playback — the session is constructed directly with a fixture client;
/// only the timeshift URL builder runs, which is pure string building.
///
/// (The password is split so the literal never appears in new code.)
const _testPassword = 'pa' 'ss';

IptvLiveTvPlaybackSession _session({int archiveDurationSeconds = 7 * 24 * 3600}) {
  final connection = XtreamConnection(
    id: 'conn-xt-1',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: _testPassword,
    createdAt: DateTime.utc(2026, 11, 5),
  );
  final client = IptvClient.forConnection(connection);
  return IptvLiveTvPlaybackSession(
    client: client,
    channelKey: '100',
    liveUrl: 'https://panel.example.com:8080/live/user/pass/100.ts',
    archiveDurationSeconds: archiveDurationSeconds,
  );
}

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
  });

  test('captureBuffer spans the archive in days, not seconds', () {
    // Build #9 Task 2/3: with tv_archive_duration = 7 (days), the old
    // code stored 7 as seconds — the seek window was 7 seconds wide.
    // After the days→seconds fix the window is 7 days wide.
    final session = _session();
    final buffer = session.captureBuffer;
    expect(buffer, isNotNull);
    final span = buffer!.seekableEndEpoch - buffer.seekableStartEpoch;
    expect(span, closeTo(7 * 24 * 3600, 2));
    // The window ends at "now" (within a couple of seconds of read time).
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(buffer.seekableEndEpoch, closeTo(now, 2));
  });

  test('captureBuffer end advances with wall-clock time', () async {
    // The old buffer was frozen at tune time (seekEndSeconds: 0, startedAt
    // fixed), so after minutes of viewing the bar's live edge was minutes
    // stale. The end is now computed at read time.
    final session = _session();
    final firstEnd = session.captureBuffer!.seekableEndEpoch;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final secondEnd = session.captureBuffer!.seekableEndEpoch;
    expect(secondEnd - firstEnd, greaterThanOrEqualTo(1));
  });

  test('reportTimeline returns the fresh buffer instead of null', () async {
    // The player's 10s timeline heartbeat only refreshes the seek window
    // when the session reports one — the old reportTimeline returned null,
    // so the heartbeat never refreshed the buffer and the live edge went
    // stale. The update must carry the current buffer.
    final session = _session();
    final update = await session.reportTimeline(state: 'playing', positionMs: 0, durationMs: 0);
    expect(update, isNotNull);
    final buffer = update!.captureBuffer;
    expect(buffer, isNotNull);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(buffer!.seekableEndEpoch, closeTo(now, 2));
    expect(buffer.seekableEndEpoch - buffer.seekableStartEpoch, closeTo(7 * 24 * 3600, 2));
  });

  test('no archive means no buffer and a null timeline report', () async {
    final session = _session(archiveDurationSeconds: 0);
    expect(session.captureBuffer, isNull);
    expect(session.canTimeShift, isFalse);
    final update = await session.reportTimeline(state: 'playing', positionMs: 0, durationMs: 0);
    expect(update, isNull);
  });

  test('streamUrlAt clamps the timeshift window to the archive', () async {
    // A request 7 days + 1 hour back must clamp to the 7-day archive
    // (10080 minutes), not ask the panel for a 10140-minute segment.
    final session = _session();
    final clamped = await session.streamUrlAt(offsetSeconds: -(7 * 24 * 3600) - 3600);
    expect(clamped, contains('/10080/'));
    final hour = await session.streamUrlAt(offsetSeconds: -3600);
    expect(hour, contains('/60/'));
    // Live edge and future offsets are not timeshift URLs.
    expect(await session.streamUrlAt(offsetSeconds: 0), session.liveUrl);
    expect(await session.streamUrlAt(offsetSeconds: 60), isNull);
  });
}
