// Widget tests — build #14 (v2.25.10): the "Last crash" Settings row.
//
// The row reads the persisted crash record (and the abnormal-exit flag)
// from disk in initState. Those reads are real dart:io, which never
// completes inside `testWidgets`' fake async zone on a plain pump — the
// tests yield to the real event loop first, then pump to rebuild (same
// pattern as the guide EPG tests).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/last_crash_row.dart';
import 'package:plezy/services/last_crash_store.dart';

import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    tempDir = await Directory.systemTemp.createTemp('plezy_last_crash_row_test_');
    LastCrashStore.debugDirectoryOverride = tempDir;
  });

  tearDown(() async {
    LastCrashStore.debugDirectoryOverride = null;
    LastCrashStore.resetForTesting();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Yield to the real event loop, then pump, until the row's disk read
  /// lands (the loading text disappears) — or 10 tries pass.
  Future<void> waitForLoad(WidgetTester tester) async {
    for (var i = 0; i < 10 && find.text(t.settings.lastCrashLoading).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
    expect(find.text(t.settings.lastCrashLoading), findsNothing);
  }

  /// Same yield, until [finder] matches — for the async Clear.
  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 10 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
    expect(finder, findsWidgets);
  }

  Future<void> pumpRow(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(home: Scaffold(body: const LastCrashRow())),
        ),
      ),
    );
    await waitForLoad(tester);
  }

  testWidgets('a recorded crash shows its headline, details, and Clear removes it', (tester) async {
    // record() writes synchronously when the directory override is set.
    LastCrashStore.record(StateError('boom on startup'), source: 'uncaught');

    await pumpRow(tester);

    expect(find.text(t.settings.lastCrash), findsOneWidget);
    expect(find.textContaining('boom on startup'), findsOneWidget);

    // Expand: the full error + stack show, with a Clear button.
    await tester.tap(find.byKey(const Key('LastCrashRowTile')));
    await tester.pump();
    expect(find.byKey(const Key('LastCrashDetails')), findsOneWidget);
    expect(find.textContaining('boom on startup'), findsWidgets);
    expect(find.byKey(const Key('LastCrashClearButton')), findsOneWidget);

    // Clear: the record is deleted and the row falls back to "no error".
    await tester.tap(find.byKey(const Key('LastCrashClearButton')));
    await waitFor(tester, find.text(t.settings.lastCrashNone));
    expect(find.textContaining('boom on startup'), findsNothing);
  });

  testWidgets('an abnormal exit with no record says so instead of "no error"', (tester) async {
    // Two launches, no clean exit in between: the flag is set.
    expect(await LastCrashStore.markLaunched(), isFalse);
    expect(await LastCrashStore.markLaunched(), isTrue);

    await pumpRow(tester);

    expect(find.text(t.settings.lastCrash), findsOneWidget);
    expect(find.text(t.settings.lastCrashAbnormalExit), findsOneWidget);
    expect(find.text(t.settings.lastCrashNone), findsNothing);
  });

  testWidgets('no record and a clean previous exit reads "no Dart error recorded"', (tester) async {
    expect(await LastCrashStore.markLaunched(), isFalse);
    LastCrashStore.markCleanExit();
    expect(await LastCrashStore.markLaunched(), isFalse);

    await pumpRow(tester);

    expect(find.text(t.settings.lastCrash), findsOneWidget);
    expect(find.text(t.settings.lastCrashNone), findsOneWidget);
    expect(find.text(t.settings.lastCrashAbnormalExit), findsNothing);
  });
}
