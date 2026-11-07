# PlezTV Build #12 — Live TV mini-player (portrait) + library header overflow (v2.25.8)

**Version:** 2.25.8+165. **Status:** code + tests done, committed locally on
`main`, NOT pushed, no Codemagic build started (parent handles that).

**The ask (Matt, 2026-11-06 ~22:24 EST, screenshot of the Plex app):**
video player on top, TV guide below, both visible at once — "in phone
landscape mode". **Correction (Matt, 2026-11-07 ~00:24 EST): the mini-player
is PORTRAIT, exactly like the Plex screenshot — "landscape" was a
misstatement.** Rotating to landscape behaves as it does today (fullscreen
video as normal). Do NOT build a landscape mini-player.

**Second ask (same build, Matt's screenshot `9602_9_f0b1.jpg`):** the
library page header ("trex — Movies" + edit / heart / filter / refresh)
overflows by 5 pixels on the Fold 7 cover screen, producing the yellow/black
"OVERFLOWED BY 5 PIXELS" debug banner. Fix the layout, don't just hide the
banner.

## Task 1 — Live TV mini-player (portrait phones only)

Phone held upright: a 16:9 video player sits at the top of the guide, the
guide below it, both visible at the same time — the Plex reference layout.
Portrait layout is otherwise unchanged; TV/tablet/desktop layouts are
untouched, and TV D-pad navigation is untouched.

- **One player only** (provider allows one stream at a time):
  `LiveTvMiniPlayerController` owns a single `Player` for its lifetime.
  Tapping another guide channel re-opens the same instance; scrolling the
  guide never tunes at all.
- **Tap a guide channel** → the mini-player switches to that channel
  (same tap-to-tune as today, except the player stays in the mini-player
  slot instead of taking over the screen). Programme detail sheet's
  Play / Watch Channel button does the same.
- **Rotate to landscape** → the stream is released (player disposed) and
  the slot disappears. Landscape behaves as today: tapping a channel
  opens the full player, fullscreen video as normal.
- **Fullscreen** is reachable from the mini-player (fullscreen button):
  the mini-player stops, the full player opens for the same channel, and
  on return the slot stays as a stopped card for that channel — one tap
  resumes it instead of the mini-player vanishing.
- **Close (X)** stops playback and hides the slot entirely.
- **Catch-up keeps working:** "Start from beginning" / "Watch from start"
  in the programme detail sheet route into the mini-player and open the
  archive at the programme's start (Xtream `/timeshift/`), same offset
  math as the full player.
- **Block scrubber keeps working:** the mini-player applies the same
  `force-seekable=no` option the full player applies before every live
  open (v2.25.5), so live can't be scrubbed from the mini-player either.
- **Controls stay reachable:** play/pause, mute/unmute, fullscreen,
  close, plus channel name + now-playing programme title from the guide's
  EPG. Failed tunes show a retry card; the old stream is released so a
  stale picture never plays behind the error.
- **Session hygiene:** the controller resolves the server and starts the
  session exactly like the full player (`liveTvServerInfoForChannel` +
  `startPlayback` + `streamUrlAt`), registers its shutdown with
  `PlaybackCoordinator` (app background / agent stop can stop it), and
  abandons superseded tunes by generation so a slow session can never
  overwrite the channel the user actually picked.

### Design

- **New file `lib/screens/livetv/live_tv_mini_player.dart`** —
  `LiveTvMiniPlayerController` (a `ChangeNotifier`: `tune` / `retry` /
  `togglePlayPause` / `toggleMute` / `stop` / `stopForFullscreen`) +
  `LiveTvMiniPlayer` (stateless, rebuilds on the controller via
  `ListenableBuilder`; `videoBuilder` seam defaults to the real `Video`
  widget). Statuses: `idle` (slot hidden) / `tuning` / `active` /
  `failed` (retry card) / `stopped` (resume card).
- **`lib/screens/livetv/tabs/guide_tab.dart`** — owns the controller;
  inserts the slot at the top of `_buildGuideGrid` when
  `_miniPlayerEnabled` (phone + portrait) and status != idle; routes
  channel-cell taps, D-pad select on the channel column, programme
  detail sheet tune, and catch-up through `_tuneFromGuide` (mini-player
  when enabled, full player otherwise — catch-up keeps its archive start
  on both paths); `didChangeDependencies` stops the player on leaving
  portrait. The guide only rebuilds when the slot appears/disappears
  (selective listener); the slot's own `ListenableBuilder` handles its
  internal state.
- **`lib/screens/livetv/live_tv_actions_mixin.dart`** — `showProgramDetails`
  gains an optional `onTuneChannel` override (default is the old
  behaviour); the guide passes its mini-player tune. What's On and the
  show schedule screen keep the default.
- **Test seams (`@visibleForTesting` on `GuideTab`):**
  `debugPlayerFactory`, `debugVideoBuilder`, `debugFullscreenHandler` —
  widget tests never construct a native `Player`, never render the real
  `Video` surface, and never open the real full player.
- **What the mini-player does NOT do:** it is guide-only. Switching to
  the What's On tab disposes the guide tab and stops playback. The
  What's On tab has no mini-player.

### Tests

- `test/screens/livetv/live_tv_mini_player_test.dart` (8 widget tests,
  portrait 390x844, fake `Player` + real `IptvClient` + controllable
  fake Xtream API): no mini-player before any tap; tap shows it above
  the guide on one player (live URL, `force-seekable=no`); second tap
  retunes the same player; scrolling the grid does not re-tune; rotate
  to landscape stops playback and hides it; fullscreen stops it, hands
  the channel to fullscreen, and leaves a stopped resume card; close
  hides it; catch-up from the guide opens a `timeshift` URL in the
  mini-player.
- `test/screens/livetv/live_tv_mini_player_controller_test.dart` (6 unit
  tests): tune opens the live URL; retune re-opens the same player;
  catch-up tune opens the archive URL; tune with no live server fails
  and retry stays failed for the same channel; stop releases the player;
  mute toggles 0/100.
- **Gotcha found while testing:** `await`ing a broadcast-stream
  subscription's `cancel()` stalls inside `testWidgets`' fake async
  zone (the cancel future only resolves on the real event queue), so
  `_disposePlayer` fire-and-forgets the cancels with `unawaited` —
  event delivery stops at the `cancel()` call itself, so awaiting buys
  nothing. This also fixed the close/fullscreen/rotate tests, which all
  failed on the same stall.
- **Gotcha:** `debugDefaultTargetPlatformOverride` set in `setUp` fails
  the test even when reset in `tearDown`/`addTearDown` — the binding
  verifies foundation debug variables inside the test body, before any
  tearDown runs. The platform now comes from the pumped theme
  (`monoTheme(...).copyWith(platform: TargetPlatform.android)`), which
  is what `PlatformDetector.isMobile` reads.

## Task 2 — Library header overflow

`_buildLibraryDropdownTitle` in `lib/screens/libraries/libraries_screen.dart`:
the title (either branch — the multi-server `Column` with the server label,
or the plain `Text`) is now wrapped in `Flexible` with `maxLines: 1` +
`TextOverflow.ellipsis`. The library icon and dropdown arrow stay fixed;
only the title shrinks. The overflow banner only renders in debug builds,
but the layout bug was real — the fix is in the layout, not a banner
suppression.

- `test/screens/libraries/library_header_overflow_test.dart`: pumps
  `LibrariesScreen` at 360dp wide with the trex movies library
  ("trex — Movies", server "trex") + a second-server library, Browse tab
  active (all four actions visible: edit / heart / filter / refresh).
  **Failed before the fix** with `A RenderFlex overflowed by 98 pixels
  on the right`; passes after.

## Version + changelog

- `pubspec.yaml`: 2.25.8+165.
- `changelog2258` in `lib/i18n/en.i18n.json` + first `_ChangelogEntry`
  in `lib/screens/settings/about_screen.dart`; slang regenerated
  (`t.about.changelog2258` exists).

## What to verify on the phone (unproven until then)

- Portrait guide: tap a channel — video plays on top, guide below, both
  visible; scroll the guide — the stream keeps playing, no restart.
- Tap another channel — the mini-player switches, no second stream.
- Rotate to landscape — mini-player gone; tap a channel — full player
  as today.
- Fullscreen button in the mini-player — full video; back — stopped
  card for the same channel; tap its play button — resumes.
- Catch-up: open a past programme's detail, "Start from beginning" —
  plays from the programme start inside the mini-player.
- Cover screen library page: "trex — Movies" header fits, all four
  action icons reachable, no overflow banner.
- In-app update from v2.25.7 → v2.25.8 still unproven on phone/TV (the
  download + install prompt from build #10).
- Series search on the real 46k catalog, category-initials list at real
  833-category scale, and the Movies Browse spinner on second launch
  (build #11 cache) are still unproven from earlier builds — this build
  does not touch them.
