# PlezTV build #23 — local-only search (v1.0.6-2.25.0+178)

Audit finding #4 (full audit §6) + the search-offline research: build #21
capped the search burst at 8 and split the health verdict, but a cold/stale
search still made panel requests (up to ~96 concurrent before #21; 237
category requests + 3 unfiltered loads after). Every peer searches a local
store — TiviMate (local indexed SQLite DB at playlist-update, 0 requests
during search), IPTVMac 0.9.8 (SQLite FTS5, prefix terms), IPTVnator 0.25.0
(trigram FTS, substring ≥3 chars), OpenTV (Room/SQLite, 6h WorkManager sync,
`replaceCatalogue` merge by stable streamId, chunked upserts, delete-stale
by sync-stamp, never delete-all), Hypnotix (whole-list sync at load, 8h TTL,
empty list = cache-miss). This build closes the gap to zero: the whole
catalog (live channels, VOD movies, series) is synced to a local FTS index
once, and search reads only that index.

Matt's decisions: the catalog is downloaded once and checked once a week
(default, user-changeable) plus a manual refresh; a popup says "refreshing
Trex details" while it loads all the titles for movies, TV (series) and
channels; Settings → IPTV shows how big the IPTV cache is. Startup rule
(Matt, 2026-11-10): the app must NOT reload everything from Trex every
time it starts — it opens from the local synced catalog file only; the ONLY
panel traffic for the catalog is the scheduled refresh and the manual
refresh button; splash/startup must not wait on a catalog fetch.

## What changed

- NEW `lib/services/iptv/iptv_search_index.dart` (~800 lines): dedicated
  SQLite file via `package:sqlite3` directly (NOT the main Drift
  AppDatabase — the index is rebuildable cache, isolated from the main DB;
  avoids a v26 migration + build_runner churn). File
  `<documents>/iptv_search_index/iptv_search_index.db` (documents dir, NOT
  cache). One file for all IPTV connections (`connection_id` column). WAL
  mode + `PRAGMA busy_timeout = 30000`. Schema: `iptv_search_item`
  (connection/type/stream_id/category_id/name/name_norm/thumb/rating/
  container_ext/summary/epg_channel_id/has_archive/archive_duration; PK
  connection/type/stream_id) + `iptv_search_fts` — FAT FTS5
  `fts5(name_norm, conn, type, id, tokenize='trigram')` carrying the key
  columns + `iptv_search_category` + `iptv_search_meta`
  (row_count/last_sync_ms). `ftsPattern`: quoted tokens ≥3 chars joined
  with spaces = AND; prefix and substring both match; special chars quoted
  (`"a&e"` → 0 rows, no throw); <3-char token → LIKE fallback on
  `name_norm` (still local-only). Candidate cap 5000 (per-section output
  still capped at 100 by the append builders; the aggregation re-ranks).
  `sqlite3: ^3.5.0` added as a direct dependency (was transitive via
  drift). CLI probe (sqlite3 3.45.1): a slim FTS with the filter applied
  after the join is catastrophically slow at Trex scale (rare series needle
  11 s, rare movie 190 s, common-needle count 43 s); fat FTS (filter on
  `fts.conn`/`fts.type` inside the scan): rare series 0.001 s, rare movie
  0.001 s, common count 0.27 s. Query plan: `SCAN fts VIRTUAL TABLE INDEX`
  + `SEARCH i USING INTEGER PRIMARY KEY (rowid=?)`.
- Writes in a background isolate via `compute`:
  `writeIndexTypeInBackground(IndexWriteParams)` parses both bodies
  (jsonDecode + `parseFlexibleJsonList` + fromJson, same shape as
  `XtreamApi`'s isolate parsers, no nested compute), then atomically
  replaces the type's rows in ONE transaction (delete type rows from
  item+fts+categories, insert fresh, upsert meta). Shared `createSchema`
  so the two paths cannot drift. Seed completeness guard (in the isolate):
  categories empty → skip `'no-categories'`; rows cover < 50% of the
  categories → skip `'partial'` (a crawl-shaped/partial source would make
  search MISS rows with no heal to cover the gap; the type stays cold so
  the fallback sweep still heals).
- `lib/media/iptv_client.dart`: sync engine (`syncSearchIndex` /
  `ensureSearchIndexSynced` / `seedSearchIndexFromDisk`), per type,
  sequential — (1) interval check (skip `'up-to-date'` unless forced;
  manual-only interval 0 skips unless forced); (2) fetch category list +
  unfiltered catalog (6 requests total per sync); (3) guards as one choke
  point — empty response keeps old rows (`'empty-response'`), partial (<
  half the indexed rows, when the index has rows) keeps old rows
  (`'partial'`), oversize → `XtreamCatalogTooLargeException`
  (`'oversize'`), never delete-all; (4) write via `compute`; progress
  callback (`IptvSearchSyncProgress`: type/phase
  `fetching`/`writing`/`done`/`skipped`/rows/reason) drives the popup;
  `AbortController` aborts between types (already-synced types stay).
  Writes serialized by a generic `_runIndexWrite<T>` mutex. The sync also
  writes the raw catalog body + category list to the disk cache and
  publishes the fetched rows into the memoized futures
  (`_publishSyncedCatalog`), so browse/search see the fresh rows without a
  restart. A disk-write failure never fails the sync (index is primary).
  Disk seed: the three warm-ups each fire-and-forget
  `_maybeSeedSearchIndexFromDisk()` (shared through the mutex, runs once)
  — the seed reads the three disk catalogs + category files and writes the
  index via `compute`, so the index is warm within seconds of upgrading
  with NO network. Warm-ups are disk-only now (`_warm*CatalogFromDisk`
  read the disk catalog into the memoized future, never fetch; fresh
  install with no disk file = no-op, the background sync populates disk +
  index and a browse/search in that window uses the old cold-fetch
  fallback). Search path (index-first, per section):
  `_searchMoviesFromIndex` / `_searchSeriesFromIndex` /
  `_searchLiveFromIndex` — return matches when the index is warm for the
  type (category names from the index alone, no panel round trip; rows
  mapped back to Xtream models so the append builders run unchanged with
  the hidden-category filter, prefix strip, favourites, hidden channels);
  return null when cold (caller falls through to the warm/cold disk/sweep
  paths). Trace: `loadSource = 'index'`, `loadRows` = index row count.
  Scope inversion — INDEX-PATH-ONLY (deliberate, preserves #21):
  `_searchItemsInner` calls all three sections always and passes
  `include` (from `excludedLibraryIds`); each section runs the index
  branch regardless of scope (global first; the aggregation filters by
  scope), but when the index is cold an excluded section is skipped
  (`trace.skipped = true`, no sweep for rows the caller drops) and an
  included one falls back to the warm/cold paths. `clearCatalogCache()`
  also clears the connection's index rows (only when the index was already
  opened). `close()` closes the index + disposes the notifier and is
  idempotent. `searchIndexState` / `searchIndexStateNotifier`:
  `ValueNotifier<IptvSearchIndexState>` (rowCounts, lastSync, syncing,
  seeding, totalRows/isWarm/isEmpty/isBusy). `clearCatalogForNewDataSource()`
  (awaitable: clears the disk catalog + deletes the connection's index
  rows even when this client never opened the index).
- `lib/services/iptv/xtream_api.dart`: `XtreamCatalogTooLargeException` +
  `XtreamApi.maxCatalogResponseChars = 300000000` (300 MB cap, enforced in
  the three UNFILTERED catalog getters only, after `_fetchBody`, before
  `compute` parse). Per-category bodies are small and uncapped.
- `lib/services/multi_server_manager.dart`: `addIptvConnection` calls
  `client.ensureSearchIndexSynced()` after the warm-ups, before the health
  probe (fire-and-forget). On client replace (`oldClient != null`) it
  awaits `client.clearCatalogForNewDataSource()` BEFORE the warm-ups, so
  the new client starts cold and the background sync fetches the new
  source. A first bind clears nothing; filter-only re-bind reuses the
  client (early return, no clear).
- `lib/services/settings_service.dart`: `iptvCatalogSyncIntervalHours` —
  `IntPref('iptv_catalog_sync_interval_hours', defaultValue: 168)`, in
  `_portableOnlyPrefs` (rides export/import). Choices 6/12/24/168/0
  (manual only). Falls back to 168 when Settings is not initialized
  (tests).
- `lib/screens/settings/iptv_settings_screen.dart`: Playlist section gains
  the interval `SettingSelectionTile<int>` (168 → `catalogSyncWeekly`,
  0 → `epgManualOnly`, else `epgHoursCount`), the "Sync catalog now" tile
  → `_syncCatalogNow` (Xtream clients only; shows `_CatalogSyncDialog`
  when there is at least one, else a `noConnections` snackbar), and
  `_CatalogCacheSizeTile` (`ValueListenableBuilder` on the first Xtream
  client's `searchIndexStateNotifier` + `FutureBuilder` summing
  `IptvSearchIndex.totalFileSizeBytes()` + per-connection
  `IptvCatalogDiskCache().sizeBytes(id)`; shows `ByteFormatter.formatBytes`
  + live/movie/series counts, or `catalogCacheEmpty`). NEW
  `_CatalogSyncDialog` (per-type progress rows for Live TV / Movies / TV
  Series with counts, Cancel wired to an `AbortController` — aborts
  between types, already-synced types stay — barrier-dismissible so the
  sync continues in the background, Done/OK on completion, failed state
  shows `catalogSyncFailed`).
- `lib/screens/search_screen.dart`: NEW `_CatalogHealthLine` (under the
  search field in the `!hasSearched` empty state, a `SliverToBoxAdapter`
  before the `SliverFillRemaining` message): `ValueListenableBuilder` on
  the first Xtream client's notifier; shows `catalogSyncing` when busy,
  `catalogNotSynced` when empty, else `catalogUpdated` with live/movie/
  series counts + `DateFormat.MMMd` date. The provider is OPTIONAL
  (try/catch on `ProviderNotFoundException` → hidden) — widget tests that
  pump the screen without a `MultiServerProvider` must not crash (this
  was a real breakage: the first version threw and failed 27 search-screen
  tests with focus-scope assertions).
- `pubspec.yaml`: `sqlite3: ^3.5.0` direct. Version
  1.0.6-2.25.0+178. `lib/i18n/en.i18n.json`: `about.changelog2270` (3
  bullets, top of the About list) + 19 new `iptv` keys; regenerated with
  `dart run slang` (Strings 51197 → 51216). Slang drift note: the regen
  re-chunked three pre-existing switch blocks (the `_ => null,}?? switch
  (path) {` boundaries moved) — LEGITIMATE re-chunking from adding 19
  keys, NOT the #22 no-op drift; analyze is clean and the new keys
  resolve.
- `lib/screens/settings/about_screen.dart`: changelog entry for
  1.0.6-2.25.0 at the TOP (newest first).

## Measured numbers (in-harness, fake panel)

- Trex scale (55k live / 200k VOD / 46,527 series = 301,527 rows): sync
  16.8 s, 6 requests, index file 162,195,488 bytes (154.7 MB). The
  30–60 MB estimate given to Matt on 2026-11-09 was low — the real number
  is ~155 MB (the harness rows carry fuller fields + WAL). CLI benchmark
  (301k synthetic rows): item inserts 1.21 s, FTS build 1.62 s (slim) /
  2.22 s (fat), DB size 68.82 MB (slim) / 79.47 MB (fat).
- Warm search: 0 panel requests, all three sections `loadSource=index`,
  GoT found, seriesRows=6.
- Search latency (1 warm-up discarded + 10 measured): common needle
  ('Movie Title', ~200k matches, 5000 candidates scored) median 531.5 ms,
  p95 1195 ms; rare needle ('game of thrones', 1 row) median 2.5 ms, p95
  5 ms. The 2s common-p95 bound is the worst-case tail from scoring 5000
  candidates — GC / isolate scheduling — still an order of magnitude
  under the old 29s network heal at cap 8.
- Sync: 6 requests per sync (3 category lists + 3 unfiltered catalogs).
  Second sync inside the interval → 0 requests, `skipped={live,movie,
  series: up-to-date}`. Forced sync → 6 requests.
- Guards: empty → `skipped={series: empty-response}`, rows kept (6);
  partial (10 of 100) → `skipped={series: partial}`, rows kept (100);
  oversize → `skipped={series: oversize}`, rows kept (6).
- Startup: warm-index bind total=1, userInfo=1, catalog=0 (the health
  probe is the only panel call at startup); due weekly refresh bind
  total=7, userInfo=1, catalog=6, waitedMs=200 (the bind returns after
  the health probe while the sync runs in the background); the sync also
  refreshed the disk catalog (series disk fetchedAt < 2 min old). After
  both binds, a search costs 0 more requests and finds GoT. Stale-disk
  warm-up + search: 0 unfiltered catalog requests (3 on base).
- Scope inversion: scoped search (movies excluded) — movies section
  `skipped=false`, `loadSource=index`, 0 requests; the client returns the
  global pool, the aggregation filters. Aggregation + Plex: Trex-scoped
  search titles=[GoT only], trexRequests=0.

## Tests

- NEW `test/services/iptv/iptv_build23_local_search_test.dart` (4,
  failing-first): disk seeding, warm-ups, `searchItems`,
  `lastSearchDiagnostics.loadSource`. Fixtures: 5 categories/type; GoT
  series_id 219 in category 1219 (last); a row named `'Filler Common 0'`
  in EACH type. `_waitForIndex` polls an unscoped search for
  `'Filler Common 0'` until all three sections report
  `loadSource == 'index'` (10s timeout; on base the index never exists →
  poll times out → `expect(warm, isTrue)` fails). Failing-first
  CONFIRMED on base `d937a1797`: all 4 fail. On the fix, all 4 PASS
  (16 s).
- NEW `test/services/iptv/iptv_build23_local_search_new_api_test.dart`
  (16, only compiles on the fix): sync engine, guards, interval setting,
  cache-size measurement (empty-schema size 98,696 bytes on open; 222,296
  bytes after syncing 18 rows), FTS matching (substring/prefix,
  multi-token AND, special chars, <3-char LIKE fallback), scope
  inversion, aggregation + Plex, Trex-scale bench, manager-level startup
  bind. All 16 pass. Notes: the oversize guard is tested via an
  `_OversizeSeriesApi` subclass throwing `XtreamCatalogTooLargeException`
  past `_fetchBody` (a panel throwing from `send()` gets wrapped by
  `_fetchBody` into `MediaServerHttpException`, so the subclass is
  required); the fake Plex is modelled on `iptv_build19_probes_test.dart`'s
  `_PlexLikeFakeClient`.
- NEW `test/services/iptv/iptv_build23_startup_test.dart` (2,
  failing-first, pre-fix API only): seeds the disk catalog then backdates
  every file's mtime 2 days (the disk cache takes fetchedAt from file
  mtime, so the catalog reads as STALE, older than the 24h TTL). Counts
  UNFILTERED catalog requests only (the warm-up's crime is the whole-
  catalog re-download; the search's cold path still fetches the 3 category
  lists — the sweep's lifeline). Failing-first CONFIRMED on base
  `d937a1797` via a temporary base worktree (created, test copied in,
  run, worktree removed — verified gone): stale disk = 3 unfiltered on
  base (FAIL, expected 0), fresh disk = 0 on base (control, passes). On
  the fix: stale disk unfiltered=0, categoryLists=3, total=3; fresh disk
  unfiltered=0, categoryLists=3. Both pass.
- `test/services/iptv/iptv_build17_toggle_test.dart` UPDATED to the #23
  world (product fix done, test update was the remaining item): the test
  set `IptvCatalogDiskCache.debugDisableDisk = true` and `waitForWarmUps()`
  polled for ≥1 unfiltered call per type, which relied on the warm-ups
  fetching. Under #23 the warm-ups are disk-only, so the test now seeds
  the disk catalog (the fixture rows + categories) and sets
  `IptvSearchIndex.debugDirectoryProvider` to the same temp dir, and
  `waitForWarmUps` polls the bound client's `searchIndexState` until
  `isWarm && !isBusy` (the seed warms the index from the seeded disk, so
  the sync skips and no unfiltered calls are expected before the toggle).
  The URL-change test now waits for the background sync re-fetch
  (`waitForRefetch` polls until the unfiltered counts rise). This update
  also exposed the real URL-change correctness gap the product fix
  closes: without the manager's `clearCatalogForNewDataSource` on
  replace, a new data source would serve the old source's cached catalog.
  Both tests pass.
- `iptv_epg_cache_test.dart` "Clear guide deletes the persisted files and
  stays empty until refresh" is a KNOWN PRE-EXISTING timing flake
  (fire-and-forget XMLTV feed write racing the test's 1s poll): it fails
  under default parallel load on this 1.5-CPU VM and passes alone (21/21)
  and with `--concurrency 2` (full iptv suite 296/296). It is NOT a #23
  regression — #23 does not touch the EPG write path; the heavy Trex-scale
  bench running in parallel makes the pre-existing race more likely to
  fire. Run the suite with `--concurrency 2` on this VM.
- Suites: `test/services/iptv/` 296/296 (concurrency 2),
  `test/screens/livetv/` 102/102, `test/screens/search_screen_test.dart`
  30/30, aggregation bridge + #19 probes 51/51. #21 suite 8/8, #19 probes
  10/10 (one expected fail-open warning per test client: "search index
  unavailable … MissingPluginException" — those tests don't set the
  index's debug provider; the index is attempted once per client via the
  memoized future, then falls back). Analyze repo-wide 49 = baseline (all
  vendored wakelock_plus, zero in `lib/`).

## Version

1.0.6-2.25.0+178. Changelog `about.changelog2270`. About entry at the top
of the list.

## Deliberately left out / UNPROVEN

- Cold-start browse/search before the first sync lands: on a fresh install
  (no disk, no index) the warm-ups are no-ops and the sync takes ~15–30s
  in the background; a browse/search in that window uses the old
  cold-fetch fallback (the loaders still fetch when there is no disk
  file). The sync is the designed path; the cold-fetch is the safety net.
- Category lists on the cold search path: the search's disk/sweep
  fallback still fetches the 3 category lists (they are the sweep's
  lifeline for #19's heal). They cost 0 when the index is warm. Making
  the category loaders disk-only would break #19's sweep.
- Search-screen health line follows the first Xtream client (not the
  scoped connection) — the scoped connection is a build-local in the
  search screen, only set when hidden matches exist; the line is a global
  catalog-health line, which is correct for its purpose.
- The sync dialog's "no Xtream clients" case shows the existing
  `noConnections` snackbar (closest string; Matt has a Trex connection,
  so this path rarely fires).
- Debounce stays 500ms (the research recommendation to drop it toward
  100ms once local-only was NOT implemented in #23 — the search is local
  now, but the debounce change was not part of the build).
- Phone behaviour is UNPROVEN until Matt's phone decides — all
  in-harness numbers are lab measurements, not proof. In particular: the
  panel accepts the sync's 6-request shape, the ~155 MB index on the
  phone, and a warm search feels instant.
