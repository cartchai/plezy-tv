// BUILD #22 — stream User-Agent: the configured Xtream UA on every stream
// open (live, VOD, series episode, catch-up) and on panel image fetches.
//
// Build #20 fixed the API client (every player_api.php call sends VLC),
// but streams opened with mpv/ffmpeg's default UA and posters said
// 'Plezy' — three identities to the same panel. If the panel enforces UA
// on streams, live TV and VOD 403 while browsing works.
//
// Failing-first: on base 652db5f90, IptvClient.streamHeaders is `const {}`
// (unit + resolver tests fail), LiveTvPlaybackSession has no streamHeaders
// and MediaImageHelper has no artworkHeadersFor / serverArtworkProvider
// takes no headers (those tests fail to compile), and the mini-player
// widget tests open with Accept-Language only (UA assertion fails).
//
// No live panel: fakes only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/models/transcode_quality_preset.dart';
import 'package:plezy/mpv/models.dart' as mpv_models;
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/mpv/player/player_state.dart';
import 'package:plezy/mpv/player/player_streams.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/services/playback_source_resolver.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/media_image_helper.dart';
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

M3uConnection _m3uConnection() => M3uConnection(
  id: 'm3u',
  name: 'M3U',
  playlistUrl: 'https://panel.example.com:8080/get.php?username=user&password=pass&type=m3u_plus&output=ts',
  createdAt: DateTime.utc(2026, 11, 6),
);

/// A non-IPTV client: artwork fetches for any other backend keep the app's
/// name ('PlezTV'), exactly as before.
class _OtherBackendClient implements MediaServerClient {
  @override
  ServerId get serverId => ServerId('plex');

  @override
  MediaBackend get backend => MediaBackend.plex;

  @override
  double get watchedThreshold => 0.9;

  @override
  Map<String, String> get streamHeaders => const {};

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake provider: two live channels (100 has catch-up, 101 does not).
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
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(await getXmltv(timeout: timeout, abortTrigger: abortTrigger))),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }
  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    throw Exception('xmltv feed unavailable in stream-UA tests');
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

/// A fake [Player] that records every [Media] it opens, headers included,
/// so the tests can prove the stream open carries the configured UA.
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

  @override
  PlayerState state = const PlayerState();

  @override
  String get playerType => 'mpv';

  final List<mpv_models.Media> openedMedia = [];
  final List<String> setProperties = [];
  var openCount = 0;
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
    openedMedia.add(media);
    if (play) {
      isPlaying = true;
      _playing.add(true);
    }
  }

  @override
  Future<void> play() async {
    isPlaying = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
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
    isPlaying = false;
    _playing.add(false);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setProperty(String name, String value) async => setProperties.add('$name=$value');

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

final class _MiniPlayerHarness {
  final _MiniPlayerApi api = _MiniPlayerApi();
  late final IptvClient client;
  late final MultiServerProvider provider;
  late final List<LiveTvChannel> channels;

  final List<_FakePlayer> players = [];

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
              theme: monoTheme(MonoPalette.dark).copyWith(platform: TargetPlatform.android),
              home: Scaffold(
                body: GuideTab(
                  channels: channels,
                  debugPlayerFactory: _playerFactory,
                  debugVideoBuilder: (context, player) => const SizedBox(key: Key('mini-player-video-surface')),
                  debugFullscreenHandler: (channel) async {},
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

  Future<void> waitForEpgCalls(WidgetTester tester, int count) async {
    for (var i = 0; i < 10 && api.epgCalls < count; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
    expect(api.epgCalls, count);
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
    epgTempDir = await Directory.systemTemp.createTemp('plezy_stream_ua_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  group('Build #22 — IptvClient.streamHeaders (VOD / series / movie opens)', () {
    test('default is VLC', () {
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      expect(client.streamHeaders, {'User-Agent': 'VLC'});
    });

    test('the configured choice flows through', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());

      await settings.write(SettingsService.iptvXtreamUserAgent, 'smarters');
      expect(client.streamHeaders, {'User-Agent': 'IPTVSmartersPro'});

      await settings.write(SettingsService.iptvXtreamUserAgent, 'browser');
      expect(
        client.streamHeaders,
        {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'},
      );
    });

    test('custom text flows through; blank custom and unknown choice fall back to VLC', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());

      await settings.write(SettingsService.iptvXtreamUserAgent, 'custom');
      await settings.write(SettingsService.iptvXtreamUserAgentCustom, 'MyAgent/9');
      expect(client.streamHeaders, {'User-Agent': 'MyAgent/9'});

      await settings.write(SettingsService.iptvXtreamUserAgentCustom, '   ');
      expect(client.streamHeaders, {'User-Agent': 'VLC'});

      await settings.write(SettingsService.iptvXtreamUserAgent, 'bogus-choice');
      expect(client.streamHeaders, {'User-Agent': 'VLC'});
    });

    test('a setting change applies to the next read, no client rebuild', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      expect(client.streamHeaders, {'User-Agent': 'VLC'});

      await settings.write(SettingsService.iptvXtreamUserAgent, 'smarters');
      expect(client.streamHeaders, {'User-Agent': 'IPTVSmartersPro'});
    });

    test('an M3U client sends the same configured UA', () {
      final client = IptvClient.m3u(m3uConnection: _m3uConnection());
      expect(client.streamHeaders, {'User-Agent': 'VLC'});
    });
  });

  group('Build #22 — live session headers (live TV + catch-up opens)', () {
    test('the session carries the UA alongside Accept-Language', () {
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      final session = IptvLiveTvPlaybackSession(
        client: client,
        channelKey: '100',
        liveUrl: 'https://panel.example.com:8080/live/user/pass/100.m3u8',
        archiveDurationSeconds: 86400,
      );
      expect(session.streamHeaders, {
        'Accept-Language': 'en',
        'User-Agent': 'VLC',
      });
    });

    test('the session re-reads the setting, so a change applies to the next open', () async {
      final settings = await SettingsService.getInstance();
      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      final session = IptvLiveTvPlaybackSession(
        client: client,
        channelKey: '100',
        liveUrl: 'https://panel.example.com:8080/live/user/pass/100.m3u8',
        archiveDurationSeconds: 0,
      );
      expect(session.streamHeaders['User-Agent'], 'VLC');

      await settings.write(SettingsService.iptvXtreamUserAgent, 'custom');
      await settings.write(SettingsService.iptvXtreamUserAgentCustom, 'MyAgent/9');
      expect(session.streamHeaders['User-Agent'], 'MyAgent/9');
    });
  });

  group('Build #22 — VOD resolve carries the UA into PlaybackContext', () {
    test('an Xtream movie resolve puts the UA in context.streamHeaders', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final manager = MultiServerManager();
      addTearDown(() async {
        manager.dispose();
        await db.close();
      });

      final client = IptvClient.xtream(xtreamConnection: _trexConnection());
      manager.debugRegisterClientForTesting(client, online: true);

      final context = await PlaybackSourceResolver(serverManager: manager, database: db).resolve(
        PlaybackInitializationOptions(
          metadata: XtreamMediaItem(
            id: 'movie-2',
            kind: MediaKind.movie,
            serverId: 'trex',
            streamUrl: 'https://panel.example.com:8080/movie/user/pass/2.mp4',
          ),
          selectedMediaIndex: 0,
          qualityPreset: TranscodeQualityPreset.original,
        ),
        offlineLibraryMode: false,
      );

      expect(context.result.videoUrl, 'https://panel.example.com:8080/movie/user/pass/2.mp4');
      expect(context.streamHeaders, containsPair('User-Agent', 'VLC'));
    });
  });

  group('Build #22 — panel image fetches carry the UA', () {
    test('artworkHeadersFor gives VLC for an IPTV client, PlezTV otherwise', () {
      final iptv = IptvClient.xtream(xtreamConnection: _trexConnection());
      expect(MediaImageHelper.artworkHeadersFor(iptv), {'User-Agent': 'VLC'});
      expect(MediaImageHelper.artworkHeadersFor(_OtherBackendClient()), {'User-Agent': 'PlezTV'});
      expect(MediaImageHelper.artworkHeadersFor(null), {'User-Agent': 'PlezTV'});
    });

    test('serverArtworkProvider defaults to PlezTV and honours passed headers', () {
      const imageUrl = 'https://panel.example.com:8080/cover.jpg';

      // memWidth/memHeight 0 returns the provider unwrapped (no ResizeImage).
      final defaultProvider = MediaImageHelper.serverArtworkProvider(
        imageUrl: imageUrl,
        memWidth: 0,
        memHeight: 0,
      );
      expect(defaultProvider, isA<CachedNetworkImageProvider>());
      expect(
        (defaultProvider as CachedNetworkImageProvider).headers,
        {'User-Agent': 'PlezTV'},
      );

      final iptvProvider = MediaImageHelper.serverArtworkProvider(
        imageUrl: imageUrl,
        memWidth: 0,
        memHeight: 0,
        headers: const {'User-Agent': 'VLC'},
      );
      expect(
        (iptvProvider as CachedNetworkImageProvider).headers,
        {'User-Agent': 'VLC'},
      );
    });
  });

  group('Build #22 — mini-player stream opens carry the UA', () {
    testWidgets('a live tune opens with the configured UA', (tester) async {
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
      final media = harness.players.single.openedMedia.single;
      expect(media.uri, contains('live'));
      expect(media.headers, containsPair('User-Agent', 'VLC'));
      expect(media.headers, containsPair('Accept-Language', 'en'));
    });

    testWidgets('a catch-up tune opens the timeshift URL with the UA', (tester) async {
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
        _epg(
          id: 'live',
          title: 'Live Show',
          start: now.subtract(const Duration(minutes: 10)),
          end: now.add(const Duration(minutes: 50)),
        ),
      ]);
      harness.api.completeEmpty('101');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Past Show'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Watch from start'), findsOneWidget);

      await tester.tap(find.textContaining('Watch from start'));
      await tester.pump();
      await tester.pump();

      expect(harness.players.single.openCount, 1);
      final media = harness.players.single.openedMedia.single;
      expect(media.uri, contains('timeshift'));
      expect(media.headers, containsPair('User-Agent', 'VLC'));
    });

    testWidgets('a setting change applies to the next tune', (tester) async {
      final harness = _MiniPlayerHarness();
      addTearDown(harness.dispose);
      await harness.init();
      await harness.pump(tester);
      await harness.waitForEpgCalls(tester, 2);
      harness.api.completeEmpty('100');
      harness.api.completeEmpty('101');
      await tester.pumpAndSettle();

      await harness.tapChannel(tester, 'Trex News');
      expect(harness.players.single.openedMedia.single.headers, containsPair('User-Agent', 'VLC'));

      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvXtreamUserAgent, 'custom');
      await settings.write(SettingsService.iptvXtreamUserAgentCustom, 'MyAgent/9');

      await harness.tapChannel(tester, 'Trex Sports');
      expect(harness.players.single.openCount, 2);
      expect(harness.players.single.openedMedia.last.headers, containsPair('User-Agent', 'MyAgent/9'));
    });
  });
}
