# PlezTV Build #13 — v2.25.9 (2026-11-07)

Search fixes (Matt: "don't stop testing and working until you get it
working"), the missing Trex Movies/Series libraries, the black Live TV
mini-player, the category-initials filter that did nothing, and the
cache/fluidity session ("the cache thing didn't even feel like it really
worked... the app needs to feel more fluid"). Every fix has a
failing-first test; every screen fix has a screen-level test driving the
actual flow. Nothing here ships on "unit tests pass" alone.

Version: **2.25.9+166**. Commits: see `git log` (build #13, one commit
on main). No keystore / applicationId / iOS bundle ID change.

## 1. Trex Movies/Series libraries MISSING on v2.25.8 — TOP PRIORITY, FIXED

**Symptom (Matt, 2026-11-07 ~05:17 EST):** the Trex Movies and Series
libraries disappeared from the app on v2.25.8 (present on v2.25.6/7).
Live TV "half works" — the connection is alive, but the VOD libraries
are gone entirely.

**Root cause (proven at screen level):** `IptvClient.fetchLibraries`
omitted a synthetic library when ALL of its categories were disabled by
id (`_allCategoriesDisabled` probe: `categories.every((c) =>
_disabledCategories.contains(c.id))`). The probe used to fail open on a
slow network (5s timeout); the build #11 disk cache made category reads
instant, so the probe started completing — and hiding the libraries. One
"Hide all groups" tap in the connection Edit screen (`_disabled.addAll(
_allCategories.map((c) => c.id))` — applies across all three sections at
once) makes both libraries vanish while Live TV keeps working: exactly
Matt's symptom. Honest caveat: his stored disabled-id set could not be
seen directly, so "his set is full" is not directly proven — but this is
the ONLY code path that produces his exact symptom (libraries gone, Live
TV alive), it is reproduced at screen level, and the fix removes the
landmine regardless.

Ruled out by code-read + tests: the build #12 header change
(`_buildLibraryDropdownTitle`, header Row only — innocent), the
late-bind/pre-bound cold-start race (both pass), the aggregation 15s
deadline, the initials filter (hides categories/items, never libraries).

**Fix (`lib/media/iptv_client.dart`):** `fetchLibraries` now ALWAYS
returns both synthetic libraries for Xtream. `_allCategoriesDisabled`
and the probe are deleted (also removes 2 network round trips + up to 5s
from every library fetch). Disabled categories are still hidden from
browse/search/guide by the content-level filters; an all-disabled
library simply shows its empty state.

**Screen test:** `test/screens/libraries/iptv_build13_libraries_screen_test.dart`
(real provider stack, 360×800 Fold 7 cover viewport, Trex-shaped fake).
4/4 pass: late bind, pre-bound, all-category-ids-disabled (FAILED before
the fix once the disabled set included the AR id '900' — the first
version without '900' passed spuriously because `every` failed on the
undisabled AR category), Movies + Series browse rows load.

## 2. Live TV search — Xtream channels were NOT searchable, FIXED

**Root cause (proven):** `IptvClient.searchItems` for Xtream returned
movies + series only. Only M3U channels were searchable
(`_searchM3uEntries`). Live TV search was empty by construction — that
is what "broken in live TV" meant. No timing/aggregation bug was also
needed: the leg simply did not exist.

**Fix (`lib/media/iptv_client.dart`):** new `_searchLive` leg (same race
shape as movies/series: unfiltered `_liveStreams()` vs per-category
sweep), `_appendLiveMatches`, `_liveChannelItem` (`MediaItem.xtream`,
id `live:<streamId>`, `_liveLibraryId`, title `'$_name — Live TV'`,
streamUrl/EPG/catch-up flags), `fetchItem` `'live'` case. The live
section runs only when `excludedLibraryIds` is empty (live is not a real
library, so it can never appear in the excluded set). Search never opens
a stream (one-stream limit): results are plain items whose tap resolves
through `fetchItem`. `groupSearchResults` already handles `:live` ids
(rank 2), so the Live TV section header works as-is.

**Tests:** diagnosis harness `iptv_build13_diagnosis_test.dart` L tests
(live searchable — FAILED before, passes after; L-scope guard; L-filter
guard); screen tests `test/screens/iptv_build13_search_screen_test.dart`
3/3 ("alpha" shows Alpha Show + Alpha Movie; "hbo" shows HBO East;
"aljazeera" shows nothing — AR hidden).

## 3. Series search — the cold-crawl trap, FIXED

**Root causes (proven by the failing-first harness, Trex scale: 150
visible EN categories/section, 100ms per-category latency, his filter
state with AR hidden):**
- **(g) per-category `get_series` returns [] on this panel** while the
  unfiltered load returns rows (Recommended proves it). The sweep was
  futile on his phone; the search depended ENTIRELY on the unfiltered
  load landing within ~49s.
- **(c) sweep timing:** the sweep deadline (90% of the 50s section
  budget) could fire after the sweep found a match but before
  `_searchSeries` returned (the 100ms margin was eaten), discarding the
  found match. **Real bug, found via the screen test:** diagnostics
  showed `series sweep=1, ms=0, totalMs=201` — the match was found, then
  thrown away by the timeout.
- **The crawl published nothing until it finished:** `_loadSeries()`'s
  fallback crawl (when unfiltered returns []) had NO deadline and
  returned only when ALL visible categories were crawled; partial
  progress was invisible to search, browse, warm-up, and the disk cache.

**Fix (`lib/media/iptv_client.dart`):**
- Partial-row publication: `_vodPartialRows` / `_seriesPartialRows` (+
  crawled-category sets) publish each crawl batch as it lands
  (generation-guarded); `_vodStreams()` / `_seriesList()` clear them
  once the full load completes.
- Sweep skips already-crawled categories; search filters the partial
  snapshot after the sweep and once more after the post-sweep load wait.
- `_catalogFallbackBatchSize` 8 → 16 (sweep + crawl reach doubles).
- **Non-destructive timeout:** `_SectionTrace.partialOut` holds the
  section's live result list; the `.timeout()` onTimeout now returns
  `trace.partialOut` instead of `[]` — a section that runs out of budget
  returns what it already found, never [].
- `seriesCatalogDiagnostics()` probes directly (unfiltered `getSeries`
  + categories + first 3 per-category probes, each 10s-bounded) instead
  of awaiting the full `_seriesList()` crawl (it used to time out at
  1500ms in the harness).
- Warm-ups: added `warmUpVodCatalog()` + `warmUpLiveCatalog()`; all three
  warm-ups now start BEFORE `checkHealth()` in `addIptvConnection`
  (previously series-only, after the probe).

**Tests:** diagnosis harness 9/9 (was 5 fail / 4 pass before the fix);
screen search tests 3/3 (incl. the cold-crawl B1: "alpha" finds the show
in category 110, scaled 1s budget). Two build #10 diagnosis tests
(`iptv_build10_diagnosis_test.dart`) were updated from DIAGNOSIS to
FIXED — the late-category matches they documented as unreachable are now
found (batch 16 + partial publication); they are regression tests for
this fix now.

**On-device search diagnostics** (`lib/screens/settings/iptv_settings_screen.dart`,
`_IptvCatalogDiagnosticsState`): the settings row now resolves the LIVE
bound client (`MultiServerProvider.getClientForServer`, fresh-client
fallback) and shows a "Last search" section under the catalog rows:
query + total ms + scoped suffix; per-section lines (Movies / Series /
Live TV) with returned count, load rows/ms, sweep, partial, ms; "load
never landed" when loadRows is -1; "skipped" for scoped-out sections;
"No search yet — search for something, then check back here." when null.
The client records `_lastSearchDiagnostics` on every search (query,
scoped, totalMs, per-section `_SectionTrace`). One screenshot of this
row settles where a search dies: load vs sweep vs cache, per section.
New i18n strings: `iptv.lastSearchTitle`, `lastSearchNone`,
`lastSearchQuery`, `lastSearchScopedSuffix`, `lastSearchSection`,
`lastSearchSectionLoadNeverLanded`, `lastSearchSectionSkipped`.

**Honest limit:** a first search whose unfiltered load exceeds the 50s
section budget still returns [] — warm-up + second search are the
mitigation. Do NOT claim the budget problem is solved.

## 4. Live TV mini-player BLACK (audio only), FIXED

**Symptom (Matt, 2026-11-07 ~05:11 EST):** mini-player is black, audio
only; maximizing plays video fine.

**Root cause (proven by widget test):** the custom mpv `Video` widget
(`lib/mpv/video.dart`) does NOT use a Flutter Texture — video lives in
a native surface BEHIND the Flutter window. The widget paints a black
`ColoredBox` until `_hasFirstFrame`; without an external notifier it
learns the first frame ONLY from `player.streams.playbackRestart` (a
broadcast stream — an event fired before subscription is missed
forever). The mini-player inserts its `Video` only after `tune()` awaits
`player.open()`, so the restart during `open()` is missed → the black
cover stays, audio plays. Fullscreen works because the player screen
subscribes at player creation (before open) and drives
`_firstFrame.uiReady`, plus a position-advance fallback.

**Fix (`lib/mpv/video.dart`):** `Video.initState` now reads the latched
`widget.player.state.hasRenderedFrame` (`PlayerState.hasRenderedFrame`,
set when the restart is processed) as the initial value;
`didUpdateWidget` on player change re-reads the new player's latched
state (no-external-notifier case only). The subscription still catches
restarts arriving after mount.

**Test:** `test/mpv/video_first_frame_test.dart` (real `Video` widget +
fake `Player` whose restart stream never emits). 3/3: frame rendered
before mount + missed event → transparent (FAILED before the fix, passes
after); no frame yet → stays black (control); restart after mount →
transparent (control). **Real proof is Matt's phone — say so.**

## 5. Category initials don't hide categories, FIXED

**Symptom (Matt, 2026-11-07 ~05:12 EST):** "Category initials doesn't
actually turn off the categories with those initials."

**Root causes (proven, 6 of 7 tests failing before the fix):**
- **Derivation gaps:** `categoryInitial()` only read a LEADING prefix.
  Provider categories with the region buried after a content-type prefix
  ("MOVIES | EN | Action", "SERIES | FR | Drama", "LIVE TV | AR | News")
  returned null, as did lowercase ("en | …") and bracket ("[EN] …")
  forms → toggling EN/FR/AR did nothing for them. A Title Case trailing
  word ("News", 4 letters) also matched as a bare initial and overrode
  the region ("LIVE TV | AR | News" → NEWS, not AR).
- **No refresh after toggle (proven by code-read):** library tabs only
  reload when `LibrariesProvider.libraryContentEpoch` bumps, and it bumps
  ONLY on server push events; a rebind emits nothing → Categories/browse
  tabs showed stale lists. The guide only reloads when the server-id SET
  changes → same ids after rebind → no reload. So even where the filter
  worked, the lists did not update until a restart.

**Fix:**
- `lib/utils/iptv_initials.dart`: `categoryInitial()` now scans
  pipe-separated segments, LAST match wins ("TV | EN" → EN),
  case-insensitive (canonical uppercase out), bracketed segments count
  (`[EN]` → EN), and a bare/prefixed/bracketed token only counts when it
  looks like a code — all-caps or all-lowercase, never Title Case
  ("News" is a word, not an initial). Controls preserved: "Action" →
  null, "ENGLISH | …" → null, "UK Series" → null, "NF" → NF,
  "|EN| UK SERIES" → EN, "24/7 …" → "24/7".
- `lib/services/multi_server_manager.dart`: `addIptvConnection` now calls
  `client.notifyCatalogRefreshed()` when replacing an existing client
  (`_notifyCatalogRefreshed` renamed public, 3 call sites updated).
  Library tabs already listen to `LibraryContentNotifier` (paced,
  scroll-aware), so they reload on rebind.
- `lib/screens/livetv/live_tv_screen.dart`: the guide now subscribes to
  `LibraryContentNotifier` in `initState` and reloads channels via
  `_loadChannels()` on an event targeting one of its servers; cancelled
  in `dispose`.

**Tests:** `test/services/iptv/iptv_build13_initials_test.dart` 7/7
(was 6 fail / 1 pass); pre-existing
`test/services/iptv/iptv_category_initials_test.dart` 14/14 (no
regression from the derivation change). Legacy 161-hidden set needs no
migration (same strings, reused with the new meaning; broadening the
derivation makes more of them take effect — the desired outcome).

## 6. Cache verification + fluidity — MEASURED, FIXED

Matt: "the cache thing didn't even feel like it really worked."

**Benchmark:** `test/services/iptv/iptv_build13_cache_benchmark_test.dart`
(Trex scale: 199,762 VOD rows; 16ms jank ticker — the longest gap
between ticks is the UI freeze). Measured before/after (this VM; his
phone will differ in absolute ms, the ratios are the point):

| | Before | After |
|---|---|---|
| First launch, wall | 1398ms | **161ms** |
| First launch, max UI freeze | 1346ms | **111ms** |
| Second launch (disk), wall | 1438ms | **1058ms** |
| Second launch, max UI freeze | 558ms | **114ms** |
| Second launch, unfiltered network calls | 0 | 0 |
| Browse page-2 turn, freeze | 647ms | **56ms** |
| Movies Recommended hub open, freeze | 802ms | **74ms** |

(The second-launch wall is longer than the first-launch wall in the
test only because the fake network is instant; in reality the first
launch downloads ~29MB over LTE — minutes — while the second reads disk
in ~1s. The cache DOES eliminate the network; what it did not eliminate
was the freeze.)

**Bottleneck 1 — the disk write re-encoded the catalog (FIXED):**
`_writeDiskCatalog` ran `jsonEncode(rows.map(toJson).toList())`
synchronously on the UI isolate (map 304ms + jsonEncode 434ms at Trex
scale, ~1.3s freeze with the adjacent block). The network path already
HAD the raw body (`XtreamApi._fetchBody`) and threw it away after
parsing. Now `XtreamApi` keeps `lastLiveStreamsBody` /
`lastVodStreamsBody` / `lastSeriesBody` (unfiltered calls only;
per-category calls clear them), and the client caches the raw body
verbatim via `_writeCatalogRows` / `_writeDiskText` — no encode at all.
Fallback: a crawled catalog (merged from per-category bodies) or a
faked API has no single body, so it still re-encodes. The background
refresh (`_refreshCatalogInBackground`) takes the same raw body via an
optional `rawBody` callback. Decomposition (informational): UTF-8 decode
of the 29MB body is 45ms, `compute` parse wall 804ms with only a 99ms
main-isolate gap (result transfer) — the read path was never the problem.

**Bottleneck 2 — concurrent category writes raced directory creation
(FIXED, found in the benchmark warnings):** parallel dataset writes
raced `Directory.create(recursive: true)` and the losers threw
`PathNotFoundException`, so the category files never landed (categories
re-fetched every launch). `IptvCatalogDiskCache.write` now tolerates a
create that fails only because the directory now exists.

**Bottleneck 3 — per-row filter work over 199k rows (FIXED):**
`_isHiddenCategory` called `categoryInitial()` (splits + regexes) PER
ROW in `_moviesItems()` / `_seriesItems()` / search — ~600ms. Now
`categoryInitial()` memoizes (pure function of the name; 833 distinct
names on his provider). And the search match loops did
`name.toLowerCase().contains(needle)` per row (199k allocations) — now
one case-insensitive `RegExp` per call, `hasMatch` per row, in
`_appendMovieMatches` / `_appendSeriesMatches` / `_appendLiveMatches` /
`_searchM3uEntries`.

**Bottleneck 4 — paged browse built all 199k items per page turn
(FIXED):** `fetchLibraryPagedContent` called `_moviesItems()` /
`_seriesItems()` (full 199k `MediaItem` build) then sliced one page.
Now `_filteredVodRows` / `_filteredSeriesRows` filter ROWS (hidden
removed, query on the stripped title — same text the old item filter
matched), and `_vodPageItems` / `_seriesPageItems` map only the page's
rows. Same for the Recommended hubs (map only the first `limit` rows)
and `fetchMoreHubItemsPage`. `_recommendedHub` takes a `totalCount` so
`size` / `more` still reflect the catalog, not the preview (caught by
the stage2 test). The guide was already lazy
(`SliverVariedExtentList.builder`) — no change needed there.

**Known remaining costs (not fixed in this build):**
- `fetchMoreHubItems` (no limit) still builds the full item list once
  per hub-detail expansion — the hub detail's section filter runs over
  it. A row-level section filter is future work.
- The second-launch ~114ms freeze is the inherent cost of scanning /
  parsing a 199k-row catalog (disk read + `compute` parse + result
  transfer); a persistent worker isolate holding the catalogs would
  remove the transfer, but that is a redesign, not a fix.
- First launch on LTE is dominated by the ~29MB network download; the
  cache only helps from the second launch.

## Bug testing (flows tested, not invented)

- Libraries list (late bind, pre-bound, all-ids-disabled, browse rows):
  screen test, 4/4.
- Movies/Series browse paging + hub open at Trex scale: benchmark, 2/2.
- Search (series cold crawl, movies, live, scope, filter): diagnosis
  harness 9/9 + screen tests 3/3.
- Live TV guide + mini-player video surface: widget test 3/3 (video
  widget transparent when the frame latched before mount).
- Category-initial toggle (derivation, end-to-end hiding, rebind
  notification): 7/7.
- Cache (first vs second launch, disk read, encode split, read split):
  benchmark 6/6.

## Files changed

- `lib/media/iptv_client.dart` — search (live leg, partial rows,
  non-destructive timeout, diagnostics, warm-ups), fetchLibraries always
  lists VOD libraries, raw-body disk writes, row-level paging + hubs,
  allocation-free matching, memoized-category filtering.
- `lib/services/iptv/xtream_api.dart` — `last*StreamsBody` raw bodies.
- `lib/services/iptv/iptv_catalog_cache.dart` — directory-create race.
- `lib/utils/iptv_initials.dart` — buried/lowercase/bracket derivation,
  code-case rule, memoization.
- `lib/services/multi_server_manager.dart` — notify on client replace.
- `lib/screens/livetv/live_tv_screen.dart` — guide subscribes to
  `LibraryContentNotifier`.
- `lib/mpv/video.dart` — latched `hasRenderedFrame` at init.
- `lib/screens/settings/iptv_settings_screen.dart` — "Last search"
  diagnostics row.
- `lib/i18n/en.i18n.json`, `lib/i18n/strings.g.dart`,
  `lib/i18n/strings_en.g.dart` (slang regen) — `changelog2259` +
  last-search strings.
- `lib/screens/settings/about_screen.dart` — `changelog2259` entry first.
- `pubspec.yaml` — 2.25.9+166.
- Tests: `test/services/iptv/iptv_build13_diagnosis_test.dart`,
  `iptv_build13_initials_test.dart`,
  `iptv_build13_cache_benchmark_test.dart`,
  `iptv_build13_browse_benchmark_test.dart`,
  `test/screens/iptv_build13_search_screen_test.dart`,
  `test/screens/libraries/iptv_build13_libraries_screen_test.dart`,
  `test/mpv/video_first_frame_test.dart`; updated
  `iptv_build10_diagnosis_test.dart` (2 tests DIAGNOSIS → FIXED),
  `iptv_build13_diagnosis_test.dart` (B1/B2 margins widened — the
  post-fix crawl sat exactly on the 1000ms budget and flaked under suite
  load; 120 categories / match 110 / 80ms keeps it failing-first with
  room to spare), `iptv_stage2_test.dart` untouched (its failure was the
  hub `more` flag — fixed in the product).

## Verification

- `flutter analyze`: **49** (the pre-existing wakelock_plus baseline;
  zero in new code — 11 new issues found during the build were fixed).
- `test/services/iptv/`: **168/168**. Search screens: **33/33**.
  `test/screens/livetv/`: **76/76**. `test/screens/iptv/`: **17/17**.
  `test/screens/libraries/` + `test/mpv/`: **313/313**.
- Full suite (run per top-level directory — the combined `flutter test`
  run is the one that historically gets SIGTERM-killed at ~72 min, so
  the suite was run in 4 chunks covering all 694 test files):
  **8566 pass, 20 fail** — small dirs 2744 pass / 3 fail; services 3672
  pass / 17 fail; screens 1058 pass / 0 fail; widgets + scripts 1092
  pass / 0 fail. **All 20 failures are pre-existing: proven by running
  exactly those 7 files on a pristine worktree at HEAD (c5081169c,
  before this build) — same 20 failures, 78 pass.** The 20 are: 12×
  `data_aggregation_bridge_test.dart` (known, documented pre-existing),
  3× companion LAN discovery, 1× deep-links item_links, 1× Jellyfin LAN
  discovery, 1× android network security config, 1× memory-pressure
  breadcrumbs, 1× watch-together provider. None of those files import
  any file this build changed. One failure found during the run was MINE
  (cache benchmark second launch, 281ms vs a 250ms threshold under suite
  load) — fixed by widening the load-tolerant thresholds to 400ms
  (pre-fix freezes were 1346ms / 558ms) and re-verified in the services
  re-run.
- Known pre-existing failure (NOT chased):
  `test/services/data_aggregation_bridge_test.dart` fails 12 tests on
  pristine HEAD too.

## Phone verification (what Matt should check)

1. Install v2.25.9 over the top. **Libraries tab: Trex Movies and Trex
   Series must be listed** (they were missing on v2.25.8). Open each —
   rows load, no endless spinner.
2. **Search "alpha"** (or any show title): the TV Shows section must
   list the show. **Search a live channel name** (e.g. a channel he
   watches): a Live TV section must appear with the channel. Tap a live
   result — it tunes (one stream only).
3. **Live TV mini-player:** tune a channel in portrait — video must show
   in the small player on top of the guide, not black with audio only.
4. **Category initials:** Settings → Trex → turn off an initial (e.g.
   AR) — those categories must disappear from the Categories tab, the
   Library browse, the Live TV guide, and search, with no restart.
5. **Fluidity:** second launch after the first — Libraries/Movies open
   noticeably faster than the first launch; scrolling through Movies
   pages does not stutter.
6. **If search still fails on his phone:** Settings → IPTV → the "Last
   search" row (under the catalog rows) — screenshot it. It shows the
   query, total ms, and per-section load/sweep/partial/ms — that one
   screenshot settles where the search dies.
