// Build #28 — zap waits for release (v1.0.9).
//
// On a one-connection line the old stream's slot is still counted until
// its socket dies, so the new stream must not open until the old one is
// released. These tests prove it in the real player screen: a zap from a
// session that requires release-before-open stops the player and does NOT
// open the next channel until that stop completes, and the events land in
// order (stop-started, stop-finished, open). A session that does not
// require it (the Plex/Jellyfin shape) opens without waiting, so a failed
// zap there still leaves the current channel playing.
//
// Failing-first: on the base (6fe84db64) the zap opens the next channel
// without stopping the old one — the open lands while the stop is held
// open, so the "open waits" assertion fails there. No live panel: fakes
// only.
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/models/livetv_capture_buffer.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/media/media_source_info.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player/live_tv_session_args.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/offline_watch_sync_service.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/player_streams.dart';
import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mediaControlChannel = MethodChannel('com.edde746.os_media_controls/methods');
  const mediaControlEvents = MethodChannel('com.edde746.os_media_controls/events');

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    await initializeDateFormatting('en');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(mediaControlChannel, (call) async => null);
    messenger.setMockMethodCallHandler(mediaControlEvents, (call) async => null);
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(mediaControlChannel, null);
    messenger.setMockMethodCallHandler(mediaControlEvents, null);
  });

  testWidgets('a zap waits for the old stream to release before opening the next', (tester) async {
    final channels = [
      LiveTvChannel(key: 'ch-1', title: 'Channel 1', serverId: 'srv-1'),
      LiveTvChannel(key: 'ch-2', title: 'Channel 2', serverId: 'srv-1'),
      LiveTvChannel(key: 'ch-3', title: 'Channel 3', serverId: 'srv-1'),
    ];
    final liveTv = _SingleConnectionLiveTvSupport();
    final player = _ReleaseRecordingPlayer();
    final shell = _LiveShell(client: _LiveMediaServerClient(liveTv));

    await SettingsService.instance.write(SettingsService.matchContentFrameRate, true);

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async => call.method == 'initialize' ? false : null,
      testBody: () async {
        final key = GlobalKey<VideoPlayerScreenState>();
        await tester.pumpWidget(shell.screen(key: key, channel: channels.first, channels: channels));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final state = key.currentState!..player = player;
        await state.debugMarkPlaybackStartedForTesting();

        await tester.runAsync(state.debugStartPlaybackForTesting);
        await tester.pump();
        expect(player.openedUris, ['http://example.invalid/ch-1.m3u8']);

        // Hold the stop open: the zap's release must wait on it. The zap
        // is started in the fake zone (not runAsync) so the test's pumps
        // flush its microtasks; a second runAsync while the zap is pending
        // is denied as reentrant.
        final stopGate = Completer<void>();
        player.stopGate = stopGate;
        final zap = state.debugSwitchLiveChannelForTesting(1);
        // Let the zap progress to the release (session + URL resolve,
        // then the player stop) — the open must not fire while the stop
        // is held.
        for (var i = 0; i < 20 && !player.events.contains('stop-started'); i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(player.events, contains('stop-started'), reason: 'the zap must stop the old stream first');
        expect(
          player.openedUris,
          ['http://example.invalid/ch-1.m3u8'],
          reason: 'the next channel must not open while the old stream is still being released',
        );

        // Release the stop: the zap proceeds and opens ch-2.
        stopGate.complete();
        await zap;
        await tester.pump();

        expect(player.openedUris, contains('http://example.invalid/ch-2.m3u8'));
        final stopStarted = player.events.indexOf('stop-started');
        final stopFinished = player.events.indexOf('stop-finished');
        final opened = player.events.indexOf('open:http://example.invalid/ch-2.m3u8');
        expect(stopStarted, greaterThanOrEqualTo(0));
        expect(stopFinished, greaterThan(stopStarted));
        expect(opened, greaterThan(stopFinished), reason: 'open must follow the release, not overlap it');

        // Drain the fake clock past the release gate's 1.5 s timeout and
        // the zap's 10 s open deadline so no timer is pending at teardown.
        await tester.pump(const Duration(seconds: 15));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  testWidgets('a zap from a session that does not require release opens without waiting', (tester) async {
    final channels = [
      LiveTvChannel(key: 'ch-1', title: 'Channel 1', serverId: 'srv-1'),
      LiveTvChannel(key: 'ch-2', title: 'Channel 2', serverId: 'srv-1'),
    ];
    final liveTv = _MultiConnectionLiveTvSupport();
    final player = _ReleaseRecordingPlayer();
    final shell = _LiveShell(client: _LiveMediaServerClient(liveTv));

    await SettingsService.instance.write(SettingsService.matchContentFrameRate, true);

    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (call) async => call.method == 'initialize' ? false : null,
      testBody: () async {
        final key = GlobalKey<VideoPlayerScreenState>();
        await tester.pumpWidget(shell.screen(key: key, channel: channels.first, channels: channels));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final state = key.currentState!..player = player;
        await state.debugMarkPlaybackStartedForTesting();

        await tester.runAsync(state.debugStartPlaybackForTesting);
        await tester.pump();
        expect(player.openedUris, ['http://example.invalid/ch-1.m3u8']);

        // Even with the stop held open, the zap must open ch-2: this
        // session never waits for a release.
        final stopGate = Completer<void>();
        player.stopGate = stopGate;
        await tester.runAsync(() => state.debugSwitchLiveChannelForTesting(1));
        await tester.pump();

        expect(
          player.openedUris,
          contains('http://example.invalid/ch-2.m3u8'),
          reason: 'a session that does not require release-before-open opens without waiting',
        );
        expect(player.events, isNot(contains('stop-started')), reason: 'no release was requested at all');
        stopGate.complete();

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}

/// The provider shell a live screen needs (same shape as
/// live_zap_pretune_test.dart).
class _LiveShell {
  _LiveShell({MediaServerClient? client}) {
    if (client != null) {
      serverManager.debugRegisterClientForTesting(client);
      multiServer.debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: client.serverId.value, dvrKey: 'dvr-1')]);
    }
    addTearDown(() async {
      multiServer.dispose();
      offlineWatch.dispose();
      serverManager.dispose();
      await db.close();
    });
  }

  final AppDatabase db = AppDatabase.forTesting(NativeDatabase.memory());
  final MultiServerManager serverManager = MultiServerManager();
  late final MultiServerProvider multiServer = testMultiServerProvider(serverManager);
  late final OfflineWatchSyncService offlineWatch = OfflineWatchSyncService(database: db, serverManager: serverManager);

  Widget screen({
    required GlobalKey<VideoPlayerScreenState> key,
    required LiveTvChannel channel,
    List<LiveTvChannel>? channels,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PlaybackStateProvider()),
        ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
        ChangeNotifierProvider<OfflineWatchSyncService>.value(value: offlineWatch),
        ChangeNotifierProvider<OfflineModeProvider>(create: (_) => OfflineModeProvider(serverManager)),
        ChangeNotifierProvider(create: (_) => WatchTogetherProvider()),
      ],
      child: MaterialApp(
        home: VideoPlayerScreen(
          key: key,
          metadata: testMediaItem(id: channel.key, kind: MediaKind.clip, title: channel.displayName),
          live: LiveTvSessionArgs(
            channel: channel,
            channels: channels,
            currentChannelIndex: channels == null ? 0 : channels.indexOf(channel),
          ),
        ),
      ),
    );
  }
}

/// A player that records stop/open order, with a test-held stop: when
/// [stopGate] is set, [stop] waits on it, so the test can prove the open
/// waits for the release.
class _ReleaseRecordingPlayer implements Player {
  final List<String> openedUris = [];
  final List<String> events = [];
  Completer<void>? stopGate;

  @override
  PlayerState get state => const PlayerState(position: Duration.zero, duration: Duration.zero, seekable: false);

  @override
  String get playerType => 'mpv';

  @override
  PlayerStreams get streams => emptyPlayerStreams();

  @override
  Duration get timelineOffset => Duration.zero;

  @override
  bool get needsDecoderRefreshAfterDisplaySwitch => false;

  @override
  Future<void> open(
    Media media, {
    bool play = true,
    bool isLive = false,
    List<SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    openedUris.add(media.uri);
    events.add('open:${media.uri}');
  }

  @override
  Future<void> stop() async {
    events.add('stop-started');
    final gate = stopGate;
    if (gate != null) await gate.future;
    events.add('stop-finished');
  }

  @override
  Future<void> updateFrame() async {}

  @override
  Future<void> setBoxFitMode(int mode) async {}

  @override
  Future<void> setVideoZoom(double zoom) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<bool> requestAudioFocus() async => true;

  @override
  Future<void> setProperty(String name, String value) async {}

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A session on a one-connection line: the next stream must wait for this
/// one to release.
class _SingleConnectionSession implements LiveTvPlaybackSession {
  _SingleConnectionSession(this.key);

  final String key;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.retainSession;

  @override
  CaptureBuffer? get captureBuffer => null;

  @override
  bool get canTimeShift => false;

  @override
  bool get requiresReleaseBeforeOpen => true;

  @override
  LiveProgramInfo get program => LiveProgramInfo.none;

  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  Map<String, String> get streamHeaders => const {'Accept-Language': 'en'};

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) => Future.value(null);

  @override
  Future<void> discard() async {}

  @override
  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio}) =>
      Future.value(this);

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) =>
      Future.value('http://example.invalid/$key.m3u8');
}

/// A session that never requires release-before-open (the Plex/Jellyfin
/// shape).
class _MultiConnectionSession implements LiveTvPlaybackSession {
  _MultiConnectionSession(this.key);

  final String key;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.retainSession;

  @override
  CaptureBuffer? get captureBuffer => null;

  @override
  bool get canTimeShift => false;

  @override
  bool get requiresReleaseBeforeOpen => false;

  @override
  LiveProgramInfo get program => LiveProgramInfo.none;

  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  Map<String, String> get streamHeaders => const {'Accept-Language': 'en'};

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) => Future.value(null);

  @override
  Future<void> discard() async {}

  @override
  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio}) =>
      Future.value(this);

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) =>
      Future.value('http://example.invalid/$key.m3u8');
}

class _SingleConnectionLiveTvSupport implements LiveTvSupport {
  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async =>
      _SingleConnectionSession(channelKey);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MultiConnectionLiveTvSupport implements LiveTvSupport {
  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async =>
      _MultiConnectionSession(channelKey);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LiveMediaServerClient implements MediaServerClient {
  _LiveMediaServerClient(this.liveTv);

  @override
  final LiveTvSupport liveTv;

  @override
  ServerId get serverId => ServerId('srv-1');

  @override
  String? get serverName => 'Server 1';

  @override
  MediaBackend get backend => MediaBackend.jellyfin;

  @override
  ServerCapabilities get capabilities => const ServerCapabilities(liveTv: true);

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
