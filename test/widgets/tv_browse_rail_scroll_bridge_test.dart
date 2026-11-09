import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/focus/locked_hub_controller.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_hub.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/tv_browse_rail.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

/// Widget tests for the thumbstick bridge on the TV Discover rail (Quest
/// rework v2).
///
/// The rail's vertical list is `NeverScrollableScrollPhysics` and moves only
/// when the selection changes, so a scroll event over Discover had no
/// consumer: the list rejected it and the rows scrolled directly without
/// moving the selection or the spotlight. The bridge (`Listener` +
/// [TvRailScrollBridge]) turns those scroll events — the only thing a Quest
/// controller's thumbstick can produce, via its laser pointer — into
/// selection moves. These tests prove the wiring end to end: scroll over the
/// rail moves the selection, scroll anywhere else does not.
///
/// The thumbstick-arrival and pointer-kind questions can only be settled on
/// the headset and stay UNPROVEN; these tests prove the bridge reacts to
/// the events the platform delivers, not that the platform delivers them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HubFocusMemory focusMemory;

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    focusMemory = HubFocusMemory();
    await SettingsService.getInstance();
  });

  List<MediaHub> twoHubs() {
    final movies = [
      testMediaItem(id: 'movie_1', backend: MediaBackend.plex, kind: MediaKind.movie, title: 'First Movie'),
      testMediaItem(id: 'movie_2', backend: MediaBackend.plex, kind: MediaKind.movie, title: 'Second Movie'),
    ];
    final shows = [
      testMediaItem(id: 'show_1', backend: MediaBackend.plex, kind: MediaKind.movie, title: 'First Show'),
    ];
    return [
      MediaHub(id: 'movies', title: 'Movies', type: 'movie', items: movies, size: movies.length),
      MediaHub(id: 'shows', title: 'Shows', type: 'movie', items: shows, size: shows.length),
    ];
  }

  Future<SemanticsHandle> pumpRail(WidgetTester tester, {required List<MediaHub> hubs, Widget Function(Widget rail)? wrap}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final semantics = tester.ensureSemantics();

    final serverManager = MultiServerManager();
    final rail = SizedBox(
      width: 1280,
      height: 720,
      child: TvBrowseRail(
        focusMemory: focusMemory,
        hubs: hubs,
        autofocus: true,
        iconForHub: (_, _) => Icons.movie_rounded,
      ),
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<MultiServerProvider>(
        create: (_) => testMultiServerProvider(serverManager),
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: Builder(
              // The semantic selection proxy is gated on accessibleNavigation:
              // it only exists while an accessibility service is attached.
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
                child: Scaffold(body: wrap == null ? rail : wrap(rail)),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return semantics;
  }

  String selectionLabel(WidgetTester tester) {
    final proxy = find.bySemanticsIdentifier('tv_browse_rail_selection');
    expect(proxy, findsOneWidget);
    return tester.getSemantics(proxy).label;
  }

  Future<void> scrollOverRail(WidgetTester tester, Offset delta, {Offset position = const Offset(640, 360)}) async {
    await tester.sendEventToBinding(PointerScrollEvent(position: position, scrollDelta: delta));
    await tester.pumpAndSettle();
  }

  testWidgets('a vertical scroll over the rail moves to the next hub', (tester) async {
    final semantics = await pumpRail(tester, hubs: twoHubs());
    expect(selectionLabel(tester), contains('First Movie'));

    await scrollOverRail(tester, const Offset(0, 600));

    expect(selectionLabel(tester), contains('Shows'));
    expect(selectionLabel(tester), contains('First Show'));
    semantics.dispose();
  });

  testWidgets('a vertical scroll the other way moves back to the previous hub', (tester) async {
    final semantics = await pumpRail(tester, hubs: twoHubs());
    await scrollOverRail(tester, const Offset(0, 600));
    expect(selectionLabel(tester), contains('First Show'));

    await scrollOverRail(tester, const Offset(0, -600));

    expect(selectionLabel(tester), contains('First Movie'));
    semantics.dispose();
  });

  testWidgets('a horizontal scroll over the rail moves to the next item', (tester) async {
    final semantics = await pumpRail(tester, hubs: twoHubs());
    expect(selectionLabel(tester), contains('First Movie'));

    await scrollOverRail(tester, const Offset(600, 0));

    expect(selectionLabel(tester), contains('Second Movie'));
    semantics.dispose();
  });

  testWidgets('a sub-threshold scroll over the rail does not move the selection', (tester) async {
    final semantics = await pumpRail(tester, hubs: twoHubs());

    await scrollOverRail(tester, const Offset(0, 10));
    await scrollOverRail(tester, const Offset(10, 0));

    expect(selectionLabel(tester), contains('First Movie'));
    semantics.dispose();
  });

  testWidgets('a scroll over a real scrollable outside the rail leaves the rail alone', (tester) async {
    // A taller viewport so a list can sit above the rail.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final semantics = tester.ensureSemantics();

    final serverManager = MultiServerManager();
    final listController = ScrollController();
    addTearDown(listController.dispose);
    final hubs = twoHubs();
    await tester.pumpWidget(
      ChangeNotifierProvider<MultiServerProvider>(
        create: (_) => testMultiServerProvider(serverManager),
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
                child: Scaffold(
                  body: Column(
                    children: [
                      SizedBox(
                        height: 200,
                        child: ListView.builder(
                          controller: listController,
                          itemCount: 20,
                          itemBuilder: (context, index) => SizedBox(
                            height: 50,
                            child: Text('Row $index'),
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 1280,
                        height: 720,
                        child: TvBrowseRail(
                          focusMemory: focusMemory,
                          hubs: hubs,
                          autofocus: true,
                          iconForHub: (_, _) => Icons.movie_rounded,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(selectionLabel(tester), contains('First Movie'));

    // Scroll over the list, well above the rail: the list scrolls, the
    // rail selection does not move.
    await tester.sendEventToBinding(
      const PointerScrollEvent(position: Offset(640, 100), scrollDelta: Offset(0, 600)),
    );
    await tester.pumpAndSettle();

    expect(listController.offset, greaterThan(0), reason: 'the outside list should have scrolled');
    expect(selectionLabel(tester), contains('First Movie'));
    semantics.dispose();
  });
}
