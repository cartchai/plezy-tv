part of '../../video_player_screen.dart';

const _liveClockReadyTimeout = Duration(seconds: 15);

extension _VideoPlayerLiveTvMethods on VideoPlayerScreenState {
  /// Start periodic timeline heartbeats for live TV transcode session.
  void _startLiveTimelineUpdates() {
    if (_shuttingDown) return;
    final generation = ++_live.timelineGeneration;
    _live.timelineTimer?.cancel();
    _live.timelineTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (generation != _live.timelineGeneration) return;
      final state = player?.state.playing == true ? 'playing' : 'paused';
      _sendLiveTimeline(state);
    });
    // Delay initial heartbeat to let the transcode session stabilize.
    // Sending time=0 immediately after player.open() causes the server
    // to spawn a duplicate transcode job with offset=-1 that 404s.
    Future.delayed(const Duration(seconds: 3), () {
      if (_live.timelineTimer != null && generation == _live.timelineGeneration) {
        final state = player?.state.playing == true ? 'playing' : 'paused';
        _sendLiveTimeline(state);
      }
    });
  }

  /// Release a live start's or zap's transition lock and run recovery for a
  /// failure of its replacement stream that arrived before it committed.
  void _finishLiveReplacement(PlaybackTransitionLease lease, int replacement, {required bool committed}) {
    final ownsLock = _transitionGate.owns(lease);
    final runDeferred = _live.endReplacement(replacement, committed: committed && ownsLock);
    _transitionGate.release(lease);
    if (runDeferred && mounted && !_shuttingDown && !_isExiting.value && !_hasFatalPlaybackError) {
      appLogger.w('Replacement live stream failed before its transition committed; recovering now');
      _beginLiveLadderRetry();
    }
  }

  /// Advance the fallback ladder and retry — the error path's entry point.
  void _beginLiveLadderRetry() {
    if (_shuttingDown) return;
    // A start or zap that already opened its stream owns it but has not
    // adopted its session yet: recovering now would re-tune the session being
    // replaced, and the gate turns the retry away. Park the failure until the
    // replacement commits (see [_finishLiveReplacement]).
    final transition = _transitionGate.transition;
    if ((transition == PlaybackTransition.startingLive || transition == PlaybackTransition.switchingChannel) &&
        _live.deferReplacementFailure()) {
      appLogger.d('Live stream failure deferred until ${transition.name} commits');
      return;
    }
    _live.fallbackLevel++;
    _live.retrying = true;
    appLogger.w('Live stream failed, retrying with fallback level ${_live.fallbackLevel}');
    unawaited(_retryLiveStreamAfterBackoff());
  }

  /// Waits out the ladder backoff, then retries — unless a zap superseded
  /// the wait (it clears [_live.retrying]) or the screen went away. The
  /// panel that just refused the stream (403/429) needs a beat to recover,
  /// and an immediate re-open reads as another knock on a closed door.
  /// Play-pressed retries ([_retryLiveStreamForPlayIntent]) stay immediate:
  /// the viewer asked for it now.
  Future<void> _retryLiveStreamAfterBackoff() async {
    await Future.delayed(liveRetryBackoff(_live.fallbackLevel));
    if (!mounted || _shuttingDown || !_live.retrying) return;
    await _retryLiveStream();
  }

  /// Play pressed while the live stream is dead: reuse the ladder retry
  /// unless one is already in flight.
  Future<void> _retryLiveStreamForPlayIntent() {
    if (_shuttingDown || _live.retrying) return Future.value();
    _live.retrying = true;
    return _retryLiveStream();
  }

  /// A playback restart proves the current ladder level works; refill it.
  void _resetLiveLadderOnPlaybackRestart() {
    _live.fallbackLevel = 0;
    _live.retryFailed = false;
  }

  void _suspendLiveTimelineForBackground() {
    _live.resumeTimelineOnResume = _live.timelineTimer != null;
    _stopLiveTimelineUpdates();
  }

  void _resumeLiveTimelineAfterBackgroundIfNeeded() {
    final shouldResume = _live.resumeTimelineOnResume;
    _live.resumeTimelineOnResume = false;
    if (shouldResume && _live.session != null) {
      _startLiveTimelineUpdates();
    }
  }

  /// The TV background policy stopped the tuned session: exit the screen on
  /// the next resume instead of showing a dead stream.
  void _stopLiveSessionForTvBackground() {
    _live.exitOnResume = true;
    _live.resumeTimelineOnResume = false;
    _stopLiveTimelineUpdates();
  }

  /// Whether the background stop asked for an exit-on-resume; consuming the
  /// flag so the exit runs once.
  bool _consumeLiveExitOnResume() {
    if (!_live.exitOnResume) return false;
    _live.exitOnResume = false;
    return true;
  }

  void _stopLiveTimelineUpdates() {
    _live.timelineGeneration++;
    _live.timelineTimer?.cancel();
    _live.timelineTimer = null;
  }

  Future<void> _sendLiveTimeline(String state) async {
    if (_shuttingDown && state != 'stopped') return;
    final requestSession = _live.session;
    if (requestSession == null) return;
    // The scrub block follows the tuned channel: resolve it on the first
    // heartbeat after a tune/zap, and re-resolve when the block ends.
    if (state != 'stopped') _maybeRefreshLiveBlock();
    final requestGeneration = _live.timelineGeneration;
    final requestStreamGeneration = _live.streamGeneration;
    // For live TV, player position/duration are unreliable (often 0). Use
    // elapsed wall-clock as the position and the program duration from tune
    // metadata; the per-backend session owns the wire mapping.
    final playbackTime = _live.playbackStartTime != null
        ? DateTime.now().difference(_live.playbackStartTime!).inMilliseconds
        : 0;

    try {
      await _live.timelineReports.send(
        stopped: state == 'stopped',
        report: () => runLiveTimelineReport(
          requestSession: requestSession,
          requestGeneration: requestGeneration,
          state: state,
          positionMs: playbackTime,
          currentSession: () => _live.session,
          currentGeneration: () => _live.timelineGeneration,
          isMounted: () => mounted,
          commit: (update) {
            final hadSeekWindow = _live.captureBuffer != null;
            _setPlayerState(() {
              final playbackStream = update.playbackStream;
              if (playbackStream != null &&
                  _live.adoptPlaybackStreamOrigin(playbackStream, generation: requestStreamGeneration)) {
                appLogger.d('Live clock re-anchored on playback transcode origin ${playbackStream.startedAt}');
              }
              final buffer = update.captureBuffer;
              if (buffer != null) _live.captureBuffer = buffer;
              final window = _live.captureBuffer;
              if (window != null) {
                _live.atLiveEdge =
                    (_currentPositionEpoch >=
                    window.seekableEndEpoch - VideoPlayerScreenState._liveEdgeThresholdSeconds);
              }
            });
            // Time-shift arrived with this heartbeat (Plex publishes the
            // capture buffer a beat after the tune): the session can now
            // advertise ±skip through it.
            if (!hadSeekWindow && _live.captureBuffer != null) {
              unawaited(_mediaControls.syncAvailability());
            }
          },
        ),
      );
    } catch (e) {
      appLogger.d('Live timeline update failed', error: e);
    }
  }

  /// Release a session that started but was never adopted (unmount or
  /// superseded mid-start) so the backend frees its tuner/transcode instead of
  /// holding it until an idle timeout, or forever (#2394).
  void _abandonLiveSession(LiveTvPlaybackSession session) => unawaited(session.discard());

  /// Resolve the owning live-TV server for [channel] and start a playback
  /// session on it — the shared resolution path for initial launch and
  /// channel zapping (Plex tunes a DVR, Jellyfin negotiates a direct URL).
  Future<LiveTvPlaybackSession?> _startLiveSession(LiveTvChannel channel) async {
    final multiServer = context.read<MultiServerProvider>();
    final serverInfo = liveTvServerInfoForChannel(multiServer, channel);
    if (serverInfo == null) {
      appLogger.w('No live TV server available for ${channel.displayName}');
      return null;
    }
    final client = multiServer.getClientForServer(ServerId(serverInfo.serverId));
    if (client == null) {
      appLogger.w('Live TV server ${serverInfo.serverId} is not connected');
      return null;
    }
    return client.liveTv.startPlayback(channel.key, dvrKey: serverInfo.dvrKey, quality: _selectedQualityPreset);
  }

  /// (Re)starts background tunes for the channels adjacent to the one
  /// playing, after a launch commits or a zap lands. The pretuner is created
  /// lazily and only ever runs for live TV; the probe runs for IPTV sessions
  /// only (a Plex/Jellyfin session negotiates a transcode, and GETting its
  /// URL would pull transcode output — a second stream).
  void _refreshLivePretune() {
    final channels = widget.live?.channels;
    if (channels == null || channels.isEmpty) return;
    _livePretuner ??= LiveChannelPretuner(
      startSession: (channel) => _startLiveSession(channel),
      resolveUrl: (session) => session.streamUrlAt(),
      discardSession: (session) => _abandonLiveSession(session),
      // Build #28: probe only an IPTV session whose line does NOT require
      // release-before-open. A probe is a panel GET on the neighbour's
      // playlist — on a one-connection line it stacks on top of the
      // stream already playing (the zap-overlap mechanism), so the
      // neighbour is pre-tuned (session + URL, both local) but never
      // probed; the 10 s open deadline still bounds a dead channel when
      // the zap opens it. The neighbour session's own panel decides —
      // correct for cross-server lists, where one neighbour may be
      // single-connection and the next multi-connection.
      shouldProbe: (session) => session is IptvLiveTvPlaybackSession && !session.requiresReleaseBeforeOpen,
      probePlaylist: probeIptvPlaylist,
    );
    _livePretuner!.refresh(channels, _live.channelIndex);
  }

  /// The item that stands in for [channel] once a zap adopts its session.
  ///
  /// Resolves the channel's server the same way [_startLiveSession] does, so a
  /// cross-server channel list cannot leave every `_currentMetadata` consumer
  /// describing the channel that was tuned first.
  MediaItem _liveChannelItem(LiveTvChannel channel) {
    final multiServer = context.read<MultiServerProvider>();
    final serverInfo = liveTvServerInfoForChannel(multiServer, channel);
    // An unscoped channel names no server of its own; the live TV server the
    // tune would pick is the one that can serve its logo.
    final serverId = serverInfo?.serverId ?? channel.serverId;
    final client = serverId == null ? null : multiServer.getClientForServer(ServerId(serverId));
    return liveTvChannelItem(channel, backend: client?.backend ?? _currentMetadata.backend, serverId: serverId);
  }

  /// Retry the live stream with degraded direct-stream settings.
  ///
  /// The session owns the per-backend recovery: Plex re-tunes the channel
  /// for a fresh capture session (the previous one expires while MPV
  /// exhausts its reconnect attempts) applying the degradation flags;
  /// Jellyfin re-opens its session-less URL.
  Future<void> _retryLiveStream() async {
    _liveSeek.cancel();
    final currentPlayer = player;
    if (!mounted || _shuttingDown || currentPlayer == null) return;
    final session = _live.session;
    if (session == null) {
      _live.retrying = false;
      appLogger.w('Cannot retry live stream — no session');
      showGlobalErrorSnackBar(_redactPlayerError(_lastLogError ?? t.liveTv.liveStreamFailed));
      unawaited(_handleBackButton());
      return;
    }

    // Recovery reopens the stream, so it holds the transition lock like any
    // other in-place transition. A zap or start in flight is replacing the
    // stream that failed; recovering the old session under it would reopen
    // the previous channel over the new one. The new stream reports its own
    // failures once it is in place.
    final lease = _transitionGate.tryAcquire(PlaybackTransition.recoveringLive);
    if (lease == null) {
      _live.retrying = false;
      appLogger.d('Live stream retry skipped: ${_transitionGate.transition.name} in flight');
      return;
    }
    try {
      await _recoverLiveStream(currentPlayer, session, lease);
    } finally {
      _transitionGate.release(lease);
    }
  }

  Future<void> _recoverLiveStream(
    Player currentPlayer,
    LiveTvPlaybackSession session,
    PlaybackTransitionLease lease,
  ) async {
    final generation = _transitionGate.generation;
    // A zap supersedes the recovery by taking the lock over (see
    // [_switchLiveChannel]); everything recovered after that is discarded.
    bool isCurrent() =>
        _isCurrentPlaybackGeneration(generation, currentPlayer) &&
        _transitionGate.owns(lease, expected: PlaybackTransition.recoveringLive);

    final ds = _live.fallbackLevel < 1;
    final dsa = _live.fallbackLevel < 2;
    appLogger.i('Retrying live stream: directStream=$ds directStreamAudio=$dsa');

    // Carried across the re-tune: stream ids are tune-scoped, so the choice
    // is re-mapped onto the recovered session's track list. Recovering the
    // video outranks keeping subtitles — a failed burn re-apply drops them.
    MediaSubtitleTrack? recoveredSubtitle;
    CaptureBuffer? recoveredCaptureBuffer;
    final result = await runLiveStreamRetry<LiveTvPlaybackSession>(
      recover: () => session.recover(directStream: ds, directStreamAudio: dsa),
      lookupStreamUrl: (recovered) async {
        recoveredCaptureBuffer = recovered.captureBuffer;
        recoveredSubtitle = LiveTvSessionState.remapSubtitleSelection(recovered.subtitleTracks, _live.selectedSubtitle);
        if (recoveredSubtitle != null) {
          final url = await recovered.streamUrlAt(subtitleTrack: recoveredSubtitle);
          if (url != null) return url;
          appLogger.w('Live recovery could not re-apply the subtitle burn; retrying without subtitles');
          recoveredSubtitle = null;
        }
        return recovered.streamUrlAt();
      },
      applyPlayerOptions: () => _setLiveStreamOptions(currentPlayer),
      open: (streamUrl, recovered) async {
        _live.markStreamRestartedAtLiveEdge(recoveredCaptureBuffer);
        final targetEpoch = recoveredCaptureBuffer == null ? null : _live.streamStartEpoch.round();
        await _openLiveStream(
          currentPlayer,
          streamUrl,
          headers: recovered.streamHeaders,
          targetEpoch: targetEpoch,
          applyOptions: false,
        );
      },
      isCurrent: isCurrent,
      adoptSession: (recovered) {
        _live.adoptSession(recovered);
        _live.selectedSubtitle = recoveredSubtitle;
      },
      // Jellyfin's recover() returns the receiver, so the recovered object can
      // be the still-current session; the retry helper skips the discard by
      // identity so a failed retry cannot terminally release it.
      currentSession: () => _live.session,
      discardSession: _abandonLiveSession,
      reportFailure: (error, stackTrace) {
        appLogger.e('Failed to recover live stream', error: error, stackTrace: stackTrace);
        _live.retryFailed = true;
        showGlobalErrorSnackBar(t.messages.liveStreamInterrupted);
      },
      onFinished: () {
        if (isCurrent()) _live.retrying = false;
      },
    );
    if (result == LiveStreamRetryResult.succeeded && isCurrent()) {
      _live.retryFailed = false;
    }
  }

  /// Configure MPV options for live streaming.
  /// The official Plex Media Player does not set client-side reconnect options —
  /// reconnection is handled by the server's transcoder on the input side.
  Future<void> _setLiveStreamOptions(Player player) => player.setProperty('force-seekable', 'no');

  /// Re-opens the current session's live stream at [streamUrl].
  ///
  /// Offset-based MPV opens register their requested absolute [targetEpoch]
  /// before `loadfile` and bind that registration to the source id the load
  /// reports, so only that source's events can calibrate it. When [awaitClock]
  /// is true, success means the new source's first rendered player position
  /// has been mapped to that epoch.
  Future<bool> _openLiveStream(
    Player player,
    String streamUrl, {
    Map<String, String>? headers,
    int? targetEpoch,
    bool awaitClock = false,
    bool? play,
    bool applyOptions = true,
    bool timeShifted = false,
    void Function()? onOpenStarted,
  }) async {
    if (_shuttingDown || !_launchCurrent) return false;
    // Build #28: no open starts while a previous stream's release is
    // still in flight — the choke point, so a release the zap started
    // (or a mini-player tune started) is honoured by every open, not
    // just the zap that asked for it. Returns immediately when no
    // release is running, so Plex/Jellyfin and multi-connection opens
    // pay nothing.
    await _liveReleaseGate.waitForRelease();
    _live.streamGeneration++;
    // Build #22: [headers] are the session's own headers — the configured
    // Xtream User-Agent for IPTV, so the stream carries the same identity
    // as the API calls instead of mpv's default. Callers pass the session
    // that built the URL: the adopted session may still be the previous
    // channel's (a zap adopts after the open, recovery adopts after).
    final media = Media(streamUrl, headers: headers ?? const {'Accept-Language': 'en'});
    final playNow = play ?? automotivePlaybackAllowedNow();
    if (targetEpoch == null || player is! PlayerNative) {
      if (applyOptions) await _setLiveStreamOptions(player);
      if (_shuttingDown || !_launchCurrent) return false;
      onOpenStarted?.call();
      await player.open(media, play: playNow, isLive: true);
      return true;
    }

    final clockGeneration = _live.beginClockOpen(targetEpoch);
    final clockResult = _live.clockOpenResult(clockGeneration);
    final int? sourceId;
    try {
      if (applyOptions) await _setLiveStreamOptions(player);
      if (_shuttingDown || !_launchCurrent) return false;
      onOpenStarted?.call();
      sourceId = await player.open(media, play: playNow, isLive: true, startLivePlaylistFromBeginning: timeShifted);
    } catch (_) {
      _live.failClockOpen(clockGeneration);
      rethrow;
    }
    if (sourceId == null) {
      // The load never reached mpv (core unavailable), so no source will ever
      // report for this open.
      _live.failClockOpen(clockGeneration);
      return false;
    }
    _live.bindClockOpen(clockGeneration, sourceId);

    if (!awaitClock) {
      unawaited(clockResult);
      return true;
    }
    return clockResult.timeout(
      _liveClockReadyTimeout,
      onTimeout: () {
        _live.timeoutClockOpen(clockGeneration);
        appLogger.w('Live time-shift source did not report a rendered clock position');
        return false;
      },
    );
  }

  /// Arm display negotiation for a live open that tunes a channel — the
  /// launch and every zap. Android mpv and Apple TV open the stream paused
  /// and negotiate from what the player presents at its first frame, the way
  /// a VOD open does ([_firstFrameStartupPlan]). Broadcast is where
  /// interlaced video lives, and a MediaCodec decoder that deinterlaces by
  /// itself presents one frame per field with only the measured cadence to
  /// say so: matched from the container rate, 1080i25 got a 25 Hz mode that
  /// dropped every other frame and let video fall behind audio (#2568).
  ///
  /// [firstFrame] is the open's first-frame signal, armed before the open:
  /// the launch's attempt outcome, or the one a zap arms for itself. Null —
  /// open as before — on ExoPlayer, which keeps its post-first-frame
  /// detection, and on desktop. Time-shift seeks, subtitle rebuilds and
  /// stream recovery reopen the same channel and keep its negotiated mode.
  _FrameRateStartupPlan? _armLiveDisplayNegotiation(Player currentPlayer, PlaybackOpenOutcome firstFrame) {
    final plan = _firstFrameStartupPlan(currentPlayer, SettingsService.instance, hasVideoUrl: true);
    if (plan == null) return null;
    _frameRate.resetForNewItem();
    if (plan.countsAsApplied) _frameRate.applied = true;
    plan.armFirstFrameGate(firstFrame, _frameRate);
    return plan;
  }

  /// Release a gate [_armLiveDisplayNegotiation] armed: negotiate the display
  /// at the stream's first frame, then resume it. Runs once the start or zap
  /// gave up its transition lock, so a channel that never shows a frame
  /// cannot hold the next zap up. Any later live open (zap, recovery,
  /// time-shift seek, subtitle rebuild) supersedes it and owns the play state
  /// it leaves. [stream] is the [LiveTvSessionState.streamGeneration] the
  /// gated open produced; null when that open did not commit, which only
  /// releases the first-frame hold.
  Future<void> _releaseLiveDisplayNegotiation(
    Player currentPlayer,
    _FrameRateStartupPlan plan, {
    required int? stream,
  }) async {
    final generation = _transitionGate.generation;
    try {
      if (stream == null || !plan.holdPlaybackStart) return;
      await _releaseFrameRateStartupGate(
        currentPlayer: currentPlayer,
        settingsService: SettingsService.instance,
        plan: plan,
        isCurrent: () => _isCurrentPlaybackGeneration(generation, currentPlayer) && _live.streamGeneration == stream,
        resumeAfterStartupGate: (reason) =>
            _resumeAfterFrameRateStartupGate(currentPlayer: currentPlayer, reason: reason),
      );
    } finally {
      _frameRate.endDisplayNegotiation(plan.displayNegotiation);
    }
  }

  int _liveEpochForPosition(Duration position) => _liveSeek.pendingEpoch ?? _live.epochForPosition(position);

  /// Current playback position in absolute epoch seconds.
  int get _rawPositionEpoch => _live.epochForPosition(player?.currentPosition ?? Duration.zero);

  /// While a relative skip is queued, its accumulated target remains
  /// authoritative until the replacement source clock is calibrated.
  int get _currentPositionEpoch => _liveEpochForPosition(player?.currentPosition ?? Duration.zero);

  /// Show "Watch from Start" / "Watch Live" dialog.
  /// Returns true if user chose "Watch from start", false for "Watch Live", null if dismissed.
  Future<bool?> _showWatchFromStartDialog(int effectiveStartEpoch, int nowEpoch) {
    final minutesAgo = ((nowEpoch - effectiveStartEpoch) / 60).round();
    return showOptionPickerDialog<bool>(
      context,
      title: t.liveTv.joinSession,
      options: [
        (icon: Symbols.replay_rounded, label: t.liveTv.watchFromStart(minutes: minutesAgo), value: true),
        (icon: Symbols.live_tv_rounded, label: t.liveTv.watchLive, value: false),
      ],
    );
  }

  /// Seek the live TV stream to an absolute epoch second by rebuilding the
  /// stream at the target offset. The session returns null when the backend
  /// can't time-shift (Jellyfin), and its capture buffer is null there too,
  /// so both guards cover it. Returns whether the rebuilt stream was opened.
  Future<bool> _seekLivePosition(int targetEpochSeconds) async {
    final currentPlayer = player;
    if (_shuttingDown || currentPlayer == null) return false;
    final session = _live.session;
    final buffer = _live.captureBuffer;
    if (session == null || buffer == null) return false;

    final clamped = targetEpochSeconds.clamp(buffer.seekableStartEpoch, buffer.seekableEndEpoch);
    final offsetSeconds = clamped - buffer.startedAt.round();

    final streamUrl = await session.streamUrlAt(offsetSeconds: offsetSeconds, subtitleTrack: _live.selectedSubtitle);
    if (streamUrl == null || !mounted || _shuttingDown || player != currentPlayer) return false;

    if (currentPlayer is! PlayerNative) {
      _live.streamStartEpoch = buffer.startedAt + offsetSeconds;
    }
    _live.atLiveEdge = (clamped >= buffer.seekableEndEpoch - VideoPlayerScreenState._liveEdgeThresholdSeconds);
    _live.playbackStartTime = DateTime.now();

    final opened = await _openLiveStream(
      currentPlayer,
      streamUrl,
      headers: session.streamHeaders,
      targetEpoch: clamped,
      awaitClock: currentPlayer is PlayerNative,
      timeShifted: true,
    );
    if (!mounted || player != currentPlayer) return false;
    _setPlayerState(() {});
    return opened;
  }

  /// Apply a source subtitle choice to the live stream by rebuilding it with
  /// the backend's server-side delivery (Plex points the part's selection at
  /// the stream and burns it). The live counterpart of the VOD source switch:
  /// same [PlaybackSourceSubtitleChoice], but the restart is the raw
  /// `streamUrlAt → open(isLive: true)` every live URL change uses.
  Future<PlaybackSourceChangeOutcome> _switchLiveSubtitle(PlaybackSourceSubtitleChoice choice) async {
    final currentPlayer = player;
    final session = _live.session;
    if (currentPlayer == null || session == null) return PlaybackSourceChangeOutcome.unavailable;

    MediaSubtitleTrack? target;
    if (!choice.isOff) {
      for (final track in session.subtitleTracks) {
        if (track.id == choice.sourceStreamId) {
          target = track;
          break;
        }
      }
      if (target == null) return PlaybackSourceChangeOutcome.unavailable;
    }
    final previous = _live.selectedSubtitle;
    if (target?.id == previous?.id) return PlaybackSourceChangeOutcome.unchanged;

    _live.selectedSubtitle = target;

    // Keep the viewer's position: rebuild at the time-shift offset when
    // behind the live edge, otherwise re-open at the edge.
    if (_live.captureBuffer != null && !_live.atLiveEdge) {
      if (await _seekLivePosition(_currentPositionEpoch)) return PlaybackSourceChangeOutcome.applied;
      _live.selectedSubtitle = previous;
      return PlaybackSourceChangeOutcome.failed;
    }

    final streamUrl = await session.streamUrlAt(subtitleTrack: target);
    if (!mounted || player != currentPlayer || _live.session != session) {
      return PlaybackSourceChangeOutcome.superseded;
    }
    if (streamUrl == null) {
      _live.selectedSubtitle = previous;
      return PlaybackSourceChangeOutcome.failed;
    }
    _live.markStreamRestartedAtLiveEdge(_live.captureBuffer);
    await _openLiveStream(
      currentPlayer,
      streamUrl,
      headers: session.streamHeaders,
      targetEpoch: _live.captureBuffer == null ? null : _live.streamStartEpoch.round(),
    );
    if (mounted) _setPlayerState(() {});
    return PlaybackSourceChangeOutcome.applied;
  }

  /// Current seekable epoch window for [_liveSeek], or null when there is no
  /// live capture buffer. The ±skip window follows the scrub block when one
  /// is pinned, so a skip cannot carry the playhead out of the time slot
  /// the bar shows; the end is still capped at the live edge.
  LiveSeekBounds? _liveSeekBounds() {
    final buffer = _live.captureBuffer;
    if (buffer == null) return null;
    final blockStart = _live.scrubBlockStartEpoch;
    final blockEnd = _live.scrubBlockEndEpoch;
    if (blockStart != null && blockEnd != null && blockEnd > blockStart) {
      final start = blockStart.clamp(buffer.seekableStartEpoch, buffer.seekableEndEpoch);
      final end = blockEnd.clamp(buffer.seekableStartEpoch, buffer.seekableEndEpoch);
      if (end > start) return (start: start, end: end);
    }
    return (start: buffer.seekableStartEpoch, end: buffer.seekableEndEpoch);
  }

  /// The channel currently tuned, from the zap list or the launch args.
  LiveTvChannel? get _currentLiveChannel {
    final channels = widget.live?.channels;
    if (channels != null && _live.channelIndex >= 0 && _live.channelIndex < channels.length) {
      return channels[_live.channelIndex];
    }
    return widget.live?.channel;
  }

  /// Re-resolve the scrub block when it is missing (first heartbeat after a
  /// tune/zap; a failed resolution is retried at most once a minute) or
  /// when the current block has ended (the programme rolled over).
  void _maybeRefreshLiveBlock() {
    if (_shuttingDown) return;
    final session = _live.session;
    if (session is! IptvLiveTvPlaybackSession || !session.canTimeShift) return;
    final now = DateTime.now();
    final blockEnd = _live.scrubBlockEndEpoch;
    if (blockEnd != null) {
      if (now.millisecondsSinceEpoch ~/ 1000 < blockEnd) return;
    } else {
      final attemptedAt = _live.scrubBlockAttemptedAt;
      if (attemptedAt != null && now.difference(attemptedAt) < const Duration(minutes: 1)) return;
    }
    unawaited(_resolveLiveBlock());
  }

  /// Resolve the current scrub block for the tuned channel (build #9 Task
  /// 3): the programme covering now, or the current clock hour when there
  /// is no guide data. Only for IPTV catch-up sessions — Plex/Jellyfin
  /// keep the capture-window bar. The EPG fetch serves the persisted cache
  /// the guide already loaded, so coming from the guide this is cheap.
  Future<void> _resolveLiveBlock() async {
    final session = _live.session;
    if (_shuttingDown || session is! IptvLiveTvPlaybackSession || !session.canTimeShift) return;
    final channel = _currentLiveChannel;
    if (channel == null) return;
    _live.scrubBlockAttemptedAt = DateTime.now();
    final multiServer = context.read<MultiServerProvider>();
    final serverInfo = liveTvServerInfoForChannel(multiServer, channel);
    final client = serverInfo == null ? null : multiServer.getClientForServer(ServerId(serverInfo.serverId));
    final support = client?.liveTv;
    if (support is! IptvLiveTvSupport) return;
    final now = DateTime.now();
    final programs = await support
        .fetchEpgForChannel(
          channel.key,
          from: now.subtract(const Duration(hours: 6)),
          to: now.add(const Duration(hours: 2)),
        )
        .catchError((Object e) {
          appLogger.w('Live scrub block: EPG unavailable for ${channel.displayName}: $e');
          return const <LiveTvProgram>[];
        });
    if (!mounted || _shuttingDown || !identical(_live.session, session)) return;
    final block = liveScrubBlock(programs, DateTime.now());
    _setPlayerState(() {
      _live.scrubBlockStartEpoch = block.startEpoch;
      _live.scrubBlockEndEpoch = block.endEpoch;
    });
  }

  /// Rebuild and refresh live-edge state when [_liveSeek]'s pending target
  /// changes (a skip was accumulated, or the post-seek pin was released).
  void _onLiveSeekTargetChanged() {
    if (!mounted) return;
    final pending = _liveSeek.pendingEpoch;
    final buffer = _live.captureBuffer;
    _setPlayerState(() {
      if (pending != null && buffer != null) {
        _live.atLiveEdge = pending >= buffer.seekableEndEpoch - VideoPlayerScreenState._liveEdgeThresholdSeconds;
      }
    });
  }

  /// Re-open the live stream at [targetEpochSeconds], logging failures.
  Future<bool> _runLiveSeek(int targetEpochSeconds) async {
    try {
      final opened = await _seekLivePosition(targetEpochSeconds);
      if (!opened) {
        appLogger.w('Live time-shift seek did not reach a calibrated source');
      }
      return opened;
    } catch (e, st) {
      appLogger.w('Live time-shift seek failed', error: e, stackTrace: st);
      return false;
    }
  }

  /// Seek the live stream to an absolute epoch (scrubber / jump-to-live). Drops
  /// any pending relative-skip burst first so a queued seek can't override it.
  Future<void> _seekLiveToEpoch(int targetEpochSeconds) async {
    _liveSeek.cancel();
    await _runLiveSeek(targetEpochSeconds);
  }

  Future<void> _jumpToLiveEdge() async {
    if (_live.captureBuffer == null) return;
    await _seekLiveToEpoch(_live.captureBuffer!.seekableEndEpoch);
  }

  /// Channel switch, debounced (build #28, OwnTV's shape): rapid presses
  /// collapse into one tune instead of one tune per press, so a held key
  /// cannot open a stream per step on a one-connection panel. The returned
  /// Future completes when the tune executes (or is dropped as a net-zero
  /// burst) — an isolated press tunes at once, so the common case awaits
  /// the tune itself.
  Future<void> _switchLiveChannel(int delta) {
    final completer = Completer<void>();
    _pendingZapCompleters.add(completer);
    _liveZapDebouncer.request(delta);
    return completer.future;
  }

  Future<void> _switchLiveChannelNow(int delta) async {
    if (_shuttingDown) return;
    final channels = widget.live?.channels;
    if (channels == null || channels.isEmpty) return;
    final newIndex = _live.channelIndex + delta;
    if (newIndex < 0 || newIndex >= channels.length) return;
    final currentPlayer = player;
    if (currentPlayer == null) return;

    // Zapping away from a failing channel must not wait out its recovery (a
    // re-tune can take the whole tune budget): the zap replaces that stream,
    // so it supersedes the recovery, which discards whatever it recovered.
    if (_transitionGate.transition == PlaybackTransition.recoveringLive) {
      _transitionGate.forceIdle();
      _live.retrying = false;
    }
    final transitionLease = _transitionGate.tryAcquire(PlaybackTransition.switchingChannel);
    if (transitionLease == null) return; // debounce concurrent switches
    final replacement = _live.beginReplacement();
    var committed = false;
    bool isCurrentChannelSwitch() =>
        mounted &&
        !_shuttingDown &&
        player == currentPlayer &&
        _transitionGate.owns(transitionLease, expected: PlaybackTransition.switchingChannel);
    _liveSeek.cancel();

    final previousSession = _live.session;
    final previousFirstFrame = _firstFrame.snapshot();
    final channel = channels[newIndex];
    appLogger.d('Switching to channel: ${channel.displayName} (${channel.key})');

    LiveTvPlaybackSession? session;
    var replacementOpenStarted = false;
    PlaybackOpenOutcome? zapOutcome;
    _FrameRateStartupPlan? frameRatePlan;
    int? openedStream;
    try {
      // A neighbour the launch (or the previous zap) pre-tuned is already
      // started with its URL resolved: the zap skips the session-start round
      // trip. A neighbour whose playlist already refused fails fast here —
      // stay on the current channel instead of opening mpv onto a dead
      // stream.
      final pretuned = _livePretuner?.take(channel.key);
      String? streamUrl;
      if (pretuned != null) {
        if (pretuned.isDead) {
          _abandonLiveSession(pretuned.session);
          if (mounted) showErrorSnackBar(context, t.liveTv.failedToStartChannel);
          return;
        }
        session = pretuned.session;
        streamUrl = pretuned.streamUrl;
      } else {
        // Channel switch IS a fresh start: same resolution path as launch. Keep
        // the old session alive until the replacement stream is actually open so
        // a failed zap does not tell the server to reclaim the still-playing
        // tuner/transcode session.
        session = await _startLiveSession(channel);
        if (session == null) {
          // Jellyfin's negotiation returns null instead of throwing, so this
          // is not covered by the catch below; without feedback a failed zap
          // looks like a dead remote (#2198).
          if (mounted) showErrorSnackBar(context, t.liveTv.failedToStartChannel);
          return;
        }
        if (!isCurrentChannelSwitch()) {
          _abandonLiveSession(session);
          return;
        }

        streamUrl = await session.streamUrlAt();
        if (streamUrl == null || !isCurrentChannelSwitch()) {
          _abandonLiveSession(session);
          return;
        }
      }
      if (!isCurrentChannelSwitch()) {
        _abandonLiveSession(session);
        return;
      }

      _setPlayerState(() {
        _firstFrame.reset();
      });
      _live.markStreamRestartedAtLiveEdge(session.captureBuffer);
      final targetEpoch = session.captureBuffer == null ? null : _live.streamStartEpoch.round();
      // Build #28: on a one-connection line the old stream's slot is still
      // counted until its socket dies, so the new stream must not open
      // until the old one is released. The release is the player stop —
      // there is no panel disconnect call — and the gate bounds the wait
      // at 1.5 s, never blocking the zap on a failed stop. Only when the
      // previous session requires it: Plex/Jellyfin and multi-connection
      // lines keep the old order (open first, adopt after), so a failed
      // zap leaves the current channel playing. The session and URL are
      // already resolved above, so the stop happens as late as possible —
      // the old channel plays until the last moment.
      if (previousSession != null && previousSession.requiresReleaseBeforeOpen) {
        await _liveReleaseGate.release(() => currentPlayer.stop());
        if (!isCurrentChannelSwitch()) {
          _abandonLiveSession(session);
          return;
        }
      }
      // A zap starts no playback attempt, so it arms its own first-frame
      // signal; the deadline bounds a stream that stops moving before one.
      zapOutcome = PlaybackOpenOutcome.arm(currentPlayer, deadline: openDeadlineFor(isLive: true));
      frameRatePlan = _armLiveDisplayNegotiation(currentPlayer, zapOutcome);
      final opened = await _openLiveStream(
        currentPlayer,
        streamUrl,
        headers: session.streamHeaders,
        targetEpoch: targetEpoch,
        play: (frameRatePlan?.holdPlaybackStart ?? false) ? false : null,
        onOpenStarted: () {
          replacementOpenStarted = true;
          // The native state belongs to the replacement from this point,
          // before its session/channel is adopted after timeline reporting.
          // Detach the receipt, not the screen's launch lifetime fence.
          widget.launchObserver?.detach();
        },
      );
      if (opened) openedStream = _live.streamGeneration;
      if (!isCurrentChannelSwitch()) {
        _abandonLiveSession(session);
        return;
      }

      // The new stream is now the active local playback. Stop the old heartbeat
      // and send its terminal timeline before adopting the replacement session.
      _stopLiveTimelineUpdates();
      if (previousSession != null) {
        await _sendLiveTimeline('stopped');
      }
      if (!isCurrentChannelSwitch()) {
        _abandonLiveSession(session);
        return;
      }

      _live.adoptSession(session);
      _live.fallbackLevel = 0;
      committed = true;

      if (!mounted) return;
      _setPlayerState(() {
        _live.channelIndex = newIndex;
        _live.channelName = channel.displayName;
        _currentMetadata = _liveChannelItem(channel);
      });

      // The neighbours changed with the channel: pre-tune the new ones.
      _refreshLivePretune();

      // The screen now describes a different channel: republish before the
      // heartbeats restart, or the OS controls, the client lookups and the
      // scoped player preferences stay pinned to the channel tuned first.
      final mediaControlsManager = _mediaControlsManager;
      if (mediaControlsManager != null) {
        unawaited(
          mediaControlsManager.updateMetadata(
            metadata: _currentMetadata,
            client: _getOnlineMediaServerClient(context),
            duration: null,
          ),
        );
      }
      unawaited(_mediaControls.syncAvailability());

      // Restart timeline heartbeats for the new session
      _startLiveTimelineUpdates();
    } catch (e) {
      // A session that tuned but was never adopted (streamUrlAt/open threw)
      // would otherwise hold its server-side tuner until the backend times out.
      final orphan = session;
      if (orphan != null && _live.session != orphan) _abandonLiveSession(orphan);
      if (!isCurrentChannelSwitch()) return;
      if (replacementOpenStarted && mounted && _live.session == previousSession) {
        _setPlayerState(() {
          _firstFrame.restore(previousFirstFrame);
        });
      }
      appLogger.e('Failed to switch channel', error: e);
      if (mounted) showErrorSnackBar(context, t.liveTv.channelSwitchFailed(reason: localizedErrorReason(e)));
    } finally {
      _finishLiveReplacement(transitionLease, replacement, committed: committed);
      if (!committed) zapOutcome?.abort('channel switch did not commit');
      final plan = frameRatePlan;
      if (plan != null) {
        await _releaseLiveDisplayNegotiation(currentPlayer, plan, stream: committed ? openedStream : null);
      }
    }
  }

  bool get _hasNextChannel {
    final channels = widget.live?.channels;
    return channels != null && _live.channelIndex >= 0 && _live.channelIndex < channels.length - 1;
  }

  bool get _hasPreviousChannel => widget.live?.channels != null && _live.channelIndex > 0;
}
