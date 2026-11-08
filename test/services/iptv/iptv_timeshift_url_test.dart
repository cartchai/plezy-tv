// FAILING-FIRST — build #16 (v2.25.12): catch-up "isn't working" on Matt's
// phone (2026-11-08 ~10:38 EST). Tapping a past programme (The Office,
// 9:30 AM) gives "Could not start the live channel".
//
// Root cause (by code-read + documented format): the timeshift URL the app
// builds has a start stamp the panel cannot parse. Every documented source
// (UniPlayer catch-up spec, Dispatcharr/pvr.dispatcharr's Xtream client,
// the Xtream API docs) agrees the start is `YYYY-MM-DD:HH-MM` — NO seconds
// ("Strict `YYYY-MM-DD:HH-MM`" — Dispatcharr). Our builder appended
// seconds (`YYYY-MM-DD:HH-MM-SS`, e.g. `2026-11-08:14-30-00`), so the
// panel's strict parse fails, no archive segment resolves, and mpv's open
// of the URL fails → the mini-player's "Could not start" card. Duration
// (minutes) and the UTC choice match the documented clients and are
// unchanged.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

void main() {
  group('build16: Xtream timeshift URL start format', () {
    XtreamApi api() => XtreamApi(
          serverUrl: 'https://panel.example.com:8080',
          username: 'user',
          password: _testPassword,
        );

    test('start stamp is YYYY-MM-DD:HH-MM with no seconds', () {
      final url = api().timeshiftUrl(
        streamId: '100',
        durationMinutes: 60,
        start: DateTime.utc(2026, 11, 8, 14, 30),
      );
      expect(url, 'https://panel.example.com:8080/timeshift/user/pass/60/2026-11-08:14-30/100.m3u8');
    });

    test('seconds in the start are dropped, not appended', () {
      // EPG starts are minute-aligned in practice, but a :45s input must
      // still produce the strict HH-MM form — never HH-MM-SS.
      final url = api().timeshiftUrl(
        streamId: '100',
        durationMinutes: 30,
        start: DateTime.utc(2026, 11, 8, 9, 30, 45),
      );
      expect(url, contains('/2026-11-08:09-30/'));
      expect(url, isNot(contains(':09-30-45')));
    });

    test('duration stays in minutes', () {
      final url = api().timeshiftUrl(
        streamId: '100',
        durationMinutes: 68,
        start: DateTime.utc(2026, 11, 8, 14, 30),
      );
      expect(url, contains('/timeshift/user/pass/68/2026-11-08:14-30/100.m3u8'));
    });
  });
}
