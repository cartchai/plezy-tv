import '../../models/livetv_capture_buffer.dart';
import '../../models/livetv_channel.dart';

/// Launch parameters for a live TV session — pure UX data. A
/// [VideoPlayerScreen] plays live TV iff it was constructed with one of
/// these.
///
/// Transport (tune/stream-URL resolution, session identity) is no longer
/// passed in: the player starts a backend-neutral `LiveTvPlaybackSession`
/// via `client.liveTv.startPlayback` itself, for both backends, so launch
/// and channel zapping share one resolution path and one spinner UX.
/// How to start a channel that already has recorded history (an in-progress
/// DVR recording or an existing capture session).
enum LiveTvStartPosition {
  /// Ask the user whether to start from the beginning or join live.
  ask,

  /// Start from the beginning of the current program without asking.
  beginning,

  /// Join at the live edge without asking.
  live,
}

/// Offset (seconds from the session's capture-buffer origin) that starts
/// playback at [catchUpStartEpoch] — the block start of a "No information"
/// guide placeholder — or null when catch-up does not apply: no start was
/// requested, the session has no archive buffer, or the start is at/after
/// the live edge. The offset is clamped into the archive window, so a start
/// older than the archive begins at the oldest available point instead of
/// failing. Pure function, unit-tested.
int? liveTvCatchUpOffsetSeconds({
  required int? catchUpStartEpoch,
  required CaptureBuffer? captureBuffer,
  required int nowEpoch,
}) {
  if (catchUpStartEpoch == null || captureBuffer == null) return null;
  var offset = catchUpStartEpoch - nowEpoch;
  if (offset >= 0) return null;
  final minOffset = captureBuffer.seekStartSeconds.round();
  if (offset < minOffset) offset = minOffset;
  return offset;
}

class LiveTvSessionArgs {
  /// The channel to start on.
  final LiveTvChannel channel;

  /// Full channel list for channel up/down navigation.
  final List<LiveTvChannel>? channels;

  /// Index of [channel] within [channels] (-1 / null when unknown).
  final int? currentChannelIndex;

  /// How to handle recorded history on the first tune. Channel zaps inside
  /// the player always ask.
  final LiveTvStartPosition startPosition;

  /// Catch-up start (epoch seconds) for a "No information" guide
  /// placeholder: the player opens the archive at this time instead of the
  /// live edge. Null for a normal tune. Only set for channels that offer
  /// catch-up; the player ignores it when the session cannot time-shift.
  final int? catchUpStartEpoch;

  const LiveTvSessionArgs({
    required this.channel,
    this.channels,
    this.currentChannelIndex,
    this.startPosition = LiveTvStartPosition.ask,
    this.catchUpStartEpoch,
  });
}
