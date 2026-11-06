# PlezTV — build #5 audit + fixes (IPTV_FIXES2)

Date: 2026-11-06. Working tree only — NOT committed, NOT pushed, NOT built.
Base: `fb4cece1e` (build #4). Target version: **2.25.1+158**, deliverable
**`PlezTV v2.25.1.apk`**. App name is now **PlezTV** (Matt, 2026-11-06 ~01:06 EST;
supersedes "Plezy TV").

## 0. The primary cause of "nothing changed" — STALE INSTALL (confirmed)

Matt's screenshots (2026-11-06 ~01:00 EST) settle it:

- His **Settings → Connections** shows Add connection / Profiles / Account
  preferences — **no "IPTV" row**. Build #4's code adds that row
  (`lib/screens/settings/settings_screen.dart`, IPTV row gated on the new
  `IptvSettingsScreen`), so **build #4 is NOT running on his phone**.
- His **Add connection** screen DOES show "Connect to M3U" and "Connect to
  Xtream Codes" — build #3's Stage 3 UI — confirming **build #3 is installed**
  and its import UI works.
- His About screen says "Plezy" Version 2.25.0 with the orange logo — not
  diagnostic on its own (both builds are 2.25.0; About name/logo come from
  bundled assets).

**Root cause:** build #3 and build #4 share **versionCode 157 +
versionName 2.25.0** (`pubspec.yaml:4` was `2.25.0+157` in both). Android
treats the new APK as the same version, so his phone kept the old build when
he installed the new file. The delivered build #4 APK itself was verified to
contain the fixes (its `assets/flutter_assets/kernel_blob.bin` contains
`Show catch-up badge`, `No channels loaded from`, `All sources`,
`Refresh playlists`, `iptvShowCatchUpBadge`, class `IptvSettingsScreen`,
`liveTvServerName`) — the code shipped; it just never landed on his phone.

**Fix (this build):** `pubspec.yaml:4` → `version: 2.25.1+158`. The version
flows via `flutter.versionCode` / `flutter.versionName` in
`android/app/build.gradle.kts:307-308` (no hardcoded version anywhere else),
so the built APK must report **versionName 2.25.1 / versionCode 158**.
`lib/main.dart` ~1093 log string changed `'Plezy TV v...'` →
`'PlezTV v${packageInfo.version}+${packageInfo.buildNumber}...'`.
**Rule going forward (Matt's test-before-ship rule): every build bumps
versionCode/versionName, and every build is proven with real screen tests
before it ships.**

## 1. Audit — "Trex — Live TV" still in Libraries

**How Libraries gets its list:** `LibrariesProvider`
(`lib/providers/libraries_provider.dart`) is **in-memory only** — `_libraries`
is a plain list, cleared on profile switch/logout, with **no Drift
persistence and no cache** that could hold a stale build #3 entry. The old
row **cannot survive an app restart** with build #4 code, and build #4's
`IptvClient.fetchLibraries()` returns no Live TV library (Xtream returns
Movies + Series only; M3U returns none). Conclusion: stale install (section
0) is the only consistent explanation — **not** a cache bug.

**Latent defect found anyway:** `fetchLibraries()` did two SEQUENTIAL
provider calls (`_allCategoriesDisabled(_vodCategories)` then
`_allCategoriesDisabled(_seriesCategories)`) before returning anything,
under the aggregation service's 15 s per-server deadline
(`MediaServerTimeouts.libraryListServerDeadline`,
`lib/utils/media_server_timeouts.dart:60`, enforced via
`_withinServerDeadline` in `lib/services/data_aggregation_service.dart:213,261`).
A slow provider → Trex contributes zero libraries → the whole Trex section
vanishes from Libraries (per-server failures are swallowed;
`LibrariesProvider._loadLibrariesInternal` treats a zero-success pass as
non-authoritative).

**Fix — `lib/media/iptv_client.dart`, `fetchLibraries()`:** the category
probes now run in parallel with a 5 s fail-open timeout
(`Future.wait(...).timeout(const Duration(seconds: 5), onTimeout: () => [false, false])`).
Content-level filtering in `_moviesItems` / `_seriesItems` still hides
disabled categories even when the probe fails open, so the fail-open path
can only ever show a library that its items then filter — it cannot leak a
disabled category's content.

## 2. Audit — Movies / Series don't load at all (Browse AND Recommended)

**What the tabs actually call:** Recommended tab calls
`client.fetchLibraryHubs(libraryId, libraryName, limit: defaultHubPreviewLimit=20, ...)`
(`lib/screens/libraries/tabs/library_recommended_tab.dart:197`); Browse calls
`fetchLibraryPagedContent` (`lib/screens/libraries/tabs/library_browse_tab.dart:918`).
Both tabs await the FULL catalog first: `_moviesItems()` →
`_vodStreams()` → `XtreamApi.getVodStreams()` (**199,762 rows**, one HTTP GET
+ `jsonDecode` on the **main isolate**, 60 s timeout); `_seriesList()`
(46,461 rows) likewise; `_liveStreams()` (55,205 rows) likewise. Errors
surface via `BaseLibraryTabState.runLoadTransaction` →
`localizedLoadErrorMessage` (sanitized — never carries exception text,
hostnames, or paths, so no credential leakage; timeouts map to the generic
"connection timeout" string).

**Root cause:** the classic Xtream API has NO offset/limit pagination for
these endpoints (only `category_id`, already supported in the API methods) —
a single full fetch is unavoidable — but it ran on the UI thread with a
60 s timeout, so on a phone the parse alone can jank/time out and the whole
tab fails with "Unable to load Recommended".

**Fix — `lib/services/iptv/xtream_api.dart`:** extracted `_fetchBody()` (GET +
status checks, shared by `_getJson` and the big calls); `getLiveStreams` /
`getVodStreams` / `getSeries` now fetch the raw body then parse via
`compute()` on a background isolate (top-level `_parseLiveStreams` /
`_parseVodStreams` / `_parseSeries` + `_decodeCatalogJson`, which maps
`FormatException` to the same `MediaServerHttpException` the inline path
threw); timeouts raised **60 s → 120 s**. `compute` is an established
pattern in the codebase (`lib/services/trackers/etag_cached_remote_store.dart`).

## 3. Audit — Live TV shows only HOME PC, no Trex switcher

**How `liveTvServers` is built:** `MultiServerProvider.checkLiveTvAvailability()`
(`lib/providers/multi_server_provider.dart:288`) iterates `onlineServerIds`
(visibility-filtered). For each server: Plex DVRs → one entry per DVR;
otherwise if `liveTv.isAvailable()` → one synthesized entry (dvrKey =
backend id). `IptvLiveTvSupport.isAvailable()` returns true unconditionally
(no network), so **the registration path is sound PROVIDED Trex is online +
visible** — the build #4 picker (`lib/screens/livetv/live_tv_screen.dart`
`_buildSourcePicker`, ~line 1000) renders only when `liveTvServers.length >= 2`,
and Trex registers as a second server once bound. No DVR-only gate exists.

**Residual risk (no change made):** if the bind health probe (`getUserInfo()`,
30 s timeout) fails transiently at bind, `_bindIptv`
(`lib/profiles/active_profile_binder.dart:1204`) returns not-visible and Trex
is silently absent from Live TV AND Libraries. Health re-checks exist at
`lib/main.dart:1704` and `lib/screens/main_screen.dart:1245`, so it can
recover later. Per-server channel-fetch failures in `_loadChannelsOnce` are
swallowed by the `onError` handler (logged only; error state only when ALL
servers fail). The Live TV screen reloads channels when the server set
changes (build #4 listener; provider ref saved in `initState` — `context.read`
in `dispose()` crashes, already fixed in build #4).

## 4. Screen tests — the new pre-ship bar

New file: `test/screens/iptv/iptv_screens_test.dart` — pumps the ACTUAL
screens with a fake Plex client + a REAL `IptvClient` backed by a fake
Xtream catalog (2 movies, 1 series, 2 live streams incl. one tvArchive,
categories), **no network**. Harness patterns reused from
`test/test_helpers/multi_server_fixtures.dart` (`testMultiServerProvider`,
`debugRegisterClientForTesting`), `test/test_helpers/library_tab_scaffold.dart`
(`pumpLibraryTab`, `pumpRequestFrames`),
`test/screens/libraries/libraries_screen_test.dart` (`_Harness` pattern:
`LibrariesProvider` + `HiddenLibrariesProvider` + `NoSyncRulesDownloadProvider`),
`test/screens/livetv/live_tv_screen_test.dart` (`_pumpLiveTvScreen` pattern:
`TranslationProvider` + `InputModeTracker` + `monoTheme`),
`test/screens/settings/connection_persistence_test.dart` (DB/registry pattern:
in-memory Drift via `AppDatabase.forTesting(NativeDatabase.memory())`,
`CredentialVault.resetKeyForTesting()` + protect warmup,
`registry.upsert(XtreamConnection)`).

Tests (11 total):

1. Libraries screen lists Trex Movies + Series but no Trex Live TV library
   (also asserts Plex Movies/TV Shows present). Phone viewport (420×900
   logical): the library list lives in the app-bar dropdown there, so the
   test taps the dropdown (tooltip `t.libraries.selectLibrary`) and asserts
   the menu entries. **Harness lesson:** `LibrariesProvider.initialize()`
   only stores the aggregation service — the test must drive the load itself
   (`await libraries.loadLibraries()`); and at a 1280×720 viewport the list
   lives in MainScreen's side nav, which LibrariesScreen doesn't render
   standalone. Also: `physicalSize` is in PHYSICAL pixels — 420×900 at
   ratio 2 is a 210dp-wide screen and overflows; use 840×1800 at ratio 2.
2. Movies Recommended tab loads items (Alpha/Beta Movie), no "Unable to load" text.
3. Movies Browse tab loads items (uses `pumpRequestFrames` for the debounced load).
4. Series Recommended tab loads items (Alpha Show).
5. Series Browse tab loads items.
6. Live TV picker offers HOME PC and Trex and switches channels (pumps real
   `LiveTvScreen` with both servers in `debugSetLiveTvServersForTesting`;
   taps Trex chip → only Trex News/Sports; taps HOME PC → only A&E/ABC).
   **Harness lesson:** tap the chip via `find.widgetWithText(ChoiceChip, 'Trex')`
   — bare `find.text('Trex')` is ambiguous (channel rows also show the
   server name).
7. IPTV settings screen renders the Trex connection (real `ConnectionRegistry`
   on in-memory Drift DB; asserts 'Trex', 'Xtream Codes', refresh row).
   **Harness lesson:** the screen's `StreamBuilder` over the real Drift
   `registry.watchConnections()` schedules a zero-duration stream-close
   timer on unmount, which the framework flags as a pending timer. Fixed by
   using a `_FakeConnectionRegistry` (real DB for `list()`/`upsert()`,
   `watchConnections()` overridden to `Stream.value([...])`) — the same
   pattern as `profile_detail_screen_test.dart`'s `_FakeConnectionRegistry`.
   The fake Plex client also needed `fetchLibraryHubs` / `fetchLibraryPagedContent` /
   `fetchLibraryFiltersWithValues` (empty results): without them the fake's
   `noSuchMethod` throws and the Libraries screen degrades to an error state.
8. English strings call the app PlezTV and carry the changelog (unit test on
   `await AppLocale.en.build()`).
9. About screen shows PlezTV and the changelog, newest first (widget test;
   asserts 'PlezTV', "What's new", 'Version 2.25.1', 'Version 2.25.0',
   'Blue app icon', and that the 2.25.1 heading sits above the 2.25.0 heading).
10. First-run Auth screen offers M3U and Xtream Codes and opens their add
    screens (pumps `AuthScreen(initializeServices: false)`; asserts the IPTV
    buttons sit alongside Sign in with Plex; taps Xtream → add form with
    server/username/password fields; back → taps M3U → add form with
    playlist URL field). See section 8.
11. IPTV-only local profile binds the Xtream client with no Plex anywhere
    (`test/profiles/active_profile_binder_test.dart`): a local profile whose
    only connection is Xtream binds through `_bindIptv`; asserts the client
    is registered, the server is expected, and exactly 1 server is registered
    (no Plex). `lastBindingSucceeded` is false in the test ONLY because the
    health probe cannot succeed there (see section 8). See section 8.

**Results (verified 2026-11-06):**
- `flutter test test/screens/iptv/iptv_screens_test.dart test/profiles/active_profile_binder_test.dart`
  — **51/51 PASS, 0 fail** (10 screen tests + 41 binder tests, incl. the 40
  pre-existing binder tests — no regressions). EXIT=0.
- `flutter analyze --no-pub` — **0 errors** outside the pre-existing
  `packages/wakelock_plus/` test noise (that package's tests reference
  undefined `any`/`when`/`verify`; untouched by this work).
- Affected suites (`test/services/iptv/`, `test/screens/livetv/`,
  `test/screens/libraries/`, `test/screens/settings/`): **375/377 pass** on the
  first run; the only 2 failures were `logs_screen_test.dart` expectations
  encoding the old name (`startsWith('Plezy')`, `find.textContaining('Plezy')`)
  — the log header now correctly reads 'PlezTV', so the tests were updated
  to 'PlezTV' (6 lines; the pure-function `'Plezy test device'` payload
  input deliberately left). Re-run of `test/screens/settings/`: **193/193
  PASS**. The IPTV unit, Live TV, and libraries suites passed in the combined
  run with no failures.

## 5. Rename — PlezTV (Matt, 2026-11-06 ~01:06 EST)

Applied everywhere the app name appears to the user:

- **Android launcher label:** `android/app/src/main/AndroidManifest.xml:35`
  `android:label="Plezy TV"` → `"PlezTV"`.
- **In-app strings:** `lib/i18n/en.i18n.json` — all 50 "Plezy" occurrences →
  "PlezTV" (45 app-name references incl. possessives "Plezy's" → "PlezTV's",
  "Plezy Supporter" → "PlezTV Supporter", "Quit Plezy" → "Quit PlezTV",
  "This Plezy link" → "This PlezTV link", "Activate Plezy on ${service}" →
  "Activate PlezTV on..."). The two i18n *keys* containing the old name were
  also renamed, with their Dart call sites updated:
  `addPlezyProfile` → `addPlezTVProfile`
  (`lib/screens/profile/profile_switch_screen.dart:116`),
  `quitPlezy` → `quitPlezTV` (`lib/widgets/startup_failure_view.dart:234`).
  Same key renames applied in all 21 other locale files (keys only; their
  translated *values* stay as-is — Matt uses English).
- **Other locales:** `app.title` ("Plezy" → "PlezTV") in all 22 locale files
  (brand token, safe in every language). Inflected "Plezy" mentions inside
  other languages' sentences were deliberately left (English is the tested
  locale).
- **`lib/main.dart` ~1093:** `'Plezy TV v...'` → `'PlezTV v...'`.
- **Watch Together client string** (shown in participant labels):
  `lib/watch_together/providers/watch_together_provider.dart:127`
  `'Plezy/${info.version}'` → `'PlezTV/${info.version}'`; default/fallback
  display names `_defaultName()` / `_sanitizedName()` → 'PlezTV' (lines 74,
  722–727).
- **Profile fallback name:** `lib/navigation/profile_session_screen.dart:279`
  `?? 'Plezy'` → `?? 'PlezTV'`.
- **Regenerated:** `dart run slang` (all `strings_*.g.dart` updated).
- **About screen:** title comes from `t.app.title` → "PlezTV"; version from
  `t.about.versionLabel(version: packageInfo.version)` → "Version 2.25.1"
  after the bump. About logo is the bundled `assets/plezy.png` (see section 6).

**Deliberately left (not user-visible in-app):**

- Dart package name `plezy` + `package:plezy/...` imports (changing = ~1,000 edits).
- `com.edde746.plezy.libass` internal package + its JNI names.
- `plezy://` deep-link scheme; Android package id `com.matt.plezytv`
  (data must carry over); GitHub repo `cartchai/plezy-tv`; Codemagic app name.
- `MethodChannel('com.plezy/theme')` in `lib/main.dart` (internal channel name).
- `PlezyActivity` / `PlezyWidgetsBinding` class names (internal).
- Code comments mentioning Plezy.
- Wire-protocol client identifiers sent to servers (not shown in our UI):
  `X-Plex-Product` / `X-Plex-Device-Name` (`lib/services/plex_client.dart:814-815`,
  `lib/services/plex_discover_client.dart:350`, `lib/services/plex_auth_service.dart:54`
  `_appName`), Jellyfin client name (`lib/models/jellyfin/jellyfin_display_preferences.dart:23`,
  `lib/services/jellyfin_auth_header.dart:31,54,70`,
  `lib/services/jellyfin_client/parts/playback.dart:912`),
  `User-Agent: 'Plezy'` (`lib/utils/media_image_helper.dart:428`).
  Follow-up candidate: rename these too if Matt wants Plex's authorized-devices
  list to show "PlezTV" instead of "Plezy".
- Upstream attribution: github.com/edde746/plezy links and "based on Plezy"
  credit stay as-is — including the one remaining "Plezy" in
  `lib/i18n/en.i18n.json` (v2.25.0 changelog bullet: "First PlezTV release,
  based on Plezy 2.25.0").
- Asset filenames `assets/plezy.png` / `assets/plezy_adaptive_foreground.svg`
  (filenames only; contents recolored — see section 6).

## 6. Blue icon (Matt: "I told you to make the icon blue")

Wood is gone. Default adaptive launcher icon, same play-mark shape:

- `android/app/src/main/res/values/colors.xml`:
  `ic_launcher_background` #6B4423 (dark wood) → **#0A1931** (deep navy).
- `android/app/src/main/res/drawable/ic_launcher_foreground.xml`: gradient
  #FFE8C39E → #FFC08A4E → **#FFA8D8FF → #FF0A84FF** (light sky blue → strong
  blue, the app accent).
- Monochrome drawable is white #FFFFFFFF — left alone.
- `splash_icon.xml` uses `@drawable/ic_launcher_foreground` — covered by the
  recolor.
- **24 alternate icons untouched** (picker options).
- **About/auth logo is a bundled asset, not the launcher icon:**
  `assets/plezy.png` (1024×1024, used on About at 80×80 and on the auth
  screen at 120×120 twice) — recolored in place by a +190° HSV hue shift
  (orange ~20° → blue ~210°), preserving saturation/value/alpha so shading
  and transparency are untouched. Verified: dominant colours are now
  (64,160,224) / (64,128,192) instead of (240,112,80) / (208,96,64).
  Original saved at `/tmp/plezy-wood.png` (ephemeral; not a deliverable).
- **Legacy raster launcher PNGs** (`mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png`)
  carried the old orange mark — same hue shift applied to all five
  (original xxxhdpi saved at `/tmp/ic_launcher-wood.png`).
- **Loading-screen logo** `assets/plezy_adaptive_foreground.svg` (shown at
  160×160 / 288×288 on the startup screen, `lib/main.dart:2526,2549`, and in
  the app-icon picker, `lib/screens/settings/app_icon_setting.dart:278`) —
  gradient stops #ff7e57 → **#A8D8FF**, #ab543a → **#0A84FF**.
- **TV banner** `android/app/src/main/res/drawable-xhdpi/tv_banner.png`
  (320×180, black background + orange play-mark) — same hue shift applied
  (trivial recolor of the same mark; original at `/tmp/tv_banner-wood.png`).
  The 24 alternate `tv_banner_*.webp` variants were NOT touched.

## 7. Changelog in the About section (Matt, 2026-11-06 ~01:07 EST)

New "What's new" section on the About screen, newest first, static in code
(no network — About works fully offline):

- **UI:** `lib/screens/settings/about_screen.dart` — `SettingsGroup`
  (title `t.about.changelogTitle`) with `_ChangelogEntry` widgets (version
  heading via `t.about.versionLabel`, bullet list). Sits between the app
  description and the Open Source Licenses row.
- **Strings:** `lib/i18n/en.i18n.json` `about` block — `changelogTitle`
  ("What's new"), `changelog2251` (8 bullets), `changelog2250` (4 bullets);
  generated as `List<String>` by slang (`lib/i18n/strings_en.g.dart:3587+`).
  Other locales fall back to English for these keys (established slang
  behaviour).
- **v2.25.1 entries** (adjusted to what this build actually ships): PlezTV
  name throughout the app; Blue app icon; Add IPTV on first start — no Plex
  needed; Movies and Series Recommended now
  loads; "Trex — Live TV" removed from Libraries — live TV only lives in
  Live TV; Live TV source picker: All sources, HOME PC, Trex; New IPTV
  settings at Settings → Connections → IPTV: connections, turn categories
  on/off, Show all / Hide all, Refresh playlists, Show catch-up badge;
  Catch-up badge on guide channels for channels that support it; M3U category
  filter now works in Live TV and search.
- **v2.25.0 entries:** First PlezTV release, based on Plezy 2.25.0; M3U and
  Xtream Codes import: Add connection → M3U / Xtream Codes; Live TV from IPTV
  in the Live TV section; movies and series in the Library; Country/region
  filter on each connection's edit screen.

## 8. First-run IPTV onboarding (Matt, 2026-11-06 ~01:26 EST)

**Finding:** on a fresh install the Setup screen routes to `AuthScreen`
(`lib/main.dart`, `allConnections.isEmpty` → `AuthScreen`), and that screen
offered ONLY Plex (Sign in / QR / browser), Jellyfin, and Emby — no M3U,
no Xtream Codes. The app looked Plex-reliant at first start even though
everything downstream already supported IPTV-only.

**What was already wired (no change needed):**
- `persistAndExitIptvConnection`
  (`lib/screens/settings/iptv_connection_persistence.dart`) already creates
  a first-run local profile named after the connection and binds the IPTV
  connection to it (`persistAndBindConnection` activates it).
- The binder already routes IPTV connections through `_bindIptv`
  (`lib/profiles/active_profile_binder.dart:1204,662`), which registers the
  client via `addIptvConnection` and marks the server visible when the probe
  succeeds (or refused, so the banner shows).
- MainScreen has no Plex-only gate (no "No servers" Plex requirement found
  in `lib/screens/main_screen.dart`); Discover loads hubs via the
  aggregation service, which includes IPTV (`fetchGlobalHubs`, build #4).

**Change — `lib/screens/auth_screen.dart`:**
- New `_connectToIptv({required bool isM3u})`, mirroring
  `_connectToMediaBrowser`: pushes `AddM3uScreen` / `AddXtreamScreen`
  (both accept a null `targetProfile` — first-run profile creation handles
  it), and on success (`pop(true)`) navigates to `ProfileSessionScreen`,
  exactly like the Jellyfin path.
- Two new buttons after Emby, same style/order as the Add connection screen:
  "Connect to M3U" (`t.addServer.connectToM3uCard`, `BackendBadge` m3u) and
  "Connect to Xtream Codes" (`t.addServer.connectToXtreamCard`, `BackendBadge`
  xtream). No new i18n keys needed — the Add connection screen's keys were
  reused. The buttons sit outside the TV-only branch, so they show on TV too.

**Known behaviour (pre-existing, not changed):** if the IPTV health probe
fails at startup (e.g. slow network on first launch), the binder reports the
bind unsuccessful and, with no servers online, Setup routes to the offline
shell (`shouldEnterOfflineModeAfterStartupBind`, `lib/main.dart:2389`) rather
than MainScreen — the same as a failed Plex/Jellyfin probe. Health re-checks
(`lib/main.dart:1704`, `lib/screens/main_screen.dart:1245`) can recover the
server afterwards. On a real phone with a working Trex login the probe
succeeds and the server goes visible.

**Tests:** screen test #10 (AuthScreen buttons + add screens open) and
binder test #11 (IPTV-only profile binds; see section 4). A full
pump-through from first-run Auth → filled Xtream form → Home was NOT built:
it would need the whole MainScreen provider tree plus a mocked Xtream probe
(the binder creates its own `XtreamApi` internally — no injection point —
and in tests HttpClient returns 400, so the probe can never succeed there).
The two tests together cover the entry point and the bind; the Home /
Libraries / Live TV rendering for an IPTV-only profile is the same code
path the other screen tests prove (they use a real `IptvClient`).

## 9. Honest gaps — what this work does NOT prove

- **Whether the 199,762-row VOD fetch succeeds on a real phone over LTE is
  UNPROVEN.** The screen tests use a 2-row fake catalog. The isolate parse +
  120 s timeout fix the known failure mode (main-isolate jank/timeout), but
  the real provider's response size/speed over mobile data is only provable
  on Matt's phone.
- **EPG is still not wired** (`IptvLiveTvSupport.fetchSchedule` returns `[]`;
  guide renders empty). Deliberately out of this build.
- **`fetchChannels` still returns the full 55k live list in one call** (paged
  variant is a bigger refactor); the UI must page it, never render 55k rows.
- **Item watch-state / item favorites still do not persist** (item
  `setFavorite` is a no-op; only live-channel favorites persist).
- **Timeshift start-time timezone is UTC** (the known disputed point —
  verify against the real provider).
- **The About screen widget test runs with an empty version** (PackageInfo
  has no platform channel in tests, so the app-version label renders blank
  there); the "Version 2.25.1" label is proven by the pubspec + build.gradle
  version flow, not by the widget test. The changelog headings use hardcoded
  version strings and are asserted directly.
- **The blue icon / About logo recolors are verified by pixel values, not by
  a phone screenshot** — Matt's phone is the final check for how the icon
  looks on the launcher.
- **Stale-install risk remains if the version is not bumped again** — the
  2.25.1+158 bump is what makes build #5 unambiguously an update over build #3.
