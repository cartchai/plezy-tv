// FAILING-FIRST — build #16 (v2.25.12): the Live TV mini-player is STILL
// BLACK on Matt's phone (v2.25.11, 2026-11-08 ~09:58 EST), and the build #15
// diagnostic named the step: "Video rect sent: no".
//
// Root cause (research #16 §2): the rect path cannot ever be "yes" on
// Android. `Video` only sends a rect when `player is VideoRectSupport`
// (video.dart), and that mixin is mixed in ONLY by the Linux/Windows
// players. Neither Android player implements it, and no `setVideoRect`
// exists in the Android native plugin — so on Android the video picture
// is fitted into the FULL window and centered, while the mini-player's
// hole is only the top 16:9 strip: the picture sits in the vertical
// middle behind opaque Flutter UI. Audio plays, the first frame arrives,
// the cover lifts — all consistent.
//
// These tests drive the real [Video] widget with the REAL production
// Android players ([PlayerNativeAndroid], [PlayerAndroid]) and assert the
// rect IS sent with the hole geometry. Run against the pre-fix tree the
// first version of this file failed at runtime with zero `setVideoRect`
// calls, using a fake shaped like the pre-fix Android player (a bare
// [PlayerNative] — no mixin); the rewritten file also cannot compile
// pre-fix ([PlayerNativeAndroid] does not exist yet). Either way the
// pre-fix tree fails and the fixed tree passes.
//
// Test-hygiene notes, learned the hard way in this file:
// - Never dispose a real [PlayerBase] in a widget test: dispose awaits
//   native-ownership waits + event-channel cancels that never resolve
//   inside testWidgets' fake async zone and stall the runner with no
//   output. The players here are never disposed (never initialized;
//   no timers started).
// - One real player per channel per file: [PlayerBase.invoke] waits on
//   the previous instance's native-ownership release, and an undisposed
//   predecessor never releases — so a second real player on the same
//   channel never reaches the method channel at all (its invoke times
//   out after 8 s and returns null). The single-player tests therefore
//   share one [PlayerNativeAndroid] / one [PlayerAndroid]; the retune
//   test, which needs two instances, uses [_FakeRectPlayer] fakes
//   (no [PlayerBase], no ownership gate) instead.
// - The players' event channels ARE mocked (as a MethodChannel, like
//   test_helpers/mock_player_channels.dart): the base constructor
//   subscribes to it, and an unmocked listen/cancel surfaces as
//   MissingPluginException errors that fail the test.
// - The rect is in PHYSICAL pixels, so the tests pin the device pixel
//   ratio to 1.0: at the test default of 3.0 a 320-wide hole sends
//   right=960, which is correct behaviour and a confusing assertion.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/mpv/player/player_state.dart';
import 'package:plezy/mpv/player/player_streams.dart';
import 'package:plezy/mpv/player/platform/player_android.dart';
import 'package:plezy/mpv/player/platform/player_native_android.dart';
import 'package:plezy/mpv/player/video_rect_support.dart';
import 'package:plezy/mpv/video.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mpvChannel = MethodChannel('com.plezy/mpv_player');
  const mpvEvents = MethodChannel('com.plezy/mpv_player/events');
  const exoChannel = MethodChannel('com.plezy/exo_player');
  const exoEvents = MethodChannel('com.plezy/exo_player/events');

  group('build16: Android video rect', () {
    late List<MethodCall> mpvCalls;
    late List<MethodCall> exoCalls;

    // One real player per channel for the whole group (see the header
    // note): a second instance's invoke would wait on the first's
    // never-released ownership and never reach the channel.
    PlayerNativeAndroid? sharedMpvPlayer;
    PlayerAndroid? sharedExoPlayer;
    PlayerNativeAndroid mpvPlayer() => sharedMpvPlayer ??= PlayerNativeAndroid();
    PlayerAndroid exoPlayer() => sharedExoPlayer ??= PlayerAndroid();

    setUp(() {
      mpvCalls = [];
      exoCalls = [];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(mpvChannel, (MethodCall call) async {
        mpvCalls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(mpvEvents, (MethodCall call) async => null);
      messenger.setMockMethodCallHandler(exoChannel, (MethodCall call) async {
        exoCalls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(exoEvents, (MethodCall call) async => null);
    });

    tearDown(() {
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(mpvChannel, null);
      messenger.setMockMethodCallHandler(mpvEvents, null);
      messenger.setMockMethodCallHandler(exoChannel, null);
      messenger.setMockMethodCallHandler(exoEvents, null);
    });

    List<MethodCall> rectCalls(List<MethodCall> calls) =>
        calls.where((c) => c.method == 'setVideoRect').toList();

    Future<void> pumpVideo(
      WidgetTester tester,
      Player player, {
      Size hole = const Size(320, 180),
      void Function(String rect)? onVideoRectSent,
    }) async {
      // Physical pixels == logical pixels (see the header note).
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: hole.width,
              height: hole.height,
              child: Video(player: player, onVideoRectSent: onVideoRectSent),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('rect is sent for the mini-player hole after mount', (tester) async {
      final player = mpvPlayer();

      await pumpVideo(tester, player);

      final calls = rectCalls(mpvCalls);
      expect(calls, hasLength(1));
      expect(calls.single.arguments['left'], 0);
      expect(calls.single.arguments['top'], 0);
      expect(calls.single.arguments['right'], 320);
      expect(calls.single.arguments['bottom'], 180);
    });

    testWidgets('rect is re-sent when the hole moves', (tester) async {
      final player = mpvPlayer();

      await pumpVideo(tester, player, hole: const Size(320, 180));
      expect(rectCalls(mpvCalls), hasLength(1));

      await pumpVideo(tester, player, hole: const Size(640, 360));
      final calls = rectCalls(mpvCalls);
      expect(calls, hasLength(2));
      expect(calls.last.arguments['right'], 640);
      expect(calls.last.arguments['bottom'], 360);
    });

    testWidgets('rect is re-sent for a replacement player (retune)', (tester) async {
      // Fakes, not the shared real player: the retune needs two player
      // instances, and a second real player on the mpv channel would wait
      // on the first's never-released ownership (see the header note).
      final first = _FakeRectPlayer();
      final second = _FakeRectPlayer();

      await pumpVideo(tester, first);
      expect(first.rectCalls, hasLength(1));

      // Same hole, new player: Video resets its sent-rect cache on a
      // player swap, so the replacement surface gets positioned too.
      await pumpVideo(tester, second);
      expect(second.rectCalls, hasLength(1));
      expect(first.rectCalls, hasLength(1));
    });

    testWidgets('full-window video sends the full-window rect', (tester) async {
      final player = mpvPlayer();

      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpVideo(tester, player, hole: const Size(800, 600));

      final calls = rectCalls(mpvCalls);
      expect(calls, hasLength(1));
      expect(calls.single.arguments['left'], 0);
      expect(calls.single.arguments['top'], 0);
      expect(calls.single.arguments['right'], 800);
      expect(calls.single.arguments['bottom'], 600);
    });

    testWidgets('onVideoRectSent fires once the rect lands (diagnostic)', (tester) async {
      final player = mpvPlayer();
      var sent = false;

      await pumpVideo(tester, player, onVideoRectSent: (_) => sent = true);

      expect(rectCalls(mpvCalls), hasLength(1));
      expect(sent, isTrue);
    });

    testWidgets('real ExoPlayer backend sends the rect on its own channel', (tester) async {
      final player = exoPlayer();

      await pumpVideo(tester, player);

      final calls = rectCalls(exoCalls);
      expect(calls, hasLength(1));
      expect(calls.single.arguments['right'], 320);
      expect(calls.single.arguments['bottom'], 180);
    });

    test('production Android players expose rect support; plain PlayerNative does not', () {
      // The wiring itself, not the fake: the Android mpv subclass and the
      // ExoPlayer player mix the rect support in; PlayerNative stays the
      // rect-less iOS/macOS player, whose native side has no surface to
      // position (its Video widget must keep taking the plain branch).
      // Typed as Player so the checks are real runtime checks, not
      // statically-known truths the analyzer flags.
      final Player mpv = PlayerNativeAndroid();
      final Player exo = PlayerAndroid();
      final Player plain = PlayerNative();
      expect(mpv is VideoRectSupport, isTrue);
      expect(exo is VideoRectSupport, isTrue);
      expect(plain is VideoRectSupport, isFalse);
    });
  });
}

/// Rect-capable fake player for the retune test only. The real players
/// cannot be constructed twice per channel in one test file (the second
/// instance's invoke waits on the first's never-released native ownership),
/// and this test only needs the widget-side behaviour — [Video] resetting
/// its sent-rect cache when the player instance changes. Extends [Fake] so
/// only the members [Video] actually touches need stubs.
final class _FakeRectPlayer extends Fake implements Player, VideoRectSupport {
  final List<Map<String, Object?>> rectCalls = [];

  @override
  PlayerState get state => const PlayerState();

  @override
  PlayerStreams get streams => const PlayerStreams(
        playing: Stream<bool>.empty(),
        completed: Stream<bool>.empty(),
        buffering: Stream<bool>.empty(),
        position: Stream<Duration>.empty(),
        duration: Stream<Duration>.empty(),
        seekable: Stream<bool>.empty(),
        buffer: Stream<Duration>.empty(),
        volume: Stream<double>.empty(),
        rate: Stream<double>.empty(),
        tracks: Stream<Tracks>.empty(),
        track: Stream<TrackSelection>.empty(),
        log: Stream<PlayerLog>.empty(),
        error: Stream<PlayerError>.empty(),
        audioDevice: Stream<AudioDevice>.empty(),
        audioDevices: Stream<List<AudioDevice>>.empty(),
        bufferRanges: Stream<List<BufferRange>>.empty(),
        playbackRestart: Stream<void>.empty(),
        backendSwitched: Stream<void>.empty(),
      );

  @override
  Future<void> setVideoRect({
    required int left,
    required int top,
    required int right,
    required int bottom,
    required double devicePixelRatio,
  }) async {
    rectCalls.add({
      'left': left,
      'top': top,
      'right': right,
      'bottom': bottom,
      'devicePixelRatio': devicePixelRatio,
    });
  }
}
