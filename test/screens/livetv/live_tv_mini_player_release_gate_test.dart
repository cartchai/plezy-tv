// Build #28 — mini-player retune waits for release (v1.0.9).
//
// Same rule as the full-player zap, in the mini-player: on a
// one-connection line the retune must not open the new channel until the
// old stream is released (player stop). Proves it with the real
// [IptvClient] and a fake panel: the client's max_connections is unknown
// here (no health probe ran), so it waits — unknown means wait.
//
// Failing-first: on the base (6fe84db64) the retune opens the new channel
// without stopping the old one, so the "open waits" assertion fails there.
// No live panel: fake API only.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/mpv/models.dart' as mpv_models;
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/mpv/player/player_state.dart';
import 'package:plezy/mpv/player/player_streams.dart';
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
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Trex News', categoryId: '1', tvArchive: true, tvArchiveDuration: 86400),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
  ];

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    throw Exception('xmltv feed unavailable in controller tests');
  }
}

/// Same fake player as live_tv_mini_player_controller_test.dart, plus a
/// test-held stop and an event log so the test can prove the open waits
/// for the release.
final class _ReleaseRecordingPlayer implements Player {
  _ReleaseRecordingPlayer() {
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
      log: const Stream<mpv_models.PlayerLog>.empty(),
      error: _error.stream,
      audioDevice: const Stream<mpv_models.AudioDevice>.empty(),
      audioDevices: const Stream<List<mpv_models.AudioDevice>>.empty(),
      bufferRanges: const Stream<List<mpv_models.BufferRange>>.empty(),
      playbackRestart: const Stream<void>.empty(),
      fileLoadFailed: _fileLoadFailed.stream,
      backendSwitched: const Stream<void>.empty(),
    );
  }

  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _error = StreamController<mpv_models.PlayerError>.broadcast();
  final _fileLoadFailed = StreamController<void>.broadcast();

  @override
  late final PlayerStreams streams;

  @override
  PlayerState state = const PlayerState();

  @override
  String get playerType => 'mpv';

  final List<String> openedUris = [];
  final List<String> events = [];
  Completer<void>? stopGate;
  var disposeCount = 0;

  @override
  Future<void> open(
    mpv_models.Media media, {
    bool play = true,
    bool isLive = false,
    List<mpv_models.SubtitleTrack>? externalSubtitles,
    Duration? timelineDuration,
    Duration timelineOffset = Duration.zero,
  }) async {
    openedUris.add(media.uri);
    events.add('open:${media.uri}');
    if (play) _playing.add(true);
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> stop() async {
    events.add('stop-started');
    final gate = stopGate;
    if (gate != null) await gate.future;
    events.add('stop-finished');
    _playing.add(false);
  }

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
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late IptvClient client;
  late MultiServerProvider provider;
  late List<LiveTvChannel> channels;
  late List<_ReleaseRecordingPlayer> players;
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
    controller = LiveTvMiniPlayerController(playerFactory: () {
      final player = _ReleaseRecordingPlayer();
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

  test('a retune waits for the old stream to release before opening the next', () async {
    await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
    expect(controller.status, LiveTvMiniPlayerStatus.active);
    expect(players.single.openedUris, hasLength(1));

    // Hold the stop open: the retune's release must wait on it.
    final stopGate = Completer<void>();
    players.single.stopGate = stopGate;
    final retune = controller.tune(channel: channels.firstWhere((c) => c.key == '101'), multiServer: provider);
    // Give the retune real time to reach the release.
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(players.single.events, contains('stop-started'), reason: 'the retune must stop the old stream first');
    expect(
      players.single.openedUris,
      hasLength(1),
      reason: 'the new channel must not open while the old stream is still being released',
    );

    // Release the stop: the retune proceeds and opens ch-101 on the
    // same player.
    stopGate.complete();
    await retune;

    expect(players, hasLength(1));
    expect(players.single.openedUris, hasLength(2));
    expect(players.single.openedUris.last, contains('101'));
    expect(controller.channel?.displayName, 'Trex Sports');
    expect(controller.status, LiveTvMiniPlayerStatus.active);
    final stopStarted = players.single.events.indexOf('stop-started');
    final stopFinished = players.single.events.indexOf('stop-finished');
    final opened = players.single.events.indexWhere((e) => e.startsWith('open:') && e.contains('101'));
    expect(stopStarted, greaterThanOrEqualTo(0));
    expect(stopFinished, greaterThan(stopStarted));
    expect(opened, greaterThan(stopFinished), reason: 'open must follow the release, not overlap it');
  });
}
