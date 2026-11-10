import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/live_tv_support.dart';
import '../../models/livetv_channel.dart';
import '../../mpv/models.dart';
import '../../mpv/player/player.dart';
import '../../mpv/player/video_rect_support.dart';
import '../../mpv/video.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/playback_coordinator.dart';
import '../../services/settings_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/live_tv_player_navigation.dart';
import '../video_player/live_tv_session_args.dart';

/// Playback state of the Live TV mini-player (build #12).
enum LiveTvMiniPlayerStatus {
  /// Nothing tuned; the slot is hidden.
  idle,

  /// A tune is in flight.
  tuning,

  /// A channel is loaded on the one player (playing or paused).
  active,

  /// The last tune failed; the slot shows a retry.
  failed,

  /// Stopped for fullscreen; the slot keeps the last channel with a
  /// resume action instead of vanishing.
  stopped,
}

/// What kind of failure ended the last tune (build #17). The failed card
/// and the diagnostic branch on it — a catch-up 404 is a missing
/// recording, not a generic load failure, and a 458 is a busy line, not a
/// missing recording (parent probe 2026-11-08 ~13:02 EST: 458 is
/// transient; only 404 is a stable "no recording").
enum LiveTvMiniPlayerFailureKind {
  /// Any other failure: the generic "Could not start" card + Retry.
  generic,

  /// Catch-up tune whose panel answered 404: the panel has no recording
  /// for that programme on that channel. Card: "No recording available
  /// for `<programme>` on `<channel>`" + Watch live. Never retried — the
  /// panel already answered.
  missingRecording,

  /// Any tune whose panel answered 458: the single connection slot is in
  /// use (max_connections = 1). Card: "Line busy" + Retry.
  lineBusy,
}
///
/// - [event]: a `playback-restart` arrived on the controller's subscription.
/// - [latch]: the player's latched `hasRenderedFrame` was already true when
///   the tune finished opening — no event was needed.
/// - [watchdog]: nothing ever reported a frame while the stream played, so
///   the grace timer revealed the surface rather than leaving a permanent
///   black box. A watchdog reveal is a real finding: it means the backend
///   never signalled a first frame for that tune.
/// - [none]: nothing has revealed the surface yet for the current tune.
enum LiveTvMiniPlayerReveal { none, event, latch, watchdog }

/// On-device diagnostic for the last mini-player tune (build #15). Held
/// in memory on the controller class (not per instance) so Settings → IPTV
/// can read it after the guide is gone; it resets when the app restarts.
class LiveTvMiniPlayerDiagnostic {
  const LiveTvMiniPlayerDiagnostic({
    required this.at,
    required this.channelName,
    required this.backend,
    required this.restartObserved,
    required this.reveal,
    required this.videoRectSent,
    this.videoRect,
    this.msToReveal,
    this.failReason,
  });

  /// When the tune started.
  final DateTime at;

  /// The tuned channel's display name.
  final String channelName;

  /// The player backend (`Player.playerType`: 'mpv' or 'exoplayer').
  final String backend;

  /// Whether a `playback-restart` was ever observed for this tune.
  final bool restartObserved;

  /// How the surface was revealed (or [LiveTvMiniPlayerReveal.none]).
  final LiveTvMiniPlayerReveal reveal;

  /// Whether the native video rect was ever sent successfully.
  final bool videoRectSent;

  /// The rect actually sent to the native plane, as
  /// "left,top,right,bottom@dpr" in physical pixels (build #17) — the
  /// diagnostic proves the rect equals the laid-out hole instead of just
  /// saying "yes". Null when no rect was ever sent.
  final String? videoRect;

  /// Milliseconds from tune start to reveal, when revealed.
  final int? msToReveal;

  /// Why the tune failed, when it did (build #16): the "Could not start
  /// the live channel" card used to hide every error — the tune swallowed
  /// them all — so a failed catch-up left nothing to diagnose. The reason
  /// is a short stage label or the player error's cause tag, never a raw
  /// URL (a stream URL carries the provider login).
  final String? failReason;
}

/// Owns the single player behind the Live TV mini-player (build #12).
///
/// The guide is portrait-only: video plays on top while the user browses
/// the guide below. Exactly one [Player] exists for the mini-player's
/// lifetime — tapping another channel re-opens the same instance (the
/// provider allows one stream at a time) and scrolling the guide never
/// tunes at all. The open sequence mirrors the full player's
/// (`_openLiveStream`): the same `force-seekable=no` option that blocks
/// scrubbing on live (v2.25.5), the same `Accept-Language` header, the
/// same session resolution (`liveTvServerInfoForChannel` +
/// `startPlayback` + `streamUrlAt`), and the same catch-up offset math
/// (`liveTvCatchUpOffsetSeconds`).
///
/// A tune that is superseded mid-flight is abandoned by generation, so a
/// slow session can never overwrite the channel the user actually picked.
///
/// First-frame reveal (build #15): the [Video] cover is driven by the
/// controller-owned [hasFirstFrame] notifier, NOT by the Video widget's
/// own late subscription — the build #13 fix subscribed at Video mount,
/// i.e. after `open()` returned, and on Matt's phone the surface stayed
/// black while audio played. The controller subscribes to
/// `playbackRestart` the moment the player is created (before any open),
/// checks the player's latched `hasRenderedFrame` after every open and
/// on every playing transition, and — as a backstop that cannot depend on
/// any backend event — reveals the surface on a watchdog timer once the
/// stream has played for [firstFrameWatchdogGrace] with no frame
/// reported. A brief black flash is acceptable; a permanent black box is
/// the bug.
class LiveTvMiniPlayerController extends ChangeNotifier {
  LiveTvMiniPlayerController({Player Function()? playerFactory, Duration? firstFrameWatchdogGrace})
    : _playerFactory = playerFactory ?? _defaultPlayerFactory,
      firstFrameWatchdogGrace = firstFrameWatchdogGrace ?? const Duration(seconds: 5);

  static Player _defaultPlayerFactory() {
    final settings = SettingsService.instance;
    return Player(
      useExoPlayer: settings.read(SettingsService.useExoPlayer),
      hardwareDecoding: settings.read(SettingsService.enableHardwareDecoding),
    );
  }

  final Player Function() _playerFactory;

  /// Grace after which a playing tune with no reported frame reveals the
  /// surface anyway (build #15 watchdog). Overridable for tests.
  final Duration firstFrameWatchdogGrace;

  /// The last tune's diagnostic, for the Settings → IPTV "Mini-player"
  /// row (build #15). In-memory; cleared when the app restarts.
  static LiveTvMiniPlayerDiagnostic? lastDiagnostic;

  /// Whether the current tune's video surface has been revealed. Owned by
  /// the controller and passed to [Video] as its external `hasFirstFrame`
  /// — the same notifier object across retunes, so the surface re-covers
  /// and re-reveals per tune.
  final ValueNotifier<bool> hasFirstFrame = ValueNotifier<bool>(false);

  LiveTvMiniPlayerStatus _status = LiveTvMiniPlayerStatus.idle;
  LiveTvChannel? _channel;
  int? _catchUpStartEpoch;

  /// Title of the programme a catch-up tune is replaying (build #17) —
  /// the guide passes it so the missing-recording card can name the
  /// programme. Null on live tunes.
  String? _catchUpProgrammeTitle;
  Player? _player;
  LiveTvPlaybackSession? _session;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _muted = false;
  bool _disposed = false;
  int _generation = 0;

  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<PlayerError>? _errorSubscription;
  StreamSubscription<void>? _fileLoadFailedSubscription;
  StreamSubscription<void>? _playbackRestartSubscription;

  /// The player's log stream (build #17): ffmpeg logs the HTTP status
  /// one warn-level line ahead of the error (`http: HTTP error 404 Not
  /// Found`), and mpv collapses every status into the same "file failed
  /// to load" — the log is the only place the panel's answer survives.
  /// Same latch the full player screen keeps (`_onPlayerLog`).
  StreamSubscription<PlayerLog>? _logSubscription;
  Timer? _firstFrameWatchdog;

  /// First-frame state for the current tune (build #15).
  bool _restartObserved = false;
  LiveTvMiniPlayerReveal _revealMethod = LiveTvMiniPlayerReveal.none;
  DateTime? _tuneStartedAt;
  bool _videoRectSent = false;

  /// The rect actually sent for the current tune (build #17), as
  /// "left,top,right,bottom@dpr" in physical pixels.
  String? _videoRect;

  /// Completes when the first rect is sent for the current tune (build
  /// #17): tune() waits on it before opening, so mpv attaches to the
  /// final surface once instead of being stranded by a post-open resize.
  /// Re-created per tune; a tune whose widget never mounts times out
  /// instead of hanging.
  Completer<void>? _rectSentCompleter;

  /// The HTTP status the panel answered with for the current tune's
  /// stream (build #17), latched from the player's log stream. Null
  /// when the log named none — a failure with no status stays generic
  /// and must never be reported as a missing recording.
  int? _lastHttpStatus;

  /// Why the current tune failed, when it did (build #16 — see
  /// [LiveTvMiniPlayerDiagnostic.failReason]).
  String? _failReason;

  /// What kind of failure ended the current tune (build #17).
  LiveTvMiniPlayerFailureKind _failureKind = LiveTvMiniPlayerFailureKind.generic;

  /// What kind of failure ended the current tune.
  LiveTvMiniPlayerFailureKind get failureKind => _failureKind;

  /// Title of the programme a catch-up tune is replaying, if any.
  String? get catchUpProgrammeTitle => _catchUpProgrammeTitle;

  /// The rect actually sent for the current tune, if any.
  String? get videoRect => _videoRect;

  /// How the current tune's surface was revealed ([LiveTvMiniPlayerReveal.none]
  /// while it is still covered).
  LiveTvMiniPlayerReveal get firstFrameReveal => _revealMethod;

  /// Whether a `playback-restart` was observed for the current tune.
  bool get firstFrameRestartObserved => _restartObserved;

  /// Whether the native video rect was sent for the current tune.
  bool get firstFrameVideoRectSent => _videoRectSent;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Record the current tune's diagnostic for the on-device readout.
  void _recordDiagnostic() {
    final channel = _channel;
    if (channel == null) return;
    final startedAt = _tuneStartedAt;
    lastDiagnostic = LiveTvMiniPlayerDiagnostic(
      at: startedAt ?? DateTime.now(),
      channelName: channel.displayName,
      backend: _player?.playerType ?? 'unknown',
      restartObserved: _restartObserved,
      reveal: _revealMethod,
      videoRectSent: _videoRectSent,
      videoRect: _videoRect,
      msToReveal: startedAt == null || _revealMethod == LiveTvMiniPlayerReveal.none
          ? null
          : DateTime.now().difference(startedAt).inMilliseconds,
      failReason: _failReason,
    );
  }

  /// Reveal the surface once, by [method], and stop the watchdog. The
  /// first reveal wins — a later event must not rewrite how it happened.
  void _reveal(LiveTvMiniPlayerReveal method) {
    if (_revealMethod != LiveTvMiniPlayerReveal.none) return;
    _revealMethod = method;
    hasFirstFrame.value = true;
    _firstFrameWatchdog?.cancel();
    _firstFrameWatchdog = null;
    _recordDiagnostic();
  }

  /// The latched state is the backstop for an event the subscription could
  /// not have seen (e.g. a frame rendered before the player was created is
  /// impossible — but a restart the source-id gate dropped leaves the
  /// latch false too, so this also catches a latch set by any other path).
  void _checkLatch() {
    final player = _player;
    if (player == null) return;
    if (player.state.hasRenderedFrame) _reveal(LiveTvMiniPlayerReveal.latch);
  }

  /// Arm the watchdog: once the stream has played for the grace with no
  /// frame reported, reveal anyway and log it — a permanent black box
  /// while audio plays is the bug, a brief flash is not.
  void _armWatchdog() {
    _firstFrameWatchdog?.cancel();
    _firstFrameWatchdog = null;
    if (_revealMethod != LiveTvMiniPlayerReveal.none || !_isPlaying) return;
    _firstFrameWatchdog = Timer(firstFrameWatchdogGrace, () {
      _firstFrameWatchdog = null;
      if (_disposed || _status != LiveTvMiniPlayerStatus.active) return;
      if (!hasFirstFrame.value) {
        appLogger.w(
          'LiveTvMiniPlayer: no first frame after ${firstFrameWatchdogGrace.inMilliseconds}ms of playing '
          '(${_channel?.displayName ?? '?'}, restartObserved=$_restartObserved) — revealing by watchdog',
        );
        _reveal(LiveTvMiniPlayerReveal.watchdog);
      }
    });
  }

  /// Reset the first-frame state for a new tune (build #15). Runs
  /// synchronously at the top of [tune] so the surface re-covers the
  /// moment a retune starts, before any await.
  void _resetFirstFrame() {
    _firstFrameWatchdog?.cancel();
    _firstFrameWatchdog = null;
    _restartObserved = false;
    _revealMethod = LiveTvMiniPlayerReveal.none;
    _tuneStartedAt = DateTime.now();
    _videoRectSent = false;
    _videoRect = null;
    _rectSentCompleter = Completer<void>();
    _lastHttpStatus = null;
    _failReason = null;
    _failureKind = LiveTvMiniPlayerFailureKind.generic;
    hasFirstFrame.value = false;
  }

  /// Called by the [Video] surface when the native rect is first sent
  /// successfully (build #15). Feeds the diagnostic: a watchdog reveal
  /// with no rect sent means the plane was never positioned. [rect] is
  /// the exact "left,top,right,bottom@dpr" the native plane received
  /// (build #17). Completes the tune's rect wait so the open can start
  /// on the final surface.
  void noteVideoRectSent(String rect) {
    _videoRect = rect;
    _rectSentCompleter?.complete();
    if (_videoRectSent) return;
    _videoRectSent = true;
    _recordDiagnostic();
  }

  /// The shutdown the coordinator calls to stop this player (app
  /// background, agent stop). Registered when the player is created and
  /// unregistered when it is released, so the identity the coordinator
  /// compares is always this controller's own stop.
  late final Future<void> Function() _coordinatorShutdown = stop;

  LiveTvMiniPlayerStatus get status => _status;
  LiveTvChannel? get channel => _channel;
  Player? get player => _player;
  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  bool get isMuted => _muted;

  /// Tune (or retune) the mini-player to [channel], opening the stream on
  /// the one player. [catchUpStartEpoch] starts the archive at the
  /// programme's own start time (guide catch-up entry points);
  /// [catchUpProgrammeTitle] names that programme for the
  /// missing-recording card (build #17).
  Future<void> tune({
    required LiveTvChannel channel,
    required MultiServerProvider multiServer,
    int? catchUpStartEpoch,
    String? catchUpProgrammeTitle,
  }) async {
    final generation = ++_generation;
    final previousSession = _session;
    _session = null;
    if (previousSession != null) unawaited(previousSession.discard());
    _channel = channel;
    _catchUpStartEpoch = catchUpStartEpoch;
    _catchUpProgrammeTitle = catchUpProgrammeTitle;
    _status = LiveTvMiniPlayerStatus.tuning;
    _isPlaying = false;
    _isBuffering = true;
    // Re-cover the surface for the new tune before any await (build #15).
    _resetFirstFrame();
    _notify();

    final serverInfo = liveTvServerInfoForChannel(multiServer, channel);
    if (serverInfo == null) {
      _fail('no live server for this channel');
      return;
    }
    final client = multiServer.getClientForServer(ServerId(serverInfo.serverId));

    // Build #17 — rect BEFORE open: create the player now and mount the
    // hole (notify) so the Video sends the rect to the native plane
    // before any stream opens. On v2.25.12 the rect arrived after open()
    // and its container resize destroyed and recreated the SurfaceView
    // while mpv was starting, stranding mpv on a placeholder surface
    // with no frame ever reported ("Restart seen: no"). Attaching to the
    // final surface once removes that race instead of hardening it.
    // Players without rect support (fakes, non-Android backends) skip
    // the wait — there is no rect to wait for.
    final player = _ensurePlayer();
    _notify();
    if (player is VideoRectSupport) {
      await _rectSentCompleter?.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {
          appLogger.w(
            'LiveTvMiniPlayer: no video rect within 500ms for ${channel.displayName} — '
            'opening without one (the widget may not be mounted)',
          );
        },
      );
      if (generation != _generation) return;
    }

    LiveTvPlaybackSession? session;
    if (client != null) {
      try {
        session = await client.liveTv.startPlayback(channel.key, dvrKey: serverInfo.dvrKey);
      } catch (_) {
        session = null;
      }
    }
    if (generation != _generation) {
      if (session != null) unawaited(session.discard());
      return;
    }
    if (session == null) {
      _fail('startPlayback returned no session');
      return;
    }
    _session = session;

    int? offsetSeconds;
    if (catchUpStartEpoch != null) {
      offsetSeconds = liveTvCatchUpOffsetSeconds(
        catchUpStartEpoch: catchUpStartEpoch,
        captureBuffer: session.captureBuffer,
        nowEpoch: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      );
    }
    String? url;
    try {
      url = await session.streamUrlAt(offsetSeconds: offsetSeconds);
    } catch (_) {
      url = null;
    }
    if (generation != _generation) {
      unawaited(session.discard());
      return;
    }
    if (url == null) {
      _fail('no stream URL for the requested offset');
      return;
    }

    try {
      // Live streams are not seekable: the same one-line option the full
      // player applies before every live open.
      await player.setProperty('force-seekable', 'no');
      // Build #22: the session's headers carry the configured Xtream
      // User-Agent for IPTV, so the stream carries the same identity as
      // the API calls. Covers the live edge and catch-up alike — both
      // open through this session.
      await player.open(Media(url, headers: session.streamHeaders), play: true, isLive: true);
    } catch (e) {
      if (generation != _generation) return;
      _fail('open failed (${e.runtimeType})');
      return;
    }
    if (generation != _generation) return;
    _status = LiveTvMiniPlayerStatus.active;
    _isPlaying = true;
    _isBuffering = false;
    // The open returned: the frame may already be latched (build #15),
    // and the watchdog starts from here if it is not.
    _checkLatch();
    _armWatchdog();
    _recordDiagnostic();
    _notify();
  }

  /// Re-tune the last channel (failed card's Retry, stopped card's
  /// resume). No-op when nothing was ever tuned. A catch-up retry
  /// replays the same programme from its start.
  Future<void> retry({required MultiServerProvider multiServer}) async {
    final channel = _channel;
    if (channel == null) return;
    await tune(
      channel: channel,
      multiServer: multiServer,
      catchUpStartEpoch: _catchUpStartEpoch,
      catchUpProgrammeTitle: _catchUpProgrammeTitle,
    );
  }

  /// Watch the last channel live (build #17): the missing-recording
  /// card's one action. Same channel, no catch-up epoch — the panel has
  /// no recording for the programme, but the live stream works.
  Future<void> watchLive({required MultiServerProvider multiServer}) async {
    final channel = _channel;
    if (channel == null) return;
    await tune(channel: channel, multiServer: multiServer);
  }

  Future<void> togglePlayPause() async {
    final player = _player;
    if (player == null || _status != LiveTvMiniPlayerStatus.active) return;
    try {
      await player.playOrPause();
    } catch (_) {
      // The playing stream is the source of truth; a rejected toggle
      // surfaces there, not here.
    }
  }

  Future<void> toggleMute() async {
    final player = _player;
    if (player == null) return;
    _muted = !_muted;
    try {
      await player.setVolume(_muted ? 0 : 100);
    } catch (_) {
      _muted = !_muted;
    }
    _notify();
  }

  /// Stop playback and release the player; the slot hides (status idle).
  Future<void> stop() async {
    _generation++;
    _status = LiveTvMiniPlayerStatus.idle;
    _channel = null;
    _catchUpStartEpoch = null;
    _catchUpProgrammeTitle = null;
    _isPlaying = false;
    _isBuffering = false;
    await _releasePlayerAndSession();
    _notify();
  }

  /// Stop for the fullscreen handoff: the player is released but the slot
  /// stays as a stopped card for the same channel, so one tap resumes it
  /// when the user comes back from the full player.
  Future<void> stopForFullscreen() async {
    _generation++;
    _status = LiveTvMiniPlayerStatus.stopped;
    _isPlaying = false;
    _isBuffering = false;
    await _releasePlayerAndSession();
    _notify();
  }

  Player _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = _playerFactory();
    _player = player;
    PlaybackCoordinator.instance.registerVideoSession(shutdown: _coordinatorShutdown);
    _playingSubscription = player.streams.playing.listen((playing) {
      if (_isPlaying == playing) return;
      _isPlaying = playing;
      if (playing) {
        // A playing transition is another chance to notice a frame the
        // restart subscription could not have seen (build #15).
        _checkLatch();
        _armWatchdog();
      }
      _notify();
    });
    _bufferingSubscription = player.streams.buffering.listen((buffering) {
      if (_isBuffering == buffering) return;
      _isBuffering = buffering;
      _notify();
    });
    _errorSubscription = player.streams.error.listen((error) {
      _onPlayerError(
        _reasonForError(error),
        _classifyFailure(errorCause: error.cause),
      );
    });
    _fileLoadFailedSubscription = player.streams.fileLoadFailed.listen(
      (_) => _onPlayerError('file failed to load', _classifyFailure()),
    );
    // Build #17: the log stream carries the panel's HTTP answer (ffmpeg
    // logs `http: HTTP error <status>` before the end-file); mpv
    // collapses every status into the same "file failed to load", so
    // without this latch a catch-up 404 and a busy line look identical.
    _logSubscription = player.streams.log.listen(_onPlayerLog);
    // Build #15: subscribe the moment the player is created — BEFORE any
    // open() — so a restart fired during the open is caught. The build #13
    // Video-widget subscription mounted after open() returned and missed it.
    _playbackRestartSubscription = player.streams.playbackRestart.listen((_) {
      _restartObserved = true;
      _reveal(LiveTvMiniPlayerReveal.event);
    });
    return player;
  }

  /// Latch the panel's HTTP answer for the current tune from the
  /// player's log stream (build #17). ffmpeg logs the status one
  /// warn-level line ahead of the error; the full player screen keeps
  /// the same latch (`_onPlayerLog`). Reset per tune, so a stale status
  /// from an earlier tune can never mislabel the next failure.
  void _onPlayerLog(PlayerLog log) {
    final status = PlayerError.httpStatusFromLog(log.text);
    if (status != null) _lastHttpStatus = status;
  }

  /// Classify a playback failure from the panel's answer (build #17).
  /// 458 is the busy line on any tune (the single slot is in use);
  /// 404 is a missing recording ONLY on a catch-up tune — a live 404
  /// is a dead stream, not a missing recording. Anything else, and
  /// anything with no HTTP status at all, stays generic: a network
  /// error, an auth failure, or a bad URL must never be reported as a
  /// missing recording. [errorCause] is the error event's cause tag
  /// (`server-http-404`), a fallback when the log line never arrived.
  LiveTvMiniPlayerFailureKind _classifyFailure({String? errorCause}) {
    final status = _lastHttpStatus ?? (errorCause == PlayerError.serverHttp404 ? 404 : null);
    if (status == 458) return LiveTvMiniPlayerFailureKind.lineBusy;
    if (status == 404 && _catchUpStartEpoch != null) {
      return LiveTvMiniPlayerFailureKind.missingRecording;
    }
    return LiveTvMiniPlayerFailureKind.generic;
  }

  /// A load/playback failure once a stream is up: the slot shows the
  /// failed card with a retry. Errors during a tune are handled by the
  /// tune itself (the open's catch), not here.
  void _onPlayerError([String? reason, LiveTvMiniPlayerFailureKind kind = LiveTvMiniPlayerFailureKind.generic]) {
    if (_status != LiveTvMiniPlayerStatus.active) return;
    _fail(reason, kind);
  }

  /// Short failure reason for the diagnostic from a player error (build
  /// #16). The cause tag wins when the backend set one (`server-http-404`
  /// names the failure outright); otherwise the message's first line,
  /// truncated, with any `://user:pass@` credentials stripped — a stream
  /// URL must never land in a readout the user might screenshot.
  static String _reasonForError(PlayerError error) {
    final cause = error.cause;
    if (cause != null && cause.isNotEmpty) return cause;
    var line = error.message.split('\n').first.trim();
    line = line.replaceAll(RegExp(r'://[^/\s]*@'), '://…@');
    if (line.length > 120) line = '${line.substring(0, 117)}…';
    return line.isEmpty ? 'player error' : line;
  }

  void _fail([String? reason, LiveTvMiniPlayerFailureKind kind = LiveTvMiniPlayerFailureKind.generic]) {
    _failureKind = kind;
    // Build #17: the diagnostic carries the missing-recording / line-busy
    // state distinctly from a generic load failure, naming the programme
    // and channel — "Could not start: file failed to load" told Matt
    // nothing about a catch-up that the panel simply has no recording for.
    _failReason = switch (kind) {
      LiveTvMiniPlayerFailureKind.missingRecording =>
        'no recording for ${_catchUpProgrammeTitle ?? 'this programme'} on ${_channel?.displayName ?? 'this channel'}',
      LiveTvMiniPlayerFailureKind.lineBusy => 'line busy: HTTP 458',
      LiveTvMiniPlayerFailureKind.generic => reason,
    };
    _status = LiveTvMiniPlayerStatus.failed;
    _isPlaying = false;
    _isBuffering = false;
    final session = _session;
    _session = null;
    if (session != null) unawaited(session.discard());
    // Record the tune as failed (reveal: none) before the player goes.
    _firstFrameWatchdog?.cancel();
    _firstFrameWatchdog = null;
    _recordDiagnostic();
    // The failed card replaces the video: release the player so a stale
    // stream does not keep playing behind it.
    unawaited(_disposePlayer());
    _notify();
  }

  Future<void> _releasePlayerAndSession() async {
    final session = _session;
    _session = null;
    if (session != null) unawaited(session.discard());
    await _disposePlayer();
  }

  Future<void> _disposePlayer() async {
    final player = _player;
    _player = null;
    if (player == null) return;
    // Fire-and-forget: a broadcast subscription's cancel() future only
    // resolves on the event queue, which never drains inside a widget
    // test's fake async zone — awaiting it stalls teardown there (and
    // buys nothing: event delivery stops at the cancel() call itself, so
    // no listener can fire after this point).
    unawaited(_playingSubscription?.cancel());
    unawaited(_bufferingSubscription?.cancel());
    unawaited(_errorSubscription?.cancel());
    unawaited(_fileLoadFailedSubscription?.cancel());
    unawaited(_playbackRestartSubscription?.cancel());
    unawaited(_logSubscription?.cancel());
    _playingSubscription = null;
    _bufferingSubscription = null;
    _errorSubscription = null;
    _fileLoadFailedSubscription = null;
    _playbackRestartSubscription = null;
    _logSubscription = null;
    _firstFrameWatchdog?.cancel();
    _firstFrameWatchdog = null;
    PlaybackCoordinator.instance.unregisterVideoSession(_coordinatorShutdown);
    try {
      await player.dispose();
    } catch (_) {
      // Dispose must not throw out of the stop paths.
    }
  }

  @override
  Future<void> dispose() async {
    _generation++;
    _disposed = true;
    _firstFrameWatchdog?.cancel();
    _firstFrameWatchdog = null;
    await _releasePlayerAndSession();
    hasFirstFrame.dispose();
    super.dispose();
  }
}

/// The mini-player slot itself (build #12): 16:9 video on top, channel +
/// programme info and controls below it, sitting above the guide in the
/// portrait guide column — video and guide visible at the same time, like
/// the Plex reference.
///
/// Hidden entirely while [LiveTvMiniPlayerStatus.idle]; a stopped card
/// while [LiveTvMiniPlayerStatus.stopped] (fullscreen return); a retry
/// card while [LiveTvMiniPlayerStatus.failed].
class LiveTvMiniPlayer extends StatelessWidget {
  const LiveTvMiniPlayer({
    super.key,
    required this.controller,
    required this.nowPlayingTitle,
    required this.onFullscreen,
    required this.onResume,
    this.onWatchLive,
    this.videoBuilder,
  });

  final LiveTvMiniPlayerController controller;

  /// Title of the programme currently airing on the tuned channel, from
  /// the guide's EPG (null while the guide has none).
  final String? nowPlayingTitle;

  /// Fullscreen handoff: the guide stops the mini-player, then opens the
  /// full player for the tuned channel.
  final VoidCallback onFullscreen;

  /// Retry (failed card) / resume (stopped card): re-tunes the last
  /// channel. The guide supplies the provider.
  final Future<void> Function() onResume;

  /// Watch live (build #17): the missing-recording card's one action —
  /// re-tunes the last channel live, without the catch-up epoch. The
  /// guide supplies it; null falls back to [onResume].
  final Future<void> Function()? onWatchLive;

  /// Builds the video surface for [player]. Defaults to the real [Video]
  /// widget; tests inject a placeholder so no native surface is created.
  final Widget Function(BuildContext context, Player player)? videoBuilder;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final status = controller.status;
        if (status == LiveTvMiniPlayerStatus.idle) return const SizedBox.shrink();
        final channel = controller.channel;
        if (channel == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final isStopped = status == LiveTvMiniPlayerStatus.stopped;
        final isFailed = status == LiveTvMiniPlayerStatus.failed;
        final isTuning = status == LiveTvMiniPlayerStatus.tuning;
        final nowPlaying = nowPlayingTitle;
        // Build #17: NO opaque color on this container. On v2.25.12 it
        // was black, and the native surface below the Flutter view can
        // only show through transparent Flutter pixels — so the Video's
        // own transparent hole revealed this black, not the video, on
        // every tune. Black survives only where it is a fallback: the
        // stopped card (no player) and the failed overlay below.
        return Container(
          key: const Key('live-tv-mini-player'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isStopped)
                      ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                key: const Key('mini-player-resume'),
                                tooltip: t.common.play,
                                iconSize: 48,
                                onPressed: () => unawaited(onResume()),
                                icon: const Icon(Icons.play_arrow, color: Colors.white),
                              ),
                              Text(
                                channel.displayName,
                                style: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      )
                    else if (controller.player != null)
                      // Build #15: the Video cover is driven by the
                      // controller-owned hasFirstFrame notifier (subscribed
                      // at player creation) plus the rect-sent callback for
                      // the diagnostic — not by Video's own late
                      // subscription, which missed the restart on the phone.
                      (videoBuilder ??
                          ((context, player) => Video(
                            player: player,
                            hasFirstFrame: controller.hasFirstFrame,
                            onVideoRectSent: controller.noteVideoRectSent,
                          )))(context, controller.player!)
                    else
                      const ColoredBox(color: Colors.black),
                    if ((isTuning || controller.isBuffering) && !isFailed)
                      const Center(child: CircularProgressIndicator(color: Colors.white)),
                    if (isFailed)
                      ColoredBox(
                        color: Colors.black.withValues(alpha: 0.7),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline, color: Colors.white, size: 32),
                              const SizedBox(height: 8),
                              // Build #17: the failure kind decides the
                              // card. A missing recording names the
                              // programme and channel and offers Watch
                              // live — never a retry (the panel already
                              // answered) and never the generic "Could not
                              // start". A busy line offers Retry.
                              Text(
                                switch (controller.failureKind) {
                                  LiveTvMiniPlayerFailureKind.missingRecording =>
                                    controller.catchUpProgrammeTitle != null
                                        ? t.iptv.miniPlayerMissingRecording(
                                            programme: controller.catchUpProgrammeTitle!,
                                            channel: channel.displayName,
                                          )
                                        : t.iptv.miniPlayerMissingRecordingNoProgramme(
                                            channel: channel.displayName,
                                          ),
                                  LiveTvMiniPlayerFailureKind.lineBusy => t.iptv.miniPlayerLineBusy,
                                  LiveTvMiniPlayerFailureKind.generic => t.liveTv.failedToStartChannel,
                                },
                                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 8),
                              if (controller.failureKind == LiveTvMiniPlayerFailureKind.missingRecording &&
                                  onWatchLive != null)
                                TextButton(
                                  key: const Key('mini-player-watch-live'),
                                  onPressed: () => unawaited(onWatchLive!()),
                                  child: Text(t.iptv.miniPlayerWatchLive),
                                )
                              else
                                TextButton(
                                  key: const Key('mini-player-retry'),
                                  onPressed: () => unawaited(onResume()),
                                  child: Text(t.common.retry),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                color: theme.colorScheme.surface,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            channel.displayName,
                            style: theme.textTheme.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (nowPlaying != null)
                            Text(
                              nowPlaying,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const Key('mini-player-play-pause'),
                      tooltip: isStopped || !controller.isPlaying ? t.common.play : t.common.pause,
                      onPressed: isStopped || isFailed
                          ? () => unawaited(onResume())
                          : () => unawaited(controller.togglePlayPause()),
                      icon: Icon(isStopped || !controller.isPlaying ? Icons.play_arrow : Icons.pause),
                    ),
                    if (!isStopped && !isFailed)
                      IconButton(
                        key: const Key('mini-player-mute'),
                        tooltip: controller.isMuted ? t.videoControls.unmuteButton : t.common.mute,
                        onPressed: () => unawaited(controller.toggleMute()),
                        icon: Icon(controller.isMuted ? Icons.volume_off : Icons.volume_up),
                      ),
                    if (!isStopped && !isFailed)
                      IconButton(
                        key: const Key('mini-player-fullscreen'),
                        tooltip: t.common.fullscreen,
                        onPressed: onFullscreen,
                        icon: const Icon(Icons.fullscreen),
                      ),
                    IconButton(
                      key: const Key('mini-player-close'),
                      tooltip: t.common.close,
                      onPressed: () => unawaited(controller.stop()),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
