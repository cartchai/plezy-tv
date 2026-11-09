# PlezTV fork maintenance — keeping our changes re-appliable onto newer Plezy

This file is the map for repatching. When upstream Plezy ships a new version,
our changes must be re-applied onto it. This file lists every change we made
against the upstream base, so the rebase can be done area by area instead of
from memory.

## Upstream base

- Upstream: https://github.com/edde746/plezy
- Base: tag **2.25.0**, commit `c30493435ca98e7f521b89ecd8d096484d237c57`
  ("chore: bump version to 2.25.0")
- License: **GPL-3.0** — the fork stays GPL-3.0, keep `LICENSE` untouched.
- Our repo: https://github.com/cartchai/plezy-tv (branch `main`)
- Local clone: `~/workspace/plezy-tv/`, remote `upstream` = edde746/plezy
- Scale of the fork vs base: **413 files changed, 42310 insertions, 3291 deletions**
  (most of the churn is the rename commit sweeping Kotlin package paths;
  verified 2026-11-08 after the build #18 commit — was 412 files /
  +41,872/−3,278 at build #17).

## Branch model (researched, 2026-11-06 — see report in
`~/workspace/research_notes/git-fork-maintenance-repatch-20261106-0706/report.md`)

- `upstream-main` — pristine mirror of upstream, fast-forward only, NEVER
  commit here. (Create it with `git checkout -b upstream-main upstream/main`
  — it does not exist yet.)
- `main` — our patch stack: every custom commit, in order, on top of the
  upstream base. This is the branch users build from.
- `sync/<tag>-<date>` — disposable trial branch for a repatch. The rebase is
  done and verified here FIRST; `main` only moves once the trial is green.
- `release/<tag>-<n>` + tag `v<tag>-fork.<n>` — immutable release branches
  (e.g. `v2.26.0-fork.1`).
- `backport/upstream-<sha>-…` — cherry-picks of single upstream fixes
  between releases (`git cherry-pick -x`), merged into `main`.
- One-time git config (do it now, on the machine that does rebases):
  `git config rerere.enabled true`, `git config rerere.autoupdate true`,
  `git config merge.conflictstyle diff3`. rerere remembers how you resolved
  a conflict and replays it next time — the cache lives in `.git/rr-cache`
  and is pruned after ~60 days, so re-record resolutions each repatch.

## Our commits on top of upstream (in order)

| Commit | What it is |
|---|---|
| `845dfed7c` | Rename fork: app label "Plezy TV", applicationId + namespace `com.matt.plezytv`, Kotlin source moved `com/edde746/plezy/` → `com/matt/plezytv/`, wood icon, `codemagic.yaml` added, GitHub Actions workflows removed (`.github/workflows/` deleted — Codemagic is the builder) |
| `c6e093756` | IPTV Stage 1: `MediaBackend` gains `m3u` + `xtream`; `M3uConnection` + `XtreamConnection` (user-given name, source label, disabledCategoryIds); `assets/m3u_icon.svg`, `assets/xtream_icon.svg`; 21 non-exhaustive switch sites fixed |
| `1b14d772b` | IPTV Stage 2a: `MediaItem` gains `m3u` + `xtream` cases (+ regenerated `media_item.freezed.dart` / `media_item.g.dart`) |
| `84305fdef` | Build #1 fix: restore libass imports to `com.edde746.plezy.libass.*` (libass module was NOT renamed) |
| `0d0d33fcf` | IPTV Stage 2b: `lib/services/iptv/xtream_api.dart`, `lib/services/iptv/m3u_parser.dart`, `lib/media/iptv_client.dart`, `lib/media/iptv_live_tv.dart` + tests |
| `c128d1b06` | IPTV Stage 3: `MultiServerManager.addIptvConnection` + binder, Add-connection screen gains M3U/Xtream rows, `add_m3u_screen`, `add_xtream_screen`, `edit_iptv_connection_screen` (country/region filter), i18n keys |
| `fb4cece1e` | Build #3 bug fixes: Recommended hubs implemented, Live TV library removed, Live TV source picker, IPTV settings screen, catch-up badge, M3U category filter fix |
| `8a1974df3` | README rewrite: PlezTV vs Plezy sections, app-store links removed |
| `2e3f4897d` | About/auth logo `assets/plezy.png` recolored blue (was orange) |

Build #5 (PlezTV v2.25.1) is committed as `136491ea2`: rename Plezy → PlezTV
in-app (all 22 locales + slang regen), blue launcher icon + TV banner +
adaptive foreground, About changelog, first-start IPTV on the Auth screen,
Xtream catalog parsing moved to an isolate with 120s timeouts, parallel
library probes, version `2.25.1+158`, screen tests in `test/screens/iptv/`.
Detail: `IPTV_FIXES2_NOTES.md`.

Build #6 (PlezTV v2.25.2) is in this commit: EPG wired lazily per visible
guide channel (`IptvLiveTvSupport.fetchEpgForChannel`; `fetchSchedule`
stays `[]` deliberately), subtle 3px loading line under the guide time
navigation, Series root cause fixed (one malformed row no longer kills the
whole catalog — `parseFlexibleJsonList` in all three catalog parsers),
categories split into collapsible Live TV / Movies / TV Series sections on
the edit screen, TiviMate-modelled EPG settings (days to load, update
interval, past days, update on app start, time offset, Update now, Clear
guide, Last updated), in-app update repointed at `cartchai/plezy-tv`
(`codemagic.yaml` now passes `--dart-define=ENABLE_UPDATE_CHECK=true`),
clickable "No information available" hour blocks with catch-up where the
channel supports it, version `2.25.2+159`. Detail: `IPTV_EPG_NOTES.md`.
Honest limits: EPG cache is in-memory (update-on-start has no observable
effect until the cache is persisted); the update flow is browser-download
(no native PackageInstaller); real-provider EPG shape / timeshift UTC
still unproven — needs Matt's phone.

Build #7 (PlezTV v2.25.3) is in this commit: IPTV favourites section
(`IptvFavoritesScreen`, heart in the Libraries app bar; VOD/series
favourites now persist via `IptvItemFavoritesRepository`, key
`iptv_fav_items:<connectionId>` — `setFavorite` was a no-op before),
Collections tab replaced by the provider's Categories tab for IPTV
libraries only (`LibraryCategoriesTab`; Plex/Jellyfin/Emby keep
Collections), IPTV downloads fixed (`resolveDownload` returns the direct
stream URL instead of throwing `UnsupportedError`), EPG cache persisted
to disk (per-channel JSON under `iptv_epg/`, so update-on-start now
works), Xtream EPG now comes from the login's `xmltv.php` feed
(TiviMate-style; `getShortEpg` is the fallback), IPTV search fixed
(per-section fail-open + concurrent fetch + 60s IPTV search deadline),
Movies Browse empty fixed (per-category fallback when the unfiltered VOD
fetch returns `[]`; empty catalogs are never cached), series/movie titles
strip the category prefix when it duplicates their own category
("NF - Alice" → "Alice"), and ONE fixed debug keystore committed
(`android/app/debug.keystore`, `signingConfigs.debug` wired to it) so
every build signs with the same key — v2.25.3 will NOT install over
v2.25.1/v2.25.2, one uninstall + fresh install required, after which
updates install over the top. Version `2.25.3+160`.
Detail: `IPTV_BUILD7_NOTES.md`. Reference: `PLEZY_REFERENCE.md` (full
codebase reference + fork-vs-upstream inventory, written this round).

Build #8 (PlezTV v2.25.4) is in this commit: series search fixed
(per-section result caps — a query matching 100+ movies no longer starves
series before ranking — plus a 50s per-section budget inside the 60s leg
deadline), search results grouped into Movies / TV Shows / Live TV / other
libraries with jump chips, EPG made truthful (fetch failures now throw
instead of being cached as loaded-empty; rows show "Loading guide…" while
fetching and a tap-to-retry state on failure; `getShortEpg` runs first for
visible channels while the 55k-channel `xmltv.php` download runs in the
background), and a name-initials filter (repeating 2–3 letter prefixes
like EN / ES / NF, threshold 5, toggleable per connection in IPTV settings
and on the connection edit screen, grouped with the categories; no
language mapping, no ISO list). Version `2.25.4+161`.
Detail: `IPTV_BUILD8_NOTES.md`.

## Change inventory by area (for repatching)

### 1. Rebrand / rename
- AndroidManifest label → "PlezTV"; `applicationId` + namespace
  `com.matt.plezytv`; FileProvider `com.matt.plezytv.fileprovider`.
- Kotlin source moved to `com/matt/plezytv/` (79 main + 59 test files).
- Icon: `colors.xml` launcher background `#0A1931`, foreground gradient
  `#FFA8D8FF → #FF0A84FF` (blue; wood was superseded); 5 legacy mipmap PNGs,
  `ic_launcher_foreground.xml`, `assets/plezy.png`,
  `assets/plezy_adaptive_foreground.svg`, TV banner — all blue.
  24 alternate icons untouched.
- In-app name "PlezTV" everywhere user-visible: `lib/i18n/en.i18n.json`
  (and the other 21 locale files — keys renamed, values untouched),
  `lib/main.dart` version string, Watch Together strings, profile fallback
  name. Exactly one "Plezy" remains in `en.i18n.json` on purpose: the
  v2.25.0 changelog bullet "First PlezTV release, based on Plezy 2.25.0".
- README.md rewritten (PlezTV section + Plezy upstream section, no store links).

### 2. IPTV import (the point of the fork)
- New files: `lib/services/iptv/xtream_api.dart`,
  `lib/services/iptv/m3u_parser.dart`, `lib/media/iptv_client.dart`,
  `lib/media/iptv_live_tv.dart`,
  `lib/screens/settings/add_m3u_screen.dart`,
  `lib/screens/settings/add_xtream_screen.dart`,
  `lib/screens/settings/edit_iptv_connection_screen.dart`,
  `lib/screens/settings/iptv_connection_persistence.dart`,
  `lib/screens/settings/iptv_settings_screen.dart`,
  `assets/m3u_icon.svg`, `assets/xtream_icon.svg`.
- Touched upstream files: `lib/media/media_backend.dart`,
  `lib/connection/connection.dart`, `lib/connection/connection_registry.dart`,
  `lib/media/media_item.dart` (+ generated `.freezed.dart` / `.g.dart`),
  `lib/profiles/active_profile_binder.dart`,
  `lib/services/multi_server_manager.dart`,
  `lib/screens/settings/add_connection_screen.dart`,
  `lib/screens/profile/profile_detail_screen.dart`,
  `lib/screens/livetv/live_tv_screen.dart`,
  `lib/screens/livetv/tabs/guide_tab.dart`,
  `lib/models/livetv_channel.dart`,
  `lib/providers/multi_server_provider.dart`,
  `lib/screens/settings/settings_screen.dart`,
  `lib/services/settings_service.dart`, `lib/screens/auth_screen.dart`,
  `lib/screens/settings/about_screen.dart`, `lib/main.dart`,
  `lib/navigation/profile_session_screen.dart`,
  `lib/screens/profile/profile_switch_screen.dart`,
  `lib/watch_together/providers/watch_together_provider.dart`,
  `lib/watch_together/widgets/watch_labels.dart`,
  `lib/widgets/startup_failure_view.dart`, `pubspec.yaml`,
  `lib/i18n/en.i18n.json` (+ generated `strings*.g.dart`).
- Progress notes: `IPTV_PROGRESS.md`, `IPTV_STAGE2_NOTES.md`,
  `IPTV_STAGE3_NOTES.md`, `IPTV_FIXES_NOTES.md`, `IPTV_FIXES2_NOTES.md`.

### 3. Build infrastructure
- `codemagic.yaml` (new file): Codemagic "Android Debug" workflow,
  Flutter 3.47.9, Java 17, Mac mini M2.
- GitHub Actions workflows deleted (the PAT used for pushes lacks
  `workflow` scope, so Actions cannot be managed from the fork).
- Build #6: build command passes `--dart-define=ENABLE_UPDATE_CHECK=true`
  so the Settings → Updates section renders in shipped builds.
- Build #7: ONE fixed debug keystore committed
  (`android/app/debug.keystore`, `.gitignore` exception
  `!app/debug.keystore`) + `signingConfigs.debug` wired to it in
  `android/app/build.gradle.kts`. Every Codemagic build now signs with
  the same key (SHA-256
  `32:1A:E6:3C:35:33:C7:98:EE:7D:0A:F3:82:DE:3C:83:54:BF:62:A2:E5:EC:A8:7C:8F:D5:9D:02:A4:05:23:6F`).
  Before this, each Codemagic build generated its own fresh debug key,
  so no build installed over the previous one. Release keystores stay
  ignored; never commit one.

### 4. Build #6 — EPG, Series fix, categories, EPG settings, update, hour blocks
- New files: `lib/services/iptv/xmltv_parser.dart` (isolate-safe XMLTV
  parse), `test/services/iptv/iptv_epg_test.dart`,
  `test/screens/livetv/guide_tab_iptv_test.dart`,
  `test/screens/settings/edit_iptv_connection_screen_test.dart`,
  `test/screens/video_player/live_tv_catch_up_test.dart`.
- Touched upstream files: `lib/screens/livetv/tabs/guide_tab.dart`
  (lazy per-row EPG, loading line, hour placeholders),
  `lib/models/livetv_program.dart` (`isPlaceholder`),
  `lib/screens/livetv/program_details_sheet.dart` (catch-up from a block,
  actions in a `Wrap`), `lib/screens/video_player/live_tv_session_args.dart`
  + `parts/playback_start.dart` + `lib/utils/live_tv_player_navigation.dart`
  (catch-up start epoch), `lib/screens/settings/iptv_settings_screen.dart`
  (EPG section), `lib/services/settings_service.dart` (EPG prefs),
  `lib/services/update_service.dart` + `lib/utils/update_dialog.dart`
  (repointed at the fork, `.apk` asset pick), `lib/screens/settings/settings_screen.dart`
  ("View releases on GitHub" tile).
- Progress notes: `IPTV_EPG_NOTES.md` (also covers the honest limits:
  in-memory EPG cache, browser-download update flow, unproven provider
  details).

### 5. Build #7 — favourites, Categories tab, downloads, persisted EPG, xmltv.php EPG, search, Movies Browse, prefix strip, fixed key
- New files: `lib/services/iptv/iptv_item_favorites_repository.dart`,
  `lib/screens/iptv/iptv_favorites_screen.dart`,
  `lib/screens/libraries/tabs/library_categories_tab.dart`,
  `test/services/iptv/iptv_item_favorites_test.dart`,
  `test/services/iptv/iptv_epg_cache_test.dart`,
  `test/screens/iptv/iptv_favorites_screen_test.dart`,
  `test/screens/libraries/library_categories_tab_test.dart`,
  `android/app/debug.keystore` (fixed debug signing key — see §3).
- Touched upstream files: `lib/media/iptv_client.dart` (favourites
  persistence, `resolveDownload`, Categories support, per-section
  fail-open search, per-category catalog fallback, category-prefix
  strip), `lib/media/iptv_live_tv.dart` (persisted per-channel EPG
  cache, xmltv.php primary + `getShortEpg` fallback, per-channel
  update-on-start), `lib/models/livetv_program.dart` (`toJson`),
  `lib/screens/libraries/libraries_screen.dart` (new `categories` tab
  type, favourites heart action, tab-focus-nodes fix),
  `lib/services/data_aggregation_service.dart` (60s IPTV search
  deadline), `lib/utils/media_server_timeouts.dart`
  (`iptvSearchServerDeadline`), `lib/services/iptv/xtream_api.dart`
  (`getXmltv` timeout), `lib/screens/video_player/parts/build.dart`
  (playback-failure scroll fix), `lib/i18n/en.i18n.json` + generated
  `strings*.g.dart` (favourites keys, changelog 2.25.3),
  `lib/screens/settings/about_screen.dart` (changelog entry),
  `pubspec.yaml` (version `2.25.3+160`), `android/.gitignore`
  (keystore exception).
- Progress notes: `IPTV_BUILD7_NOTES.md`. Reference:
  `PLEZY_REFERENCE.md` (full codebase reference + fork-vs-upstream
  inventory, 295 files / +11,052/−3,045 vs base at build #6).

### 6. Build #8 — series search, search sections, truthful EPG loader, initials filter
- New files: `lib/utils/iptv_initials.dart`,
  `lib/utils/search_sections.dart`,
  `lib/widgets/iptv_initials_checklist.dart`,
  `test/utils/iptv_initials_test.dart`,
  `test/utils/search_sections_test.dart`,
  `test/widgets/iptv_initials_checklist_test.dart`.
- Touched upstream files: `lib/media/iptv_client.dart` (per-section
  search caps + budgets, `disabledInitials` filtering,
  `iptvInitials()`), `lib/media/iptv_live_tv.dart` (fetch throws on
  failure, `getShortEpg` first + xmltv in the background),
  `lib/screens/livetv/tabs/guide_tab.dart` (Loading guide… / retry
  rows), `lib/screens/search_screen.dart` (sectioned results + jump
  chips), `lib/screens/settings/edit_iptv_connection_screen.dart`
  (Name initials section),
  `lib/screens/settings/iptv_settings_screen.dart` (per-connection
  initials sections), `lib/connection/connection.dart`
  (`disabledInitials`), `lib/services/settings_service.dart`
  (initials expansion pref), `lib/i18n/en.i18n.json` + generated
  `strings*.g.dart` (changelog 2.25.4),
  `lib/screens/settings/about_screen.dart` (changelog entry),
  `pubspec.yaml` (version `2.25.4+161`).
- Progress notes: `IPTV_BUILD8_NOTES.md`.

### 7. Build #9 — series search on cold catalogs, per-library search scope, catch-up + block scrubber
- New files: `lib/utils/live_tv_scrub_block.dart`,
  `test/services/iptv/iptv_live_session_test.dart`,
  `test/utils/live_tv_scrub_block_test.dart`.
- Touched upstream files: `lib/media/iptv_client.dart` (cold-catalog
  per-category sweep returning partial matches; library scope via
  `hiddenLibraryIds`), `lib/services/iptv/xtream_api.dart`
  (`tv_archive_duration` days → seconds),
  `lib/media/iptv_live_tv.dart` (capture buffer computed at read time;
  `reportTimeline` returns the fresh buffer),
  `lib/screens/livetv/tabs/guide_tab.dart` (catch-up action for every
  started programme on a catch-up channel),
  `lib/screens/livetv/program_details_sheet.dart` (catch-up next to
  Play / Watch Channel; "Start from beginning" for live programmes),
  `lib/screens/search_screen.dart` (always-visible library scope strip),
  `lib/screens/video_player/live_tv_session_state.dart`,
  `lib/screens/video_player/parts/live_tv.dart`,
  `lib/screens/video_player/parts/build.dart`,
  `lib/screens/video_player_screen.dart` (block-bounded scrubber),
  `lib/widgets/video_controls/video_controls.dart`,
  `lib/widgets/video_controls/desktop_video_controls.dart`,
  `lib/widgets/video_controls/mobile_video_controls.dart`,
  `lib/widgets/video_controls/parts/navigation.dart`,
  `lib/widgets/video_controls/widgets/live_timeline_bar.dart`
  (visible block range), `lib/i18n/en.i18n.json` + generated
  `strings*.g.dart` (changelog 2.25.5, `startFromBeginning` string),
  `lib/screens/settings/about_screen.dart` (changelog entry),
  `pubspec.yaml` (version `2.25.5+162`).
- Progress notes: `IPTV_BUILD9_NOTES.md`.

### 8. Build #10 — in-app update download + install, category-initials redesign, series search race + warm-up + diagnostics
- New files: `lib/services/apk_update_downloader.dart`,
  `lib/services/apk_installer.dart`,
  `android/app/src/main/kotlin/com/matt/plezytv/ApkInstallChannel.kt`,
  `test/services/apk_update_downloader_test.dart`,
  `test/services/apk_installer_test.dart`,
  `test/utils/update_dialog_test.dart`,
  `test/services/iptv/iptv_category_initials_test.dart`.
- Touched upstream files: `lib/utils/update_dialog.dart` (rewritten —
  was the browser-download dialog), `lib/media/iptv_client.dart`
  (category-initial filter replacing the name filter; search races the
  unfiltered catalog against the per-category sweep; `warmUpSeriesCatalog`;
  `seriesCatalogDiagnostics`), `lib/utils/iptv_initials.dart`
  (`categoryInitial` / `countCategoryInitials`; `detectInitial` /
  `initialOf` / `countInitials` deleted),
  `lib/services/multi_server_manager.dart` (warm-up call in
  `addIptvConnection`), `lib/services/update_service.dart`
  (`apkAssetSize`), `lib/screens/settings/iptv_settings_screen.dart`
  ("Category initials" rename + series catalog diagnostics widget),
  `lib/screens/settings/edit_iptv_connection_screen.dart`
  ("Category initials" rename),
  `lib/widgets/iptv_initials_checklist.dart` (doc comment; the sort
  itself was already alphabetical),
  `lib/connection/connection.dart` (`disabledInitials` doc — same
  storage, new meaning), `android/app/src/main/AndroidManifest.xml`
  (`REQUEST_INSTALL_PACKAGES`),
  `android/app/src/main/kotlin/com/matt/plezytv/PlezyActivity.kt`
  (installer channel attach), `lib/i18n/en.i18n.json` + generated
  `strings*.g.dart` (updater + diagnostics strings; v2.25.4 changelog
  line untouched — historical), `pubspec.yaml` (version `2.25.6+163`,
  set by the parent at commit time).
- Progress notes: `IPTV_BUILD10_NOTES.md` (redesign + search +
  diagnostics), `IPTV_UPDATER_NOTES.md` (updater part),
  `IPTV_BUILD10_DIAGNOSIS.md` (diagnosis; its (h) fix is superseded
  by the redesign — note at the top of the doc).

### 9. Build #11 — IPTV catalog disk cache (v2.25.7)
- New files: `lib/services/iptv/iptv_catalog_cache.dart`
  (`IptvCatalogDiskCache` — documents dir, per-connection datasets,
  TTL, total methods), `test/services/iptv/iptv_catalog_cache_test.dart`
  (20 tests).
- Touched upstream files: `lib/services/iptv/xtream_api.dart`
  (`toJson` on the four catalog models + public parse helpers),
  `lib/media/iptv_client.dart` (disk-first loaders for live/VOD/series/
  all three category lists/M3U playlist, generic background refresh,
  `_catalogGeneration` guard, `_liveCategories()`,
  `clearCatalogCache` rewrite — also the manual-refresh affordance via
  IPTV settings "Refresh playlists"), `lib/i18n/en.i18n.json` +
  generated `strings*.g.dart` (`changelog2257`),
  `lib/screens/settings/about_screen.dart` (changelog entry first),
  `pubspec.yaml` (version `2.25.7+164`).
- Touched test files: `test/services/iptv/iptv_epg_cache_test.dart`
  (tearDown retries the recursive delete — a fire-and-forget EPG write
  landing mid-delete made it flaky); the six widget-test files that
  build real `IptvClient`s now set
  `IptvCatalogDiskCache.debugDisableDisk = true` in setUp (the disk
  cache's real dart:io never completes in `testWidgets`' fake async
  zone — same reason the favourites repo has an in-memory stand-in):
  `test/screens/livetv/guide_tab_iptv_test.dart`,
  `test/screens/iptv/iptv_screens_test.dart`,
  `test/screens/libraries/library_categories_tab_test.dart`,
  `test/screens/iptv/iptv_favorites_screen_test.dart`,
  `test/widgets/iptv_initials_checklist_test.dart`,
  `test/screens/settings/edit_iptv_connection_screen_test.dart`.
- NOT touched: EPG caching (build #7) except reusing its patterns;
  the build #10 search race, warm-up and diagnostics row; image loading
  (posters/artwork deliberately NOT cached — Matt's call).
- Progress notes: `IPTV_BUILD11_NOTES.md` (design, storage layout,
  TTL/refresh rules, ~91 MB size estimate at his provider scale,
  limits, widget-test fake-async finding).

### 10. Build #12 — Live TV mini-player (portrait) + library header overflow (v2.25.8)
- **CORRECTED scope (Matt, 2026-11-07 ~00:24 EST): the mini-player is
  PORTRAIT, exactly like the Plex screenshot — "landscape" in the
  original brief was a misstatement.** Rotating to landscape behaves as
  today (fullscreen video as normal); no landscape mini-player was
  built.
- New files: `lib/screens/livetv/live_tv_mini_player.dart`
  (`LiveTvMiniPlayerController` — one `Player`, generation-guarded
  tunes, `force-seekable=no`, coordinator registration — +
  `LiveTvMiniPlayer` widget, 16:9 + info/control bar),
  `test/screens/livetv/live_tv_mini_player_test.dart` (8 widget tests),
  `test/screens/livetv/live_tv_mini_player_controller_test.dart` (6
  unit tests), `test/screens/libraries/library_header_overflow_test.dart`
  (1 widget test, failed before the fix with a 98px RenderFlex overflow
  at 360dp).
- Touched upstream files: `lib/screens/livetv/tabs/guide_tab.dart`
  (owns the controller; slot at the top of `_buildGuideGrid` when phone
  + portrait; `_tuneFromGuide` routes channel taps, D-pad select,
  detail-sheet tune and catch-up; `didChangeDependencies` stops the
  player on leaving portrait),
  `lib/screens/livetv/live_tv_actions_mixin.dart`
  (`showProgramDetails` gains optional `onTuneChannel`, default
  unchanged), `lib/screens/libraries/libraries_screen.dart` (title
  `Flexible` + ellipsis in `_buildLibraryDropdownTitle`),
  `lib/i18n/en.i18n.json` + generated `strings*.g.dart`
  (`changelog2258`), `lib/screens/settings/about_screen.dart`
  (changelog entry first), `pubspec.yaml` (version `2.25.8+165`).
- NOT touched: TV/tablet/desktop layouts, TV D-pad navigation, the
  What's On tab (no mini-player there; switching tabs stops playback),
  the full player open sequence (the mini-player mirrors it, it does not
  share code with it), series search / category initials / EPG /
  disk cache behaviour.
- Progress notes: `IPTV_BUILD12_NOTES.md` (design, test seams, the
  broadcast-cancel fake-async finding, the theme-platform finding,
  phone verification list).

### 11. Build #13 — Search fixes (live + series), missing VOD libraries, black mini-player, category initials, cache/fluidity (v2.25.9)
- New files: `IPTV_BUILD13_NOTES.md` (diagnosis, root causes with proof,
  measured cache/fluidity timings, phone verification list),
  `test/services/iptv/iptv_build13_diagnosis_test.dart` (9 failing-first
  reproduction tests — cold crawl trap, live search, diagnostics),
  `test/services/iptv/iptv_build13_initials_test.dart` (7 tests),
  `test/services/iptv/iptv_build13_cache_benchmark_test.dart` (6 tests,
  Trex-scale timings + jank ticker),
  `test/services/iptv/iptv_build13_browse_benchmark_test.dart` (2 tests,
  paged browse + hub at Trex scale),
  `test/screens/iptv_build13_search_screen_test.dart` (3 screen tests),
  `test/screens/libraries/iptv_build13_libraries_screen_test.dart` (4
  screen tests, 360×800 Fold 7 cover viewport),
  `test/mpv/video_first_frame_test.dart` (3 widget tests).
- Touched upstream files: `lib/media/iptv_client.dart` (Xtream live
  search leg `_searchLive` + `_liveChannelItem` + `fetchItem` `'live'`
  case; partial-row publication + sweep-skips-crawled + batch 16 +
  non-destructive section timeout; `seriesCatalogDiagnostics` probes
  directly; VOD+live warm-ups before `checkHealth`;
  `fetchLibraries` always lists the Xtream Movies/Series libraries —
  `_allCategoriesDisabled` probe deleted; raw-body disk writes
  `_writeCatalogRows` + `rawBody` on the background refresh; row-level
  paging `_filteredVodRows`/`_filteredSeriesRows` +
  `_vodPageItems`/`_seriesPageItems` (paged browse, hubs,
  `fetchMoreHubItemsPage`) + `totalCount` on `_recommendedHub`;
  allocation-free matching via one case-insensitive RegExp per call;
  `lastSearchDiagnostics` + `_SectionTrace`/`IptvSearchDiagnostics`),
  `lib/services/iptv/xtream_api.dart` (`lastLiveStreamsBody` /
  `lastVodStreamsBody` / `lastSeriesBody` — unfiltered calls only),
  `lib/services/iptv/iptv_catalog_cache.dart` (directory-create race on
  concurrent writes), `lib/utils/iptv_initials.dart` (buried/lowercase/
  bracket derivation, code-case rule, memoization),
  `lib/services/multi_server_manager.dart`
  (`notifyCatalogRefreshed()` on client replace — was private),
  `lib/screens/livetv/live_tv_screen.dart` (guide subscribes to
  `LibraryContentNotifier`), `lib/mpv/video.dart` (latched
  `hasRenderedFrame` at `initState` / player change),
  `lib/screens/settings/iptv_settings_screen.dart` ("Last search"
  diagnostics row), `lib/i18n/en.i18n.json` + generated
  `strings*.g.dart` (`changelog2259`, last-search strings),
  `lib/screens/settings/about_screen.dart` (changelog entry first),
  `pubspec.yaml` (version `2.25.9+166`).
- Touched test files: `test/services/iptv/iptv_build10_diagnosis_test.dart`
  (2 tests DIAGNOSIS → FIXED — the late-category matches are now found),
  `test/services/iptv/iptv_build13_diagnosis_test.dart` (B1/B2 margins
  widened: 120 categories / match 110 / 80ms — the post-fix crawl sat
  exactly on the 1000ms budget and flaked under suite load).
- NOT touched: EPG behaviour, the mini-player controller/tuning, the
  in-app updater, TV/tablet layouts, `fetchMoreHubItems` (no limit —
  still builds the full item list once per hub-detail expansion; the hub
  detail's section filter runs over it — row-level section filter is
  future work), image loading (still not cached).
- Progress notes: `IPTV_BUILD13_NOTES.md`.

### 12. Build #14 — v2.25.9 startup crash hunt (NOT reproduced) + RefreshPacer cooldown bypass (v2.25.10)
- New files: `IPTV_BUILD14_NOTES.md` (crash report, three independent
  hunts with counts, harness-blind spots, cooldown fix with failing-first
  proof, next evidence step), `test/services/iptv/iptv_build14_migration_test.dart`
  (4 tests — v2.25.8-format disk cache, 161 hidden initials, Trex-shaped
  fake panel), `test/services/iptv/iptv_build14_startup_test.dart` (2
  tests — dummy Plex HOME PC + Trex, library aggregation, Discover load),
  `test/screens/libraries/iptv_build14_startup_libraries_test.dart` (4
  tests — real Libraries screen, 360×800 + 1280×800, incl. the cooldown
  failing-first test),
  `test/screens/iptv_build14_startup_discover_test.dart` (1 test — real
  Discover screen, 360×800, full provider stack).
- Touched upstream files: `lib/utils/refresh_pacer.dart` (new
  `scheduleBypassCooldown()` — one-shot cooldown skip, debounce kept,
  blocked-retry kept), `lib/media/library_change_event.dart` (new
  `userInitiated` flag), `lib/media/iptv_client.dart`
  (`notifyCatalogRefreshed({userInitiated:})`, `clearCatalogCache` passes
  `userInitiated: true`), `lib/services/multi_server_manager.dart`
  (rebind passes `userInitiated: true`),
  `lib/screens/libraries/tabs/base_library_tab.dart`
  (`_onLiveLibraryChange` branches on `event.userInitiated`),
  `lib/providers/discover_provider.dart` (`_onLibraryContentChanged`
  branches the same way), `lib/i18n/en.i18n.json` + generated
  `strings*.g.dart` (`changelog2260`),
  `lib/screens/settings/about_screen.dart` (changelog entry first),
  `pubspec.yaml` (version `2.25.10+167`).
- Touched test files: `test/utils/refresh_pacer_test.dart` (+4 tests —
  bypass at debounce edge, bypass upgrades pending trailing pass, later
  push event paced normally, bypass retries while blocked; suite 13/13).
- The v2.25.9 startup crash ("Right after the app loads and the whole UI
  starts to come in", Plex HOME PC + Trex connected) was NOT reproduced:
  builder migration 4/4 + startup unit 2/2 + Libraries widget 4/4 +
  Discover widget 1/1; tester Task 1 (6/6 unit + 4/4 widget,
  services/iptv 174/174); tester Task 1b (7/7 unit + 4/4 widget, dummy
  Plex + Trex, Plex-offline/network-down, bind-racing-UI). No crash fix is
  claimed in this build. Remaining harness-blind spots: real `main()`
  startup sequence, real SharedPreferences migration on the phone, native
  mpv player, real panel data at full scale.
- Second pass (same build, same version): the on-device crash readout IS
  in — `lib/services/last_crash_store.dart` (new: `LastCrashCatcher` +
  `LastCrashStore` + abnormal-exit flag) + `lib/screens/settings/last_crash_row.dart`
  (new: "Last crash" row in Settings → Advanced) + `lib/main.dart`
  (install + prime + `markLaunched()` + `_AppExitObserver`); research
  fold-ins (report `~/workspace/tmp_work/plezy-tv-research14/RESEARCH_BUILD14.md`):
  UI-2 "Last search" renders synchronously from the bound client's
  in-memory getter (`lib/screens/settings/iptv_settings_screen.dart`),
  SA-12 red bridge tests fixed (fake gains `backend`),
  SA-4 partial — `liveCatalogChanged` flag on `LibraryChangeEvent`,
  dataset-derived in `IptvClient._refreshCatalogInBackground`, guide
  ignores VOD/series-only events (`lib/screens/livetv/live_tv_screen.dart`).
  Verdict from the research: keep the fork, do NOT rewrite; the
  IndexedStack does NOT eagerly mount tabs at startup (corrected premise).
- Secondary finding, FIXED in the second pass: the pre-existing 40px
  RenderFlex overflow in the Discover app bar at 360dp
  (`lib/screens/discover_screen.dart:803`, `_buildOverlaidAppBar`) — the
  title Text is now wrapped in `Flexible` + `TextOverflow.ellipsis`;
  the Discover widget test now expects no exception.
- NOT touched: EPG behaviour, mini-player, in-app updater, TV/tablet
  layouts, image loading, the `fetchMoreHubItems` full-list build.
- Progress notes: `IPTV_BUILD14_NOTES.md` (§6 crash readout, §10 research
  fold-ins).

### 13. Build #15 — Plex live-TV switch, guide search, black mini-player (2nd fix), categories rework, EPG cache, favourites, Plex isolation (v2.25.11)
(Added retrospectively in the build #16 commit — build #15's own commit did
not update this file.)
- Per-server Plex live-TV switch: Settings → Live TV, one switch per
  live-TV server, storage `livetv_hidden_server_ids`, applied in
  `checkLiveTvAvailability()` (`lib/providers/multi_server_provider.dart`).
- Guide search scoped to the selected source; IPTV programme results from
  cached EPG only; jump fallback (switch source + retry once, else
  snackbar) (`lib/screens/livetv/tabs/guide_tab.dart`).
- Black mini-player, 2nd fix (FAILED on the phone — see build #16 §14):
  controller-owned `hasFirstFrame` + 5s watchdog reveal + Mini-player
  diagnostic row in Settings → IPTV (`lib/screens/livetv/live_tv_mini_player.dart`,
  `lib/screens/settings/iptv_settings_screen.dart`).
- Categories rework from scratch: one "Trex categories" screen per
  connection (`lib/screens/settings/iptv_categories_screen.dart`), every
  category visible with counts, immediate toggles; NEW storage keys
  `hiddenCategoryIds` / `hiddenCategoryInitials` + one-time migration of
  the 161 disabled initials; the old selectors and `IptvInitialsChecklist`
  deleted.
- EPG xmltv feed persisted to disk (stale-while-revalidate, 5-min
  negative cache, short-EPG concurrency capped at 4 + 15s first-paint
  timeout) (`lib/services/iptv/xtream_api.dart`,
  `lib/media/iptv_live_tv.dart` — see `IPTV_BUILD15_NOTES.md`).
- Favourites tab in every IPTV library (`LibraryTabType.favorites`) +
  long-press "Add to favourites" in the catalog menu.
- Plex isolation (P-1): IPTV-only changes swap the client in place via
  `MultiServerManager.addIptvConnection` — zero Plex client creations
  across an IPTV toggle; ADD/REMOVE flows keep their rebinds.
- Progress notes: `IPTV_BUILD15_NOTES.md` (§9 = 10-step phone-verification
  checklist). Phone verdicts that became build #16: mini-player still
  black, Categories laggy, catch-up broken.

### 14. Build #16 — Categories virtualization, Android video-rect path, timeshift stamp, tune-failure diagnostic (v2.25.12)
- Categories virtualization (`lib/screens/settings/iptv_categories_screen.dart`):
  each section is a `SliverList.builder` (header as item 0, rows after)
  instead of one `SliverToBoxAdapter` + `SettingsGroup` Column; rows build
  their own card via `_groupCard` (same `Material` surface,
  `groupItemRadii(context, i, total)`, `groupGap`); hidden counts cached
  (`_liveHidden` / `_moviesHidden` / `_seriesHidden` / `_groupsHidden` /
  `_hiddenTotal`, recomputed in `_load`/`_persist` only); `_allRows`
  deleted. Behaviour unchanged (every category visible, immediate toggles).
- Android video-rect path — Dart: `VideoRectSupport` is now
  `on PlayerBase` (`lib/mpv/player/video_rect_support.dart`); NEW
  `lib/mpv/player/platform/player_native_android.dart`
  (`PlayerNativeAndroid extends PlayerNative with VideoRectSupport`);
  `Player` factory returns it for Android mpv
  (`lib/mpv/player/player.dart`); `PlayerAndroid` mixes the mixin in too
  (`lib/mpv/player/platform/player_android.dart`). iOS/macOS keep the plain
  `PlayerNative`; `Video` unchanged.
- Android video-rect path — Kotlin: NEW `setVideoRect(left, top, right,
  bottom)` on `SurfacePlayerCore`
  (`android/.../shared/SurfacePlayerCore.kt`), implemented in
  `MpvPlayerCore` + `ExoPlayerCore` (remember `requestedVideoRect`,
  resize/reposition the surface container via `FrameLayout.LayoutParams`,
  applied after `attachToContent`); `"setVideoRect"` handlers in
  `MpvPlayerPlugin` (pending rect applied at init success) +
  `ExoPlayerPlugin` (routes via `activeSurfaceCore`, `lastVideoRect`
  applied at initialize and to fresh mpv fallback cores in
  `dispatchMpvOpen`).
- Catch-up: `XtreamApi.timeshiftUrl` start stamp is now `YYYY-MM-DD:HH-MM`
  (was `...:HH-MM-SS`, which the panel's strict parse rejects)
  (`lib/services/iptv/xtream_api.dart`).
- Tune-failure diagnostic: `LiveTvMiniPlayerDiagnostic.failReason`
  (stage labels at tune failure points + player-error cause tag,
  credentials stripped) + Settings → IPTV renders it
  (`lib/screens/livetv/live_tv_mini_player.dart`,
  `lib/screens/settings/iptv_settings_screen.dart`,
  `t.iptv.miniPlayerFailReason`).
- New tests: `test/screens/settings/iptv_categories_screen_scroll_test.dart`
  (3), `test/mpv/video_android_rect_test.dart` (7),
  `test/services/iptv/iptv_timeshift_url_test.dart` (3); strengthened
  `test/screens/livetv/live_tv_mini_player_controller_test.dart`
  (catch-up stamp shape + fail-reason assertions).
- Progress notes: `IPTV_BUILD16_NOTES.md`. Research:
  `~/workspace/tmp_work/plezy-tv-research16/RESEARCH_BUILD16.md`.

### 15. Build #17 — Catch-up missing-recording UX, mini-player black (Dart-side), series search race + filter surfacing, toggle client reuse, initials first-region-wins + denylist, collapsible categories, guide channel menu + hide store, EPG name fallback + coverage, guide category switcher, series season synthesis (v2.25.13)
- Catch-up UX (`lib/screens/livetv/live_tv_mini_player.dart`,
  `lib/screens/livetv/tabs/guide_tab.dart`): new
  `LiveTvMiniPlayerFailureKind` (generic / missingRecording / lineBusy);
  HTTP status latched from the player log stream per tune; 404 →
  missingRecording ONLY on catch-up tunes, 458 → lineBusy always (458 is
  transient — never "missing recording"); missing-recording card shows
  "No recording available for \<programme\> on \<channel\>" + Watch live
  (new `onWatchLive`, `controller.watchLive()`), no retry. No URL-shape
  change.
- Mini-player black, Dart side (`lib/screens/livetv/live_tv_mini_player.dart`,
  `lib/mpv/video.dart`, `lib/screens/main_screen.dart`,
  `lib/screens/livetv/live_tv_screen.dart`): opaque black `Container`
  removed; MainScreen portrait Scaffold transparent on the Live TV tab
  and LiveTvScreen Scaffold transparent (the Scaffold `Material` was the
  second opaque layer — SDK `scaffold.dart`); rect sent BEFORE open via
  a per-tune `_rectSentCompleter` (500 ms, generation-checked) for
  `VideoRectSupport` players only; `Video.onVideoRectSent` now passes
  the rect string, carried in `LiveTvMiniPlayerDiagnostic.videoRect` +
  the settings tile. No Kotlin changes in this build.
- Series search (`lib/media/iptv_client.dart`,
  `lib/screens/search_screen.dart`): sweep batch 16 → 32
  (`_searchSweepBatchSize`); `_append*Matches` count hidden-category
  matches into `_SectionTrace.hiddenMatches` (surfaced via
  `lastSearchHiddenMatchesForLibrary`); scoped empty state shows
  `t.search.hiddenByCategoryFilter` + a button opening the connection's
  Categories screen.
- Toggle lag (`lib/media/iptv_client.dart`,
  `lib/services/multi_server_manager.dart`): `IptvClient.connection`
  mutable + `updateConnection` (throws on id/data-source change);
  `addIptvConnection` reuses the client on filter-only changes (no
  re-warm, no health probe).
- Initials (`lib/utils/iptv_initials.dart`): first-region-wins +
  content-word denylist (NEWS, KIDS, LIVE, HBO, TV, VIP, HD, VOD, PPV,
  FHD, UHD, XXX), applied in `_deriveCategoryInitial` and
  `initialsMeetingThreshold()`; stored hidden initials never re-migrated.
- Collapsible categories (`lib/screens/settings/iptv_categories_screen.dart`):
  per-section collapse (header `InkWell` + chevron, `itemCount = 1` when
  collapsed), persisted per connection in
  `iptv_categories_collapsed:<connectionId>`; initials section not
  collapsible.
- Guide channel menu + hide store (`lib/screens/livetv/tabs/guide_tab.dart`,
  `lib/media/iptv_live_tv.dart`, `lib/screens/livetv/live_tv_screen.dart`,
  `lib/screens/settings/iptv_settings_screen.dart`,
  `lib/utils/snackbar_helper.dart`): extensible `List<ChannelMenuItem>`
  (Hide channel — IPTV only — + Add/Remove favourites); all four
  triggers (cell long-press, TV SELECT hold, context-menu key) open the
  menu; NEW `iptv_hidden_channels:<connectionId>` store (same key
  derivation as favourites), honored in guide rows, search sheet, Live TV
  search (Xtream + M3U) and the all-hidden empty state; Settings → IPTV
  `_HiddenChannelsTile` per IPTV connection (per-row Unhide + Unhide
  all); hide snackbar with Undo (`showSnackBar` action params).
- EPG (`lib/media/iptv_live_tv.dart`,
  `lib/screens/livetv/tabs/guide_tab.dart`,
  `lib/screens/settings/iptv_settings_screen.dart`): name-normalized
  fallback match (`normalizeEpgChannelName`, `IptvEpgSource`,
  `_CachedXmltvGuide.byNormalizedName`, `_CachedChannelEpg.source`);
  `IptvGuideCoverage` + `guideCoverage()` + Settings tile; no-EPG rows
  render one "No guide data for this channel" block spanning the window
  instead of hourly "No information" blocks.
- Guide category switcher (NEW `lib/screens/livetv/guide_category.dart`):
  `LiveTvChannel.categoryId` (runtime-only), `IptvClient.visibleLiveCategories()`,
  pure `filterGuideChannels`; picker chips in `GuideTab`, selection in
  `LiveTvScreen` (reset on source change, composes with source/favorites/
  search, category empty state).
- Series detail (`lib/media/iptv_client.dart`): `fetchChildren(series)`
  returns synthetic season items (`season:<seriesId>:<n>`,
  `MediaKind.season`, `leafCount` = episode count);
  `fetchChildren(season:…)` returns that season's episodes; memoized
  `_seriesInfo`. Pre-existing `iptv_stage2_test.dart` updated for the
  intentional contract change.
- New tests: `iptv_build17_probes_test.dart` (14, kept from research),
  `iptv_build17_series_detail_test.dart` (2),
  `iptv_build17_search_filter_test.dart` (2),
  `iptv_build17_toggle_test.dart` (2),
  `iptv_build17_catchup_test.dart` (5),
  `iptv_build17_mini_player_test.dart` (3, Fold cover/unfolded/16:9),
  `iptv_build17_categories_collapse_test.dart` (4),
  `guide_category_filter_test.dart` (7),
  `iptv_build17_guide_category_test.dart` (7),
  `iptv_build17_epg_coverage_test.dart` (6),
  `iptv_build17_channel_menu_test.dart` (5),
  `iptv_build17_hidden_channels_test.dart` (3); updated pre-existing
  `guide_tab_iptv_test.dart`, `live_tv_mini_player_test.dart`,
  `live_tv_screen_test.dart`, `guide_tab_test.dart`,
  `video_android_rect_test.dart`, `iptv_stage2_test.dart`.
- Progress notes: `IPTV_BUILD17_NOTES.md`. Research:
  `~/workspace/tmp_work/plezy-tv-research17/RESEARCH_BUILD17.md`.

### 16. Build #18 — Trex series search, for real (poisoned disk cache), version scheme 1.0.0-2.25.0 + updater comparison fix (v1.0.0-2.25.0)
- Root cause (`lib/media/iptv_client.dart`): `_loadSeries()` crawls
  per-category skipping hidden categories when unfiltered `getSeries()`
  returns `[]`, and `_loadSeriesCached()` wrote those crawl rows to
  disk as the catalog; the warm search then trusted the partial list
  for the 24h TTL with no fallback.
- Never persist a crawl (`lib/media/iptv_client.dart`):
  `_loadSeries()` / `_loadVodStreams()` return `({rows, complete})`
  (`complete` only when the unfiltered call returned non-empty rows);
  `_loadSeriesCached()` / `_loadVodStreamsCached()` write to disk ONLY
  when `complete`; refresh wrappers return `[]` for a crawl so a stale
  refresh never overwrites a good file. Live has no crawl fallback —
  source tracking only.
- Heal (`lib/media/iptv_client.dart`): new
  `_sweepMissingCategories<T>` — when a warm search returns 0 matches,
  sweep the categories the user has NOT turned off AND that no cached
  row belongs to (deadline-bounded, batch `_searchSweepBatchSize`,
  unchanged) before answering []. Wired into the warm branches of
  `_searchMovies` and `_searchSeries`; a complete disk list sweeps
  nothing. Live: source tracking only.
- Diagnostics (`lib/media/iptv_client.dart`,
  `lib/screens/settings/iptv_settings_screen.dart`,
  `lib/i18n/en.i18n.json` + slang regen): `_vodLoadSource` /
  `_seriesLoadSource` / `_liveLoadSource` ('disk' / 'network' /
  'crawl', '' before any load) through `_SectionTrace.loadSource` →
  `IptvSearchSectionDiagnostics.loadSource`; Last search row renders
  `(source)` after the load and `· hidden ${hidden}` (previously
  carried but not rendered).
- Version scheme: `pubspec.yaml` `1.0.0-2.25.0+171` (PlezTV 1.0.0 on
  Plezy 2.25.0; versionCode 171); About entry `1.0.0-2.25.0` →
  `changelog2264` (sequential key; 2.25.13 entry untouched).
- Updater (`lib/services/update_service.dart`): `_extractVersion`
  keeps the upstream suffix; `_isNewerVersion` is PlezTV-aware — a
  PlezTV-scheme version is always newer than a bare version, core
  compares first then the upstream suffix among PlezTV versions, bare
  comparison unchanged, non-version suffixes ignored.
- New tests: `iptv_build18_probes_test.dart` (6 — D1, D1b, D2, D3,
  D5, D4; D3's step-1 assertion corrected from research: the crawl
  must write NOTHING, the poisoned file is seeded for the heal step),
  8 new cases in `test/services/update_service_test.dart`.
  Test-only fixes: `iptv_catalog_cache_test.dart` waits for the
  refetch's fire-and-forget writes before the test ends (tearDown
  ENOTEMPTY race); probes tearDown takes the EPG tests' retry guard.
- Progress notes: `IPTV_BUILD18_NOTES.md`. Research:
  `~/workspace/tmp_work/plezy-tv-research18/RESEARCH_BUILD18.md`.

## Deliberately NOT renamed (do not rename during a repatch)
- Dart package name stays `plezy` (~1,000 imports).
- libass module keeps `com.edde746.plezy.libass` (its JNI names match).
- Deep-link scheme stays `plezy://` (follow-up: `pleztv://`).
- Wire-protocol client identifiers (X-Plex-Product, Jellyfin client name,
  User-Agent) still say "Plezy".
- Repo / Codemagic app names, class names, comments.

## Repatch procedure (when upstream ships a new version)

Researched workflow (rebase a clean patch stack — NOT merge; merging tangles
history and hides what is ours, cherry-picking doesn't scale to a whole
release). Full procedure with sources:
`~/workspace/research_notes/git-fork-maintenance-repatch-20261106-0706/report.md`.

**0. Prepare & baseline (before touching anything).**
```bash
git checkout main && git status --short --branch   # clean tree required
git branch archive/main-2.25.0 main                # backup
git format-patch --full-index 2.25.0..HEAD -o patches/2.25.0/  # export the stack
flutter analyze && flutter test                     # known-good baseline on the OLD base
OLD_BASE=$(git rev-parse 2.25.0)                   # the old upstream base tag
```

**1. Fetch the new upstream and create a trial branch.**
```bash
git fetch upstream --tags
NEW_TAG=2.26.0                                     # example; use the real new tag
git log --oneline $OLD_BASE..upstream/$NEW_TAG | head -50   # what upstream changed
git checkout -b sync/$NEW_TAG-$(date +%Y%m%d) main
```

**2. Rebase the stack onto the new tag.**
```bash
git rebase --onto upstream/$NEW_TAG $OLD_BASE
# If a commit is skipped as "already applied upstream", note it — that patch
# is now redundant; drop it deliberately.
# On conflict: favour the upstream shape, re-apply only the fork hook.
# For generated files, take upstream's version now and regenerate in step 4.
# git rebase --abort at any point returns to the trial branch's starting state.
```

**3. Audit the rebase itself — a clean rebase is NOT proof.**
```bash
git log --oneline upstream/$NEW_TAG..HEAD
git diff --stat upstream/$NEW_TAG..HEAD
git range-diff $OLD_BASE..main@{1} upstream/$NEW_TAG..HEAD
git diff --check
# Compare against upstream's own diff ($OLD_BASE..upstream/$NEW_TAG) for
# files you touched that upstream also changed. A stale patch can SILENTLY
# revert an upstream fix with no conflict — review the full diff, not just
# conflicted files.
```

**4. Regenerate, don't hand-merge.**
```bash
bash scripts/codegen.sh        # freezed + slang — generated files are
                               # NEVER hand-edited (media_item.freezed.dart,
                               # media_item.g.dart, strings*.g.dart)
flutter pub get                # re-resolve pubspec.lock if it conflicted;
                               # do not hand-merge it
git add -A && git commit -m "chore: regenerate codegen on $NEW_TAG"
```

**5. Verify (the gate).**
```bash
flutter analyze --no-pub   # 0 errors outside pre-existing wakelock_plus noise
flutter test               # include test/services/iptv/, test/screens/iptv/,
                           # test/screens/livetv/, test/screens/libraries/,
                           # test/screens/settings/
# Release build + smoke test: M3U import, Xtream import, playback, settings.
```

**6. Publish — only after step 5 is green.**
```bash
git checkout main
git reset --hard sync/<trial-branch>   # move main onto the verified trial
git push --force-with-lease origin main   # NEVER bare --force
git checkout -b release/$NEW_TAG-1 sync/<trial-branch>
git tag v$NEW_TAG-fork.1 release/$NEW_TAG-1
git push origin release/$NEW_TAG-1 v$NEW_TAG-fork.1
# Update this file: new base, new tag, patch inventory, conflicts, test results.
# Release notes must link the exact source tag (GPL §6) and state the
# modification + date (GPL §5a).
```

**Between releases (small upstream fixes only):** do NOT do a full rebase.
Cherry-pick the single fix onto a `backport/upstream-<sha>-…` branch with
`git cherry-pick -x`, test, and merge that branch into `main`. Rebase `main`
only when you move the base.

## GPL-3.0 obligations for the fork (official text: gnu.org/licenses/gpl-3.0)

- §5(a): mark modified files with a prominent "modified it + relevant date"
  notice. §5(b): keep the GPL notice. §5(c): the whole work stays GPL-3.0.
- §4: preserve copyright/warranty notices + include LICENSE.
- §6: Corresponding Source with every binary — link the exact source tag
  in every release (GitHub Releases / README).
- §10: no further restrictions on recipients.
- Private/unpublished use triggers nothing (§2).
- App stores: Google Play / F-Droid / GitHub releases are fine if the exact
  source tag is linked. **Apple App Store is contested, not settled** —
  GPL §6 Installation Information vs App Store code-signing is an open
  legal question (some projects use a §7 additional permission). Do not
  submit a GPL-3.0 fork to the Apple App Store without checking first.
  (Not legal advice.)

## Pitfalls to avoid

1. Committing custom work onto the `upstream-main` mirror — then the clean
   delta is gone. Keep the mirror pristine.
2. Merging upstream into `main` "just this once" — it permanently tangles
   the history; every later rebase inherits the merge. Use a trial branch.
3. Rebasing the branch users build from without a trial branch — one bad
   rebase + force-push breaks every clone.
4. Bare `git push --force` — use `--force-with-lease`.
5. Naming `<old-base>` by reflog/`--fork-point` instead of explicitly in
   `rebase --onto` — it can drop your own pushed commits after a force-push.
6. **Branding position — known imperfection in OUR stack:** research says
   branding/mechanical changes belong at the TOP of the stack (last), so
   branding conflicts don't block every feature patch. Our stack has the
   rename FIRST (commit 845dfed, historical). At the first repatch, if the
   rename conflicts block everything, consider moving it to the top with an
   interactive rebase — do not reorder blindly.
7. Hand-editing `*.freezed.dart`, `*.g.dart`, slang output, or
   `pubspec.lock` — take upstream's version, finish the rebase, regenerate,
   commit separately. Never use `.gitattributes merge=ours` on lockfiles —
   it silently drops upstream dependency bumps.
8. Trusting a clean rebase — see step 3: stale patches can silently revert
   upstream fixes. Always `range-diff` + `diff --stat`.
9. Skipping the baseline test run on the old base — without it you cannot
   tell a rebase regression from a pre-existing failure.
10. Dropping the GPL notice / copyright headers in a rename, shipping a
    binary without a source link, or re-using the upstream name/icon —
    GPL §5/§6 violations and trademark confusion. Keep LICENSE, add a
    "modified <date>" notice, link the exact source tag in every release,
    ship under our own branding.
11. Letting the custom delta grow unchecked — every release, drop patches
    upstream has absorbed and upstream anything generic. A fork whose delta
    only grows eventually becomes un-rebaseable.

## Rules for future changes (so repatching stays possible)
- Keep changes in small atomic commits, one feature per commit. Never mix
  a rename/branding sweep with a feature in the same commit.
- New features go in NEW files where possible; touch upstream files only
  where integration requires it, and keep those touch-points minimal.
- Never hand-edit generated files (`.freezed.dart`, `.g.dart`,
  `strings*.g.dart`) — change the source and regenerate.
- Keep this file updated with every change. If a change drops or replaces
  an upstream behaviour, say so here with the reason.
