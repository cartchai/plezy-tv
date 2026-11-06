import '../models/livetv_program.dart';

/// The current scrub block for live TV (build #9 Task 3 refinement — Matt:
/// the scrubber "covers either the hour block for no information segments
/// or the block for whatever show, so that you can scrub around for what
/// that time slot in that block should be").
///
/// - A programme covering [now] → its own block ([beginsAt], [endsAt]).
/// - Nothing covering [now] — no EPG, a gap between programmes, or an
///   open-ended programme — → the current clock-hour block, the same hour
///   the guide renders as "No information available".
///
/// The block is the RANGE the scrubber shows, not the seekable window:
/// the player still clamps seeks to the capture buffer (archive → now),
/// so dragging past the live edge inside a still-airing block lands on
/// live, never in the future.
({int startEpoch, int endEpoch}) liveScrubBlock(List<LiveTvProgram> programs, DateTime now) {
  final nowEpoch = now.millisecondsSinceEpoch ~/ 1000;
  for (final program in programs) {
    final beginsAt = program.beginsAt;
    final endsAt = program.endsAt;
    if (beginsAt == null || endsAt == null) continue;
    if (nowEpoch >= beginsAt && nowEpoch < endsAt) {
      return (startEpoch: beginsAt, endEpoch: endsAt);
    }
  }
  final hourStart = DateTime(now.year, now.month, now.day, now.hour);
  final startEpoch = hourStart.millisecondsSinceEpoch ~/ 1000;
  return (startEpoch: startEpoch, endEpoch: startEpoch + 3600);
}
