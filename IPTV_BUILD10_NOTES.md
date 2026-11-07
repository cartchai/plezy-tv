# PlezTV Build #10 — v2.25.6 (uncommitted; parent owns version bump, commit, push)

Four parts in one build, all from Matt 2026-11-06:

1. **In-app update download + install** — see `IPTV_UPDATER_NOTES.md`.
2. **Initials list in alphabetical order** — the checklist sorts by
   initial (case-insensitive), counts attached ("EN (142)").
3. **Category-initials redesign** — "Name initials" becomes "Category
   initials" (this doc).
4. **Series search fix** — search must use the data source that provably
   works, plus on-device diagnostics (this doc).

## Part 3 — Category-initials redesign

### Why (Matt's screenshots, 2026-11-06 ~19:17 EST)

The IPTV settings screen showed "Name initials: 161 of 171 hidden" —
EN on, everything else off. He had hidden 161 initials. The edit screen
showed the Trex connection with Live TV "833 categories", all toggled
ON. The name filter hid nearly every ITEM (that is what emptied the
series categories and broke series search — hypothesis (h) from
`IPTV_BUILD10_DIAGNOSIS.md`, confirmed as the mechanism), while the
CATEGORIES themselves stayed listed, because the filter never touched
categories. Recommended still showed series because EN is one of the
few initials left on.

Matt's correction: "the name initial is not turning off the category…
it should be more like category initial… I should be able to turn off
entire categories with this, that's the idea, so I can turn off
regions… no longer name initial, category initial… it should turn off
all the categories connected to it… See how 24/7 is kind of a
category… AR is a region category, Asia is a region category, etc."

### The redesign

- The section is renamed everywhere it appears (IPTV settings screen
  AND connection edit screen — shared widget
  `IptvInitialsChecklist`): "Name initials" → "Category initials".
  i18n key `connections.iptvFilterInitials` + `iptv.initialsLoadFailed`
  / `iptv.initialsNoneFound` reworded. The v2.25.4 changelog line is
  historical and was NOT touched.
- The initial is derived from the CATEGORY NAME's leading prefix
  (`categoryInitial` in `lib/utils/iptv_initials.dart`):
  "|EN| UK SERIES" → EN (leading pipes stripped); "24/7 ACTION &
  ADVENTURE VIP" → "24/7" (short leading token before the first
  space, when it is a tag not a word); "AR - …" → AR; a category that
  IS just an initial ("NF", "ASIA") → itself. A bare space is NOT a
  separator ("UK Series", "Action", "IT Crowd" → ungrouped, always
  shown, toggled individually). Repeat threshold stays 5 (only offer
  an initial shared by 5+ categories).
- Toggling a category initial OFF hides ALL categories carrying it —
  and everything in them (channels, movies, series) — everywhere:
  Live TV, Library browse, categories tab, search, EPG. Toggling it
  back ON restores them.
- The stored per-connection `disabledInitials` set is REUSED as-is
  (same strings, same storage, same copyWith/JSON). Its meaning
  changed from "hide items whose name starts with this" to "hide
  categories whose name starts with this". No data migration. His
  current 161-hidden state then hides those regions' categories, which
  is what he asked for — and "Show all" resets it.
- Item-name filtering is GONE: `_isDisabledInitial` / `_isDisabled`
  deleted; the client now has `_isHiddenCategory(categoryId,
  categoryName)` (hidden by its own switch OR its category initial)
  and `_isHiddenGroup(groupTitle)` for M3U (group title is both id and
  name). Items are hidden if and only if their category is hidden.
- The initials list is derived from the loaded categories (Live TV +
  Movies + Series), sorted ALPHABETICALLY, each row's count = the
  number of CATEGORIES carrying that initial. `iptvInitials()` no
  longer loads any catalog for Xtream (it used to load the whole
  live/VOD/series catalogs just to count item-name prefixes) — only
  the three category lists; M3U reads group titles only.
- `detectInitial` / `initialOf` / `countInitials` deleted from
  `lib/utils/iptv_initials.dart` (replaced by `categoryInitial` /
  `countCategoryInitials`); `initialsMeetingThreshold` and
  `IptvInitial` unchanged. (`lib/utils/initials_palette.dart` has its
  own unrelated `initialOf` for profile avatars — untouched.)

### Call sites changed (`lib/media/iptv_client.dart`)

`_loadVodStreams` / `_loadSeries` fallback crawls (exclude
initial-hidden categories), `_moviesItems` / `_seriesItems`,
`iptvCategoriesForLibrary`, `iptvItemsForCategory` (hidden category
returns [] early, before loading the catalog),
`_appendMovieMatches` / `_appendSeriesMatches`, `_searchM3uEntries`,
`iptvChannels` Xtream (new cached `_liveCategoryNames()` future, so a
channel is hidden exactly when its category is) and M3U. EPG inherits
the Live TV filtering via `iptvChannels()`.

## Part 4 — Series search fix

### The decisive fact (Matt, 2026-11-06 ~19:21 EST)

He turned ALL name initials back ON (Show all — nothing hidden) and TV
search STILL doesn't work. **(h) is RULED OUT for search.** Search has
its own root cause. Recommended DOES load series — it uses the
unfiltered `_seriesList()`, so the unfiltered catalog returns rows on
his phone. Search must be made to use the data source that provably
works.

### The diagnosis (from `IPTV_BUILD10_DIAGNOSIS.md`)

`_searchSeries` on a cold catalog bet everything on the per-category
sweep: if the panel's per-category `get_series` calls return [] (g),
the sweep finds nothing while the unfiltered load would have returned
rows. Plus the timing defects: T1 (the category list fetched twice —
once for names, once for the sweep — burning the 50s section budget
before the sweep runs), T3 (the sweep deadline was measured from sweep
start, so a slow names fetch pushed the sweep past the outer timeout
and its partial matches were discarded). And every settings rebind
recreates the client, wiping the warm catalog caches — his searches
kept landing on a fresh cold client.

### The fix (`_searchMovies` / `_searchSeries`, same shape)

1. **Race both sources.** The unfiltered load starts at once
   (`_vodStreams()` / `_seriesList()` — the shared cached future);
   when it lands with rows, its matches are appended and
   `loadLanded` stops the sweep. The sweep runs in parallel for when
   the load is the slow one.
2. **Post-sweep load await — only when the sweep found NOTHING.** If
   the sweep finished early (instant [] per-category calls) before the
   load landed, search waits out the remaining budget for the load;
   without this a fast-empty sweep wins over a slow-but-returning load.
   If the sweep found matches, search returns them at once and lets
   the load keep warming the cache — waiting there would stall every
   cold search for the rest of the budget. (First version of this fix
   waited whenever `out.length < limit`; corrected before testing —
   that shape would have stalled a cold search that already had
   matches.)
3. **T1/T3 timing fixes.** One shared category-list fetch (the names
   lookup fetches it, the sweep reuses the cached future — no
   re-fetch on failure). The sweep deadline is measured from the
   SECTION start (`_sweepDeadline(sectionStarted)` = start + 90% of
   the section budget), not the sweep start. The load-await deadline
   is section start + 98% of the budget.
4. **Warm path unchanged** (filter the cached list), except it keeps
   awaiting names first as today.
5. **Startup warm-up.** `IptvClient.warmUpSeriesCatalog()` (Xtream
   only; unawaited `_seriesList()`; a load already in flight is
   shared) is called in `MultiServerManager.addIptvConnection` right
   after the client is stored — so the second search after app start
   finds a warm catalog. Series only: movies search already works and
   warming the 199k-row VOD catalog on every rebind is unnecessary
   cost.
6. **A late load landing never mutates a returned list** (`finished`
   flag set right before `return out`; the `.then` handler checks it).

### On-device diagnostics (diagnosis recommendation 6)

`IptvClient.seriesCatalogDiagnostics()` — unfiltered series row count,
series category count, per-category row counts for the first 3 series
categories (direct `get_series` probes — this directly settles (g)),
disabled-initials count, disabled-categories count. Surfaced in the
IPTV settings screen as a collapsed-by-default "Series catalog" row
after the initials section (Xtream only; own client, loads on expand,
"Loading…" + Retry on failure). i18n strings under `iptv`
(`catalogDiagnostics*`). One screenshot of it settles whether the
catalog loads on his phone.

## Tests

### New: `test/services/iptv/iptv_category_initials_test.dart` (14 tests)

- Detection counts categories per initial, not items (EN 16, FR 11,
  UK 5); ungrouped categories never offered.
- Disabling FR hides all its categories + their items in browse,
  categories tab, drill-down (empty), and Live TV; re-enabling
  restores them; individual category toggles work alongside; an
  EN-named channel in a UK category stays visible when EN is off
  (item names are never filtered).
- **The search goal, both states:** (a) FR + UK hidden, EN shown →
  an EN show is found, the FR show is hidden by its category, the
  ungrouped show is found; (b) Show-all → any show is found.
- (g) race: unfiltered slow (300ms) but returning rows + per-category
  [] → search finds the show (post-sweep await) AND the drill-down
  finds it; mid-sweep landing (load at 300ms, per-category batches at
  400ms) → the load's matches win; sweep still works when the
  unfiltered load never completes (returns promptly on the sweep's
  matches, < 700ms of a 1000ms budget — the `out.isEmpty` guard).
- Warm-up loads the catalog without any search/browse (diagnostics
  shows 3 rows after the warm-up delay); diagnostics reports the full
  readout (3 rows, 12 categories, per-category probes, filter counts).

### Flipped / reworked existing tests

- `test/services/iptv/iptv_build10_diagnosis_test.dart` — H1 FLIPPED:
  a disabled EN initial no longer hides EN-named shows (the category
  here is "Action", which carries no initial). T1/T3 comments updated
  to the post-fix reading; header notes the redesign supersedes the
  (h) fix. T1/T2/T3 expectations still hold under the race (the timing
  fakes return a never-completing unfiltered load, so the race cannot
  rescue those matches). G1/G2, I1, R1, W1, S1 unchanged.
- `test/services/iptv/iptv_stage2_test.dart` — the initials group
  reworked for categories: fake's CATEGORIES now carry the repeating
  initials (EN ×11 = 6 live + 5 VOD; NF ×9 = 1 VOD + 8 series);
  detection expects `[('NF', 11), ('EN', 6)]`; browse/search/Live TV
  expectations hold under category filtering (the ES channel moved to
  its own "ES - Live" category so the Live TV test still isolates it).
- `test/utils/iptv_initials_test.dart` — rewritten for
  `categoryInitial` / `countCategoryInitials` ("|EN| UK SERIES" → EN,
  "24/7 ACTION…" → "24/7", "AR …" → AR, plain names → ungrouped).
- `test/widgets/iptv_initials_checklist_test.dart` — both fakes
  reworked for category counts (same expected labels "EN (11)",
  "NF (9)"; alphabetical test "EN (11)", "FR (8)", "UK (13)"
  unchanged).
- `test/screens/settings/edit_iptv_connection_screen_test.dart` and
  `test/screens/iptv/iptv_screens_test.dart` — same fake rework;
  tests renamed "Category initials…".

## Verification (this build)

- `flutter analyze --no-pub`: **49 issues, exactly the pre-existing
  wakelock_plus baseline, zero in build #10 code.** (One transient
  50th — an unnecessary `dart:typed_data` import in the dialog test —
  was removed.)
- Suites green per directory (never combined, never concurrent):
  `test/services/iptv/` **124/124** (was 110; +14 new),
  `test/utils/` **840/840**, `test/widgets/` checklist **5/5** (+9
  utils initials tests in the combined run — 14 total across the two
  files), `test/screens/settings/` **199 pass + 3 skipped**,
  `test/screens/iptv/` **17/17**, `test/screens/livetv/` +
  `test/screens/search_screen_test.dart` **92/92**,
  updater services **28/28** (downloader 6 + installer 5 +
  update_service 17).
- Credential grep on the diff: clean (only the word "token" in
  comments about text tokens; test passwords use the split `'pa'
  'ss'` pattern; no real credentials).
- **Test-environment note:** `/tmp` is a 512 MB tmpfs — a big test
  dir's compiler output (~460 MB) fills it; stale
  `/tmp/flutter_tools.*` dirs from killed runs filled it twice during
  this build and the test compile failed with "No space left on
  device" (which looks like a hang — the tool prints nothing while it
  waits). Clean them before big suites.

## Proven by test vs needs Matt's phone

- **Proven in fixtures:** the redesign hides whole regions by
  category initial and restores them; item names are never filtered;
  search finds series with most initials hidden + EN shown, with
  Show-all, with per-category [] + slow unfiltered load, with the load
  landing mid-sweep, and with a never-completing unfiltered load via
  the sweep; the startup warm-up loads the catalog; the diagnostics
  readout reports the right numbers; the updater downloads + installs
  (see `IPTV_UPDATER_NOTES.md`).
- **Unproven until his phone:** series search against the real 46k-row
  Trex catalog on LTE (the fixtures model the panel shapes, but the
  real panel's timing is the thing that has beaten three builds); the
  real GitHub download + install prompt on phone and TV; whether the
  category-initials list on his real 833 categories is usable (EN/UK/
  FR counts will be in the hundreds — the list is alphabetical, but
  its length on the real provider is untested). If search still fails,
  the "Series catalog" readout in IPTV settings settles in one
  screenshot whether the catalog loads (unfiltered rows + the first 3
  per-category probes).
- **What the fixtures cannot prove:** a search whose unfiltered load
  takes longer than the 50s section budget on LTE still returns [] on
  the FIRST search (the warm-up + the second search are the mitigation;
  the sweep is the fallback). Say so plainly if he reports it — do not
  claim the budget problem is solved, only that both sources are now
  raced and the warm-up exists.
