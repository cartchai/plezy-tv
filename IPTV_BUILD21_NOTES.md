# Build #21 — search must not disconnect Trex (v1.0.4-2.25.0+176)

Builder notes, 2026-11-09 ~23:18–2026-11-10. Worktree
`~/workspace/tmp_work/plezy-tv-build21-offline`, off main 652db5f90
(v1.0.3-2.25.0+175). No push, no release, no live panel calls, no
credentials — per the task. The login is purged; no panel access exists.

## The failure (from Matt + research)

- Phone (2026-11-09 ~23:12 EST): searching puts the app into OFFLINE
  mode and disconnects Trex. Searching also takes forever on a cold/stale
  catalog (the heal sweeps all 237 series categories mid-search).
- Research (`~/workspace/tmp_work/plezy-tv-research-search-offline/RESEARCH_SEARCH_OFFLINE.md`,
  read first): the search itself never touches health state. The
  disconnect comes from `IptvClient.checkHealth`, which maps EVERY
  failure except 401/403 to `HealthStatus.offline` — timeout, 429, 500,
  socket error, DNS — catch-all, no retry, no transient/dead
  distinction. The search's heal burst (up to 32 concurrent category
  calls per section, 3 sections concurrently = ~96 in flight against a
  max_connections=1 panel, orphaned requests outliving the 50s section
  budget) makes the probe fail. Aggravators: the offline verdict is
  composite (Trex-refused + Plex-offline on mobile data = whole app
  enters the offline shell, because the "refused is not offline"
  carve-out only applied when ALL visible servers were refused); and
  `reconnectOfflineServers` has NO IPTV branch, so a flipped Trex stays
  offline until a manual reconnect.
- Matt (2026-11-09 ~23:25 EST): "Do as few requests as you can, make it
  comparable to other apps. I think that's why Trex blocks me from time
  to time, they're seeing all those requests." The request budget is
  therefore a first-class goal of this build, not a side effect: the
  burst cap is 8 (the top of the low end Matt asked for, 4–8),
  orphans are hard-cancelled, and no health probe fires while a search
  is in flight. Matt (~23:28 EST): the bar is the other apps' request
  profile, not just "fewer than before". Matt (~23:29 EST): weight the
  comparison toward the open-source apps, where the code can be seen.

## What changed

- `lib/services/iptv/xtream_api.dart` — `_fetchBody` now builds an
  `http.AbortableRequest('GET', uri, abortTrigger: abortTrigger)` with
  the UA header, then `_http.send(request)` + `http.Response.fromStream`
  under ONE `.timeout(timeout)` — identical to what `BaseClient.get`
  does under the hood, preserving the old combined headers+body
  timeout. A null trigger behaves exactly like the old `get()`.
  `_getJson` threads an optional `Future<void>? abortTrigger` through.
  The six search-path methods accept optional `Future<void>? abortTrigger`
  and pass it through: `getLiveCategories`, `getVodCategories`,
  `getSeriesCategories`, `getLiveStreams`, `getVodStreams`, `getSeries`.
  (`getXmltv`/`getM3u` via `_getText` left unchanged — not search-path.)
  Verified: package:http 1.6.0 `AbortableRequest` exists; the real
  IOClient honours the trigger (pre-response it aborts the SDK request,
  post-response it injects the error into the stream and cancels the
  subscription). MockClient does NOT honour the trigger — existing tests
  still pass; the new orphan test uses a custom fake that does.
- `lib/media/iptv_client.dart` — the bulk of the fix:
  - `checkHealth` rewritten. If a search is in flight (`_activeSearchCount
    > 0`), set `_deferredHealthProbe = true` and return the last-known
    status with NO request. Xtream branch: `getUserInfo` null → authError;
    401 → authError; 403 → accessDenied; cancellation → return
    last-known WITHOUT advancing the streak; transient (`isTransient` OR
    429 OR 5xx) → `_recordTransientHealthFailure()`; any other 4xx →
    offline immediately; generic catch classifies via
    `MediaServerHttpException.from(e)` (transient → streak, else offline).
    M3U branch: same classification (200 online, 401 authError, 403
    accessDenied, 429/5xx transient, else offline). N=3 consecutive
    transient failures before publishing offline (documented: probes are
    event-driven — resume / manual reconnect / connectivity change — not
    periodic, so 3 = three separate triggers, not one slow probe under a
    burst).
  - Burst: `_searchBurstCap = 8` (static const, with a full justification
    comment) and a per-client `_SearchRequestSemaphore` shared across the
    three sections AND concurrent searches. Cap justification: cap 4 (the
    low end Matt asked for) was tried first and REJECTED by evidence —
    build #19's P4-fast probe (1s per call, 232 categories to sweep)
    needs 232/4 × 1s = 58s > the 49s sweep deadline, so the heal misses
    Game of Thrones (log: `ms=49283, sweepMatches=0`, GoT missing). Cap 8
    (the top of Matt's 4–8 range) passes P4-fast in 29s (232/8 × 1s, 20s
    margin) and is still a 12x cut from the old ~96 concurrent requests
    and 4x down from the old per-section 32. A slower panel (6s/call, the
    P4-slow stress case) cannot be swept inside the deadline at any cap
    in Matt's range — the unfiltered load (outside the cap) is the primary
    path then. The reach test (R1) proves it in-harness at 250ms/call:
    GoT in the LAST category (237 of 237) at cap 8.
  - Orphans: `searchItems` is a thin wrapper (increments
    `_activeSearchCount`, calls `_searchItemsInner`, on finally decrements
    and fires the deferred probe when the count hits 0). Each section gets
    its own `AbortController`; the caller's abort is wired to all three
    (same pattern as `data_aggregation_service.dart` `_withinServerDeadline`);
    each section's `.timeout(searchSectionBudget, onTimeout: ...)`
    hard-cancels that section's in-flight requests on budget expiry.
    `_sweepCatalogCategories` takes `burst` + `sectionAbort`; it acquires
    a permit before launching (false → stop), releases on completion, and
    — the gap the orphan test caught — when the sweep stops EARLY (its own
    deadline passes, or enough matches were found) it hard-cancels its
    in-flight calls, because their rows will be dropped anyway. Without
    this the sweep's own deadline (2.94s) ends the sweep just before the
    section timeout (3s), the section returns normally, the abort never
    fires, and the orphaned calls keep downloading to their own 120s
    HTTP budget — the battery drain Matt reported. A sweep that visited
    every category keeps its in-flight calls (the final wait collects
    their rows).
  - `AbortController` here is the CUSTOM one from
    `../utils/media_server_http_client.dart` (`.trigger` / `.isAborted` /
    `.abort()`), NOT dart:async's AbortController. All abort wiring uses
    `.trigger` / `.isAborted`.
  - Deliberate boundary (documented in code): the three unfiltered
    catalog loads (1/section) and the category-list fetches are NOT
    aborted and NOT capped — single, memoized, cache-warming requests
    outside the burst. The background catalog crawl
    (`_catalogFallbackBatchSize` = 16, only when the unfiltered call
    returns []) keeps its own path, no semaphore, no abort. After a
    timed-out search, sweep traffic = 0; at most 3 loads may still
    complete within their own HTTP budgets (30s categories, 120s
    unfiltered). Worst-case concurrent during a cold+degraded search after
    this build ≈ crawl (up to 48) + sweep (8) + loads (3) + lists (3) ≈
    62, vs ~150 before; typical healthy ≈ 14 (8 sweep + 3 loads + 3
    lists) vs ~102 before; warm (common, disk cache fresh) = heal sweep
    only, ≤ 8 vs up to 96 before.
  - Close-after-use (Matt, 2026-11-10 ~00:39 EST: "Should the connection
    have a close function so it stops talking after?"): the search screen
    already aborted the previous search on a new keystroke (proven by
    C1), and `XtreamApi.close()` / `IptvClient.close()` already ran on
    connection removal and app exit — but an in-flight search kept
    running after the user left the search screen or the app backgrounded.
    `IptvClient.cancelActiveSearches()` tracks the three sections'
    `AbortController`s in `_activeSearchAborts` (added after creation,
    removed in a try/finally around the section wait) and aborts them
    all. `MultiServerManager.cancelActiveIptvSearches()` calls it on
    every connection from `main.dart`'s `paused`/`detached` lifecycle
    case (alongside the library-socket suspend). `search_screen.dart`
    `dispose()` aborts `_activeSearchAbort` as a safety net (the tab is
    kept alive in an `IndexedStack`, so the background path is the one
    that fires). The background catalog crawl is NOT cancelled by this
    (bounded batch walk, finishes on its own, never re-runs for the same
    catalog).
- `lib/services/multi_server_manager.dart` — NEW `_reconnectIptvServer`
  (mirrors `_reconnectJellyfinServer`) + `_probeIptvHealth` (targeted
  single-connection re-probe with the same stale guard as
  `_doCheckServerHealth`). IPTV branch in `_doReconnectOfflineServers`
  (uses `_clients`, not `_iptvByConnectionId`, so the existing
  `debugRegisterClientForTesting` harness can exercise it). Deferred-probe
  wiring in `addIptvConnection`: `client.onDeferredHealthProbe` →
  `_probeIptvHealth` (targeted, not `checkServerHealth()`, which would
  probe all servers including Plex). NEW `cancelActiveIptvSearches()`
  (close-after-use): calls `cancelActiveSearches()` on every IPTV
  client; called from `main.dart`'s `paused`/`detached` lifecycle case.
- `lib/main.dart` — the `paused`/`detached` lifecycle case now calls
  `_serverManager.cancelActiveIptvSearches()` alongside
  `_libraryEventService.suspend()`: backgrounding the app cancels any
  in-flight IPTV search (close-after-use).
- `lib/screens/search_screen.dart` — `dispose()` aborts
  `_activeSearchAbort` (safety net; the tab is kept alive in an
  `IndexedStack`, so the background path is the one that fires).
- `lib/providers/offline_mode_provider.dart` — `onlyRefusedServers` now
  means "at least one visible server refused while NO visible server is
  online" (renamed getter `_hasRefusedServerAndNoneOnline`). Trex-refused
  + Plex-offline → refusal banner, not the offline shell. Genuine
  no-network (none refused) still falls through to `noServerConnection`
  → offline shell. Plex online + Trex refused → online (unchanged).
- Version: 1.0.4-2.25.0+176 (pubspec, about_screen changelog2268,
  en.i18n.json + `dart run slang` regen, FORK_MAINTENANCE.md §20).
  Changelog key 2268; build #22 (stream UA, v1.0.5-2.25.0+177, built in
  parallel off the same base) reserved 2269 — no collision.

## Request counts (measured in-harness, fake panel)

- Warm-heal search (the common case): 19 requests, max 4 concurrent
  observed (cap 8) — vs up to 96 concurrent on base.
- Cold search (237 series categories): 237 category requests + 3
  unfiltered loads + 3 category lists, max 8 concurrent — vs ~102
  concurrent on base.
- Two keystrokes while the first sweep is still running: 28 requests
  total, max 5 concurrent, 12 aborted, no tail — vs up to 38+ on base.
- A timed-out search: returns in 2942ms, 9 in-flight requests aborted, 0
  requests after it — vs orphans running to their own 120s budget on
  base.
- An abandoned search (`cancelActiveSearches`, app backgrounded): stops
  in 2ms, 15 in-flight requests aborted, 0 requests after it — vs ~27s
  uncancelled.

## Peer comparison (the bar, not just "fewer than before")

Open-source, code-verified (primary — Matt, 2026-11-09 ~23:29 EST):

- **IPTVMac 0.9.8** (Goelir/IPTVMac, GPL-3.0) — OSS research doc §2:
  SQLite FTS5 (`item_fts` virtual table, `Sources/IPTVCore/AppDatabase.swift`),
  one FTS5 query per search (prefix terms, rank order,
  `FTS5Pattern(matchingAllPrefixesIn:)`); SyncService
  (`Sources/IPTVCore/SyncService.swift` §2.3) guards: empty response keeps
  old data, per-type stale-mark + upsert + delete-still-stale, 300 MB cap.
  Search = 0 panel requests.
- **IPTVnator 0.25.0** (4gray/iptvnator, MIT) — OSS research doc §4:
  SQLite (Drizzle) trigram FTS, `MIN_COMPOUND_WORD_LENGTH = 3` (trigram =
  substring ≥3 chars), FTS match + LIKE/GLOB fallback arms, SQL-side.
  Search = 0 panel requests.
- **OpenTV** (opentvproject/opentv, GPL-3.0) — Xtream-loading research doc
  §2.2: Room/SQLite on device; WorkManager periodic sync **every 6h**
  (network-connected constraint, exponential backoff from 15 min,
  failures return `Result.retry()` — "the app never hammers a provider
  that is already struggling"); manual refresh one-time work request with
  REPLACE (repeated taps coalesce); `ChannelDao.replaceCatalogue` merges
  user state by streamId (favourite/hidden/sortIndex/customName/
  epgOverrideId/matchedEpgId), chunked upserts, `deleteStale` by
  `lastSeenMillis` sync-stamp, "deliberate absence of any 'delete
  everything then insert' method"; search is a Room @Query `WHERE
  displayName LIKE '%' ||:query || '%'... LIMIT 200` per table → 0 panel
  requests during search; retries: 403/429/5xx exponential backoff
  (500ms doubling to 8s, 5 attempts) + up to 3 silent restarts; 401/404/410
  never retried.
- **Hypnotix** (linuxmint/hypnotix, GPLv3) — Xtream-loading research doc
  §2.1: `XTream.load_iptv()` fetches whole lists unfiltered at load (all
  groups then all streams, Live/VOD/Series in turn); JSON disk cache with
  **8h TTL** (`threshold_time_sec = 60*60*8`); empty list treated as cache
  miss (`_load_from_file` returns None when `len(my_data) == 0` — a
  provider returning [] can never wipe a good cache); series detail lazy
  (`get_series_info_by_id` on open only). Search = 0 panel requests after
  load.
- **OwnTV** (ahXN00/OwnTV, GPLv3) — Xtream-loading research doc §2.3:
  FTS4 + Paging 3 (**README claim** — core library separate, implementation
  not inspected; label as README-level); one-connection-at-a-time engine
  discipline (stated explicitly). App-layer verified; sync/FTS internals
  are README claims.
- **Kodi** (kodi-pvr/pvr.iptvsimple, GPL) — Xtream-loading research doc
  §2.4: no Xtream support at all; M3U+XMLTV via get.php; add-on is a data
  supplier, Kodi core owns channels/EPG/search/playback in its own store;
  auto-refresh interval; catch-up via M3U tags + Catchup correction
  setting. Search = 0 panel requests (core store).

TiviMate (closed-source, secondary, inferred from guides/reviews and the
community UX spec for v5.3.3): syncs the whole catalog into a local
indexed SQLite DB at playlist-update; search is always a local DB query,
never touches the network → 0 panel requests during search.

**Where this build still falls short of parity — stated plainly:** a
cold/stale search still makes panel requests (capped at 8 concurrent,
plus 3 unfiltered loads + 3 category lists). Every peer above makes ZERO
panel requests during a search. Only build #23 (local-only search,
v1.0.6) closes that gap. What this build does close: the burst is no
longer abuse-shaped (8 vs ~96), orphans are dead (0 tail), and a single
failed probe no longer disconnects the server.

## Verification (in-harness only; phone is the final gate)

- Failing-first on base 652db5f90 (worktree
  `~/workspace/tmp_work/plezy-tv-build21-base`, test files copied in):
  9 fail, 2 pass (the two controls). On the fix all 13 pass (see below).
  R1's base failure is the cap (32 vs 8) — GoT is found on both, so the
  reach is proven and the cap is the failure.
- `test/services/iptv/iptv_build21_search_offline_test.dart` (8):
  H1 transient health (timeout probe 1st/2nd online, 3rd offline;
  success resets the streak; 5 user-info requests, none suppressed);
  H2 429 transient + 403 → accessDenied + 401 → authError immediately;
  B1 burst (maxConcurrentCategory=4, cap=8, categoryRequests=19,
  totalRequests=19); R1 reach (GoT in cat-237, last of 237,
  maxConcurrentCategory=8, categoryRequests=237); O1 orphan
  (elapsed=2942ms, aborted=9, tail=0); P1 probe deferral
  (userInfoBefore=0, userInfoAfter=0); C1 two keystrokes
  (maxConcurrent=5, cap=8, categoryRequests=28, total=28, aborted=12);
  M1 IPTV reconnect (userInfo 0→1, online=true).
- `test/services/iptv/iptv_build21_deferred_probe_test.dart` (1, new API
  — only compiles on the fix): two probes mid-search coalesce to one
  deferred probe (callbacks=1, userInfoRequests=1).
- `test/services/iptv/iptv_build21_close_after_use_test.dart` (1, new API
  — only compiles on the fix): A1 abandon — `cancelActiveSearches()`
  stops an in-flight search in 2ms, 15 aborted, tail=0 (vs ~27s
  uncancelled).
- `test/providers/offline_mode_provider_build21_test.dart` (3):
  mixed refusal → banner not offline; genuine no-network → offline;
  refused + online → online.
- `flutter analyze` on the 4 changed product files: clean (after fixing
  one new `unawaited_futures` info at iptv_client.dart:3886). Repo-wide
  analyze: **49 issues, all vendored `packages/wakelock_plus`, zero in
  `lib/`** — exactly the baseline (the exit code is 1 because the
  vendored package has issues; no new issue from this build).
- Touched suites: `test/services/iptv/` **261/261** (260 + the new A1
  close-after-use test; re-run after the close-after-use work) +
  `test/screens/livetv/` 102/102. Search/aggregation:
  `test/services/data_aggregation_bridge_test.dart`,
  `jellyfin_search_test.dart`, `plex_search_test.dart`,
  `test/utils/search_relevance_test.dart`,
  `test/utils/search_sections_test.dart`,
  `test/mixins/debounced_media_search_test.dart`,
  `test/screens/search_screen_test.dart`,
  `test/screens/search_screen_build19_scope_widget_test.dart`,
  `test/screens/catalog_search_screen_test.dart` — **136/136 pass**;
  `test/screens/livetv/guide_search_sheet_test.dart`,
  `test/screens/iptv_build13_search_screen_test.dart`,
  `test/widgets/person_search_row_test.dart`,
  `test/widgets/subtitle_search_sheet_test.dart` — **20/20 pass** after
  one recalibration (below). The 13 new build #21 tests pass (8
  failing-first + 1 deferred-probe + 1 close-after-use + 3 provider).
- Recalibrations (all the same root cause — the tests' timing budgets
  were calibrated to the old batch size 32, and cap 8 is slower; the
  behaviour under test is unchanged, only the timing calibration):
  build13 diagnosis (1s→3s), build10 diagnosis (1s→3s, two slow-call
  tests), build17 probes C4 (1s→6s), build19 P4-fast (explicit 3min test
  timeout), build19 P4-slow (now asserts the graceful miss, not the
  find — at cap 8 a 6s/call panel cannot be swept inside the deadline),
  build13 search-screen cold crawl (1s→3s — 120 cats / 8 × 100ms =
  1500ms to reach category 120, past the 980ms deadline at 1s). The
  build13 cold-crawl failure was caught by the search-suite run and
  fixed here (it failed alone, not a flake).
- Build #20 tests still pass against the new `_fetchBody`:
  `test/services/iptv/iptv_build20_user_agent_test.dart` +
  `iptv_build20_user_agent_setting_test.dart` — 6/6 (proves the
  AbortableRequest change is behavior-preserving for MockClient).
- NOT verified: the panel (phone-only); the settings screen rendering;
  the deferred-probe wiring end-to-end through the manager's reconnect
  loop (the M1 test exercises `reconnectOfflineServers` via the manager,
  the D1 test exercises the callback — the two halves are not yet joined
  in one test).

## Gotchas hit during this build

- The sweep's own deadline (2.94s) ends the sweep just before the section
  timeout (3s), so the section returns normally and the section abort
  never fires — the in-flight calls are orphaned. The orphan test caught
  this (abortedRequests == 0 on the first implementation). Fix: the sweep
  hard-cancels its in-flight calls when IT stops early (deadline or
  shouldStop). A sweep that visited every category keeps its calls.
- The failing-first tests must use the literal `8` for the cap, not
  `IptvClient.searchBurstCap` (new in the fix) — otherwise they do not
  compile on base. `searchSectionBudget` is pre-existing (build19), so it
  is safe to reference.
- The deferred-probe and close-after-use tests are fix-only (they use
  `onDeferredHealthProbe` / `cancelActiveSearches`, new in the fix) and
  live in their own files so the failing-first file stays base-compilable.
  Fix-only test files carry their own minimal fake panel (see
  `iptv_build21_deferred_probe_test.dart`, `iptv_build21_close_after_use_test.dart`).
- Do NOT run `dart format` on whole files in this repo (caught twice on
  build #20). Match the surrounding 120-col style by hand.
- `flutter test` on a big directory backgrounds after ~120 s; write the
  log to a file and read the file.
- The `AbortController` in iptv_client.dart is the CUSTOM one from
  `media_server_http_client.dart` (`.trigger` / `.isAborted`), NOT
  dart:async's. The semaphore's `abort?.trigger.then(...)` needed an
  `unawaited` wrapper (one analyze info).
- Wrapping the section `Future.wait` in a try/finally by LINE NUMBER
  broke the file: the line numbers came from a grep run BEFORE earlier
  edits in the same session had shifted the file, so the `try {` landed
  inside the `Future.wait` list and the `} finally {` after the M3U code
  (246 analyze errors). Repaired by replacing the whole region anchored
  on unique content markers (`final sections = await Future.wait([` …
  `final m3uStarted = ...`), not line numbers. Lesson: never trust
  line numbers from an earlier turn — re-grep in the same command, or
  anchor on content.
