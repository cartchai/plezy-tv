# Plezy TV — IPTV Stage 3 notes (2026-11-05)

Final wiring + Add-connection UI for M3U + Xtream Codes. NOT committed,
NOT pushed. Parent to review, then commit/push, Codemagic build, and bug
testing against the real provider.

## Files created

- `lib/screens/settings/add_m3u_screen.dart` — `AddM3uScreen`: NAME
  (required, becomes the library title) + Playlist URL (required) +
  optional EPG URL. The Add button probes first (fetch playlist URL,
  `parseM3u`, require ≥1 entry) and only then persists an `M3uConnection`
  via the shared helper. Probe failures map to fixed strings
  (`m3uInvalidUrl` / `m3uPlaylistEmpty` / `m3uProbeFailed`); raw probe
  errors are never surfaced.
- `lib/screens/settings/add_xtream_screen.dart` — `AddXtreamScreen`: NAME
  (required) + Server URL + Username + Password (obscured, required).
  The Sign in button probes with `XtreamApi.getUserInfo()` (a `user_info`
  object means the login works; null means rejected) and only then
  persists an `XtreamConnection` via the shared helper. The password is
  never logged and never appears in any error message: Xtream errors can
  embed the request URI, which carries the credentials in the query
  string, so all failures map to fixed strings (`invalidCredentials` /
  `xtreamProbeFailed`).
- `lib/screens/settings/iptv_connection_persistence.dart` —
  `persistAndExitIptvConnection()`: shared persist path for both add
  screens, mirroring the Jellyfin `_persistAndExit` flow (optional
  first-run profile creation, profile-selection prompt when several
  profiles exist, `persistAndBindConnection`, rebind when bound to the
  active profile, pop(true)). IPTV carries no per-profile token, so the
  `ProfileConnection` gets `userToken: null` and `userIdentifier` = the
  Xtream username ('' for M3U). Returns false when it bails before
  persisting (no profile to bind to) so the caller can show
  `noProfilesAvailable` and keep the form visible.
- `lib/screens/settings/edit_iptv_connection_screen.dart` —
  `EditIptvConnectionScreen`: the country/region filter UI. Loads the
  connection's categories (Xtream: live+VOD+series categories merged by
  id; M3U: distinct playlist group titles, which is exactly what the
  client filters on) and shows a scrollable checklist of
  `FocusableSwitchListTile` rows (on = shown) rendered with a
  `SliverList.builder`, so 800+ categories never build all at once.
  Toggling OFF adds the id to `disabledCategoryIds`; Save persists via
  `registry.upsert(updated, expected: connection)` and pops true. The
  caller rebinds, so the new filter applies immediately. Loading /
  empty / load-error (with retry) states included; the load error is
  kept apart from the save error so it never renders twice.

## Files changed

- `lib/services/multi_server_manager.dart` — `addIptvConnection()`
  (creates `IptvClient.forConnection`, registers it in `_clients` under
  the connection id — which IS the client's serverId — runs a health
  probe, applies health, returns healthy bool; re-add always replaces
  the client because construction is cheap/stateless, unlike Jellyfin's
  endpoint race + reuse), `removeIptvConnection()`,
  `getIptvClientByConnectionId()`, plus `_iptvByConnectionId` /
  `_iptvHealthByConnectionId` maps wired into `removeServer` and
  `_detachAllClients` (shutdown). No Plex/Jellyfin/Emby path touched.
- `lib/profiles/active_profile_binder.dart` — the Stage 1 skip branch in
  `_bindJoinRows` now calls new `_bindIptv()` (mirrors
  `_bindMediaBrowser`: `addIptvConnection`, visibility keeps the server
  when the probe refused so the refusal banner can surface). The
  membership switch already added the connection id in Stage 1.
- `lib/screens/settings/add_connection_screen.dart` — "M3U" and
  "Xtream Codes" `_BackendOption` rows after Emby, before Borrow, using
  the Stage 1 badge SVGs.
- `lib/screens/profile/profile_detail_screen.dart` — `_editConnection`
  now routes M3U/Xtream connections to `EditIptvConnectionScreen`
  (Jellyfin unchanged); after any edit it still rebinds the profile.
- `lib/i18n/en.i18n.json` — 17 new `addServer` keys (card titles /
  subtitles, add-screen titles, library name, playlist/EPG/server URL,
  probe-failure strings) + 5 new `connections` keys (filter title /
  intro / empty / loading / load-failed). Regenerated with
  `dart run slang` (`strings.g.dart`, `strings_en.g.dart` updated;
  other locales fall back to English for the new keys).
- `test/screens/settings/add_connection_screen_test.dart` — the badge
  test now expects all five backends; the D-pad test now steps through
  five cards; added M3U/Xtream card-opens-screen tests.

## Verification

- `flutter analyze --no-pub`: 0 errors, 0 warnings outside the
  pre-existing `packages/wakelock_plus/` noise (49 issues, all there).
- Tests, all passing: add_connection_screen 8/8, connection_persistence
  (in the 148-run below), multi_server_manager 63/63,
  multi_server_manager_progress, active_profile_binder 40/40,
  connection_models 19/19, iptv_stage2 9/9 — **148/148 across the 7
  affected suites**. (One failure was found and fixed during the run:
  the D-pad test asserted exactly 3 cards; updated for 5.)
- No network was contacted; no credentials exist in the repo.

## Where the country/region filter lives

Profile detail → Edit connection (the pencil/edit affordance on an IPTV
connection) → `EditIptvConnectionScreen`. It is NOT on the add screens:
the filter is an edit-time concern (categories are only known after a
successful probe), and the Jellyfin-style edit flow already rebinds on
save, so the filter applies immediately. The client already honored
`disabledCategoryIds` in Stage 2b (libraries, paged content, channels).

## What remains

- EPG: `IptvLiveTvSupport.fetchSchedule` still returns `[]` (TODO in
  Stage 2b) — wire get_short_epg (visible channels) / xmltv.php.
- Local watch-state / item-level favorite persistence (item
  `setFavorite` is a silent no-op; only live-channel favorites persist).
- Bug testing against Matt's real provider in small batches, never 2
  streams at once; then Codemagic build + APK delivery.
- Follow-ups from earlier stages (unchanged): `plezytv://` deep-link
  scheme, pruning the 24 alternate icons, wood TV banner.
