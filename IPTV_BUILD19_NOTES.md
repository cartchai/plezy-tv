# PlezTV build #19 — v1.0.0-2.25.0 — scoped search leaks a Plex movie + series-leg repair

Search-only build. Version stays `1.0.0-2.25.0`, versionCode **172**
(keeps climbing from 171, so it installs over the top).

## The bug (v1.0.0-2.25.0, Matt's screenshot 2026-11-09 ~03:48 EST)

Search "game of" scoped to **Trex — Series**: the ONLY result is
"Sherlock Holmes: A Game of Shadows" from **HOME PC · Movies** — a PLEX
MOVIE under a Trex — Series scope, no Trex series rows at all. Build
#18's 7/7 probes passed in-harness but never modeled a Plex server
alongside Trex.

Two root causes (research
`~/workspace/tmp_work/plezy-tv-research19/RESEARCH_BUILD19.md`,
10 probes 4 pass / 6 fail on base):

1. **Plex leak (primary, app-side).** Scope was enforced in two places,
   both holed:
   - Hole A: `PlexClient.searchItems` IGNORED `excludedLibraryIds`
     (its comment claimed every row carries `librarySectionID`), while
     the aggregation keeps null-key rows by design — so an unattributed
     Plex row (external/shared shape) was filtered by NOBODY.
   - Hole B: `hiddenKeys` is built from `LibrariesProvider.libraries`
     ONLY, so if the Plex libraries aren't in that list the Plex key is
     never hidden and even an ATTRIBUTED row leaks.
   - Stale-list suspect DEAD (spinner replaces results while searching).
2. **Series leg (secondary).** The build #18 heal must reach category
   1219 (LAST of 237) inside the sweep deadline — works at 1 s/call,
   misses at 6 s/call; AND a partial unfiltered list (any non-empty =
   "complete") overwrites a good 46,527-row disk file, and a healing
   search never repairs the disk.

## The fix

### 1. Scope leak — explicit scope key (both holes)

- `DataAggregationService.searchAcrossServers` gains
  `scopedLibraryKey` (`lib/services/data_aggregation_service.dart`).
  New `_inScopedLibrary` drops every title row whose
  `libraryGlobalKey != scopedLibraryKey` — including unattributed rows
  from other servers. Applied AFTER the hidden-library filter; people
  are NOT filtered by the scope key (they span libraries; backends
  filter them by `excludedLibraryIds`).
- `SearchScreen.performSearchQuery` passes `_selectedLibraryKey` as
  `scopedLibraryKey` whenever the scope library is loaded — the same
  condition as the hiddenKeys block (`lib/screens/search_screen.dart`).
  A stale scope still behaves as All.
- **Why a key, not just hiddenKeys (design conclusion, proven):** P3 as
  written is unsatisfiable via `hiddenLibraryKeys` alone. From the
  aggregation's perspective P3 (hiddenKeys={trex movies}, attributed
  Plex row must die) is structurally identical to a two-server
  unscoped hide (hiddenKeys={plex:2}, Trex rows must live) — and bridge
  test `:724` pins that a single-server hide keeps unattributed rows.
  No aggregation rule on hiddenKeys alone can satisfy P3 + :724 +
  unscoped-hide together. The scope MUST be conveyed explicitly. The
  probe file documents this; the ORIGINAL probe (hiddenKeys only) was
  run on base first (4 pass / 6 fail) and is preserved in the research
  worktree for the tester to re-run failing-first.
- Hide-one ≠ scope-all-but-one is preserved: `_withoutHiddenLibraries`
  is untouched, and bridge test `:724` still passes (verified — see
  below).
- `PlexClient.searchItems` now filters client-side
  (`lib/services/plex_client.dart`), like `searchPeople` already does:
  attributed rows in an excluded section are dropped, and unattributed
  rows are dropped too — but ONLY when `excludedLibraryIds` covers
  every library on this server (memoized `fetchLibraries()`, fail-open
  on error). Hiding one library keeps unattributed rows, as `:724`
  requires.

### 2. Series leg — partial-list guard, heal repair, sliding window

- **P5a** (`lib/media/iptv_client.dart`, `_loadSeriesCached` /
  `_loadVodStreamsCached` stale-disk refresh): a partial unfiltered
  list must not overwrite a larger good disk file. Refuse the write
  when the new list is under half the file's row count (635 vs 46,527
  is refused; a genuine shrink that large overnight is implausible).
  The stale file keeps serving and the next warm-up retries the
  refresh. VOD audited — same bug class, same guard. (Live not
  changed: no crawl fallback, same shape but out of this build's scope;
  noted for a later build.)
- **P5b** (same file, warm branches of `_searchMovies` /
  `_searchSeries`): a healing search now repairs the disk. New
  `_repairDiskCatalogAfterHeal<T>` merges the swept categories' rows
  into the cached list (deduped by id), writes the merged list to disk,
  and swaps the in-memory memoized list so the next search does not
  heal again. AWAITED before the search returns (the next search / a
  disk read must see the repaired file). Generation-guarded like the
  other disk writes. Cost note: the merge re-encodes the whole catalog
  (~0.3 s for 46k series rows on the phone's scale), so it runs only
  on a healing search.
- **P4** (same file): `_sweepCatalogCategories` is now a SLIDING
  WINDOW — up to `batchSize` (32, unchanged) calls run concurrently
  and a finished call frees its slot immediately, instead of the
  batched `Future.wait` where one slow call held a whole batch
  hostage. AND `_sweepDeadline` moved from 90% (45 s) to 98% (49 s)
  of the section budget: at a uniform 6 s/call the 8-batch x 6 s
  packing minimum puts the last batch's landing at ~48 s, past 45 s
  no matter the scheduling — 49 s fits inside the 50 s section budget
  with room for the merge and the post-heal repair, and matches the
  0.98 remaining-budget factor the cold path already uses. The
  threshold moves to ~6.1 s/call; beyond that the section budget
  itself is the binding constraint.

## What did NOT change

- No re-migration of the 161 initials; the filter is untouched; the
  sweep batch size is unchanged (32); the version scheme is unchanged
  (`1.0.0-2.25.0`, versionCode 172).
- No Kotlin changes. No Trex credentials anywhere — fakes only.
- Live loader: P5a guard NOT applied (see above); the live refresh
  still overwrites with any non-empty unfiltered list.

## Verification (builder's own)

- Build #19 probes `test/services/iptv/iptv_build19_probes_test.dart`:
  **10/10** (P1, P2, P2b, P3, P4-fast, P4-slow, P5a, P5b, P6, P7).
  Failing-first confirmed on base before any product-code change with
  the ORIGINAL probe: 4 pass / 6 fail (P2, P2b, P3, P4-slow, P5a,
  P5b fail; P1, P4-fast, P6, P7 pass).
  - P4-slow: GoT found, sweepMatches=1, ms=48347, perCategoryCalls=265.
  - P5a: disk rows after refresh=46527, hasGoT=true, unfilteredCalls=1.
  - P5b: after healing search, disk rows=46527, hasGoT=true.
  - P2/P2b/P3: titles=[EN - Game Of Thrones (2011)] only; P3
    plexExcluded={} (the scope key, not hiddenKeys, closes it).
- `test/services/iptv/`: **239/239, all passed.**
- `test/screens/livetv/`: **102/102, all passed.**
- Aggregation/search suites (`test/services/data_aggregation_bridge_test.dart`
  incl. :724, `test/services/plex_search_test.dart`,
  `test/screens/search_screen_test.dart`,
  `test/screens/iptv_build13_search_screen_test.dart`): **84/84, all
  passed.** The :724 test
  ('searchAcrossServers drops hidden-library results and keeps
  unattributed ones') was also run on its own: passes.
- `flutter analyze`: **49 issues — exactly the baseline**, all in
  packages/wakelock_plus.

## UNPROVEN / open

- **Live-panel series validation is BLOCKED.** The panel currently
  serves only 635 series rows (all Netflix), GoT not among them, and
  category 1219 returns 0 rows — no app-side fix can find GoT until
  the panel recovers. The panel watch (every 2 h) reports recovery.
  The scope leak (P1/P2/P2b/P3) validates in-harness regardless of
  panel state and is the phone-provable half of this build.
- The series-leg fixes (P4/P5a/P5b) validate IN-HARNESS ONLY for the
  same reason.
- Which hole produced the phone's row (A or B) — both proven
  in-harness; the phone cannot discriminate without the provider-list
  state at search time. The fix closes both.
- Whether a Plex `/library/search?includeExternalMedia=1` row can
  carry `librarySectionTitle` without a `librarySectionID` — inferred
  from the card rendering ("HOME PC · Movies"), not from a Plex API
  doc. Either way, both holes are closed.
- People rows under a scope when the provider list is incomplete:
  people are filtered by `excludedLibraryIds` at the backend, not by
  the scope key — the same Hole-B shape, untested surface. (Titles
  are the phone's failure and are fully covered.)
- The Plex `_allLibrariesExcluded` fetch runs inside the search
  deadline; a slow `/library/sections` on a search that excludes
  libraries and returns unattributed rows could eat search time. It
  is memoized (once per client) and fails open.
- A healing search at uniform ~6 s/call returns at ~48.5 s, inside
  the 50 s section budget but with ~1.5 s of margin (the post-heal
  repair encode included). Above ~6.1 s/call the section budget
  itself binds — no app-side scheduling can beat it at batch 32.

## Phone gate (for Matt)

1. Search "game of thrones" scoped to **Trex — Series**: only Trex
   series rows (GoT among them once the panel recovers — while the
   panel serves 635 rows, expect NO Trex series rows anywhere,
   including TiviMate; that is the provider, not the app).
2. Same query scoped to Trex — Series must show NO Plex rows at all
   (the phone-provable half — works regardless of panel state).
3. Unscoped "game of thrones": no Plex movie under a Trex scope;
   Plex GoT still appears under All / Plex scopes (no over-filtering).
4. Other famous shows in ON categories (Matt's ask): same behaviour.
5. About shows 1.0.0-2.25.0; updater offers it to 2.25.13 installs.
6. Carry-over: Last search row shows load source + hidden count.
