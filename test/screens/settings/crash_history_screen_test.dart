// Widget tests — v1.0.10: the "Crash history" page.
//
// Every recorded crash, newest first, each with its date + time and a Copy
// button sharing that crash alone. No live panel, no network.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/crash_history_screen.dart';
import 'package:plezy/services/last_crash_store.dart';

import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The tiles format dates with DateFormat — same as the app's startup
  // init (main.dart).
  setUpAll(() => initializeDateFormatting('en'));

  late Directory tempDir;

  // The test binding installs no clipboard mock, so Clipboard.setData /
  // getData are no-ops that return null (and getData never resolves
  // inside fake async at all). Fake the platform channel so the Copy
  // test can read back exactly what the tile copied.
  String? fakeClipboardText;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    tempDir = await Directory.systemTemp.createTemp('plezy_crash_history_test_');
    LastCrashStore.debugDirectoryOverride = tempDir;
    fakeClipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          fakeClipboardText = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return fakeClipboardText == null
              ? null
              : {'text': fakeClipboardText};
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    LastCrashStore.debugDirectoryOverride = null;
    LastCrashStore.resetForTesting();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Yield to the real event loop, then pump, until [finder] matches — the
  /// screen reads the history from real dart:io, which never completes
  /// inside `testWidgets`' fake async zone on a plain pump.
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 10 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
    expect(finder, findsWidgets);
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(home: const CrashHistoryScreen()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('crashes list newest first with their date', (tester) async {
    LastCrashStore.record(
      StateError('first crash'),
      source: 'framework',
      timestamp: DateTime.utc(2026, 11, 10, 10, 0, 0),
    );
    LastCrashStore.record(
      StateError('second crash'),
      source: 'uncaught',
      timestamp: DateTime.utc(2026, 11, 11, 5, 27, 12),
    );

    await pumpScreen(tester);
    await waitFor(tester, find.byKey(const Key('CrashHistoryTile-0')));

    // Newest first: tile 0 is the second crash, tile 1 the first.
    expect(
      find.descendant(
        of: find.byKey(const Key('CrashHistoryTile-0')),
        matching: find.textContaining('second crash'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('CrashHistoryTile-1')),
        matching: find.textContaining('first crash'),
      ),
      findsOneWidget,
    );
    // Each entry shows its date.
    expect(find.textContaining('Nov 11, 2026'), findsOneWidget);
    expect(find.textContaining('Nov 10, 2026'), findsOneWidget);
  });

  testWidgets('Copy shares only that crash', (tester) async {
    LastCrashStore.record(StateError('first crash'), source: 'framework');
    LastCrashStore.record(StateError('second crash'), source: 'uncaught');

    await pumpScreen(tester);
    await waitFor(tester, find.byKey(const Key('CrashHistoryTile-0')));

    await tester.tap(find.byKey(const Key('CrashHistoryTile-0')));
    // The tile expands with an animation — the Copy button inside it
    // is offstage until the animation settles, so wait for it before
    // tapping.
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('CrashHistoryCopyButton-0')));
    // The copy writes to the platform clipboard, which only completes
    // on the real event loop: a bare `Clipboard.getData` await inside
    // fake async hangs forever, so yield to real time first, then read
    // the clipboard back in real async too.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    final data =
        await tester.runAsync(() => Clipboard.getData(Clipboard.kTextPlain));
    expect(data?.text, contains('second crash'));
    expect(data?.text, isNot(contains('first crash')));
  });

  testWidgets('empty history says no error recorded', (tester) async {
    await pumpScreen(tester);
    await waitFor(tester, find.text(t.settings.lastCrashNone));
  });

  testWidgets('Clear empties the list', (tester) async {
    LastCrashStore.record(StateError('boom'), source: 'uncaught');

    await pumpScreen(tester);
    await waitFor(tester, find.byKey(const Key('CrashHistoryTile-0')));

    await tester.tap(find.byTooltip(t.settings.lastCrashClear));
    await waitFor(tester, find.text(t.settings.lastCrashNone));
    expect(find.byKey(const Key('CrashHistoryTile-0')), findsNothing);
  });
}
