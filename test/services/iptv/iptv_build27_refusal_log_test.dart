// Failing-first tests for build #27 (refusal recorder, v1.0.8).
//
// The refusal log does not exist on the base (2643073f9): these tests
// reference the new API, so they fail to compile there and pass on the
// fix. No live panel: fakes only. Credentials below are fake
// ('alice-7' / 'hunter-9') and must never appear in a stored entry.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/iptv/iptv_refusal_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/prefs.dart';

IptvRefusalEntry _entry({
  String action = 'player_api.php?action=get_live_categories',
  int? statusCode = 403,
  String failureKind = 'http',
  Map<String, String> headers = const {'cf-ray': 'abc123', 'server': 'cloudflare'},
  String bodySnippet = 'Just a moment...',
  String userAgent = 'VLC',
  String network = 'wifi',
  String connectionId = 'trex',
  String connectionName = 'Trex',
  DateTime? timestamp,
}) {
  return IptvRefusalEntry(
    timestamp: timestamp ?? DateTime.utc(2026, 11, 10, 5, 40, 12),
    connectionId: connectionId,
    connectionName: connectionName,
    action: action,
    statusCode: statusCode,
    failureKind: failureKind,
    headers: headers,
    bodySnippet: bodySnippet,
    userAgent: userAgent,
    network: network,
  );
}

IptvRefusalLog _log() => IptvRefusalLog(
  prefsProvider: BaseSharedPreferencesService.sharedCache,
  networkTypeProvider: () async => 'wifi',
);

void main() {
  setUp(() => resetSharedPreferencesForTest());

  test('record + read back round-trips every field', () async {
    final log = _log();
    await log.record(
      _entry(),
    );
    final entries = await log.loadEntries();
    expect(entries, hasLength(1));
    final e = entries.single;
    expect(e.action, 'player_api.php?action=get_live_categories');
    expect(e.statusCode, 403);
    expect(e.failureKind, 'http');
    expect(e.headers['cf-ray'], 'abc123');
    expect(e.headers['server'], 'cloudflare');
    expect(e.bodySnippet, 'Just a moment...');
    expect(e.userAgent, 'VLC');
    expect(e.network, 'wifi');
    expect(e.connectionName, 'Trex');
    expect(e.timestamp, DateTime.utc(2026, 11, 10, 5, 40, 12));
  });

  test('log is bounded at 50: oldest entries drop off', () async {
    final log = _log();
    for (var i = 0; i < 55; i++) {
      await log.record(
        _entry(
          action: 'player_api.php?action=call-$i',
          timestamp: DateTime.utc(2026, 11, 10, 5, 40, i),
        ),
      );
    }
    final entries = await log.loadEntries();
    expect(entries, hasLength(IptvRefusalLog.maxEntries));
    // Newest first: the last recorded entry is first, the first five
    // recorded entries are gone.
    expect(entries.first.action, 'player_api.php?action=call-54');
    expect(entries.last.action, 'player_api.php?action=call-5');
    expect(entries.map((e) => e.action), isNot(contains('player_api.php?action=call-0')));
  });

  test('entries survive a restart: a fresh log instance reads the same log', () async {
    await _log().record(_entry(action: 'player_api.php?action=get_live_categories'));
    await _log().record(_entry(action: 'xmltv.php'));
    // A new instance (a new app launch) reads the same persisted log.
    final reopened = await _log().loadEntries();
    expect(reopened, hasLength(2));
    expect(reopened.first.action, 'xmltv.php');
    expect(reopened.last.action, 'player_api.php?action=get_live_categories');
  });

  test('notifier updates on record and clear (the UI listens to it)', () async {
    final log = _log();
    await log.ensureLoaded();
    expect(log.entriesNotifier.value, isEmpty);
    await log.record(_entry());
    expect(log.entriesNotifier.value, hasLength(1));
    await log.clear();
    expect(log.entriesNotifier.value, isEmpty);
  });

  test('clear empties the persisted log', () async {
    final log = _log();
    await log.record(_entry());
    await log.record(_entry(action: 'xmltv.php'));
    await log.clear();
    expect(await log.loadEntries(), isEmpty);
  });

  test('credentials never appear in a stored entry', () async {
    const username = 'alice-7';
    const password = 'hunter-9';
    final uri = Uri.parse(
      'https://panel.example.com:8080/player_api.php?username=$username&password=$password&action=get_live_categories',
    );
    final entry = IptvRefusalEntry(
      timestamp: DateTime.utc(2026, 11, 10, 5, 40, 12),
      action: IptvRefusalEntry.actionForUri(uri),
      statusCode: 403,
      failureKind: 'http',
      // A set-cookie value is a session credential: stored redacted.
      headers: {'set-cookie': 'session=$password-secret', 'cf-ray': 'abc123'},
      // An error page echoing the request URL carries the credentials in
      // `password=` form: the sanitizer (with the caller's credential
      // values, as XtreamApi supplies them) must strip them.
      bodySnippet: IptvRefusalEntry.sanitizeBody(
        'Forbidden: https://panel.example.com:8080/player_api.php?username=$username&password=$password',
        redactValues: const ['alice-7', 'hunter-9'],
      ),
      userAgent: 'VLC',
    );
    await _log().record(entry);
    final stored = await _log().loadEntries();
    expect(stored, hasLength(1));
    final json = jsonEncode(stored.single.toJson());
    expect(json, isNot(contains(username)));
    expect(json, isNot(contains(password)));
    expect(stored.single.headers['set-cookie'], '[REDACTED]');
    expect(stored.single.action, 'player_api.php?action=get_live_categories');
  });

  test('body snippet is truncated to the cap', () async {
    final longBody = 'x' * 5000;
    final entry = _entry(bodySnippet: IptvRefusalEntry.sanitizeBody(longBody));
    await _log().record(entry);
    final stored = await _log().loadEntries();
    expect(stored.single.bodySnippet.length, lessThanOrEqualTo(IptvRefusalLog.maxBodyChars));
  });

  test('actionForUri never leaks credentials, for every URL shape', () {
    const cases = <String, String>{
      'https://panel.example.com:8080/player_api.php?username=alice-7&password=hunter-9&action=get_live_categories':
          'player_api.php?action=get_live_categories',
      'https://panel.example.com:8080/player_api.php?username=alice-7&password=hunter-9': 'player_api.php',
      'https://panel.example.com:8080/xmltv.php?username=alice-7&password=hunter-9': 'xmltv.php',
      'https://panel.example.com:8080/get.php?username=alice-7&password=hunter-9&type=m3u_plus&output=ts':
          'get.php',
      'https://panel.example.com:8080/live/alice-7/hunter-9/123.m3u8': 'live:123',
      'https://panel.example.com:8080/movie/alice-7/hunter-9/456.mp4': 'movie:456',
      'https://panel.example.com:8080/series/alice-7/hunter-9/101.mkv': 'series:101',
      'https://panel.example.com:8080/timeshift/alice-7/hunter-9/60/2026-11-10:05-40/789.m3u8': 'timeshift:789',
      'https://panel.example.com:8080/unknown/path': 'request',
    };
    for (final entry in cases.entries) {
      final action = IptvRefusalEntry.actionForUri(Uri.parse(entry.key));
      expect(action, entry.value, reason: entry.key);
      expect(action, isNot(contains('alice-7')), reason: entry.key);
      expect(action, isNot(contains('hunter-9')), reason: entry.key);
    }
  });

  test('share text names the refusal without credentials', () {
    final entry = _entry();
    final text = entry.toShareText();
    expect(text, contains('HTTP 403'));
    expect(text, contains('player_api.php?action=get_live_categories'));
    expect(text, contains('cf-ray: abc123'));
    expect(text, contains('Just a moment...'));
    expect(text, contains('VLC'));
    expect(text, contains('Trex'));
  });

  test('a transport failure (no HTTP status) round-trips', () async {
    final log = _log();
    await log.record(
      _entry(statusCode: null, failureKind: 'timeout', headers: const {}, bodySnippet: ''),
    );
    final entries = await log.loadEntries();
    expect(entries.single.statusCode, isNull);
    expect(entries.single.failureKind, 'timeout');
    expect(entries.single.toShareText(), contains('timeout'));
  });

  test('a failed load does not poison the log: the next record retries and lands', () async {
    // The prefs store is down for exactly one call, then recovers.
    var calls = 0;
    Future<SharedPreferencesWithCache> flakyProvider() async {
      calls++;
      if (calls == 1) throw StateError('prefs down');
      return BaseSharedPreferencesService.sharedCache();
    }
    final log = IptvRefusalLog(
      prefsProvider: flakyProvider,
      networkTypeProvider: () async => 'wifi',
    );
    // Recording never throws, even with the store down — the entry is
    // dropped, not the caller.
    await log.record(_entry());
    expect(calls, 1);
    // The second record retries the load (the failed future is not
    // cached) and lands.
    await log.record(_entry(action: 'xmltv.php'));
    final entries = await log.loadEntries();
    expect(entries, hasLength(1));
    expect(entries.single.action, 'xmltv.php');
  });

  test('record never throws when the network probe throws (the entry still lands)', () async {
    final log = IptvRefusalLog(
      prefsProvider: BaseSharedPreferencesService.sharedCache,
      networkTypeProvider: () async => throw StateError('probe down'),
    );
    // The entry carries no network, so record resolves it via the probe.
    await log.record(_entry(network: 'unknown'));
    final entries = await log.loadEntries();
    expect(entries, hasLength(1));
    expect(entries.single.network, 'unknown');
  });
}
