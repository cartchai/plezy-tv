// FAILING-FIRST — build #17 §5 (v2.25.13): a catch-up tune whose panel
// has no recording for the programme failed with the generic "Could not
// start the live channel" + Retry, and the diagnostic said only "file
// failed to load". mpv collapses every HTTP status into that one error,
// so the app never knew the panel had answered 404.
//
// The fix: the controller latches the HTTP status from the player's log
// stream (ffmpeg logs `http: HTTP error <status>` ahead of the error).
// 404 on a catch-up tune = missing recording (plain sentence naming the
// programme + channel, Watch live, no retry loop); 458 = line busy +
// Retry; anything with no HTTP status stays generic and is never
// reported as a missing recording.

import 'dart:async';
import 'dart:convert';

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

  /// Build #26: the fake's feed is a small canned String, so the stream
  /// is built on top of [getXmltv] — the production path streams, the fake
  /// does not need to.
  @override
  Stream<List<int>> getXmltvStream({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async* {
    yield utf8.encode(await getXmltv(timeout: timeout, abortTrigger: abortTrigger));
  }
  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    throw Exception('xmltv feed unavailable in controller tests');
  }
}

/// Same fake player as the controller tests, with a controllable log
/// stream so the tests can drive the exact lines ffmpeg emits when the
/// panel answers a timeshift URL.
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
      log: _log.stream,
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
  final _log = StreamController<mpv_models.PlayerLog>.broadcast();
  final _error = StreamController<mpv_models.PlayerError>.broadcast();
  final _fileLoadFailed = StreamController<void>.broadcast();

  @override
  late final PlayerStreams streams;

  @override
  PlayerState state = const PlayerState();

  @override
  String get playerType => 'mpv';

  final List<String> openedUris = [];
  var openCount = 0;
  var disposeCount = 0;

  /// Drive a server rejection the way mpv reports it: ffmpeg's
  /// warn-level log line first, then the end-file failure.
  Future<void> failOpenWithHttpStatus(int status) async {
    _log.add(
      mpv_models.PlayerLog(
        level: mpv_models.PlayerLogLevel.warn,
        prefix: 'ffmpeg',
        text: 'http: HTTP error $status Not Found',
      ),
    );
    // The log subscription is async: let it latch before the failure
    // lands, the way the real demuxer orders them.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    _fileLoadFailed.add(null);
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> failOpenWithoutStatus() async {
    _fileLoadFailed.add(null);
    await Future<void>.delayed(Duration.zero);
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
    openCount++;
    openedUris.add(media.uri);
    if (play) _playing.add(true);
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
    await _log.close();
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

  Future<void> tuneCatchUp() async {
    final nowEpoch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await controller.tune(
      channel: channels.firstWhere((c) => c.key == '100'),
      multiServer: provider,
      catchUpStartEpoch: nowEpoch - 1800,
      catchUpProgrammeTitle: 'The Office',
    );
    expect(controller.status, LiveTvMiniPlayerStatus.active);
    expect(players.single.openedUris.single, contains('timeshift'));
  }

  group('build17 catch-up: the panel answer decides the failure', () {
    test('404 on a catch-up tune is a missing recording, named, with Watch live', () async {
      await tuneCatchUp();
      await players.single.failOpenWithHttpStatus(404);

      expect(controller.status, LiveTvMiniPlayerStatus.failed);
      expect(controller.failureKind, LiveTvMiniPlayerFailureKind.missingRecording);
      // The diagnostic carries the state distinctly — not "file failed
      // to load" — naming programme and channel.
      final failReason = LiveTvMiniPlayerController.lastDiagnostic?.failReason;
      expect(failReason, contains('The Office'));
      expect(failReason, contains('Trex News'));
      expect(failReason, contains('no recording'));
      // Watch live re-tunes the same channel WITHOUT the archive (the
      // failed tune released its player, so this is a fresh one).
      await controller.watchLive(multiServer: provider);
      expect(controller.status, LiveTvMiniPlayerStatus.active);
      expect(players, hasLength(2));
      expect(players.last.openedUris.last, contains('live'));
      expect(players.last.openedUris.last, isNot(contains('timeshift')));
    });

    test('458 on a catch-up tune is line busy, never a missing recording', () async {
      await tuneCatchUp();
      await players.single.failOpenWithHttpStatus(458);

      expect(controller.status, LiveTvMiniPlayerStatus.failed);
      expect(controller.failureKind, LiveTvMiniPlayerFailureKind.lineBusy);
      final failReason = LiveTvMiniPlayerController.lastDiagnostic?.failReason;
      expect(failReason, contains('458'));
      expect(failReason, isNot(contains('no recording')));
    });

    test('a failure with no HTTP status stays generic', () async {
      await tuneCatchUp();
      await players.single.failOpenWithoutStatus();

      expect(controller.status, LiveTvMiniPlayerStatus.failed);
      expect(controller.failureKind, LiveTvMiniPlayerFailureKind.generic);
      expect(
        LiveTvMiniPlayerController.lastDiagnostic?.failReason,
        'file failed to load',
      );
    });

    test('404 on a LIVE tune is generic, not a missing recording', () async {
      await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
      expect(controller.status, LiveTvMiniPlayerStatus.active);
      await players.single.failOpenWithHttpStatus(404);

      expect(controller.status, LiveTvMiniPlayerStatus.failed);
      expect(controller.failureKind, LiveTvMiniPlayerFailureKind.generic);
      expect(
        LiveTvMiniPlayerController.lastDiagnostic?.failReason,
        'file failed to load',
      );
    });

    test('a stale 404 from an earlier tune never mislabels the next failure', () async {
      await tuneCatchUp();
      await players.single.failOpenWithHttpStatus(404);
      expect(controller.failureKind, LiveTvMiniPlayerFailureKind.missingRecording);

      // Live tune on the same player, no log line this time (the failed
      // tune released its player, so this is a fresh one).
      await controller.tune(channel: channels.firstWhere((c) => c.key == '100'), multiServer: provider);
      expect(controller.status, LiveTvMiniPlayerStatus.active);
      await players.last.failOpenWithoutStatus();

      expect(controller.failureKind, LiveTvMiniPlayerFailureKind.generic);
    });
  });
}
