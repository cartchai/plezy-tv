# PlezTV build #28 — block fixes (v1.0.9-2.25.0+181)

Base: main tip `6fe84db64` (v1.0.8-2.25.0+180, the refusal recorder).
Research: `~/workspace/tmp_work/plezy-tv-research-block-after-use/RESEARCH_BLOCK_AFTER_USE.md`
(ranked mechanisms from open-source peers + boards; no panel calls, no credentials).

## Why

Trex blocks PlezTV shortly after use on a max_connections=1 line. The ranked
mechanisms:

1. **Zap overlap** — PlezTV kept the old stream alive until the new one opened,
   plus #24's 2 pre-tune GETs per zap. OwnTV measured this exact failure on a
   real one-connection panel ("thirteen streams in 3.6 s… locked the account
   for about two minutes, HTTP 458") and fixed it with a 500 ms debounce +
   wait-for-release.
2. **Retrying a refusal reads as an attack** — live 403s climbed a retry ladder
   that refills on playback restart; refused `player_api.php` calls count
   toward the flood limit.
3. **Ghost slot** — `discard()` is a no-op and nothing tells the panel a stream
   ended, so the slot lingers ~30 s–5 min.
4. **Background EPG/catalog work runs while streaming** (OwnTV's workers wait
   until nothing is playing).
5. **Health probe on resume + reconnect sweep re-probe a refused panel.**

Matt decided (2026-11-10 ~07:55 EST): build the fixes right after 1.0.8 ships,
don't wait for the recorder log.

## What changed

### 1. Wait-for-release on zap + zap debounce (OwnTV's shape)

- NEW `lib/screens/video_player/live_stream_release_gate.dart` —
  `LiveStreamReleaseGate` (cap 1,500 ms): `release(stop)` awaits any in-flight
  release, runs stop(), awaits it with the cap, swallows errors/timeout;
  `waitForRelease()` awaits an in-flight release (capped). Per player instance.
- The zap path (`_switchLiveChannelNow`) awaits the gate before
  `_openLiveStream` when the previous session requires it; `_openLiveStream`
  also awaits `waitForRelease()` at its top so no open can start while a
  release is in flight; the mini-player's `tune()` does the same before
  `player.open`.
- NEW `lib/screens/video_player/live_zap_debouncer.dart` — `LiveZapDebouncer`
  (delay 500 ms; injected clock + timer factory; `onExecute` + `onDrop`):
  isolated press executes at once (0 ms); rapid presses accumulate the net
  delta and restart the timer; a net-zero burst executes NOTHING and fires
  `onDrop` so callers awaiting the switch are released. Wired inside
  `_switchLiveChannel` (returns a Future via pending completers; real logic
  moved to `_switchLiveChannelNow`).

### 2. Single-connection plumbing

- `IptvClient` caches `max_connections` from `getUserInfo()` in `checkHealth()`;
  new `int? maxConnections` + `bool isSingleConnection` — **default unknown →
  wait** (true unless the panel told us it allows more than one; the wait is
  bounded by the stop completing, usually tens of ms). Applies to Xtream AND
  M3U (M3U never knows → waits).
- NEW getter on the abstract session: `bool get requiresReleaseBeforeOpen =>
  false` (default — Plex/Jellyfin don't need it); `IptvLiveTvPlaybackSession`
  overrides it to `client.isSingleConnection`. The zap gate checks the PREVIOUS
  session (its panel holds the slot); the pre-tune probe gate checks the
  NEIGHBOUR session's own panel.
- Pre-tune probe gate: `shouldProbe` is now `session is
  IptvLiveTvPlaybackSession && !session.requiresReleaseBeforeOpen` — the
  neighbour is still pre-tuned (session + URL, both local) but never probed on
  a single-connection line; the 10 s open deadline still bounds a dead channel.
- Ghost slot: verified `discard()` is a no-op because the IPTV session owns no
  releasable resource (no panel logout/disconnect endpoint exists — no peer
  sends one); the fix IS the awaited player stop (release gate) in the
  zap/retune paths + the choke-point guard. `discard()` stays a no-op with an
  updated comment.

### 3. Never retry a 403

- In `resolvePlaybackFailureAction`, a latched 403 returns
  `playbackNotAllowedDialog` FIRST (before the transient branch and before the
  live ladder) for both live and VOD; the VOD `retryTransient` condition keeps
  only 429. NEW helper `shouldRefillLiveLadderAfterRestart(Set<int>) =>
  !fatalHttpStatuses.contains(403)`; the `playbackRestart` listener captures
  `hadRefusal` BEFORE clearing the latched sets and skips the ladder reset
  when a refusal was latched.
- **458 stays ladder-eligible on live TV** (documented): it is the transient
  line-busy signal ("458 is TRANSIENT" — Matt's rule), and the ladder's 1 s/2 s
  backoff gives the ghost slot time to expire, so a retry after the wait can
  succeed where a 403 retry never could.

### 4. Playback-activity signal + background-work gating

- NEW `lib/services/iptv/iptv_playback_activity.dart` — `IptvPlaybackActivity`
  (singleton, `ValueNotifier<bool> isPlayingNotifier`, `markPlaying()` /
  `markIdle()`, `waitForIdle()`). Set by: full player at first frame →
  playing, dispose/fatal → idle; mini-player tune active → playing,
  stop/stopForFullscreen/fail/dispose → idle. Paused still counts as playing
  (the slot is held server-side until expiry).
- Gate the STARTS on playback — weekly sync (pauses between types, resumes
  when idle; the wait happens BEFORE acquiring the index-write lock; forced /
  manual refresh skips the gate — user intent wins), catalog background refresh
  (defer until idle, not just skip — `_liveStreamsFuture` is cached and a
  skipped refresh won't re-fire; the fetch now takes `Future<void>?
  abortTrigger`), xmltv feed (don't START a new feed download while playing;
  short-EPG only; a cached/in-flight feed is free to await). Per-channel
  short-EPG is NOT gated on playback (small, bounded, and it is what the
  visible guide needs while the mini-player plays).
- **Cancel on background:** new `IptvClient.cancelBackgroundWork()` (aborts
  sync + catalog refresh controllers + EPG), `MultiServerManager.
  cancelActiveIptvBackgroundWork()`, wired in `main.dart` paused/detached next
  to `cancelActiveIptvSearches()`.
- **Scroll-away cancel:** abort threaded through `fetchEpgForChannel` →
  short-EPG/xmltv; the support tracks in-flight per-channel fetches and
  exposes per-channel + all cancel; the guide tab wraps each row in
  `_IptvEpgRowLifecycle` (stable `ValueKey(scopeKey)`, dispose cancels that
  channel's fetch) and its `_ensureIptvEpg` catchError distinguishes
  cancellation (NOT marked failed — scrolling back refetches) from a real
  failure (still marked failed).

### 5. Health-probe backoff

- In `IptvClient.checkHealth()` (the one choke point): if the refusal log has
  a recent 403 for this connection (within **5 min**, test-overridable
  `refusalProbeBackoff`), return `_lastHealthStatus` (accessDenied) WITHOUT a
  panel call. After the window, probe normally. Unconditional (all callers,
  including the manual reconnect sweep); a fresh sign-in bypasses it. Only 403
  backs off. A log that cannot be loaded fails open (probe runs).

### EPG abort plumbing

- `XtreamApi.getShortEpg` + `getXmltv` gained optional `abortTrigger`;
  `_getText` now uses `AbortableRequest` so the feed aborts at the socket;
  `_fetchXtreamShortEpg` passes the trigger (its concurrency slot releases in
  a `finally`); `_fetchXtreamEpg` split into a wrapper (owns the per-channel
  `AbortController`) + `_fetchXtreamEpgWithAbort` (rethrows cancellations
  instead of falling through to the feed, `throwIfAborted()`s before awaiting
  the feed); `_loadXmltvGuide` does NOT set the negative-cache marker on a
  cancellation; the M3U feed races its bare `http.get` against the trigger
  (best-effort — documented). The feed-deferral warning is suppressed while
  playing.

## Ripple fixes (required by the API changes)

- Adding the optional `abortTrigger` param to `getShortEpg`/`getXmltv` broke 15
  existing fake-API overrides (`invalid_override` — Dart does not allow an
  override to omit an optional named parameter of the base). Fixed by adding
  the parameter to the overrides (fakes answer immediately, so they ignore it).
- Adding `requiresReleaseBeforeOpen` to `LiveTvPlaybackSession` broke every
  `implements` class — explicit `=> false` added to `_PlexLiveTvPlaybackSession`,
  `_JellyfinLiveTvPlaybackSession`, and 5 test fakes.
- Analyze: 49 = baseline, identical issue list to base (verified by diffing the
  full analyze output, base worktree vs fix worktree). The 4 extra warnings
  that appeared mid-build (unnecessary `?.` in `_syncSearchIndex` after
  `abort ??= AbortController()`) were fixed by dropping the null-aware
  operators.

## Tests

New files (all failing-first on base 6fe84db64):

| File | Tests | Failing-first on base |
|---|---|---|
| `test/screens/video_player/live_stream_release_gate_test.dart` | 7 | fails to load (new API absent) |
| `test/screens/video_player/live_zap_debouncer_test.dart` | 7 | fails to load (new API absent) |
| `test/services/iptv/iptv_playback_activity_test.dart` | 6 | fails to load (new API absent) |
| `test/services/iptv/iptv_build28_block_fixes_test.dart` | 12 | fails to load (missing `maxConnections`, `isSingleConnection`, `requiresReleaseBeforeOpen`, `testRefusalLog`, `refusalProbeBackoff`, `cancelBackgroundWork`, `iptv_playback_activity.dart`) |
| `test/services/iptv/iptv_build28_epg_gate_test.dart` | 3 | fails to load (missing `iptv_playback_activity.dart`, `cancelEpgFetchForChannel`, `cancelBackgroundWork`) |
| `test/screens/video_player/live_zap_release_gate_test.dart` | 2 | product reason: base opens ch-2 with no stop at all (`openedUris` [ch-1, ch-2], no 'stop-started'); fix stops first, opens only after the release, order stop-started < stop-finished < open |
| `test/screens/livetv/live_tv_mini_player_release_gate_test.dart` | 1 | product reason: base retunes without stopping; fix waits |
| `test/screens/livetv/guide_tab_epg_cancel_test.dart` | 1 | product reason: base `aborted` is empty — the scrolled-away fetch is never aborted; fix aborts '100' only, '124' keeps its fetch, new fetches start for newly visible rows |

Updated (deliberate policy change, stricter assertions — no weakening):
`playback_failure_action_transient_test.dart` + `playback_failure_action_test.dart`
(403 → `playbackNotAllowedDialog` immediately, no retry; the live ladder is
still covered elsewhere: 404 → liveRetry, ladder exhaustion, in-flight retry
owns the error with 404). Failing-first: 3 tests fail on base with the exact
product reason (403 → `liveRetry`/`retryTransient` instead of the dialog).

Widget-test notes (hard-won):

- The zap test starts the tune in the fake zone (not runAsync) so pumps flush
  its microtasks — a second runAsync while the zap is pending is denied as
  reentrant, and fake-time pumps alone do not advance a real-zone tune. Drain
  the fake clock 15 s past the release gate's 1.5 s timeout and the zap's 10 s
  open deadline before disposing, or a pending-timer assertion fails the test.
- The guide test's fake API must RACE the abort trigger against its Completer
  (like the real API's AbortableRequest at the socket) — otherwise the support
  stays parked on the pending future, the concurrency slot never releases, and
  no queued fetch starts. Cleanup must guard `Completer.complete` with
  `isCompleted` (it throws on an already-completed future) and use bounded
  pumps, not `pumpAndSettle` (the 15 s first-paint timers keep firing).
- A re-pump with a different channel list is NOT a scroll-away test: the
  sliver matches rows by index, so it recreates the surviving row too and
  cancels its fetch as well (it then refetches via the catchError's setState).
  The real scroll test (30 channels, real drag) is the faithful proof.

## Suites (full runs on the fix)

- video_player: 318/318
- livetv: 104/104
- iptv (`--concurrency 2`): 340/340
- mpv: 193/193
- settings: 217 passed / 3 skipped / 1 failed — the failure is the PRE-EXISTING
  #20 UA widget test ("picking Custom reveals the custom text row"), proven
  failing on the base 6fe84db64 too (same file/line/error; #23 broke it, not #28).

One real #28-caused test failure found and fixed during the suite run:
`live_media_session_test.dart` "OS next/previous on live zap channels" — the
no-op Previous at ch-1 executes through the debouncer and consumes the
isolated-press slot, so the Next a few real milliseconds later falls inside
the 500 ms rapid-press window and is deferred; the test now pumps 600 ms past
the debounce window. That is the debounce working as designed (a no-op press
delays the next real press by at most 500 ms), not a regression.

## Deliberately NOT changed

- The #20 UA widget test issue (separate queue item — #23 broke it; test-only
  vs real reachability still to determine).
- The refusal recorder's log format.
- No new panel calls, probes, or retries anywhere (the only new panel-adjacent
  behaviour is FEWER calls: the backoff skips a probe, the gates defer work,
  the cancels stop work).
- User-Agent behaviour (#20/#22) unchanged.
- #21 abort wiring intact, #23 index/search untouched, #24 intact except the
  deliberate 403-retry removal (see §3 above).

## UNPROVEN (phone-only)

- Zapping waits for the old channel to release (no overlap) on a real
  one-connection line.
- A refused stream shows the access-denied dialog with no re-open.
- Background work doesn't run while watching.
- A refused panel isn't re-probed on every resume.
- Tap→first-frame zap time was NOT measured honestly (the mock player renders
  no real first frame — same caveat as #24).

## Version

1.0.9-2.25.0+181. Changelog `about.changelog2273`.
