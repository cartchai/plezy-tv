import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show Uint8List, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';
import 'debug_log_export_service.dart';
import 'last_crash_store.dart';

/// Auto debug dump (1.2.9, Matt ~2026-11-14 01:48 EST): after 3 launches
/// in a row that never reach a stable state (first MainScreen frame AND
/// the first catalog bind settled — a launch that dies while loading the
/// Trex catalog counts), the next launch writes a debug dump by itself —
/// so a crashing TV produces evidence without anyone navigating Settings.
///
/// The dump is exactly the manual export ([DebugLogExportService
/// .buildDebugText]: summary first, then the FULL rolling log + Settings
/// + Memory + Last crash, fully redacted — nothing is trimmed). One
/// fixed-name file, overwritten each time, so it is always findable at a
/// known path. The counter resets after a successful write, so a
/// persistently crashing app produces a fresh dump every 3 failed starts
/// rather than one per launch.
///
/// Destination (scoped storage — the literal external-storage root is NOT
/// writable on modern Android TV without a manual all-files-access grant):
/// the app-specific external files dir
/// (`/storage/emulated/0/Android/data/com.matt.plezytv/files/`, no
/// permission needed, reachable via a TV file manager / adb / in-app copy
/// of the path), falling back to the app docs dir. Never requests
/// MANAGE_EXTERNAL_STORAGE. Every step is best-effort: a dump failure
/// must never break startup.
abstract final class AutoDumpService {
  static const String dumpFileName = 'pleztv-autodump.txt';

  /// Consecutive failed starts before a dump is written (Matt said three
  /// or four; 3 — the good-start marker already filters false positives,
  /// so an earlier dump is worth more than waiting for a fourth death).
  static const int failedStartThreshold = 3;

  @visibleForTesting
  static Directory? debugExternalDirectoryOverride;

  @visibleForTesting
  static Directory? debugDocumentsDirectoryOverride;

  /// Build the dump and write it to the external files dir (fallback: the
  /// app docs dir). Returns the saved path, or null when no location was
  /// writable. On success the failed-start counter resets to 0. Never
  /// throws.
  static Future<String?> writeDump({required int failedStarts}) async {
    try {
      final fullLog = await FileLogOutput.readFullLog();
      final text = await DebugLogExportService.buildDebugText(
        baseLogsText: fullLog,
        dumpReason: 'auto-dump after $failedStarts failed starts',
        failedStarts: failedStarts,
      );
      final bytes = Uint8List.fromList(utf8.encode(text));
      final path = await _writeDumpFile(bytes);
      if (path == null) return null;
      await LastCrashStore.resetFailedStartCounter();
      return path;
    } catch (error, stackTrace) {
      appLogger.d('Could not write the auto-dump', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  static Future<String?> _writeDumpFile(Uint8List bytes) async {
    // Primary: app-specific external files dir — writable with no
    // permission on all API levels (scoped-storage exempt).
    try {
      final dir = debugExternalDirectoryOverride ?? await getExternalStorageDirectory();
      if (dir != null) {
        final file = File(p.join(dir.path, dumpFileName));
        if (!await file.parent.exists()) await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
        return file.path;
      }
    } catch (error, stackTrace) {
      appLogger.d('Could not write the auto-dump to external storage', error: error, stackTrace: stackTrace);
    }
    // Fallback: app docs dir (always writable; reachable via adb run-as
    // on a debug build, or the in-app path copy on the Logs screen).
    try {
      final dir = debugDocumentsDirectoryOverride ?? await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, dumpFileName));
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (error, stackTrace) {
      appLogger.d('Could not write the auto-dump to the app documents dir', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// The last auto-dump, if one exists (external dir first, docs dir
  /// fallback): its path and last-modified time. Never throws.
  static Future<({String path, DateTime modified})?> lastDump() async {
    for (final (override, external) in <(Directory?, bool)>[
      (debugExternalDirectoryOverride, true),
      (debugDocumentsDirectoryOverride, false),
    ]) {
      try {
        final resolved = override ?? await _resolveDir(external);
        if (resolved == null) continue;
        final file = File(p.join(resolved.path, dumpFileName));
        if (await file.exists()) {
          return (path: file.path, modified: await file.lastModified());
        }
      } catch (_) {
        // Best effort: try the next location.
      }
    }
    return null;
  }

  static Future<Directory?> _resolveDir(bool external) async {
    try {
      return external ? await getExternalStorageDirectory() : await getApplicationDocumentsDirectory();
    } catch (_) {
      return null;
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    debugExternalDirectoryOverride = null;
    debugDocumentsDirectoryOverride = null;
  }
}
