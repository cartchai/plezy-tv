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

/// A zap must consume the neighbour the launch pre-tuned instead of starting
/// it cold: one session start per channel, and the zap opens the URL the
/// pre-tune already resolved. (Same shell shape as
/// test/screens/video_player/live_media_session_test.dart.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mediaControlChannel = MethodChannel('com.edde746.os_media_controls/methods');
  const mediaControlEvents = MethodChannel('com.edde746.os_media_controls/events');

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    await initializeDateFormatting('en');
    // The screen's player init touches the OS media session; without these
    // mocks its attempt stalls instead of failing fast on the refused core
    // (same setUp as live_media_session_test.dart).
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(mediaControlChannel, (call) async => null);
    messenger.setMockMethodCallHandler(mediaControlEvents, (call) async => null);
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(mediaControlChannel, null);
    messenger.setMockMethodCallHandler(mediaControlEvents, null);
  });

  testWidgets('a zap to a pre-tuned neighbour does not start it again', (tester) async {
    final channels = [
      LiveTvChannel(key: 'ch-1', title: 'Channel 1', serverId: 'srv-1'),
      LiveTvChannel(key: 'ch-2', title: 'Channel 2', serverId: 'srv-1'),
      LiveTvChannel(key: 'ch-3', title: 'Channel 3', serverId: 'srv-1'),
    ];
    final liveTv = _TuningLiveTvSupport();
    final player = _RecordingLivePlayer();
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
        // The screen's own init refuses the mocked core before it creates
        // the volume controller, so seed the completed-startup state the
        // Video widget needs (volume controller + initialized) explicitly.
        await state.debugMarkPlaybackStartedForTesting();

        await tester.runAsync(state.debugStartPlaybackForTesting);
        await tester.pump();
        expect(player.openedUris, ['http://example.invalid/ch-1.m3u8']);

        // The launch pre-tunes the neighbour in the background: ch-2 is
        // started before any zap happens.
        for (var i = 0; i < 20 && !liveTv.startedChannels.contains('ch-2'); i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          liveTv.startedChannels,
          contains('ch-2'),
          reason: 'the launch must pre-tune the next channel while ch-1 plays',
        );
        // Let the pre-tune's URL resolution settle so the entry is stored.
        await tester.pump();
        await tester.pump();

        await tester.runAsync(() => state.debugSwitchLiveChannelForTesting(1));
        await tester.pump();

        expect(
          liveTv.startedChannels.where((key) => key == 'ch-2'),
          hasLength(1),
          reason: 'the zap must consume the pre-tuned session, not start ch-2 cold',
        );
        expect(
          player.openedUris,
          contains('http://example.invalid/ch-2.m3u8'),
          reason: 'the zap opens the URL the pre-tune already resolved',
        );

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });
}

/// The provider shell a live screen needs. With a [client], its server is
/// registered online and published as the live TV server so an in-player
/// channel zap resolves it the way the launch path did.
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

class _RecordingLivePlayer implements Player {
  final List<String> openedUris = [];

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

class _TuningSession implements LiveTvPlaybackSession {
  _TuningSession(this.key);

  final String key;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.retainSession;

  @override
  CaptureBuffer? get captureBuffer => null;

  @override
  bool get canTimeShift => false;

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

/// Starts a real session per channel and records every start, so the test can
/// tell a pre-tune start from a cold zap start.
class _TuningLiveTvSupport implements LiveTvSupport {
  final List<String> startedChannels = [];

  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async {
    startedChannels.add(channelKey);
    return _TuningSession(channelKey);
  }

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
