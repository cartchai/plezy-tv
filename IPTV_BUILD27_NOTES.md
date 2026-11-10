# IPTV build #27 — refusal recorder (v1.0.8-2.25.0+180)

## Why

The app used to discard the body and headers of every refused Xtream
response, so a 403 could not be told apart from a Cloudflare/WAF block, a
flood-protection block, or a panel error — see
`~/workspace/tmp_work/plezy-tv-research-trex-block-causes/RESEARCH_TREX_BLOCK_CAUSES.md`
(§2: "The app currently discards the 403 body and headers"; the
discriminator between a Cloudflare block and a panel block IS the 403
response itself: `cf-ray` / `server: cloudflare` headers and a
"Just a moment..." body). Matt: "Ok so start recording refusals"
(2026-11-10 ~05:40 EST). This build records what the app already sees
during his normal use — it adds no new panel calls, probes, or retries.

## What

- NEW `lib/services/iptv/iptv_refusal_log.dart` — `IptvRefusalEntry`
  (timestamp, connection id/name, action, HTTP status or null, failure
  kind, headers, body snippet ≤2048 chars, User-Agent, network) +
  `IptvRefusalLog` (persisted, bounded at 50 newest-first, in one
  SharedPreferences string via the app-wide shared cache; writes
  serialised; recording never throws; a `ValueNotifier` for the UI).
- `IptvRefusalEntry.actionForUri` derives the action without host or
  credentials: `player_api.php?action=X`, `xmltv.php`, `get.php`,
  `live:123` / `movie:456` / `series:101` / `timeshift:789`, else
  `request`. `sanitizeBody` truncates + `LogRedactionManager.redact`,
  with literal credential values (XtreamApi passes its username and
  password) replaced verbatim first. `sanitizeHeaders` redacts
  cookie/set-cookie/authorization/API-key values wholesale.
- `XtreamApi`: new optional `onRefusal` callback + `connectionId` /
  `connectionName`. `_fetchBody` and `_getText` record every refused
  response (401/403/other non-2xx, with headers + body) and every
  transport failure (timeout/socket, status null) BEFORE the throw.
  Cancellations are NOT recorded (a search the user abandoned is not a
  refusal — otherwise every keystroke would fill the log). The exception
  the caller sees is unchanged.
- `IptvClient._xtreamApi` wires the recorder (connection id + name);
  the sign-in probe in `add_xtream_screen.dart` wires it too (the 06:02
  event WAS a failed sign-in) with the typed name.
- Stream opens: the full player records a newly-latched fatal HTTP
  status (`_onPlayerLog`), a persistent 503 (`_onOpenHttp503Persistent`)
  and an open-deadline expiry (`_onOpenDeadlineExpired`, kind
  'timeout'); the mini-player records in `_fail` when the tune latched
  an HTTP status. Both are gated on IPTV (full player: client is an
  `IptvClient`; mini-player: the session carried a User-Agent — Plex /
  Jellyfin sessions return Accept-Language-only headers). The action is
  the title/channel name, never the stream URL (credentials in its path).
  Fire-and-forget; record-only, failure policy unchanged.
- UI: Settings → IPTV → "Connection refusals" row (count subtitle, or
  "No refusals recorded yet") at the end of the Xtream section, opening NEW
  `lib/screens/settings/iptv_refusals_screen.dart` — entries
  newest-first, each expandable to status/time/connection/network/UA/
  headers/body; Copy (256 KB cap, same rationale as the logs screen)
  and Clear in the AppBar; empty state when nothing is recorded. (The
  row is NOT its own SettingsGroup: a group titled "Connection refusals"
  holding a row titled the same would say it twice.)
- Network type is resolved in the log via `ConnectivityProbe` (500 ms
  cap) only when the entry does not carry one — recording never stalls
  the error path by more than that, and only on the failure path.

## Deliberately left out

- M3U health-probe (HEAD) refusals: the M3U path is not the Trex path;
  the brief covers Xtream + IPTV streams only.
- Image-fetch refusals: NOT included — they do not ride the API-client
  path, and the brief made them optional.
- The two M3U fetches that still send no User-Agent (research §8):
  out of scope for this build.
- No retry/backoff change for 403s (research §7): a separate fix, not
  a recorder's job.
- No new panel calls, no re-probing, no background work.

## Verification

- Failing-first: both new unit test files fail to compile on base 2643073f9
  (new API absent); the widget file fails to compile on base too
  (verified by analyze in a base worktree at d937a1797: missing imports
  `iptv_refusals_screen.dart` / `iptv_refusal_log.dart`, undefined
  `IptvRefusalEntry` / `IptvRefusalLog` / `IptvRefusalsScreen`, undefined
  i18n getters `refusalsTitle` / `refusalsEmpty` / `refusalsDescription`;
  the copy was removed after and the base worktree left clean).
- `test/services/iptv/iptv_build27_refusal_log_test.dart` (10 tests):
  round-trip, 50-entry bound, restart persistence, notifier, clear,
  credentials never stored, body truncation, action sanitizer for all
  URL shapes, share text, transport failure. 10/10.
- `test/services/iptv/iptv_build27_xtream_refusal_test.dart` (11 tests):
  403 Cloudflare (cf-ray + body), 403 panel JSON body, 429 retry-after,
  401, timeout, socket error, cancellation NOT recorded, xmltv.php
  action, configured UA recorded, echoed-URL body redacted, no-hook
  behaviour unchanged. 11/11.
- Widget tests `test/screens/settings/iptv_build27_refusals_screen_test.dart`
  (7 tests): empty state, newest-first order, expand shows headers/body,
  Clear empties, Copy does not crash, settings row exists + opens the log,
  count subtitle after a refusal. 7/7. (Two test-only fixes along the
  way, both documented in the file: `record()` runs inside
  `tester.runAsync` — the prefs async path parks in testWidgets' fake
  async zone; the settings pump uses a tall viewport because the screen
  is long and lazily built and the 200px-step scroll helpers stop with
  the last row below the fold. One real product fix along the way: the
  refusals row moved from its own SettingsGroup into the Xtream section
  — a group titled "Connection refusals" holding a row titled the same
  said it twice.)
- `test/services/iptv/` suite: 315/317, with 2 flakes that pass alone
  (build23 Trex-scale bench: common p95 9878 ms vs the 2000 ms bound
  under suite load — 888 ms alone, median 658 ms; catalog-cache
  corruption test: PathNotFound race on the replaced file — passes
  alone). #23 startup tests 2/2 inside the suite (stale disk 0 catalog
  requests, fresh disk 0) — request profile unchanged.
- `test/screens/settings/` suite: 217 passed, 3 skipped, 1 failed.
  The 1 failure is PRE-EXISTING on the #27 base, not a #27 regression:
  `iptv_build20_test20_user_agent_widget_test.dart` "picking Custom
  reveals the custom text row and stores the choice" (line 147,
  "IPTVSmartersPro" not found — the tap never opens the dialog). It
  passes 3/3 on d937a1797 (pre-#23) and fails on the pristine #23 commit
  2643073f9 and in this worktree with the refusals tile commented out,
  so build #23 broke it (added sync-section rows above the Xtream
  section shift the scroll/tap geometry). Left as-is for the parent to
  queue; #27 does not touch the UA tile or its dialog.
- `test/screens/livetv/`: 102/102. `test/screens/video_player/`:
  277/277. Repo-wide analyze: 49 = baseline (all vendored
  wakelock_plus, zero in `lib/`/`test/`).
- Two test runs were lost to contention, not to code: the first widget
  run stalled ~15 min (the #24 tester's `flutter test` was compiling
  concurrently on this 1.5-CPU VM and starved the frontend server) and
  was killed; a later `pkill -f frontend_server_aot` matched the run's
  own compiler and killed it ("The Dart compiler exited unexpectedly"
  in that log is my own pkill, not a code failure). No `pkill -f` with
  a pattern matching the run itself after that; kills by PID only.

## Version

- pubspec 1.0.8-2.25.0+180, changelog `about.changelog2272` (2271 is
  build #24's, built in parallel off the same base).
- PENDING REBASE: build #24 (v1.0.7+179, changelog2271) ships first;
  when it lands, rebase this work onto its tip (keep both changelog
  keys, pubspec becomes 1.0.8-2.25.0+180, FORK §23 = #24, §24 = this).

## UNPROVEN (phone-only)

- A real refusal lands in the log with its cf-ray/body intact (the
  fake-panel shapes are proven; the real panel's 403 shape is not).
- The Copy text is readable/useful when Matt sends it.
