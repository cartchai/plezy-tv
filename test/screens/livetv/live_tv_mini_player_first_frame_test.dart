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
import 'package:plezy/mpv/video.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/live_tv_mini_player.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';

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
    throw Exception('xmltv feed unavailable in first-frame tests');
  }
}

/// A fake [Player] whose first-frame signals the test drives by hand, so
/// each phone event ordering from the build #15 research can be replayed:
/// restart during open, restart late, restart never, latch already set.
///
/// Unlike the controller test's fake, this one implements [state] and
/// [playerType] — the controller reads both for the first-frame reveal and
/// the on-device diagnostic, and a fake that throws on them would hide a
/// real ordering behind a NoSuchMethodError.
final class _FirstFrameFakePlayer implements Player {
  _FirstFrameFakePlayer();

  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _error = StreamController<mpv_models.PlayerError>.broadcast();
  final _fileLoadFailed = StreamController<void>.broadcast();
  final _playbackRestart = StreamController<void>.broadcast();

  @override
  PlayerStreams get streams => PlayerStreams(
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
    log: const Stream<mpv_models.PlayerLog>.empty(),
    error: _error.stream,
    audioDevice: const Stream<mpv_models.AudioDevice>.empty(),
    audioDevices: const Stream<List<mpv_models.AudioDevice>>.empty(),
    bufferRanges: const Stream<List<mpv_models.BufferRange>>.empty(),
    playbackRestart: _playbackRestart.stream,
    fileLoadFailed: _fileLoadFailed.stream,
    backendSwitched: const Stream<void>.empty(),
  );

  @override
  PlayerState state = const PlayerState();

  @override
  String get playerType => 'mpv';

  /// When true, open() emits a playback-restart before returning — the
  /// "restart fires during open" ordering (b).
  bool emitRestartDuringOpen = false;

  /// When true, open() latches hasRenderedFrame in [state] before
  /// returning WITHOUT emitting a restart — the "already rendered"
  /// ordering, which only a post-open latch check can catch.
  bool latchFrameDuringOpen = false;

  var openCount = 0;
  var disposeCount = 0;

  /// Drive a playback-restart into the controller, as the backend would.
  void emitRestart() {
    state = state.copyWith(hasRenderedFrame: true);
    _playbackRestart.add(null);
  }

  @override
  Future<int?> open(
    mpv_models.Media media, {
    bool play = true,
    bool isLive = false,
    List<mpv_models.SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    openCount++;
    // A new file resets the latch (start-file), like the real backend —
    // without this the second tune would see the first tune's frame.
    state = state.copyWith(hasRenderedFrame: false);
    if (latchFrameDuringOpen) state = state.copyWith(hasRenderedFrame: true);
    if (emitRestartDuringOpen) emitRestart();
    if (play) _playing.add(true);
    return null;
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> stop() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setProperty(String name, String value) async {}

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async => disposeCount++;

  Future<void> close() async {
    await _playing.close();
    await _buffering.close();
    await _error.close();
    await _fileLoadFailed.close();
    await _playbackRestart.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IptvClient client;
  late MultiServerProvider provider;
  late List<LiveTvChannel> channels;
  late List<_FirstFrameFakePlayer> players;
  late LiveTvMiniPlayerController controller;

  /// Flags the player factory applies to the player it creates (the
  /// player is created lazily inside tune(), after the session awaits,
  /// so the test sets these BEFORE calling tune()).
  var emitRestartDuringOpen = false;
  var latchFrameDuringOpen = false;

  /// Flush broadcast stream deliveries (they land a microtask after add).
  Future<void> flushEvents() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() async {
    resetSharedPreferencesForTest();
    IptvCatalogDiskCache.debugDisableDisk = true;
    addTearDown(() => IptvCatalogDiskCache.debugDisableDisk = false);
    LiveTvMiniPlayerController.lastDiagnostic = null;
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
    emitRestartDuringOpen = false;
    latchFrameDuringOpen = false;
    controller = LiveTvMiniPlayerController(
      playerFactory: () {
        final player = _FirstFrameFakePlayer()
          ..emitRestartDuringOpen = emitRestartDuringOpen
          ..latchFrameDuringOpen = latchFrameDuringOpen;
        players.add(player);
        return player;
      },
      // Short grace so the watchdog tests run in real time.
      firstFrameWatchdogGrace: const Duration(milliseconds: 100),
    );
  });

  tearDown(() async {
    await controller.dispose();
    for (final player in players) {
      await player.close();
    }
    provider.dispose();
  });

  LiveTvChannel news() => channels.firstWhere((c) => c.key == '100');
  LiveTvChannel sports() => channels.firstWhere((c) => c.key == '101');

  test('(b) restart fires during open: revealed by the event, before any Video mounts', () async {
    emitRestartDuringOpen = true;
    await controller.tune(channel: news(), multiServer: provider);
    await flushEvents();

    expect(controller.hasFirstFrame.value, isTrue);
    expect(controller.firstFrameReveal, LiveTvMiniPlayerReveal.event);
    expect(controller.firstFrameRestartObserved, isTrue);
  });

  test('(a) restart arrives LATE, after tune returns: still reveals', () async {
    await controller.tune(channel: news(), multiServer: provider);
    await flushEvents();

    expect(controller.hasFirstFrame.value, isFalse);

    players.single.emitRestart();
    await flushEvents();

    expect(controller.hasFirstFrame.value, isTrue);
    expect(controller.firstFrameReveal, LiveTvMiniPlayerReveal.event);
  });

  test('(c) restart NEVER fires: the watchdog reveals while playing', () async {
    await controller.tune(channel: news(), multiServer: provider);
    await flushEvents();

    expect(controller.hasFirstFrame.value, isFalse);

    // The grace is 100ms in this test; wait past it.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await flushEvents();

    expect(controller.hasFirstFrame.value, isTrue);
    expect(controller.firstFrameReveal, LiveTvMiniPlayerReveal.watchdog);
    expect(controller.firstFrameRestartObserved, isFalse);
  });

  test('(d) restart dropped by the backend (mismatched source id): watchdog still reveals', () async {
    // At the controller level a dropped restart is indistinguishable from
    // one that never arrives — the event simply never reaches the
    // subscription. The watchdog is what saves the phone from a permanent
    // black box in that case.
    await controller.tune(channel: news(), multiServer: provider);
    await flushEvents();
    expect(controller.hasFirstFrame.value, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 300));
    await flushEvents();

    expect(controller.hasFirstFrame.value, isTrue);
    expect(controller.firstFrameReveal, LiveTvMiniPlayerReveal.watchdog);
  });

  test('(e) retune resets the reveal and the new open re-reveals', () async {
    emitRestartDuringOpen = true;
    await controller.tune(channel: news(), multiServer: provider);
    await flushEvents();
    expect(controller.hasFirstFrame.value, isTrue);

    // The reset happens synchronously at the top of the second tune().
    // The player is reused, so flip the flag on the live player object.
    players.single.emitRestartDuringOpen = false;
    final secondTune = controller.tune(channel: sports(), multiServer: provider);
    expect(controller.hasFirstFrame.value, isFalse);
    expect(controller.firstFrameReveal, LiveTvMiniPlayerReveal.none);
    await secondTune;
    await flushEvents();
    expect(controller.hasFirstFrame.value, isFalse);

    players.single.emitRestart();
    await flushEvents();
    expect(controller.hasFirstFrame.value, isTrue);
    expect(controller.firstFrameReveal, LiveTvMiniPlayerReveal.event);
  });

  test('latch already set in state at open: post-open check reveals without any event', () async {
    latchFrameDuringOpen = true;
    await controller.tune(channel: news(), multiServer: provider);
    await flushEvents();

    expect(controller.hasFirstFrame.value, isTrue);
    expect(controller.firstFrameReveal, LiveTvMiniPlayerReveal.latch);
    expect(controller.firstFrameRestartObserved, isFalse);
  });

  test('diagnostic records the last tune for the on-device readout', () async {
    emitRestartDuringOpen = true;
    await controller.tune(channel: news(), multiServer: provider);
    await flushEvents();

    final diagnostic = LiveTvMiniPlayerController.lastDiagnostic;
    expect(diagnostic, isNotNull);
    expect(diagnostic!.channelName, 'Trex News');
    expect(diagnostic.backend, 'mpv');
    expect(diagnostic.restartObserved, isTrue);
    expect(diagnostic.reveal, LiveTvMiniPlayerReveal.event);
    expect(diagnostic.msToReveal, isNotNull);
  });

  testWidgets('mini-player Video cover lifts when the controller reveals (wiring)', (tester) async {
    // No restart ever arrives: the only reveal is the watchdog.
    await controller.tune(channel: news(), multiServer: provider);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: LiveTvMiniPlayer(
              controller: controller,
              nowPlayingTitle: 'Show',
              onFullscreen: () {},
              onResume: () async {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // The cover is the ColoredBox inside the Video surface (the outer
    // black container and the info bar are ColoredBoxes too — scope the
    // finder to the Video so only its cover is counted).
    Finder cover() => find.descendant(of: find.byType(Video), matching: find.byType(ColoredBox));
    expect(cover(), findsOneWidget);
    expect(tester.widget<ColoredBox>(cover()).color, Colors.black);

    // Past the 100ms watchdog grace the controller reveals and the cover lifts.
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(cover(), findsOneWidget);
    expect(tester.widget<ColoredBox>(cover()).color, Colors.transparent);
  });
}
