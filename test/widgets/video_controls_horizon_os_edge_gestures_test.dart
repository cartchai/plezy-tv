import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/video_volume_controller.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/watch_together/providers/watch_together_provider.dart';
import 'package:plezy/widgets/video_controls/player_chrome_controller.dart';
import 'package:plezy/widgets/video_controls/video_controls.dart';
import 'package:plezy/widgets/video_controls/widgets/player_toast_indicator.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/theme.dart';

/// The player gate exception (Quest rework v2): the edge gestures accept a
/// mouse drag on Horizon OS TV, where the TV layout stays on.
///
/// On Quest the laser pointer is the only drag a controller can make, and it
/// arrives as a mouse-kind pointer. The gate (`_mobileTouchGesturesAllowed`)
/// used to require `isMobile && !isTV()`, which is false on every TV —
/// including Quest, where `isMobile()` is false because the TV layout is
/// on. The f52cacfa3 mouse acceptance was therefore inert on the headset.
/// The exception adds `isHorizonOs()` to both halves of the gate, so a
/// mouse drag in an edge zone drives the brightness/volume adjustment on
/// Quest while plain TV stays gesture-free.
///
/// The observable here is the `com.plezy/device_adjustment` channel: an
/// active edge gesture writes the volume through it. The on-screen edge
/// indicator is `isMobile`-gated and never renders on TV, so it cannot
/// prove anything here — that missing feedback on Quest is a known
/// follow-up, not something this test covers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const deviceAdjustmentChannel = MethodChannel('com.plezy/device_adjustment');

  late _RecordingPlayer player;
  late PlayerChromeController chrome;
  late PlayerToastController toast;
  late VideoVolumeController volume;
  late PlaybackStateProvider playbackState;
  late WatchTogetherProvider watchTogether;
  late AppDatabase database;
  late List<double> volumeWrites;

  Future<dynamic> deviceAdjustmentHandler(MethodCall call) async {
    switch (call.method) {
      case 'getBrightness':
      case 'getMediaVolume':
        return 0.5;
      case 'setMediaVolume':
        volumeWrites.add((call.arguments as num).toDouble());
        return null;
      default:
        return null;
    }
  }

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    await initializeDateFormatting('en');
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.seekTimeSmall, 10);

    // TV layout in both cases: the Apple TV override makes isTV() true, so
    // isMobile() is false. The cases differ only in the Horizon OS flag.
    TvDetectionService.debugSetAppleTVOverride(true);
    PlatformDetector.debugSetIsDesktopOSOverride(false);

    volumeWrites = <double>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceAdjustmentChannel, deviceAdjustmentHandler);

    database = AppDatabase.forTesting(NativeDatabase.memory());
    player = _RecordingPlayer();
    chrome = PlayerChromeController();
    toast = PlayerToastController();
    volume = VideoVolumeController(player: player, settings: settings, initialVolume: 100);
    playbackState = PlaybackStateProvider();
    watchTogether = WatchTogetherProvider();
  });

  tearDown(() async {
    TvDetectionService.debugSetAppleTVOverride(null);
    TvDetectionService.debugSetHorizonOsOverride(null);
    PlatformDetector.debugSetIsDesktopOSOverride(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(deviceAdjustmentChannel, null);
    volume.dispose();
    playbackState.dispose();
    watchTogether.dispose();
    chrome.dispose();
    toast.dispose();
    await database.close();
  });

  const surface = Size(800, 600);

  Future<void> pumpControls(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<AppDatabase>.value(value: database),
          ChangeNotifierProvider<PlaybackStateProvider>.value(value: playbackState),
          ChangeNotifierProvider<WatchTogetherProvider>.value(value: watchTogether),
        ],
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android, extensions: const [testMonoTokens]),
          home: Scaffold(
            body: SizedBox(
              width: surface.width,
              height: surface.height,
              child: PlexVideoControls(
                player: player,
                volumeController: volume,
                metadata: testMediaItem(id: 'horizon-os-edge-gestures'),
                toastController: toast,
                chromeController: chrome,
                canNavigateMediaItems: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    chrome.hide();
    chrome.markControlsHidden();
    await tester.pump();
  }

  /// A mouse drag up in the right edge zone — the volume edge. The zone is
  /// 96 logical pixels wide on this surface, vertically inside the middle
  /// 70% of the height.
  Future<void> dragVolumeEdgeUp(WidgetTester tester) async {
    final gesture = await tester.startGesture(const Offset(760, 300), kind: PointerDeviceKind.mouse);
    await gesture.moveBy(const Offset(0, -120));
    // The baseline read resolves through the mocked channel; give the
    // pending adjustment a pump to start and write.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump();
  }

  testWidgets('a mouse drag on the volume edge adjusts the volume on Horizon OS TV', (tester) async {
    TvDetectionService.debugSetHorizonOsOverride(true);
    await pumpControls(tester);

    await dragVolumeEdgeUp(tester);

    expect(volumeWrites, isNotEmpty, reason: 'the edge gesture must reach the volume write');
    expect(volumeWrites.last, greaterThan(0.5), reason: 'dragging up raises the volume from the 0.5 baseline');
  });

  testWidgets('the same mouse drag does nothing on plain TV', (tester) async {
    TvDetectionService.debugSetHorizonOsOverride(false);
    await pumpControls(tester);

    await dragVolumeEdgeUp(tester);

    expect(volumeWrites, isEmpty, reason: 'without the Horizon OS exception the gate stays closed on TV');
  });
}

class _RecordingPlayer implements Player {
  final List<Duration> seeks = [];
  final StreamController<Duration?> _jumpController = StreamController<Duration?>.broadcast();

  bool _playing = true;
  Duration _position = const Duration(minutes: 10);

  @override
  String get playerType => 'mpv';

  @override
  PlayerState get state =>
      PlayerState(playing: _playing, position: _position, duration: const Duration(minutes: 45), seekable: true);

  @override
  PlayerStreams get streams => PlayerStreams(
    playheadJump: _jumpController.stream,
    playing: const Stream<bool>.empty(),
    completed: const Stream<bool>.empty(),
    buffering: const Stream<bool>.empty(),
    position: const Stream<Duration>.empty(),
    duration: const Stream<Duration>.empty(),
    seekable: const Stream<bool>.empty(),
    buffer: const Stream<Duration>.empty(),
    volume: const Stream<double>.empty(),
    rate: const Stream<double>.empty(),
    tracks: const Stream<Tracks>.empty(),
    track: const Stream<TrackSelection>.empty(),
    log: const Stream<PlayerLog>.empty(),
    error: const Stream<PlayerError>.empty(),
    audioDevice: const Stream<AudioDevice>.empty(),
    audioDevices: const Stream<List<AudioDevice>>.empty(),
    bufferRanges: const Stream<List<BufferRange>>.empty(),
    playbackRestart: const Stream<void>.empty(),
    backendSwitched: const Stream<void>.empty(),
  );

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    _position = position;
    _jumpController.add(position);
  }

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {
    await _jumpController.close();
  }

  @override
  Future<void> play() async => _playing = true;

  @override
  Future<void> pause() async => _playing = false;

  @override
  Future<void> playOrPause() async => _playing = !_playing;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
