// 1.2.9 — always-on file logging + auto-dump after 3 failed starts
// (Matt, 2026-11-14 ~01:48 EST): debug logging saves to a file, always —
// it is NOT a setting — and after three failed starts the app saves a
// debug dump by itself, so a crashing TV produces evidence without anyone
// navigating Settings.
//
// A "failed start" is a launch that never reaches a STABLE state: the
// first MainScreen frame AND the first catalog bind settled (Matt,
// 2026-11-14 ~02:12 EST: the TV dies WHILE loading the Trex catalog,
// after the first frame is up — a first-frame marker alone would call
// that death a good start and never dump). A crash mid-bind counts.
//
// The dump carries the FULL rolling log (Matt, 2026-11-14 ~02:15 EST:
// nothing gets cut) with a short summary block first.
//
// Failing-first: on the 1.2.7 base there is no file sink, no counter and
// no dump, so every test here fails until the feature lands.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/auto_dump_service.dart';
import 'package:plezy/services/last_crash_store.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/log_redaction_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/prefs.dart';

void main() {
  late Directory tempDir;
  late Directory externalDir;
  late Directory docsDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    tempDir = await Directory.systemTemp.createTemp('plezy_auto_dump_test_');
    externalDir = Directory('${tempDir.path}/external');
    docsDir = Directory('${tempDir.path}/docs');
    await externalDir.create(recursive: true);
    await docsDir.create(recursive: true);
    LastCrashStore.debugDirectoryOverride = tempDir;
    FileLogOutput.debugDirectoryOverride = tempDir;
    AutoDumpService.debugExternalDirectoryOverride = externalDir;
    AutoDumpService.debugDocumentsDirectoryOverride = docsDir;
  });

  tearDown(() async {
    await FileLogOutput.resetForTesting();
    FileLogOutput.debugDirectoryOverride = null;
    AutoDumpService.debugExternalDirectoryOverride = null;
    AutoDumpService.debugDocumentsDirectoryOverride = null;
    AutoDumpService.resetForTesting();
    LastCrashStore.debugDirectoryOverride = null;
    LastCrashStore.resetForTesting();
    LogRedactionManager.clearTrackedValues();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// One launch that never reaches a stable state: mark the launch,
  /// update the counter from the previous launch's state, and — exactly
  /// like `_recordLaunchAndMaybeDump` in main.dart — write the dump when
  /// the counter crosses the threshold. Returns the counter. This is a
  /// crash mid-bind (the TV dying while loading the Trex catalog): no
  /// good-start marker was ever written, so it counts.
  Future<int> failedLaunch() async {
    final abnormal = await LastCrashStore.markLaunched();
    final count = await LastCrashStore.updateFailedStartCounter(previousAbnormal: abnormal);
    if (count >= AutoDumpService.failedStartThreshold) {
      await AutoDumpService.writeDump(failedStarts: count);
    }
    return count;
  }

  /// A launch that reaches a stable state: the first MainScreen frame
  /// plus the first catalog bind settled, so the good-start marker is
  /// written and the counter resets on the next launch.
  Future<int> goodLaunch() async {
    final abnormal = await LastCrashStore.markLaunched();
    final count = await LastCrashStore.updateFailedStartCounter(previousAbnormal: abnormal);
    LastCrashStore.markGoodStart();
    return count;
  }

  group('failed-start counter + auto-dump (T-A1–A5)', () {
    test('T-A1: 3 failed starts, then the next launch writes the dump and resets the counter', () async {
      // The dump lands at the START of the launch after the 3rd failure
      // (launch #4): only then is the rolling file holding launches #1–3
      // and the counter known to have crossed the threshold.
      expect(await failedLaunch(), 0); // launch 1: first launch, nothing before it
      expect(await failedLaunch(), 1); // launch 2: launch 1 never reached a stable state
      expect(await failedLaunch(), 2); // launch 3
      expect(File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);

      expect(await failedLaunch(), 3); // launch 4: threshold crossed → dump
      final dump = File('${externalDir.path}/${AutoDumpService.dumpFileName}');
      expect(dump.existsSync(), isTrue);
      expect(await LastCrashStore.readFailedStartCount(), 0);
    });

    test('T-A2: 2 failed starts, then a good start → no dump, counter 0', () async {
      expect(await failedLaunch(), 0);
      expect(await failedLaunch(), 1);
      // Launch 3 reaches a stable state — the startup window is over,
      // even though the process is then killed (no clean exit).
      expect(await goodLaunch(), 2);
      expect(File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);

      // Launch 4: the previous launch died after a good start, so the
      // marker resets the counter instead of counting a startup failure.
      expect(await failedLaunch(), 0);
      expect(File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);
      expect(await LastCrashStore.readFailedStartCount(), 0);
    });

    test('T-A3: good starts only → no dump ever', () async {
      for (var i = 0; i < 4; i++) {
        expect(await goodLaunch(), 0);
      }
      expect(File('${externalDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isFalse);
      expect(await LastCrashStore.readFailedStartCount(), 0);
    });

    test('T-A4: the counter survives a kill — it lives in a file, not memory', () async {
      expect(await failedLaunch(), 0);
      expect(await failedLaunch(), 1);

      // Simulate the process dying: drop every in-memory handle and
      // re-create the store from the same directory.
      LastCrashStore.resetForTesting();
      expect(await LastCrashStore.readFailedStartCount(), 1);

      expect(await failedLaunch(), 2);
    });

    test('T-A5: the dump holds the FULL log + a summary first + Settings + Memory + Last crash, redacted', () async {
      // Matt (2026-11-14 ~02:15 EST): nothing gets cut — the dump carries
      // the complete rolling log, and a short summary opens the file.
      // A panel URL in the rolling log must never reach the dump.
      LogRedactionManager.registerServerUrl('https://panel.example.com:8080');
      await FileLogOutput.prime();
      appLogger.i('IPTV: search index seeded from disk cache');
      appLogger.e('panel call failed https://panel.example.com:8080/player_api.php');
      // A marker line at the very start, then >500 KB of filler: the old
      // 500 KB tail would have cut the marker off — the full log keeps it.
      appLogger.i('full-log-marker-first-line');
      final filler = 'x' * 1024;
      for (var i = 0; i < 600; i++) {
        appLogger.i('filler-$i $filler');
      }

      await failedLaunch();
      await failedLaunch();
      await failedLaunch();
      final path = await AutoDumpService.writeDump(failedStarts: 3);
      expect(path, isNotNull);

      final text = await File(path!).readAsString();
      // Summary first, before any log line; the failed-start count and
      // the reason live in it now, not in a separate header.
      expect(text, startsWith('== Summary =='));
      expect(text.indexOf('== Summary =='), lessThan(text.indexOf('IPTV: search index seeded')));
      expect(text, contains('RSS max:'));
      expect(text, contains('Failed starts: 3'));
      expect(text, contains('auto-dump after 3 failed starts'));
      expect(text, isNot(contains('Failed consecutive starts')));
      // The full log: the marker at the start survives (no truncation).
      expect(text, contains('full-log-marker-first-line'));
      expect(text, contains('IPTV: search index seeded from disk cache'));
      expect(text, contains('== Settings =='));
      expect(text, contains('== Memory =='));
      expect(text, contains('== Last crash =='));
      expect(text, isNot(contains('panel.example.com')));
    });
  });

  group('good-start gate — the marker waits for the bind', () {
    // Matt (2026-11-14 ~02:12 EST): the TV dies WHILE loading the Trex
    // catalog, after the first frame is up. The marker must only land
    // once the binder has settled AND the catalog binds have ended — a
    // mid-bind death counts as a failed start.
    test('the marker is written only after the binder AND the catalog binds settle', () async {
      final binder = Completer<bool>();
      final binds = Completer<void>();
      final pending = LastCrashStore.markGoodStartWhenStable(
        binderSettled: binder.future,
        catalogBinds: binds.future,
      );
      await Future<void>.delayed(Duration.zero);
      expect(File('${tempDir.path}/${LastCrashStore.goodStartMarkerFileName}').existsSync(), isFalse);
      binder.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(File('${tempDir.path}/${LastCrashStore.goodStartMarkerFileName}').existsSync(), isFalse);
      binds.complete();
      await pending;
      expect(File('${tempDir.path}/${LastCrashStore.goodStartMarkerFileName}').existsSync(), isTrue);
    });

    test('a failed bind still ends the wait — the marker is written', () async {
      final binder = Completer<bool>();
      final binds = Completer<void>();
      final pending = LastCrashStore.markGoodStartWhenStable(
        binderSettled: binder.future,
        catalogBinds: binds.future,
      );
      binder.complete(false);
      binds.completeError(StateError('bind failed'));
      await pending;
      expect(File('${tempDir.path}/${LastCrashStore.goodStartMarkerFileName}').existsSync(), isTrue);
    });

    test('a binder error still ends the wait — the marker is written', () async {
      final binder = Completer<bool>();
      final binds = Completer<void>();
      final pending = LastCrashStore.markGoodStartWhenStable(
        binderSettled: binder.future,
        catalogBinds: binds.future,
      );
      binder.completeError(StateError('binder failed'));
      binds.complete();
      await pending;
      expect(File('${tempDir.path}/${LastCrashStore.goodStartMarkerFileName}').existsSync(), isTrue);
    });

    test('awaitIptvCatalogBinds returns at once when no IPTV bind is in flight', () async {
      final manager = MultiServerManager();
      await manager.awaitIptvCatalogBinds().timeout(const Duration(seconds: 5));
    });
  });

  group('rolling file log (T-A6–A7)', () {
    test('T-A6: the file survives a simulated kill — the buffer does not', () async {
      await FileLogOutput.prime();
      appLogger.i('first launch line one');
      appLogger.w('first launch line two');

      // Simulate the process dying: drop the in-memory buffer entirely.
      MemoryLogOutput.clearLogs();
      expect(MemoryLogOutput.getLogs(), isEmpty);

      final tail = await FileLogOutput.readFullLog();
      expect(tail, contains('first launch line one'));
      expect(tail, contains('first launch line two'));
    });

    test('T-A6: rotation past the 2 MB cap keeps the old file as .1, total bounded', () async {
      await FileLogOutput.prime();
      // Just over the cap, in a few big lines.
      final bigLine = 'x' * (512 * 1024);
      for (var i = 0; i < 5; i++) {
        appLogger.i('bulk $i $bigLine');
      }
      // Simulate a restart: the new process starts with an empty memory
      // buffer, and prime() must not re-drain lines already in the file.
      MemoryLogOutput.clearLogs();
      await FileLogOutput.resetForTesting();
      await FileLogOutput.prime();

      final current = File('${tempDir.path}/${FileLogOutput.fileName}');
      final rotated = File('${tempDir.path}/${FileLogOutput.rotatedFileName}');
      expect(rotated.existsSync(), isTrue);
      final total = (current.existsSync() ? current.lengthSync() : 0) + rotated.lengthSync();
      expect(total, lessThanOrEqualTo(2 * FileLogOutput.maxFileSizeBytes + (512 * 1024)));
      // The newest lines are in the current file.
      expect(await FileLogOutput.readFullLog(), contains('bulk 4'));
    });

    test('T-A7: debug lines reach the file even with a stale toggle-off value stored', () async {
      // A 1.2.7 install stored enable_debug_logging=false. Logging is no
      // longer a setting: the stale value must not gate anything.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('enable_debug_logging', false);

      expect(debugLoggingEnabled, isTrue);
      await FileLogOutput.prime();
      appLogger.d('a debug line, toggle off in storage');
      expect(await FileLogOutput.readFullLog(), contains('a debug line, toggle off in storage'));
    });
  });

  group('dump destination fallback (T-A8)', () {
    test('T-A8: external dir unavailable → the dump lands in the docs dir', () async {
      // Point the external dir at a path under a plain file: it can never
      // be created as a directory.
      final blocker = File('${tempDir.path}/blocker');
      await blocker.writeAsString('not a directory');
      AutoDumpService.debugExternalDirectoryOverride = Directory('${blocker.path}/sub');

      final path = await AutoDumpService.writeDump(failedStarts: 3);
      expect(path, startsWith(docsDir.path));
      expect(File('${docsDir.path}/${AutoDumpService.dumpFileName}').existsSync(), isTrue);
    });

    test('T-A8: both dirs unavailable → no crash, no dump, null path', () async {
      final blocker = File('${tempDir.path}/blocker');
      await blocker.writeAsString('not a directory');
      AutoDumpService.debugExternalDirectoryOverride = Directory('${blocker.path}/ext');
      AutoDumpService.debugDocumentsDirectoryOverride = Directory('${blocker.path}/docs');

      expect(await AutoDumpService.writeDump(failedStarts: 3), isNull);
      expect(await AutoDumpService.lastDump(), isNull);
    });

    test('lastDump finds the dump in the external dir first', () async {
      await AutoDumpService.writeDump(failedStarts: 3);
      final found = await AutoDumpService.lastDump();
      expect(found, isNotNull);
      expect(found!.path, '${externalDir.path}/${AutoDumpService.dumpFileName}');
      expect(found.modified.isAfter(DateTime.now().subtract(const Duration(minutes: 1))), isTrue);
    });
  });
}
