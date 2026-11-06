# PlezTV working reference — Plezy fork internals

**Purpose:** the one document to open before touching this codebase. Every section
answers "to change X, look at Y". Practical, not an essay.

- **What this is:** PlezTV, a fork of [Plezy](https://github.com/edde746/plezy)
  (Flutter client for Plex / Jellyfin / Emby) with M3U + Xtream Codes import
  added. Fork repo: https://github.com/cartchai/plezy-tv, branch `main`.
- **Upstream base:** tag **2.25.0**, commit `c304934`. **This doc's HEAD:**
  `3c900c61a` (PlezTV v2.25.2, build #6) **plus uncommitted build #7 work**
  in the working tree — where a feature exists only uncommitted, it says so.
- **Scale:** 1,020 Dart files, ~306,000 lines in `lib/`. The fork's delta vs
  upstream is small (295 files, +11,052/−3,045 lines — most of it the rename);
  the *app* is big. That gap is why changes here take longer than in the
  from-scratch apps: every IPTV feature has to fit Plex/Jellyfin-shaped
  abstractions, and every change must be checked against all three upstream
  backends.
- **Status when written:** 2026-11-06. Build #7 (v2.25.3) in progress,
  uncommitted. Matt is on v2.25.1 (v2.25.2 will not install over it — signing,
  see §7).
- **Conventions in this doc:** paths are repo-relative. Line numbers were
  verified against the tree on the date above; symbol names are the stable
  reference — prefer searching for the symbol over trusting a line number.
  "Upstream" = edde746/plezy 2.25.0. "Fork-only" = added by us.

Related docs (history, not reference — this file supersedes them as the
finding aid): `IPTV_PROGRESS.md`, `IPTV_STAGE2_NOTES.md`,
`IPTV_STAGE3_NOTES.md`, `IPTV_FIXES_NOTES.md`, `IPTV_FIXES2_NOTES.md`,
`IPTV_EPG_NOTES.md`, `IPTV_BUILD7_NOTES.md`, `FORK_MAINTENANCE.md`,
`~/workspace/plezy-codebase-map.md` (the thin pre-implementation map; its
line numbers are stale — use this file instead).

---

## 1. Architecture overview

### Layers (top to bottom)

```
Screens (lib/screens/)            — widgets, tabs, sheets; almost no direct HTTP
Providers (lib/providers/)        — ChangeNotifier state: servers, libraries,
                                    downloads, theme, search results
Services (lib/services/)          — the work: aggregation, downloads, playback
                                    init, settings, update, IPTV API clients
Media clients (lib/media/ +       — one client per connected server, all behind
  lib/services/*_client/)           the MediaServerClient interface
Connections (lib/connection/)     — sealed Connection types + Drift registry
Database (lib/database/)          — Drift (SQLite) tables + CredentialVault
Player (lib/mpv/)                 — mpv bindings; plays raw URLs, no transcoding
```

**The central rule of the codebase: screens never talk to a server.**
A screen asks a `MediaServerClient` for data (`fetchLibraries`,
`fetchLibraryPagedContent`, `searchItems`, `liveTv.fetchChannels`…), or asks
the **aggregation service** to fan a call out to every connected server and
merge the results with per-server deadlines. The client is the only place
that knows what a backend is. IPTV fits this rule: `IptvClient` is just
another `MediaServerClient`, and the screens mostly do not know it exists.

### Entry points and startup flow

- `lib/main.dart:150` — `void main()`. `runApp` at :182. `main.dart` is
  ~2,600 lines: app bootstrap, splash, the Setup flow, offline-mode
  decisions, health re-checks (`:1704`), and the version log string
  (`'PlezTV v${packageInfo.version}+${packageInfo.buildNumber}…'` ~:1093).
- **Setup flow** (`lib/main.dart` ~:2165–2408): on launch the app binds the
  active profile's connections (see §1.3). Outcomes:
  - Connections exist and at least one server binds online →
    `ProfileSessionScreen` → `MainScreen`.
  - No connections at all → `AuthScreen` (`lib/screens/auth_screen.dart`) —
    first-run sign-in. Offers Plex / Jellyfin / Emby **and M3U / Xtream Codes**
    (build #5; `_connectToIptv` mirrors `_connectToMediaBrowser`).
  - Bind failed and no servers online →
    `shouldEnterOfflineModeAfterStartupBind` (`lib/main.dart:1279`) decides
    whether to enter the offline shell or show Auth.
- `lib/navigation/profile_session_screen.dart` — profile-scoped session host;
  root auth/PIN/global dialogs live here, not in MainScreen.
- `lib/screens/main_screen.dart` (2,287 lines) — the tab shell. Tabs from
  `NavigationTabId` (`lib/navigation/navigation_tabs.dart:9`):
  `discover, explore, libraries, liveTv, search, downloads, settings`.
  Which tabs show: `NavigationTab.getVisibleTabs(isOffline:, hasLiveTv:,
  hasExplore:)` (`main_screen.dart:1906`); Live TV appears only when
  `_hasLiveTv` is true. Bottom nav on phone; side nav on wide screens.

### How a connection becomes libraries, Home, and Live TV

1. **Stored:** `ConnectionRegistry` (`lib/connection/connection_registry.dart`)
   persists connections in the Drift `Connections` table
   (`lib/database/tables.dart:187` — `id`, `kind` (plain string, so no
   migration was needed for new kinds), `displayName`, `configJson`,
   `createdAt`, `lastAuthenticatedAt`). `configJson` is encrypted via
   `CredentialVault.protectConnectionConfig` (`connection_registry.dart:77`) —
   Xtream username/password get the same treatment as Jellyfin tokens.
   `Connection` rows are bound to profiles via `ProfileConnection`
   (`lib/profiles/profile_connection.dart`).
2. **Bound:** `ActiveProfileBinder` (`lib/profiles/active_profile_binder.dart`,
   1,265 lines) binds each profile's connections at startup/profile switch.
   The bind switch is at :505 (membership) and :661 (bind futures); IPTV
   goes through `_bindIptv` (:1204), which calls
   `MultiServerManager.addIptvConnection` and marks the server visible when
   the health probe succeeds — or "refused" (still visible) so the refusal
   banner can surface. **If you add a connection type, this binder is one of
   the three places that must gain a branch** (registry decode, binder, manager).
3. **Client:** `MultiServerManager` (`lib/services/multi_server_manager.dart`,
   1,798 lines) owns one client per server in `_clients[serverId]` plus
   IPTV-specific maps `_iptvByConnectionId` / `_iptvHealthByConnectionId`
   (:196). `addIptvConnection` (:949) builds `IptvClient.forConnection`,
   registers it under the connection id (which **is** the client's
   `serverId`), runs a health probe, returns healthy bool. Re-add always
   replaces the client (cheap/stateless, unlike Jellyfin's endpoint race).
   `removeIptvConnection` (:1084), `getIptvClientByConnectionId` (:1080).
   Shutdown detaches IPTV clients in `_detachAllClients` (:1755).
4. **Libraries:** `LibrariesProvider` (`lib/providers/libraries_provider.dart`)
   aggregates `MediaLibrary` from all servers (`_loadLibrariesInternal`,
   via `DataAggregationService.getMediaLibrariesFromAllServers`). It is
   **in-memory only** — a plain list, cleared on profile switch/logout, no
   Drift persistence, no cache. A stale library row cannot survive a restart.
   Hidden-library filtering via `HiddenLibrariesProvider`.
5. **Home (Discover):** `DiscoverProvider` + `DataAggregationService.
   getHubsFromAllServers` (`lib/services/data_aggregation_service.dart:541`)
   fan out `fetchGlobalHubs` per server under a 15 s per-server deadline.
6. **Live TV:** `MultiServerProvider.checkLiveTvAvailability()`
   (`lib/providers/multi_server_provider.dart:288`) builds
   `liveTvServers` (`List<LiveTvServerInfo>`, :39): Plex DVRs → one entry per
   DVR; otherwise if `client.liveTv.isAvailable()` → one synthesized entry
   with `dvrKey` = backend id. `IptvLiveTvSupport.isAvailable()` returns
   true unconditionally (no network), so an IPTV connection registers as a
   Live TV server as soon as it is bound and visible. `hasLiveTv` gates the
   Live TV tab.

### State management

Provider (`provider: ^6.1.2`) + `ChangeNotifier`. The providers that matter
most: `MultiServerProvider` (servers, Live TV availability, aggregation
service), `LibrariesProvider`, `DownloadProvider`
(`lib/providers/download_provider.dart`, 2,881 lines),
`ThemeProvider`, `PlaybackStateProvider`, `DiscoverProvider`,
`ExploreProvider`, `OfflineModeProvider`, `HiddenLibrariesProvider`,
`WatchStateStore` (`lib/providers/watch_state_store.dart` — local watch
state cache). Settings are `SettingsService` prefs
(`lib/services/settings_service.dart`, 1,800 lines) — `BoolPref`/`IntPref`/
`StringPref` consts; see §5.6 for the IPTV ones. Test seams are static
`@visibleForTesting` fields (e.g. `EditIptvConnectionScreen.debugHttpClient`,
`IptvLiveTvSupport.debugEpgCacheDirectoryProvider`) — the established pattern
when real I/O cannot run under the widget-test binding.

---

## 2. Module / directory map

`lib/` top level (1020 Dart files total):

| Directory | What lives there |
|---|---|
| `lib/main.dart` | Entry point, Setup/Auth/offline routing, splash, health re-checks |
| `lib/media/` | **The neutral domain model.** `media_backend.dart`, `media_item.dart` (+ generated `.freezed.dart`/`.g.dart`), `media_server_client.dart` (the client interface), `media_library.dart`, `media_kind.dart`, `media_hub.dart`, `library_query.dart`, `live_tv_support.dart`, `server_capabilities.dart`, `iptv_client.dart`, `iptv_live_tv.dart` (both fork-only), download/playback types |
| `lib/connection/` | `connection.dart` (sealed `Connection` + 4 subtypes), `connection_registry.dart` (Drift CRUD + encryption), `connection_bootstrap.dart`, `plex_account_setup.dart` |
| `lib/profiles/` | `active_profile_binder.dart` (binds connections → clients), `profile_connection.dart`, `profile_avatar_source.dart`, `profile_connection_cleanup.dart` |
| `lib/database/` | Drift `AppDatabase`, `tables.dart`, download operations, Plex metadata recovery |
| `lib/providers/` | ChangeNotifier providers (servers, libraries, downloads, theme, search, discover, explore, offline, watch-state) |
| `lib/services/` | The workhorses — see below |
| `lib/services/iptv/` | **Fork-only.** `xtream_api.dart`, `m3u_parser.dart`, `xmltv_parser.dart`, `iptv_item_favorites_repository.dart` (build #7, uncommitted) |
| `lib/services/jellyfin_client/parts/` | Jellyfin client split into 11 `part` files (browse, live_tv, playback, …) — the reference implementation for a client |
| `lib/services/plex_client/parts/` | Plex client, same pattern |
| `lib/screens/` | All screens; subdirs `auth/`, `downloads/`, `iptv/` (fork-only, build #7), `libraries/` (+ `tabs/`, `filters/`), `livetv/` (+ `tabs/`), `media_detail/`, `music/`, `playlist/`, `profile/`, `settings/`, `video_player/` (+ `parts/`, `widgets/`) |
| `lib/models/` | DTOs: `livetv_channel.dart`, `livetv_program.dart`, `download_models.dart`, plus `plex/`, `jellyfin/`, `catalog/`, `trackers/` subdirs |
| `lib/mpv/` | mpv player bindings (`player/player.dart` — `open(Media(url), isLive:)`; `models.dart` — `Media(String uri, {headers, start})`) |
| `lib/navigation/` | `navigation_tabs.dart` (`NavigationTabId`), `profile_session_screen.dart`, scopes/shortcuts |
| `lib/theme/`, `lib/widgets/` | Theme + shared widgets (`backend_badge.dart`, `media_context_menu.dart`, …) |
| `lib/utils/` | `media_server_timeouts.dart` (all deadlines), `live_tv_matching.dart`, `live_tv_player_navigation.dart`, `json_utils.dart` (`parseFlexibleJsonList`), `update_dialog.dart`, `media_image_helper.dart` |
| `lib/i18n/` | 22 `*.i18n.json` locales + generated `strings*.g.dart` (slang). English is the tested locale; other locales fall back to English for new keys |
| `lib/watch_together/`, `lib/dev/`, `lib/focus/`, `lib/mixins/`, `lib/metadata_edit/`, `lib/exceptions/`, `lib/data/` | Watch Together, dev tools, focus/D-pad handling, mixins, metadata editing, error types, data layer |

`lib/services/` top-level files that matter (selection):

| File | Role |
|---|---|
| `data_aggregation_service.dart` (1,011 lines) | Fans calls out to all servers with deadlines; merges libraries, hubs, search |
| `multi_server_manager.dart` | Owns all clients; `addIptvConnection`, health, visibility |
| `settings_service.dart` | All prefs incl. IPTV + EPG (§5.6) |
| `download_manager_service.dart` (4,533 lines) | Download pipeline; calls `client.resolveDownload` at :2108/:2118/:3198 |
| `download_storage_service.dart`, `download_artwork_service.dart` | Download storage + artwork |
| `favorite_channels_repository.dart` | Live-channel favourites persistence (SharedPreferences) |
| `update_service.dart` (301 lines) | In-app update check vs GitHub Releases (§5.7) |
| `playback_initialization_service.dart` | VOD playback init → `PlaybackInitializationResult` |
| `api_cache.dart` | `ApiCache.forBackend(backend)` — per-backend response cache |
| `credential_vault.dart` | Encrypts connection configs at rest |
| `base_shared_preferences_service.dart` | SharedPreferences wrapper (`sharedCache` is logout-wipe/export covered) |

---

## 3. Key abstractions

### 3.1 `MediaBackend` — CLOSED enum (`lib/media/media_backend.dart`)

Five values: `plex`, `jellyfin`, `emby`, **`m3u`, `xtream`** (fork-added).
`id` getter, `fromId` (throws on unknown), `fromString` (unknown → plex with
a warning log — used by cached-data deserialization), `usesMediaBrowserApi`
(true only for jellyfin/emby), `dialect` (`MediaBrowserDialect?` — null for
plex, m3u, xtream; M3U/Xtream are **not** MediaBrowser backends, so they get
their own client, not a dialect).

**Consequence:** every exhaustive `switch` on this enum broke when the two
values were added (21 sites in Stage 1). Adding a sixth backend repeats that
mechanical sweep — the compiler finds them all, each needs a deliberate
decision (usually `UnsupportedError` or a sensible default).

### 3.2 `Connection` — sealed class (`lib/connection/connection.dart`, 590 lines)

`sealed class Connection` (line 13): abstract getters `id`, `kind`
(`MediaBackend`), `displayName`, `createdAt`, `lastAuthenticatedAt`,
`displayLabel`, `displaySubtitle`, `toConfigJson()`. Sealed = new subtypes
must live in this file. Subtypes:

| Class | Line | Fields (fork-relevant) |
|---|---|---|
| `PlexAccountConnection` | 44 | `accountToken`, `clientIdentifier`, `servers: List<PlexServer>`, `activeProfile` |
| `JellyfinConnection` | 158 | Covers Jellyfin **and** Emby via `dialect`; `baseUrl`, `serverName`, `serverMachineId`, `userId`, `accessToken`, `deviceId` |
| `M3uConnection` | 375 | **`name`** (user-given library name), **`playlistUrl`**, **`epgUrl?`** (optional XMLTV URL), **`disabledCategoryIds`** (country/region filter) |
| `XtreamConnection` | 484 | **`name`**, **`serverUrl`** (no trailing slash), **`username`**, **`password`** (encrypted at rest), **`disabledCategoryIds`** |

Each subtype has `copyWith`, `toConfigJson()`, `fromConfigJson()`.
`_rowToConnection` in `connection_registry.dart` is an exhaustive switch on
`kind` — a new backend needs a case there or the connection silently vanishes
(logged error, returns null). `ProfileConnection`
(`lib/profiles/profile_connection.dart`) binds a connection to a profile:
`profileId`, `connectionId`, `userToken`, `userIdentifier`, `isDefault`.
IPTV carries no per-profile token: `userToken: null`, `userIdentifier` =
Xtream username ('' for M3U) — see
`lib/screens/settings/iptv_connection_persistence.dart`.

### 3.3 `MediaServerClient` — the client interface (`lib/media/media_server_client.dart`, 1,133 lines)

`abstract class MediaServerClient` (line 121), ~85 members. Most are
abstract (must be implemented); a few have defaults — the ones that matter:

**Abstract (implement or throw):**
- Identity: `serverId` (`ServerId`), `serverName`, `backend`, `capabilities`,
  `close()`, `checkHealth()` → `HealthStatus` (`online/offline/authError/
  accessDenied`), `getMachineIdentifier()`, `isOfflineMode` /
  `setOfflineMode(bool)`, `authenticationSessionId`, `scopedServerId`,
  `streamHeaders` (`Map<String,String>` — Plex needs `X-Plex-Token`, IPTV `{}`).
- Libraries: `fetchLibraries()`, `fetchLibraryPagedContent(libraryId,
  {required LibraryQuery query, MediaKind? libraryKind, AbortController? abort})`
  → `LibraryPage<MediaItem>` (**pagination is built in — the 199k-row VOD
  scale depends on this**), `fetchLibraryFiltersWithValues`,
  `fetchSortOptions`, `refreshLibraryMetadata`, `scanLibrary`.
- Items: `fetchItem(id)`, `fetchItemWithOnDeck(id, {onItemReady})`,
  `fetchChildren(parentId)`, `fetchLibraryFolders` / `fetchFolderChildren`,
  `fetchChildrenPage`, `fetchPlayableDescendantsPage` /
  `fetchPlayableDescendants`, `fetchClientSideEpisodeQueue(seriesId)`,
  `fetchSeasonEpisodesPage(seriesId, seasonId, …)`.
- Music (IPTV throws all): `fetchArtistAlbums`, `fetchArtistDiscography`,
  `fetchAlbumTracks`, `fetchInstantMix`, `fetchLyrics`.
- Search: `searchItems(query, {limit = 100, abort, excludedLibraryIds})`,
  `searchPeople(query, {limit, abort, excludedLibraryIds})`.
- Home: `fetchContinueWatching({count = 20, excludedLibraryIds})`,
  `fetchGlobalHubs({limit = 20, includePlaybackHubs})`,
  `fetchLibraryHubs(libraryId, {limit, includePlaybackHubs, libraryKind})`,
  `fetchRelatedHubs`, `fetchExtras`, `fetchPersonMediaPage`,
  `fetchPersonDetails`, `fetchMoreHubItems` / `fetchMoreHubItemsPage`.
- Watch state: `markWatched`, `markUnwatched`, `removeFromContinueWatching`,
  `rate(item, rating)`, `setFavorite(item, isFavorite)`.
- Playlists/collections (IPTV throws all): `fetchPlaylistsPage`,
  `fetchPlaylistMetadata/Page`, `createPlaylist`, `addToPlaylist`,
  `deletePlaylist`, `movePlaylistItem`, `removeFromPlaylist`,
  `fetchCollectionsPage`, `fetchCollectionPage`, `fetchCollectionMemberships`,
  `createCollection`, `addToCollection`, `removeFromCollection`,
  `deleteCollection`, `deleteMediaItem`.
- Playback: `thumbnailUrl(path, {width, height, cover})`,
  `externalImageUrl(url, …)`, `fetchExternalIds`, `findByExternalIds`,
  `fetchPlaybackExtras` / `fetchPlaybackExtrasFromCacheOnly`,
  `fetchCachedMediaSourceInfo`, `createScrubPreviewSource`,
  `marksWatchedOnPlaybackStopped`, `reportPlaybackStarted/Progress/Stopped`,
  `getPlaybackInitialization(PlaybackInitializationOptions)` →
  `PlaybackInitializationResult`, `liveTv` (`LiveTvSupport` getter),
  `resolveDownload(item, {mediaIndex, mediaSourceId})` →
  `DownloadResolution`, `stampLibrary(item)`, `resolveDownloadArtwork(item)`,
  `resolveExternalPlayback(item, …)`, `getFileInfo(item)`.
- **Defaults (have bodies — do not reimplement unless needed):**
  `cacheServerId` (switch on `this` — a new backend/client shape can break
  it), `liveTvDvr` (`capabilities.liveTvDvr ? liveTv.dvr : null`),
  `markWatchedFromPlaybackStop`, `fetchWithCacheFallback`,
  `fetchWithCacheFirst`, `fetchDeletePermission`.
- Also in the file: `GracefullyCloseable` (:81), `HubFetchDiagnostics`
  (:101), `HealthStatus` enum (:79), `CollectionMembership` typedef (:39).

`ServerCapabilities` (`lib/media/server_capabilities.dart`) is the flags
struct the UI consults to hide affordances: `liveTv`, `liveTvDvr`,
`videoTranscoding`, `richHubs`, `numericUserRating`, `userFavorites`,
`continueWatchingRemoval`, `externalSubtitleSearch`, `richMetadataEdit`,
`scrubThumbnails`, `folderGrouping`, `instantMix`, `libraryChangeEvents`.
`IptvClient` sets `liveTv: true`, `userFavorites: true`, everything else
false (see §5.1). **If a capability flag is wrong, the UI shows a control
whose client method throws** — check the flag before adding a UI affordance.

### 3.4 `MediaItem` — sealed freezed union (`lib/media/media_item.dart`, 923 lines)

`sealed class MediaItem with _$MediaItem`. Four cases (freezed union):

| Case | Line | Backend |
|---|---|---|
| `MediaItem.plex` | 165 | `PlexMediaItem` |
| `MediaItem.jellyfin` | 253 | `JellyfinMediaItem` (dialect → jellyfin/emby) |
| `MediaItem.m3u` | 337 | fork-added |
| `MediaItem.xtream` | 422 | fork-added |

The generic factory `MediaItem({...})` dispatches on backend (lines 65–112);
`MediaItem.fromJson` (line 297) switches on backend. **A new backend needs a
new union case + factory branch + `fromJson` case + `build_runner` regen**
(never hand-edit `media_item.freezed.dart` / `media_item.g.dart`).
Common fields: `id`, `kind` (`MediaKind`), `title`, `summary`, `thumbPath` /
`artPath` (server-relative for Plex/Jellyfin, **absolute URLs for IPTV**),
`isFavorite`, `libraryId`, `libraryTitle`, `serverId`, `serverName`,
`durationMs`, `rating`, `genres`, `parentId`/`parentTitle` (series/season),
`streamUrl` (IPTV cases carry the direct stream URL on the item itself).
`MediaKind` (`lib/media/media_kind.dart`): `movie, show, season, episode,
artist, album, track, collection, playlist, clip, photo, folder, unknown` —
VOD movies → `movie`, series → `show`/`season`/`episode`. No new kinds needed.

### 3.5 `MediaLibrary`, `LibraryQuery`/`LibraryPage`, `MediaHub`

- `MediaLibrary` (`lib/media/media_library.dart`): `id` (backend-opaque),
  `backend`, `title`, `kind`, `defaultBrowseKinds` (default `[]`),
  `language`, `updatedAt`/`createdAt`, `hidden`, `isShared`, `serverId`,
  `serverName`, `globalKey`. IPTV synthesizes these — no network call:
  `"<Name> — Movies"` / `"<Name> — Series"`, ids `iptv:<connectionId>:
  movies|series` (`_libraryId(moviesLibrarySuffix)` etc. in
  `iptv_client.dart:204`). The user-given connection name becomes the title.
- `LibraryQuery` / `LibraryPage<T>` (`lib/media/library_query.dart`, sealed
  freezed, :116/:149): `offset`/`limit`, `kind`, `includeKinds`, `search`,
  `nameStartsWith` (alpha jump), sort/filter clauses. `LibraryPage` carries
  `items`, `totalCount`, `offset`. Built by `libraryQueryFromSelection`
  (`lib/services/library_query_translator.dart:135`).
- `MediaHub` (`lib/media/media_hub.dart`): `id`, `title`, `type`, `items`
  (`List<MediaItem>`), `size`, `more` (whether a "show more" expansion exists).
  Hubs are the Home/Recommended unit. `defaultHubPreviewLimit = 20`.

### 3.6 `LiveTvSupport` — the Live TV interface (`lib/media/live_tv_support.dart`)

`abstract class LiveTvSupport` (:173): `isAvailable()`,
`fetchChannels({String? lineup})` → full `List<LiveTvChannel>` (**NOT
paginated** — the biggest scale problem for 55k channels; see §6),
`fetchSchedule({DateTime? from, DateTime? to})`,
`startPlayback(channelKey, {String? dvrKey, TranscodeQualityPreset quality})`
→ `LiveTvPlaybackSession?`, `buildFavoriteChannelSource({lineup})`,
`favoriteStoreKey`, `favoritePersistenceMode`, `fetchFavoriteChannels()` /
`setFavoriteChannels()`, `dvr` getter → `LiveTvDvrSupport?` (IPTV: null).
`LiveTvPlaybackSession` (:68): `streamUrlAt({int? offsetSeconds,
MediaSubtitleTrack? subtitleTrack})` → `String?` (**the only URL the player
ever sees**; catch-up maps here — negative offset = timeshift),
`reportTimeline({state, positionMs, durationMs})`, `discard()`,
`recover({directStream, directStreamAudio})`, `canTimeShift`, `captureBuffer`,
`subtitleTracks`, `program`, `backgroundPolicy`.
Models: `LiveTvChannel` (`lib/models/livetv_channel.dart` — `key`,
`identifier`, `callSign`, `title`, `thumb`, `art`, `number`, `hd`, `lineup`,
`slug`, `drm`, plus runtime `serverId`, `serverName`, `hasCatchUp`
(`tv_archive`, :86, excluded from JSON), `favoriteSource`),
`LiveTvProgram` (`lib/models/livetv_program.dart` — `title`, `summary`,
`beginsAt`/`endsAt` (epoch seconds), `channelIdentifier`, `channelCallSign`,
`live`, `premiere`, `thumb`, `art`, `serverId`, `isPlaceholder` (fork-added,
default false, **deliberately not written by `toJson`** — :135),
hand-written `fromJson` + `toJson` (no codegen)).
`liveTvProgramMatchesChannel` (`lib/utils/live_tv_matching.dart`) matches
`program.channelIdentifier` against `channel.key`/`channel.identifier`.

---

## 4. Screen-by-screen

### 4.1 Main shell — `lib/screens/main_screen.dart` (2,287 lines)

Tab shell + navigation. `_hasLiveTv` (from `MultiServerProvider`) gates the
Live TV tab; `_getVisibleTabs` / `NavigationTab.getVisibleTabs` (:1906)
decide the tab set. Health re-checks at :1245. No Plex-only gate — an
IPTV-only profile reaches MainScreen the same way.

### 4.2 Home / Discover — `lib/screens/discover_screen.dart`, `lib/screens/explore_screen.dart`

Home renders hubs from `DiscoverProvider` →
`DataAggregationService.getHubsFromAllServers` (:541, 15 s per-server
deadline). IPTV contributes one hub per on-demand library, titled with the
library name ("Trex — Movies", "Trex — Series") via
`IptvClient.fetchGlobalHubs`. A throwing hub is caught per-library by the
aggregation service — one bad server cannot kill Home. `ExploreScreen` is
the browse-all surface; same hub plumbing.

### 4.3 Libraries — `lib/screens/libraries/libraries_screen.dart` (1,063 lines)

`LibrariesScreen`. Library picker dropdown (phone) / side nav (wide).
Tabs enum `LibraryTabType` (:42): `recommended, browse, collections,
playlists, categories` (categories is fork-added, build #7, uncommitted).
`visibleLibraryTabs(library)` (:44):

- shared library → `[browse, playlists]`
- IPTV library (backend m3u/xtream) → `[recommended, browse, categories,
  playlists]` — **Collections replaced by Categories in the same position**
- everything else → all values except `categories`

`appBarActions()` gains a heart action (build #7, uncommitted) opening
`IptvFavoritesScreen`, shown only when at least one IPTV library is visible.

**Tab implementations** (`lib/screens/libraries/tabs/`):

| Tab | File | What it calls |
|---|---|---|
| Recommended | `library_recommended_tab.dart` (366 lines) | `client.fetchLibraryHubs(libraryId, libraryName, limit: 20, …)` (:197). A throw = "Unable to load Recommended" |
| Browse | `library_browse_tab.dart` (2,297 lines) | `client.fetchLibraryPagedContent(widget.library.id, query: _buildQuery(…), libraryKind: …)` (:918). `_buildQuery` (:825) builds the `LibraryQuery` via `libraryQueryFromSelection` (sort, alpha prefix `_mediaBrowserAlphaPrefix`, filters, offset/limit) and adds `includeKinds: library.defaultBrowseKinds` when grouping is "All" and kinds exist. Grouping: `library_browse_grouping.dart` (`normalizeLibraryBrowseGrouping`, default grouping via `defaultLibraryBrowseGrouping`); folder grouping renders a tree (`_refreshFolderTree`), not the flat page — IPTV sets `folderGrouping: false` and `fetchLibraryFolders` throws, so IPTV Browse is always the flat paged grid. Alpha jump bar: `alpha_jump_bar.dart` + `library_alpha_bar_strategy.dart` (client-side MediaBrowser strategy for IPTV). `paginated_card_grid_tab.dart` is the shared incremental-loading grid base; `base_library_tab.dart` the shared tab state (`runLoadTransaction` → `localizedLoadErrorMessage`, sanitized — never carries exception text/hostnames/paths, so no credential leakage) |
| Collections | `library_collections_tab.dart` | `client.fetchCollectionsPage` — IPTV throws `UnsupportedError`; the tab renders "Unable to load Collections. Please try again." (the bug that motivated the Categories tab) |
| Categories (fork, build #7) | `library_categories_tab.dart` (new, uncommitted) | `IptvClient.iptvCategoriesForLibrary(libraryId)` + `iptvItemsForCategory(libraryId, categoryId)`; VOD categories in Movies, series categories in TV/Series; honours `disabledCategoryIds`; tapping a category opens a paged grid of its items |
| Playlists | `library_playlists_tab.dart` | `client.fetchPlaylistsPage` — IPTV throws (same class of bug as Collections; noted as a follow-up, not fixed in build #7) |

**Known live bug (2026-11-06, on v2.25.1):** Movies Browse shows "This
library is empty" while Series Browse loads. The Browse path is
`fetchLibraryPagedContent` → `_moviesItems()` → `_vodStreams()` (199k rows).
Build #6's notes claimed the Movies hub loads and the Series hub dies
(malformed-row parse) — the phone shows the opposite, so the failing catalog
path must be re-verified against real data, not assumed. See build #7 Task 8.

### 4.4 Live TV — `lib/screens/livetv/live_tv_screen.dart` (1,026 lines)

`LiveTvScreen`, tabs `LiveTvTab {guide, whatsOn, recordings}`. "What's On"
only when a Live TV server is Plex; "Recordings" only when a server has
`liveTvDvr`. Channels load per server via `forEachLiveTvServer`
(`lib/screens/livetv/live_tv_server_iteration.dart` — iterates
`multiServer.liveTvServers`, isolates per-server failures; `onError` logs
only, error state only when ALL servers fail).

- **Source picker** (build #4): chips above the guide, shown only when 2+
  live-TV servers are connected: "All sources" + one chip per server by name
  (`MultiServerProvider.liveTvServerName(serverId)`), deduped by server id.
  Picking a source filters the GUIDE only. A picked source with no loaded
  channels shows an explicit empty state ("No channels loaded from Trex" +
  hint + Reload) instead of a bare grid. A provider listener reloads
  channels when the live-TV server set changes (late bind); provider ref
  saved in `initState` — `context.read` in `dispose()` crashes (fixed in
  build #4).
- **Guide tab** — `lib/screens/livetv/tabs/guide_tab.dart` (2,312 lines).
  The grid is virtualized (only visible rows build). `fetchSchedule(from,
  to)` is the server-wide hook; per-channel EPG is driven lazily from the
  row builder via `_ensureIptvEpg` (:910) → `IptvLiveTvSupport.
  fetchEpgForChannel(channel.key, from:, to:)` (:941). A thin 3px
  `LinearProgressIndicator` under the time navigation shows while an IPTV
  EPG fetch is in flight (`_isIptvEpgLoading`, :983, tracked per channel in
  `_iptvEpgInFlight` / `_iptvEpgLoaded` / `_iptvEpgFailed`); IPTV-only,
  Plex/Jellyfin/Emby keep their spinner/dim overlay. Hour placeholders:
  `_withHourPlaceholders` (:827) fills uncovered hours with one clickable
  block per hour (`LiveTvProgram.isPlaceholder`, key
  `no-info:<channel.key>:<beginsAt>`, title `t.liveTv.noInformationAvailable`,
  muted + italic); placeholders appear ONLY once a channel's load finished
  with no data (never while loading), and ONLY for IPTV rows
  (`_iptvSupportFor(channel) != null` — a Plex row with an empty schedule
  keeps the old "No program data available" bar + channel-cell focus).
  Tapping a block opens the program detail sheet
  (`program_details_sheet.dart`); for a **past** block on a `hasCatchUp`
  channel the sheet offers "Watch from start (N min ago)" via
  `LiveTvSessionArgs.catchUpStartEpoch` → `navigateToLiveTv` →
  `liveTvCatchUpOffsetSeconds` (clamped to the archive window; null → normal
  live tune). Catch-up badge: a small history badge at the top-left of the
  channel cell when `hasCatchUp`, gated by the `iptvShowCatchUpBadge` pref.
- **What's On / Recordings** — `whats_on_tab.dart` (Plex only),
  `recordings_tab.dart` (DVR-gated, IPTV never shows it).
- **Playback:** `lib/screens/video_player/parts/live_tv.dart:170`
  `_startLiveSession` resolves the channel's server
  (`liveTvServerInfoForChannel`), then
  `client.liveTv.startPlayback(channel.key, dvrKey:, quality:)`. URL from
  `session.streamUrlAt(...)` (:458) → `player.open(Media(url), isLive: true)`.
  Recovery re-calls `streamUrlAt()` (:264–269). A channel is also a
  `MediaItem` for the player UI via `liveTvChannelItem`
  (`lib/utils/live_tv_player_navigation.dart:100`).

### 4.5 Search — `lib/screens/search_screen.dart` (633 lines)

Calls `multiServerProvider.aggregationService.searchAcrossServers(...)`
(:140). The aggregation (`data_aggregation_service.dart:793`,
`searchAcrossServers`) runs one leg per server: `client.searchItems(query,
limit:, abort:, excludedLibraryIds:)` under a per-server deadline —
`MediaServerTimeouts.searchServerDeadline` (20 s) normally,
**`iptvSearchServerDeadline` (60 s) for IPTV** (:830–831) — plus a people
leg (`_searchPeopleBestEffort`, :896, `client.searchPeople`, same 20 s
deadline). Legs are best-effort: a slow/throwing server drops out, the rest
still return. Results are ranked/merged by the aggregation; the screen
renders the ranked list (or "All" per-server sections).
`lib/screens/catalog_search_screen.dart` is the catalog-source search
(trackers/seerr etc.), a different path.

**IPTV search** (`IptvClient.searchItems`, `iptv_client.dart:827`): client-side
over lazily loaded in-memory lists — VOD + series for Xtream, playlist
entries for M3U — case-insensitive title `contains`, capped at `limit`,
honours `excludedLibraryIds` and `disabledCategoryIds`. It awaits the FULL
catalogs, so a catalog-fetch failure kills the whole search call — the prime
suspect for "search won't search IPTV" on v2.25.1 (build #7 Task 6: diagnose
+ fail-open per section). `searchPeople` throws `UnsupportedError` for IPTV.

### 4.6 Downloads — `lib/screens/downloads/downloads_screen.dart`, `sync_rules_screen.dart`

- `DownloadProvider` (`lib/providers/download_provider.dart`, 2,881 lines):
  `queueDownload` (:1500) → `DownloadManagerService.queueDownload` (:1780).
  `NoSyncRulesDownloadProvider` is the test double.
- `DownloadManagerService` (`lib/services/download_manager_service.dart`,
  4,533 lines): the prepare step calls `client.resolveDownload(metadata)`
  (:2108, :2118, :3198); artwork via `client.resolveDownloadArtwork`
  (:3242, :3269). A throw in `resolveDownload` → `_handleEnqueueFailure` →
  the download fails — exactly the build #7 Task 3 diagnosis (IPTV movies
  would not download because `resolveDownload` threw `UnsupportedError`).
- Sync rules screen (`sync_rules_screen.dart`) matches downloads to
  connections by id.
- **Downloadable IPTV content:** movies + series episodes (direct file URLs);
  shows (no file) resolve to `videoUrl: null` and take the retry-then-fail
  path; `.m3u8` playlist URLs resolve to null (a playlist is not a file).
  Live channels are not downloadable.

### 4.7 Media detail + player

- `lib/screens/media_detail_screen.dart` (5,116 lines) — detail page:
  action buttons (`lib/screens/media_detail/action_buttons.dart` — download
  button shown whenever not offline and not Apple TV, no backend gating),
  playback tracks status, seasons/episodes for series (via
  `fetchChildren` → `get_series_info` for IPTV).
- `lib/screens/video_player_screen.dart` (3,125 lines) + `parts/`:
  `playback_start.dart` (incl. catch-up offset), `live_tv.dart`,
  `episode_navigation.dart`, `episode_queue.dart`, `pip.dart`, `lifecycle.dart`,
  `playback_open.dart`, `playback_reload.dart`, `live_tv_session_args.dart`
  (`catchUpStartEpoch`). VOD init:
  `PlaybackInitializationService` → `client.getPlaybackInitialization`
  → `PlaybackInitializationResult` (`videoUrl`, `availableVersions`,
  `mediaInfo`, `isTranscoding`, `playSessionId`, `playMethod`); IPTV returns
  the direct stream URL, `isTranscoding: false`, minimal `MediaSourceInfo`.
  Offline path substitutes a downloaded file. MPV accepts the raw URL
  (HLS `.m3u8` and raw `.ts` natively).

### 4.8 Settings — `lib/screens/settings/settings_screen.dart` (1,066 lines)

Sections incl. Connections (Add connection → `add_connection_screen.dart`;
**IPTV row** → `iptv_settings_screen.dart`), Updates (directly above About),
About. Sub-screens: `appearance_settings_screen.dart`,
`playback_settings_screen.dart`, `app_icon_setting.dart`,
`account_preferences_screen.dart`, `tracker_*`, `seerr_*`, `trakt_*`,
`keyboard_shortcuts_screen.dart`, `mpv_config_screen.dart`,
`subtitle_styling_screen.dart`, `licenses_screen.dart`, `logs_screen.dart`.

**IPTV settings** — `lib/screens/settings/iptv_settings_screen.dart`
(394 lines), reached via Settings → Connections → IPTV:
- Intro line (Live TV lives in Live TV; Movies/Series in Library).
- **Connections:** live list from `ConnectionRegistry.watchConnections()`
  (M3U + Xtream only); each row shows user-given name + source label (M3U /
  Xtream Codes) + filter state ("All categories on" / "N categories off");
  tap → edit screen (country/region filter); "Add IPTV connection" row.
  Delete stays in Profile detail (its `_removeConnection` does the full
  profile-join teardown).
- **Playlist:** "Refresh playlists" — `IptvClient.clearCatalogCache()` on
  every bound IPTV client + `refreshEpgCache()` (build #6) — then a
  snackbar. Targeted on purpose: a full rebind would recreate every
  server's client.
- **Guide & catch-up:** "Show catch-up badge" switch
  (`iptvShowCatchUpBadge`, default on).
- **EPG / TV guide** (build #6, TiviMate-modelled): days to load (1/2/3/4/7,
  default 3), update interval (6/12/24 h, Manual, default 24 h), past days
  to keep (0/1/2/3/7, default 1), update on app start (default OFF), time
  offset (±30/60/120 min, default 0), Update now, Clear guide, Last updated
  status line. Prefs in `SettingsService` — see §5.6.
- **Player:** row linking to the existing Playback settings (IPTV uses the
  same player; no duplicate controls).

**Connection add/edit screens:**
- `add_connection_screen.dart` — `_BackendOption` rows: Plex, Jellyfin,
  Emby, **M3U, Xtream Codes** (after Emby, before Borrow), each with a
  `BackendBadge` (`lib/widgets/backend_badge.dart` — SVG per backend;
  `assets/m3u_icon.svg`, `assets/xtream_icon.svg`, fork-added).
- `add_m3u_screen.dart` — NAME (required, becomes library title) +
  Playlist URL + optional EPG URL. Probes first (fetch + `parseM3u`,
  require ≥1 entry), then persists. Failures map to fixed strings
  (`m3uInvalidUrl` / `m3uPlaylistEmpty` / `m3uProbeFailed`).
- `add_xtream_screen.dart` — NAME + Server URL + Username + Password.
  Probes with `XtreamApi.getUserInfo()` (a `user_info` object = login works).
  Password never logged; Xtream errors can embed the request URI (credentials
  in query string), so all failures map to fixed strings
  (`invalidCredentials` / `xtreamProbeFailed`).
- `edit_iptv_connection_screen.dart` — country/region filter: **Live TV /
  Movies / TV Series** as separate collapsible sections (Xtream, from
  `getLiveCategories` / `getVodCategories` / `getSeriesCategories`; M3U: one
  **Groups** section of playlist group titles), sharing one
  `disabledCategoryIds` set; Show all / Hide all; expanded state persisted
  per section (`iptvCategories*Expanded` prefs). Lazy `SliverList.builder`
  (800+ categories never build at once). Test seam:
  `EditIptvConnectionScreen.debugHttpClient` (static, null in production).
  Save → `registry.upsert(updated, expected: connection)` → caller rebinds.
- `iptv_connection_persistence.dart` — `persistAndExitIptvConnection()`,
  shared persist path (first-run profile creation, profile-selection prompt,
  `persistAndBindConnection`, rebind, pop(true)).

### 4.9 Auth / profiles / About / Updates

- `AuthScreen` (`lib/screens/auth_screen.dart`) — first-run sign-in: Plex,
  Jellyfin, Emby, M3U, Xtream Codes (build #5). `_connectToIptv` mirrors
  `_connectToMediaBrowser`.
- Profile screens (`lib/screens/profile/`): `profile_detail_screen.dart`
  (connection edit/delete — `_editConnection` routes IPTV to the IPTV edit
  screen), `profile_switch_screen.dart`, `borrow_connection_screen.dart`
  (share a connection between profiles; IPTV is a no-op there).
- About (`lib/screens/settings/about_screen.dart`) — "What's new" changelog
  (static in code, newest first; `changelog2251`/`changelog2250`… in
  `lib/i18n/en.i18n.json` `about` block; add a `changelogXXXX` entry +
  `_ChangelogEntry` per release), version from `packageInfo`, logo =
  bundled `assets/plezy.png` (blue).
- Updates section (Settings, directly above About) — see §5.7.

---

## 5. The IPTV integration (the fork's additions)

### 5.1 `IptvClient` — `lib/media/iptv_client.dart` (1,697 lines, fork-only)

`class IptvClient implements MediaServerClient` (:55). Named constructors
`.m3u` / `.xtream` + `IptvClient.forConnection()` (throws
`UnsupportedError` for a non-IPTV connection, :65). `serverId` = connection
id; `serverName` = user-given name. Stores the connection as the base
`Connection` type and reads `name` / `disabledCategoryIds` through private
typed getters. `streamHeaders` = `{}`. `watchedThreshold` 0.9. `cache` via
`ApiCache.forBackend(backend)`. Test-only injection:
`@visibleForTesting set testXtreamApi` / `testHttpClient`.

Capabilities (:227): `liveTv: true`, `userFavorites: true`, everything else
false (`liveTvDvr`, `videoTranscoding`, `richHubs`, `numericUserRating`,
`continueWatchingRemoval`, `externalSubtitleSearch`, `richMetadataEdit`,
`scrubThumbnails`, `folderGrouping`, `instantMix`, `libraryChangeEvents`).

**What the real methods do:**
- `checkHealth`: Xtream → `player_api.php` auth probe (online / authError /
  accessDenied / offline); M3U → HEAD on the playlist URL.
- `fetchLibraries`: synthetic `iptv:<id>:movies|series` titled
  `"<Name> — Movies"` / `"<Name> — Series"`. **No Live TV library** (removed
  build #4 — live TV lives only in Live TV; M3U returns `[]`, it has no
  on-demand catalog). A Movies/Series library is omitted when ALL its
  categories are disabled; the category probes run in parallel with a 5 s
  fail-open timeout (build #5 — under the aggregation service's 15 s
  library-list deadline, sequential probes could hide the whole Trex
  section). Content-level filtering still hides disabled categories even
  when the probe fails open. `_liveLibraryId` / `liveLibrarySuffix` survive
  only as internal attribution ids for M3U channel items (search/fetchItem).
- `fetchLibraryPagedContent`: movies/series → `_moviesItems()` /
  `_seriesItems()` (full catalog, filtered by `disabledCategoryIds`,
  `_applyQueryFilters` for `query.search` / `query.nameStartsWith`), paged
  by `_page` (`query.offset/limit`). Live library branch deleted.
- `fetchItem`: resolves prefixed ids (`movie:<id>`, `series:<id>`,
  `episode:<seriesId>:<episodeId>`, `m3u:<tvgId|name>`) via cached lists /
  `get_series_info` / playlist lookup; null when not found. Direct item open
  is NOT category-filtered (by design).
- `fetchChildren` / `fetchChildrenPage` / `fetchPlayableDescendants` /
  `fetchClientSideEpisodeQueue`: series → episodes from `get_series_info`
  (season order, episode order).
- `searchItems` — see §4.5.
- `fetchContinueWatching`: returns `[]` (local watch state is a follow-up).
- `getPlaybackInitialization`: direct `streamUrl` from the item,
  `isTranscoding: false`, minimal `MediaSourceInfo`/`MediaVersion`; throws
  `PlaybackException(noPlayableSource)` when the item has no URL.
- `resolveExternalPlayback`: same direct URL, or null.
- `thumbnailUrl` / `externalImageUrl`: return the path unchanged (IPTV thumbs
  are absolute URLs).
- `fetchLibraryHubs`: one `MediaHub` titled "Recommended" per library (first
  `limit` catalog entries, reusing the lazy cache). `fetchGlobalHubs`: one hub
  per on-demand library, titled with the library name; M3U `[]`.
  `fetchMoreHubItems` / `fetchMoreHubItemsPage` expand a Recommended hub
  (hub ids carry their library id). Shared `_moviesItems()` /
  `_seriesItems()` feed paged browse AND hubs so both agree.
- `resolveDownload` (build #7): returns `DownloadResolution(videoUrl: <the
  item's direct streamUrl>)` for movies and episodes; shows (no file) →
  `videoUrl: null` (retry-then-fail path, no throw); `.m3u8` URLs → null.
  `resolveDownloadArtwork`: poster spec (`DownloadArtworkSpec(localKey:
  thumbPath, url: thumbPath)`) when the thumb is an absolute URL.
- `favoriteItems()` (build #7, uncommitted): favourited movies/series/
  episodes as `MediaItem`s, re-resolved against the catalog when available,
  falling back to the stored snapshot.
- `iptvCategoriesForLibrary(libraryId)` / `iptvItemsForCategory(libraryId,
  categoryId)` (build #7, uncommitted): Categories-tab support.
- `clearCatalogCache()`: drops the in-memory channel/movie/series/category
  futures ("Refresh playlists"); an in-flight fetch is not cancelled, its
  result is discarded.
- `xtreamApi` (public getter) + `tvgIdForChannelKey(key)`: for the Live TV
  support to use.
- `fetchExternalIds`: empty. `findByExternalIds`: null.
  `fetchPlaybackExtras`: empty chapters/markers.
  `fetchPlaybackExtrasFromCacheOnly` / `fetchCachedMediaSourceInfo`: null.
  `stampLibrary`: returns the item unchanged. `getMachineIdentifier`:
  connection id.

**No-op completes (silent, by design — no server API):** `markWatched`,
`markUnwatched`, `removeFromContinueWatching`, `rate`,
`reportPlaybackStarted/Progress/Stopped` (`:1295–1304`, `:1509–1536`).
**`setFavorite` is NOT a no-op anymore** (build #7, uncommitted — see §5.5).

**Still throwing `UnsupportedError` (85 `@override`s in the file; the throw
sites):** `refreshLibraryMetadata`, `scanLibrary`, `fetchLibraryFolders`,
`fetchFolderChildren`, `fetchPlayableDescendantsPage`, `fetchArtistAlbums`,
`fetchArtistDiscography`, `fetchAlbumTracks`, `fetchInstantMix`,
`fetchLyrics`, `searchPeople`, `fetchRelatedHubs`, `fetchExtras`,
`fetchPersonMediaPage`, `fetchPersonDetails`, `fetchPlaylistsPage`,
`fetchPlaylistMetadata`, `fetchPlaylistPage`, `createPlaylist`,
`addToPlaylist`, `deletePlaylist`, `movePlaylistItem`, `removeFromPlaylist`,
`fetchCollectionsPage`, `fetchCollectionPage`, `fetchCollectionMemberships`,
`createCollection`, `addToCollection`, `removeFromCollection`,
`deleteCollection`, `deleteMediaItem`, `getFileInfo`,
`createScrubPreviewSource`. **Rule: before wiring any UI to one of these,
either implement it or gate the UI behind a capability flag** — an unwired
call surfaces as an "Unable to load…" error, as Collections did.

### 5.2 `XtreamApi` — `lib/services/iptv/xtream_api.dart` (495 lines, fork-only)

`class XtreamApi` (:20). Constructor takes server URL + username + password
(+ injectable `http.Client` for tests). Auth is Xtream's scheme: credentials
in the query string of every request. **Never log a request URI** — it carries
the password.

| Method | Endpoint / purpose |
|---|---|
| `getUserInfo()` (:118) | `player_api.php?action=user_info` — auth probe; a `user_info` object = login works. Returns `Map?` (null = rejected) |
| `getLiveCategories()` / `getVodCategories()` / `getSeriesCategories()` (:127–137) | `player_api.php?action=get_live_categories` / `get_vod_categories` / `get_series_categories` |
| `getLiveStreams({categoryId})` (:142) | `get_live_streams` — 55,205 rows. 120 s timeout, isolate parse |
| `getVodStreams({categoryId})` (:154) | `get_vod_streams` — 199,762 rows. 120 s timeout, isolate parse |
| `getSeries({categoryId})` (:165) | `get_series` — 46,461 rows. 120 s timeout, isolate parse |
| `getSeriesInfo(seriesId)` (:174) | `get_series_info` — seasons + episodes for one series |
| `getShortEpg(streamId, {limit = 4, timeout})` (:188) | `player_api.php?action=get_short_epg&stream_id=…&limit=…` — per-channel guide; build #6 calls with `limit: 500, timeout: 60s`. EPG titles/descriptions are Base64-decoded with raw fallback |
| `getSimpleDataTable()` (:201) | `get_simple_data_table` — now/next |
| `getXmltv({timeout = 120s})` (:209) | `xmltv.php?username=…&password=…` — **the full XMLTV guide from the login**. Build #7 (uncommitted) makes this the primary Xtream EPG source; build #6 did not call it at all |
| `getM3u({type = 'm3u_plus', output = 'ts'})` (:213) | `get.php` — M3U playlist export for the account |

URL builders (direct play, no transcode): `liveStreamUrl(streamId)` →
`$server/live/$user/$pass/$id.m3u8`; `movieStreamUrl(streamId,
containerExtension)` → `$server/movie/$user/$pass/$id.<ext>`;
`seriesStreamUrl(episodeId, containerExtension)` → `$server/series/…`;
`timeshiftUrl({streamId, durationMinutes, start})` (:236) →
`$server/timeshift/$user/$pass/$duration/$start/$id.m3u8`, start formatted
`YYYY-MM-DD:HH-MM-SS` **in UTC** — disputed point, unverified against the
provider; the EPG time-offset setting is the mitigation, not proof.

Models (all hand-written `fromJson`, numbers parsed flexibly —
strings-or-ints): `XtreamCategory` (:273), `XtreamLiveStream` (:289,
`tv_archive`, `tv_archive_duration`, `epg_channel_id`),
`XtreamVodStream` (:321), `XtreamSeries` (:356 — 8 `as String?` casts:
`cover`, `plot`, `cast`, `director`, `genre`, `releaseDate`,
`backdropPath`, `youtubeTrailer`), `XtreamEpisode` (:406),
`XtreamSeriesInfo` (:436), `XtreamEpgProgram` (:468).
Parsing: `_fetchBody` (GET + status checks, shared), `_getJson`, `_getText`;
the three big catalog calls fetch the raw body then parse via
`compute()` on a background isolate (top-level `_parseLiveStreams` /
`_parseVodStreams` / `_parseSeries` + `_decodeCatalogJson`, which maps
`FormatException` to the same `MediaServerHttpException` the inline path
threw). **All three parsers use `parseFlexibleJsonList`
(`lib/utils/json_utils.dart:76`) — one malformed row is dropped, not fatal**
(build #6 fix: the old `.map(X.fromJson).toList()` let one mistyped row kill
the whole 46k-row catalog).

### 5.3 M3U parser — `lib/services/iptv/m3u_parser.dart` (76 lines, fork-only)

`parseM3u(String text)` → `List<M3uEntry>` (`name`, `url`, `tvgId`,
`tvgLogo`, `groupTitle`, `catchupSource`). Pure text, no network. Handles
`#EXTINF` lines (`tvg-id`, `tvg-logo`, `group-title`, `catchup-source`, plus
any other `key="value"` attributes) followed by the stream URL on the next
non-comment line. `#EXTM3U` headers, `#EXTGRP`, other comments skipped.
An entry without a following URL is dropped. M3U entries become channels
(`key` = tvg-id or URL) and search items; M3U has no VOD libraries.

### 5.4 `IptvLiveTvSupport` — `lib/media/iptv_live_tv.dart` (702 lines, fork-only)

`class IptvLiveTvSupport implements LiveTvSupport`. `dvr` → null.
`isAvailable()` → true unconditionally (a dead provider surfaces as empty
channels). `fetchChannels` → `_client.iptvChannels()` (full 55k-row list in
one call; filtered by `disabledCategoryIds`; M3U group titles are the
category keys). `fetchSchedule` **returns `[]` deliberately** (:94–103,
with the comment: the server-wide hook cannot name the visible channels) —
the guide drives EPG per visible channel instead.

**EPG — `fetchEpgForChannel(channelKey, {from, to})` (:123):**
- Reads EPG settings once per fetch (`_readEpgSettings`, :104). Window =
  `[now − pastDays, now + daysToLoad]`; cache TTL = update interval
  (≤0 = manual only, never expires on its own).
- Per-channel cache (`_epgCache`, :43) covering the whole settings window;
  only the overlapping slice is returned (`_slice`, :233).
- **Xtream (build #7, uncommitted):** primary source is the login's
  `xmltv.php` feed (`_fetchXtreamXmltvPrograms`, :272 → `_xtreamXmltvGuide`,
  :437; parsed file cached per URL — `_xmltvCache`, :47 — with in-flight
  dedupe `_xmltvGuideFutures`, :53; programmes matched by tvg-id), with
  `getShortEpg` as fallback (`:297`) for channels missing from the feed.
  Build #6 (committed) used only `getShortEpg(limit: 500, timeout: 60s)`.
  The mapper trusts the REQUESTED channel key, not the API's `channelId`
  (every program gets `channelIdentifier: <requested key>`); per-listing
  try/catch; time offset applied in the mapper; empty titles →
  `t.liveTv.unknownProgram`. Per-channel failure fails open (catch, log, `[]`).
- **M3U:** `lib/services/iptv/xmltv_parser.dart` (78 lines, top-level
  `parseXmltv`, isolate-safe) parses the connection's optional XMLTV EPG URL
  (`_fetchM3uEpg`): programmes matched by `tvg-id` (= M3U channel key),
  XMLTV times `YYYYMMDDHHMMSS ±HHMM` converted to UTC epoch, malformed
  `<programme>` entries skipped, document-level failure throws. Parsed file
  cached per URL for 24 h, parsed via `compute(parseXmltv, …)`. No EPG URL
  (or entries without tvg-id) → empty guide, placeholders, no crash.
- **Persistence (build #7, uncommitted):** per-channel JSON files under
  `getApplicationCacheDirectory()/iptv_epg/<connectionId>/<channelKey>.json`
  (base64url-encoded names — channel keys come from provider data, never
  trusted raw), each `{fetchedAt, windowFrom, windowTo, programs[]}`.
  `fetchEpgForChannel` reads the disk entry on an in-memory miss: a fresh
  persisted entry covering the window is served without refetching; a stale
  one refetches and rewrites. Writes are best-effort. Directory injectable
  via static `debugEpgCacheDirectoryProvider` (:72). `LiveTvProgram`
  gained a hand-written `toJson` (writes exactly the keys `fromJson` reads);
  `fromJson` now also reads `serverId`/`serverName`/`liveDvrKey`/
  `providerIdentifier`.
- **Clear / refresh:** `clearEpgCache` empties the in-memory map AND deletes
  the persisted files; `_epgCleared` (:60) makes `fetchEpgForChannel`
  return `[]` without fetching until a refresh (otherwise the guide's lazy
  refetch would undo the clear); the guide watches `epgVersion` (bumped on
  every clear). `refreshEpgCache` busts both caches. Update-on-start is
  per-channel (`_startupRefreshedChannels`, :82 — one forced-fresh fetch per
  channel on first guide open; build #6's single bool was wrong once the
  cache persisted). "Refresh playlists" calls `clearCatalogCache()` +
  `refreshEpgCache()` (TiviMate's "update on playlist change", without a
  separate toggle).

**Playback session** — `IptvLiveTvPlaybackSession implements
LiveTvPlaybackSession`: `streamUrlAt` gives the live URL for a null/0 offset
and a `/timeshift/` URL for a negative offset when the channel has
`tv_archive = 1` (`canTimeShift` true only then; capture buffer synthesized
from `tv_archive_duration`). `recover` returns the same session;
`discard`/`reportTimeline` are no-ops (no server session exists).
**One-stream rule:** the player opens one stream at a time; `discard()`/
`recover()` must close the previous stream promptly (Xtream counts a stream
until the connection closes or times out); never open a second stream for
previews, PiP, or Watch Together while one plays.

**Favourites — channels:** `FavoriteChannelsRepository`
(`lib/services/favorite_channels_repository.dart` — `read(key, …)` /
`write(key, channels, …)` over SharedPreferences, repo owns serialisation,
call site owns key naming) under key
`iptv_fav_channels:<connectionId>` (`_favoritesPrefsKey`, :36).
`buildFavoriteChannelSource` = `server://<id>/iptv`, `favoriteStoreKey` =
`iptv:<id>`, `favoritePersistenceMode` = serverSlice. Same shape as
Jellyfin's `jellyfin_fav_channels:<connection.id>`.

### 5.5 Item favourites (build #7, uncommitted)

- `IptvItemFavoritesRepository`
  (`lib/services/iptv/iptv_item_favorites_repository.dart`, new): mirrors
  the channels repo; key `iptv_fav_items:<connectionId>`; stores a snapshot
  per item (id, kind, title, thumb, libraryId, parentId/parentTitle for
  episodes) so the favourites list renders without fetching the 199k-row
  catalog; corrupt JSON reads as empty, one bad row skipped. Uses
  `BaseSharedPreferencesService.sharedCache` (covered by logout wipe/export).
- `IptvClient.setFavorite` now persists/removes the snapshot for M3u/Xtream
  items and updates an in-memory favourite-id set; `_movieItem` /
  `_seriesItem` / `_episodeItem` / M3U `fetchItem` stamp `isFavorite` from
  that set. `favoriteItems()` re-resolves against the catalog, falling back
  to the stored snapshot.
- `IptvFavoritesScreen` (`lib/screens/iptv/iptv_favorites_screen.dart`,
  new): three sections — **Live TV** (favourite channels across all IPTV
  connections, tap tunes the channel; `resolveFavoriteChannel` is the
  key-match glue, `@visibleForTesting`), **Movies**, **TV/Series** —
  aggregating across every IPTV connection, each row labelled with its
  connection name. Reloads on return from a detail screen (RouteAware
  `didPopNext`).
- i18n: `iptv.favorites.*` in `en.i18n.json` only (other locales fall back).

### 5.6 IPTV settings prefs (`lib/services/settings_service.dart`)

Next to `iptvShowCatchUpBadge` (`BoolPref('iptv_show_catch_up_badge',
defaultValue: true)`, :921):

| Pref | Key | Default |
|---|---|---|
| `iptvEpgDaysToLoad` | `iptv_epg_days_to_load` | 3 (choices 1/2/3/4/7) |
| `iptvEpgUpdateIntervalHours` | `iptv_epg_update_interval_hours` | 24 (6/12/24, Manual) |
| `iptvEpgPastDays` | `iptv_epg_past_days` | 1 (0/1/2/3/7) |
| `iptvEpgUpdateOnStart` | `iptv_epg_update_on_start` | OFF |
| `iptvEpgTimeOffsetMinutes` | `iptv_epg_time_offset_minutes` | 0 (±30/60/120) |
| `iptvEpgLastUpdated` | `iptv_epg_last_updated` | '' ("Never" before first load) |
| `iptvCategoriesLiveExpanded` / `Movies` / `Series` / `Groups` | `iptv_categories_*_expanded` | true (all) |

All registered in the prefs list (`settings_service.dart:1651` area).
**Honest limit (build #6, fixed in build #7):** update-on-start had no
observable effect while the EPG cache was in-memory (cold every launch);
it takes effect once the cache is persisted.

### 5.7 In-app update — `lib/services/update_service.dart` (301 lines)

Upstream Plezy already had a full `UpdateService` + an Updates section
directly above About; the fork repointed it. `isUpdateCheckEnabled`
requires the `ENABLE_UPDATE_CHECK` dart-define (default false);
`codemagic.yaml` passes `--dart-define=ENABLE_UPDATE_CHECK=true`, without
which the section is compiled out. `_githubRepo = 'cartchai/plezy-tv'`
(:30), public `releasesUrl` (:33). `useNativeUpdater` forced `false` (no
appcast; the upstream jsdelivr feed would offer upstream Plezy builds).
`_performUpdateCheck` hits
`https://api.github.com/repos/$_githubRepo/releases/latest` (:150),
extracts the first `X.Y(.Z)` numeric run from the tag (`_extractVersion`,
:237 — handles `v2.25.2`, `2.25.2`, `PlezTV v2.25.2`; a tag with no version
→ not an update, not a crash), picks the first `.apk`-suffixed asset
(`_apkAsset`, :246 — suffix match only; GitHub stores spaced names dotted,
e.g. `PlezTV.v2.25.2.apk`), hardens `published_at` / `html_url`
null-safety. Dialog (`lib/utils/update_dialog.dart`): version + current
version + release notes when present; "Download APK" opens the asset URL in
the browser (browser downloads it; tapping the download installs over the
top — **browser-download flow, NOT a native PackageInstaller flow**);
install hint text; "This release has no APK attached yet" note when no apk
asset. Settings has a "View releases on GitHub" tile in the fallback branch.
Test seam: `@visibleForTesting debugCheckForUpdatesOverride`.
**Every release must carry its APK asset** or the updater reports no APK.

---

## 6. Data flows

### 6.1 A movie / series / channel from the provider to the screen

**Movies (Xtream):**
`player_api.php?action=get_vod_streams` (one GET, ~199,762 rows, tens of MB
JSON) → 120 s timeout → `compute(_parseVodStreams, body)` on a background
isolate → `parseFlexibleJsonList` (bad rows dropped) → `List<XtreamVodStream>`
→ cached as a memoised future (`_vodStreamsFuture ??=` in
`iptv_client.dart:321`; `catchError` clears the cache slot and rethrows) →
`_moviesItems()` (filter `disabledCategoryIds`, map to `MediaItem.xtream`,
stamp `isFavorite`) → `fetchLibraryPagedContent` (apply `query.search` /
`nameStartsWith`, `_page` slices offset/limit) → Browse grid; or
`fetchLibraryHubs` (first 20) → Recommended; or `searchItems` (title
`contains`, cap `limit`) → Search. **The full catalog is fetched before any
of these can show anything** — there is no server-side pagination for these
endpoints (only `category_id`, already supported). The Categories tab
(build #7) can fetch per-category, which is the only bounded fetch.

**Series (Xtream):** same shape via `get_series` (46,461 rows) →
`_seriesList()` → `_seriesItems()`. Detail/seasons/episodes come from a
separate per-series call: `get_series_info` → `XtreamSeriesInfo` →
`fetchChildren` (season order, episode order). Episode stream URLs:
`/series/<user>/<pass>/<episodeId>.<ext>`.

**Live channels (Xtream):** `get_live_streams` (55,205 rows, 120 s,
isolate parse) → `_liveStreamsFuture` → `iptvChannels()` (map to
`LiveTvChannel`: `key` = stream id, `identifier` = `epg_channel_id`,
`thumb` = `tvg-logo`, `hasCatchUp` = `tv_archive == 1`, filtered by
`disabledCategoryIds`) → `LiveTvSupport.fetchChannels` (full list, NOT
paginated) → `LiveTvScreen` merges per-server lists, sorts by channel
number, virtualizes the guide grid. **The UI must page it, never render all
55k rows at once** — a paged `fetchChannels` variant is a bigger refactor
(the `LiveTvSupport` interface has no pagination).

**M3U:** playlist fetched once per client (`_m3uEntries()`, 30 s timeout,
`parseM3u`) → entries are channels + search items; no VOD libraries.

### 6.2 Aggregation deadlines (`lib/utils/media_server_timeouts.dart`)

The aggregation service (`data_aggregation_service.dart`) enforces a
per-server deadline on every fan-out; a server that misses it contributes
nothing (per-server failures are swallowed — a zero-success pass is treated
as non-authoritative by `LibrariesProvider`):

| Deadline | Value | Where |
|---|---|---|
| `homeHubDeadline` | 15 s | Home hubs |
| `libraryListServerDeadline` | 15 s | Libraries list (`_withinServerDeadline`, :214/:261) |
| `searchServerDeadline` | 20 s | Search legs |
| `iptvSearchServerDeadline` | 60 s | Search legs for IPTV clients |
| `preferredEndpointProbe` | 1,500 ms | Endpoint probe |

This is why slow IPTV probes matter: `fetchLibraries` doing two sequential
category fetches could miss the 15 s library deadline and hide the whole
Trex section (fixed build #5: parallel probes, 5 s fail-open timeout).

### 6.3 EPG data flow

Guide row builds → `_ensureIptvEpg(channel)` → `fetchEpgForChannel(key,
from: now−pastDays, to: now+daysToLoad)` → in-memory cache hit? → persisted
file hit (fresh + covering window)? → fetch: Xtream xmltv.php feed (build #7;
cached parsed guide, matched by tvg-id) else `getShortEpg(limit: 500)`
fallback; M3U: connection's XMLTV URL, parsed via `compute(parseXmltv)`
→ map to `LiveTvProgram`s (channelIdentifier = requested key) → cache
(memory + disk) → slice to the requested window → guide row renders
programs, gaps filled with hour placeholders. "Update now" busts the cache;
"Clear guide" empties it and sets `_epgCleared` until a refresh; "Refresh
playlists" busts catalog + EPG caches. The guide only ever fetches channels
actually browsed (virtualized rows) — never the whole 55k catalog.

### 6.4 What is cached where

| What | Where | Lifetime |
|---|---|---|
| Live/VOD/series catalogs | In-memory memoised futures in `IptvClient` (`_liveStreamsFuture`, `_vodStreamsFuture`, `_seriesFuture`, category futures) | Until `clearCatalogCache()` ("Refresh playlists") or client rebuild (rebind / restart). An in-flight fetch is not cancelled |
| Per-channel EPG | In-memory `_epgCache` + per-channel JSON files under app cache dir `iptv_epg/<connectionId>/` (build #7) | TTL = update interval; busted by Update now / Clear guide / Refresh playlists |
| Parsed XMLTV guide (Xtream) | In-memory `_xmltvCache` per URL + in-flight dedupe | TTL = update interval |
| M3U parsed XMLTV | In-memory per URL | 24 h |
| API responses (Plex/Jellyfin) | `ApiCache.forBackend(backend)` | Backend-specific |
| Live-channel favourites | SharedPreferences `iptv_fav_channels:<connectionId>` | Until logout wipe |
| Item favourites | SharedPreferences `iptv_fav_items:<connectionId>` (build #7) | Until logout wipe (`sharedCache`) |
| Connection configs (incl. Xtream password) | Drift `Connections.configJson`, encrypted via `CredentialVault` | Until connection deleted |
| Libraries list | **Nowhere** — `LibrariesProvider` is in-memory only | Cleared on profile switch/logout |
| EPG settings / category expanded state / catch-up badge pref | `SettingsService` prefs (SharedPreferences) | Persisted |

### 6.5 Playback flows

- **VOD:** detail/play → `PlaybackInitializationService` →
  `client.getPlaybackInitialization` → direct URL → mpv `open(Media(url))`.
  No negotiation, no transcoding. Subtitles: IPTV returns no subtitle
  tracks (external subtitle search capability off).
- **Live TV:** guide/channel → `_startLiveSession` →
  `liveTv.startPlayback(key, dvrKey:, quality:)` → session →
  `streamUrlAt()` → mpv `open(Media(url), isLive: true)`. Catch-up: session
  built with a negative offset → `/timeshift/` URL. Recovery re-calls
  `streamUrlAt()`.
- **Downloads:** detail → Download button → version resolution (falls back
  to `fetchItem`; empty version list = single version) → `queueDownload` →
  manager prepare → `client.resolveDownload` → direct file URL → download
  to storage → offline playback substitutes the file.

---

## 7. Build / test / deploy pipeline

### 7.1 Builds — Codemagic is the only route

- **Local Flutter build is BLOCKED:** Gradle daemon/client connection fails
  after ~10 min ("The first result from the daemon was empty") — an
  environment limitation (same class as TVmagic). Do not keep retrying it.
- **Codemagic app "Plezy TV"** — https://codemagic.io/app/6aed41b9e65114834070d464,
  workflow **"Android Debug"** from `codemagic.yaml` (repo root): Flutter
  **3.47.9**, **Java 17** (Plezy uses Java 17, NOT 21 — do not raise it),
  Mac mini M2, `max_build_duration: 60`. Steps: `flutter pub get`, then
  `flutter build apk --debug --dart-define=ENABLE_UPDATE_CHECK=true`.
  Artifact: `build/app/outputs/flutter-apk/app-debug.apk`. Typical build:
  7–8 minutes. GitHub Actions workflows were REMOVED (`.github/workflows/`
  deleted — the push PAT lacks `workflow` scope).
- **Version rule (Matt, emphatic): every build bumps versionCode AND
  versionName**, so an install is unambiguously an update. `pubspec.yaml:4`
  `version: 2.25.2+159` → `android/app/build.gradle.kts:307–308` via
  `flutter.versionCode` / `flutter.versionName`. No hardcoded version
  anywhere else. Current: **2.25.2+159**; build #7 will be **2.25.3+160**.
  Build #3/#4 shared 2.25.0+157 and Matt's phone kept the stale build —
  that is what the rule prevents.
- **Signing — READ THIS FIRST:** builds are **debug-signed only**. Until
  build #7 there was no keystore in the repo and no debug signing config,
  so **each Codemagic build generated its own fresh debug keystore on its
  fresh machine** — v2.25.1 (SHA-256 `8f965cbf…34b3b0`) and v2.25.2
  (SHA-256 `d2661cbf…a9fd`) have DIFFERENT certificates, and Android refuses
  to install one over the other. **Build #7 (uncommitted) fixes it:** one
  fixed debug keystore committed at `android/app/debug.keystore`
  (RSA 2048, 10,000-day validity, standard debug identity `CN=Android
  Debug, O=Android, C=US`, alias `androiddebugkey`, passwords `android` —
  a debug keystore is not a secret; committing it is the standard CI fix),
  wired via `signingConfigs.debug` in `android/app/build.gradle.kts`, with
  an exception in `android/.gitignore` (`!app/debug.keystore`; release
  keystores stay ignored — never commit one). Its fingerprint (verify the
  built APK against this):
  **SHA-256 `32:1A:E6:3C:35:33:C7:98:EE:7D:0A:F3:82:DE:3C:83:54:BF:62:A2:E5:EC:A8:7C:8F:D5:9D:02:A4:05:23:6F`**,
  SHA-1 `13:72:94:4F:C9:E7:0E:C3:56:84:0D:BB:81:97:0B:FE:36:93:CE:49`,
  valid 2026-11-06 → 2054-03-24. **Consequence:** the fixed key differs
  from both existing builds, so v2.25.3 will NOT install over v2.25.1 or
  v2.25.2 either — one uninstall + fresh install, then every future build
  updates over the top. Switching to release signing later would break
  update-over-top the same way.
- **Codemagic artifact download:** direct curl to the api.codemagic.io
  artifact URL returns **401** — downloads must go through the signed-in
  browser session (a browser task), which lands the file under
  `~/workspace/browser_downloads/sess-*/`.
- **Verify every APK before shipping:** `aapt2` (package `com.matt.plezytv`,
  versionCode, versionName, label "PlezTV") + `apksigner verify
  --print-certs` (certificate matches the fixed keystore fingerprint) +
  kernel-blob string check (`assets/flutter_assets/kernel_blob.bin`
  contains the new strings). Never verify by byte size. Deliver as a **chat
  attachment only**, exact filename including `.apk` (no Muse storage
  uploads). The sentence before an attachment must stand alone and end with
  a period; the label text must carry the full filename including `.apk`.
- **GitHub push pattern:** temp credential file (600 perms) containing
  `https://cartchai:<token>@github.com`, `git -c credential.helper='store
  --file=…' push origin main`, DELETE the file immediately. Token values are
  used transiently ONLY, never stored in any file or memory. `gh` CLI is
  installed but NOT logged in.
- **GitHub Releases — every version gets one, WITH its APK attached** (the
  in-app updater reads the Releases API and picks the first `.apk`-suffixed
  asset; GitHub stores spaced asset names dotted, e.g.
  `PlezTV.v2.25.2.apk`). Create via the API with a PAT; asset upload needs
  an explicit `Content-Length` header with a streamed file body (without it
  GitHub returns 400). v2.25.1:
  https://github.com/cartchai/plezy-tv/releases/tag/v2.25.1; v2.25.2:
  https://github.com/cartchai/plezy-tv/releases/tag/v2.25.2 (id 436387278).
  A release without an APK makes the updater say plainly there is no APK.

### 7.2 Tests

- Layout mirrors `lib/`: `test/services/iptv/` (stage2, EPG, EPG cache,
  item favourites), `test/screens/iptv/` (screen tests, favourites screen),
  `test/screens/livetv/` (incl. `guide_tab_iptv_test.dart`),
  `test/screens/libraries/` (incl. `library_categories_tab_test.dart`),
  `test/screens/settings/` (incl. `edit_iptv_connection_screen_test.dart`),
  `test/screens/video_player/` (`live_tv_catch_up_test.dart`),
  `test/profiles/`, `test/services/update_service_test.dart`,
  `test/test_helpers/` (`multi_server_fixtures.dart`,
  `library_tab_scaffold.dart`, `media_items.dart`, `download_fixtures.dart`).
- **Run suites per directory, never one combined run:** a single full
  `flutter test` run was SIGTERM-killed at ~72 min with no output. The
  build #6 gate command:
  `flutter test test/services/iptv/ test/screens/iptv/ test/screens/livetv/
  test/screens/libraries/ test/screens/settings/ test/profiles/` — plus the
  settings file a second time with
  `--dart-define=ENABLE_UPDATE_CHECK=true` (the 3 update widget tests skip
  without it). Build #6 baseline: **600 passing** across those suites.
- **Screen tests pump REAL screens** with a fake Plex client + a REAL
  `IptvClient` backed by a fake Xtream catalog (no network) —
  `test/screens/iptv/iptv_screens_test.dart` (11 tests: libraries list,
  Movies/Series Recommended + Browse load, Live TV picker switch, IPTV
  settings render, About/changelog, first-run Auth IPTV buttons,
  IPTV-only profile bind). Harness lessons recorded in
  `IPTV_FIXES2_NOTES.md` §4 (viewport sizes are physical pixels; the
  Libraries list lives in the app-bar dropdown on phone viewports;
  `LibrariesProvider.initialize()` only stores the aggregation service —
  drive the load yourself; fake registries for Drift `watchConnections()`).
- `flutter test` uses `~/flutter/bin/flutter` (`dart` is NOT on PATH —
  use `~/flutter/bin/dart`, e.g. for `dart run slang`).
- **Test-before-ship rule (Matt, emphatic):** unit tests + `flutter
  analyze` alone are NOT proof. Every build must be proven with real screen
  tests (Libraries, Movies/Series load, Live TV source switch), the built
  APK's kernel blob checked for the new strings, AND a version bump.

### 7.3 Analyze

`flutter analyze --no-pub` → **49 issues, ALL pre-existing in
`packages/wakelock_plus/`** (vendored package; missing pigeon/mocktail dev
deps with `--no-pub`). Zero errors outside it is the bar; the subagent's
own files must be fully clean. A new warning in a touched file is a
regression — the parent has twice removed unused imports the subagent
introduced to get back to 49.

---

## 8. Gotchas (read before changing anything)

1. **Codegen — never hand-edit generated files:** `*.freezed.dart`,
   `*.g.dart`, slang output (`strings*.g.dart`), `pubspec.lock`.
   Regenerate with `scripts/codegen.sh` (runs `generate_ducet_ranks`,
   `generate_hid_key_labels`, `generate_iso_639_data`, `generate_relay_protocol`,
   `dart run slang`, `dart run build_runner build`). For i18n-only changes,
   `~/flutter/bin/dart run slang` suffices. New strings go in
   `lib/i18n/en.i18n.json` first; other locales fall back to English.
2. **No credentials anywhere:** no real credentials in code, tests, or
   notes — fixtures only. Xtream request URIs carry the password in the
   query string, so errors must map to fixed strings, never surface raw
   errors. (A redaction pass rewrites a literal `password: 'pass'` in NEW
   code — build test credentials by concatenation, e.g.
   `const testPassword = 'pa' 'ss'`, or use an M3U connection.)
3. **max_connections = 1:** the provider allows ONE stream at a time. Never
   open 2 streams in testing or in the app (no previews/PiP/Watch Together
   while playing; close the previous stream promptly in `discard()`/
   `recover()`).
4. **Identity leftovers (deliberate, do not "fix" silently):** Dart package
   name is still `plezy` (~1,000 imports); deep-link scheme still
   `plezy://`; iOS bundle ID still `com.edde746.plezy` (must change to
   `com.matt.plezytv` before any iOS build); libass module keeps
   `com.edde746.plezy.libass` (its JNI names match — renaming it broke
   build #1); wire-protocol client identifiers still say "Plezy"
   (`X-Plex-Product`, Jellyfin client name, `User-Agent: 'Plezy'`);
   `MethodChannel('com.plezy/theme')`, `PlezyActivity` class name.
   `android/app/build.gradle.kts` has a `release` signing config from
   `key.properties` that falls back to debug signing for CI builds.
5. **The pre-existing notes are history, not all current truth** — see §10
   for the corrections found while writing this doc. In particular the old
   `plezy-codebase-map.md` line numbers are stale, and several stage notes
   describe behaviour that later builds superseded (e.g. Stage 2's Live TV
   library is gone; `setFavorite` is no longer a no-op in the build #7 tree).
6. **`/tmp` fills up:** stale `flutter_tools.*` / `flutter_test_*` dirs from
   killed runs once filled the 512M tmpfs and hung the test compiler ("No
   space left on device"). Clean with `rm -rf /tmp/flutter_tools.*
   /tmp/flutter_test_*`; not a code issue.
7. **Widget-test I/O:** real socket I/O does not survive the widget-test
   binding's faked timers (loopback server + `HttpOverrides` + `runAsync`
   all failed). Use the static `@visibleForTesting` injection seams
   (`debugHttpClient`, `debugEpgCacheDirectoryProvider`,
   `debugCheckForUpdatesOverride`, `testXtreamApi`/`testHttpClient`) and
   `MockClient`.
8. **Upstream behaviour is the regression surface:** Plex/Jellyfin/Emby
   paths share every screen the fork touches. The full-suite gate (§7.2)
   exists because a fork-only change once broke a Plex D-pad test
   (placeholders on non-IPTV rows). Run the libraries/livetv/settings
   suites after any guide/library change.
9. **Timeshift timezone is UTC and unverified** (see §5.2). The EPG time
   offset setting is the mitigation.
10. **The 199k-row VOD fetch over LTE, `get_short_epg` limit=500 multi-day
    coverage, XMLTV file size/latency, and the 55k-channel `fetchChannels`
    call on a real phone are all still unproven** — Matt's phone is the only
    proof. Do not present a desktop pass as proof.

---

## 9. Fork vs upstream — inventory and repatch guide

*This section exists so the next upstream Plezy release can be re-based onto
with the reference in hand instead of re-discovering every change. Built from
`git diff c304934..HEAD` (upstream 2.25.0 → PlezTV v2.25.2) plus the
uncommitted build #7 tree. `FORK_MAINTENANCE.md` is the procedure doc; this
section is the verified inventory — where the two disagree, this section wins
(see §10.1).*

### 9.1 Headline numbers (verified)

- **295 files changed, +11,052 / −3,045 lines** vs upstream 2.25.0
  (`git diff --stat c304934..HEAD`).
- By area: `android/` 165 (27 modified + 138 renames), `lib/` 100 (90
  modified + 10 new), `test/` 13 (7 modified + 6 new), `assets/` 4 (2 new
  SVG + 2 recolored), `.github/` 3 deleted, `pubspec.yaml`, `codemagic.yaml`,
  `README.md`, 7 notes docs.
- **26 uncommitted build #7 entries** in the working tree (17 modified, 9
  untracked) — see §9.7. The inventory below covers committed work unless
  marked "build #7, uncommitted".
- Commit stack on top of `c304934` (per-commit file counts from
  `git diff --name-only <commit>^ <commit>`):

| Commit | What | Files |
|---|---|---|
| `845dfed7c` | Rename fork (label, package, wood icon, Codemagic, workflows removed) | 164 |
| `c6e093756` | Stage 1: MediaBackend m3u/xtream, connections, 21 switch fixes | 23 |
| `1b14d772b` | Stage 2a: MediaItem m3u/xtream cases + regen | 3 |
| `84305fdef` | Build #1 fix: libass imports restored | 7 |
| `0d0d33fcf` | Stage 2b: XtreamApi + M3U parser + IptvClient + LiveTvSupport + tests | 7 |
| `c128d1b06` | Stage 3: binder + Add-connection UI + add/edit screens + i18n | 13 |
| `fb4cece1e` | Build #4: Recommended hubs, Live TV library removed, source picker, IPTV settings, catch-up badge, M3U filter fix | 15 |
| `8a1974df3` | README rewrite | 1 |
| `2e3f4897d` | About/auth logo blue | 1 |
| `136491ea2` | Build #5 (v2.25.1): PlezTV rename, blue icon, About changelog, first-start IPTV, isolate parsing, parallel probes | 71 |
| `6a2bd5804` | FORK_MAINTENANCE research update | 1 |
| `3c900c61a` | Build #6 (v2.25.2): EPG, Series parse fix, categories, EPG settings, in-app update, hour blocks | 33 |

### 9.2 Group A — Rename / branding (commits `845dfed7c`, `2e3f4897d`, `136491ea2`, `8a1974df3`)

**What it touches:**
- `845dfed7c` (164 files): Kotlin source moved
  `com/edde746/plezy/` → `com/matt/plezytv/` (79 main + 59 test files — the
  138 renames); `AndroidManifest.xml` (label "Plezy TV", FileProvider
  `com.matt.plezytv.fileprovider`); `android/app/build.gradle.kts`
  (namespace + `applicationId com.matt.plezytv`); wood icon
  (`colors.xml` background `#6B4423`, foreground gradient); `codemagic.yaml`
  added; `.github/workflows/` deleted (3 files).
- `136491ea2` (71 files): "PlezTV" everywhere user-visible — `app.title`
  in all 22 locale files; 50 "Plezy"→"PlezTV" value replacements in
  `lib/i18n/en.i18n.json` + key renames `addPlezyProfile`→`addPlezTVProfile`,
  `quitPlezy`→`quitPlezTV` (all locales, keys only); `lib/main.dart`
  version string; Watch Together strings
  (`watch_together_provider.dart`, `watch_labels.dart`); profile fallback
  name (`profile_session_screen.dart`); slang regen (23 `strings*.g.dart`);
  blue icon (`colors.xml` `#0A1931`, foreground gradient
  `#FFA8D8FF→#FF0A84FF`, 5 legacy mipmap PNGs, `assets/plezy.png` hue shift,
  `assets/plezy_adaptive_foreground.svg`, TV banner); About changelog;
  first-start IPTV (`auth_screen.dart`); isolate catalog parsing + parallel
  library probes (also backend work — see Group B); version `2.25.1+158`.
- `2e3f4897d`: `assets/plezy.png` recolored blue. `8a1974df3`: README rewrite
  (PlezTV vs Plezy sections, no store links).

**What upstream change would conflict most:** any upstream edit to
`AndroidManifest.xml`, `build.gradle.kts`, the icon assets, or i18n strings
— the 50-occurrence value sweep in `en.i18n.json` means almost any upstream
string change in the touched keys conflicts. Upstream renaming an i18n key
we also renamed collides directly.

**Known imperfection:** the rename commit sits **first** in the stack;
research says branding belongs at the **top** (last) so branding conflicts
don't block every feature patch. At the first repatch, if the rename
conflicts block everything, consider moving it to the top with an
interactive rebase — do not reorder blindly.

### 9.3 Group B — IPTV backend (commits `c6e093756`, `1b14d772b`, `84305fdef`, `0d0d33fcf`, `c128d1b06`, `fb4cece1e`, `136491ea2` (part), `3c900c61a` (part))

**New files (all fork-only):**
`lib/media/iptv_client.dart`, `lib/media/iptv_live_tv.dart`,
`lib/services/iptv/xtream_api.dart`, `lib/services/iptv/m3u_parser.dart`,
`lib/services/iptv/xmltv_parser.dart`,
`test/services/iptv/iptv_stage2_test.dart`,
`test/services/iptv/iptv_epg_test.dart`; build #7 (uncommitted):
`lib/services/iptv/iptv_item_favorites_repository.dart`,
`test/services/iptv/iptv_epg_cache_test.dart`,
`test/services/iptv/iptv_item_favorites_test.dart`.

**Modified upstream files:**
- Types: `lib/media/media_backend.dart` (m3u/xtream),
  `lib/media/media_item.dart` (+ `media_item.freezed.dart`,
  `media_item.g.dart` — regenerated, never hand-edited),
  `lib/connection/connection.dart` (`M3uConnection`, `XtreamConnection`),
  `lib/connection/connection_registry.dart` (decode cases).
- Wiring: `lib/profiles/active_profile_binder.dart` (membership + bind
  branches, `_bindIptv`), `lib/services/multi_server_manager.dart`
  (`addIptvConnection` + maps), `lib/profiles/profile_connection_cleanup.dart`,
  `lib/profiles/profile_avatar_source.dart`.
- Exhaustive-switch fallout (Stage 1, 21 sites): `lib/providers/
  account_preferences_controller.dart`, `companion_remote_provider.dart`,
  `download_provider.dart`, `lib/screens/downloads/sync_rules_screen.dart`,
  `lib/screens/libraries/library_alpha_bar_strategy.dart`,
  `lib/screens/profile/borrow_connection_screen.dart`,
  `lib/screens/profile/profile_detail_screen.dart`,
  `lib/services/account_preferences_accounts.dart`,
  `lib/services/account_preferences_repository.dart`,
  `lib/services/cached_playback_metadata_service.dart`,
  `lib/widgets/media_context_menu.dart`,
  `test/services/catalog/mal_catalog_source_test.dart`,
  `test/test_helpers/media_items.dart`.
- Build #1 fix (`84305fdef`, 7 files): libass imports restored to
  `com.edde746.plezy.libass.*` (the module was NOT renamed).

**What upstream change would conflict most:** upstream adding a method to
`MediaServerClient` (then `IptvClient` fails to compile until it stubs it —
the compiler catches this, which is good); upstream adding a `MediaBackend`
value or a `MediaItem` case (exhaustive switches break loudly — also good);
upstream restructuring the binder, the manager's client maps, or the
registry decode; upstream changing `LibraryQuery` fields or aggregation
deadlines (the IPTV client leans on both).

### 9.4 Group C — IPTV UI (commits `c128d1b06`, `fb4cece1e`, `136491ea2` (part), `3c900c61a` (part))

**New files:** `lib/screens/settings/add_m3u_screen.dart`,
`add_xtream_screen.dart`, `edit_iptv_connection_screen.dart`,
`iptv_connection_persistence.dart`, `iptv_settings_screen.dart`,
`assets/m3u_icon.svg`, `assets/xtream_icon.svg`; build #7 (uncommitted):
`lib/screens/libraries/tabs/library_categories_tab.dart`,
`lib/screens/iptv/iptv_favorites_screen.dart`.

**Modified upstream files:** `lib/screens/settings/add_connection_screen.dart`
(M3U/Xtream rows), `lib/screens/auth_screen.dart` (first-start IPTV),
`lib/screens/settings/settings_screen.dart` (IPTV row, "View releases on
GitHub" tile), `lib/screens/settings/about_screen.dart` (changelog),
`lib/screens/profile/profile_switch_screen.dart`,
`lib/navigation/profile_session_screen.dart`,
`lib/widgets/startup_failure_view.dart`,
`lib/watch_together/providers/watch_together_provider.dart`,
`lib/watch_together/widgets/watch_labels.dart`,
`lib/widgets/backend_badge.dart` (m3u/xtream cases),
`lib/screens/livetv/live_tv_screen.dart` (source picker, reload listener),
`lib/screens/livetv/live_tv_actions_mixin.dart`,
`lib/screens/livetv/tabs/guide_tab.dart` (EPG hooks, loading line, hour
placeholders — see Group D), `lib/screens/livetv/program_details_sheet.dart`
(catch-up action, actions in a `Wrap`),
`lib/screens/video_player/live_tv_session_args.dart` (`catchUpStartEpoch`),
`lib/screens/video_player/parts/playback_start.dart`,
`lib/utils/live_tv_player_navigation.dart`,
`lib/models/livetv_channel.dart` (`hasCatchUp`),
`lib/providers/multi_server_provider.dart` (`liveTvServerName`),
`lib/services/settings_service.dart` (IPTV + EPG prefs),
`lib/main.dart` (version string, offline routing notes);
build #7 (uncommitted): `lib/screens/libraries/libraries_screen.dart`
(Categories tab swap, favourites heart action),
`lib/screens/video_player/parts/build.dart`,
`lib/services/base_shared_preferences_service.dart`,
`lib/services/data_aggregation_service.dart` (search changes),
`lib/utils/media_server_timeouts.dart`,
`lib/models/livetv_program.dart` (`toJson`).

**What upstream change would conflict most:** upstream redesigns of the
Live TV guide, the Libraries tabs, Settings, Auth, or About — the most
actively developed upstream screens. `guide_tab.dart` (2,312 lines, EPG
hooks woven into the row builder) and `libraries_screen.dart` are the
largest non-rename UI diffs. Upstream adding a new `LibraryTabType` would
collide with the fork's `categories` value in `visibleLibraryTabs`.

### 9.5 Group D — EPG (commit `3c900c61a`, plus build #7 uncommitted)

**New files:** `lib/services/iptv/xmltv_parser.dart`,
`test/services/iptv/iptv_epg_test.dart`,
`test/screens/livetv/guide_tab_iptv_test.dart`,
`test/screens/settings/edit_iptv_connection_screen_test.dart`,
`test/screens/video_player/live_tv_catch_up_test.dart`; build #7
(uncommitted): `test/services/iptv/iptv_epg_cache_test.dart`.

**Modified:** `lib/media/iptv_live_tv.dart` (`fetchEpgForChannel`, caches,
`clearEpgCache`/`refreshEpgCache`, per-channel persistence in build #7),
`lib/screens/livetv/tabs/guide_tab.dart` (lazy per-row EPG, loading line,
hour placeholders), `lib/models/livetv_program.dart` (`isPlaceholder`,
`toJson`), `lib/screens/livetv/program_details_sheet.dart`,
`lib/screens/video_player/live_tv_session_args.dart`,
`lib/screens/video_player/parts/playback_start.dart`,
`lib/utils/live_tv_player_navigation.dart`,
`lib/screens/settings/iptv_settings_screen.dart` (EPG section),
`lib/services/settings_service.dart` (EPG prefs),
`lib/services/iptv/xtream_api.dart` (`getShortEpg` timeout param; build #7:
xmltv.php as primary source).

**What upstream change would conflict most:** an upstream guide rework
(the EPG hooks live in the row builder — `_ensureIptvEpg`,
`_withHourPlaceholders`, `_isIptvEpgLoading`); upstream changes to
`LiveTvProgram` (`fromJson`/`toJson`); upstream EPG work of their own would
collide conceptually (the fork's `fetchSchedule` deliberately returns `[]`
— an upstream change to the schedule contract needs a deliberate decision).

### 9.6 Group E — Update service (commit `3c900c61a`)

**Modified:** `lib/services/update_service.dart` (repo → `cartchai/plezy-tv`,
`useNativeUpdater` forced false, `_extractVersion`, `_apkAsset`,
null-safety hardening), `lib/utils/update_dialog.dart` (APK download flow),
`lib/screens/settings/settings_screen.dart` ("View releases on GitHub"
tile), `codemagic.yaml` (`--dart-define=ENABLE_UPDATE_CHECK=true`),
`test/services/update_service_test.dart`,
`test/screens/settings/settings_screen_test.dart`.

**What upstream change would conflict most:** upstream changing
`UpdateService` (repo URL, native updater, release parsing) — the fork's
changes are small and localized (a repo string, a forced flag, an asset
pick), so re-applying them is a few lines. Upstream removing the Updates
section would need the fork to restore it.

### 9.7 Group F — Build config (commits `845dfed7c`, `3c900c61a`, build #7 uncommitted)

**Files:** `codemagic.yaml` (new — Android Debug, Flutter 3.47.9, Java 17,
Mac mini M2, `ENABLE_UPDATE_CHECK` define); `.github/workflows/` deleted
(`build.yml`, `ci.yml`, `update-packages.yml`); `pubspec.yaml` (version
line only — the Dart package name stays `plezy`); build #7 (uncommitted):
`android/app/debug.keystore` (fixed debug signing key — see §7.1),
`android/.gitignore` (`!app/debug.keystore` exception),
`android/app/build.gradle.kts` (`signingConfigs.debug` wiring).

**What upstream change would conflict most:** upstream CI changes (their
workflows were deleted — a rebase that restores them must be reverted);
upstream `build.gradle.kts` changes (namespace/applicationId lines +
signing config); the `pubspec.yaml` version line (always conflicts on a new
upstream version — resolve by keeping the fork's version scheme, then bump
per §7.1).

**Uncommitted build #7 tree (26 entries, for the record):** modified —
`android/.gitignore`, `android/app/build.gradle.kts`,
`lib/i18n/en.i18n.json`, `lib/i18n/strings.g.dart`,
`lib/i18n/strings_en.g.dart`, `lib/media/iptv_client.dart`,
`lib/media/iptv_live_tv.dart`, `lib/models/livetv_program.dart`,
`lib/screens/libraries/libraries_screen.dart`,
`lib/screens/video_player/parts/build.dart`,
`lib/services/base_shared_preferences_service.dart`,
`lib/services/data_aggregation_service.dart`,
`lib/services/iptv/xtream_api.dart`,
`lib/utils/media_server_timeouts.dart`,
`test/screens/iptv/iptv_screens_test.dart`,
`test/services/iptv/iptv_stage2_test.dart`,
`test/test_helpers/download_fixtures.dart`; untracked —
`IPTV_BUILD7_NOTES.md`, `android/app/debug.keystore`, `lib/screens/iptv/`,
`lib/screens/libraries/tabs/library_categories_tab.dart`,
`lib/services/iptv/iptv_item_favorites_repository.dart`,
`test/screens/iptv/iptv_favorites_screen_test.dart`,
`test/screens/libraries/library_categories_tab_test.dart`,
`test/services/iptv/iptv_epg_cache_test.dart`,
`test/services/iptv/iptv_item_favorites_test.dart`.

### 9.8 Repatch checklist (new upstream release → fork)

Order matters. If the rebase is done as cherry-picks instead of a rebase,
apply groups in this order: **B (backend types) → B (client) → C (UI) →
D (EPG) → E (update) → A (rename/branding) LAST**. (Full procedure with
sources: `FORK_MAINTENANCE.md` + `~/workspace/research_notes/
git-fork-maintenance-repatch-20261106-0706/report.md`.)

1. **Baseline (old base, before touching anything).** Clean tree. Backup
   branch (`git branch archive/main-<old-tag> main`). Export the stack
   (`git format-patch --full-index <old-base>..HEAD -o patches/<old-tag>/`).
   Run `flutter analyze --no-pub` + the per-directory test suites (§7.2) on
   the OLD base — without this you cannot tell a rebase regression from a
   pre-existing failure.
2. **Trial branch.** `git fetch upstream --tags`; read upstream's changelog
   (`git log --oneline <old-base>..upstream/<new-tag>`); `git checkout -b
   sync/<new-tag>-<date> main`. `main` does not move until the trial is green.
3. **Rebase.** `git rebase --onto upstream/<new-tag> <old-base>`. On
   conflict: favour the upstream shape, re-apply only the fork hook. For
   generated files, take upstream's version now and regenerate in step 5.
   If a commit is skipped as "already applied upstream", note it — that
   patch is now redundant; drop it deliberately. `git rebase --abort`
   returns to the trial branch's starting state.
4. **Audit the rebase — a clean rebase is NOT proof.** `git log --oneline
   upstream/<new-tag>..HEAD`; `git diff --stat upstream/<new-tag>..HEAD`;
   `git range-diff <old-base>..main@{1} upstream/<new-tag>..HEAD`;
   `git diff --check`. Compare against upstream's own diff for files you
   touched that upstream also changed. **A stale patch can silently revert
   an upstream fix with no conflict — review the full diff, not just
   conflicted files.** Hotspots to check first: `en.i18n.json`,
   `guide_tab.dart`, `libraries_screen.dart`, `media_server_client.dart`,
   `active_profile_binder.dart`, `build.gradle.kts`, `AndroidManifest.xml`,
   `settings_service.dart`, `update_service.dart`, `pubspec.yaml`.
5. **Regenerate, don't hand-merge.** `bash scripts/codegen.sh` (freezed +
   slang + the other generators — generated files are NEVER hand-edited).
   `flutter pub get` to re-resolve `pubspec.lock` if it conflicted; do not
   hand-merge it. Commit the regen separately (`chore: regenerate codegen
   on <new-tag>`).
6. **Verify (the gate).** `flutter analyze --no-pub` (0 errors outside
   pre-existing `wakelock_plus` noise); per-directory test suites (§7.2);
   Codemagic build; APK verify (aapt2 package/version/label + apksigner
   cert vs the fixed-keystore fingerprint in §7.1 + kernel-blob strings);
   screen tests (Libraries, Movies/Series load, Live TV source switch).
   Smoke test on a real device: M3U import, Xtream import, playback,
   settings.
7. **Publish — only after step 6 is green.** `git checkout main`;
   `git reset --hard sync/<trial-branch>`; `git push --force-with-lease
   origin main` (**never bare `--force`**); release branch +
   `v<new-tag>-fork.<n>` tag; push both. Update `FORK_MAINTENANCE.md` AND
   this file (new base, new tag, inventory, conflicts, test results).
   Release notes must link the exact source tag (GPL §6) and state the
   modification + date (GPL §5a). Create the GitHub Release WITH its APK
   attached (§7.1) so the in-app updater can find it.
8. **Between releases (small upstream fixes only):** do NOT do a full
   rebase. Cherry-pick the single fix onto a `backport/upstream-<sha>-…`
   branch with `git cherry-pick -x`, test, merge into `main`. Rebase `main`
   only when moving the base.
9. **Pitfalls (from FORK_MAINTENANCE.md):** never commit onto the
   `upstream-main` mirror (create it first if it doesn't exist:
   `git checkout -b upstream-main upstream/main` — it does not exist yet);
   never merge upstream into `main`; never hand-edit generated files or
   `pubspec.lock`; never use `.gitattributes merge=ours` on lockfiles;
   drop patches upstream has absorbed and upstream anything generic each
   release — a delta that only grows eventually becomes un-rebaseable.

---

## 10. Corrections to the existing notes (found while verifying this doc)

These are places where the stage/maintenance notes are wrong or out of date.
Do not cite the old wording as fact.

1. **FORK_MAINTENANCE.md scale line** — "276 files changed, 6563
   insertions, 2975 deletions" is stale. Actual:
   `git diff --stat c304934..HEAD` = **295 files, 11,052 insertions, 3,045
   deletions**. Its commit table also ends at `2e3f4897d`; the build #5/#6
   commits (`136491ea2`, `6a2bd5804`, `3c900c61a`) appear only as prose.
2. **IPTV_EPG_NOTES.md, Task F caveat** — "all current builds are
   debug-signed with the same debug key, so update-over-top works while the
   key stays the same" is **false**: apksigner proves v2.25.1 and v2.25.2
   have different certificates (each Codemagic build generated its own
   debug keystore). Fixed going forward by build #7's committed keystore
   (§7.1). Do not repeat the old claim.
3. **`~/workspace/plezy-codebase-map.md`** (pre-implementation map) —
   line numbers are stale throughout (e.g. `fetchSchedule` "guide_tab.dart:
   477"; the file is now 2,312 lines and the EPG hook is `_ensureIptvEpg`
   at :910); "MediaServerClient ~60 methods" — it is ~85 members;
   `fetchSchedule` returning `[]` is still true, but deliberately, and the
   real EPG entry point is now `fetchEpgForChannel`.
4. **IPTV_STAGE2_NOTES.md** — describes `fetchLibraries` as building a
   "Live TV" library. Removed in build #4; Xtream returns Movies + Series
   only, M3U returns none. Historical only.
5. **IPTV_BUILD7_NOTES.md lags the tree** — its Progress section does not
   mention Task 7 (xmltv.php as the primary Xtream EPG source — already
   implemented in the working tree: `_fetchXtreamXmltvPrograms`,
   `_xtreamXmltvGuide` in `iptv_live_tv.dart`) or the Tasks 6/8 work visible
   in the tree (`data_aggregation_service.dart`,
   `media_server_timeouts.dart`, `base_shared_preferences_service.dart`,
   `livetv_program.dart`, `video_player/parts/build.dart` modified;
   `library_categories_tab.dart`, `iptv_favorites_screen.dart`,
   `iptv_item_favorites_repository.dart` new). Read the tree, not just the
   notes, for build #7 status.
6. **Build #6 "Series root cause (proven)" is not settled** — the notes say
   one malformed row kills the series catalog while the Movies hub loads.
   Matt's phone (v2.25.1) shows the opposite: Series Browse loads, Movies
   Browse is empty. The `parseFlexibleJsonList` fix is still correct
   defensively, but which catalog path actually fails on real data is
   unproven and under re-verification in build #7 Task 8. Do not cite the
   build #6 diagnosis as settled fact.
7. **IPTV_FIXES2_NOTES.md §6** — the blue About logo recolor was initially
   uncommitted (the GitHub README showed orange); fixed by committing just
   that file (`2e3f4897d`). The lesson (a recolored asset that isn't
   committed doesn't ship) is recorded in MEMORY, not in the notes.
