# PlezTV Build #14 — v2.25.10 (2026-11-07)

## Honest headline first

**The v2.25.9 startup crash was NOT reproduced in the harness, and this
build does NOT claim to fix it.** Three independent hunts — the builder
(this build), independent tester Task 1, independent tester Task 1b —
drove the startup path with Matt's migrated state (Trex + 161 disabled
initials + v2.25.8-format disk cache), with a dummy Plex server alongside
Trex, Plex-offline and network-down variants, and the bind-racing-UI race.
Zero exceptions, zero failing-first tests. Every Dart-level suspect from
the build #13 diff was exercised and passed.

What this build DOES ship is the one PROVEN bug the investigation found:
toggling a category/category-initial takes up to 2 minutes to show, because
the RefreshPacer cooldown swallows the user-initiated rebind. That is the
same symptom Matt reported on v2.25.8 ("toggling an initial doesn't turn
off the categories"), and it has a failing-first test. It rides in this
build alongside the crash-hunt evidence and the next evidence step below —
not as a crash fix.

Version: **2.25.10+167**. No keystore / applicationId / iOS bundle ID change.

## 1. The crash report

**Symptom (Matt, 2026-11-07 ~18:07 EST):** "Now the app crashes FUCKING
TEST IT BEFORE YOU SHIP IT" — v2.25.9 on his Galaxy Z Fold 7.

**When (Matt, 2026-11-07 ~18:35 EST):** "Right after the app loads and
the whole UI starts to come in." A STARTUP crash, during the initial
library/UI load, before he taps anything.

**Key lead (same message):** "I also have it connected to a Plex server
so maybe test it with a dummy Plex server." His HOME PC Plex server is
connected alongside Trex. All earlier harnesses were IPTV-only.

## 2. The crash hunt — three attempts, all negative

### Builder hunt (this build, worktree at 75c94dbcf + uncommitted #14 work)

- **Migration harness**
  `test/services/iptv/iptv_build14_migration_test.dart` — plain `test()`,
  real async. Seeds v2.25.8-format disk cache files via the real
  `IptvCatalogDiskCache` (temp dir via `debugDirectoryProvider`; stale
  variant backdates mtimes 25h). Trex connection with 161 generated hidden
  initials (EN NOT hidden) and categories all ON. Fake panel reproducing
  HIS panel shape: unfiltered get_vod_streams returns [] (VOD loads by
  per-category crawl); unfiltered get_series returns rows while per-category
  get_series returns [] (g-shape); unfiltered live returns rows; 150 EN
  categories + AR/buried/bracket/lowercase forms per section; sets
  `last*Body` on unfiltered calls so the raw-body disk-write path is
  exercised. Four tests: fresh v2.25.8 cache cold-start flow; stale cache
  background refresh + crawl; toggle an initial + rebind, then clear cache
  and reload; v2.25.9 raw-body files re-parse on a second client (second
  launch). **4/4 PASS.**
- **Startup unit test**
  `test/services/iptv/iptv_build14_startup_test.dart` — plain `test()`,
  real async. Dummy Plex client (serverId `plex-home-pc`, serverName
  `HOME PC`, backend plex, `ServerCapabilities.plex`, libraries
  Movies/TV Shows/Music, `fetchGlobalHubs` → Recommended + Recently
  Added, `fetchContinueWatching` → 1 item) registered FIRST via
  `manager.debugRegisterClientForTesting`, then Trex via the real
  `addIptvConnection` with migrated state; drives
  `LibrariesProvider.loadLibraries()` + `DiscoverProvider.load()`.
  **2/2 PASS** — libraries merge Plex + Trex; Discover load completes
  with hubs from both; Trex hubs carry size=1500 with items≤20 (the
  build #13 shape).
- **Libraries widget test**
  `test/screens/libraries/iptv_build14_startup_libraries_test.dart`
  (testWidgets, phone 360×800 + tablet 1280×800,
  `IptvCatalogDiskCache.debugDisableDisk = true`) — real Libraries screen
  via the build #13 harness pattern. **4/4 PASS** (plex-first, trex-first,
  tablet width, + the cooldown test in §3).
- **Discover widget test**
  `test/screens/iptv_build14_startup_discover_test.dart` (testWidgets,
  phone 360×800) — real Discover screen with the full provider stack
  (AppDatabase.memory, fake profile/connection registries, PlexHomeService,
  ActiveProfileProvider, DiscoverProvider, WatchTogether,
  CompanionRemote). **1/1 PASS.**
- **Code review of the build #13 diff** found no crash by reading either:
  all new async paths fail-open or are caught; parsers are null-safe
  (`as String?` + `?? ''`, `parseFlexibleJsonList` skips bad rows — the
  old `.map(X.fromJson)` that threw the whole list away is gone).

### Independent tester Task 1 (own worktree at 75c94dbcf)

Migrated state: full 161-entry legacy disabled-initials list, realistic
Trex category names, v2.25.8-format disk cache files, network down.
Crash-repro tests **6/6 unit + 4/4 widget pass**, full services/iptv
**174/174**. Code review of the build #13 diff: no crash found.

### Independent tester Task 1b (own worktree at 75c94dbcf)

Startup shape: HOME PC Plex + Trex, migrated state, library aggregation
across both servers, hubs, on-deck, Libraries/Search/Live TV screens at
Fold 7 cover width, Plex-offline and network-down variants, the
bind-racing-UI-load race. **7/7 unit + 4/4 widget, zero exceptions.**
Harness corrections from its report (its test expectations were wrong, not
the app): an offline server contributes no libraries by design
(`visibleOnlineClients` filters by health) — the client is still bound
and serves hubs from disk; the app bar shows only the selected library,
others live in the dropdown; `debugRegisterClientForTesting` does not emit
status — the provider load only starts after `debugEmitStatusForTesting()`;
the fake needed `authenticationSessionId` + `searchPeople`; the guide
needs `initializeDateFormatting('en')` + SettingsService init, and never
settles under `pumpAndSettle` when EPG fails (frame-scheduling loop —
bounded pumps instead).

### What is still untested (harness-blind spots)

- **Explore screen** — IndexedStack-mounted at startup like the rest, but
  it loads from `CatalogSourcesProvider` (Trakt/MAL/AniList/Plex catalog
  sources), never touches the IPTV/Plex media-server clients, and build
  #13 did not touch it. Not a build #13 crash lead.
- **The real app startup sequence** — `main()` → auth → bindings → home
  shell with ALL tabs IndexedStack-mounted at once. The harness drives
  screens one at a time; pumping the real `MainScreen` with the full
  provider stack was beyond harness reach in this session.
- **Real SharedPreferences migration on the phone** — the harness seeds
  prefs via `resetSharedPreferencesForTest()` + the v2.25.8 cache files;
  the phone migrates the real prefs store written by v2.25.8's real
  Flutter build.
- **The native mpv player** — the harness never constructs a real
  `Player`; the build #13 `hasRenderedFrame` change touches the Dart
  side only, and the widget tests pass, but a native-side crash (libmpv
  init, decoder) is invisible here.
- **Real panel data at full scale** — 55,205 live channels / 199,762 VOD
  movies / 46,461 series. The fakes return well-formed rows; the real
  panel's odd rows, error pages, and truncated bodies are not in the
  harness. (Parsers are null-safe by design — see §2 — so a bad row alone
  should not throw; but a full-scale shape the fakes don't produce, e.g.
  an unexpected top-level type, is untested.)

## 3. The PROVEN fix: user-initiated rebind must bypass the RefreshPacer cooldown

**Symptom (Matt on v2.25.8, same symptom in tester Task 1):** toggling a
category initial shows nothing for up to 2 minutes.

**Mechanism (traced 2026-11-07):** user toggles a category initial →
connection upserted → `addIptvConnection` rebind →
`notifyCatalogRefreshed()` → `LibraryContentNotifier` emits
`LibraryChangeEvent` → the visible library tab's `_onLiveLibraryChange`
calls `_livePacer.schedule()` (debounce 3s, cooldown 2 min,
`lib/screens/libraries/tabs/base_library_tab.dart:333-337`) and
DiscoverProvider's `_onLibraryContentChanged` calls
`_libraryEventPacer.schedule()` (same 2-min cooldown,
`lib/providers/discover_provider.dart:110`). The tab's last committed load
called `recordLibraryContentEpoch` → `_livePacer.notePass()`, arming the
cooldown — so the toggle's refresh defers to the trailing edge, up to 2
minutes later. The guide (`lib/screens/livetv/live_tv_screen.dart:193`)
subscribes directly with a post-frame reload — NO pacer, already immediate,
no change needed.

**Fix (6 lib files, +76/−14):**

- `lib/utils/refresh_pacer.dart`: new `scheduleBypassCooldown()` —
  cancels any pending timer, sets a one-shot `_bypassCooldown` flag, arms
  the debounce timer; `_run()` skips the cooldown check once when the flag
  is set (still honors `isBlocked` → blockedRetry, flag preserved across
  retries; a later push event is paced normally).
- `lib/media/library_change_event.dart`: new `userInitiated` flag
  (default false) with doc comment.
- `lib/media/iptv_client.dart`: `notifyCatalogRefreshed({bool
  userInitiated = false})` carries the flag into the event;
  `clearCatalogCache` passes `userInitiated: true` (manual "Refresh
  playlists" — only caller is
  `lib/screens/settings/iptv_settings_screen.dart:232`). Background
  refresh landings leave it false and stay paced.
- `lib/services/multi_server_manager.dart:984`: rebind passes
  `notifyCatalogRefreshed(userInitiated: true)` — every rebind is the
  user's own action (edit/toggle/save, or profile switch via
  `active_profile_binder.dart:1209`); first bind has no oldClient and fires
  nothing.
- `lib/screens/libraries/tabs/base_library_tab.dart`:
  `_onLiveLibraryChange` branches — `event.userInitiated` →
  `_livePacer.scheduleBypassCooldown()`, else `_livePacer.schedule()`.
- `lib/providers/discover_provider.dart`: `_onLibraryContentChanged`
  branches the same way.

**Failing-first proof:** widget test "rebind with a toggled initial
refreshes promptly, not after the 2-minute cooldown" in
`test/screens/libraries/iptv_build14_startup_libraries_test.dart` — bind
Trex, Browse shows 'Alpha Movie', rebind with EN added to
`disabledInitials`, pump 5s of fake time (past the 3s debounce, far short
of the 2-min cooldown), expect 'Alpha Movie' gone. **With the fix: PASS.
With the lib fix stashed (`git stash push -- lib/`): FAILS** — 'Alpha
Movie' still listed after 5s. Fix restored via `git stash pop`.

**Pacer unit tests:** 4 new tests appended to
`test/utils/refresh_pacer_test.dart` (bypass runs at debounce edge despite
fresh notePass; bypass upgrades a pending trailing pass; a later push event
is paced normally; bypass still retries while blocked). **Full pacer suite:
13/13 PASS.**

## 4. Secondary finding — FIXED in this build (second pass)

**Pre-existing 40px RenderFlex overflow in the Discover app bar at 360dp**
(`lib/screens/discover_screen.dart:803`, `_buildOverlaidAppBar` —
"Discover" title + Spacer + FocusableActionBar with refresh / Watch
Together / Companion Remote actions). It painted yellow/black stripes in
a debug build but did NOT kill the app, and build #13 never touched that
file. Fixed here because it was the trivial one-line case: the title
`Text` is now wrapped in `Flexible` + `TextOverflow.ellipsis` (the same
fix shape as build #12's library-header overflow). The Discover widget
test now expects `tester.takeException()` to be null instead of
acknowledging the overflow. UI-5 in the research report.

## 5. Harness lessons (kept for future crash hunts)

- **Never wrap a test body in `runZonedGuarded` to collect zone errors:**
  inside the zone the shared_preferences method channel has no
  implementation (`MissingPluginException(No implementation found for
  method getAll on channel plugins.flutter.io/shared_preferences)`) and
  the settings init never completes, so the test hangs to timeout — a
  harness artifact, NOT the app crashing. Proven by a probe test:
  identical flow passes in ~3s without the zone, throws + hangs with it.
  flutter_test already fails a test on an unhandled async error, so no
  zone wrapper is needed. (Probe file deleted after use.)
- **`/tmp` is a 512 MB tmpfs** — clean stale `/tmp/flutter_tools.*`
  before big runs, and run big test files with
  `TMPDIR=~/workspace/tmp_flutter` (created 2026-11-07) so flutter_tools
  uses real disk. A big test file's compiler output can fill /tmp ("No
  space left on device" writing output.dill).
- **Never run two `flutter test` processes at once** (cache contention
  stalls both).
- **Real disk I/O hangs inside `testWidgets`' fake async zone** — follow
  the `IptvCatalogDiskCache.debugDisableDisk` precedent.

## 6. Next evidence step — DONE: the on-device crash readout is IN this build

Another guessed fix would repeat the pattern that failed: same agent
building + testing + declaring it works. What is needed is the crash
itself, from the phone — and this build now collects it:

1. **On-device crash readout (DONE):** `lib/services/last_crash_store.dart`
   — `LastCrashCatcher.install()` (wired in `main.dart` `_bootstrapApp`,
   before `runApp`) chains to the previous handlers and persists the last
   fatal Dart error + stack to `last_crash.json` under the app support
   directory (never the cache dir). `FlutterError.onError` records
   framework errors (except the known-benign `RenderFlex overflowed`
   diagnostic, which would otherwise overwrite the real record on a 360dp
   screen every launch); `PlatformDispatcher.instance.onError` records
   uncaught async errors. The message + stack are redacted with
   `LogRedactionManager` before writing (Xtream URLs carry credentials).
   All methods are total — a failed write is logged and swallowed, never
   thrown. The write is synchronous once the directory is primed at
   startup, so it lands before the dying process exits.
   Shown as a **"Last crash" row in Settings → Advanced**
   (`lib/screens/settings/last_crash_row.dart`, after the View Logs tile):
   expandable, 240px scrollable error + stack, Clear button. It reads one
   small file and does not depend on the IPTV/Plex clients, so it is
   reachable even when the app is otherwise unstable.
   **Abnormal-exit flag (research D-6, also in):** `markLaunched()` writes
   `last_exit_state.txt` = 'running' at startup;
   `_AppExitObserver` (in `main.dart`) writes 'clean' on engine detach.
   A crash / force-stop / OS kill never reaches detach, so the next launch
   finds 'running' and the row says "The app did not shut down cleanly
   last time, and no Dart error was recorded" — the signature of a native
   (mpv) crash. When nothing was recorded AND the exit was clean, the row
   says so plainly ("No Dart error recorded — if the app still crashed,
   the crash is outside Dart code").
   **How Matt uses it:** if v2.25.10 crashes again, relaunch the app,
   open Settings → Advanced → "Last crash", and screenshot the row. A
   Dart error + stack names the site; an abnormal-exit note with no Dart
   error proves native; a clean "no error recorded" with no abnormal
   flag means the previous run exited normally and the crash report needs
   re-checking.
2. **Ask Matt:** does it crash on EVERY launch, or sometimes? Does the app
   window appear at all before it dies, or does it die on the splash? Does
   it crash with the Plex server unreachable (HOME PC off) vs reachable?
   Any "app keeps stopping" dialog vs a silent return to the home screen?
3. **Do not ship another build as "the crash fix"** until a failing-first
   test reproduces the crash with migrated state — per the SEPARATE TESTER
   RULE, a separate independent testing agent must verify any future crash
   fix in its own worktree before anything ships.

## 7. Phone verification (v2.25.10)

1. Install over v2.25.9 (or fresh install if over-the-top fails — cert is
   the same fixed debug keystore, but install-over-the-top has failed
   before despite a cert match; fresh download + free-space check first).
2. Toggle a category initial OFF in IPTV settings → the category must
   disappear from Browse/guide/search within ~3 seconds, not up to 2
   minutes. Same for toggling it back ON, and for "Refresh playlists".
3. Report whether v2.25.9's startup crash still happens on v2.25.10, and
   if so, exactly what is on screen when it dies (splash? UI half-drawn?)
   and whether it is every launch.
4. **If it crashes again: relaunch, Settings → Advanced → "Last crash",
   screenshot the row.** A Dart error + stack names the site; "did not
   shut down cleanly" with no Dart error points at native (mpv); "No Dart
   error recorded" with a clean exit means the previous run ended
   normally. Clear the row after screenshotting it.
5. IPTV settings → "Series catalog" → expand it: the **"Last search"**
   readout must show straight away (last query + per-section lines) even
   while the series check is still spinning below it.
6. The Discover app-bar overflow stripes at 360dp are FIXED in this build
   — the Discover header must no longer overflow on the cover screen.

## 8. Tests + analyze

- Builder: migration 4/4, startup unit 2/2, Libraries widget 4/4
  (incl. cooldown failing-first), Discover widget 1/1, pacer unit 13/13.
- Tester Task 1: 6/6 unit + 4/4 widget, services/iptv 174/174.
- Tester Task 1b: 7/7 unit + 4/4 widget.
- Second pass (crash readout + research fold-ins), all failing-first
  where a behaviour is asserted (each new test was run with its lib fix
  stashed and failed, then passed with it):
  - `test/services/last_crash_store_test.dart` **11/11** (record round-trip,
    overwrite, clear, corrupt file, credential redaction, catcher records
    through both handlers + calls the previous handler, overflow does not
    overwrite the record, abnormal-exit flag: first launch clean, second
    launch without a clean exit flags abnormal, clean exit clears it,
    reset clears it). One inherited compile error fixed in the file
    itself: the saved `FlutterError.onError` handler was declared as
    returning `FlutterErrorDetails` — it returns `void`.
  - `test/screens/settings/last_crash_row_test.dart` **3/3** (recorded
    crash shows headline + details, Clear removes it; abnormal exit with
    no record shows the abnormal text; clean previous exit reads "no Dart
    error recorded"). Disk reads in the row use the `runAsync` real-delay
    + pump loop (same pattern as the guide EPG tests).
  - `test/screens/settings/settings_screen_test.dart` **26 pass, 3 skipped**
    (skips pre-existing), incl. the new integration test: the Advanced
    section shows the Last crash row with no record.
  - `test/services/data_aggregation_bridge_test.dart` **41/41** (was 12
    failing on pristine HEAD — SA-12: the `_LibrariesClient` fake now
    implements the `backend` getter as `MediaBackend.plex`).
  - `test/services/iptv/iptv_catalog_cache_test.dart` **22/22**, incl. the
    new SA-4 group: a stale VOD refresh emits `liveCatalogChanged=false`,
    a stale live refresh emits `true`.
  - `test/screens/livetv/live_tv_screen_test.dart` **14/14**, incl. the
    new SA-4 tests: a VOD-only event does not reload the guide, a live
    one does, an event for another server does not. Harness note: the
    guide reload is deferred to a post-frame callback, which does not
    schedule a frame — and `tester.pump()` is a no-op without a scheduled
    frame — so the tests call `tester.binding.scheduleFrame()` before
    pumping (found by instrumenting the listener: it fired, the callback
    only ran at tearDown with `mounted=false`).
  - `test/screens/iptv/iptv_screens_test.dart` **18/18**, incl. the new
    UI-2 test: "Last search" shows while the series probe is still
    running (fake API hangs the unfiltered `getSeries`; the test advances
    the clock 11s at the end so the probe's 10s timeouts fire and no
    timer is left pending at teardown). Found while writing it: the
    diagnostics record stores the query lower-cased (`needle`).
- Touched suites re-run for this build: services/iptv **176/176**
  (first run: 1 fail — the build #13 browse benchmark's Movies hub test,
  load flake under suite load; passes standalone 2/2 and on the full
  re-run), screens/iptv **18/18**, screens/libraries **131/131**,
  screens/livetv **78/78**, test/mpv/ + pacer + crash-store + bridge
  **251/251** combined, search screen + startup discover **31/31**,
  settings row + settings screen **26 pass, 3 skipped**.
- `flutter analyze`: **49 issues — the wakelock baseline, zero in build
  #14 files.**

## 9. Files changed

- `lib/utils/refresh_pacer.dart` (`scheduleBypassCooldown`),
  `lib/media/library_change_event.dart` (`userInitiated` flag +
  `liveCatalogChanged` flag, default true),
  `lib/media/iptv_client.dart` (`notifyCatalogRefreshed(userInitiated:,
  liveCatalogChanged:)`, dataset-derived flag in
  `_refreshCatalogInBackground`),
  `lib/services/multi_server_manager.dart` (rebind passes
  `userInitiated: true`), `lib/screens/libraries/tabs/base_library_tab.dart`
  (branch in `_onLiveLibraryChange`),
  `lib/providers/discover_provider.dart` (branch in
  `_onLibraryContentChanged`),
  `lib/screens/livetv/live_tv_screen.dart` (guide ignores
  VOD/series-only events),
  `lib/screens/discover_screen.dart` (title `Flexible` + ellipsis —
  overflow fix).
- Crash readout: `lib/services/last_crash_store.dart` (new),
  `lib/screens/settings/last_crash_row.dart` (new),
  `lib/screens/settings/settings_screen.dart` (row in Advanced section),
  `lib/main.dart` (`LastCrashCatcher.install()` + `prime()` +
  `markLaunched()` + `_AppExitObserver`).
- UI-2: `lib/screens/settings/iptv_settings_screen.dart` ("Last search"
  renders synchronously from the bound client's in-memory getter, above
  the probe-gated diagnostics).
- `pubspec.yaml` (version `2.25.10+167`), `lib/i18n/en.i18n.json` +
  generated `strings*.g.dart` (`changelog2260` now 6 bullets, incl.
  crash readout + abnormal-exit flag + Last search + Discover overflow),
  `lib/screens/settings/about_screen.dart` (changelog entry first).
- New tests: `test/services/iptv/iptv_build14_migration_test.dart` (4),
  `test/services/iptv/iptv_build14_startup_test.dart` (2),
  `test/screens/libraries/iptv_build14_startup_libraries_test.dart` (4),
  `test/screens/iptv_build14_startup_discover_test.dart` (1),
  `test/services/last_crash_store_test.dart` (11),
  `test/screens/settings/last_crash_row_test.dart` (3).
- Modified tests: `test/utils/refresh_pacer_test.dart` (+4),
  `test/services/data_aggregation_bridge_test.dart` (fake gains `backend`),
  `test/services/iptv/iptv_catalog_cache_test.dart` (SA-4 group, +2),
  `test/screens/livetv/live_tv_screen_test.dart` (SA-4 tests, +2, fake
  gains `fetchChannelsCalls`),
  `test/screens/iptv/iptv_screens_test.dart` (UI-2 test, +1, fake gains
  `hangUnfilteredSeries`),
  `test/screens/settings/settings_screen_test.dart` (Last crash row
  integration test, +1).
- This file: `IPTV_BUILD14_NOTES.md`.

## 10. Research fold-ins (RESEARCH_BUILD14.md, 2026-11-07)

The research agent's verdict: **keep the fork, do NOT rewrite** — the IPTV
layer is cleanly separated behind `MediaServerClient`, the bugs are
ordinary and local, TVmagic v0.2.0 (no import/EPG/VOD/playback yet) is not
a shortcut. Its adversarial self-audit also did NOT find the v2.25.9
startup crash in our code. One brief premise was WRONG and is corrected
here: the IndexedStack does NOT eagerly mount all tabs at startup —
`_mountedTabs` starts with only the current tab
(`main_screen.dart:446,558,1200`); startup cost is one tab + the binder.
Do not chase eager mounting; it doesn't exist.

Folded into #14 (small, startup-visible, per the report's §7 table):

- **(a) Abnormal-exit flag (D-6)** — §6 above. The Dart catcher alone
  cannot see a native mpv crash; the flag distinguishes "no Dart error
  recorded + abnormal exit" (native) from "no Dart error + clean exit".
- **(b) UI-2 — "Last search" renders synchronously** — §9 above. It was
  gated behind the series probe (up to ~40s, "No search yet" if the probe
  failed); now it reads `client.lastSearchDiagnostics` on build, above
  the probe section, which keeps its own spinner.
- **(c) UI-5 — Discover 40px overflow** — §4 above, fixed (one-line
  layout change + test).
- **(d) SA-12 — 12 red bridge tests** — fixed: the `_LibrariesClient`
  fake implements `backend` (`MediaBackend.plex`). Zero-red-on-HEAD is
  now the rule: a red suite trains everyone to ignore red, which is how
  a real regression ships.
- **(e) SA-4 partial — guide ignores VOD/series-only events** — the
  background refresh now carries `liveCatalogChanged` on the event
  (live rows / live categories → true; VOD / series rows / categories →
  false; clear / rebind / M3U → true by default) and the guide returns
  early on false. Full coalescing (a 1–2s trailing-edge timer / pacer
  for the guide) stays in #15.

Deliberately LEFT for build #15 (per the report, not expanded here):
E-1 warm-up staggering, SA-5 filtered-row memoization, SA-6 row-level
`fetchMoreHubItems`, SA-3 + SA-8 live crawl + partial rows, SA-7 search
abort, SA-1 live-tap loading state, UI-1 browse timeout + retry, UI-3
filtered empty state, D-1 startup smoke harness, D-2 benchmark gates.
Build #16: fork re-seating (`guide_tab.dart` delegate, updater dialog
renders service state), SA-2 `(rows, body)` return, SA-10 diagnostics
probe bound, SA-9 pacer flag hardening, UI-4 live scope chip/note, UI-7
mini-player switching state. Form-factor integration after #16.
