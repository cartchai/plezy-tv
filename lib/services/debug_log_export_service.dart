import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../i18n/strings.g.dart';
import '../utils/log_redaction_manager.dart';
import '../utils/platform_detector.dart';
import 'device_performance.dart';
import 'file_picker_service.dart';
import 'last_crash_store.dart';
import 'sensitive_prefs.dart';
import 'settings_export_service.dart';
import 'settings_service.dart';
import 'storage_service.dart';

/// Debug log export (1.2.6, Matt ~2026-11-13 16:25 EST): one file with
/// all settings, logs, errors and app info, saved from Settings → Logs.
/// The caller passes the already-formatted logs text ([buildDebugText]
/// appends the settings, memory and last-crash sections to it); the app
/// version + device + startup record come from that base text, so they
/// are not duplicated here.
///
/// Privacy (standing Trex ban): the file must NEVER carry the panel
/// address or login. Three layers: the settings section is built only
/// from the closed portable registry ([SettingsExportService
/// .buildExportMap] — endpoints and credentials are never in it), the
/// renderer drops sensitive keys and withholds URL-looking values, and
/// the whole file goes through [LogRedactionManager.redact] before it
/// is written.
class DebugLogExportService {
  /// File name for the export, e.g. `pleztv-debug-20261113-204500.txt`.
  @visibleForTesting
  static String debugFileName([DateTime? now]) {
    final t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'pleztv-debug-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.txt';
  }

  /// Render the settings export map as `key: value` lines, sorted by
  /// key, with the `prefs` map rendered one level indented. Pure and
  /// testable. Keys the sensitive-prefs list names never render, and
  /// any string value that looks like a URL (a server address that
  /// slipped into a portable string pref) renders as `[URL withheld]`
  /// instead of the address itself.
  @visibleForTesting
  static String renderSettingsSection(Map<String, dynamic> exportMap) {
    final lines = <String>[];
    final keys = exportMap.keys.toList()..sort();
    for (final key in keys) {
      final value = exportMap[key];
      if (value is Map) {
        lines.add('$key:');
        final subKeys = value.keys.map((k) => '$k').toList()..sort();
        for (final subKey in subKeys) {
          if (isSensitivePrefKey(subKey)) continue;
          lines.add('  $subKey: ${_renderSettingValue(value[subKey])}');
        }
      } else {
        lines.add('$key: ${_renderSettingValue(value)}');
      }
    }
    return lines.join('\n');
  }

  static String _renderSettingValue(Object? value) {
    if (value is Map && value.containsKey('value')) {
      final inner = _renderSettingValue(value['value']);
      final type = value['type'];
      return type == null ? inner : '$inner ($type)';
    }
    if (value is String && value.contains('://')) return '[URL withheld]';
    // 1.2.7 (T4b): a URL-looking element inside a List value is
    // withheld the same way — a list of server addresses is still a
    // list of server addresses.
    if (value is List) {
      return jsonEncode(
        value.map((e) => e is String && e.contains('://') ? '[URL withheld]' : e).toList(),
      );
    }
    return '$value';
  }

  /// The settings section, from the live portable prefs.
  static Future<String> buildSettingsSection() async {
    final prefs = (await SettingsService.getInstance()).prefs;
    final storage = await StorageService.getInstance();
    String appVersion = '';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.version;
    } on Exception {
      // Best-effort metadata; platforms without PackageInfo (and unit
      // tests, where the plugin channel has no implementation) still
      // export.
    }
    final exportMap = SettingsExportService.buildExportMap(
      prefs,
      currentUserUuid: storage.activeUserScope(),
      appVersion: appVersion,
    );
    return renderSettingsSection(exportMap);
  }

  /// Current memory numbers: RSS now/max and device RAM, plus the
  /// low-end flag the bind gate reads. The startup RSS and pressure
  /// history live in the base logs text already.
  static String buildMemorySection() {
    final rss = ProcessInfo.currentRss;
    final maxRss = ProcessInfo.maxRss;
    final totalMem = DevicePerformance.totalMemBytes;
    final lines = <String>[
      'RSS now: ${rss >> 20} MB ($rss bytes)',
      'RSS max: ${maxRss >> 20} MB ($maxRss bytes)',
      'Device total RAM: ${totalMem == null ? 'unknown' : '${totalMem >> 20} MB ($totalMem bytes)'}',
      'Low-end hardware: ${DevicePerformance.isLowEndHardware}',
    ];
    return lines.join('\n');
  }

  /// The last recorded crash, or that none was recorded.
  static Future<String> buildLastCrashSection() async {
    final record = await LastCrashStore.read();
    return record?.describe() ?? 'none recorded';
  }

  /// One line identifying the app + device for the summary block.
  /// Best-effort: on a platform without the device-info channel (and in
  /// unit tests) it falls back to 'unknown' rather than throwing.
  static Future<String> buildDeviceLine() async {
    String appVersion = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Best-effort metadata.
    }
    String device = 'unknown device';
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await plugin.androidInfo;
        device = '${android.manufacturer} ${android.model} — Android ${android.version.release} (API ${android.version.sdkInt})';
      } else if (Platform.isIOS) {
        final ios = await plugin.iosInfo;
        device = '${ios.model} — iOS ${ios.systemVersion}';
      } else {
        device = Platform.operatingSystem;
      }
    } catch (_) {
      // Best-effort metadata.
    }
    return 'App: PlezTV $appVersion — $device';
  }

  /// One-line memory numbers for the summary block (the full numbers
  /// stay in [buildMemorySection] below, unchanged).
  static String buildMemorySummaryLine() {
    final rss = ProcessInfo.currentRss;
    final maxRss = ProcessInfo.maxRss;
    final totalMem = DevicePerformance.totalMemBytes;
    return 'Memory: RSS now: ${rss >> 20} MB / max: ${maxRss >> 20} MB — device total RAM: ${totalMem == null ? 'unknown' : '${totalMem >> 20} MB'} — low-end: ${DevicePerformance.isLowEndHardware}';
  }

  /// Memory-pressure events in the log: the watchdog's 'RSS high'
  /// drop line (one per trip — the image-cache line from the same trip
  /// is not a second event) plus the OS pressure line. The worst RSS
  /// comes from the watchdog lines.
  static String buildPressureSummaryLine(String baseLogsText) {
    var events = 0;
    var worstRssMb = 0;
    for (final line in baseLogsText.split('\n')) {
      if (line.contains('System memory pressure')) {
        events++;
      } else if (line.contains('RSS high (') && line.contains('dropped IPTV catalogs')) {
        events++;
        final match = RegExp(r'RSS high \((\d+)MB').firstMatch(line);
        if (match != null) {
          final rss = int.tryParse(match.group(1)!) ?? 0;
          if (rss > worstRssMb) worstRssMb = rss;
        }
      }
    }
    if (events == 0) return 'Memory pressure: none recorded';
    return 'Memory pressure: $events events, worst RSS $worstRssMb MB';
  }

  /// The previous exit reason, from the last 'Previous Android
  /// application exit' line in the log (the whole line — it already
  /// carries the startup phase and RSS).
  static String buildPreviousExitSummaryLine(String baseLogsText) {
    const prefix = 'Previous Android application exit: ';
    String? last;
    for (final line in baseLogsText.split('\n')) {
      final index = line.indexOf(prefix);
      if (index != -1) last = line.substring(index + prefix.length).trim();
    }
    if (last == null || last.isEmpty) return 'Previous exit: none recorded';
    return 'Previous exit: $last';
  }

  /// The last recorded crash, one line: when + error type + short message.
  static Future<String> buildLastCrashSummaryLine() async {
    final record = await LastCrashStore.read();
    if (record == null) return 'Last crash: none recorded';
    final firstLine = record.message.split('\n').first;
    final short = firstLine.length > 120 ? '${firstLine.substring(0, 120)}…' : firstLine;
    return 'Last crash: ${record.timestamp.toUtc().toIso8601String()} [${record.source}] ${record.errorType}: $short';
  }

  /// The summary block (1.2.9, Matt ~2026-11-14 02:14 EST): the facts
  /// someone opens the file to find, at the very top, before the log —
  /// so the file is easy to access without scrolling through hundreds
  /// of lines. One line each; the sections below stay unchanged.
  static Future<String> buildSummarySection({
    required String baseLogsText,
    required String dumpReason,
    required int failedStarts,
  }) async {
    final lines = <String>[
      '== Summary ==',
      await buildDeviceLine(),
      buildMemorySummaryLine(),
      buildPressureSummaryLine(baseLogsText),
      buildPreviousExitSummaryLine(baseLogsText),
      await buildLastCrashSummaryLine(),
      'Failed starts: $failedStarts — $dumpReason',
    ];
    return lines.join('\n');
  }

  /// The full debug file text: a summary block first, then the base logs
  /// text (device + app info + startup record + logs, errors and stack
  /// traces — the FULL log, nothing trimmed), plus the settings, memory
  /// and last-crash sections. The whole file is redacted before it is
  /// returned, so a panel URL, token or password-like value that somehow
  /// reached the logs or the settings never lands in the file.
  ///
  /// [dumpReason] says why this file was written ('auto-dump after 3
  /// failed starts', or the manual-export default); [failedStarts]
  /// defaults to the live counter.
  static Future<String> buildDebugText({
    required String baseLogsText,
    String? dumpReason,
    int? failedStarts,
  }) async {
    final reason = dumpReason ?? 'manual export from Settings → Logs';
    final count = failedStarts ?? await LastCrashStore.readFailedStartCount();
    final buffer = StringBuffer(
      await buildSummarySection(baseLogsText: baseLogsText, dumpReason: reason, failedStarts: count),
    );
    buffer.writeln();
    buffer.writeln();
    buffer.writeln(baseLogsText);
    buffer.writeln();
    buffer.writeln('== Settings ==');
    buffer.writeln(await buildSettingsSection());
    buffer.writeln();
    buffer.writeln('== Memory ==');
    buffer.writeln(buildMemorySection());
    buffer.writeln();
    buffer.writeln('== Last crash ==');
    buffer.writeln(await buildLastCrashSection());
    return LogRedactionManager.redact(buffer.toString());
  }

  /// Build the debug file and write it to a location of the user's
  /// choosing. Returns the saved path, or `null` if the user cancelled
  /// the picker. Same shape as [SettingsExportService.exportToFile]:
  /// Android TV has no document picker, so it writes to the app docs
  /// dir and the caller surfaces the path.
  static Future<String?> exportToFile({required String baseLogsText}) async {
    final text = await buildDebugText(baseLogsText: baseLogsText);
    final bytes = Uint8List.fromList(utf8.encode(text));
    final fileName = debugFileName();

    // Android TV has no document picker — write to the app docs dir and let
    // the caller surface the path.
    if (Platform.isAndroid && PlatformDetector.isTV()) {
      return _writeToAppDocuments(fileName, bytes);
    }

    return FilePickerService.instance.saveFile(
      dialogTitle: t.logs.exportDebugDialogTitle,
      fileName: fileName,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['txt'],
    );
  }

  static Future<String> _writeToAppDocuments(String fileName, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
