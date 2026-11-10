# PlezTV build #24 — dead-channel fast-fail + zap optimisation + transient stream retry (v1.0.7-2.25.0+179)

Audit findings #2 and #6 (full audit `~/workspace/tmp_work/plezy-tv-research-full-audit/RESEARCH_FULL_AUDIT.md` §§2, 6, 10).
Research: `~/workspace/tmp_work/plezy-tv-research-xtream-loading/RESEARCH_XTREAM_LOADING_AND_IPTV_APPS.md`
(OpenTV: single ExoPlayer instance + 350ms debounce on channel switching; IPTV-tuned retries
403/429/503 backoff, never 401/404/410).

## What was built

### 1. Dead/slow channel fast-fail — live open deadline 30 s → 10 s, VOD stays 30 s

NEW `lib/screens/video_player/playback_open_deadline.dart`:

- `liveOpenDeadline = 10 s`, `vodOpenDeadline = 30 s`, `openDeadlineFor({required bool isLive})`.
- The launch path (`_beginPlaybackAttempt`) and the zap path (`_switchLiveChannel`) both arm
  with `openDeadlineFor(isLive: widget.isLive)`. `_openDeadline` (the old static const in
  `VideoPlayerScreenState`) is removed; `_onOpenDeadlineExpired` logs the actual deadline used.
- 10 s is long enough for a slow HLS playlist fetch + demux, short enough that a dead channel
  surfaces promptly. It matches the app's existing patience for live: the mini-player's 5 s
  watchdog only reveals the surface, it does not fail the tune — unchanged.
- The 503 watchdog (20 s, VOD only, `open_http_503_watchdog.dart`) is unchanged; it never arms
  for live opens, so it needed no change.

Deadline-expiry semantics (established during implementation): `_onOpenDeadlineExpired`
synthesizes `PlayerError(cause: PlayerError.openTimedOut)` → `_onPlayerError` → policy. For live,
`openTimedOut` has no fatal status latched → the policy's live branch: `liveRetry` (ladder) up
to level 2, then `liveInterrupted` (snackbar + back) if the last retry failed. So a dead live
channel: 10 s deadline → ladder retry (level 1, backoff 1 s) → another 10 s deadline → ladder
retry (level 2, backoff 2 s) → another 10 s → `liveInterrupted`.

- **Time to FIRST visible failure signal: 30 s → 10 s.**
- **Time to terminal (after ladder exhausts): ≈93 s → ≈33 s worst case.**
- The ladder retries are the existing design for transient blips; this build's scope is the
  deadline, not the ladder. Report the numbers honestly.

### 2. Zap optimisation — pre-tune the next/previous channel while the current one plays

NEW `lib/screens/video_player/live_channel_pretune.dart`:

- `LiveChannelPretuner` (injected `startSession` / `resolveUrl` / `discardSession` /
  `probePlaylist` / `shouldProbe`, 60 s TTL, `now` seam for tests). `PretunedChannel`
  (channelKey, session, streamUrl, readyAt, probeStatus; `isDead` = probe status in
  `fatalPlaybackHttpStatuses`).
- While the current channel plays, it pre-tunes index±1 only (prev/next neighbours in the
  guide order). `refresh()` drops entries no longer wanted or expired; a tune completing
  after the viewer moved on is discarded (checked against `_wantedKeys`, not the start
  index — a neighbour of both old and new index stays valid). `take(key)` consumes (removes;
  expired → discard + null). `dispose()` discards held sessions; in-flight completions
  discard instead of storing.
- The probe is IPTV-only by design (`shouldProbe: session is IptvLiveTvPlaybackSession`):
  `probeIptvPlaylist(url, headers)` GETs the manifest with a 5 s timeout and returns the
  status, or null on failure (inconclusive, never a verdict). A probed-dead channel (probe
  status in `fatalPlaybackHttpStatuses`, i.e. 403/404) makes the zap stay on the current
  channel with the existing `failedToStartChannel` snackbar (same as the `session == null`
  path). Plex/Jellyfin are NEVER probed — GETting a Plex transcode URL would pull transcode
  output, a second stream on a max_connections=1 line.
- Pre-tune = fetch the playlist + hold the session ready, NOT a second stream. Matt's line
  allows exactly 1 simultaneous stream; nothing here opens a second one.
- Full player only: the mini-player is untouched (generation-gating unchanged, 5 s watchdog
  unchanged).
- Hooks (`lib/screens/video_player/parts/live_tv.dart`): `_refreshLivePretune()` (lazy
  pretuner creation); `_switchLiveChannel` consumes the pre-tuned entry first (skipping
  `_startLiveSession` / `streamUrlAt`), `_refreshLivePretune()` after the commit setState
  that updates `_live.channelIndex`; zap outcome deadline is
  `openDeadlineFor(isLive: true)`. The launch path (`parts/playback_start.dart`) calls it
  after `committed = attempt.isCurrent` (a failed launch pre-tunes nothing). The pretuner
  is disposed in both `dispose()` and `_shutdownVideo()`.
- No debounce was added: the zap path already force-idles a superseded recovery and a zap
  supersedes a recovery, so rapid zaps do not pile up. OpenTV's 350ms debounce shape was
  considered and left out — the existing generation-gating already bounds the work.
- Real bug caught by the new probe-throw test: the first `_pretune` implementation let a
  throwing probe kill the whole entry (catch discarded the session). Fixed: the probe call
  is wrapped in its own try/catch inside `_pretune` (inconclusive → `probeStatus: null`,
  entry stored).

### 3. Retry transient stream failures with backoff before latching fatal

- NEW `transientPlaybackHttpStatuses = {429}` in `lib/mpv/models.dart` (rate limit is
  transient, never fatal; 403 stays in the fatal set). 429 was previously latched nowhere.
- `_onPlayerLog` (`parts/errors.dart`) latches 429 into a new `_transientHttpStatuses` set
  (mirroring `_fatalHttpStatuses`); a persistent 403 still ends in the access-denied dialog.
- `resolvePlaybackFailureAction` (`lib/screens/video_player/playback_failure_action.dart`)
  gains a new action `retryTransient`, optional params `transientHttpStatuses` +
  `transientRetryAttempts`, and consts `maxTransientPlaybackRetries = 1`,
  `transientRetryBackoff = 1 s`, `liveRetryBackoff(level)` (level 1 → 1 s, level 2 → 2 s,
  capped). Retry branch (after the audio check, before the 403 dialog): VOD with attempts
  remaining and (429 in the transient set OR 403 in the fatal set) → `retryTransient`;
  attempts exhausted → the existing terminal path (403 → `playbackNotAllowedDialog`,
  429 → `fatal`, no dialog of its own). 500 alone never retries; 404 never retries. Live
  keeps the ladder (no transient branch pre-empts it).
- Live ladder backoff: `_beginLiveLadderRetry` now waits `liveRetryBackoff(level)` via
  `unawaited(_retryLiveStreamAfterBackoff())`, re-checking
  `mounted && !_shuttingDown && _live.retrying` after the wait. Play-pressed retries via
  `_retryLiveStreamForPlayIntent` stay immediate.
- `_onPlayerError` passes the transient set/attempts to the policy; `retryTransient`
  increments `_transientRetryAttempts` and calls `_retryTransientPlayback()` (waits the 1 s
  backoff, guards `mounted && !_shuttingDown && !_hasFatalPlaybackError`,
  `_transientRetryAttempts == 0` — a playback restart reset the budget, i.e. the stream
  recovered on its own — and `identical(_playbackAttempt, attempt) && attempt.isCurrent`,
  then `_retryFailedPlayback()`).
- The transient set + attempts are reset wherever `_hasFatalPlaybackError` is reset
  (playback restart listener in `playback_services.dart`, `_startPlayback` in
  `playback_start.dart`, reload path in `playback_reload.dart`).
- 503 needs no new branch (VOD: the ffmpeg reconnect loop already retries inside the 20 s
  watchdog patience; live: rides the ladder) — documented in the policy file.
- The tension, handled honestly: PlezTV cannot tell a UA-block 403 from a transient 403,
  so a VOD 403 gets exactly ONE automatic retry with a 1 s backoff, then the access-denied
  dialog. A persistent 403 still surfaces as access-denied, never "offline".
- Catch-up 404/458 semantics are UNCHANGED (404 = missing-recording message naming
  programme/channel + Watch live; 458 = transient/line-busy, never missing-recording).

## Failing-first evidence (all on base 2643073f9)

- `test/screens/video_player/playback_open_deadline_test.dart` (4 tests): failed to load on
  base (no `playback_open_deadline.dart`); passes on fix. Live 10 s, VOD 30 s; fakeAsync
  outcome armed with the live deadline fires at 10 s (not at 9 s), VOD at 30 s. Reuses the
  `_StreamPlayer` harness shape from `test/services/playback_open_outcome_test.dart`.
- `test/screens/video_player/live_channel_pretune_test.dart` (9 tests): failed to load on
  base; 9/9 pass on fix. Neighbours-only pre-tune; take consumes; tune completing after
  the viewer moved on is discarded; TTL expiry discards on take; probe 403 → `isDead`,
  probe 200 → alive, probe throws → probeStatus null, entry still usable; probe 404 →
  dead, probe 429 → not dead; dispose discards held sessions; pre-tuned take is
  synchronous (0 ms vs 250 ms cold session-start in the fake); failed pre-tune never
  blocks the zap.
- `test/screens/video_player/playback_failure_action_transient_test.dart` (9 tests): failed
  to load on base (no `retryTransient`/backoff APIs); 9/9 pass on fix. 429 transient never
  fatal; VOD 429 → retryTransient; VOD 403 → retryTransient then dialog with budget spent;
  403 outranks co-latched 404/500 for the retry; 429 budget spent → fatal; 500/404 alone
  never retry; live keeps the ladder; backoff 1 s, budget 1, ladder backoff 1 s/2 s (capped).
- `test/screens/video_player/live_zap_pretune_test.dart` (1 widget test): failed on base
  with the exact product reason (`Expected: contains 'ch-2', Actual: ['ch-1']` — the launch
  did not pre-tune); passes on fix. Harness modelled on `live_media_session_test.dart`
  (`_LiveShell`, mock player channels with `initialize: false`): asserts that after launch
  + settle, `startedChannels` contains ch-2, and after the zap ch-2 was started exactly
  once (consumed, not re-started) and the player opened ch-2's pre-resolved URL.
- New tests on fix: 23 new (4 + 9 + 9 + 1) + the 18 updated policy tests + 11 media-session
  tests = **52/52** when run together after the version/docs edits.

## Existing test updates (deliberate behaviour changes, timing only otherwise)

- `test/screens/video_player/playback_failure_action_test.dart`: local `resolve()` helper
  gained `transientStatuses`/`transientAttempts` params; new `resolveTerminal()` helper
  passes `transientAttempts: maxTransientPlaybackRetries`; the two 403 tests now use
  `resolveTerminal` (403-terminal assertions must pass the budget as spent, since with
  attempts remaining a 403 takes the one bounded retry first). 500/404/503/audio/ladder
  tests unchanged (503/404 not retried).
- `test/screens/video_player/live_media_session_test.dart`: the ladder test now pumps 2 s
  before asserting `recoveries == 1` (the ladder waits the 1 s backoff) and gains the
  zap-test harness fixes — WatchTogetherProvider in the shared shell,
  `initializeDateFormatting('en')` in setUp, `playerType`/`updateFrame`/`setBoxFitMode`/
  `setVideoZoom` on `_FailingOpenLivePlayer` only, `debugMarkPlaybackStartedForTesting()`
  after setting the player in the ladder test (the pump builds Video, which crashes on a
  null `_volumeController` without it — diagnosed via the stack; the null at
  `build.dart:287` is `_volumeController`, NOT `player`).

## Measured (in-harness, fake panel/player)

- Dead live channel: first visible signal 30 s → 10 s; terminal after ladder exhausts
  ≈93 s → ≈33 s worst case.
- Pre-tuned zap skips the 250 ms fake session-start (0 ms take) — the real saving on a
  phone is the playlist fetch + demux the pre-tune already did.
- Transient retry: VOD 403 → 1 automatic retry after 1 s, then the access-denied dialog;
  VOD 429 → 1 retry after 1 s, then fatal; live ladder backoff 1 s then 2 s between retries.
- A tap→first-frame zap-time bench in the widget harness was NOT measured honestly (the
  mock player renders no real first frame), so no zap-time number is claimed — UNPROVEN.

## Suite numbers

- `test/screens/video_player/`: **300/300 pass**
- `test/screens/livetv/`: **102/102 pass**
- `test/services/iptv/`: **296/296 pass** (second run; first run 295/296 — the known
  pre-existing EPG Clear-guide flake fired once, `iptv_epg_cache_test.dart` "Clear guide
  deletes the persisted files and stays empty until refresh", which passes alone 21/21.
  #23 documented it as a timing flake (fire-and-forget feed write racing a 1s poll); #24
  touches no EPG code.)
- `test/mpv/`: **193/193 pass**
- Repo-wide analyze: **49 = baseline** (all vendored wakelock_plus, zero in `lib/`, zero
  in `test/`)
- #24 test files together (6 files): **52/52 pass**

## Version / docs

- pubspec 1.0.7-2.25.0+179. Changelog `about.changelog2271` (at TOP of the About list).
  `dart run slang` regen: header 51216 → 51219, only the 2271 getter + flat-map entries
  plus the known three pre-existing switch-block re-chunks (same as #22/#23).
- FORK_MAINTENANCE.md §23. This file.

## Deliberately left out / UNPROVEN

- Tap→first-frame zap time on a real phone (no honest bench in the widget harness; the
  mock player renders no real first frame). The pre-tune unit test measures the
  session-start skip (250 ms fake); the deadline test pins 10 s vs 30 s; the policy test
  pins 1 retry + 1 s backoff + ladder 1 s/2 s.
- The probed-dead fail-fast branch is covered at the pretuner unit level (`isDead`), not
  at the widget level (an IPTV session fake is too heavy to stand up in the widget harness).
- No 350ms zap debounce was added (existing generation-gating bounds the work; a zap
  supersedes a recovery).
- The 503 watchdog (20 s, VOD only) is unchanged. The mini-player is untouched (pre-tune
  is full-player only; its 5 s watchdog unchanged).
- Cold-start browse/search before the first sync (not #24's scope).
- Phone behaviour is UNPROVEN until Matt's phone decides — do not claim the phone
  behaviour is fixed.
