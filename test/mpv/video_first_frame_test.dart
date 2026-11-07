// FAILING-FIRST — build #13 (v2.25.9): the Live TV mini-player is BLACK
// with audio only on Matt's phone (2026-11-07 ~05:11 EST), while
// maximizing plays video fine.
//
// Root cause (by code-read): the mpv [Video] widget paints a black cover
// until its first frame, and without an external notifier it learns the
// first frame ONLY from `player.streams.playbackRestart` — a broadcast
// stream, so an event fired before the subscription is missed forever.
// The mini-player inserts its Video widget only AFTER `tune()` awaits
// `player.open()`, so the restart that fires during open() is missed and
// the black cover stays up forever. Fullscreen works because the player
// screen subscribes at player creation, before open().
//
// These tests drive the real [Video] widget with a fake player whose
// restart event never fires (the missed event) and whose latched
// `state.hasRenderedFrame` says a frame already rendered — exactly the
// mini-player's situation. The fix: Video reads the latched state at
// init (and on player change), not just the event.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/models.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/mpv/player/player_state.dart';
import 'package:plezy/mpv/player/player_streams.dart';
import 'package:plezy/mpv/video.dart';

void main() {
  group('build13: Video reveals the surface when a frame already rendered', () {
    testWidgets('frame rendered before mount, restart event missed: reveals', (tester) async {
      // The mini-player's exact situation: open() already rendered a
      // frame (the latched state says so) but the restart event fired
      // before this widget subscribed, so the stream never emits.
      final player = _FakePlayer(hasRenderedFrame: true);
      addTearDown(player.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 180,
              child: Video(player: player),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(_coverColor(tester), Colors.transparent);
    });

    testWidgets('no frame yet, no event: stays black', (tester) async {
      final player = _FakePlayer(hasRenderedFrame: false);
      addTearDown(player.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 320, height: 180, child: Video(player: player)),
          ),
        ),
      );
      await tester.pump();

      expect(_coverColor(tester), Colors.black);
    });

    testWidgets('restart event after mount: reveals', (tester) async {
      final player = _FakePlayer(hasRenderedFrame: false);
      addTearDown(player.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 320, height: 180, child: Video(player: player)),
          ),
        ),
      );
      await tester.pump();
      expect(_coverColor(tester), Colors.black);

      player.emitPlaybackRestart();
      await tester.pumpAndSettle();

      expect(_coverColor(tester), Colors.transparent);
    });
  });
}

/// The cover is the Video widget's root ColoredBox: black while waiting
/// for the first frame, transparent once the surface is revealed.
Color _coverColor(WidgetTester tester) {
  final cover = find.descendant(of: find.byType(Video), matching: find.byType(ColoredBox));
  return tester.widget<ColoredBox>(cover).color;
}

/// A player that renders a frame BEFORE the Video widget mounts: its
/// latched state says so, but its restart stream never emits (the event
/// was missed). Deliberately NOT a VideoRectSupport, so the surface
/// needs no platform channel.
final class _FakePlayer implements Player {
  _FakePlayer({required bool hasRenderedFrame})
    : _state = PlayerState(hasRenderedFrame: hasRenderedFrame) {
    streams = PlayerStreams(
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
      playbackRestart: _playbackRestart.stream,
      backendSwitched: const Stream<void>.empty(),
    );
  }

  final PlayerState _state;
  final _playbackRestart = StreamController<void>.broadcast();

  @override
  PlayerState get state => _state;

  @override
  late final PlayerStreams streams;

  void emitPlaybackRestart() => _playbackRestart.add(null);

  Future<void> close() async => _playbackRestart.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
