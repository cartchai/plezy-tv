# PlezTV Build #11 — IPTV catalog disk cache (v2.25.7)

**Version:** 2.25.7+164. **Status:** code + tests done, committed locally on
`main`, NOT pushed, no Codemagic build started (parent handles that).

**The ask (Matt, 2026-11-06 ~21:19 EST):** "Can you have it cache the iptv
so loading doesnt take fucking forever." Images do NOT have to be cached —
"Movies series and live tv stuff."

## What it does

Every IPTV catalog is now stored on disk per connection, so a cold start
shows the saved copy immediately and the network only refreshes it in the
background:

- **Xtream:** live channels + live categories, VOD movies + movie
  categories, series + series categories.
- **M3U:** the playlist text itself (parsed on demand, same as before).
- **Images/posters/artwork: deliberately NOT cached.** Image loading is
  exactly as it was.

Behaviour: cold start reads disk first (no network wait). A fresh cache
(under 24h old) is served with zero API calls. A stale cache is still
shown immediately and a background refresh replaces it, then the UI
updates. A missing or corrupted cache falls back to a normal network fetch
and the bad file is replaced. "Refresh playlists" in IPTV settings clears
the disk cache too, so the next load refetches everything.

## Design

- **New file `lib/services/iptv/iptv_catalog_cache.dart`** —
  `IptvCatalogDiskCache` (const constructor). Opaque storage: it stores and
  returns raw bodies and never validates them; the client parses and treats
  an unparseable body as a miss (file deleted, network refetch).
- **Storage location:** app **documents** directory
  (`getApplicationDocumentsDirectory()`), NOT the cache dir — the OS may
  wipe the cache dir. Layout:
  `<documents>/iptv_catalog/<base64url(connectionId)>/<dataset>.json`.
  Datasets: `live`, `vod`, `series`, `live_categories`,
  `vod_categories`, `series_categories`, `m3u`. A file's mtime IS its
  fetched time, so no metadata envelope is needed.
- **Payload shape:** raw API payloads, re-serialized through the models'
  new `toJson()` (`XtreamCategory`, `XtreamLiveStream`, `XtreamVodStream`,
  `XtreamSeries` in `lib/services/iptv/xtream_api.dart`, API-shaped keys,
  same as `fromJson` reads) and parsed on demand with the same isolate
  parsers as the network path — one parse shape. `tv_archive_duration`
  is stored in SECONDS as held on the object (a seconds value > 366 passes
  through `fromJson` unchanged, so a 7-day archive = 604800s round-trips).
  New public parse helpers on `XtreamApi`: `parseLiveStreamsBody`,
  `parseVodStreamsBody`, `parseSeriesBody` (via `compute`),
  `parseCategoriesBody` (inline, <1k rows).
- **TTL:** 24h (`catalogCacheTtl`, `@visibleForTesting`, shrinkable in
  tests). Fresh = serve with no network. Stale = serve + background
  refresh. Empty results are never written (this panel's unfiltered call
  returns `[]` legitimately at 199k rows — an empty file would poison
  later loads).
- **Background refresh:** generic `_refreshCatalogInBackground` in
  `lib/media/iptv_client.dart` (fetch → write disk → generation re-check
  → swap the memoized future → `_notifyCatalogRefreshed()`). Failures are
  swallowed; the stale rows stay. M3U has its own refresh
  (`_refreshM3uEntriesInBackground`) because the playlist is raw text,
  not model rows.
- **Generation guard:** `_catalogGeneration` is bumped by
  `clearCatalogCache`. Background refreshes capture it at start and drop
  if it changed. Fire-and-forget writes are also generation-guarded: a
  write scheduled before a clear deletes its own file afterwards, so a
  late write can never resurrect a cleared catalog (regression test
  included).
- **UI update path:** `_notifyCatalogRefreshed()` reuses the existing
  #1646 machinery — `LibraryContentNotifier().notifyChanged(...)` with
  `itemsUpdated: true`. Libraries/Home tabs already subscribe and do a
  paced, scroll-aware, server-scoped in-place reload (visible tabs
  live-update; hidden tabs reload on next show). The Live TV guide does
  NOT listen to it; it re-reads the catalog on its next load (source
  switch, Reload). No shared-screen changes were needed.
- **Manual refresh:** "Refresh playlists" in IPTV settings
  (`_refreshPlaylists`, also busts EPG) is the refresh affordance — it
  calls the rewritten `clearCatalogCache()`, which now bumps the
  generation, clears all in-memory futures (including the new
  `_liveCategoriesFuture`), clears the channel-by-key maps, deletes the
  disk files and notifies. Pull-to-refresh in browse re-runs the load
  (fast from cache) and was deliberately NOT made to force a network
  refetch — that would re-download 199k rows.
- **Filters:** disabled categories / disabled category initials are
  applied at READ time on the parsed rows, never baked into storage —
  exactly as before. The build #10 category-initials redesign is
  untouched; `iptvInitials()` now reads the three category lists through
  the disk-backed `_liveCategories()` / `_vodCategories()` /
  `_seriesCategories()` (no catalog loads), and `_liveCategoryNames()`
  uses `_liveCategories()` too.
- **Search race (build #10) kept:** `_searchMovies` / `_searchSeries`
  still race the unfiltered load against the per-category sweep; the
  unfiltered load now reads disk on warm starts, which is what makes the
  race fast the second time. `warmUpSeriesCatalog()` in
  `MultiServerManager.addIptvConnection` is unchanged (it calls
  `_seriesList()`, which now hits disk). The "Series catalog" diagnostics
  row is unchanged. `getSeriesInfo` (per-series detail) is NOT cached —
  out of scope, small per-item call. `edit_iptv_connection_screen.dart`
  still probes `api.getLiveCategories()` directly (edit-screen probe, not
  the client path).
- **EPG caching (build #7) untouched** except reusing its patterns
  (directory seam, fire-and-forget writes, total methods). EPG still
  lives under the app cache dir; catalogs live under documents.

## Size on disk (measured, his provider scale)

Serialized with the real `toJson()` on realistic rows (names with
country prefixes, cover URLs, plots), then extrapolated:

| dataset | bytes/row | rows (Trex) | size |
| --- | --- | --- | --- |
| live channels | ~212 B | 55,205 | ~11 MB |
| VOD movies | ~269 B | 199,762 | ~51 MB |
| series | ~636 B | 46,461 | ~28 MB |
| categories (all three lists) | ~77 B | 833 | ~63 KB |
| **total** | | | **~91 MB** |

Real rows vary (longer plots, shorter names) — treat this as
order-of-magnitude. The stored payload is the re-serialized model subset,
so it is smaller than the provider's raw JSON (which carries fields the
models drop). Nothing is loaded into widget state all at once: the parse
happens in an isolate and the existing lazy/paged UI is unchanged.

## Tests

- **New `test/services/iptv/iptv_catalog_cache_test.dart` — 20 tests,
  all passing** (written failing-first; first run failed to compile:
  `IptvCatalogDiskCache` undefined). Fake API with scripted rows + call
  counters + `failAll` flag; temp dir + `debugDirectoryProvider`;
  `resetSharedPreferencesForTest` in setUp. Coverage: repo round-trip,
  missing → null, delete/clear/sizeBytes, TTL, cold read from disk with
  the API failing (live, movies, series incl. search finding a show,
  categories), fresh cache served with zero API calls, stale served then
  replaced by the background refresh, corrupt file → network + replaced,
  `clearCatalogCache` deletes disk + next load refetches, a write in
  flight when the cache is cleared does not resurrect the file,
  per-connection isolation, filters on disk data (disabled category +
  disabled initial hide disk-loaded items in browse and search), M3U
  playlist cache, `debugDisableDisk` makes the cache inert.
- **Existing suites re-run (all green):**
  - `test/services/iptv/` — **144/144** (was 124; +20 new).
  - search screen + Live TV — **92/92** (same as build #10).
  - `test/screens/iptv/` — **17/17**.
  - settings — **199 pass + 3 skipped**.
  - `library_categories_tab` + `edit_iptv_connection_screen` +
    `iptv_initials_checklist` — **18/18** combined.
  - `flutter analyze` — **49 issues = the pre-existing wakelock_plus
    baseline, zero in build #11 code.**
- **Known pre-existing failure — not chased:**
  `test/services/data_aggregation_bridge_test.dart` fails 12 tests
  (`NoSuchMethodError: _LibrariesClient.backend`) on pristine HEAD too.

## Two things found while testing (both fixed in this build)

1. **Widget tests hang on real disk I/O — `debugDisableDisk` seam.**
   `getApplicationDocumentsDirectory()` never resolves inside
   `testWidgets`' fake async zone (proven by probe: even
   `Directory.systemTemp.createTemp` hangs in a test body; a
   `runAsync`+pump loop takes ~3 iterations to land a read). The first
   run of the Live TV suite stalled 15 minutes on the guide test for
   this. The fix follows the codebase's own precedent: the favourites
   repository has an in-memory stand-in in widget tests for exactly this
   reason. New static `IptvCatalogDiskCache.debugDisableDisk` — when
   true, reads return null and writes/deletes/clears are no-ops. The six
   widget-test files that build real `IptvClient`s set it in setUp and
   clear it in tearDown: `guide_tab_iptv_test.dart`,
   `iptv_screens_test.dart`, `library_categories_tab_test.dart`,
   `iptv_favorites_screen_test.dart`, `iptv_initials_checklist_test.dart`,
   `edit_iptv_connection_screen_test.dart`. (The search screen test uses
   a stub client, so it needed nothing.) The disk behaviour itself is
   covered by the unit tests, which run with real async. The
   `debugDirectoryProvider` seam still exists for the unit tests.
2. **Flaky EPG test tearDown — retry added.** In the full-directory run,
   `iptv_epg_cache_test.dart: update-on-start force-refreshes from disk
   on the first guide open` failed once (1 in 2 runs) with
   `FileSystemException: Deletion failed … Directory not empty` in
   tearDown: a fire-and-forget EPG write landed mid-delete. Pre-existing
   race (the EPG cache writes are fire-and-forget); the extra async hops
   my catalog loads add to the shared client paths shifted the odds.
   The test file alone passes 14/14. Fix (test-only): tearDown retries
   the recursive delete once after a 100ms yield. After the fix the
   directory suite passed 144/144 twice in a row.
   Note: in plain `test()` (not `testWidgets`) the platform channel
   THROWS `MissingPluginException` instead of hanging, so the other
   services/iptv tests just log a warning per load and fall back to the
   network — same noise the EPG cache already makes there. Harmless.

## Changelog (2.25.7, in About, newest first)

- Your channels, movies and shows are now saved on the phone, so they
  load straight away instead of downloading every time you open the app
- When the saved copy gets old, the app shows it straight away and
  quietly fetches the new one in the background
- Refresh playlists in IPTV settings now clears the saved copy too, so
  you always get fresh data
- The saved copy is per connection, so two IPTV sources never mix each
  other up
- Pictures and posters still load from the internet as before — only the
  lists are saved

## Limits / unproven until his phone

- First launch after installing still downloads everything once (there
  is no cache yet) — the win is on every launch after that.
- The ~91 MB estimate is measured on realistic rows, not his real
  catalog; the real number will differ somewhat. There is no cache-size
  cap or eviction in this build — the only way to shrink it is "Refresh
  playlists" (clears) or clearing the app's data (which wipes logins
  too — do not suggest that lightly).
- A background refresh landing while a tab is visible triggers the
  existing paced reload (debounce 3s, cooldown 2m, blocked while
  scrolling or playing video) — the refresh itself is silent, no spinner.
- The Live TV guide does not live-update on a background refresh; it
  picks the new catalog up on its next load.
- Stale-while-revalidate means the first thing he sees after 24h is
  yesterday's catalog for a moment, then the fresh one.
- A background refresh that fails (no network) is silent — the stale
  rows stay, no error shown. That is deliberate, but it means a silently
  stale catalog looks identical to a fresh one.
- Not verified on a real device: cold-start time on LTE with the real
  55k/199k/46k catalogs, disk write time for ~91 MB on his phone, or
  the refresh landing while he is mid-scroll.

## Files changed

- `lib/services/iptv/iptv_catalog_cache.dart` (new)
- `lib/services/iptv/xtream_api.dart` (`toJson` ×4, parse helpers ×4)
- `lib/media/iptv_client.dart` (disk-first loaders, background refresh,
  generation guard, `_liveCategories()`, `clearCatalogCache` rewrite)
- `pubspec.yaml` (2.25.7+164), `lib/i18n/en.i18n.json` + generated
  `strings.g.dart` / `strings_en.g.dart` (`changelog2257`),
  `lib/screens/settings/about_screen.dart` (changelog entry first)
- `test/services/iptv/iptv_catalog_cache_test.dart` (new, 20 tests)
- `test/services/iptv/iptv_epg_cache_test.dart` (tearDown retry)
- 6 widget-test files (debugDisableDisk in setUp/tearDown)
- Signing keystore, applicationId, iOS bundle ID: untouched.
