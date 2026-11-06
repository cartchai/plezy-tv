# PlezTV Build #9 Notes — v2.25.5 (IN PROGRESS, uncommitted)

Parent owns version bump (2.25.5+162), commit, push, Codemagic, delivery.
This build answers Matt's v2.25.4 report (2026-11-06 ~13:16 EST, after
reinstall): (1) "Search hasn't been worked on at all, there's no option to
search certain libraries, and it still can't search tv/series"; (2) "make it
so i can do catch up, the feature is missing"; (3) "make sure the player can
scrub properly for the catch up function".

## Task 1(a) — series search still returns nothing

### Diagnosis (proven by failing-first tests, not just code reading)

Build #8 fixed the merge cap (movies no longer starve series) and gave each
section its own 50s budget — but the section still returns `[]` on a cold
catalog, every time, for a structural reason:

- `_searchSeries` awaits `_seriesList()` — the FULL 46k-row catalog — before
  it filters a single title. On the real provider the unfiltered
  `get_series` call is either very slow (tens of seconds on LTE for 46k
  rows) or returns `[]` (the same panel behaviour build #7 found for VOD at
  199k rows), in which case `_loadSeries` crawls per-category in batches of
  8 — minutes for the whole catalog.
- The outer `.timeout(searchSectionBudget, onTimeout: () => [])` then fires
  and the section returns `[]`. The catalog fetch keeps warming the cache
  in the background, but the NEXT search usually hits the same wall: the
  background crawl is still running (it is not finished, so there is no
  warm catalog to filter), and the search races the same 50s budget again.
  On a cold start Matt can search all day and never see a series match —
  the budget discards partial progress instead of returning it.

Proved with fixtures in `test/services/iptv/iptv_stage2_test.dart`
(`_ColdCatalogFakeXtreamApi`): unfiltered `get_series` never answers within
the budget while per-category calls return matches fast → old code returns
`[]`; unfiltered `[]` + a slow per-category crawl → old code returns `[]`.

### Fix

`_searchMovies` / `_searchSeries` now take two paths:

- **Warm catalog** (a full load already completed): unchanged — await the
  cached list and filter. Tracked by `_vodStreamsLoaded` /
  `_seriesListLoaded`, set only on a non-empty completed load (an empty
  result is never treated as loaded, same as the existing never-cache-empty
  rule).
- **Cold catalog**: kick the full load off in the background (`unawaited`)
  so the next search / browsing finds a warm catalog, and sweep
  per-category NOW — categories in parallel batches of 8 (the existing
  `_catalogFallbackBatchSize`), fail-open per category, filtering by the
  query as each batch lands, stopping early at `limit` or at a sweep
  deadline of 90% of `searchSectionBudget` so partial matches are
  RETURNED instead of being discarded by the outer timeout.

Shared helper `_sweepCatalogCategories<T>` does the batched sweep; the
per-row filtering (disabled categories/initials, needle match, favourite
flag, category-name prefix strip) is the same code as the warm path.

Cost note: on a cold search the background full load and the sweep issue
overlapping per-category reads (both are idempotent GETs). Worth it — the
first search returns matches and the second search is instant.

### Tests

- `test/services/iptv/iptv_stage2_test.dart` (53/53 in that file):
  cold-catalog fixtures — series search returns matches from a slow/large
  fixture catalog (unfiltered call never answers, per-category calls do);
  a stalled per-category crawl returns the matches that already landed;
  a failing series leg does not hide the movies leg (and vice versa);
  per-category failure is fail-open; sweep stops at `limit`; the
  pre-existing slow-series test still passes (first search movies only,
  second finds the series once warmed). Both new tests were verified
  FAILING on the old code before the fix (51 pass / 2 fail → 53 pass).

## Task 1(b) — always-visible library scope

### Design choice

A scope strip sits directly under the search field on the Search screen,
rendered whenever libraries are loaded — INDEPENDENT of whether a search
has run or returned anything. It lists **All libraries** plus one chip per
visible library (title as shown in Libraries, e.g. "Trex — Series").
Selecting a scope re-runs the current query scoped to that library, or
arms the scope for the next query if none is running. A scoped search with
no hits shows an honest empty state — "No results in Trex — Series" —
never a hidden option and never the generic flat list.

Scoping is enforced at the aggregation, not by post-filtering the screen:
the selected library's `globalKey` is kept and every other library's
`globalKey` is added to `hiddenLibraryIds` for that query (unioned with
the user's own hidden libraries). The existing `_withoutHiddenLibraries`
filter in `DataAggregationService` then drops the other libraries'
candidates AND hits, and the IPTV client skips the excluded sections
entirely (no wasted catalog fetch for a library Matt did not ask for).
The scope survives query refinements and clearing the field; tapping
"All libraries" clears it. A scope whose library is no longer loaded (or
was hidden) reads as All rather than hiding everything. Hidden libraries
are never offered as a scope chip.

Deliberate boundary: the scope lists LIBRARIES. Live TV is not a library
in this codebase (fetchLibraries never returns it, by design), so there is
no "Live TV" scope chip — and Xtream live channels are not searchable
today (only M3U channel entries are). Adding live-channel search is a
follow-up, not part of this build.

### Tests

- `test/screens/search_screen_test.dart` (30/30 green): scope strip
  shows All + library chips before any search; selecting "Anime" re-runs
  the query scoped (only that library's results, then All restores both);
  selecting a scope with no results shows the honest "No results in
  Anime" empty state with the strip still visible. (One test pump
  updated to provide LibrariesProvider, which the screen now watches in
  build.)

## Task 2 — catch-up is missing

### Diagnosis

Catch-up existed as plumbing, not as a feature Matt could reach:

1. **No entry point for real programmes.** `_catchUpActionFor`
   (`lib/screens/livetv/tabs/guide_tab.dart`) returned a catch-up action
   ONLY for "No information" placeholder programmes on catch-up channels.
   Any programme WITH EPG data — i.e. every programme Matt can actually
   see once the guide loads — got NO catch-up entry. As the EPG improved,
   the only catch-up entry point disappeared. Tapping a past programme
   opened the details sheet, which shows "Watch from start" only when
   `onCatchUp` is non-null — and it was null for real programmes.
2. **`tv_archive_duration` is in DAYS, the code treats it as SECONDS.**
   Xtream's `tv_archive_duration` is the catch-up window in days
   (deepwiki pvr.dispatcharr docs: "Catchup window duration in days";
   xui.live docs: "for how many days"; example value 7). The code stored
   the raw value as `archiveDurationSeconds` and used it as the seekable
   window and the timeshift duration clamp. With the provider's typical
   value of 7, the seekable window was **7 seconds** and every catch-up
   clamped to a 1-minute segment at the live edge — catch-up silently
   played live. This is the bug that made catch-up LOOK missing even
   where an entry point existed.
3. The rest of the chain was already wired and correct: `XtreamApi`
   timeshift URL builders (`/timeshift/`, UTC start), `playback_start.dart`
   handling `catchUpStartEpoch` via `liveTvCatchUpOffsetSeconds` →
   `streamUrlAt` → `/timeshift/` URL, and the player start path.

### Fix

- `XtreamLiveStream.fromJson`: convert `tv_archive_duration` days → seconds
  (`* 86400`), with a passthrough guard — a raw value > 366 is already
  seconds (some panels return seconds) and is kept as-is. Field comment
  updated; the stored value stays seconds everywhere downstream.
- `_catchUpActionFor`: any programme that has already started
  (`beginsAt < now`) on a catch-up channel (`hasCatchUp`) gets the
  catch-up action — past programmes start at their beginning, the
  currently-airing programme starts at its beginning ("Start from
  beginning", see below). Future programmes still get none.
  Placeholders keep their existing path.
- **Entry point (Matt, 2026-11-06 ~13:31 EST): catch-up is a clickable
  option NEXT TO Play Now.** The programme details sheet renders its
  actions in one `Wrap` row: Play (live programme) / Watch Channel (past
  programme) first, catch-up second. The widened `_catchUpActionFor`
  makes the catch-up button appear there for every started programme on
  a catch-up channel — visible and tappable beside the play action, not
  buried in a menu and not only on hour blocks. (There is no "Play Now"
  string in the app — Matt's name for the sheet's Play / Watch Channel
  button. A bare channel row has no action sheet; tapping it tunes
  directly, and its current programme's block is the channel-level
  catch-up entry via the same sheet. On TV, tapping a live programme
  tunes directly; the sheet — and Start from beginning — is reached via
  long-press, the existing TV details gesture.)
- **Label (Matt, 2026-11-06 ~13:32 EST): for a programme ALREADY
  PLAYING, catch-up reads "Start from beginning".** The details sheet
  branches on `program.isCurrentlyAiring`: live → new string
  `t.liveTv.startFromBeginning` ("Start from beginning"); past →
  existing `t.liveTv.watchFromStart(minutes:)` ("Watch from start (X min
  ago)"). BOTH resolve to the same thing — `_catchUpToProgram` with
  `catchUpStartEpoch = beginsAt`, i.e. the beginning of that programme's
  block (the same block the Task 3 scrubber spans). It is still catch-up
  underneath (timeshift to the block start), just labelled and behaving
  as start-from-beginning for a live programme.
- One-stream limit (max_connections=1): catch-up opens ONE stream — the
  timeshift URL replaces the live tune in the single player route; the
  guide cannot launch a second player while one is open (the player is a
  pushed route above the guide). No second stream is ever opened.

### Tests

- `test/services/iptv/iptv_stage2_test.dart`: `tv_archive_duration: 7`
  parses to 604800 seconds; 1 → 86400; 0/absent → 0; a seconds-scale
  value (> 366) passes through unchanged.
- `test/screens/livetv/guide_tab_iptv_test.dart` (62/62 green for the
  whole `test/screens/livetv/` dir): details sheet shows "Watch from
  start" next to "Watch Channel" for a past real programme on a catch-up
  channel; "Start from beginning" next to "Play" for a currently-airing
  programme; no catch-up action for a future programme or a non-catch-up
  channel. Fixture-only timeshift URL tests; NO real playback.

## Task 3 — player scrubbing for catch-up

### Diagnosis

Scrubbing a catch-up stream was broken by the same two defects, plus one
more:

1. **The 7-second window (Task 2 #2).** The `CaptureBuffer` seek window
   was `seekStartSeconds: -7` (archiveDurationSeconds = 7). The live
   timeline bar spanned 7 seconds, offsets clamped to -7s, and every
   catch-up segment was 1 minute at the live edge. The days→seconds fix
   restores the real window (7 days → seekable back 7 days).
2. **The live edge went stale.** `IptvLiveTvPlaybackSession.reportTimeline`
   returned null, so the player's 10s timeline heartbeat never refreshed
   `_live.captureBuffer` — the buffer was frozen at tune time
   (`seekEndSeconds: 0`, `startedAt` fixed). After 10 minutes of catch-up
   viewing the bar's end (and "Jump to live") was 10 minutes stale.
3. **The bar spanned the whole archive (Matt, 2026-11-06 ~13:30 EST).**
   Even with the window fixed, a 7-day-wide bar is useless for scrubbing
   to a show: the scrubber must cover the CURRENT BLOCK — the programme
   block for whatever show is on, or the one-hour "No information"
   block when there is no guide data — so Matt can scrub back/forward
   within that time slot.
4. The seek machinery itself is sound and was NOT changed: `_seekLivePosition`
   rebuilds the timeshift URL at the requested offset, `LiveTimelineBar`
   maps drag position → epoch via `epochForPosition`, `markStreamRestartedAtLiveEdge`
   calibrates the clock open. `force-seekable=no` is left alone — the live
   bar does not consult mpv's seekable flag, and changing it risks live
   DVR behaviour for Plex.

### Fix

- `IptvLiveTvPlaybackSession.captureBuffer` is now computed at read time:
  `seekEndSeconds = now - startedAt` (clamped ≥ 0), so the window's end is
  always "now"; `seekStartSeconds = -archiveDurationSeconds` (now days).
- `reportTimeline` returns a `LiveTimelineUpdate` carrying the fresh
  buffer instead of null, so the existing 10s heartbeat refreshes
  `_live.captureBuffer` and `atLiveEdge` — the same commit path Plex uses.
  No other caller is affected (the report path only commits the update).
- **Block-bounded scrubber (Matt's refinement): how the range is derived.**
  - `liveScrubBlock(programs, now)` (`lib/utils/live_tv_scrub_block.dart`,
    pure, unit-tested): the programme covering `now` → its
    `[beginsAt, endsAt]`; nothing covering now — no EPG, a gap between
    programmes, or an open-ended programme — → the current clock-hour
    block `[hourFloor(now), hourFloor(now)+3600]`, the same hour the guide
    renders as "No information available".
  - The player resolves the block in `_resolveLiveBlock`
    (`live_tv.dart`): only for IPTV catch-up sessions
    (`IptvLiveTvPlaybackSession` + `canTimeShift`) — Plex/Jellyfin keep
    the capture-window bar. It fetches the tuned channel's EPG via
    `IptvLiveTvSupport.fetchEpgForChannel` over `[now-6h, now+2h]` (the
    persisted cache the guide already loaded, so coming from the guide
    this is cheap; a failure falls back to the hour block). The block
    lives on `LiveTvSessionState` (`scrubBlockStartEpoch` /
    `scrubBlockEndEpoch`, cleared on every `adoptSession` so a zap
    re-resolves for the new channel). The 10s heartbeat re-resolves when
    the block ends (programme rolled over) and retries a failed
    resolution at most once a minute.
  - The range is threaded player → `PlexVideoControls` →
    desktop/mobile controls → `LiveTimelineBar` as optional
    `visibleStartEpoch` / `visibleEndEpoch`. The bar uses them for its
    range when both are set and valid, otherwise the capture buffer
    window (existing behaviour everywhere else). Drag targets, key
    seeks, and semantics all read the same range, so the whole bar is
    block-bounded. The ±skip window (`_liveSeekBounds`) follows the
    block too, capped at the live edge.
  - Seeks still clamp to the capture buffer in `_seekLivePosition`
    (archive → now), so dragging past the live edge inside a still-airing
    block lands on live, never in the future. The unplayable future part
    of a still-airing block is not shaded differently — noted as a
    cosmetic follow-up, not a behaviour gap.

### Tests

- `test/services/iptv/iptv_live_session_test.dart` (NEW, 5/5): buffer
  window spans the archive in days; buffer end advances with wall-clock
  time; `reportTimeline` returns an update carrying the fresh buffer
  (not null); no archive → no buffer + null report; `streamUrlAt`
  clamps the timeshift window to the archive (7 days + 1h back → 10080
  minutes).
- `test/utils/live_tv_scrub_block_test.dart` (NEW, 7/7): programme
  covering now is the block (incl. the beginsAt boundary); a programme
  that just ended is not; gaps / no EPG / open-ended programme fall back
  to the clock hour; the covering programme wins over its neighbours.
- `test/widgets/live_timeline_bar_test.dart` (9/9): a pinned visible
  block bounds drags (mid-bar drag on a 7-day buffer seeks to the block
  middle, not the buffer middle); an invalid block falls back to the
  buffer window.
- The player-side resolution (`_resolveLiveBlock`, heartbeat
  re-resolution) has NO widget test — pumping the full player screen
  needs mpv mocks this codebase does not have; it is covered by the
  pure-helper + bar tests plus code review, and needs Matt's phone.

### What is proven by test vs what needs Matt's phone

- Proven by test: days→seconds conversion, sweep returning partial
  matches under a budget, library scope filtering, catch-up action
  availability + labels ("Watch from start" past / "Start from
  beginning" live), buffer window/refresh math, timeshift URL shape and
  clamping, block derivation (programme vs hour fallback), bar range
  following a pinned block.
- NEEDS MATT'S PHONE (cannot be proven in a harness): series search
  against the real 46k-row Trex catalog on LTE (cold timing); whether
  the provider's per-category series calls answer fast enough for the
  sweep to find matches inside 45s; catch-up actually playing a
  timeshift segment on the real panel (URL shape is per docs, the panel's
  exact behaviour is unverified); scrubbing a real catch-up stream end
  to end (mpv + panel behaviour); the block scrubber on a real live
  channel (block resolution + EPG fetch inside the player, programme
  rollover advancing the block); what happens when catch-up playback
  reaches the tune moment (the segment ends — the player holds the last
  frame and "Jump to live" is the path back; auto-advance to live is NOT
  implemented in this build).

## Verification (parent to confirm before commit)

- `flutter analyze --no-pub`: 49 issues = pre-existing wakelock_plus
  baseline, zero in build #9 code (verified after all changes).
- Suites green per directory (never combined, never two at once);
  `/tmp/flutter_tools.*` cleaned before big suites.
  - test/services/iptv/: 98/98
  - test/screens/livetv/: 62/62
  - test/screens/search_screen_test.dart: 30/30
  - test/widgets/: 1040/1040 (build #8 baseline 1038 + 2 new bar tests)
  - test/utils/: 835/835
  - test/screens/video_player/: 277/277 (incl. pre-existing
    live_tv_catch_up_test + live_tv_session_state_test)
- No credentials anywhere (fixtures only; test passwords built by
  concatenation; diff grepped clean).
- Nothing committed, pushed, or version-bumped — parent owns 2.25.5+162,
  commit, push, Codemagic, delivery.
