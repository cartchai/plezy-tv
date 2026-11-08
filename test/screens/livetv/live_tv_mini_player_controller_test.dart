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
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Trex News', categoryId: '1', tvArchive: true, tvArchiveDuration: 86400),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
  ];

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120)}) async {
    throw Exception('xmltv feed unavailable in controller tests');
  }
}

/// Same fake player as the widget tests: records opens so the tests can
/// prove one player serves every tune.
final class _FakePlayer implements Player {
  _FakePlayer() {
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

  /// Build #15: the controller reads the latched frame state and the
  /// backend name for the first-frame reveal and diagnostic.
  @override
  PlayerState state = const PlayerState();

  @override
  String get playerType => 'mpv';

  final List<String> openedUris = [];
  final List<double> volumes = [];
  var openCount = 0;
  var playCount = 0;
  var pauseCount = 0;
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
    openCount++;
    openedUris.add(media.uri);
    if (play) _playing.add(true);
  }

  @override
  Future<void> play() async {
    playCount++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _playing.add(false);
  }

  @override
  Future<void> playOrPause() async {
    if (playCount > pauseCount) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> stop() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> setProperty(String name, String value) async {}

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async => disposeCount++;

  /// Close the event sinks (the fake's streams are never consumed after
  /// the test disposes the player).
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
  late List<_FakePlayer> players;
  late LiveTvMiniPlayerController controller;

  setUp(() async {
    resetSharedPreferencesForTest();
    // The catalog disk cache (build #11) reads real dart:io, which never
    // completes in the test zone — switch it off; its behaviour is
    // covered by its own unit tests.
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
      final player = _FakePlayer();
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

  test('tune opens the live URL on one player and reports the channel', () async {
    await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);

    expect(controller.status, LiveTvMiniPlayerStatus.active);
    expect(controller.channel?.displayName, 'Trex News');
    expect(players, hasLength(1));
    expect(players.single.openCount, 1);
    expect(players.single.openedUris.single, contains('live'));
  });

  test('retune re-opens the same player for the new channel', () async {
    await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
    await controller.tune(channel: channels.firstWhere((c) => c.key == '101'), multiServer: provider);

    expect(players, hasLength(1));
    expect(players.single.openCount, 2);
    expect(controller.channel?.displayName, 'Trex Sports');
    expect(controller.status, LiveTvMiniPlayerStatus.active);
  });

  test('tune with a catch-up start opens the archive URL', () async {
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await controller.tune(
      channel: channels.firstWhere((c) => c.key == '100'),
      multiServer: provider,
      catchUpStartEpoch: nowEpoch - 1800,
    );

    expect(controller.status, LiveTvMiniPlayerStatus.active);
    expect(players.single.openedUris.single, contains('timeshift'));
  });

  test('tune with no live server fails, and retry stays failed for the same channel', () async {
    final orphan = LiveTvChannel(key: '999', title: 'Orphan', serverId: 'no-such-server');
    await controller.tune(channel: orphan, multiServer: provider);

    expect(controller.status, LiveTvMiniPlayerStatus.failed);
    expect(players, isEmpty);

    // Retry re-tunes the same channel, so it fails the same way — but
    // the controller stays usable for a real channel afterwards.
    await controller.retry(multiServer: provider);
    expect(controller.status, LiveTvMiniPlayerStatus.failed);

    await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
    expect(controller.status, LiveTvMiniPlayerStatus.active);
  });

  test('stop releases the player and returns to idle', () async {
    await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
    await controller.stop();

    expect(controller.status, LiveTvMiniPlayerStatus.idle);
    expect(controller.channel, isNull);
    expect(players.single.disposeCount, 1);
  });

  test('mute toggles the volume between 0 and 100', () async {
    await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);

    await controller.toggleMute();
    expect(controller.isMuted, isTrue);
    expect(players.single.volumes, [0]);

    await controller.toggleMute();
    expect(controller.isMuted, isFalse);
    expect(players.single.volumes, [0, 100]);
  });
}
