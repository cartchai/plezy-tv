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

## 4. Secondary finding (NOT fixed — out of scope, parent decides)

**Pre-existing 40px RenderFlex overflow in the Discover app bar at 360dp**
(`lib/screens/discover_screen.dart:803`, `_buildOverlaidAppBar` —
"Discover" title + Spacer + FocusableActionBar with refresh / Watch
Together / Companion Remote actions). It paints yellow/black stripes in a
debug build but does NOT kill the app, and build #13 never touched that
file. The Discover widget test acknowledges exactly that error via
`tester.takeException()` + `contains('overflowed')` so it still fails on
any OTHER exception. Do NOT fix it in build #14 — it is a layout bug, not
the crash, and the parent decides whether it rides in a later build.

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

## 6. Next evidence step — what would actually find this crash

Another guessed fix would repeat the pattern that failed: same agent
building + testing + declaring it works. What is needed is the crash
itself, from the phone:

1. **On-device crash readout (recommended):** add a fatal-error catcher
   (`FlutterError.onError` + `PlatformDispatcher.instance.onError`) that
   persists the last fatal Dart error + stack to disk and shows it in
   Settings (or IPTV settings) on the next launch, so Matt can screenshot
   the actual exception instead of describing the crash. If the crash is
   native (mpv/libmpv), a Dart catcher will show nothing — that negative
   result itself narrows it to native.
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
4. The Discover app-bar overflow stripes at 360dp are a known pre-existing
   debug-build artifact, not the crash — report them separately if seen.

## 8. Tests + analyze

- Builder: migration 4/4, startup unit 2/2, Libraries widget 4/4
  (incl. cooldown failing-first), Discover widget 1/1, pacer unit 13/13.
- Tester Task 1: 6/6 unit + 4/4 widget, services/iptv 174/174.
- Tester Task 1b: 7/7 unit + 4/4 widget.
- Touched suites re-run for this build: services/iptv, screens/iptv,
  screens/libraries, screens/livetv, mpv, utils/refresh_pacer_test,
  screens/iptv_build13_search_screen_test — combined run **599 pass, 2
  fail, both explained, neither a regression**: (1) `test/screens/mpv`
  does not exist — a bad path in the invocation (the mpv tests live in
  `test/mpv/` and passed inside the run); (2) the build #13 cache
  benchmark's first-launch test failed in its own teardown
  (`FileSystemException: Directory not empty` deleting its temp dir — an
  async disk write still in flight under suite load). Re-run alone:
  **6/6 pass** (first launch wall 170ms / maxTickGap 172ms; second launch
  1066ms / 113ms, 0 network calls). My diff does not touch the cache
  write path; this is a pre-existing teardown race flake under load, not
  a build #14 regression.
- `flutter analyze`: **49 issues — the wakelock baseline, zero in build
  #14 files.**

## 9. Files changed

- `lib/utils/refresh_pacer.dart` (`scheduleBypassCooldown`),
  `lib/media/library_change_event.dart` (`userInitiated` flag),
  `lib/media/iptv_client.dart` (`notifyCatalogRefreshed(userInitiated:)`),
  `lib/services/multi_server_manager.dart` (rebind passes
  `userInitiated: true`), `lib/screens/libraries/tabs/base_library_tab.dart`
  (branch in `_onLiveLibraryChange`),
  `lib/providers/discover_provider.dart` (branch in
  `_onLibraryContentChanged`).
- `pubspec.yaml` (version `2.25.10+167`), `lib/i18n/en.i18n.json` +
  generated `strings*.g.dart` (`changelog2260`),
  `lib/screens/settings/about_screen.dart` (changelog entry first).
- New tests: `test/services/iptv/iptv_build14_migration_test.dart` (4),
  `test/services/iptv/iptv_build14_startup_test.dart` (2),
  `test/screens/libraries/iptv_build14_startup_libraries_test.dart` (4),
  `test/screens/iptv_build14_startup_discover_test.dart` (1).
- Modified tests: `test/utils/refresh_pacer_test.dart` (+4).
- This file: `IPTV_BUILD14_NOTES.md`.
