// Widget tests — build #14 (v2.25.10): the "Last crash" Settings row.
//
// The row reads the persisted crash record (and the abnormal-exit flag)
// from disk in initState. Those reads are real dart:io, which never
// completes inside `testWidgets`' fake async zone on a plain pump — the
// tests yield to the real event loop first, then pump to rebuild (same
// pattern as the guide EPG tests).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/screens/settings/last_crash_row.dart';
import 'package:plezy/services/last_crash_store.dart';

import '../../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The History button opens the crash history page, which formats
  // dates with DateFormat — same as the app's startup init (main.dart).
  setUpAll(() => initializeDateFormatting('en'));

  late Directory tempDir;

  // The test binding installs no clipboard mock, so Clipboard.setData /
  // getData are no-ops that return null (and getData never resolves
  // inside fake async at all). Fake the platform channel so the Copy
  // tests can read back exactly what the row copied.
  String? fakeClipboardText;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    tempDir = await Directory.systemTemp.createTemp('plezy_last_crash_row_test_');
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

  testWidgets('Copy copies the exact crash details to the clipboard', (tester) async {
    LastCrashStore.record(StateError('boom on startup'), source: 'uncaught');

    await pumpRow(tester);

    // Expand, then Copy: the clipboard holds the same text the row shows.
    await tester.tap(find.byKey(const Key('LastCrashRowTile')));
    await tester.pump();
    expect(find.byKey(const Key('LastCrashCopyButton')), findsOneWidget);

    await tester.tap(find.byKey(const Key('LastCrashCopyButton')));
    // The copy writes to the platform clipboard, which — like the disk
    // reads above — only completes on the real event loop: a bare
    // `Clipboard.getData` await inside fake async hangs forever, so
    // yield to real time first, then read the clipboard back in real
    // async too.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    final data =
        await tester.runAsync(() => Clipboard.getData(Clipboard.kTextPlain));
    expect(data?.text, contains('Last crash'));
    expect(data?.text, contains('boom on startup'));
    // The record is still there after copying — Copy never clears.
    expect(find.textContaining('boom on startup'), findsWidgets);
  });

  testWidgets('History opens the crash history page', (tester) async {
    LastCrashStore.record(StateError('boom on startup'), source: 'uncaught');

    await pumpRow(tester);

    await tester.tap(find.byKey(const Key('LastCrashRowTile')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('LastCrashHistoryButton')));
    await waitFor(tester, find.byKey(const Key('CrashHistoryTile-0')));
    expect(find.text(t.settings.lastCrashHistory), findsWidgets);
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
