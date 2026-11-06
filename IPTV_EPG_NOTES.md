# PlezTV build #6 — EPG, Series fix, categories, EPG settings, in-app update, no-information hour blocks

Build #6 work (2026-11-06). Repo HEAD at start: `6a2bd5804`. **Do not commit
from this file — the parent verifies and commits.** No version bump here.

## Task A — EPG wired (was: `fetchSchedule` returned `[]`, guide empty)

### Architecture: lazy, per visible channel — never the whole catalog

- `IptvLiveTvSupport.fetchSchedule` **still returns `[]`, deliberately.**
  The server-wide hook cannot name the channels the guide is actually
  showing, and one call per channel across 55,205 channels is not an
  option. The guide drives EPG lazily per visible channel through the new
  `IptvLiveTvSupport.fetchEpgForChannel(channelKey, {from, to})`
  (`lib/media/iptv_live_tv.dart`), called from the row builder
  (`_ensureIptvEpg` in `lib/screens/livetv/tabs/guide_tab.dart`) — so
  only browsed channels are ever fetched. The guide grid is virtualized
  (only visible rows build), which is what makes "visible channels only"
  true in practice.
- Per call the support fetches the **whole settings window**
  `[now − pastDays, now + daysToLoad]` for that one channel and caches it
  per channel (`_epgCache`), so scrolling re-uses it until the update
  interval elapses. Only the slice overlapping the requested `[from, to]`
  is returned.
- Xtream: `XtreamApi.getShortEpg(channelKey, limit: 500, timeout: 60s)`.
  Limit 500 covers ~10 days of half-hour slots; anything past the limit
  simply does not appear (hour placeholders fill the gap) instead of
  failing. One bad listing never invalidates the channel (per-listing
  try/catch). **The API's own `channelId` is NOT trusted for matching:**
  every mapped program gets `channelIdentifier: <the requested channel
  key>`, because that is what the guide indexes by
  (`_indexProgramsByChannel` / `liveTvProgramMatchesChannel`).
- Time offset (Task E) is applied in the mapper (`beginsAt/endsAt +
  offsetSeconds`). Empty titles fall back to `t.liveTv.unknownProgram`.
- Per-channel failure fails open: `fetchEpgForChannel` catches and logs,
  returns `[]` — the guide renders hour placeholders for that channel
  and never crashes.
- M3U: `lib/services/iptv/xmltv_parser.dart` (new, top-level `parseXmltv`,
  isolate-safe) parses the connection's optional XMLTV EPG URL
  (`_fetchM3uEpg`): programmes matched by `tvg-id` (= the M3U channel
  key), XMLTV times `YYYYMMDDHHMMSS ±HHMM` converted to UTC epoch,
  malformed `<programme>` entries skipped, document-level failure throws.
  The parsed file is cached per URL for 24h and parsed via
  `compute(parseXmltv, ...)` (provider files run to megabytes). M3U
  without an EPG URL, or entries without a `tvg-id`, degrade gracefully
  to an empty guide (placeholders) — no crash.
- `IptvClient` gained a public `xtreamApi` getter and
  `tvgIdForChannelKey(key)` for the support to use.

## Task B — subtle EPG loading indicator

- A thin `LinearProgressIndicator` (3px) directly under the guide's time
  navigation (`_buildTimeNavigation`), shown only while an IPTV EPG fetch
  is in flight (`_isIptvEpgLoading`, tracked per channel in
  `_iptvEpgInFlight` / `_iptvEpgLoaded` / `_iptvEpgFailed`). It
  disappears when the programs arrive. It is IPTV-only: Plex/Jellyfin/
  Emby keep their existing full-screen spinner / dim overlay.
- Timing rule (Task G): hour blocks appear ONLY once a channel's load has
  finished with no data. While loading, the row stays blank and the header
  indicator is the signal — never placeholders as a substitute for a load
  still in flight.

## Task C — Series didn't load: root cause found and fixed

- **Root cause (proven, not guessed):** `_parseSeries` (and
  `_parseLiveStreams` / `_parseVodStreams`) in
  `lib/services/iptv/xtream_api.dart` did
  `_asObjectList(...).map(X.fromJson).toList()` — ONE throwing row kills
  the whole catalog. `XtreamSeries.fromJson` has 8 `as String?` casts
  (`cover`, `plot`, `cast`, `director`, `genre`, `releaseDate`,
  `backdropPath`, `youtubeTrailer`) that throw on mistyped values (e.g. a
  numeric `cover`). The 46,461-row `get_series` response contains at
  least one such row → the isolate parse throws → `_seriesList()` fails
  → `_seriesItems()` throws → `fetchLibraryHubs(series)` throws (caught
  per-library by the aggregation service) while Movies loads — exactly
  Matt's symptom. `fetchGlobalHubs` was also vulnerable: `await
  _seriesItems()` threw AFTER the Movies hub was added, killing the
  whole home call.
- **Fix:** all three `_parse*` functions now use
  `parseFlexibleJsonList(_decodeCatalogJson(body), X.fromJson)`
  (`lib/utils/json_utils.dart:76` — parses every valid object
  independently, drops malformed rows). `fetchGlobalHubs`' series section
  is wrapped in try/catch (fail-open: log, keep the Movies hub).
- **Tests:** 3 new tests in `test/services/iptv/iptv_stage2_test.dart`
  ("Catalog parsing tolerates malformed rows": series/VOD/live payloads
  each with 2 valid rows + 1 mistyped row parse to the 2 valid rows, no
  throw), using the real `XtreamApi` with an injectable `MockClient`.

## Task D — categories split into three collapsible sections

- `lib/screens/settings/edit_iptv_connection_screen.dart` no longer
  merges the three category lists. Xtream now renders **Live TV /
  Movies / TV Series** as separate collapsible sections (header row with
  title, count or "N of M hidden", expand chevron), each listing only its
  own type's categories, sorted alphabetically as before, from the three
  existing API methods (`getLiveCategories` / `getVodCategories` /
  `getSeriesCategories`).
- All sections share the same `disabledCategoryIds` set: a category id in
  more than one section shows the same state in both, and toggling in one
  updates the other (proven by test: id `1` is News/Action/Action).
- "Show all / Hide all" applies across all three sections at once.
- Expanded/collapsed state persists per section (new prefs
  `iptvCategoriesLiveExpanded` / `iptvCategoriesMoviesExpanded` /
  `iptvCategoriesSeriesExpanded` / `iptvCategoriesGroupsExpanded`,
  default expanded) — a fresh instance of the screen reads them.
- M3U: groups have no live/VOD/series type — one plain **Groups**
  section, still collapsible and toggleable.
- Rendering stays lazy: the sections flatten into one row list for the
  `SliverList.builder` (one header row per section, then its categories
  only while expanded), so the provider's 800+ categories never build
  all at once.
- **Test seam:** `EditIptvConnectionScreen.debugHttpClient` (static,
  `@visibleForTesting`, null in production). Widget tests point it at a
  `MockClient` — real socket I/O does not survive the widget test
  binding's faked timers (proven the hard way: loopback-server + global
  `HttpOverrides` + `runAsync` all failed to deliver a request in a
  widget test). The seam feeds both the Xtream `XtreamApi` and the M3U
  playlist fetch; a client created by the screen is closed after the
  fetch, the injected one is left alone.

## Task E — EPG settings, modelled on TiviMate

New "EPG / TV guide" section on the IPTV settings screen
(`lib/screens/settings/iptv_settings_screen.dart`), prefs in
`SettingsService` next to `iptvShowCatchUpBadge`:

| Setting | Choices | Default | TiviMate equivalent |
|---|---|---|---|
| Days to load | 1 / 2 / 3 / 4 / 7 | 3 | Guide window (3–4 days recommended) |
| Update interval | 6 / 12 / 24 h, Manual only | 24 h | Update interval (24 h standard) |
| Past days to keep | 0 / 1 / 2 / 3 / 7 | 1 | Past days to keep (1; up to 7 for catch-up) |
| Update on app start | switch | OFF | Update on app start (usually Off) |
| Time offset | −120/−60/−30/0/30/60/120 min | 0 | Time offset per source |
| Update now | action | — | Manual "Update now" |
| Clear guide | action | — | "Clear guide" |
| Last updated | status line ("Never" before first load) | — | Last-updated status |

- The EPG layer honours them: the fetch window is
  `−pastDays .. now + daysToLoad`; the per-channel cache TTL is the
  update interval (0 = manual only, never expires on its own); "Update
  now" busts the cache and forces a fresh fetch on the guide's next
  build; "Clear guide" empties the cache **and stays empty** (a
  `_epgCleared` flag: `fetchEpgForChannel` returns `[]` without fetching
  until a refresh) — otherwise the guide's lazy refetch would undo the
  clear on its next row build. The guide watches `epgVersion` (bumped
  on every clear) to reset its per-channel state.
- **Update on playlist change (TiviMate: On) is NOT a separate toggle:**
  "Refresh playlists" already clears the catalog cache, and it now also
  busts the EPG cache (`refreshEpgCache()` alongside
  `clearCatalogCache()` in `_refreshPlaylists`) — same effect, one less
  control.
- **Honest limit — update on app start has no observable effect yet.**
  The EPG cache is in-memory, so it starts cold on every launch and the
  first fetch after launch is always fresh. The pref is read and the
  force-refresh path exists (`_startupRefreshDone`), so it takes effect
  once the EPG cache is persisted — but until then the toggle changes
  nothing observable. This is documented in the unit test file as well
  (`test/services/iptv/iptv_epg_test.dart`); do not present the setting
  as doing more than it does.

## Task F — in-app update (above About, from GitHub Releases)

- Plezy ALREADY had a full `UpdateService`
  (`lib/services/update_service.dart`) + an Updates section in Settings
  sitting directly above About — the work was repointing it at the fork,
  not building from scratch. `isUpdateCheckEnabled` requires the
  `ENABLE_UPDATE_CHECK` dart-define (default false) and `codemagic.yaml`
  did NOT pass it, so the section was compiled out of shipped builds.
- Changes: `_githubRepo` `'edde746/plezy'` → `'cartchai/plezy-tv'`;
  public `releasesUrl`; `useNativeUpdater` forced `false` (the fork has
  no appcast; the upstream jsdelivr feed would offer upstream Plezy
  builds); removed now-unused `_isHomebrewInstall` / `_isWingetInstall` /
  `_isInstalledApp` + the `dart:io` import; `_performUpdateCheck` now
  extracts the first `X.Y(.Z)` numeric run from the tag (`_extractVersion`,
  handles "v2.25.2", "2.25.2", "PlezTV v2.25.2"; a tag with no version →
  not an update, not a crash), picks the first `.apk`-suffixed asset
  (`_apkAsset`, suffix match only — GitHub stores spaced names dotted,
  e.g. `PlezTV.v2.25.2.apk`), and hardens `published_at` / `html_url`
  null-safety. Added a `@visibleForTesting debugCheckForUpdatesOverride`
  seam so widget tests can drive the paths without the network.
- Dialog (`lib/utils/update_dialog.dart`): version + current version +
  release notes ("What's new", scrollable) when present; "Download APK"
  primary button when an apk asset exists (opens the asset URL in the
  browser — the browser downloads it, tapping the download installs over
  the top); install hint text (browser download + allow "Install unknown
  apps" for the browser if asked); "This release has no APK attached yet"
  note + only "View release" when no apk asset. No native
  PackageInstaller flow — the browser-download flow is what upstream
  Plezy already does; a native installer is a possible later step.
- Settings: a "View releases on GitHub" tile (releases URL) in the
  fallback update branch, after the auto-check tile. The Updates group
  already sits directly above About.
- `codemagic.yaml`: build command now passes
  `--dart-define=ENABLE_UPDATE_CHECK=true`.
- **Caveats (tell Matt):** all current builds are debug-signed with the
  same debug key, so update-over-top works while the key stays the same;
  switching to release signing later WILL break it (signature mismatch)
  and must be handled then. The live v2.25.1 GitHub Release has NO APK
  asset attached (source archives only), so the updater will say plainly
  there is no APK for it — v2.25.2's release must carry its APK.

## Task G — clickable "No information available" hour blocks

- When a channel has no EPG data for the requested window, the guide
  fills its row with clickable placeholder blocks, **one per hour**,
  covering the window — and fills gaps between real programs the same
  way, hour by hour, for uncovered hours
  (`_withHourPlaceholders` in `guide_tab.dart`: real programs clipped to
  the window, covered intervals merged, clock hours walked, one
  placeholder per uncovered hour, partial edge hours clipped to the
  window). Each block is a real program entry (`LiveTvProgram` gained
  `isPlaceholder`, default false; key `no-info:<channel.key>:<beginsAt>`,
  title `t.liveTv.noInformationAvailable` — Matt's wording; TiviMate
  says "No information", Plezy's whole-row empty state says "No program
  data available" — the block wording is Matt's).
- Blocks are visually distinct: muted fill (surface at 0.3 alpha),
  title at 0.45 alpha in italics, subtitle at 0.3 alpha. Focus still
  inverts them for D-pad.
- **Placeholders are IPTV-only (regression caught by the full suite).**
  The first version merged placeholders for ANY ready channel, so a
  Plex row with a genuinely empty schedule gained blocks — breaking the
  pre-existing test "moving into a row with no programs focuses its
  channel cell" (D-pad down landed on a block instead of the channel
  cell). Fixed: `_getProgramsForChannel` only synthesizes placeholders
  when `_iptvSupportFor(channel) != null`. A Plex/Jellyfin/Emby row with
  no programs keeps the old behaviour (channel-cell focus + the "No
  program data available" bar, which the empty-row branch restores for
  non-IPTV rows; an IPTV row is blank only while its EPG is still
  loading, with the header indicator as the signal).
- Tapping one opens the same program detail sheet a real program would.
  The sheet's Record action never appears for placeholders (no guid —
  automatic). **Catch-up (placeholders only):** for a past block on a
  channel with `hasCatchUp` (`tv_archive = 1`), the sheet offers
  "Watch from start (N min ago)" (reusing the existing
  `t.liveTv.watchFromStart` string). It starts the archive at the
  block's own start time: `LiveTvSessionArgs.catchUpStartEpoch` →
  `navigateToLiveTv(..., catchUpStartEpoch:)` → `_startPlayback`
  computes the offset with the pure helper
  `liveTvCatchUpOffsetSeconds(...)` (negative offset from now, clamped
  into the archive window via the session's `CaptureBuffer`; null when
  there is no start, no buffer, or the start is at/after the live edge —
  then it falls back to a normal live tune). The watch-from-start prompt
  is bypassed for catch-up — the user already chose the slot. The same
  plumbing can extend to real programs later; the scope decision for
  this build is placeholders only.
- **Bug found by the widget test, fixed in the build:** the sheet's
  action buttons were a bare `Row` — the long catch-up label overflowed
  it by 64px. The actions now render in a `Wrap` (spacing 8): buttons
  stay side by side when they fit and drop to the next line when they
  don't. This also protects narrow phone screens.

## Tests (all new or extended, all green)

- `test/services/iptv/iptv_epg_test.dart` (new, 13 tests): EPG mapping
  (channelIdentifier = requested key, not the API's id), days window
  bounds the fetch, interval gates refreshes, Update now busts the
  cache, manual-only never expires, Clear stays empty until a refresh,
  per-channel failure fails open, time offset shifts programs, empty
  title → "Unknown Program", update-on-start loads (in-memory cache
  starts cold), `parseXmltv` (offsets to UTC, malformed rows skipped,
  bad document throws), M3U XMLTV end-to-end over a loopback server
  (tvg-id channel only; no-EPG-URL degrades gracefully). The loopback
  tests restore the real `HttpClient` via `HttpOverrides` — that works
  in a plain `test()`; it does NOT work in a widget test (see Task D).
- `test/screens/livetv/guide_tab_iptv_test.dart` (new, 5 tests): loading
  indicator while in flight (no placeholders, no full-screen spinner),
  no-EPG → hour blocks (5 per row in the tree at 1280px — slot width
  180px + one slot of overscan virtualizes the rest away), partial EPG
  → blocks only in uncovered hours, tap opens the detail with catch-up
  (archive channel), no catch-up action (non-archive channel).
- `test/screens/video_player/live_tv_catch_up_test.dart` (new, 5 tests):
  the offset helper (null cases, negative offset, live-edge null,
  archive clamp).
- `test/screens/iptv/iptv_screens_test.dart` (+1 test): the EPG settings
  section renders with its defaults and Update now / Clear guide
  announce themselves. Note: the screen is a lazy sliver list — the
  test scrolls rows into view; the second snackbar queues behind the
  first, so the test waits 5s for it.
- `test/screens/settings/edit_iptv_connection_screen_test.dart` (new, 5
  tests): three sections render separately, each collapses/expands
  alone, toggling a shared id updates every section, Show/Hide all
  across sections, collapsed state persists across screen instances,
  M3U single Groups section.
- `test/services/iptv/iptv_stage2_test.dart` (+3 tests): catalog parsing
  tolerates malformed rows (series/VOD/live).
- `test/services/update_service_test.dart` (+5) and
  `test/screens/settings/settings_screen_test.dart` (+3): version compare
  + latest-release parsing (incl. no-.apk release, malformed tag) and
  the Updates section above About. **The 3 settings widget tests only
  execute with `--dart-define=ENABLE_UPDATE_CHECK=true`; without it
  they skip.**

Run: `flutter test test/services/iptv/ test/screens/iptv/
test/screens/livetv/ test/screens/libraries/ test/screens/settings/
test/profiles/` — and the settings file a second time with the
dart-define. Plus `flutter analyze --no-pub` (0 errors outside the
pre-existing `packages/wakelock_plus/` noise).

## What could NOT be verified against the real provider

- Whether `get_short_epg` with `limit=500` covers multi-day windows on
  this provider, and what its real payload shape is (Base64 titles,
  `channel_id` values, listing counts per channel). The mapper is
  defensive about all three, but the real shape is unproven.
- XMLTV file size / latency for an M3U EPG URL (the 24h file cache and
  isolate parse assume a large file; no real file was fetched).
- The `/timeshift/` start-time UTC assumption is still unverified — the
  new Time offset setting is the mitigation, not a proof.
- The 199k-row VOD fetch over LTE is still unproven (from build #5).
- Whether the 55k-channel `fetchChannels` call survives on a real phone
  (unchanged from build #5).
- The update-over-top flow needs a real release WITH an APK asset to
  exercise end to end (v2.25.1's release has none).
- All of the above needs Matt's phone: the guide, the indicator, the
  hour blocks, catch-up from a block, the EPG settings, the update row.
