import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'log_redaction_manager.dart';

/// Represents a single log entry stored in memory
class LogEntry {
  final DateTime timestamp;
  final Level level;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  const LogEntry({required this.timestamp, required this.level, required this.message, this.error, this.stackTrace});

  /// Estimate the memory size of this log entry in bytes
  int get estimatedSize {
    int size = 0;
    size += 8;
    size += 4;
    size += message.length * 2;
    if (error != null) {
      size += error.toString().length * 2;
    }
    if (stackTrace != null) {
      size += stackTrace.toString().length * 2;
    }
    return size;
  }
}

/// In-memory log store with a circular buffer.
///
/// Fed by [MemoryAwareLogPrinter.log()]; console output goes through the
/// logger's default [ConsoleOutput].
class MemoryLogOutput {
  static const int maxLogSizeBytes = 5 * 1024 * 1024;
  static final ListQueue<LogEntry> _logs = ListQueue<LogEntry>();
  static int _currentSize = 0;

  /// Append [entry], evicting the oldest entries once the buffer exceeds
  /// [maxLogSizeBytes] — O(1) with ListQueue.
  static void add(LogEntry entry) {
    _logs.add(entry);
    _currentSize += entry.estimatedSize;
    while (_currentSize > maxLogSizeBytes && _logs.isNotEmpty) {
      _currentSize -= _logs.removeFirst().estimatedSize;
    }
  }

  static List<LogEntry> getLogs() => _logs.toList().reversed.toList();

  static void clearLogs() {
    _logs.clear();
    _currentSize = 0;
  }
}

/// The one-line text form of [entry], matching the format the Logs screen
/// and the debug export use (`[HH:MM:SS.mmm] [LEVEL] message`, error and
/// stack trace on following lines).
String formatLogEntry(LogEntry entry) {
  final t = entry.timestamp;
  String two(int v) => v.toString().padLeft(2, '0');
  String three(int v) => v.toString().padLeft(3, '0');
  final buffer = StringBuffer(
    '[${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}] '
    '[${entry.level.name.toUpperCase()}] ${entry.message}',
  );
  if (entry.error != null) buffer.write('\nError: ${entry.error}');
  if (entry.stackTrace != null) buffer.write('\nStack trace:\n${entry.stackTrace}');
  return buffer.toString();
}

/// Rolling file log (1.2.9, auto-dump): every redacted line the printer
/// stores in memory is also appended to a rolling file in the app support
/// dir, so a crash does not lose the log. The file survives any process
/// kill (LMK / crash / force-stop) because plain sync writes land in the
/// OS page cache — only a kernel panic or power loss loses them — so no
/// per-line fsync is needed; the file is flushed on a 1 s timer and on
/// error lines.
///
/// Size: 2 MB per file, current + 1 rotated (4 MB max on disk). The memory
/// buffer stays at its 5 MB cap. The rolling file IS the auto-dump's log
/// (Matt, 2026-11-14 ~02:15 EST: nothing gets cut — the dump carries the
/// complete rolling log); the dump goes through
/// [DebugLogExportService.buildDebugText] (redacted, settings from the
/// closed portable registry). The file lives in app-private storage and
/// its lines are redacted by the printer before they get here — the Trex
/// ban applies throughout: no panel URL, username, or password may reach
/// the file.
class FileLogOutput {
  static const int maxFileSizeBytes = 2 * 1024 * 1024;

  static const String fileName = 'pleztv-rolling-log.txt';
  static const String rotatedFileName = 'pleztv-rolling-log.txt.1';

  @visibleForTesting
  static Directory? debugDirectoryOverride;

  static RandomAccessFile? _file;
  static Directory? _directory;
  static int _bytesWritten = 0;
  static Timer? _flushTimer;
  static bool _primed = false;

  /// Resolve the support dir, rotate if the file is already over the cap,
  /// open in append mode, then drain the memory buffer first so no line
  /// logged before the file opened is lost. Called unawaited from
  /// `_bootstrapApp` alongside `LastCrashStore.prime()`. Never throws;
  /// when the file cannot open, logging continues memory-only.
  static Future<void> prime() async {
    if (_primed) return;
    _primed = true;
    try {
      final directory = debugDirectoryOverride ?? await getApplicationSupportDirectory();
      _directory = directory;
      if (!directory.existsSync()) directory.createSync(recursive: true);
      _rotateIfOverCap(directory);
      final file = File(p.join(directory.path, fileName));
      _file = file.openSync(mode: FileMode.append);
      _bytesWritten = file.lengthSync();
      // Drain oldest-first: lines logged since process start, before the
      // file was open. (getLogs returns newest-first.)
      for (final entry in MemoryLogOutput.getLogs().reversed) {
        _appendSync(formatLogEntry(entry));
      }
      _flushTimer = Timer.periodic(const Duration(seconds: 1), (_) => _flush());
    } catch (_) {
      // Best effort: the file is diagnostics, never load-bearing. Close
      // the handle if it opened before the failure, so it does not leak.
      try {
        _file?.closeSync();
      } catch (_) {
        // Best effort.
      }
      _file = null;
    }
  }

  /// Append one already-redacted line (the printer redacts before it gets
  /// here). Sync write to the page cache — survives a process kill. A
  /// no-op before [prime] (the line stays in memory and drains on prime).
  /// Never throws, and never logs (that would recurse into the printer).
  static void appendLine(String line, {bool isError = false}) {
    if (_file == null) return;
    try {
      _appendSync(line);
      if (isError) _flush();
    } catch (_) {
      // Logging must never break the app.
    }
  }

  static void _appendSync(String line) {
    final file = _file;
    if (file == null) return;
    final bytes = utf8.encode('$line\n');
    if (_bytesWritten + bytes.length > maxFileSizeBytes) {
      _rotate();
      // The rotate closed the file; _file is null again if it failed.
      if (_file == null) return;
    }
    _file!.writeFromSync(bytes);
    _bytesWritten += bytes.length;
  }

  /// The whole rolling log (rotated file first — it is older — then the
  /// current file), for the auto-dump base text. Nothing is trimmed (Matt,
  /// 2026-11-14 ~02:15 EST: "it doesnt have to be shorter it just needs
  /// to be easy to access"); the 2 MB-per-file cap bounds the total at
  /// 4 MB. Never throws; returns '' when there is nothing to read.
  static Future<String> readFullLog() async {
    try {
      final directory = debugDirectoryOverride ?? _directory ?? await getApplicationSupportDirectory();
      final bytes = <int>[];
      for (final name in [rotatedFileName, fileName]) {
        final file = File(p.join(directory.path, name));
        if (file.existsSync()) bytes.addAll(file.readAsBytesSync());
      }
      if (bytes.isEmpty) return '';
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  static void _rotateIfOverCap(Directory directory) {
    try {
      final file = File(p.join(directory.path, fileName));
      if (file.existsSync() && file.lengthSync() > maxFileSizeBytes) {
        final rotated = File(p.join(directory.path, rotatedFileName));
        if (rotated.existsSync()) rotated.deleteSync();
        file.renameSync(rotated.path);
      }
    } catch (_) {
      // Best effort.
    }
  }

  static void _rotate() {
    final directory = _directory;
    if (directory == null) return;
    try {
      _file?.closeSync();
    } catch (_) {
      // Best effort.
    }
    _file = null;
    // Unconditional rename: the caller rotates because the file reached
    // the cap, not because it is already over it.
    try {
      final current = File(p.join(directory.path, fileName));
      final rotated = File(p.join(directory.path, rotatedFileName));
      if (rotated.existsSync()) rotated.deleteSync();
      if (current.existsSync()) current.renameSync(rotated.path);
    } catch (_) {
      // Best effort.
    }
    try {
      final file = File(p.join(directory.path, fileName));
      _file = file.openSync(mode: FileMode.append);
      _bytesWritten = 0;
    } catch (_) {
      _file = null;
    }
  }

  static void _flush() {
    try {
      _file?.flushSync();
    } catch (_) {
      // Best effort.
    }
  }

  @visibleForTesting
  static Future<void> resetForTesting() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    try {
      await _file?.close();
    } catch (_) {
      // Best effort.
    }
    _file = null;
    _directory = null;
    _bytesWritten = 0;
    _primed = false;
  }
}

/// Custom log printer that also stores error and stack trace information
class MemoryAwareLogPrinter extends LogPrinter {
  final LogPrinter _wrappedPrinter;

  MemoryAwareLogPrinter(this._wrappedPrinter);

  @override
  List<String> log(LogEvent event) {
    final message = LogRedactionManager.redact(event.message.toString());
    final error = event.error != null ? LogRedactionManager.redact(event.error.toString()) : null;
    final stackTrace = event.stackTrace != null
        ? StackTrace.fromString(LogRedactionManager.redact(event.stackTrace.toString()))
        : null;

    final entry = LogEntry(
      timestamp: DateTime.now(),
      level: event.level,
      message: message,
      error: error,
      stackTrace: stackTrace,
    );
    MemoryLogOutput.add(entry);
    // Always-on file logging (1.2.9): the same redacted line, all levels.
    FileLogOutput.appendLine(formatLogEntry(entry), isError: event.level.index >= Level.error.index);

    return _wrappedPrinter.log(LogEvent(event.level, message, time: event.time, error: error, stackTrace: stackTrace));
  }
}

/// Custom production filter that respects our level setting even in release mode
class ProductionFilter extends LogFilter {
  Level _currentLevel = Level.debug;

  void setLevel(Level level) {
    _currentLevel = level;
  }

  bool isEnabledFor(Level level) => level.value >= _currentLevel.value;

  @override
  bool shouldLog(LogEvent event) => isEnabledFor(event.level);
}

final _productionFilter = ProductionFilter();

/// Whether [appLogger].d would actually emit.
///
/// 1.2.9: the debug-logging setting was removed (Matt: logging is not
/// supposed to be a setting) and production always runs at debug level,
/// so this is always true in the app — the guards that read it now mean
/// "debug logging is on", which it always is. Dart builds a log call's
/// message argument *before* the filter can drop it, so a `.d()` whose
/// message costs real work — string interpolation in a loop, `redact()`,
/// `jsonEncode`, a collection `toString()` — pays that cost on every call
/// in release, where the line is then discarded. Guard those call sites
/// with this; plain constant or cheap messages need no guard.
bool get debugLoggingEnabled => _productionFilter.isEnabledFor(Level.debug);

/// Centralized logger instance for the application.
///
/// Usage:
/// ```dart
/// import 'package:plezy/utils/app_logger.dart';
///
/// appLogger.d('Debug message');
/// appLogger.i('Info message');
/// appLogger.w('Warning message');
/// appLogger.e('Error message', error: e, stackTrace: stackTrace);
/// ```
///
/// Non-final so tests can swap in a recording logger.
Logger appLogger = Logger(printer: MemoryAwareLogPrinter(SimplePrinter()), filter: _productionFilter);

/// Update the logger's level dynamically.
///
/// [ProductionFilter] is the only gate: [Logger] asks its filter on every
/// event, so changing the filter level is sufficient even in release mode.
///
/// 1.2.9: production no longer calls this — the debug-logging setting was
/// removed and the filter stays at its debug default. It remains for
/// tests that silence logs around noisy fixtures.
void setLoggerLevel(bool debugEnabled) {
  _productionFilter.setLevel(debugEnabled ? Level.debug : Level.info);
}
