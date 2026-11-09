import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plezy/widgets/tv_rail_scroll_bridge.dart';

/// Unit tests for [TvRailScrollBridge], the thumbstick bridge on the TV
/// Discover rail (Quest rework v2).
///
/// The bridge converts scroll deltas — the only thing a Quest controller's
/// thumbstick can produce, via its laser pointer — into selection moves on
/// the rail. It is deliberately dumb about the rail itself: the rail hands it
/// step thresholds (priced by the focused item's geometry) and move
/// callbacks, and the bridge only accumulates, cools down, and dispatches.
/// No Trex credentials, no panel, no headset involved here — the
/// thumbstick-arrival and pointer-kind questions can only be settled on the
/// headset and stay UNPROVEN.
void main() {
  group('TvRailScrollBridge', () {
    late DateTime fakeNow;
    late List<String> moves;
    late TvRailScrollBridge bridge;

    DateTime now() => fakeNow;

    PointerScrollEvent scrollEvent(Offset delta, {Offset position = Offset.zero}) =>
        PointerScrollEvent(position: position, scrollDelta: delta);

    setUp(() {
      fakeNow = DateTime(2026, 11, 9, 6, 0, 0);
      moves = <String>[];
      bridge = TvRailScrollBridge(
        stepThresholds: () => (horizontal: 300.0, vertical: 300.0),
        onMoveHub: (delta) => moves.add('hub $delta'),
        onMoveItem: (delta) => moves.add('item $delta'),
        now: now,
      );
    });

    test('a vertical scroll past the threshold moves the hub once', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 400)));

      expect(moves, ['hub 1']);
    });

    test('a vertical scroll the other way moves the hub back', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(0, -400)));

      expect(moves, ['hub -1']);
    });

    test('a horizontal scroll past the threshold moves the item', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(400, 0)));

      expect(moves, ['item 1']);
    });

    test('a horizontal scroll the other way moves the item back', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(-400, 0)));

      expect(moves, ['item -1']);
    });

    test('sub-threshold deltas accumulate across events until they step', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 100)));
      expect(moves, isEmpty);

      bridge.handlePointerSignal(scrollEvent(const Offset(0, 100)));
      expect(moves, isEmpty);

      bridge.handlePointerSignal(scrollEvent(const Offset(0, 100)));
      expect(moves, ['hub 1']);
    });

    test('one scroll event emits at most one step; the remainder is discarded', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 900)));

      expect(moves, ['hub 1']);

      // The 600 of travel past the first threshold was re-anchored away,
      // not banked: a later sub-threshold tick must not fire a second step.
      fakeNow = fakeNow.add(const Duration(milliseconds: 100));
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 200)));
      expect(moves, ['hub 1']);
    });

    test('a vertical lock holds while the thumbstick is mostly vertical', () {
      // Vertical establishes the axis; a small horizontal wobble inside the
      // same tick must not flip it.
      bridge.handlePointerSignal(scrollEvent(const Offset(50, 400)));

      expect(moves, ['hub 1']);
    });

    test('a dominant horizontal tick overrides a vertical lock', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 100)));
      expect(moves, isEmpty);

      bridge.handlePointerSignal(scrollEvent(const Offset(400, 50)));

      expect(moves, ['item 1']);
    });

    test('travel inside the cooldown after a step is discarded', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 400)));
      expect(moves, ['hub 1']);

      // 30 ms later: still inside the 60 ms cooldown, so a full threshold
      // of travel is dropped, not queued.
      fakeNow = fakeNow.add(const Duration(milliseconds: 30));
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 400)));
      expect(moves, ['hub 1']);

      // Past the cooldown the re-anchored accumulator starts fresh: one
      // threshold of travel steps again, the discarded travel is gone.
      fakeNow = fakeNow.add(const Duration(milliseconds: 150));
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 400)));
      expect(moves, ['hub 1', 'hub 1']);
    });

    test('a zero scroll delta is a no-op', () {
      bridge.handlePointerSignal(scrollEvent(Offset.zero));

      expect(moves, isEmpty);
    });

    test('non-scroll pointer signals are ignored', () {
      bridge.handlePointerSignal(const PointerScaleEvent(position: Offset(10, 10)));

      expect(moves, isEmpty);
    });

    test('discardPendingProgress drops un-stepped travel but keeps the cooldown', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 100)));
      bridge.discardPendingProgress();
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 100)));

      // Without the discard the two 100s would have accumulated to 200 and
      // the third 100 would have stepped; with it, only 100 is banked.
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 100)));
      expect(moves, isEmpty);
    });

    test('reset clears progress and the cooldown', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 400)));
      expect(moves, ['hub 1']);

      bridge.reset();
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 400)));

      expect(moves, ['hub 1', 'hub 1']);
    });

    test('an established vertical axis holds against a mildly diagonal tick', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 400)));
      expect(moves, ['hub 1']);

      fakeNow = fakeNow.add(const Duration(milliseconds: 100));
      // Horizontal progress (350/300) beats vertical (300/300), but not by
      // the 1.5x dominance the switch needs, so the established axis wins.
      bridge.handlePointerSignal(scrollEvent(const Offset(350, 300)));
      expect(moves, ['hub 1', 'hub 1']);
    });

    test('a dominant horizontal tick switches an established vertical axis', () {
      bridge.handlePointerSignal(scrollEvent(const Offset(0, 400)));
      expect(moves, ['hub 1']);

      fakeNow = fakeNow.add(const Duration(milliseconds: 100));
      // 500/300 horizontal vs 100/300 vertical: comfortably past 1.5x.
      bridge.handlePointerSignal(scrollEvent(const Offset(500, 100)));
      expect(moves, ['hub 1', 'item 1']);
    });

    test('thresholds are re-read per event, not cached at construction', () {
      var threshold = 300.0;
      final dynamicBridge = TvRailScrollBridge(
        stepThresholds: () => (horizontal: threshold, vertical: threshold),
        onMoveHub: (delta) => moves.add('hub $delta'),
        onMoveItem: (delta) => moves.add('item $delta'),
        now: now,
      );

      dynamicBridge.handlePointerSignal(scrollEvent(const Offset(0, 200)));
      expect(moves, isEmpty);

      // The focused card got wider (or the section taller): the same 200
      // of travel no longer counts, and a 400 tick now steps once, not twice.
      threshold = 400.0;
      dynamicBridge.handlePointerSignal(scrollEvent(const Offset(0, 400)));
      expect(moves, ['hub 1']);
    });
  });
}
