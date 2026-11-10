# PlezTV build #22 — stream User-Agent (v1.0.5-2.25.0+177)

Audit finding #1 (full audit §6): build #20 fixed the API client, but streams
opened with mpv/ffmpeg's default User-Agent and posters said 'Plezy' — three
identities to one panel. If the panel enforces UA on streams, live TV and VOD
403 while browsing works. This build sends the configured Xtream UA
(Settings → IPTV → Xtream User-Agent, default VLC) on every stream open and
every panel image fetch.

## What changed

- `lib/media/iptv_client.dart`: `streamHeaders` was `const {}` — now
  `{'User-Agent': <resolved>}` (re-read per access; Xtream and M3U alike).
  NEW `artworkHeaders` (same UA). API client UA behaviour unchanged.
- `lib/media/live_tv_support.dart`: NEW `LiveTvPlaybackSession.streamHeaders`
  (default `{'Accept-Language': 'en'}`).
- `lib/media/iptv_live_tv.dart`: IPTV session overrides with
  `{'Accept-Language': 'en', ...client.streamHeaders}` — live edge and
  timeshift URL alike.
- `lib/services/plex_client/parts/live_tv.dart`,
  `lib/services/jellyfin_client/parts/live_tv.dart`: explicit default
  (language header only). Plex/Jellyfin playback untouched.
- `lib/screens/video_player/live_stream_retry.dart`: `open` callback now
  receives `(streamUrl, session)` — adoption happens after the open, so the
  adopted session at open time is still the previous channel's.
- `lib/screens/video_player/parts/live_tv.dart`: `_openLiveStream` takes an
  explicit `headers` param; all four call sites (zap, seek, subtitle switch,
  recovery) pass `session.streamHeaders`.
- `lib/screens/livetv/live_tv_mini_player.dart`: open uses
  `session.streamHeaders`.
- `lib/utils/media_image_helper.dart`: NEW `artworkHeadersFor(client)`
  (IPTV → UA, anything else / null → 'Plezy') + optional `headers` param on
  `serverArtworkProvider` (default Plezy). No `MediaServerClient` interface
  change (~70 test fakes implement it).
- Image call sites threaded: `OptimizedMediaImage`, library browse precache,
  program details poster, media detail poster, cycling backdrop. Profile
  avatar keeps the default.
- No native change: `Media.headers` already becomes mpv `http-header-fields`
  and ExoPlayer headers for both players.

## Version

1.0.5-2.25.0+177. Changelog `about.changelog2269` (2268 reserved for build
#21's number to avoid a key collision at rebase — this branch rebases onto
#21's tip after #21 ships). About entry added at the top of the list.

## Tests

- NEW `test/services/iptv/iptv_build22_stream_user_agent_test.dart` (13):
  client streamHeaders (default/choice/custom/blank/unknown/M3U), live
  session headers + setting re-read, resolver carries the UA into
  PlaybackContext, artworkHeadersFor + provider default/override, mini-player
  widget tests (live tune, catch-up timeshift tune, setting change applies
  to the next tune) with a Media-capturing fake player.
- Failing-first on base 652db5f90 (separate worktree
  `~/workspace/tmp_work/plezy-tv-build22-base`): 9/9 runnable tests fail
  (headers are `{'Accept-Language': 'en'}` only / `streamHeaders` is `{}`),
  new-API groups fail to compile.
- `live_stream_retry_test.dart` harness updated for the new `open`
  signature + asserts open receives the recovered session. Three
  `LiveTvPlaybackSession` test fakes gained the default getter.
- Analyze on the 14 changed lib files: clean.

## UNPROVEN (phone-only)

Whether the panel accepts VLC on streams. Live TV and a VOD movie must play
on Matt's phone. If a stream 403s, try IPTVSmartersPro / browser UA in
Settings → IPTV → Xtream User-Agent. Plex playback is untouched by this
build (different server, different UA rules).
