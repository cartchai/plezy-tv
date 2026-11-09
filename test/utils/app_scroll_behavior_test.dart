import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/app_scroll_behavior.dart';

void main() {
  test('mouse drags scroll, like touch', () {
    const behavior = AppScrollBehavior();
    expect(behavior.dragDevices, contains(PointerDeviceKind.mouse));
    expect(behavior.dragDevices, contains(PointerDeviceKind.touch));
  });

  test('keeps the framework default drag kinds', () {
    const behavior = AppScrollBehavior();
    expect(
      behavior.dragDevices,
      containsAll({
        PointerDeviceKind.touch,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.unknown,
      }),
    );
  });

  testWidgets('a list scrolls on a mouse drag under AppScrollBehavior', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const AppScrollBehavior(),
        home: ListView.builder(
          controller: controller,
          itemCount: 50,
          itemBuilder: (context, i) => SizedBox(height: 100, child: Text('item $i')),
        ),
      ),
    );
    expect(controller.offset, 0);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -300));
    await gesture.up();
    await tester.pump();
    expect(controller.offset, greaterThan(0));
  });

  testWidgets('a list does NOT scroll on a mouse drag with the framework default', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView.builder(
          controller: controller,
          itemCount: 50,
          itemBuilder: (context, i) => SizedBox(height: 100, child: Text('item $i')),
        ),
      ),
    );
    expect(controller.offset, 0);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -300));
    await gesture.up();
    await tester.pump();
    // Control: proves the behavior above is what enables mouse-drag scroll.
    expect(controller.offset, 0);
  });
}
