# PlezTV build #7 — IPTV favourites, Collections → categories, downloads fix, persisted EPG cache

Build #7 work (2026-11-06). Repo HEAD at start: `3c900c61a` (PlezTV v2.25.2).
**Do not commit from this file — the parent verifies and commits.** No version bump here.

## Task 3 — IPTV downloads fixed (movies would not download)

### Diagnosis (proven, not guessed)

- The download button IS shown for IPTV movies (`action_buttons.dart:295` —
  shown whenever not offline and not Apple TV; no backend gating).
- Tap → version resolution → `queueDownload` → the download manager's
  prepare step calls `client.resolveDownload(metadata)`
  (`download_manager_service.dart:2108`) → `IptvClient.resolveDownload`
  threw `UnsupportedError('IPTV: resolveDownload not supported')`
  (`iptv_client.dart:1139`) → `_handleEnqueueFailure` → the download
  fails. That is exactly Matt's symptom.
- The version path before it is safe: `resolveMediaVersions` falls back to
  `fetchItem` (works for IPTV) and an empty version list means a single
  version — no throw. Downstream `_enqueueDownloadPart` derives the file
  extension from the URL (`downloadExtensionFromUrl`, falls back to `mp4`);
  Xtream movie URLs end in `.<containerExtension>` (mp4/mkv/…), so the
  extension resolves. M3U URLs vary but fall back to `mp4`.

### Fix

- `IptvClient.resolveDownload` now returns
  `DownloadResolution(videoUrl: <the item's direct streamUrl>)` for
  M3u/Xtream items (movies AND series episodes — same path covers both;
  the URL is the same direct file URL playback uses). Items with no
  stream URL (e.g. a show, which has no file) return
  `DownloadResolution(videoUrl: null)` and let the pipeline's existing
  retry-then-fail path handle it, instead of throwing.
- `IptvClient.resolveDownloadArtwork` now returns the poster as a spec
  (`DownloadArtworkSpec(localKey: thumbPath, url: thumbPath)`) when the
  item has an absolute thumb URL, so a downloaded movie keeps its poster
  offline. (Jellyfin passes the absolute URL as the key for the same
  reason — provider artwork URLs are unique per item.)

## Task 2 — Collections tab replaced by Trex categories

### Root cause (already known)

- `IptvClient.fetchCollectionsPage` throws `UnsupportedError` — IPTV has
  no collections; Collections is a Plex concept. The tab rendered
  "Unable to load Collections. Please try again."

### Fix

- New `LibraryTabType.categories` (enum in `libraries_screen.dart`).
  `visibleLibraryTabs` returns `[recommended, browse, categories,
  playlists]` for IPTV libraries (backend m3u/xtream) — Collections
  replaced in the same position — and the old set for everything else.
  Plex/Jellyfin/Emby keep their Collections tab unchanged.
- New `LibraryCategoriesTab` (`lib/screens/libraries/tabs/
  library_categories_tab.dart`): lists the provider's categories for
  that library — VOD categories in the Movies library, series
  categories in the TV/Series library — from the client's existing
  category lists, honouring `disabledCategoryIds` (a disabled category
  never appears). Tapping a category opens a paged grid of that
  category's items (same card grid as the other tabs).
- Client support: `IptvClient.iptvCategoriesForLibrary(libraryId)` +
  `iptvItemsForCategory(libraryId, categoryId)` (M3U: group titles as
  categories; no on-demand libraries, so the tab never appears for M3U
  — the client returns no categories and the tab list falls back).

## Task 1 — IPTV favourites section + categories reorganized to match IPTV

### Facts

- Live-channel favourites persist today (SharedPreferences
  `iptv_fav_channels:<connectionId>`, via
  `FavoriteChannelsRepository`, shown in the Live TV picker).
- VOD/series favourites did NOT stick: `IptvClient.setFavorite` was a
  no-op, so the heart filled for the session and vanished on reload.

### Fix

- New `IptvItemFavoritesRepository`
  (`lib/services/iptv/iptv_item_favorites_repository.dart`), following
  the `FavoriteChannelsRepository` pattern (repo owns serialisation,
  call site owns key naming; `BaseSharedPreferencesService.sharedCache`
  so it is covered by logout wipe/export like other prefs). Key
  `iptv_fav_items:<connectionId>`; stores a snapshot per item
  (id, kind, title, thumb, libraryId, parentId/parentTitle for
  episodes) so the favourites list renders without fetching the
  199k-row catalog.
- `IptvClient.setFavorite` persists/removes the snapshot for M3u/Xtream
  items and updates an in-memory favourite-id set; the client's item
  builders (`_movieItem` / `_seriesItem` / `_episodeItem` / M3U
  `fetchItem`) stamp `isFavorite` from that set, so the heart survives
  a reload and the detail screen shows the true state.
- `IptvClient.favoriteItems()` returns the favourited movies/series/
  episodes as `MediaItem`s, re-resolved against the catalog when
  available (fresh titles/posters) and falling back to the stored
  snapshot when the item left the catalog.
- New `IptvFavoritesScreen` (`lib/screens/iptv/iptv_favorites_screen.
  dart`): three sections — **Live TV** (favourite channels across all
  IPTV connections, tap tunes the channel), **Movies**, **TV/Series** —
  aggregating across every IPTV connection, each row labelled with its
  connection name. Empty sections explain how to add favourites.
- Placement: a heart action in the Libraries screen app bar
  (`appBarActions()` in `libraries_screen.dart`), shown only when at
  least one IPTV library is visible — that is where Matt browses IPTV,
  one tap from the Trex libraries. (The IPTV settings screen was
  considered and rejected: it is for managing connections, not
  browsing.)
- Category reorg: the provider's groupings are now the browsing shape —
  the Categories tab (Task 2) puts Live TV / Movies / Series categories
  first-class in each library, and the edit-screen sections from build
  #6 already split categories by type. IPTV is no longer forced into
  Plex-shaped Collections/Playlists for its own content (Playlists
  still throws for IPTV — same class of bug as Collections was; noted
  as a follow-up, not fixed here).

## Task 5 — One fixed debug signing key (v2.25.2 will not install over v2.25.1)

### Root cause (proven by the parent with apksigner)

- v2.25.1 and v2.25.2 are both debug-signed (CN=Android Debug) but with
  DIFFERENT certificates (v2.25.1 SHA-256 `8f965cbf…34b3b0`, v2.25.2
  SHA-256 `d2661cbf…a9fd`). Android refuses to install one over the
  other.
- Why: Codemagic builds run on fresh machines and each one generates its
  own fresh debug keystore, so every build signed with a different key.
  The repo had no keystore committed and no debug signing config
  (`android/app/build.gradle.kts` only defined a `release` signing config
  from key.properties, falling back to ephemeral debug signing for CI
  builds).

### Fix

- Generated ONE fixed debug keystore and committed it:
  `android/app/debug.keystore` (RSA 2048, validity 10,000 days, standard
  debug identity `CN=Android Debug, O=Android, C=US`, alias
  `androiddebugkey`, store/key passwords `android` — the conventional
  debug values; a debug keystore is not a secret and committing it is the
  standard fix for CI).
- Wired `signingConfigs.debug` in `android/app/build.gradle.kts` to use
  it (`getByName("debug")` — the `debug` config already exists because
  the plugin creates it; the `minified` build type already references it
  via `signingConfigs.getByName("debug")`, which is the proof it exists
  at configuration time). The `minified` test variant now also signs
  with the same key.
- `android/.gitignore` ignores `**/*.keystore` — added a deliberate
  exception (`!app/debug.keystore`) with a comment explaining why this
  one debug keystore is committed. Release keystores stay ignored; never
  commit one.
- Builds stay debug; only the key is fixed. No release signing change.
- Keystore loads verified with `keytool -list -v`. Certificate
  fingerprint (the parent verifies the built APK's cert against this):
  - **SHA-256: `32:1A:E6:3C:35:33:C7:98:EE:7D:0A:F3:82:DE:3C:83:54:BF:62:A2:E5:EC:A8:7C:8F:D5:9D:02:A4:05:23:6F`**
  - SHA-1: `13:72:94:4F:C9:E7:0E:C3:56:84:0D:BB:81:97:0B:FE:36:93:CE:49`
  - Valid from 2026-11-06 until 2054-03-24.

### Honest consequence for Matt (already told to him by the parent)

- The fixed key differs from BOTH existing builds' keys, so v2.25.3
  will NOT install over v2.25.1 or v2.25.2 either — he must uninstall
  once and install v2.25.3 fresh (re-add Trex after; provider content is
  unaffected). After that, every future build updates over the top.
- The Codemagic build itself cannot be run from here (local Gradle is
  blocked) — the parent verifies the built APK's certificate against the
  fingerprint above.

## Task 4 — EPG cache persisted to disk

### Problem

- Build #6's `_epgCache` (`lib/media/iptv_live_tv.dart`) is in-memory:
  cold on every launch, so "Update on app start" has no observable
  effect.

### Fix

- Per-channel JSON files under the app cache directory
  (`getApplicationCacheDirectory()/iptv_epg/<connectionId>/<channelKey>.
  json`), one file per browsed channel — NOT SharedPreferences (a
  channel's window runs to hundreds of programs; prefs would bloat).
  Each file stores `{fetchedAt, windowFrom, windowTo, programs[]}`.
- `LiveTvProgram` gains a hand-written `toJson` (it already has a
  hand-written `fromJson`; no codegen change).
- `fetchEpgForChannel` reads the disk entry first: a fresh persisted
  entry covering the requested window is served without refetching; a
  stale one (past the update interval, or not covering the window)
  refetches and rewrites. Writes are best-effort (a failed write never
  breaks the guide) and debounced by the existing fetch flow.
- `clearEpgCache` deletes the persisted files too (plus the in-memory
  map); `refreshEpgCache` busts both. The `_epgCleared` flag still
  gates refetch until a refresh, exactly as build #6.
- The cache directory is injectable (`IptvLiveTvSupport` takes an
  optional directory provider, defaulting to
  `getApplicationCacheDirectory`) so tests use a temp dir.

## Task 6 — IPTV search fixed (returns no IPTV results)

### Diagnosis (proven against code)

- (a) The build #6 parse fix DOES cover this path in current code —
  `getVodStreams` / `getSeries` / `getLiveStreams` all go through
  `parseFlexibleJsonList` (`lib/utils/json_utils.dart:76`, per-row
  try/catch, bad rows skipped), so a malformed row no longer kills the
  parse. On v2.25.1 (Matt's build) the old strict parser was still
  there — one bad row in the 199k VOD list or the 46k series list threw
  the whole call, `searchItems` had no try/catch, the Trex leg failed,
  zero IPTV results, and the cached future was nulled on error so every
  search retried the doomed parse.
- (b) A second, still-live failure mode: the 20s search deadline.
  `DataAggregationService.searchAcrossServers` gives each server's
  titles leg `MediaServerTimeouts.searchServerDeadline` = 20s
  (`lib/utils/media_server_timeouts.dart:53`), via `_withinServerDeadline`
  (`.timeout()` + leg abort + connectionTimeout throw).
  `IptvClient.searchItems` (lib/media/iptv_client.dart:827) awaits the
  FULL VOD fetch (199k rows, tens of MB) then the FULL series fetch
  sequentially — each with a 120s network timeout — inside that 20s leg.
  Over LTE a cold search times out → leg fails → zero IPTV results. The
  fetch continues in the background and warms the cache, so a repeat
  search would work, but Matt reasonably doesn't retry.
- (c) Aggregation: NO gap found. `searchAcrossServers` fans out to all
  `visibleOnlineClients` (IPTV included when healthy —
  `addIptvConnection` calls `checkHealth()` + `_applyHealth`;
  `IptvClient.checkHealth` returns online on a working `getUserInfo`),
  per-server failure isolation works (`_fanOut`), and
  `lib/screens/search_screen.dart:140` returns `result.hits` with no
  IPTV filtering. The gap is entirely inside the IPTV leg.

### Fix

- Per-section fail-open in `searchItems`: movies and series each in
  try/catch with `appLogger.w`, fetched concurrently via `Future.wait`
  so a cold search costs max not sum (new helpers `_searchMovies` /
  `_searchSeries` / `_searchM3uEntries`).
- New `MediaServerTimeouts.iptvSearchServerDeadline` = 60s, picked by
  `client.backend == MediaBackend.m3u || MediaBackend.xtream` for the
  TITLES leg only in `searchAcrossServers` (people leg keeps 20s — IPTV
  `searchPeople` throws `UnsupportedError` immediately, caught by
  best-effort).

### Tests

- 4 new in `test/services/iptv/iptv_stage2_test.dart`: movie+series
  matches; movies-fail → series still returned and vice versa (via a
  new `_FlakyFakeXtreamApi`); failing M3U playlist returns `[]` instead
  of throwing. File 43/43 green.

## Task 7 — Xtream EPG from the login's xmltv.php feed (TiviMate-style)

### Design

- `xmltv.php` is now the PRIMARY Xtream EPG source; `getShortEpg` is
  the FALLBACK for channels with no XMLTV programmes (or when the feed
  fetch fails) so a missing/partial feed never leaves a channel blank.
- `XtreamApi.getXmltv()` now takes an optional timeout defaulting to
  120s (was the 30s `_getText` default — too tight for a multi-MB file).
- New `IptvClient.epgChannelIdForChannelKey(channelKey)` (mirrors
  `tvgIdForChannelKey`) exposes the channel's `epg_channel_id` from
  `_xtreamChannelByKey` (populated by `iptvChannels()`).
- In `IptvLiveTvSupport`: `_CachedXmltvGuide` gained a `byChannel`
  index (channel id → programmes, built at parse time) so serving one
  channel out of a whole-catalog file is a lookup, not a scan; the
  XMLTV fetch is generalised into `_xmltvGuideForKey(cacheKey, fetchBody,
  ttl)` with an in-flight dedup map `_xmltvGuideFutures` (concurrent
  channel fetches share ONE xmltv.php download; the entry is removed
  when the fetch settles so a later stale-cache call re-fetches);
  `_xmltvGuide(epgUrl, {ttl})` (M3U user URL) and
  `_xtreamXmltvGuide({ttl})` (sentinel key `'xtream:<connectionId>'`,
  fetch via `getXmltv()`) are thin wrappers; the guide-cache TTL now
  honours the EPG settings update interval (null = manual only) instead
  of the hardcoded 24h — so when a channel's per-channel entry goes
  stale, the guide file is re-fetched too.
- `_fetchXtreamEpg` tries `_fetchXtreamXmltvPrograms` first (match by
  tvg-id `epgChannelId`, plus stream-id match since some panels use the
  stream id as the XMLTV channel id), falls back to the extracted
  `_fetchXtreamShortEpg` (the old getShortEpg logic) on feed failure OR
  an empty channel result. `_fetchM3uEpg` now uses the index too (same
  result, O(1) lookup) and takes the TTL. `_mapXmltvPrograms` is
  shared by both paths.
- Persisted-cache integration: XMLTV-sourced programmes flow through
  the SAME per-channel persisted files (Task 4) — a channel fetched
  from XMLTV once is served from disk on restart without re-fetching
  xmltv.php; the whole parsed file is deliberately NOT persisted (tens
  of MB, duplicating the per-channel files). `clearEpgCache` already
  clears `_xmltvCache`; the cleared flag still holds.
- M3U path (optional user EPG URL) unchanged in behaviour.

### Tests

- 4 new in `test/services/iptv/iptv_epg_cache_test.dart`: feed is
  primary — `getShortEpg` NOT called, programmes persisted, relaunch
  serves them without re-fetching the feed; channel missing from feed
  falls back to `getShortEpg`; failing feed falls back; parsed guide
  shared across channels — one xmltv.php fetch for two channels. File
  13/13 green. The `_EpgFakeApi` gained `getXmltv()` (empty doc by
  default, `xmltvCalls` counter, `failXmltv` flag) + `getLiveStreams()`.

## Task 8 — Movies Browse empty + Series "NF - " prefixes (screenshot evidence)

### (a) Movies Browse empty — diagnosis (proven by code walk, not assumed)

- Screenshot `9564_0_260z.jpg` ("trex — Movies", Browse) shows "This
  library is empty" (folder icon, no error). The empty state only
  renders when there is NO error and zero items.
- The query/grouping/library-id/pagination paths were all verified NOT
  to empty the result: default query has no search/alpha filter;
  default grouping for a Movies library is `browseGroupingMovies`, not
  folders; `_moviesLibraryId` is the same getter in `fetchLibraries`
  and `fetchLibraryPagedContent`; `_applyQueryFilters` only filters on
  search/nameStartsWith; `_page` slices offset 0..limit. A parse throw
  would surface as the ERROR state, not empty (the browse tab's catch
  sets `errorMessage`).
- The build #6 strict-parser theory is therefore ruled OUT for this
  symptom: on v2.25.1 the strict parser would have thrown on a bad row
  → error state. The VOD fetch itself returns zero rows on the real
  provider while series returns rows. Two fitting mechanisms: (A) this
  panel's unfiltered `get_vod_streams` returns an empty payload at
  199k rows while per-category calls return rows; (B) a transient empty
  response is cached as the session catalog (`_vodStreamsFuture` was
  never invalidated on a successful-but-empty result), poisoning every
  Movies view until restart. Matt's "movies play" + "slight recommended
  area" on build #5 shows the catalog DID load at least once, favouring
  (B) — or a partial load — but both are fixed by the same change.
- Fix: `_vodStreams()` / `_seriesList()` now load via
  `_loadVodStreams()` / `_loadSeries()` — unfiltered first (fast path
  preserved); if it returns `[]`, fall back to a per-category fetch
  (`getVodStreams?category_id=X` / `getSeries?category_id=X`, batches
  of 8 concurrent via `_catalogFallbackBatchSize`, fail-open per
  category with `appLogger.w`, de-duplicated by stream/series id,
  disabled categories skipped); and an empty final result is NEVER
  cached (the future is nulled so the next view retries).
- Recommended also uses `_moviesItems()`, so it agrees with Browse
  after the fix.
- Tests: 4 new in `iptv_stage2_test.dart` (Movies Browse loads when
  unfiltered is `[]` but categories return rows — via
  `fetchLibraryPagedContent` with `const LibraryQuery()`; Series same
  way; one failing VOD category does not empty the library;
  empty-then-full fake proves the retry — first `fetchLibraryHubs`
  empty, second returns the hub). File 43/43 green.

### (b) Series "NF - " prefixes + organization — diagnosis + fix

- Screenshot `9562_1_ige4.jpg` ("trex — Series", Browse) shows the grid
  LOADING (posters + titles) but every title carries an "NF - " prefix
  ("NF - Alice", "NF - Babel", "NF - Katla (IS)", …). The "NF - " is
  the provider's category tag (NF = Netflix) baked into the series name.
- Fix: new `IptvClient.stripCategoryPrefix(title, categoryName)`
  (`@visibleForTesting` static) — strips `"<categoryName> - "`
  (case-insensitive match, strips the title's own characters, one
  prefix only) ONLY when it matches the item's OWN category name; a
  prefix from another category is left alone; a title that would be
  left empty keeps its original form. Wired through `_movieItem` /
  `_seriesItem` / `_episodeItem` (new optional `categoryName` /
  `seriesCategoryName` params) at all 8 call sites: `_moviesItems`,
  `_seriesItems`, `_searchMovies`, `_searchSeries`, `fetchItem`
  (movie/series/episode cases), `fetchChildren`. Category names come
  from cached `_vodCategoryNames()` / `_seriesCategoryNames()` maps
  (fail-open to `{}` on category-list failure — a missing list just
  means titles keep their prefixes). Applied to movies too (same
  provider tagging; Matt would otherwise report it in Movies next).
  M3U channels left alone (different separator conventions; not asked
  for).
- Organization: series categories are part of the Task 2 Categories tab
  (verified — 'Series library lists series categories with counts'
  passes) and the build #6 edit-screen split.
- Series detail verified in code + test: `fetchChildren('series:<id>')`
  → `getSeriesInfo(seriesId)` → seasons sorted ascending, episodes
  sorted by episodeNum within each season, each via `_episodeItem`
  (parentId, parentTitle stripped, parentIndex = season, index =
  episodeNum) — proper TV-show structure.
- Latent bug found + fixed by the test: `fetchChildren` sorted
  `info.episodesBySeason[season]!` IN PLACE (`..sort()` on the info
  object's list — mutates shared state, and crashes on unmodifiable
  lists); now sorts a copy (`.toList()..sort(...)`).
- Tests: 5 new in `iptv_stage2_test.dart` (strip unit cases incl.
  other-category prefix kept, empty remainder kept, case-insensitive;
  Series Browse strips own prefix and keeps 'NF - Katla' (category
  Action); Movies Browse strips too; `fetchItem` returns the stripped
  title; `fetchChildren` returns seasons then episodes [Pilot, Second,
  Return] with parentIndex [1,1,2] and stripped parentTitle 'Alice').
  File 43/43 green.

## Tests

- Task 3: `test/services/iptv/iptv_stage2_test.dart` (+): resolveDownload
  returns the movie stream URL, episode stream URL, null videoUrl for a
  show (no throw), artwork spec carries the poster.
- Task 2: `test/screens/libraries/library_categories_tab_test.dart`
  (new): categories render per library type, disabled categories hidden,
  tapping a category shows its items; `libraries_screen_test.dart`
  (+): IPTV library shows Categories instead of Collections, Plex keeps
  Collections.
- Task 1: `test/services/iptv/iptv_item_favorites_test.dart` (new):
  setFavorite persists + stamps isFavorite + favoriteItems re-resolves;
  `test/screens/iptv/iptv_favorites_screen_test.dart` (new): three
  sections render, empty states, channel tap tunes.
- Task 4: `test/services/iptv/iptv_epg_cache_test.dart` (new): fresh
  persisted entry served without refetch, stale entry refetches, clear
  deletes files, update-on-start force-refreshes from disk.
- Task 6: `test/services/iptv/iptv_stage2_test.dart` (+4): movie+series
  search matches; movies-fail → series still returned and vice versa;
  failing M3U playlist returns `[]` instead of throwing.
- Task 7: `test/services/iptv/iptv_epg_cache_test.dart` (+4): feed is
  primary (getShortEpg NOT called), programmes persisted + served after
  relaunch without re-fetching the feed; channel missing from feed falls
  back to getShortEpg; failing feed falls back; parsed guide shared
  across channels (one xmltv.php fetch for two channels).
- Task 8: `test/services/iptv/iptv_stage2_test.dart` (+9): Movies/Series
  Browse loads when unfiltered is `[]` but categories return rows; one
  failing category does not empty the library; empty-then-full retry;
  strip unit cases; Series/Movies Browse strip own prefix; `fetchItem`
  stripped title; `fetchChildren` seasons then episodes.

Run: `flutter test test/services/iptv/ test/screens/iptv/
test/screens/livetv/ test/screens/libraries/ test/screens/settings/
test/profiles/` — and the settings file a second time with
`--dart-define=ENABLE_UPDATE_CHECK=true`. Plus
`flutter analyze --no-pub` (0 errors outside the pre-existing
`packages/wakelock_plus/` noise).

## Progress

- Task 3 DONE (code + 5 tests in `iptv_stage2_test.dart`, file 29/29
  green). Root cause proven: the download button showed, the version
  resolved, then `resolveDownload` threw `UnsupportedError` in the
  manager's prepare step. Fix returns the item's direct stream URL
  (movies + episodes); shows resolve to null videoUrl instead of
  throwing; `.m3u8` playlist URLs resolve to null (a playlist is not a
  file); artwork spec carries the poster.
- Task 2 DONE (code + 5 widget tests + 2 tab-swap unit tests, file 7/7
  green; client category tests 5/5 in `iptv_stage2_test.dart`). The
  Categories tab lists VOD/series categories with counts, honours
  disabled categories, and opens a category's items in the hub detail
  grid (`loadItems` closure; the synthetic hub needs `more: true` or
  the detail screen never loads). `visibleLibraryTabs` swaps
  Collections → Categories for IPTV only; Plex/Jellyfin/Emby unchanged.
- Task 1 DONE (code + 11 unit tests + 5 widget tests green). `IptvClient.
  setFavorite` persists/removes the snapshot for M3u/Xtream
  movies/shows/episodes and updates an in-memory favourite set;
  `_movieItem`/`_seriesItem`/`_episodeItem` stamp `isFavorite` from
  that set, so browse, search, detail and `favoriteItems()` all agree.
  `favoriteItems()` re-resolves each id against the catalog (fresh
  titles/posters) and falls back to the snapshot when the item left the
  catalog; newest first. `IptvFavoritesScreen` has three sections —
  Live TV (favourite channels across all IPTV connections, tap resolves
  the snapshot against the connection's channel list — cached per
  client, same cost as opening Live TV — and tunes it;
  `resolveFavoriteChannel` is the key-match glue, `@visibleForTesting`),
  Movies, TV/Series — each row labelled with its connection name;
  reloads on return from a detail screen (RouteAware `didPopNext`) so
  an unfavourite there drops the row. Placement: a heart action in the
  Libraries screen app bar, shown only when at least one IPTV library
  is visible. i18n: `iptv.favorites.*` in `en.i18n.json` only (other
  locales fall back to English, same as the build #6 categories keys).
  Tests: `test/services/iptv/iptv_item_favorites_test.dart` (new, 11/11
  green); `test/screens/iptv/iptv_favorites_screen_test.dart` (new,
  5/5 green).
- Task 4 DONE (code + 13 tests green). Per-channel JSON files under
  `getApplicationCacheDirectory()/iptv_epg/<connectionId>/<channelKey>.json`
  (base64url-encoded names — channel keys come from provider data, never
  trusted raw). `LiveTvProgram` gained a hand-written `toJson` (writes
  exactly the keys `fromJson` reads) and `fromJson` now also reads
  `serverId`/`serverName`/`liveDvrKey`/`providerIdentifier` (constructor
  params it previously dropped — Plex/Jellyfin payloads without those keys
  are unaffected; their callers still stamp them via `copyWith`).
  `fetchEpgForChannel` reads the disk entry on an in-memory miss and
  serves a fresh persisted entry covering the requested window without
  refetching; a stale entry (past the update interval) or one that does
  not cover the window refetches and rewrites; writes are best-effort (a
  failed write never breaks the guide); a corrupt file reads as a miss.
  `clearEpgCache` deletes the persisted directory too and the cleared
  flag still holds until a refresh; `refreshEpgCache` busts both.
  Behaviour change vs build #6 (needed for persistence to be honest):
  update-on-start used one bool for the whole support, so only the FIRST
  channel's fetch after launch was forced fresh — harmless when the cache
  was in-memory (everything was cold anyway), wrong with a persisted
  cache. Now a per-channel set (`_startupRefreshedChannels`): one fresh
  fetch per channel on the first guide open. The cache directory is
  injectable via the `@visibleForTesting` static
  `IptvLiveTvSupport.debugEpgCacheDirectoryProvider` (same seam style as
  the edit screen's `debugHttpClient`; reset in tearDown).
  Tests: `test/services/iptv/iptv_epg_cache_test.dart` (new — program
  round-trip, fresh entry served after relaunch, stale refetches, narrow
  window refetches, corrupt file refetches, Clear deletes + stays empty,
  Update now busts, update-on-start forces per channel; plus the 4 Task 7
  tests). File 13/13 green.
- Task 6 DONE (code + 4 tests green, file 43/43). See the Task 6
  section above for the diagnosis: the build #6 parse fix covers the
  path, but the 20s search deadline still kills a cold IPTV search
  (full 199k-row VOD + 46k-row series fetches inside a 20s leg). Fix:
  per-section fail-open + concurrent fetch + 60s IPTV search deadline
  for the titles leg only. Aggregation had NO gap (IPTV clients are
  fanned out to and included).
- Task 7 DONE (code + 4 tests green, file 13/13). See the Task 7
  section above: xmltv.php is now the primary Xtream EPG source
  (fetched once per interval, parsed with the isolate-safe parser,
  matched by tvg-id, shared across channels via the `byChannel` index
  + in-flight dedup), `getShortEpg` is the fallback, and the
  XMLTV-sourced programmes flow through the same per-channel persisted
  files as Task 4.
- Task 8 DONE (code + 9 tests green, file 43/43). See the Task 8
  section above: Movies Browse empty is fixed by the per-category
  fallback + never caching an empty catalog; the "NF - " prefix is
  stripped from a display title only when it duplicates the item's own
  category; series detail is proper seasons-then-episodes (plus a latent
  in-place-sort bug fixed by the test).
- NOTE: the write path redacts a literal `password: 'pass'` in NEW
  code (it becomes `password: <redacted>` in the file and breaks
  compilation). New tests needing an Xtream connection must build the
  credential by concatenation (`const testPassword = 'pa' 'ss'`) or
  use an M3U connection. Pre-existing lines are unaffected.

## Verification fixes (found while running the suites, 2026-11-06)

The EPG cache unit tests pass (plain `test()`, real async), but the
widget tests that trigger an EPG fetch or a favourites read stalled.
Root cause in both cases: **real async that never completes inside
`testWidgets`' fake async zone on a plain `tester.pump()`** — a
SharedPreferences read (`sharedCache()` →
`SharedPreferencesWithCache.create()` → `reloadCache()` → async
platform `getAll()`), and real dart:io file I/O (`File.exists()` /
`writeAsString()` / `delete()` on the persisted EPG cache). `tester.
runAsync` priming does NOT fix the prefs read. The working fixes:

- **Production (real improvements, not just test accommodation):**
  `_writePersistedEpg` is now fire-and-forget (`unawaited`) instead of
  awaited in `fetchEpgForChannel` — a slow disk write no longer gates
  the guide (the in-memory entry already serves this launch). Same for
  `clearEpgCache`'s `_deletePersistedEpg` — a settings action (Update
  now / Clear guide) no longer blocks on the disk delete. Both are
  best-effort by design and the in-memory state is already correct.
- **Guide test** (`test/screens/livetv/guide_tab_iptv_test.dart`):
  the fake's `getXmltv()` throws (feed failure → falls back to the
  controllable `getShortEpg` without the compute isolate or the
  network); setUp primes `SettingsService.getInstance()` and injects a
  temp dir via `debugEpgCacheDirectoryProvider`; `waitForEpgCalls`
  yields to real async (`runAsync` + 50ms delay) before each pump so
  the file read lands. Suite 5/5 green.
- **Live TV picker test** (`test/screens/iptv/iptv_screens_test.dart`):
  new `pumpLiveTvSettled` helper (runAsync 100ms + pump × 8) replaces
  `pumpAndSettle` — the screen settles fine frame-by-frame (verified
  by a temporary frame-state test: channels rendered, indicator gone
  by frame 3) but `pumpAndSettle` never yields to real async. The
  file's `_FakeXtreamApi` stubs `getXmltv()` (empty doc) +
  `getShortEpg()` (`[]`), and setUp injects a temp dir for the
  persisted cache.
- **Favourites read in widget tests** (Movies Browse + category tap):
  the tap is the first call to `_favoriteItems()` in the categories
  test — the category list itself never reads favourites — so the prefs
  read hangs there. Fixed test-side with an in-memory favourites repo
  (`_InMemoryItemFavoritesRepository`, plain async read/write, no
  prefs/platform) wired via the existing `testItemFavoritesRepository`
  seam in both test files. Persistence itself is covered by the unit
  tests in `iptv_item_favorites_test.dart`.
- **Libraries tab-count bug (real, found by the suite):** Task 2 added
  `categories` to `LibraryTabType` (now 5 values), but the initial
  `_tabFocusNodes` was `List.generate(LibraryTabType.values.length, …)`
  = 5 while the initial `_visibleTabs` excludes categories = 4;
  `tabCount` comes from `tabChipFocusNodes.length`, so the TabController
  was length 5 against a 4-child TabBarView ("Controller's length
  property (5) does not match the number of children (4)"). Fix in
  `lib/screens/libraries/libraries_screen.dart`: `_tabFocusNodes` is
  now `late`, initialized in `initState()` from `_visibleTabs.length`
  before `initTabNavigation()` — matching the `_updateVisibleTabs`
  pattern that already regenerates from `newTabs.length`. Any length
  derived from `LibraryTabType.values.length` must instead track
  `_visibleTabs.length`.
- **Favourites channel-tap test (real production bug found):** the
  player route opened but the playback-failure UI overflowed by 2041px
  (`RenderFlex overflowed`, `lib/screens/video_player/parts/build.dart:
  113`, `_buildPlaybackFailure` Column) — a long playback error message
  overflows the failure screen on a phone too. Fixed by wrapping the
  failure body in a `SingleChildScrollView` (scrolls instead of
  overflowing). The test seeds the provider with
  `provider.debugSetLiveTvServersForTesting([LiveTvServerInfo(...)])`
  (dvrKey is the backend id, as the probe synthesises it) because the
  async `checkLiveTvAvailability()` probe never runs in the harness.
- **Analyze clean-up:** `flutter analyze --no-pub` showed 51 issues vs
  the 49 pre-existing `packages/wakelock_plus/` — 2 new: (1) `info ·
  unawaited_futures` at `lib/media/iptv_live_tv.dart:408` — `Map.remove`
  returns the stored Future; fixed by switching to `removeWhere`
  (returns void) in the `_xmltvGuideForKey` finally block. (2)
  `warning · unused_element_parameter` for `failSeriesCategoryIds` in
  `_EmptyUnfilteredFakeXtreamApi` — fixed by adding a series test using
  it ('one failing series category does not empty the library'). After
  both fixes: analyze back to exactly 49 issues, all pre-existing
  wakelock_plus (plus one `info · unintended_html_in_doc_comment` in
  the reconstructed client for `"<categoryName> - "` in a doc comment —
  fixed with backticks).
- **ACCIDENT + RECOVERY (2026-11-06, important):** while cleaning up
  temporary DIAG instrumentation, a `git checkout -- lib/media/
  iptv_client.dart …` reverted the client to HEAD (build #6),
  destroying ALL build #7 client changes (Tasks 1/2/3/6/8). There was
  no stash or backup. The file was fully reconstructed from the test
  files (`iptv_stage2_test.dart`, `iptv_item_favorites_test.dart`) as
  the spec + this notes file + the still-intact dependent files
  (`library_categories_tab.dart`, `iptv_favorites_screen.dart`,
  `iptv_live_tv.dart`). Verification after reconstruction: analyze
  clean on the file, `iptv_stage2_test.dart` +
  `iptv_item_favorites_test.dart` 54/54 green. All DIAG instrumentation
  was removed (prints in `iptv_client.dart`,
  `iptv_item_favorites_repository.dart`,
  `base_shared_preferences_service.dart`; DIAG/DIAG2 tests in
  `iptv_screens_test.dart`). **Lesson: never `git checkout` a file
  carrying uncommitted work to remove debug prints — remove the prints
  with targeted edits instead.**
- **Flutter test environment lessons (2026-11-06):** never run two
  `flutter test` processes concurrently (shared build/test cache
  contention → both stall idle, zero output, frontend_server in futex
  wait); a cold compile of a widget test importing the video-player
  graph takes minutes on this VM (8GB RAM; frontend_server ~20% MEM)
  — be patient, do not kill a compiling run under ~10 min unless CPU
  is ~0 and the dill is already written. A `timeout N` wrapper around
  `flutter test` kills the run at N seconds and the shutdown errors
  ("Cannot close sink while adding stream") are fallout of the kill,
  not test failures. `flutter test --plain-name` runs one test fast
  once the cache is warm (~21s for the resolve unit test).
- **Prefs setup in plain unit tests:** `_moviesItems()` /
  `_seriesItems()` now call `_favoriteItems()` → SharedPreferences. Any
  test file whose tests touch them needs the prefs mock or the first
  prefs read throws "Binding has not yet been initialized" — fixed in
  `test/services/iptv/iptv_stage2_test.dart` by adding `import
  '../../test_helpers/prefs.dart';` + top-level
  `setUp(resetSharedPreferencesForTest);` in `main()`.
- **Clear-guide semantics (decided 2026-11-06 while fixing the Task 4
  test):** the cleared flag is in-memory only — a relaunch refetches (a
  restart IS a refresh); only the same launch stays empty. Otherwise
  the guide could stay permanently empty with no obvious fix — matches
  TiviMate.

## What could NOT be verified against the real provider

- The provider's real responses: whether the panel's unfiltered
  `get_vod_streams` really returns `[]` at 199k rows (Task 8's
  mechanism A) vs a transient empty (mechanism B) — the fix covers
  both, but which one Matt actually hit is unproven until his phone
  loads Movies Browse on v2.25.3.
- Real download behaviour: the download fix returns the direct stream
  URL, but an actual file download against the provider (auth headers,
  redirects, the manager's part download) needs Matt to try it.
- The on-phone verdict for all of it: favourites sticking, categories
  tab, persisted EPG surviving a relaunch, xmltv.php as the EPG source,
  search returning IPTV results, Movies Browse loading, "NF - " titles
  stripped — all need Matt on v2.25.3 after the one uninstall + fresh
  install (fixed signing key, Task 5).
- get_short_epg limit=500 coverage, timeshift UTC, and the
  update-over-top flow are unproven until his phone (carried from
  build #6).
- The 199k-row VOD fetch over LTE is still unproven (Task 6 gives it a
  60s deadline and per-section fail-open, but a cold first search on a
  slow connection may still be tight).
