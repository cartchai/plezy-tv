// FAILING-FIRST — build #17 §6 (v2.25.13): the mini-player is STILL
// BLACK on live tunes that load fine (v2.25.12, Matt 2026-11-08 ~12:33
// EST: "Video rect sent: YES · still black", no frame ever reported).
// Two stacked causes, both in the tune path:
//
// (a) The mini-player's video area was wrapped in an opaque black
//     Container — and the MainScreen + LiveTvScreen Scaffolds above it
//     painted the opaque theme background too. The native surface below
//     the Flutter view can only show through transparent Flutter pixels,
//     so the Video's own transparent hole revealed black, not video.
//     The fullscreen player works because its Scaffold is transparent.
// (b) The rect arrived AFTER open(), and its container resize destroyed
//     and recreated the SurfaceView while mpv was starting, stranding
//     mpv on a placeholder surface with no frame ever reported.
//
// These tests drive the REAL mini-player tune path end-to-end — real
// controller, real LiveTvMiniPlayer widget, real Video widget, a
// rect-capable player — at the Fold's cover / unfolded / 16:9 viewports,
// and assert: the rect sent equals the laid-out hole, the rect is sent
// BEFORE the stream opens, no opaque widget paints over the video hole,
// and a frame is reported. Run against v2.25.12 the ancestor walk fails
// on the black Container (and the rect arrives after the open); the
// fixed tree passes.
//
// What this CANNOT prove in-harness (native surface rendering): whether
// mpv actually presents a frame onto the surface on the phone — the
// playback-restart here is a faithful stand-in, not a rendered frame.
// The phone verdict is the only pass/fail for the surface half; the
// diagnostic's rect line + reveal line are the evidence.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/mpv/models.dart' as mpv_models;
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/mpv/player/player_state.dart';
import 'package:plezy/mpv/player/player_streams.dart';
import 'package:plezy/mpv/player/video_rect_support.dart';
import 'package:plezy/mpv/video.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/live_tv_mini_player.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/theme/mono_theme.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

class _UnitApi extends XtreamApi {
  _UnitApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Trex News', categoryId: '1', tvArchive: true, tvArchiveDuration: 86400),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
  ];

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120)}) async {
    throw Exception('xmltv feed unavailable in mini-player tests');
  }
}

/// Rect-capable fake player: records every setVideoRect call and the
/// order of rect vs open, and can report a first frame via
/// playback-restart. Extends [Fake] so only the members the controller
/// and the Video widget touch need stubs.
final class _RectFakePlayer extends Fake implements Player, VideoRectSupport {
  _RectFakePlayer(this.events) {
    streams = PlayerStreams(
      playing: _playing.stream,
      completed: const Stream<bool>.empty(),
      buffering: _buffering.stream,
      position: const Stream<Duration>.empty(),
      duration: const Stream<Duration>.empty(),
      seekable: const Stream<bool>.empty(),
      buffer: const Stream<Duration>.empty(),
      volume: const Stream<double>.empty(),
      rate: const Stream<double>.empty(),
      tracks: const Stream<mpv_models.Tracks>.empty(),
      track: const Stream<mpv_models.TrackSelection>.empty(),
      log: _log.stream,
      error: _error.stream,
      audioDevice: const Stream<mpv_models.AudioDevice>.empty(),
      audioDevices: const Stream<List<mpv_models.AudioDevice>>.empty(),
      bufferRanges: const Stream<List<mpv_models.BufferRange>>.empty(),
      playbackRestart: _playbackRestart.stream,
      fileLoadFailed: _fileLoadFailed.stream,
      backendSwitched: const Stream<void>.empty(),
    );
  }

  /// Shared event log: 'rect' and 'open' in the order they happened.
  final List<String> events;

  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _log = StreamController<mpv_models.PlayerLog>.broadcast();
  final _error = StreamController<mpv_models.PlayerError>.broadcast();
  final _fileLoadFailed = StreamController<void>.broadcast();
  final _playbackRestart = StreamController<void>.broadcast();

  final List<Map<String, Object?>> rectCalls = [];
  final List<String> openedUris = [];
  var openCount = 0;
  var disposeCount = 0;

  @override
  late final PlayerStreams streams;

  @override
  PlayerState get state => const PlayerState();

  @override
  String get playerType => 'mpv';

  @override
  Future<void> setVideoRect({
    required int left,
    required int top,
    required int right,
    required int bottom,
    required double devicePixelRatio,
  }) async {
    events.add('rect');
    rectCalls.add({
      'left': left,
      'top': top,
      'right': right,
      'bottom': bottom,
      'devicePixelRatio': devicePixelRatio,
    });
  }

  @override
  Future<void> open(
    mpv_models.Media media, {
    bool play = true,
    bool isLive = false,
    List<mpv_models.SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    events.add('open');
    openCount++;
    openedUris.add(media.uri);
    if (play) _playing.add(true);
  }

  @override
  Future<void> setProperty(String name, String value) async {}

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async => disposeCount++;

  /// Report a first frame the way mpv does: a playback-restart event.
  void reportFirstFrame() => _playbackRestart.add(null);

  Future<void> close() async {
    await _playing.close();
    await _buffering.close();
    await _log.close();
    await _error.close();
    await _fileLoadFailed.close();
    await _playbackRestart.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IptvClient client;
  late MultiServerProvider provider;
  late List<LiveTvChannel> channels;
  late List<_RectFakePlayer> players;
  late List<String> events;
  late LiveTvMiniPlayerController controller;

  setUp(() async {
    resetSharedPreferencesForTest();
    IptvCatalogDiskCache.debugDisableDisk = true;
    addTearDown(() => IptvCatalogDiskCache.debugDisableDisk = false);
    client = IptvClient.xtream(
      xtreamConnection: XtreamConnection(
        id: 'trex',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pa' 'ss',
        createdAt: DateTime.utc(2026, 11, 6),
      ),
    );
    client.testXtreamApi = _UnitApi();
    channels = await client.iptvChannels();
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    provider = testMultiServerProvider(manager)
      ..debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: 'trex', dvrKey: 'dvr-trex')]);
    players = [];
    events = [];
    controller = LiveTvMiniPlayerController(playerFactory: () {
      final player = _RectFakePlayer(events);
      players.add(player);
      return player;
    });
  });

  tearDown(() async {
    await controller.dispose();
    for (final player in players) {
      await player.close();
    }
    provider.dispose();
  });

  /// Pump the real mini-player widget the way production renders it:
  /// inside transparent Scaffolds (MainScreen's portrait Scaffold is
  /// transparent on the Live TV tab and LiveTvScreen's is transparent,
  /// build #17) so the ancestor walk sees the production chain, not a
  /// test Scaffold's opaque background.
  Future<void> pumpMiniPlayer(WidgetTester tester, {required Size physicalSize, required double devicePixelRatio}) async {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark).copyWith(platform: TargetPlatform.android),
          home: Scaffold(
            backgroundColor: Colors.transparent,
            body: LiveTvMiniPlayer(
              controller: controller,
              nowPlayingTitle: 'The Office',
              onFullscreen: () {},
              onResume: () async {},
              onWatchLive: () async {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Drive a live tune through the real widget tree and assert the
  /// whole §6.6 checklist for one viewport.
  Future<void> tuneAndAssert(WidgetTester tester) async {
    final tuneFuture = controller.tune(
      channel: channels.firstWhere((c) => c.key == '100'),
      multiServer: provider,
    );
    // Frame 1: tuning state builds the mini-player; the Video mounts.
    await tester.pump();
    // Frame 2: the post-frame rect fires and the tune resumes to open.
    await tester.pump();
    // Fail-fast if the rect never came: the 500 ms rect-wait timeout
    // fires inside this pump instead of stalling the test runner.
    await tester.pump(const Duration(milliseconds: 600));
    await tuneFuture;

    expect(controller.status, LiveTvMiniPlayerStatus.active);
    expect(players.single.openCount, 1);

    // (1) The rect sent equals the laid-out hole, in physical pixels.
    final player = players.single;
    expect(player.rectCalls, hasLength(1));
    final renderBox = tester.renderObject<RenderBox>(find.byType(Video));
    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final dpr = tester.view.devicePixelRatio;
    expect(player.rectCalls.single, {
      'left': (position.dx * dpr).floor(),
      'top': (position.dy * dpr).floor(),
      'right': ((position.dx + size.width) * dpr).ceil(),
      'bottom': ((position.dy + size.height) * dpr).ceil(),
      'devicePixelRatio': dpr,
    });
    // The diagnostic carries the same rect, so the phone can prove it.
    expect(LiveTvMiniPlayerController.lastDiagnostic?.videoRectSent, isTrue);
    expect(LiveTvMiniPlayerController.lastDiagnostic?.videoRect, isNotNull);

    // (2) The rect is sent BEFORE the stream opens — mpv attaches to
    // the final surface once, instead of being stranded by a post-open
    // resize.
    expect(events.indexOf('rect'), lessThan(events.indexOf('open')));

    // (3) No opaque widget paints over the video hole: walk the Video's
    // ancestors and fail on any opaque colour. This single assertion
    // catches Cause 1 without any native code — on v2.25.12 the
    // mini-player's black Container fails it.
    final opaqueAncestors = <String>[];
    tester.element(find.byType(Video)).visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      Color? color;
      if (widget is Container) color = widget.color;
      if (widget is ColoredBox) color = widget.color;
      if (widget is Material) color = widget.color;
      if (color != null && (color.a * 255.0).round() == 0xFF) {
        opaqueAncestors.add('${widget.runtimeType}($color)');
      }
      return true;
    });
    expect(opaqueAncestors, isEmpty, reason: 'opaque widgets cover the video hole: $opaqueAncestors');

    // (4) A frame is reported: a playback-restart reveals the surface
    // by event (not by the watchdog), and the controller's cover lifts.
    player.reportFirstFrame();
    await tester.pump();
    expect(controller.firstFrameReveal, LiveTvMiniPlayerReveal.event);
    expect(controller.hasFirstFrame.value, isTrue);
  }

  group('build17 mini-player: rect, hole and frame at every aspect ratio', () {
    testWidgets('Fold cover 1080x2520 @2.625', (tester) async {
      await pumpMiniPlayer(tester, physicalSize: const Size(1080, 2520), devicePixelRatio: 2.625);
      await tuneAndAssert(tester);
    });

    testWidgets('Fold unfolded 1812x2176 @2.3', (tester) async {
      await pumpMiniPlayer(tester, physicalSize: const Size(1812, 2176), devicePixelRatio: 2.3);
      await tuneAndAssert(tester);
    });

    testWidgets('standard 16:9 phone 1080x1920 @2.625', (tester) async {
      await pumpMiniPlayer(tester, physicalSize: const Size(1080, 1920), devicePixelRatio: 2.625);
      await tuneAndAssert(tester);
    });
  });
}
