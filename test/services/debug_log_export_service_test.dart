// 1.2.6 — debug log export (Matt ~2026-11-13 16:25 EST): one file with
// all settings, logs, errors and app info, saved from Settings → Logs.
// The privacy tests are the point: no panel URL or credential-like
// string may ever appear in the file (standing Trex ban).
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/debug_log_export_service.dart';
import 'package:plezy/utils/log_redaction_manager.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  tearDown(() {
    LogRedactionManager.clearTrackedValues();
  });

  group('debug log export', () {
    test('renderSettingsSection renders sorted key: value (type) lines', () {
      final section = DebugLogExportService.renderSettingsSection({
        'formatVersion': 2,
        'appVersion': '1.2.6-2.25.0',
        'exportedAt': '2026-11-13T20:00:00.000Z',
        'platform': 'android',
        'prefs': {
          'neon_glow': {'type': 'bool', 'value': true},
          'accent_color': {'type': 'string', 'value': 'blue'},
          'hidden_initials': {
            'type': 'stringList',
            'value': ['EN', 'FR'],
          },
        },
      });
      expect(section, contains('appVersion: 1.2.6-2.25.0'));
      expect(section, contains('formatVersion: 2'));
      expect(section, contains('  neon_glow: true (bool)'));
      expect(section, contains('  accent_color: blue (string)'));
      expect(section, contains('  hidden_initials: ["EN","FR"] (stringList)'));
      // Sorted within the prefs block.
      expect(
        section.indexOf('accent_color'),
        lessThan(section.indexOf('neon_glow')),
      );
    });

    test('renderSettingsSection drops sensitive keys and withholds URLs', () {
      final section = DebugLogExportService.renderSettingsSection({
        'prefs': {
          'credential_vault_key_v1': {'type': 'string', 'value': 'abc123'},
          'plex_token': {'type': 'string', 'value': 'tok456'},
          'xtream_server_url': {
            'type': 'string',
            'value': 'https://panel.example.com:8080',
          },
          'theme': {'type': 'string', 'value': 'dark'},
        },
      });
      expect(section, isNot(contains('abc123')));
      expect(section, isNot(contains('tok456')));
      expect(section, isNot(contains('credential_vault_key_v1')));
      expect(section, isNot(contains('plex_token')));
      expect(section, isNot(contains('panel.example.com')));
      expect(section, contains('[URL withheld]'));
      expect(section, contains('theme: dark (string)'));
    });

    test('renderSettingsSection withholds URL-looking elements inside List values (T4b)', () {
      // 1.2.6 tester probe T4b: a url_list holding a panel URL plus a
      // plain element — the URL must be withheld like a scalar URL, the
      // plain element stays.
      final section = DebugLogExportService.renderSettingsSection({
        'prefs': {
          'url_list': {
            'type': 'stringList',
            'value': ['https://panel.example.com:8080', 'EN'],
          },
          'theme': {'type': 'string', 'value': 'dark'},
        },
      });
      expect(section, isNot(contains('panel.example.com')));
      expect(section, contains('[URL withheld]'));
      expect(section, contains('"EN"'));
      expect(section, contains('theme: dark (string)'));
    });

    test('debugFileName has the pleztv-debug-YYYYMMDD-HHMMSS.txt shape', () {
      expect(
        DebugLogExportService.debugFileName(DateTime(2026, 11, 13, 20, 45, 30)),
        'pleztv-debug-20261113-204530.txt',
      );
    });

    test('buildMemorySection reports RSS numbers', () {
      final section = DebugLogExportService.buildMemorySection();
      expect(section, contains('RSS now:'));
      expect(section, contains('RSS max:'));
      expect(section, contains('Device total RAM:'));
      expect(section, contains('Low-end hardware:'));
    });

    test('buildDebugText keeps the sections and redacts panel URLs and passwords', () async {
      // At runtime the panel URL is registered before any HTTP traffic
      // (registerServer), so the redactor knows it; mirror that here.
      LogRedactionManager.registerServerUrl('https://panel.example.com:8080');
      const base =
          '[20:00:00] [I] IPTV: search index seeded from disk cache\n'
          '[20:01:00] [E] panel call failed https://panel.example.com:8080/player_api.php\n'
          'Error: password: hunter2\n';
      final text = await DebugLogExportService.buildDebugText(baseLogsText: base);
      expect(text, contains('== Settings =='));
      expect(text, contains('== Memory =='));
      expect(text, contains('== Last crash =='));
      expect(text, contains('IPTV: search index seeded from disk cache'));
      expect(text, isNot(contains('panel.example.com')));
      expect(text, isNot(contains('hunter2')));
      expect(text, contains('[REDACTED_URL]'));
    });
  });
}
