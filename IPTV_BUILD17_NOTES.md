# PlezTV build #17 — v2.25.13 (2.25.13+170)

Ten items from Matt's v2.25.12 reports (2026-11-08 ~12:28–12:54 EST), plus
the research report's own findings. Research:
`~/workspace/tmp_work/plezy-tv-research17/RESEARCH_BUILD17.md` (1,342
lines — proves every root cause; read it first — this file records what was
built, not the investigation). The research report's summary table lists
ten implementation items (§§ 2,3,4,5,6,8,9,10,11,12); there is no §1 or §7
— the "twelve" in the brief counts the report's two probe-only sections
(§5.5 duration clamp, §10.1 tvg-id match rate), which need live-panel
answers and are NOT implemented here (see "Panel questions still owed").

## 1. Catch-up: "just tell me missing recording" (§5)

**Report (Matt, 2026-11-08 ~12:30 EST):** catch-up still broken on
v2.25.12; the mini-player shows "Could not start: file failed to load".

**Root cause (proven by the parent's real-panel probes, 2026-11-08):** the
app's timeshift URL shape is CORRECT — the same URL returns 200 for A&E
HD and 404 for Comedy Central HD / DIY for the same programme window. The
panel simply has no recording for that programme on that channel. The app
reported every failure as a generic "Could not start", so a missing
recording looked like a broken player. (The build #16 stamp fix was the
wrong target: the stamp was never the only problem.)

**Fix** (`lib/screens/livetv/live_tv_mini_player.dart`,
`lib/screens/livetv/tabs/guide_tab.dart`, i18n):
- New `LiveTvMiniPlayerFailureKind`: `generic` / `missingRecording` /
  `lineBusy`. The controller latches the panel's HTTP status from the
  player's log stream (`_onPlayerLog` via `PlayerError.httpStatusFromLog`,
  the same latch the full player screen keeps), reset per tune.
- Classification in `_classifyFailure`: **404 → missingRecording ONLY on
  a catch-up tune** (a live 404 is a dead stream, stays generic);
  **458 → lineBusy on ANY tune** — 458 is TRANSIENT (the parent's re-test:
  Adult Swim West returned 458 at ~12:43, 404 at ~13:02 for the same
  channel; panel sources say 458 = session/connection limit), so it is
  NEVER presented as "missing recording"; no HTTP status → generic.
  The error-event cause tag `server-http-404` is a fallback when the log
  line never arrives. A stale 404 from an earlier tune never mislabels
  the next failure.
- The failed card branches on `controller.failureKind`: missing-recording
  shows "No recording available for \<programme\> on \<channel\>" + a
  **Watch live** button (new `onWatchLive` widget param,
  `controller.watchLive()` — same channel, no catch-up epoch) and NO
  retry; lineBusy shows "The line is busy — try again" + Retry; generic
  keeps the old card. `retry()` now also passes the stored programme
  title. The diagnostic `failReason` is distinct: `'no recording for
  <programme> on <channel>'` vs `'line busy: HTTP 458'`.
- NO URL-shape change (shape proven correct). NO duration clamp — that
  awaits the §5.5 probe (see below).

**Tests:** `test/screens/livetv/iptv_build17_catchup_test.dart` (5 tests):
404 catch-up → missingRecording named + Watch live re-tunes to the live
URL; 458 → lineBusy never "missing recording"; no-status failure →
generic; 404 on a LIVE tune → generic; stale 404 never mislabels the
next failure. 5/5 pass. (Test note: a failed tune disposes the player,
so `watchLive` creates a second player — assertions use
`players.last`, not `players.single`.)

**Honest limits:** the missing-recording message is only as good as the
HTTP status the player surfaces — if the panel 404s silently (no log
line, no error event), the card stays generic. The duration clamp is
unproven (probe owed).

## 2. Mini-player still black on live tunes (§6)

**Report (Matt, 2026-11-08 ~12:30–12:34 EST):** live TV works, catch-up
doesn't, "the mini-player is still black" on live TV that loads fine.
Diagnostics (screenshot 9633_7_g92x.jpg): live tune — First frame:
watchdog reveal after 5364 ms, no frame reported; Video rect sent: YES;
still black. "Im using a fold mayve its the aspect ratio but u should
make it work in any aspect ratio."

**Root cause (two stacked causes, both proven in-harness):**
(a) The mini-player widget's outer `Container` had `color: Colors.black`
— an opaque layer over the video hole (fullscreen uses a transparent
Scaffold). (b) The rect was sent AFTER the player opened, so mpv
attached to a placeholder surface and never re-attached.

**NEW FINDING (programming, verified against the Flutter SDK source):
the report's §6.3 fix alone CANNOT work.** A `Scaffold` wraps everything
in a `Material(color: widget.backgroundColor ?? theme.scaffoldBackgroundColor)`
(SDK `scaffold.dart:3237`), and the theme's `scaffoldBackgroundColor` is
opaque (`c.bg`: dark `0xFF0E0F12`, OLED black, light `0xFFF7F7F8`). In
the real tree the chain is rootShell Scaffold (transparent) → MainScreen
portrait Scaffold (opaque) → LiveTvScreen Scaffold (opaque) →
mini-player Container. Removing the Container's black alone leaves two
opaque Scaffolds over the hole.

**Fix** (`lib/screens/livetv/live_tv_mini_player.dart`, `lib/mpv/video.dart`,
`lib/screens/main_screen.dart`, `lib/screens/livetv/live_tv_screen.dart`,
`lib/screens/settings/iptv_settings_screen.dart`):
- Opaque black `Container` removed from the mini-player widget (black
  kept only for `isStopped` — no player — and the `isFailed` overlay at
  0.7 alpha).
- MainScreen portrait Scaffold gets `backgroundColor: _currentTab ==
  NavigationTabId.liveTv ? Colors.transparent : null` (conditional —
  every other tab keeps the theme bg); LiveTvScreen Scaffold gets
  `backgroundColor: Colors.transparent` unconditionally. The background
  behind is the Android window, which `PlezyActivity` syncs to the theme
  mode (dark → #0E0F12, OLED → black, light → #F7F7F8), so dark/oled/light
  look identical; tinted palettes (ember #14110F, glacier #0E1319) show
  the dark window shade in unpainted gaps on the Live TV tab only.
  Landscape shell untouched (mini-player is portrait-only).
- Rect BEFORE open: `tune()` now creates the player FIRST
  (`_ensurePlayer()`), notifies so the `Video` mounts, and — only when
  the player is a `VideoRectSupport` — awaits a per-tune
  `_rectSentCompleter` (500 ms timeout, generation-checked) before
  session/URL/open. `noteVideoRectSent` now takes the rect string and
  completes the completer. Fake players (not rect-capable) skip the wait
  entirely, so existing controller tests stay fast.
- Rect capture in the diagnostic: `Video.onVideoRectSent` changed from
  `VoidCallback?` to `void Function(String rect)?`, passing
  `'$left,$top,$right,$bottom@$dpr'`; new
  `LiveTvMiniPlayerDiagnostic.videoRect` field + controller `videoRect`
  getter; the diagnostic tile renders `t.iptv.miniPlayerRectValues` when
  present. Build #16 test `test/mpv/video_android_rect_test.dart`
  updated for the new callback signature.

**Tests:** `test/screens/livetv/iptv_build17_mini_player_test.dart` (3
tests, real controller + real `LiveTvMiniPlayer` widget + real `Video`
widget + rect-capable fake player): Fold cover 1080×2520 @2.625,
unfolded 1812×2176 @2.3, standard 16:9 1080×1920 @2.625 — each asserts
(1) rect sent equals the laid-out hole in physical px (computed from
the `Video` RenderBox, same floor/ceil math as `video.dart`), (2) rect
sent BEFORE open (shared event log), (3) no opaque ancestor over the
`Video` (walks ancestors, fails on any opaque `Container`/`ColoredBox`/
`Material` colour), (4) a frame is reported (playback-restart → reveal
event, `hasFirstFrame` true). **3/3 pass. FAILING-FIRST PROVEN: the same
file (minus the two new-API references) run in a temp worktree at base
e97112171 failed 3/3, failing at the rect-order assertion
(`indexOf('rect')=1 > indexOf('open')=0` — rect after open on v2.25.12).
Temp worktree removed afterwards.**

**Honest limits — UNPROVEN on the phone:** whether mpv actually presents
a frame onto the native surface. The playback-restart in-harness is a
faithful stand-in, not a rendered frame. The Kotlin surface-strand half
(research §6.4.2: surface size, `videoOutputEpoch`,
`pausedForSurfaceLoss`, `videoOutputFailure` from Kotlin) was NOT
implemented — no new method channel; the diagnostic now carries the rect
values + reveal, which is the Dart-side evidence. **If the phone is still
black with rect: yes + frame: event, the fault is in Kotlin surface
handling** — that is the next investigation, not another Dart change.

## 3. Series search: cold-catalog race + filter surfacing (§8)

**Report (Matt, 2026-11-08 ~12:35 EST, screenshot 9635_8_zd4m.jpg):**
"game of thrones" scoped to Trex — Series → "No results in Trex —
Series". Fourth build to touch series search (#8, #9, #10, #13).

**Root causes (proven by the research probes, A/C groups):**
(a) Cold-catalog race: the 46,527-row unfiltered load is slow, and the
per-category sweep (batch 16) could not reach the last category
("|EN| TOP SERIES", id 1219) inside the 900 ms sweep deadline (at 16 it
covered only ~176 of 237 categories). (b) The hidden-category filter:
`_searchSeries`/`_appendSeriesMatches` filters rows via
`_isHiddenCategory` BEFORE matching, so a hidden category discards the
show silently — the empty state never said why.

**Fix** (`lib/media/iptv_client.dart`,
`lib/screens/search_screen.dart`, i18n):
- Search sweep batch size raised to **32** (`_searchSweepBatchSize`,
  passed as `batchSize:` to `_sweepCatalogCategories` from
  `_searchMovies`/`_searchSeries`/`_searchLive`; background crawl
  fallback stays at 16) so the 237-category sweep reaches the last
  category inside the 900 ms deadline.
- `_appendMovieMatches`/`_appendSeriesMatches`/`_appendLiveMatches` now
  take the `_SectionTrace` and count rows that match the query but sit in
  a hidden category (`trace.hiddenMatches`); added to `_SectionTrace` and
  `IptvSearchSectionDiagnostics`; new client helper
  `lastSearchHiddenMatchesForLibrary(libraryId)`.
- Search screen empty state: when scoped and `hiddenMatches > 0`, the
  subtitle becomes `t.search.hiddenByCategoryFilter` ("1 matching title
  is in a category you turned off" / "${count} matching titles are in
  categories you turned off") and an action button opens
  `IptvCategoriesScreen(connection: client.connection)` with label
  `t.iptvCategories.title(name: connection.displayName)`.

**Tests:** `test/services/iptv/iptv_build17_search_filter_test.dart` (2
tests: EN hidden → [] with `series.hiddenMatches == 1` and
`lastSearchHiddenMatchesForLibrary('iptv:conn-xt-1:series') == 1`; EN
shown → show returned, hidden 0). Probe file group C (C3 derivation
hole, C4 cold race) passes. **Verification run (series detail 2 +
probes 14 = 16 tests): ALL PASSED.**

**Honest limits:** the scoped-search path itself was checked correct by
code (not by a failing test — the cold race was the failing one). Whether
EN or category 1219 is hidden in Matt's MIGRATED state is still unknown
— it needs his Trex categories screenshot or the "Last search" reading
he was asked for on 2026-11-08 ~12:36 EST (still owed).

## 4. Toggle-off lag: client reuse on filter-only re-bind (§2)

**Report (Matt, 2026-11-08 ~12:28 EST):** turning categories off is
still laggy (the harness measured 203 ms per toggle in build #16, but
the phone still feels laggy).

**Root cause (research probe E1):** every toggle swapped the whole
client — re-warm (three 120 s HTTP calls + three `compute()` parses +
three disk writes: VOD 1046 ms, LIVE 299 ms, SERIES 350 ms, ~1695 ms
per swap on desktop) + `checkHealth` probe + guide reload.

**Fix** (`lib/media/iptv_client.dart`,
`lib/services/multi_server_manager.dart`): `IptvClient.connection` is
now mutable (was `final`) with new `updateConnection(Connection next)`
— throws `ArgumentError` when the id or data source differs (Xtream:
serverUrl/username/password; M3U: playlistUrl/epgUrl), so a data-source
change still replaces the client. `MultiServerManager.addIptvConnection`
tries the reuse path first: filter-only change → `updateConnection` +
`notifyCatalogRefreshed(userInitiated: true)` + return last known
health, with NO re-warm and NO health probe; data-source change → full
replace as before. (Dart has no `try-on-else` — the implementation uses
a `filterOnlyChange` boolean flag.) On the reuse path the last known
health stands in for the probe (a profile re-bind of an already-bound
connection also takes this path — correct, since a fresh probe would
return the same health unless the connection died since).

**Tests:** `test/services/iptv/iptv_build17_toggle_test.dart` (2 tests:
filter toggle reuses the identical client instance with zero new
unfiltered loads and the filter still applies; server-URL change
replaces the client and re-warms). 2/2 pass.

**Honest limits:** warm-up staggering (research14 E-1) NOT done — fix 1
fully avoids the swap for toggles, so it stays in the efficiency
backlog. The 203 ms in-harness toggle is now near-zero client work;
whatever lag remains on the phone is in the persist + notify + guide
re-filter path, which the phone will show.

## 5. Initials don't hide all categories (§3)

**Report (Matt, 2026-11-08 ~12:28 EST):** the category initials do NOT
turn off all the categories with those initials (same complaint as
v2.25.8).

**Root cause (research probes A1–A4, A6):** `_deriveCategoryInitial`
took the LAST matching segment (so "LIVE TV | EN | NEWS" derived NEWS,
not EN) and had no content-word denylist, so all-caps content words
(KIDS/NEWS/LIVE/HBO) became "region initials" — the initials list and
the hide filter disagreed about which categories an initial covers.

**Fix** (`lib/utils/iptv_initials.dart`): `_deriveCategoryInitial` now
returns the FIRST matching segment (was last-match-wins) and skips
denylisted content words; denylist = NEWS, KIDS, LIVE, HBO, TV, VIP,
HD, VOD, PPV, FHD, UHD, XXX (TV is required — existing build #13 test
`categoryInitial('TV | EN')` must be 'EN'). Denylist also applied in
`initialsMeetingThreshold()`. Stored hidden initials are NOT re-migrated
or deleted (inert entries left in place) — Matt's 161 hidden initials
are never touched.

**Tests:** 30 existing initials tests pass
(`test/utils/iptv_initials_test.dart`,
`iptv_build13_initials_test.dart`, `iptv_category_initials_test.dart`)
+ all 7 probe group-A tests pass (A1–A4, A5, A5b, A6).

**Caveat:** the denylist was chosen WITHOUT the parent's panel
enumeration of real category names ending in bare content words (probe
owed — see below). If the panel has categories whose REAL region is a
denylisted word, those categories lose their initial — the enumeration
decides whether the list needs trimming.

## 6. Collapsible Live TV / Movies / Series sections (§4)

**Report (Matt, 2026-11-08 ~12:28 EST):** "allow me to colapse live tv
movies and series so i can get to those categories faster".

**Fix** (`lib/screens/settings/iptv_categories_screen.dart`): `_section`
takes a `sectionId` ('live'/'movies'/'series'/'groups'); the header is
now an `InkWell` (tap toggles) with a chevron (`expand_more`/
`expand_less`) beside the title; collapsed → `SliverList.builder`
`itemCount = 1` (header only, rows not built — build #16
virtualization holds); the collapsed header keeps showing its count
('Live TV categories · 6 categories, 0 hidden'); collapsing changes no
counts and triggers no rebind. State persisted per connection in
SharedPreferences key `iptv_categories_collapsed:<connectionId>` (set of
section ids), loaded inside `_load()` before anything renders (no
flash-expanded-then-collapse on relaunch), saved fire-and-forget with
silent failure (display-only state). The initials section is NOT
collapsible (Matt asked for Live TV / Movies / Series only).

**Tests:** `test/screens/settings/iptv_build17_categories_collapse_test.dart`
(4 tests, reusing the categories-screen harness + fake API: Live 6,
Movies 7, Series 9, initials EN ×11 / NF ×9): collapse Live TV → its 6
rows gone, header + count remain, Movies/Series untouched, switch-tile
count 24→18; collapse persists across a fresh pump (relaunch) and
expanding restores rows; toggling the EN initial while Live TV is
collapsed updates the collapsed header to "6 categories, 6 hidden";
collapsing Series never collapses Live TV/Movies. 4/4 pass.

## 7. Guide channel long-press menu (§9)

**Report (Matt, 2026-11-08 ~12:49 EST):** replace guide
long-press-to-favorite with a dropdown menu on long-press: "Hide
channel" + "Add to favourites" (or "Remove from favourites"), built to
take more items later.

**Root cause:** there was no menu and no per-channel hide store — a
long-press toggled the favorite immediately (TV SELECT hold and the
context-menu key did the same).

**Fix:**
- **Hide store** (`lib/media/iptv_live_tv.dart`): NEW
  `iptv_hidden_channels:<connectionId>` (SharedPreferences string list,
  same pattern as `iptv_fav_channels:<connectionId>`). A channel is
  identified by the SAME key derivation as favourites
  (`favoriteChannelKey` of the favorite source + channel key, factored
  into a sync `_favoriteChannelSource` getter so both agree) — per
  connection, so hiding a Trex channel never hides a Plex one. In-memory
  set loaded lazily (`loadHiddenChannels`, no-op when loaded);
  `hideChannel` / `unhideChannel` / `unhideChannelKey` (by channel key,
  for the Settings list) / `unhideAllChannels` / `isHiddenChannel` /
  `isHiddenChannelKey` (sync, for the search funnel). Hide wins over
  favorite for display; the favorite is kept, so un-hiding restores it.
- **Honored in** guide rows (`live_tv_screen.dart`: `_visibleChannels`
  getter filters `_channels` by the hidden set before the favorites /
  source / category filters — so it composes with §11 and the favorites
  filter; the search sheet reads `_visibleChannels` too, so a hidden
  channel has no guide row to jump to), Live TV search
  (`iptv_client.dart`: `_searchLive` loads the set once, then
  `_appendLiveMatches` skips hidden streams in both the warm and cold
  paths; `_searchM3uEntries` does the same for M3U), and the
  all-hidden empty state (new branch before the favorites one:
  "All channels hidden" + "Unhide all" action). NOT honored in the
  mini-player or EPG fetching. Survives rebind/refresh (connection-owned
  prefs, re-read at bind like favourites).
- **Menu** (`lib/screens/livetv/tabs/guide_tab.dart`): built from an
  extensible `List<ChannelMenuItem>` (id / label / icon / action); v1
  items "Hide channel" (IPTV only — the hide store lives on
  `IptvLiveTvSupport`, so Plex/Jellyfin/Emby channels get the favorite
  item only) + "Add to favourites" / "Remove from favourites" (reads
  `isFavoriteChannel`). Presentation: `showMenu` dropdown anchored to
  the cell rect (builder context) or the screen centre for keyboard
  triggers. All four triggers changed together: `_buildChannelCell`
  `onLongPress` (covers touch long-press AND right-click, both driven by
  the same `_ChannelCell.onLongPress` callback),
  `_handleFocusedChannelSelectKey` (TV SELECT hold),
  `_handleFocusedChannelContextMenuKey` (gamepad X / keyboard Menu).
  Long-press opens the menu — it never toggles anything directly.
- **Un-hide path:** Settings → IPTV, new `_HiddenChannelsTile` per IPTV
  connection (`lib/screens/settings/iptv_settings_screen.dart`): count
  loads on first build (cheap prefs read); channel names resolve from
  the live lineup only when first expanded (disk-first; a channel gone
  from the playlist keeps its raw key); per-row Unhide + "Unhide all".
  Hiding shows a brief "… hidden — Undo" snackbar (`showSnackBar` gained
  optional `actionLabel` + `onAction`, `lib/utils/snackbar_helper.dart`).
- **Scope decision:** hiding is IPTV-only in this build (the store lives
  on `IptvLiveTvSupport`). If Matt wants to hide Plex channels, that is
  a follow-up — the menu is built to take it.

**Tests:**
- `test/screens/livetv/iptv_build17_channel_menu_test.dart` (5 tests,
  real GuideTab + real IptvClient + fake panel): long-press opens the
  menu without toggling anything; Hide calls `onHideChannel` only; Add
  to favourites calls `onToggleFavorite` only; already-favorited shows
  "Remove from favourites"; non-IPTV channel has no Hide item. 5/5 pass.
- `test/services/iptv/iptv_build17_hidden_channels_test.dart` (3 tests):
  hide persists across a client rebind (fresh client re-reads the store);
  hidden channel never appears in Live TV search results; unhide by key
  + unhide-all restore the channels. 3/3 pass.
- **FAILING-FIRST PROVEN:** a base-API-only version of the menu test
  (long-press must not toggle the favorite) run in a temp worktree at
  e97112171 FAILED (long-press toggles immediately on v2.25.12) and the
  full file passes on the fix. Temp worktree removed afterwards.
- Pre-existing tests updated for the intentional behavior change:
  `live_tv_screen_test.dart` (favorite write-failure test now goes
  long-press → menu → "Add to favourites"), `guide_tab_test.dart` (TV
  SELECT hold + context-menu key now open the menu, then the menu item
  toggles once).

## 8. EPG feels empty (§10)

**Report (Matt, 2026-11-08 ~12:51 EST):** the guide feels empty — many
channels show "No information" — while TiviMate loads programmes for
the same channels.

**Root causes (research §10):** (a) the xmltv feed match is exact
tvg-id only — a feed whose channel ids are plain names ("Comedy Central
HD") never matches a playlist whose names carry region prefixes ("US|
COMEDY CENTRAL HD"). (b) There was no coverage number anywhere, so
"the guide feels empty" could not be measured.

**Fix** (`lib/media/iptv_live_tv.dart`, `lib/screens/livetv/tabs/guide_tab.dart`,
`lib/screens/settings/iptv_settings_screen.dart`, i18n):
- `normalizeEpgChannelName`: strips a leading `|XX| ` tag, then a
  leading `XX| ` tag (up to 15 chars before the `|`), lowercases, strips
  non-alphanumerics. "US| COMEDY CENTRAL HD" and "Comedy Central HD"
  both → "comedycentralhd". No fuzzy matching — the normalized strings
  must be exactly equal.
- `_CachedXmltvGuide.byNormalizedName` index (keyed by the normalized
  program channel id); `_CachedChannelEpg.source` field (persisted in
  toJson/fromJson, defaults `unknown` for old files).
- `_fetchXtreamXmltvPrograms` / `_fetchXtreamEpg` / `_fetchM3uEpg` now
  return `({List<LiveTvProgram> programs, IptvEpgSource source})`: exact
  tvg-id/stream-id first → `feedById`; else normalized-name fallback →
  `feedByName`; else `none`. The source names what actually served
  programmes AFTER window filtering (a match whose programmes all fall
  outside the window still counts as `none`). Short-EPG wins when
  non-empty; feed failure with short-EPG answered empty → `none`; both
  failed → rethrow.
- `IptvGuideCoverage` + `IptvLiveTvSupport.guideCoverage()` — computed
  over the loaded EPG cache (the guide only fetches visible rows, so this
  set IS the visible guide): total, withPrograms, split by source
  (feedById / feedByName / shortEpg / none / unknown),
  `percentWithPrograms`, `feedChannelIds` (distinct channel-id count of
  the last loaded XMLTV feed — context, not a denominator).
- `fetchEpgForChannel` stores the source in the cache entry.
- Guide rows: when `real.isEmpty` (fetch finished, both sources answered
  empty) the row renders ONE `_noGuideDataPlaceholder` block spanning the
  whole window (title `t.liveTv.noGuideDataForChannel` = "No guide data
  for this channel", `isPlaceholder: true`) instead of one "No
  information available" block per hour. Partial EPG still gets hourly
  "No information" blocks in uncovered hours. Failed channels still
  short-circuit to the tap-to-retry row.
- Settings tile: `_IptvCatalogDiagnosticsState._buildGuideCoverage`
  (Settings → IPTV, after "Last search"): title + percent line + split
  line + optional unknown line + feed-ids line; "No guide data loaded
  yet — open Live TV…" when total == 0.

**Tests:** `test/services/iptv/iptv_build17_epg_coverage_test.dart` (6
tests): normalizer (6 cases incl. 'UK-NOWTV| COMEDY CENTRAL HD' →
'comedycentralhd', 'A&E HD' → 'aehd'); name-shaped feed ids match by
name; exact tvg-id still wins; short-EPG serves its channel; neither
source → []; coverage split over 5 channels (total 5, withPrograms 4,
80%, byId 1, byName 2, shortEpg 1, none 1, unknown 0, feedChannelIds 3).
6/6 pass. **FAILING-FIRST PROVEN at base:** stripped variant run in a
temp worktree at e97112171 — name-fallback test FAILED, exact-id control
PASSED (1 pass / 1 fail). Temp worktree removed afterwards.
`test/screens/livetv/guide_tab_iptv_test.dart` updated for the new block
(7 pass / 2 tap tests needed expectation fixes — see below): 9/9 pass.

**Test-discovery note (worth keeping):** the two tap tests failed at
first because the whole-window block IS currently airing (beginsAt =
gridStart in the past, endsAt = gridEnd in the future), so the detail
sheet's tune button reads "Play" (`t.common.play`) and catch-up reads
"Start from beginning" — not "Watch Channel" / "Watch from start (X min
ago)" as the old first-hour-block tests expected. The sheet DOES open;
the expectations were wrong for the new block's airing state. A
temporary debug test (`iptv_build17_epg_debug_test.dart`) hung on
`pumpAndSettle` while the EPG chain was mid-flight — the same lesson as
the menu tests: settle the EPG chain with the Completer pattern
(`waitForEpgCalls` + `completeEmpty`) BEFORE calling `pumpAndSettle`.
Debug test deleted, not part of the build.

**Honest limits:** name fallback is exact-normalized equality only —
misspelled or reworded channel names still miss. The tvg-id match rate
of the real feed is unproven (probe owed — §10.1).

## 9. Guide category switcher — LIVE TV categories only (§11)

**Report (Matt, 2026-11-08 ~12:52 EST):** add a category picker in the
Live TV guide to change the viewed category. Scoped to LIVE TV
categories only.

**Fix** (`lib/models/livetv_channel.dart`,
`lib/media/iptv_client.dart`, `lib/screens/livetv/guide_category.dart`
(NEW), `lib/screens/livetv/live_tv_screen.dart`,
`lib/screens/livetv/tabs/guide_tab.dart`, i18n):
- `LiveTvChannel.categoryId` (runtime-only, `@JsonKey(includeFromJson:
  false, includeToJson: false)`, constructor default null, `copyWith`
  passthrough — no codegen needed, plain class). Set in
  `iptvChannels()`: Xtream → `stream.categoryId`; M3U →
  `entry.groupTitle`.
- `IptvClient.visibleLiveCategories()`: live categories filtered by the
  SAME `_isHiddenCategory` rule as the guide rows (Xtream:
  `liveCategories()` filtered; M3U: `m3uGroups()` filtered via
  `_isHiddenGroup`); returns `List<({String id, String name})>`.
- NEW `lib/screens/livetv/guide_category.dart`: `GuideCategoryEntry`
  typedef `({String serverId, String categoryId, String label})` + pure
  `filterGuideChannels({channels, sourceId, category})` — in-memory only,
  never re-fetches; a category id means nothing on another source; Plex
  channels (categoryId null) never match a selected category.
- `LiveTvScreen`: `_selectedGuideCategory` (reset on every source change
  — picker chips, search-jump fallback, server-gone handler);
  `_guideCategoriesByServer` map loaded by `_loadGuideCategories()`
  after channels load (unawaited, disk-first, no extra network when
  warm; reloads with channels on catalog changes; drops a selection
  whose category went away); `_guideCategoryEntries` getter (per-source
  or union; names colliding across sources get a "Trex — US" source
  prefix, bare names otherwise); `_sourceFilteredChannels` +
  `_searchSheetChannels` now use `filterGuideChannels` (search runs
  within the selected category); `_guideShowsCategoryEmptyState` +
  EmptyStateWidget branch (`category_rounded` icon,
  `t.liveTv.noChannelsInCategory` / `noChannelsInCategoryHint`, action
  "Show all categories" clearing the selection) placed BEFORE the
  favorites empty state.
- `GuideTab`: new params `guideCategories` (default `[]`),
  `selectedGuideCategory`, `onSelectGuideCategory`;
  `_buildCategoryPicker()` chip row (horizontal SingleChildScrollView,
  "All categories" + entries) in `_buildGuideGrid` between the
  mini-player slot and `_buildTimeNavigation`; hidden when the list is
  empty (Plex-only lineups).

**Tests:** `test/utils/guide_category_filter_test.dart` (7 tests: no
filter, source only, category only, same id on another source never
matches, Plex never matches, source+category compose, source+other-source
category is empty) 7/7 pass;
`test/services/iptv/iptv_build17_guide_category_test.dart` (7 tests:
Xtream visibleLiveCategories all/hidden-by-id/hidden-by-initial,
iptvChannels carries categoryId, hidden category's channels gone; M3U
groups as entries + channels carry group as categoryId, hidden group
gone — M3U via loopback HttpServer + `_RealHttpOverrides`, modeled on
`iptv_epg_test.dart`) 7/7 pass.

## 10. Series detail episodes (§12)

**Report (Matt, 2026-11-08 ~12:54 EST, screenshot 9637_10_1ngw.jpg):**
series opens from Recommended ("D+ - Secrets of the Whales (US)"), S1E1
play button works, but the Episodes section treats the episode like a
season header ("D+ - Secrets of the Whales (US) - S01E01" chip) and shows
"No episodes found" — no selectable episode rows.

**Root cause (proven by the parent's probe):** the panel shape is clean
— `get_series_info` for series_id 9483 returns episodes as a DICT keyed
by season-number strings (`{'1': 4 episodes}`), episode titles carrying
the " - S01E01" suffix — exactly what `XtreamSeriesInfo.fromJson`
already expects. The bug is app-side: `fetchChildren(series)` flattened
all episodes into one list, so the detail screen rendered each episode
as a season tab, and fetching that "season"'s children returned []
("No episodes found").

**Fix** (`lib/media/iptv_client.dart`): `fetchChildren('series:<id>')`
now returns one synthetic season item per season (id
`'season:<seriesId>:<n>'`, kind `MediaKind.season`, title `'Season N'`,
`parentId` `'series:<seriesId>'`, `index` = season number, `leafCount` =
episode count, server/library fields copied from the series item);
`fetchChildren('season:<seriesId>:<n>')` returns that season's episodes
(sorted by episodeNum). New memoized `_seriesInfo(seriesId)` (evicted on
error, cleared in `clearCatalogCache`) so one series detail does not pay
one get_series_info per season. `fetchChildrenPage` slices the season
episodes for the season pager. `fetchPlayableDescendants` walks both, so
downloads/sync/queue callers still get leaves; the S1E1 top play button
keeps working (it plays the first episode). No parser change.

**Tests:** `test/services/iptv/iptv_build17_series_detail_test.dart` (2
tests: Whales shape series 9483, 1 season / 4 episodes with " - S01E01"
titles; two-season fixture). 2/2 pass. Pre-existing
`test/services/iptv/iptv_stage2_test.dart` updated for the intentional
contract change (its `fetchChildren('series:10')` expectation was the
old flat list; it now asserts seasons then per-season episodes, keeping
the stripped-parent-title assertions).

## Version / changelog

- `pubspec.yaml`: 2.25.12+169 → **2.25.13+170**.
- `lib/i18n/en.i18n.json` + slang regen: new `changelog2263` (newest
  first) + About entry in `lib/screens/settings/about_screen.dart`.
  The mini-player line says plainly that it is still unproven on a real
  phone and points at the diagnostic — no "should fix".
- New slang strings (all in `en.i18n.json`, regen verified):
  `search.hiddenByCategoryFilter`, `iptv.miniPlayerMissingRecording`,
  `iptv.miniPlayerMissingRecordingNoProgramme`,
  `iptv.miniPlayerLineBusy`, `iptv.miniPlayerWatchLive`,
  `iptv.miniPlayerRectValues`, `liveTv.allCategories`,
  `liveTv.noChannelsInCategory`, `liveTv.noChannelsInCategoryHint`,
  `liveTv.showAllCategories`, `liveTv.noGuideDataForChannel`,
  `liveTv.hideChannel`, `liveTv.unhide`, `liveTv.allChannelsHidden`,
  `liveTv.allChannelsHiddenHint`, `liveTv.unhideAllChannels`,
  `iptv.channelHidden`, `iptv.hiddenChannelsTitle`,
  `iptv.hiddenChannelsNone`, `iptv.hiddenChannelsCount`,
  `iptv.unhideAll`, `common.undo`,
  `iptv.guideCoverageTitle/None/Line/Split/Unknown/FeedIds`.

## Verification (builder's own runs, worktree `plezy-tv-build17`)

- `flutter analyze`: **49 issues — exactly the pre-existing
  wakelock_plus baseline, no new issues.** (Seven build #17 issues found
  and fixed during the run: one unnecessary `!` in search_screen, one
  deprecated `.alpha` in the mini-player test, two unused imports, one
  dead null-aware in the EPG coverage test, one unused local in the probe
  file.)
- Suites, sequential, `TMPDIR=~/workspace/tmp_flutter`:
  - `test/services/iptv/`: **222/222 pass** (includes probes 14/14,
    hidden channels 3/3, search filter 2/2, toggle 2/2, series detail
    2/2, guide category 7/7, EPG coverage 6/6, stage2 updated).
  - `test/screens/livetv/`: **102/102 pass** (includes guide_tab_iptv
    9/9, catchup 5/5, mini-player 3/3, channel menu 5/5, mini-player
    (build #12) updated, screen favorites updated, guide_tab TV keys
    updated).
  - `test/screens/settings/iptv_build17_categories_collapse_test.dart`
    + `test/utils/guide_category_filter_test.dart`: **11/11 pass**.
  - 30 existing initials tests pass.
- Probe file: `test/services/iptv/iptv_build17_probes_test.dart` copied
  from the research worktree and kept — **14/14 pass after the fix**
  (7 pass / 7 fail at base).
- Pre-existing tests updated for intentional behavior changes (§§ 9, 10,
  12 — see each section). No other pre-existing test was touched.
- Kotlin: NO Kotlin changes in this build (the §6 fix is Dart-only;
  the Kotlin surface-strand half is explicitly UNPROVEN, see §2 above).
  Codemagic remains the native compile gate.
- NOT run: the full suite (build #13's full run was 8566 pass / 20
  pre-existing fails; the touched directories are the ones that matter
  for this build — the independent tester runs the wider suites).

## Phone checks owed (do not ship without the tester's pass + these)

1. Mini-player on a live tune, Fold cover + unfolded + 16:9: video
   visible in the hole (not black). Settings → IPTV → Mini-player row:
   "Video rect sent: yes" + rect values + "First frame: revealed" — if
   it is still black with rect: yes + frame: event, the fault is in
   Kotlin surface handling.
2. Catch-up on a programme with no recording: "No recording available
   for \<programme\> on \<channel\>" + Watch live (no retry loop). On a
   programme WITH a recording (e.g. A&E HD): plays from the start.
3. Series search "game of thrones" scoped to Trex — Series AND unscoped:
   the show returns. If it returns [], screenshot the "Last search" row
   (Settings → IPTV) — it now says whether matches were hidden by
   turned-off categories.
4. Toggle a category off: no long reload; the change applies immediately.
5. Category initials: turning off EN hides every EN category (check the
   Trex categories screen counts).
6. Trex categories screen: collapse/expand Live TV / Movies / Series;
   collapsed state survives a relaunch.
7. Long-press a guide channel → menu (Hide channel / Add to
   favourites); hide one → its row disappears, it stays hidden after a
   rebind/refresh, it never appears in Live TV search; Settings → IPTV →
   Hidden channels → Unhide brings it back.
8. Guide: category picker chips; picking a category filters the loaded
   rows (no re-fetch); hidden categories never appear in the picker.
9. Guide coverage: Settings → IPTV → Guide coverage — percent + split
   should be visibly fuller than v2.25.12's "No information" rows.
10. Series detail ("D+ - Secrets of the Whales (US)"): real Season rows
    with selectable episode rows; S1E1 play button still works.
11. Carry-over from v2.25.11 §9: Plex/Trex libraries after toggle
    storms; guide search under Trex/HOME PC/All; EPG time-to-first
    programmes; long-press favourites; channel-name tap; whether the
    v2.25.9 startup crash recurs (Settings → Advanced → Last crash if
    it does).

## Panel questions still owed (parent probes — NOT asked of any helper)

1. **§5.5 duration clamp:** one HEAD of the app-format timeshift URL
   for Comedy Central HD, start = a completed programme's start (e.g.
   The Office 9:30), duration = 30 (programme duration). 200 → clamp
   duration to programme end. 404 → the channel's archive lacks it.
2. **§10.1 tvg-id match rate:** count distinct channel ids in xmltv.php
   vs the `epg_channel_id` values of the live channels (redacted counts
   only) + the actual feed channel-id format.
3. **§3.1 category names ending in bare content words:** the real
   category names (redacted list) that end in NEWS / KIDS / LIVE / HBO /
   similar — decides whether the §5 denylist needs trimming.

## UNPROVEN in this build (marked as such in the changelog)

- Whether mpv presents a frame onto the native surface in the
  mini-player (§2 — Dart-side evidence only; Kotlin strand untouched).
- Whether the duration clamp changes catch-up on this panel (§5.5 probe
  owed).
- The tvg-id match rate of the xmltv feed (§10.1 probe owed).
- Whether EN (or category 1219) is hidden in Matt's migrated state
  (needs his Trex categories screenshot or the Last-search reading).
- The denylist's safety against real category names (§3.1 probe owed).
