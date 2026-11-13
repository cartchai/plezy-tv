import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/mpv/models.dart' as mpv_models;
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/mpv/player/player_state.dart';
import 'package:plezy/mpv/player/player_streams.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: 'pa' 'ss',
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Fake provider: two live channels (100 has catch-up, 101 does not) and
/// a short-EPG that only resolves when the test completes it.
class _MiniPlayerApi extends XtreamApi {
  _MiniPlayerApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final Map<String, Completer<List<XtreamEpgProgram>>> pending = {};
  int epgCalls = 0;

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Trex News', categoryId: '1', tvArchive: true, tvArchiveDuration: 86400),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) {
    epgCalls++;
    final completer = Completer<List<XtreamEpgProgram>>();
    pending[streamId] = completer;
    return completer.future;
  }

  /// Build #26: the fake's feed is a small canned String, so the stream
  /// is built on top of [getXmltv] — the production path streams, the fake
  /// does not need to.
  @override
  Stream<List<int>> getXmltvStream({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async* {
    yield utf8.encode(await getXmltv(timeout: timeout, abortTrigger: abortTrigger));
  }
  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    throw Exception('xmltv feed unavailable in mini-player tests');
  }

  void complete(String streamId, List<XtreamEpgProgram> programs) => pending[streamId]?.complete(programs);

  void completeEmpty(String streamId) => pending[streamId]?.complete(const []);
}

XtreamEpgProgram _epg({
  String id = 'p1',
  String title = 'Show',
  required DateTime start,
  required DateTime end,
}) => XtreamEpgProgram(
  id: id,
  title: title,
  description: '',
  startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
  stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
);

/// A fake [Player] that records every open/stop/dispose so the tests can
/// prove the guide drives exactly ONE player: scrolling never re-tunes,
/// tapping a second channel re-opens the same instance.
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
  final List<String> setProperties = [];
  final List<double> volumes = [];
  var openCount = 0;
  var playCount = 0;
  var pauseCount = 0;
  var stopCount = 0;
  var disposeCount = 0;
  var isPlaying = false;

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
    if (play) {
      isPlaying = true;
      _playing.add(true);
    }
  }

  @override
  Future<void> play() async {
    playCount++;
    isPlaying = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<void> playOrPause() async {
    if (isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  Future<void> stop() async {
    stopCount++;
    isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> setProperty(String name, String value) async => setProperties.add('$name=$value');

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

final class _MiniPlayerHarness {
  final _MiniPlayerApi api = _MiniPlayerApi();
  late final IptvClient client;
  late final MultiServerProvider provider;
  late final List<LiveTvChannel> channels;

  /// Every player the controller creates, in creation order.
  final List<_FakePlayer> players = [];

  /// Channels the test's fullscreen stub was asked to open.
  final List<LiveTvChannel> fullscreenRequests = [];

  Future<void> init() async {
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    channels = await client.iptvChannels();
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    provider = testMultiServerProvider(manager)
      ..debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: 'trex', dvrKey: 'dvr-trex')]);
  }

  Player _playerFactory() {
    final player = _FakePlayer();
    players.add(player);
    return player;
  }

  /// Portrait phone (Fold 7 cover-ish): the mini-player is portrait-only.
  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: ChangeNotifierProvider<MultiServerProvider>.value(
            value: provider,
            child: MaterialApp(
              // The platform comes from the theme, not the global
              // debugDefaultTargetPlatformOverride (the binding verifies
              // that debug variable before any tearDown runs).
              theme: monoTheme(MonoPalette.dark).copyWith(platform: TargetPlatform.android),
              home: Scaffold(
                body: GuideTab(
                  channels: channels,
                  debugPlayerFactory: _playerFactory,
                  debugVideoBuilder: (context, player) => const SizedBox(key: Key('mini-player-video-surface')),
                  debugFullscreenHandler: (channel) async => fullscreenRequests.add(channel),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> rotateLandscape(WidgetTester tester) async {
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
  }

  /// Pump until the guide has asked for the EPG of [count] channels
  /// (same real-event-loop yield as the guide EPG tests: the persisted
  /// cache read is real dart:io and never completes in fake async).
  Future<void> waitForEpgCalls(WidgetTester tester, int count) async {
    for (var i = 0; i < 10 && api.epgCalls < count; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
    expect(api.epgCalls, count);
    // Build #15: the xmltv feed read is real disk I/O kicked in the
    // background alongside get_short_epg. Real I/O only completes
    // inside runAsync in the fake async zone, and pumpAndSettle alone
    // never delivers it — give the background read one more real-async
    // window so the fetch chain can settle.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  Future<void> tapChannel(WidgetTester tester, String name) async {
    await tester.tap(find.text(name));
    await tester.pump();
    await tester.pump();
  }

  void dispose() {
    for (final player in players) {
      unawaited(player.close());
    }
    provider.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory epgTempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_miniplayer_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  testWidgets('portrait guide shows no mini-player before any channel is tapped', (tester) async {
    final harness = _MiniPlayerHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);
    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('live-tv-mini-player')), findsNothing);
    expect(harness.players, isEmpty);
  });

  testWidgets('tapping a channel shows the mini-player above the guide on the same player', (tester) async {
    final harness = _MiniPlayerHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);
    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    await harness.tapChannel(tester, 'Trex News');

    // The Plex reference: video on top, guide below, both visible at once.
    expect(find.byKey(const Key('live-tv-mini-player')), findsOneWidget);
    expect(find.byKey(const Key('mini-player-video-surface')), findsOneWidget);
    // v1.1.1: channels with no EPG render hourly "No information
    // available" blocks again (Task G restored), not one block per row.
    expect(find.text('No information available'), findsWidgets);
    // Exactly one player, one open, live URL, scrubber blocked like the
    // full player (v2.25.5 block scrubber).
    expect(harness.players, hasLength(1));
    expect(harness.players.single.openCount, 1);
    expect(harness.players.single.openedUris.single, contains('live'));
    expect(harness.players.single.setProperties, contains('force-seekable=no'));
    // The mini-player names the channel it is playing.
    expect(find.descendant(of: find.byKey(const Key('live-tv-mini-player')), matching: find.text('Trex News')), findsOneWidget);
  });

  testWidgets('tapping a second channel retunes the same player', (tester) async {
    final harness = _MiniPlayerHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);
    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    await harness.tapChannel(tester, 'Trex News');
    await harness.tapChannel(tester, 'Trex Sports');

    // One player only (max_connections = 1): the second tap re-opens the
    // same instance instead of creating another stream.
    expect(harness.players, hasLength(1));
    expect(harness.players.single.openCount, 2);
    expect(
      find.descendant(of: find.byKey(const Key('live-tv-mini-player')), matching: find.text('Trex Sports')),
      findsOneWidget,
    );
  });

  testWidgets('scrolling the guide does not re-tune the mini-player', (tester) async {
    final harness = _MiniPlayerHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);
    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    await harness.tapChannel(tester, 'Trex News');
    expect(harness.players.single.openCount, 1);

    // Drag the programme rows (inside the scrollable grid) both ways.
    // v1.1.1: the rows are hourly "No information available" blocks
    // again (Task G restored), not one "No guide data" block per row.
    await tester.drag(find.text('No information available').first, const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.drag(find.text('No information available').first, const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(harness.players.single.openCount, 1);
    expect(find.byKey(const Key('live-tv-mini-player')), findsOneWidget);
  });

  testWidgets('rotating to landscape stops playback and hides the mini-player', (tester) async {
    final harness = _MiniPlayerHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);
    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    await harness.tapChannel(tester, 'Trex News');
    expect(find.byKey(const Key('live-tv-mini-player')), findsOneWidget);

    // Landscape behaves as today (fullscreen video as normal): no
    // mini-player, and the stream is released rather than playing audio
    // behind a guide with no video surface.
    await harness.rotateLandscape(tester);

    expect(find.byKey(const Key('live-tv-mini-player')), findsNothing);
    expect(harness.players.single.disposeCount, 1);
  });

  testWidgets('fullscreen button stops the mini-player and hands the channel to fullscreen', (tester) async {
    final harness = _MiniPlayerHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);
    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    await harness.tapChannel(tester, 'Trex News');
    await tester.tap(find.byKey(const Key('mini-player-fullscreen')));
    await tester.pump();
    await tester.pump();

    expect(harness.fullscreenRequests.map((c) => c.displayName), ['Trex News']);
    expect(harness.players.single.disposeCount, 1);
    // The slot stays as a stopped card for the same channel, so one tap
    // resumes it instead of the mini-player vanishing.
    expect(find.byKey(const Key('live-tv-mini-player')), findsOneWidget);
    expect(find.byKey(const Key('mini-player-resume')), findsOneWidget);
  });

  testWidgets('close button stops playback and hides the mini-player', (tester) async {
    final harness = _MiniPlayerHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);
    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    await harness.tapChannel(tester, 'Trex News');
    await tester.tap(find.byKey(const Key('mini-player-close')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('live-tv-mini-player')), findsNothing);
    expect(harness.players.single.disposeCount, 1);
  });

  testWidgets('catch-up from the guide tunes the mini-player at the programme start', (tester) async {
    final harness = _MiniPlayerHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    final now = DateTime.now();
    harness.api.complete('100', [
      _epg(
        id: 'past',
        title: 'Past Show',
        start: now.subtract(const Duration(minutes: 50)),
        end: now.subtract(const Duration(minutes: 10)),
      ),
      _epg(id: 'live', title: 'Live Show', start: now.subtract(const Duration(minutes: 10)), end: now.add(const Duration(minutes: 50))),
    ]);
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Past Show'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Watch from start'), findsOneWidget);

    await tester.tap(find.textContaining('Watch from start'));
    await tester.pump();
    await tester.pump();

    // The catch-up entry point routes into the mini-player (not the full
    // player) and opens the archive at the programme start.
    expect(find.byKey(const Key('live-tv-mini-player')), findsOneWidget);
    expect(harness.players.single.openCount, 1);
    expect(harness.players.single.openedUris.single, contains('timeshift'));
  });
}
