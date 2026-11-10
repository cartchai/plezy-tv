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
- Scale of the fork vs base: **441 files changed, 47810 insertions, 3327 deletions**
  (most of the churn is the rename commit sweeping Kotlin package paths;
  verified 2026-11-09 after the build #19 commit — was 432 files /
  +45,201/−3,322 at the Quest release (v1.0.1-2.25.0)).

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

### 17. Build #19 — Scoped search leaks a Plex movie + series-leg repair (v1.0.2-2.25.0, versionCode 174)
- Scope leak (`lib/services/data_aggregation_service.dart`,
  `lib/screens/search_screen.dart`): `searchAcrossServers` gains
  `scopedLibraryKey`; new `_inScopedLibrary` drops every title row
  whose `libraryGlobalKey != scopedLibraryKey`, including unattributed
  rows from other servers. `performSearchQuery` passes
  `_selectedLibraryKey` when the scope library is loaded (same condition
  as the hiddenKeys block); a stale scope still behaves as All. People
  are NOT filtered by the scope key. `_withoutHiddenLibraries` untouched
  — hide-one still keeps unattributed rows (bridge test :724 passes).
  Why a key, not hiddenKeys: P3 is unsatisfiable from hiddenKeys alone
  (structurally identical to a two-server unscoped hide; :724 pins the
  single-hide behaviour), so the scope must be conveyed explicitly.
- Plex defense in depth (`lib/services/plex_client.dart`):
  `searchItems` now filters client-side by section id like
  `searchPeople` does, and drops unattributed rows ONLY when
  `excludedLibraryIds` covers every library on the server (memoized
  `fetchLibraries()`, fail-open on error).
- Series leg (`lib/media/iptv_client.dart`): (a) P5a — the stale-disk
  refresh refuses to overwrite the disk file when a partial unfiltered
  list is under half the file's row count (series + VOD; live not
  changed); (b) P5b — new `_repairDiskCatalogAfterHeal<T>`: after a
  warm 0-match search heals, the swept categories' rows are merged
  into the cached list, written to disk (awaited), and the in-memory
  memoized list swapped; (c) P4 — `_sweepCatalogCategories` is now a
  sliding window (up to `batchSize`, unchanged at 32, concurrent; a
  finished call frees its slot at once) and `_sweepDeadline` moved
  from 90% (45 s) to 98% (49 s) of the section budget — at uniform
  6 s/call the 8-batch x 6 s packing minimum lands the last batch at
  ~48 s, past 45 s no matter the scheduling.
- Version: `pubspec.yaml` `1.0.0-2.25.0+172` (versionName unchanged);
  About entry `1.0.0-2.25.0` → `changelog2265` (sequential key; the
  build #18 entry is relabelled `1.0.0-2.25.0 (build 171)` so two
  builds sharing a versionName stay distinguishable).
- New tests: `iptv_build19_probes_test.dart` (10 — P1, P2, P2b, P3,
  P4-fast, P4-slow, P5a, P5b, P6, P7; the scoped probes pass
  `scopedLibraryKey` exactly as `performSearchQuery` does — the
  original hiddenKeys-only probe was run failing-first on base, 4 pass
  / 6 fail, and is preserved in the research worktree).
- Progress notes: `IPTV_BUILD19_NOTES.md`. Research:
  `~/workspace/tmp_work/plezy-tv-research19/RESEARCH_BUILD19.md`.

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
### 18. Quest fix v2 — keep the TV interface, make it drivable with mouse + thumbstick (v1.0.1-2.25.0, versionCode 173, shipped 2026-11-09)
- Matt's correction (2026-11-09): he did NOT ask for the phone layout on Quest — he wants to MANEUVER the existing TV UI with the controller. The v1 Horizon OS TV veto was the wrong direction and is REMOVED in v2 (see below); everything else from v1 carries over.
- Root cause: Quest has no touchscreen, and the app's TV detection treats "no touchscreen" as a TV, so Quest gets the focus-driven TV interface — but a Quest controller sends zero D-pad keys (laser pointer = mouse hover/click/drag, thumbstick = scroll events, B/Y = back). Upstream-identical behaviour (verified in upstream Plezy on Quest) — inherited, not fork-introduced. V1 got Discover wrong: TV Discover DOES have a vertical `ListView.builder` (`lib/widgets/tv_browse_rail.dart:1411-1414`) but `NeverScrollableScrollPhysics` — movement is selection-driven via `_moveHub`/`_moveItem`, not scrolling. Hover already moves the selection (`MouseRegion` onEnter → `_setHoveredItem`) and click already opens things. The gap was narrow: no pointer path to change the active hub / scroll Discover vertically.
- Veto REMOVED, detection kept (`android/app/src/main/kotlin/com/matt/plezytv/PlezyActivity.kt`, `lib/utils/platform_detector.dart`): Kotlin `isTv` back to `!isAutomotive && reasons.isNotEmpty()` (only the `!isHorizonOs &&` removed); the `hasSystemFeature("horizonos.software.horizon_os")` check, the `"isHorizonOs"` map entry, and the `'horizon_os'` reason are KEPT for diagnostics and targeted pointer exceptions. Dart fallback mirrors it (`isTv: !isAutomotive && reasons.isNotEmpty` in both `detectAndroidTvFromSystemFeatures` and `_fromNativeMap`); `AndroidTvFeatureDetection.isHorizonOs`, `TvDetectionService.isHorizonOsSync()`, `PlatformDetector.isHorizonOs()` all kept. A Quest IS a TV now (`isHorizonOs` true AND `isTv` true together). Test seam added: `TvDetectionService.debugSetHorizonOsOverride` (mirrors the Apple TV / automotive overrides; cleared by `debugReset`). Diagnostic-reason fix (found by the re-scoped test): `'horizon_os'` was added to `reasons` before the `isTv` verdict, and `isTv` is `reasons.isNotEmpty` — with the veto gone, Horizon OS alone read as a TV on the diagnostic reason's strength. Fixed in both Dart and Kotlin: the verdict is computed BEFORE `'horizon_os'` is added (never mattered on a real Quest — `no_touchscreen` fires anyway — but a diagnostic reason must not vote).
- Thumbstick bridge on the rail — NEW `lib/widgets/tv_rail_scroll_bridge.dart`, `lib/widgets/tv_browse_rail.dart`: `TvRailScrollBridge` converts `PointerScrollEvent.scrollDelta` into selection moves (Apple TV accumulator shape from `AppleTvRemoteTouchService`: per-axis progress against geometry-priced thresholds, 60 ms repeat cooldown with re-anchoring, 1.5x axis-switch dominance, one step per event max). The rail's root `Focus` is wrapped in a translucent `Listener(onPointerSignal)`; the bridge calls `_moveHub`/`_moveItem` directly (no key synthesis). Step travel is priced by the focused item's geometry (card width for items, section height for hubs, clamped 120–480). Every explicit move (`_moveHub`/`_moveItem`/`_setHoveredItem`/`_selectHubItem`) discards pending bridge progress. Scoped to the rail ONLY; rows NOT made `NeverScrollable` (would break trigger-drag).
- Mouse-drag scrolling (`lib/utils/app_scroll_behavior.dart` — NEW in v1, kept, `lib/main.dart`): `AppScrollBehavior` adds `PointerDeviceKind.mouse` to `dragDevices`; applied on both `MaterialApp`s (live :2003, bootstrap :881).
- Pointer menu buttons (`lib/widgets/media_card.dart`, `lib/widgets/episode_card.dart`, `lib/screens/playlist/playlist_item_card.dart`, `lib/screens/libraries/folder_tree_item.dart`): a ••• opens the same context menu as a long-press — hover-revealed on grid posters (bottom-right), always-visible trailing button on list/episode/playlist/folder-media rows; plain folders get none (their menu is just Play/Shuffle, already buttons). Tooltip `t.common.options`.
- Player mouse gestures (`lib/widgets/video_controls/parts/playback_input.dart`, `lib/widgets/video_controls/video_controls.dart`): edge-adjustment handlers accept mouse alongside touch; two-finger tap stays touch-only. Gate is `(isMobile || isHorizonOs) && (!isTV() || isHorizonOs) && ...` — the research's `isMobile && (!isTV() || isHorizonOs())` form is inert (`isMobile()` is false on TV). The gate alone was NOT enough: the root `Listener` in `video_controls.dart` attached the handlers only when `isMobile`, so they never fired on TV at all — new local `touchPointerHandlersAllowed = isMobile || isHorizonOs()` gates the wiring; the `isMobile` local itself is unchanged (skip zones, edge indicator, chrome sizing, key handling keep TV behaviour). Known follow-ups NOT fixed here: the on-screen edge indicator is `if (isMobile)`-gated so Quest gets no visual feedback for the drag (volume/brightness still change); `_handleDeviceAdjustmentResume()` is mobile-only so a brightness set on Quest won't auto-restore on resume.
- Manifest (`android/app/src/main/AndroidManifest.xml`): `resizeableActivity="true"`, `<layout defaultWidth 1024dp / defaultHeight 640dp>`, `com.oculus.supportedDevices = quest2|questpro|quest3|quest3s`, `com.oculus.application_type = panel`. Leanback declarations KEPT; minSdk unchanged (25).
- Guide is OUT of scope for this build (Matt): no guide scroll/menu work; the "No program data" guide is his Plex server's guide data, not an app bug. No global hover→focus (rail already has model-level hover; global hover-focus would fight the auto-scroll guard, issue #2031). No joystick→D-pad bridge. Thumbstick arrival and pointer kind UNPROVEN (headset-only).
- New tests: `test/widgets/tv_rail_scroll_bridge_test.dart` (16), `test/widgets/tv_browse_rail_scroll_bridge_test.dart` (5), `test/widgets/video_controls_horizon_os_edge_gestures_test.dart` (2), `test/utils/platform_detector_test.dart` re-scoped (Quest is a TV + Horizon OS).
- Progress notes: `IPTV_BUILD_QUEST_V2_NOTES.md` (supersedes `IPTV_BUILD_QUEST_NOTES.md`). Research: `~/workspace/tmp_work/plezy-tv-research-quest-v2/RESEARCH_QUEST_V2.md` (supersedes `~/workspace/tmp_work/plezy-tv-research-quest/RESEARCH_QUEST.md`).

### 19. Trex 403 — send a User-Agent on every Xtream request (v1.0.3-2.25.0, versionCode 175)
- Phone failure (2026-11-09 ~20:47 EST, screenshot `9663_0_vy01.jpg`): Discover shows "trex refused access for this account" + "Unable to load Discover" on BOTH home WiFi and mobile data, while TiviMate works with the same account on the same phone/network. The panel answers HTTP 403 to PlezTV's `player_api.php` calls. NOT an account ban (TiviMate proves the account), NOT an IP block (same IP works in TiviMate), NOT the probes (curl from a cloud IP is a different signature, and a PlezTV login succeeded on mobile data AFTER the last probe).
- Root cause: `XtreamApi` sent NO User-Agent, so the panel saw Dart's default `Dart/3.13 (dart:io)` — a distinctive, non-player signature. Xtream panels enforce per-user allowed-UA lists and global blocked-UA patterns as a first-class feature (USER_AGENT_BAN / EMPTY_UA); `VLC` is the #1 documented 403 fix. Research: `~/workspace/tmp_work/plezy-tv-research-trex-refusal/RESEARCH_TREX_REFUSAL.md`.
- Fix (`lib/services/iptv/xtream_api.dart`): NEW `XtreamUserAgent` — constants `VLC` / `IPTVSmartersPro` / browser UA, choice keys, `resolve(choice, custom)` (unknown choice or blank custom falls back to VLC, never empty). `XtreamApi` gains `userAgent` (fixed) and `userAgentProvider` (re-read per request); `_fetchBody` AND `_getText` both send `headers: {'User-Agent': _effectiveUserAgent}` — login, all category/list calls, series info, simple data table, short EPG, `xmltv.php`, `get.php`. Default is VLC.
- Setting (Settings → IPTV → Xtream User-Agent): NEW prefs `iptv_xtream_user_agent` (choice, default 'vlc') + `iptv_xtream_user_agent_custom`, in `_portableOnlyPrefs` (backed up by settings export, like `iptvShowCatchUpBadge`). `IptvClient._xtreamApi` passes a provider closure reading both prefs per request, so changing the setting applies to the next request with no rebuild/restart; `SettingsService.instanceOrNull` null (tests) falls back to VLC. The Add-Xtream sign-in probe sends the configured UA too, or a panel that 403s the Dart UA would fail sign-in while the app would work. UI: `SettingSelectionTile<String>` (VLC / IPTVSmartersPro / Browser / Custom) + `SettingTextTile` for Custom (shown only when Custom is picked; blank rejected in the dialog). NEW shared helpers: `showPlainTextInputDialog` (`lib/screens/settings/settings_utils.dart`, modeled on `showRegexInputDialog` minus pattern validation) and `SettingTextTile` (`lib/widgets/setting_tile.dart`, modeled on `SettingRegexTile`). The 403 → `HealthStatus.accessDenied` mapping is UNCHANGED.
- Caveat: if the provider whitelists per-user UAs and VLC is not on the list, no guessed UA works — then the fix is through the provider (ask them to allow VLC). Fallback order if VLC fails on the phone: IPTVSmartersPro, then the browser UA, then stop guessing and contact the provider. Stream playback URLs go to mpv/ExoPlayer, NOT through `XtreamApi` — if the panel also 403s streams, that is a separate follow-up (player UA), not this fix.
- Tests: `test/services/iptv/iptv_build20_user_agent_test.dart` (2: default VLC on all 12 calls + no `Dart/` UA anywhere; 403 → `MediaServerHttpException` 403 'Xtream access denied' → `IptvClient.checkHealth()` == `accessDenied`) — the default-UA test FAILS on ac3ddcbda ("carries no User-Agent"), the 403 test passes on base (control). `test/services/iptv/iptv_build20_user_agent_setting_test.dart` (4: fixed UA, provider re-read per request, provider wins over fixed, `resolve()` mapping incl. blank/unknown → VLC) — new API, compiles only after the fix.
- Verify: analyze on the 10 changed files clean (repo-wide still 49, all vendored `packages/wakelock_plus`, zero in `lib/`); `test/services/iptv/` 245/245; `test/screens/livetv/` 102/102; `test/screens/iptv/` + `test/screens/settings/` 224 pass with 1 load flake (`iptv_categories_screen_scroll_test` scroll-frame cost failed once in the combined run, passes alone 3/3 and in a second combined run — untouched by this change). NOTE: do NOT run `dart format` on whole files in this repo — the committed code is not formatter-clean even at the repo's 120 width, so it rewrites unrelated lines (caught and reverted twice during this build; diff kept to 362 insertions / 11 deletions).
- Version: 1.0.3-2.25.0+175 (both climb per the updater-names-only rule). Changelog `about.changelog2267`. UNPROVEN (phone-only): Discover loads on WiFi with the banner gone.

### 20. Search must not disconnect Trex — split health verdict, bound the burst, IPTV reconnect, composite verdict (v1.0.4-2.25.0, versionCode 176)
- Phone failure (2026-11-09 ~23:12 EST): searching puts the app into OFFLINE mode and disconnects Trex. Searching also takes forever on a cold/stale catalog (heal sweeps all 237 series categories mid-search). Research: `~/workspace/tmp_work/plezy-tv-research-search-offline/RESEARCH_SEARCH_OFFLINE.md`.
- Root cause: the search itself never touches health state. `IptvClient.checkHealth` mapped EVERY failure except 401/403 to `HealthStatus.offline` — timeout, 429, 500, socket error, DNS — catch-all, no retry, no transient/dead distinction. The search's heal burst (up to 32 concurrent category calls per section, 3 sections concurrently = ~96 in flight against a max_connections=1 panel, orphaned requests outliving the 50s section budget) makes the probe fail. Aggravators: the offline verdict is composite (Trex-refused + Plex-offline on mobile data = whole app enters the offline shell, because the "refused is not offline" carve-out only applied when ALL visible servers were refused); `reconnectOfflineServers` had NO IPTV branch, so a flipped Trex stayed offline until a manual reconnect. Matt (2026-11-09 ~23:25 EST): "Do as few requests as you can, make it comparable to other apps. I think that's why Trex blocks me from time to time, they're seeing all those requests." The burst cap is therefore 8 (the top of the low end Matt asked for, 4–8), orphans are hard-cancelled, and no health probe fires while a search is in flight.
- Fix (`lib/media/iptv_client.dart`): `checkHealth` splits the verdict — timeouts / 429s / 5xx / socket errors are transient (keep last-known-online; N=3 consecutive transient failures before publishing offline — probes are event-driven, not periodic, so 3 = three separate triggers); 401 stays authError, 403 stays accessDenied; a probe during a search is deferred (coalesced to one probe after the search, via `onDeferredHealthProbe`); the search burst is a shared `_SearchRequestSemaphore` capped at 8 total in flight across all three sections and concurrent searches; orphaned requests are hard-cancelled (`http.AbortableRequest` + `AbortController.trigger` threaded through `_fetchBody`/`_getJson`/the six search-path methods in `lib/services/iptv/xtream_api.dart`) when a section's budget expires — and the sweep itself hard-cancels its in-flight calls when IT stops early (its own deadline ends the sweep just before the section timeout, so without this the abort never fires). Cap justification: cap 4 (the low end Matt asked for) was tried first and REJECTED by evidence — build #19's P4-fast probe (1s per call, 232 categories to sweep) needs 232/4 × 1s = 58s > the 49s sweep deadline, so the heal misses Game of Thrones (log: `ms=49283, sweepMatches=0`, GoT missing). Cap 8 (the top of Matt's 4–8 range) passes P4-fast in 29s (232/8 × 1s, 20s margin) and is still a 12x cut from the old ~96 concurrent requests and 4x down from the old per-section 32. A slower panel (6s/call, the P4-slow stress case) cannot be swept inside the deadline at any cap in Matt's range — the unfiltered load (outside the cap) is the primary path then. Deliberate boundary: the three unfiltered catalog loads and the category-list fetches are NOT capped/aborted (single, memoized, cache-warming); the background catalog crawl keeps its own path. Worst-case concurrent during a cold+degraded search after this build ≈ 62 vs ~150 before; typical healthy ≈ 14 vs ~102; warm (common) ≤ 8 vs up to 96.
- Fix (`lib/services/multi_server_manager.dart`): NEW IPTV branch in `_doReconnectOfflineServers` (`_reconnectIptvServer` + `_probeIptvHealth`, mirroring the Jellyfin branch) so a flipped Trex recovers on its own; the deferred probe is wired in `addIptvConnection` (`client.onDeferredHealthProbe` → `_probeIptvHealth`, a targeted single-connection re-probe).
- Fix (`lib/providers/offline_mode_provider.dart`): "no server online AND at least one refused" shows the refusal banner (`onlyRefusedServers`), not the offline shell. Genuine no-network (nothing refused) still enters offline.
- Fix (close-after-use — Matt, 2026-11-10 ~00:39 EST: "Should the connection have a close function so it stops talking after?"): the search screen already aborted the previous search on a new keystroke (proven by C1), and `XtreamApi.close()`/`IptvClient.close()` already ran on connection removal and app exit — but an in-flight search kept running after the user left the search screen or the app backgrounded, and leaving the search screen did not abort it. `IptvClient.cancelActiveSearches()` (tracks the three sections' `AbortController`s in `_activeSearchAborts`, added/removed in a try/finally around the section wait) hard-cancels an in-flight search; `MultiServerManager.cancelActiveIptvSearches()` calls it on every connection from `main.dart`'s `paused`/`detached` lifecycle case (alongside the library-socket suspend); `search_screen.dart` `dispose()` aborts `_activeSearchAbort` as a safety net (the tab is kept alive in an `IndexedStack`, so the background path is the one that fires). The background catalog crawl is NOT cancelled by this (bounded batch walk, finishes on its own, never re-runs for the same catalog).
- Tests: `test/services/iptv/iptv_build21_search_offline_test.dart` (8, failing-first, pre-fix API only): H1/H2 transient health (timeout/429 stay online until the 3rd in a row; 403 → accessDenied, 401 → authError immediately); B1 burst cap (max 4 observed, cap 8, 19/19 requests); R1 reach (GoT in cat-237, the last of 237, at cap 8, 237 requests — proves 8 still reaches); O1 orphan (search returns in 2942ms, 9 aborted, 0 requests after); P1 probe deferral (0 panel requests mid-search); C1 two keystrokes (max 5, cap 8, 28 requests, 12 aborted, no tail); M1 IPTV reconnect (probe 0→1, online). `test/services/iptv/iptv_build21_deferred_probe_test.dart` (1, new API — two probes mid-search coalesce to one deferred probe, exactly one panel request). `test/services/iptv/iptv_build21_close_after_use_test.dart` (1, new API — A1 abandon: `cancelActiveSearches()` stops an in-flight search in 2ms, 15 aborted, 0 requests after, vs ~27s uncancelled). `test/providers/offline_mode_provider_build21_test.dart` (3, failing-first): mixed refusal → banner not offline; genuine no-network → offline; refused + online → online. Failing-first on base 652db5f90: 9 fail, 2 pass (the two controls); on the fix all 13 pass. R1's base failure is the cap (32 vs 8) — GoT is found on both.
- Request counts (measured in-harness, fake panel): warm-heal search 19 requests (max 4 concurrent, cap 8) vs up to 96 on base; cold search 237 category requests + 3 loads + 3 lists (max 8 concurrent) vs ~102 concurrent on base; two keystrokes 28 requests (max 5) vs up to 38+ on base; a timed-out search leaves 0 requests after it (9 aborted) vs orphans running to their own 120s budget on base; an abandoned search stops in 2ms (15 aborted, 0 after) vs ~27s uncancelled. Peer comparison (open-source, code-verified — weighted per Matt, 2026-11-09 ~23:29 EST): IPTVMac 0.9.8 (SQLite FTS5, one query per search; SyncService guards, 300 MB cap), IPTVnator 0.25.0 (trigram FTS, substring ≥3), OpenTV (Room, 6h WorkManager sync, `replaceCatalogue`, search is a local `LIKE` query), Hypnotix (whole-list sync at load, 8h TTL, empty list = cache-miss) — all make ZERO panel requests during a search. TiviMate (closed-source, inferred from guides/reviews): 0 during search after one sync. This build still falls short of parity: a cold/stale search still makes panel requests (capped at 8); only build #23 (local-only search, v1.0.6) closes the gap to zero during search.
- Version: 1.0.4-2.25.0+176 (both climb per the updater-names-only rule). Changelog `about.changelog2268`. UNPROVEN (phone-only): search on mobile data with Trex + Plex, no offline shell, Trex recovers on its own. Build #22 (stream UA, v1.0.5-2.25.0+177) is being built in parallel off the same base and rebases onto this build after it ships; changelog key 2269 is reserved for it.

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
