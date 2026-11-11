import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/app_logger.dart';
import '../utils/log_redaction_manager.dart';

/// One fatal Dart error, persisted so the next launch can show it.
///
/// The v2.25.9 startup crash was never reproduced in the harness (build
/// #14): every Dart-level suspect passed, so the crash lives in a path the
/// harness cannot drive — or in real data the fakes don't capture. What is
/// needed is the crash itself, from the phone. This record is that evidence:
/// the last fatal error + stack, written to disk before the process dies so
/// Settings can show it on the next launch.
///
/// The message and stack are redacted with [LogRedactionManager] before
/// they are written — an error from the network layer can embed a request
/// URL, and Xtream URLs carry the username/password as query parameters.
/// Nothing derived from preference contents, database rows or file bytes is
/// ever placed in a record.
class LastCrashRecord {
  LastCrashRecord({
    required this.errorType,
    required String message,
    required this.stackTrace,
    required this.timestamp,
    required this.source,
  }) : message = LogRedactionManager.redact(message);

  /// 'uncaught' (an uncaught async error — the process was dying) or
  /// 'framework' (reported through FlutterError.onError).
  final String source;

  final String errorType;

  /// Already redacted by the constructor.
  final String message;

  /// Already redacted by the constructor.
  final String? stackTrace;

  final DateTime timestamp;

  /// One-line summary for the Settings row.
  String get headline => '[$source] $errorType: $message';

  /// Full plain-text block for the Settings row.
  String describe() {
    final buffer = StringBuffer()
      ..writeln('Last crash')
      ..writeln('When: ${timestamp.toUtc().toIso8601String()}')
      ..writeln('Source: $source')
      ..writeln('Error: $errorType')
      ..writeln('Message: $message');
    final stack = stackTrace;
    if (stack != null && stack.isNotEmpty) {
      buffer
        ..writeln('Stack trace:')
        ..writeln(stack);
    }
    return buffer.toString().trimRight();
  }

  Map<String, Object?> toJson() => {
    'errorType': errorType,
    'message': message,
    'stackTrace': stackTrace,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'source': source,
  };

  static LastCrashRecord? fromJson(Map<String, Object?> json) {
    final errorType = json['errorType'];
    final message = json['message'];
    final timestamp = DateTime.tryParse(json['timestamp'] as String? ?? '');
    if (errorType is! String || message is! String || timestamp == null) return null;
    return LastCrashRecord(
      errorType: errorType,
      message: message,
      stackTrace: json['stackTrace'] as String?,
      timestamp: timestamp,
      source: json['source'] as String? ?? 'uncaught',
    );
  }
}

/// Persists the most recent fatal Dart error so it survives the process.
///
/// Follows the [StartupDiagnosticsStore] pattern: one small file under the
/// app support directory (never the cache dir — the OS may wipe that), a
/// `debugDirectoryOverride` test seam, and total methods — a diagnostics
/// failure must never worsen the failure it is describing, so every error
/// here is logged and swallowed.
///
/// The write is synchronous whenever the directory is already known (the
/// test override, or the directory primed at startup): a fatal-error
/// handler cannot await a platform channel and hope the process stays alive
/// long enough for the write to land. When the directory is not known yet
/// (a crash in the first milliseconds of launch) the write falls back to
/// an async resolve-then-write chained behind any in-flight write.
abstract final class LastCrashStore {
  static const String fileName = 'last_crash.json';

  /// History file: every recorded crash, newest first, capped at
  /// [maxHistoryEntries] (Matt, 2026-11-11: a Crash history page with a
  /// date/time + Copy per crash). The single-record file above stays the
  /// "latest" readout — the history is additive, never a replacement.
  static const String historyFileName = 'crash_history.json';

  /// Oldest entries past this count are dropped on the next record.
  static const int maxHistoryEntries = 50;

  /// One-word exit-state file (build #14, D-6): the previous launch's
  /// shutdown. [markLaunched] writes 'running' at startup; a clean engine
  /// detach writes 'clean' ([markCleanExit]). A crash, a force-stop, or the
  /// OS killing the process never writes 'clean', so the next launch finds
  /// 'running' and knows the app did not shut down cleanly — even when no
  /// Dart error was recorded (a native mpv crash leaves no Dart record).
  /// Plain text, not JSON: it must be readable even if the crash record
  /// file itself is corrupt.
  static const String exitStateFileName = 'last_exit_state.txt';

  /// True when the previous launch did not shut down cleanly, as detected
  /// by [markLaunched] at startup. Read by the Settings "Last crash" row.
  static bool _abnormalExitDetected = false;
  static bool get abnormalExitDetected => _abnormalExitDetected;

  @visibleForTesting
  static Directory? debugDirectoryOverride;

  /// Support directory resolved by [prime] at startup. Once known, [record]
  /// writes synchronously.
  static Directory? _cachedDirectory;

  /// In-flight async write, so a fallback write never races another.
  static Future<void>? _writeInFlight;

  /// Resolves the support directory ahead of any crash. Called unawaited
  /// from `_bootstrapApp` — by the time the UI is loading in, the directory
  /// is cached and [record] writes synchronously.
  static Future<void> prime() async {
    if (debugDirectoryOverride != null || _cachedDirectory != null) return;
    try {
      _cachedDirectory = await getApplicationSupportDirectory();
    } catch (error, stackTrace) {
      appLogger.d('Last crash store location unavailable', error: error, stackTrace: stackTrace);
    }
  }

  static Future<File?> _file([String name = fileName]) async {
    try {
      final directory = debugDirectoryOverride ?? _cachedDirectory ?? await getApplicationSupportDirectory();
      return File(p.join(directory.path, name));
    } catch (error, stackTrace) {
      appLogger.d('Last crash store location unavailable', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  static bool _readExitStateSync(Directory directory) {
    try {
      final file = File(p.join(directory.path, exitStateFileName));
      return file.existsSync() && file.readAsStringSync().trim() == 'running';
    } catch (_) {
      return false;
    }
  }

  static void _writeExitStateSync(Directory directory, String state) {
    try {
      final file = File(p.join(directory.path, exitStateFileName));
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      file.writeAsStringSync(state, flush: true);
    } catch (error, stackTrace) {
      appLogger.d('Could not write the app exit state', error: error, stackTrace: stackTrace);
    }
  }

  /// Call once at startup: reads the previous launch's exit state — if it
  /// still says 'running', the app did not shut down cleanly — then marks
  /// this launch 'running'. Returns whether the previous exit was
  /// abnormal, and records it in [abnormalExitDetected]. Never throws.
  /// Synchronous when the directory is already known (primed at startup
  /// or the test override); otherwise resolves it first.
  static Future<bool> markLaunched() async {
    var abnormal = false;
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) {
      abnormal = _readExitStateSync(directory);
      _writeExitStateSync(directory, 'running');
    } else {
      try {
        final file = await _file(exitStateFileName);
        if (file != null) {
          if (await file.exists()) abnormal = (await file.readAsString()).trim() == 'running';
          if (!await file.parent.exists()) await file.parent.create(recursive: true);
          await file.writeAsString('running', flush: true);
        }
      } catch (error, stackTrace) {
        appLogger.d('Could not mark the app launch', error: error, stackTrace: stackTrace);
      }
    }
    _abnormalExitDetected = abnormal;
    return abnormal;
  }

  /// Call on a clean shutdown (engine detached): the next launch then
  /// knows this one ended normally. Best effort, never throws; synchronous
  /// when the directory is known so it lands before the process exits.
  static void markCleanExit() {
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) {
      _writeExitStateSync(directory, 'clean');
      return;
    }
    unawaited(
      _file(exitStateFileName)
          .then((file) async {
            if (file == null) return;
            if (!await file.parent.exists()) await file.parent.create(recursive: true);
            await file.writeAsString('clean', flush: true);
          })
          .catchError((Object _) {}),
    );
  }

  /// Best-effort record of a fatal error. Never throws.
  static void record(Object error, {StackTrace? stackTrace, String source = 'uncaught', DateTime? timestamp}) {
    final record = LastCrashRecord(
      errorType: error.runtimeType.toString(),
      message: error.toString(),
      stackTrace: stackTrace?.toString(),
      timestamp: timestamp ?? DateTime.now(),
      source: source,
    );
    final directory = debugDirectoryOverride ?? _cachedDirectory;
    if (directory != null) {
      _writeSync(directory, record);
      return;
    }
    _writeInFlight = (_writeInFlight ?? Future<void>.value())
        .then((_) async {
          final file = await _file();
          if (file == null) return;
          await _writeFile(file, record);
        })
        .catchError((Object _) {});
  }

  static void _writeSync(Directory directory, LastCrashRecord record) {
    try {
      final file = File(p.join(directory.path, fileName));
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(record.toJson()), flush: true);
    } catch (error, stackTrace) {
      appLogger.d('Could not persist the last crash record', error: error, stackTrace: stackTrace);
    }
    _appendHistorySync(directory, record);
  }

  /// Prepends [record] to the history file (newest first), trimming to
  /// [maxHistoryEntries]. Best effort, never throws.
  static void _appendHistorySync(Directory directory, LastCrashRecord record) {
    try {
      final file = File(p.join(directory.path, historyFileName));
      var entries = _readHistorySync(file);
      entries.insert(0, record);
      if (entries.length > maxHistoryEntries) entries = entries.sublist(0, maxHistoryEntries);
      if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode(entries.map((e) => e.toJson()).toList()),
        flush: true,
      );
    } catch (error, stackTrace) {
      appLogger.d('Could not persist the crash history', error: error, stackTrace: stackTrace);
    }
  }

  static List<LastCrashRecord> _readHistorySync(File file) {
    try {
      if (!file.existsSync()) return [];
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((m) => LastCrashRecord.fromJson(m.cast<String, Object?>()))
          .whereType<LastCrashRecord>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _writeFile(File file, LastCrashRecord record) async {
    try {
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(record.toJson()), flush: true);
    } catch (error, stackTrace) {
      appLogger.d('Could not persist the last crash record', error: error, stackTrace: stackTrace);
    }
    try {
      final historyFile = File(p.join(file.parent.path, historyFileName));
      var entries = _readHistorySync(historyFile);
      entries.insert(0, record);
      if (entries.length > maxHistoryEntries) entries = entries.sublist(0, maxHistoryEntries);
      await historyFile.writeAsString(
        jsonEncode(entries.map((e) => e.toJson()).toList()),
        flush: true,
      );
    } catch (error, stackTrace) {
      appLogger.d('Could not persist the crash history', error: error, stackTrace: stackTrace);
    }
  }

  /// Reads the persisted record without consuming it, or null when there
  /// is none or it cannot be parsed. Waits for an in-flight [record] so a
  /// just-recorded crash is visible.
  static Future<LastCrashRecord?> read() async {
    final inFlight = _writeInFlight;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {
        // Best effort: a failed write must not block the read.
      }
    }
    try {
      final file = await _file();
      if (file == null || !await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return LastCrashRecord.fromJson(decoded.cast<String, Object?>());
    } catch (error, stackTrace) {
      appLogger.d('Could not read the last crash record', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  /// Every recorded crash, newest first (capped at [maxHistoryEntries] by
  /// [record]). When no history file exists yet — e.g. the app updated from
  /// a version that only kept the latest — the legacy single record seeds
  /// the list, so the one crash already on the phone is not lost.
  static Future<List<LastCrashRecord>> readHistory() async {
    final inFlight = _writeInFlight;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {
        // Best effort: a failed write must not block the read.
      }
    }
    try {
      final file = await _file(historyFileName);
      if (file != null && await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          final entries = decoded
              .whereType<Map>()
              .map((m) => LastCrashRecord.fromJson(m.cast<String, Object?>()))
              .whereType<LastCrashRecord>()
              .toList();
          if (entries.isNotEmpty) return entries;
        }
      }
    } catch (error, stackTrace) {
      appLogger.d('Could not read the crash history', error: error, stackTrace: stackTrace);
    }
    final latest = await read();
    return latest == null ? [] : [latest];
  }

  /// Deletes the persisted record and the history. Never throws.
  static Future<void> clear() async {
    try {
      final file = await _file();
      if (file != null && await file.exists()) await file.delete();
      final historyFile = await _file(historyFileName);
      if (historyFile != null && await historyFile.exists()) await historyFile.delete();
    } catch (error, stackTrace) {
      appLogger.d('Could not clear the last crash record', error: error, stackTrace: stackTrace);
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _cachedDirectory = null;
    _writeInFlight = null;
    _abnormalExitDetected = false;
  }
}

/// Installs the fatal-error catcher for the whole app.
///
/// Installed once, in `_bootstrapApp`, before `runApp` — early enough to
/// cover the startup crash. Both handlers chain to whatever was installed
/// before them (the framework default, and later Sentry's
/// `OnErrorIntegration` chains to this one), so console output and crash
/// reporting keep working exactly as before.
///
/// `PlatformDispatcher.onError` fires for uncaught async errors — the
/// process is dying, so those are always recorded. `FlutterError.onError`
/// fires for framework-caught errors too (a build error the framework
/// contains and survives), so those are recorded as well — except the one
/// known-benign diagnostic: a `RenderFlex overflowed` error paints
/// yellow/black stripes in a debug build but the app keeps running, and on
/// a 360dp cover screen it fires on the Discover app bar every launch,
/// which would overwrite the real crash record before anyone screenshots
/// it.
abstract final class LastCrashCatcher {
  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;

    final previousFlutterErrorHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (!_isBenignLayoutDiagnostic(details)) {
        LastCrashStore.record(details.exception, stackTrace: details.stack, source: 'framework');
      }
      previousFlutterErrorHandler?.call(details);
    };

    final dispatcher = PlatformDispatcher.instance;
    final previousOnError = dispatcher.onError;
    dispatcher.onError = (Object error, StackTrace stack) {
      LastCrashStore.record(error, stackTrace: stack, source: 'uncaught');
      if (previousOnError != null) return previousOnError(error, stack);
      return false;
    };
  }

  static bool _isBenignLayoutDiagnostic(FlutterErrorDetails details) {
    return details.exception.toString().startsWith('A RenderFlex overflowed');
  }

  @visibleForTesting
  static void resetForTesting() {
    _installed = false;
  }
}
