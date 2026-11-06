# Plezy TV — IPTV Stage 2b notes (2026-11-05)

Data layer + client for M3U + Xtream Codes. NOT committed, NOT pushed.
Parent to review, then wire (Stage 3) and commit.

## Files created (no existing file was modified)

- `lib/services/iptv/xtream_api.dart` — `XtreamApi` (player_api.php /
  get.php / xmltv.php) + models `XtreamCategory`, `XtreamLiveStream`,
  `XtreamVodStream`, `XtreamSeries`, `XtreamEpisode`, `XtreamSeriesInfo`,
  `XtreamEpgProgram`. URL builders: `/live/`, `/movie/`, `/series/`,
  `/timeshift/` (start `YYYY-MM-DD:HH-MM-SS` UTC, duration in minutes).
  Numbers parsed flexibly (strings-or-ints); EPG titles/descriptions
  Base64-decoded with raw fallback. Credentials go in the query string
  (Xtream's auth scheme) and are NEVER logged.
- `lib/services/iptv/m3u_parser.dart` — `parseM3u()` → `List<M3uEntry>`
  (`name`, `url`, `tvgId`, `tvgLogo`, `groupTitle`, `catchupSource`).
  Pure text, no network. Entries without a following URL are dropped.
- `lib/media/iptv_client.dart` — `IptvClient implements MediaServerClient`.
  Named constructors `.m3u` / `.xtream` + `IptvClient.forConnection()`.
  `serverId` = connection id, `serverName` = user-given name,
  `capabilities` = liveTv true, liveTvDvr/videoTranscoding/richHubs/
  userFavorites* false except userFavorites true (see note below),
  `streamHeaders` = `{}`, `watchedThreshold` 0.9, `cache` via
  `ApiCache.forBackend(backend)`.
- `lib/media/iptv_live_tv.dart` — `IptvLiveTvSupport implements
  LiveTvSupport` + `IptvLiveTvPlaybackSession implements
  LiveTvPlaybackSession`. `dvr` null, `isAvailable` true, favorites in
  SharedPreferences under `iptv_fav_channels:<connectionId>` via the
  shared `FavoriteChannelsRepository` (same shape as Jellyfin).
- `test/services/iptv/iptv_stage2_test.dart` — 9 unit tests (M3U parser,
  Xtream URL builders + EPG Base64, client library lists). All pass.

## What the real methods do

- `checkHealth`: Xtream → player_api.php auth probe (online / authError /
  accessDenied / offline); M3U → HEAD on the playlist URL.
- `fetchLibraries`: synthetic libraries `iptv:<id>:live|movies|series`
  titled `<Name> — Live TV|Movies|Series`. M3U gets Live TV only. A
  Movies/Series library is omitted when ALL of its categories are in
  `disabledCategoryIds` (country/region filter); fails open if the
  category fetch fails.
- `fetchLibraryPagedContent`: live library → empty page (channels are
  liveTv-only). Movies/series → Xtream lists, filtered by
  `disabledCategoryIds`, paginated by `query.offset/limit`, with
  `query.search` / `query.nameStartsWith` applied. Item ids are prefixed
  (`movie:<id>`, `series:<id>`, `episode:<seriesId>:<episodeId>`,
  `m3u:<tvgId|name>`).
- `fetchItem`: resolves prefixed ids (Xtream via cached lists /
  get_series_info; M3U via playlist lookup). Returns null when not found.
- `fetchChildren` / `fetchChildrenPage` / `fetchPlayableDescendants`:
  series → episodes from get_series_info (season order, episode order).
- `fetchClientSideEpisodeQueue`: episodes or null when empty.
- `searchItems`: client-side over lazily loaded in-memory lists (VOD +
  series for Xtream; playlist entries for M3U), case-insensitive title
  contains, capped at `limit`, honours `excludedLibraryIds`.
- `fetchContinueWatching`: returns `[]` (local watch state is a follow-up).
- `getPlaybackInitialization`: direct `streamUrl` from the item,
  `isTranscoding: false`, minimal `MediaSourceInfo`/`MediaVersion`;
  throws `PlaybackException(noPlayableSource)` when the item has no URL.
- `resolveExternalPlayback`: same direct URL, or null.
- `thumbnailUrl`: returns the path unchanged (IPTV thumbs are direct
  URLs). `externalImageUrl`: returns the URL unchanged.
- `fetchExternalIds`: empty. `findByExternalIds`: null.
  `fetchPlaybackExtras`: empty chapters/markers.
  `fetchPlaybackExtrasFromCacheOnly` / `fetchCachedMediaSourceInfo`: null.
- `markWatched` / `markUnwatched` / `removeFromContinueWatching` /
  `rate` / `setFavorite`: no-op completes (no server API; local
  persistence is a follow-up).
- `reportPlaybackStarted/Progress/Stopped`: no-op completes.
- `stampLibrary`: returns the item unchanged.
  `resolveDownloadArtwork`: `[]`. `getMachineIdentifier`: connection id.
- Live TV: `fetchChannels` maps Xtream live streams → `LiveTvChannel`
  (`key` = stream id, `identifier` = epg_channel_id so
  `live_tv_matching.dart` can match EPG rows) and M3U entries →
  channels (`key` = tvg-id or URL), both filtered by
  `disabledCategoryIds`. `fetchSchedule` returns `[]` (TODO — EPG
  wiring is the next step). `startPlayback` returns a session whose
  `streamUrlAt` gives the live URL for a null/0 offset and a
  `/timeshift/` URL for a negative offset when the channel has
  `tv_archive = 1` (capture buffer synthesized from
  `tv_archive_duration`; `canTimeShift` true only then). `recover`
  returns the same session; `discard`/`reportTimeline` are no-ops
  (no server session exists). Favorites: `buildFavoriteChannelSource`
  = `server://<id>/iptv`, `favoriteStoreKey` = `iptv:<id>`,
  `favoritePersistenceMode` = serverSlice.

## Methods stubbed with throw UnsupportedError

refreshLibraryMetadata, scanLibrary, fetchLibraryFolders,
fetchFolderChildren, fetchPlayableDescendantsPage, fetchArtistAlbums,
fetchArtistDiscography, fetchAlbumTracks, fetchInstantMix, fetchLyrics,
searchPeople, fetchGlobalHubs, fetchLibraryHubs, fetchRelatedHubs,
fetchExtras, fetchPersonMediaPage, fetchPersonDetails, fetchMoreHubItems,
fetchMoreHubItemsPage, fetchPlaylistsPage, fetchPlaylistMetadata,
fetchPlaylistPage, createPlaylist, addToPlaylist, deletePlaylist,
movePlaylistItem, removeFromPlaylist, fetchCollectionsPage,
fetchCollectionPage, fetchCollectionMemberships, createCollection,
addToCollection, removeFromCollection, deleteCollection, deleteMediaItem,
getFileInfo, createScrubPreviewSource, resolveDownload.

## Verification

- `flutter analyze --no-pub`: 0 errors, 0 warnings outside the
  pre-existing `packages/wakelock_plus/` noise (49 issues total, all in
  that vendored package). My four files + the test file are fully clean
  (no errors, warnings, or infos).
- `flutter test test/connection/connection_models_test.dart`: 19/19 pass.
- `flutter test test/services/iptv/iptv_stage2_test.dart`: 9/9 pass (new).
- `flutter test test/media/media_item_test.dart`: 54/54 pass.
- `flutter test` live-tv contract/session + library_query + jellyfin
  live-tv favorites: 60/60 pass.
- No network was contacted during this work (no real provider
  credentials exist in this repo; nothing to probe against).

## Notes / caveats for the reviewer

- `capabilities.userFavorites` is true (the client heart no-ops
  instead of throwing) but item-level favorite persistence is NOT
  implemented yet — only live-channel favorites persist (via
  SharedPreferences). Item `setFavorite` is a silent no-op for now.
- `IptvClient` stores the connection as the base `Connection` type and
  reads `name` / `disabledCategoryIds` through private typed getters
  (`_name`, `_disabledCategoryIdList`) because the base class lacks
  those getters.
- `fetchChannels` returns the provider's full live list in one call
  (the API has no pagination); the UI must page it, never render all
  55k rows at once.
- Timeshift start timestamps are formatted in UTC (panel convention);
  the timezone is the known disputed point — verify against the real
  provider during bug testing.
- `isAvailable()` returns true unconditionally (per the brief); a
  dead/unreachable provider surfaces as empty channels instead.

## What remains (Stage 3 + testing)

- `MultiServerManager.addIptvConnection` + replace the Stage 1 skip in
  `ActiveProfileBinder` with a real bind (Stage 1 note in
  IPTV_PROGRESS.md).
- Add-connection UI: M3U + Xtream Codes rows on the Add connection
  screen, add screens (NAME field + probe), persist via
  `persistAndBindConnection`.
- Country/region filter UI writing `disabledCategoryIds`.
- EPG: `fetchSchedule` via get_short_epg (visible channels) / xmltv.php.
- Local watch-state / item-favorite persistence.
- Bug testing against Matt's real provider in small batches, never
  2 streams at once; then Codemagic build + APK delivery.
