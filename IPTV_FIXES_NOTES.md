# Plezy TV — IPTV fixes (build #3 bugs, Matt's phone report 2026-11-05)

Work in progress, NOT committed or pushed. Fixes Matt's four reports from
build #3 (commit c128d1b06): the Movies "Unable to load Recommended" error,
"Trex — Live TV" appearing as a library, no way to switch the Live TV source
(HOME PC vs Trex), and the new IPTV settings area (now expanded to a
TiviMate-modelled settings screen at Matt's request).

Verify: `flutter analyze --no-pub` → 49 issues, all pre-existing
`packages/wakelock_plus/` noise, zero in touched files. Tests:
`test/services/iptv/` 16/16, `test/screens/livetv/live_tv_screen_test.dart`
12/12, `guide_tab_test.dart` 16/16, `live_tv_refresh_lifecycle_test.dart`
2/2, settings + connection suites 63/63 (combined run).

## 1. Live TV is no longer a library

`lib/media/iptv_client.dart` — `fetchLibraries()` no longer builds the
synthetic `"<Name> — Live TV"` library. Xtream returns only Movies + Series;
M3U returns an empty list (it has no on-demand catalog). The dead
`iptv:<id>:live` branch in `fetchLibraryPagedContent` is deleted.

`_liveLibraryId` / `liveLibrarySuffix` are kept as INTERNAL attribution ids
only (M3U channel items from `fetchItem` / `searchItems` still carry them so
search results can say where a channel came from). They are never listed as
a library anymore — verified by grep: the only remaining references are
those two item-attribution sites.

Tests updated in `test/services/iptv/iptv_stage2_test.dart`: M3U now expects
zero libraries; Xtream expects `[movies, series]`.

## 2. "Unable to load Recommended" fixed

Root cause: `IptvClient.fetchLibraryHubs` and `fetchGlobalHubs` threw
`UnsupportedError`. The Recommended tab (and Home) treat a throw as a load
failure, hence "Unable to load Recommended. Please try again."

`lib/media/iptv_client.dart`:
- `fetchLibraryHubs` returns one `MediaHub` titled "Recommended" whose items
  are the first `limit` entries of that library's catalog (Movies → movies,
  Series → series), reusing the lazy in-memory cache — no re-fetch per call.
- `fetchGlobalHubs` returns one hub per on-demand library, titled with the
  library name ("Trex — Movies", "Trex — Series") so Home can tell two IPTV
  sources apart. M3U returns `[]`.
- `fetchMoreHubItems` / `fetchMoreHubItemsPage` now expand a Recommended hub
  instead of throwing (hub ids carry their library id).
- Shared `_moviesItems()` / `_seriesItems()` helpers feed the paged browse
  AND the hubs, so both agree; both honour the disabled-category filter.
- New test-only injection: `@visibleForTesting set testXtreamApi` (and
  `testHttpClient`, see §5) so tests stub the catalog without network.
- New tests: hub for Movies, hub for Series, hub honours the
  disabled-category filter, global hubs, hub expansion — all fake-catalog,
  no network.

The Browse tab is untouched (it already worked via
`fetchLibraryPagedContent`).

## 3. Live TV source switcher (HOME PC vs Trex)

### Root cause (two parts)

1. **There was no switcher at all.** `LiveTvScreen._loadChannelsOnce`
   iterates every entry in `MultiServerProvider.liveTvServers` and MERGES
   all servers' channels into one list, sorted by channel number. With Plex
   + Trex connected the guide is one merged list — Matt could not pick a
   source, and the guide's source-group headers only appear when a channel
   row's source differs, which does not help when one source's channels
   never arrive.
2. **Trex's channels most likely never arrived.** Per-server failures are
   swallowed by the `onError` handler in `forEachLiveTvServer` (logged
   only); the screen shows an error ONLY when every server fails. Trex's
   `fetchChannels` pulls the provider's whole live list in one
   `player_api.php` call — 55,205 rows — with a 30s timeout, so on a slow
   connection it times out and only the Plex channels (1000–1009) remain,
   exactly matching Matt's screenshot. A second, smaller cause: the screen
   loads channels once in `initState` and never re-loads when a live-TV
   server binds late (e.g. an IPTV connection finishing its health probe
   after the screen opened), so a late Trex stayed invisible until a
   manual refresh.

### What changed

`lib/screens/livetv/live_tv_screen.dart`:
- Source picker chips above the guide, shown only when 2+ live-TV servers
  are connected: "All sources" + one chip per server by name (HOME PC,
  Trex), deduped by server id (Plex yields one entry per DVR). Picking a
  source filters the GUIDE only; What's On and Recordings are unaffected.
  Plex behaviour when Plex is selected is unchanged (same channels, same
  order, same grouping).
- When a picked source has no loaded channels, the guide shows an explicit
  empty state — "No channels loaded from Trex" + hint + Reload action —
  instead of a bare grid, so a fetch failure is visible and retryable.
- A provider listener reloads channels when the live-TV server set changes
  (late bind / server going offline), with a `_reloadAfterLoad` guard so a
  server that binds mid-load is picked up by one extra pass instead of
  waiting for a manual refresh. The listener's provider reference is saved
  in `initState` — calling `context.read` in `dispose()` crashes the
  widget tree (caught by `live_tv_screen_test.dart`, fixed).
- `MultiServerProvider.liveTvServerName(serverId)` added
  (`lib/providers/multi_server_provider.dart`), resolving through the
  manager's `serverDisplayName` (client name, falling back to the raw id).

`lib/services/iptv/xtream_api.dart`: the three big catalog calls
(`getLiveStreams`, `getVodStreams`, `getSeries`) now use a 60s timeout
instead of the 30s default — 55k/199k/46k-row responses deserve more time
on a slow connection.

Catch-up visibility (Matt: "make sure you can see when a channel offers
it"): `LiveTvChannel.hasCatchUp` added (`lib/models/livetv_channel.dart`,
excluded from JSON so no codegen regen was needed); `iptvChannels()` sets
it from the Xtream `tv_archive` flag. `GuideTab` renders a small history
badge at the top-left of the channel cell (mirroring the favorite star at
top-right) when the channel offers catch-up. The badge was NOT visible
anywhere before this change — `canTimeShift` existed only on the playback
session. A settings toggle gates it (see §4).

## 4. IPTV settings area (Settings → IPTV)

New screen `lib/screens/settings/iptv_settings_screen.dart`, reached from
Settings → Connections → **IPTV**. Reachable row added in
`lib/screens/settings/settings_screen.dart` (Connections section, after Add
connection). Sections:

- **Intro line:** IPTV live TV lives in the Live TV tab; Movies/Series live
  in the Library. Xtream guide data comes from the provider; for M3U the
  EPG URL is set when the playlist is added.
- **Connections:** live list from `ConnectionRegistry.watchConnections()`
  (M3U + Xtream only). Each row shows the user-given name + source label
  (M3U / Xtream Codes) + filter state ("All categories on" /
  "N categories off"). Tapping one opens its edit screen
  (`edit_iptv_connection_screen.dart` — country/region filter); saving
  rebinds so the new filter applies. Empty state when no IPTV connection
  exists. "Add IPTV connection" row opens the Add connection screen.
- **Playlist:** "Refresh playlists" — calls the new
  `IptvClient.clearCatalogCache()` on every bound IPTV client (drops the
  in-memory channel/movie/series caches so the next guide/library load
  re-fetches from the provider), then a "Playlists refreshed" snackbar.
  Targeted on purpose: a full rebind would recreate every server's client
  (including Plex/Jellyfin).
- **Guide & catch-up:** "Show catch-up badge" switch — new pref
  `SettingsService.iptvShowCatchUpBadge` (default on, registered in the
  prefs list; applies when the guide reloads). Same setting as TiviMate's
  "Show catch-up icon in channel list".
- **Player:** "Player settings" row linking to Plezy's existing Playback
  settings (decoder, external player, playback options) — IPTV uses the
  same player, so no duplicate controls.

`lib/screens/settings/edit_iptv_connection_screen.dart`: "Show all" /
"Hide all" buttons above the category checklist (TiviMate's Manage groups
has these — the fast way to reset a big country list).

i18n: new top-level `iptv` block + 4 `liveTv` keys (source picker/empty
state) + 2 `connections` keys (Show/Hide all) in `lib/i18n/en.i18n.json`;
slang regenerated (`dart run slang` — other locales fall back to English).

## 5. Category filter — verified and fixed

The country/region filter (`disabledCategoryIds`) was already honoured for
Xtream everywhere, but NOT for M3U in two places — fixed here:

| Surface | Xtream | M3U before | M3U now |
|---|---|---|---|
| Live TV channels (`iptvChannels`) | filtered | NOT filtered | filtered |
| Movies/Series browse (`fetchLibraryPagedContent`) | filtered | n/a (no libraries) | n/a |
| Recommended hubs | filtered | n/a | n/a |
| Search (`searchItems`) | filtered | NOT filtered | filtered |
| Direct item open (`fetchItem` by id) | not filtered (by design — direct access) | not filtered | unchanged |

Fix: `iptvChannels()` and `searchItems()` M3U branches now skip entries
whose `groupTitle` is disabled (M3U categories ARE group titles — the same
key the edit screen writes). New tests in
`test/services/iptv/iptv_stage2_test.dart` ("M3U category filter", fake
HTTP via `MockClient`, no network) cover both. The edit screen's filter
checklist already merges live + VOD + series categories for Xtream and
group titles for M3U, and renders lazily (800+ categories never build at
once).

## TiviMate settings comparison (research 2026-11-06)

Sources: Neighborhood Nerd TiviMate help page (full settings walkthrough),
iptvtips.com beginner tour, drogontvshop + euroskara + tvpikoma setup
guides, store.grapevine.is 2026 checklist, bestplaylistiptv.store.

TiviMate's Settings, mapped to Plezy TV:

| TiviMate setting | In Plezy TV now | Where |
|---|---|---|
| Playlists: add / name / URL / delete | Yes (add/edit via IPTV settings; delete stays in Profile detail — see below) | IPTV settings → Connections |
| Playlists: Manage groups (per-group on/off, Show all / Hide all, sorting) | Yes — on/off + Show all/Hide all (new). Group sorting/reorder: NO (see left out) | IPTV settings → connection → edit screen |
| Playlists: update playlist on app start / manual Update playlist | Partial — "Refresh playlists" (new, manual). No auto-update interval (see left out) | IPTV settings → Playlist |
| Playlists: Main TV Guide Source / Additional Guide Source, EPG URL per playlist | Stored only — M3U EPG URL is collected at add time; Xtream uses xmltv.php automatically. The guide itself is not wired yet (see left out) | — |
| Playlists: Catch Up on/off, Logos priority | Catch-up badge toggle: yes (new). Provider catch-up itself: always on when tv_archive=1, no per-playlist off switch. Logos priority: n/a (Plezy shows provider logos) | IPTV settings → Guide & catch-up |
| TV guide (EPG): sources, update interval, update on app start / on playlist change, manual update, clear guide, past days to keep, time offset, latest update status | NO — EPG data is not implemented yet (`fetchSchedule` returns `[]`, known gap from Stage 3). No dead toggles were added for it. | — |
| Appearance: logos, groups (show favorites / all-channels categories), channel numbers, catch-up icon, highlight current channel/group, guide preview, channels sorting, channel name editor | Partial — channel numbers + logos already render in Plezy's guide; catch-up icon now added (see §3). The rest are Plezy's own Appearance settings, not IPTV-specific. | Guide (built-in) + IPTV settings |
| Player: buffer size, audio/video decoder, AFR, audio pass-through, external player | Yes — via the existing Playback settings (linked from IPTV settings, not duplicated) | IPTV settings → Player |
| General: auto start on boot/wake, last channel on start, confirm exit, backup/restore | NO — not IPTV-specific; Plezy has its own settings/backup. Left out. | — |
| Remote Control: button mapping | NO — Plezy has keyboard shortcuts (Settings → Controls) for desktop; TV remote mapping is a Plezy-wide concern, not IPTV. Left out. | — |
| Parental Controls: PIN, block/hide channels/groups | NO — Plezy has no IPTV PIN (only the Plex-managed PIN). Adding a PIN + block/hide store is a real feature, not a toggle; noted as a follow-up, not faked. | — |
| Recording, multi-view, custom groups, favorites management | NO — deferred to v2 in the TVmagic plan; Plezy has no recording/multi-view. Left out. | — |

Left out deliberately (not dead toggles): EPG update interval/sources
(guide not wired), auto playlist refresh interval, group sorting/reorder,
parental PIN, recording/multi-view, backup/restore (Plezy's own settings
cover backup). Connection removal stays in Profile detail (its
`_removeConnection` does the full profile-join teardown — downloads
release, `removeProfileConnection`, rebind — which the IPTV screen does not
replicate).

## Analyzer / test notes

- `flutter analyze --no-pub`: 49 issues, all pre-existing
  `packages/wakelock_plus/` noise (pigeon/mocktail/DBus unresolved with
  `--no-pub`). Zero issues in touched files.
- During verification the Live TV test run hung once: cause was /tmp
  filling up (512M tmpfs, stale `flutter_tools.*` dirs from killed runs
  left the test compiler with "No space left on device"). Cleaned with
  `rm -rf /tmp/flutter_tools.* /tmp/flutter_test_*`; not a code issue.
  A `context.read` in `LiveTvScreen.dispose()` did crash the widget tree
  in tests — fixed by saving the provider reference in `initState`.
- `liveTvServerName` did not exist anywhere in the codebase (an earlier
  note claimed it was in `live_tv_matching.dart`); added as a real method
  on `MultiServerProvider` resolving via the manager's `serverDisplayName`.

## What remains

- Build #4 (Codemagic) with these fixes, then Matt re-tests on his phone:
  Movies Recommended, the missing "Trex — Live TV" library, the source
  picker (HOME PC ↔ Trex), and the IPTV settings screen.
- EPG: `fetchSchedule` still returns `[]` — the guide has no programme
  data for IPTV (known Stage 3 gap). The EPG URL is stored for M3U at add
  time; Xtream's xmltv.php is the source when EPG lands.
- `fetchChannels` still returns the provider's full live list in one call
  (55k rows); the UI must page it, and a paged `fetchChannels` variant is
  a bigger refactor (the `LiveTvSupport` interface is not paginated).
  Mitigations in this change: 60s timeout, source picker so only one
  source's channels are shown at a time, visible reload on failure.
- Local watch-state / item-favorite persistence (item `setFavorite` is
  still a no-op; only live-channel favorites persist).
- Timeshift timestamps use UTC (disputed point — verify against the real
  provider when testing catch-up).
- Follow-ups noted earlier, unchanged: `plezytv://` deep-link scheme,
  pruning the 24 alternate icons, wood TV banner, EPG URL editing for M3U
  (stored at add time only).
