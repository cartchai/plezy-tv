# Plezy TV — IPTV (M3U + Xtream Codes) import progress

Goal: add M3U and Xtream Codes as CONNECTION types on the Add connection
screen (under Plex/Jellyfin/Emby). Each is NAMED by the user at import and
LABELLED by source. Live TV goes to the Live TV section, VOD to the Library
section. Plus a country/region filter to turn off whole countries/regions.

Provider (Matt's, probed 2026-11-05): 55,205 live channels (833 categories),
199,762 VOD movies, 46,461 series, 1 concurrent stream, catch-up on 2,208
channels (tv_archive=1). Credentials were used transiently for one probe
only and are NOT in any file.

## Stage 1 — Backend enum + connections + exhaustive switches (DONE 2026-11-05)

- `lib/media/media_backend.dart`: added `m3u` and `xtream` to MediaBackend
  (id/fromId/fromString/dialect; both are NOT MediaBrowser, so dialect is
  null and usesMediaBrowserApi is false).
- `lib/connection/connection.dart`: added `M3uConnection` (name, playlistUrl,
  optional epgUrl, disabledCategoryIds) and `XtreamConnection` (name,
  serverUrl, username, password, disabledCategoryIds). Both carry the
  user-given library `name` and the country/region filter list
  `disabledCategoryIds`. Password is encrypted at rest by the registry
  (same as Jellyfin tokens).
- `lib/connection/connection_registry.dart`: `_rowToConnection` decodes both
  new kinds (no DB migration — `kind` is a plain string).
- `assets/m3u_icon.svg`, `assets/xtream_icon.svg`: new backend badge icons
  (playlist list / TV set, currentColor so they tint).
- Fixed all 21 non-exhaustive switch sites the new enum values broke:
  media_item.dart (factory + fromJson — throw UnsupportedError until the
  MediaItem.iptv case exists in Stage 2), backend_badge.dart,
  active_profile_binder.dart (membership adds connection id; bind skips IPTV
  until Stage 2), profile_avatar_source.dart (null), profile_connection_cleanup
  (connection id as ServerId), account_preferences_controller (null),
  companion_remote_provider (no-op), download_provider (empty raw),
  sync_rules_screen (match by connection id, label = name),
  library_alpha_bar_strategy (client-side MediaBrowser strategy),
  borrow_connection_screen (no-op), profile_detail_screen (connection id),
  account_preferences_accounts (null), account_preferences_repository
  (unsupported capabilities), cached_playback_metadata_service (null x2),
  media_context_menu (deletion false), mal_catalog_source_test (loop limited
  to plex/jellyfin/emby + throw), test_helpers/media_items (throw).
- Verification: `flutter analyze --no-pub` → 0 errors from these changes.
  The only remaining issues are pre-existing `packages/wakelock_plus/`
  vendored-package errors (missing pigeon/mocktail dev deps), unrelated.

## Stage 2 — MediaItem.iptv + IPTV client (NEXT)

- Add `MediaItem.iptv` freezed union case + factory branch + fromJson case,
  regen via build_runner, replace the Stage 1 throws in media_item.dart.
- Implement `IptvClient` (MediaServerClient): serverId = connection id,
  capabilities (liveTv true, rest false), checkHealth, close, fetchLibraries
  (synthetic "Name — Movies" / "Name — Series"), fetchLibraryPagedContent,
  fetchItem, fetchChildren, searchItems (client-side), fetchContinueWatching
  (local), getPlaybackInitialization (direct URL), liveTv, thumbnailUrl,
  streamHeaders ({}). Everything else throws UnsupportedError.
- Implement `IptvLiveTvSupport`: isAvailable, fetchChannels (key = stream id,
  title, thumb = tvg-logo), fetchSchedule, startPlayback (streamUrlAt =
  timeshift hook, canTimeShift = tv_archive, captureBuffer from
  tv_archive_duration), dvr = null. Favorites keyed by connection id.
- Wire `addIptvConnection` into MultiServerManager + ActiveProfileBinder
  bind branches (replace the Stage 1 skip).

## Stage 3 — Add-connection UI + country/region filter

- Add "M3U" and "Xtream Codes" rows to add_connection_screen.dart (after
  Emby, before Borrow), with BackendBadge cases (done in Stage 1).
- New add screens modeled on add_jellyfin_screen.dart: NAME field + (Xtream:
  server URL + username + password, probe via player_api.php) / (M3U:
  playlist URL, probe fetch + parse header). Persist via
  persistAndBindConnection + rebind.
- Country/region filter UI: checklist of categories with on/off switches,
  persisted in the connection's disabledCategoryIds, hiding those channels
  and VOD from Live TV and Library.

## Constraints (do not violate)

- Never store or log any real credential. No real credentials in the repo.
- 1 concurrent stream: never open a second stream for previews/PiP/Watch
  Together while one plays; close the previous stream promptly in
  discard()/recover().
- Do not break Plex/Jellyfin/Emby behaviour. Keep flutter analyze clean.
- Keep the Dart package name `plezy`. Do not rename imports.
