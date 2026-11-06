import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/livetv_capture_buffer.dart';
import 'package:plezy/screens/video_player/live_tv_session_args.dart';

/// Unit tests for the catch-up offset behind the guide's "No information"
/// hour blocks (build #6, Task G): the player starts the archive at the
/// block's own start time. Pure function — no player pump needed.
void main() {
  // A 24-hour archive: the session started at `now`, seekable back a day.
  const nowEpoch = 1_800_000_000;
  const buffer = CaptureBuffer(
    startedAt: 1800000000.0,
    seekStartSeconds: -86400,
    seekEndSeconds: 0,
  );

  test('returns null with no catch-up start requested', () {
    expect(
      liveTvCatchUpOffsetSeconds(catchUpStartEpoch: null, captureBuffer: buffer, nowEpoch: nowEpoch),
      isNull,
    );
  });

  test('returns null with no archive buffer', () {
    expect(
      liveTvCatchUpOffsetSeconds(
        catchUpStartEpoch: nowEpoch - 3600,
        captureBuffer: null,
        nowEpoch: nowEpoch,
      ),
      isNull,
    );
  });

  test('offset is the block start relative to now (negative, into the past)', () {
    expect(
      liveTvCatchUpOffsetSeconds(
        catchUpStartEpoch: nowEpoch - 3600,
        captureBuffer: buffer,
        nowEpoch: nowEpoch,
      ),
      -3600,
    );
  });

  test('returns null for a start at or after the live edge', () {
    expect(
      liveTvCatchUpOffsetSeconds(
        catchUpStartEpoch: nowEpoch,
        captureBuffer: buffer,
        nowEpoch: nowEpoch,
      ),
      isNull,
    );
    expect(
      liveTvCatchUpOffsetSeconds(
        catchUpStartEpoch: nowEpoch + 600,
        captureBuffer: buffer,
        nowEpoch: nowEpoch,
      ),
      isNull,
    );
  });

  test('clamps a start older than the archive to the oldest seekable point', () {
    expect(
      liveTvCatchUpOffsetSeconds(
        catchUpStartEpoch: nowEpoch - 90000,
        captureBuffer: buffer,
        nowEpoch: nowEpoch,
      ),
      -86400,
    );
  });
}
