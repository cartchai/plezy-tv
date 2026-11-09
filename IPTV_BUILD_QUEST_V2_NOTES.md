# PlezTV Quest fix v2 — build notes (unversioned; rebased onto build #19 before release)

Supersedes `IPTV_BUILD_QUEST_NOTES.md` (v1). Base: `f52cacfa3` (the v1
Quest commit). Version NOT bumped in this worktree — pubspec stays
`1.0.0-2.25.0+171`; the parent assigns the next versionCode at release.
This commit will be rebased onto the build #19 commit.

## Why v2 (Matt's correction, 2026-11-09 ~05:23 EST)

"I did NOT ask for the phone layout on Quest — I want to maneuver the
existing TV UI with the controller." The v1 Horizon OS TV veto was the
wrong direction. The TV interface stays; the work is making it drivable
with mouse + thumbstick.

## What v1 got wrong (revised research: `~/workspace/tmp_work/plezy-tv-research-quest-v2/RESEARCH_QUEST_V2.md`)

1. TV Discover DOES have a vertical `ListView.builder`
   (`lib/widgets/tv_browse_rail.dart:1411-1414`) — but
   `NeverScrollableScrollPhysics`, so movement is selection-driven via
   `_moveHub`/`_moveItem`, not scrolling. The v1 notes' "no vertical
   Scrollable" claim was wrong.
2. Hover ALREADY moves the selection on Discover (`MouseRegion` onEnter →
   `_setHoveredItem`) and click already opens things. The gap is narrow:
   no pointer path to change the active hub / scroll Discover vertically.

## Scope (Matt, 2026-11-09)

- **Guide is OUT of scope** (Matt ~04:38 EST: "Dont worry about the tv
  guide"). No guide scroll/menu work.
- **Guide data is NOT an app bug** (Matt ~04:39 EST): the "No program
  data" guide is his Plex server's guide data, which he hasn't fixed
  server-side. Do not chase guide data / EPG here.

## What changed in v2 (from f52cacfa3)

### 1. Veto removed — ONLY the veto

- `android/app/src/main/kotlin/com/matt/plezytv/PlezyActivity.kt`:
  `isTv` back to `(!isAutomotive && reasons.isNotEmpty())` — the
  `!isHorizonOs &&` removed. The
  `hasSystemFeature("horizonos.software.horizon_os")` check, the
  `"isHorizonOs"` map entry, and the `'horizon_os'` reason are KEPT
  (diagnostics + targeted pointer exceptions).
- `lib/utils/platform_detector.dart`: `detectAndroidTvFromSystemFeatures`
  `isTv` back to `!isAutomotive && reasons.isNotEmpty`; `_fromNativeMap`
  `isTv` back to `isTv && !isAutomotive`. Kept: the
  `_androidFeatureHorizonOs` const, `AndroidTvFeatureDetection.isHorizonOs`,
  `TvDetectionService.isHorizonOsSync()`, `PlatformDetector.isHorizonOs()`.
  A Quest IS a TV now (`isHorizonOs` true AND `isTv` true together).
- Tests: the veto cases are removed from
  `test/utils/platform_detector_test.dart` and the detection cases are
  re-scoped (Quest headset is a TV and is detected as Horizon OS; Horizon
  OS with a leanback flag is a TV; Horizon OS alone with a touchscreen has
  no TV signal).
- NEW test seam: `TvDetectionService.debugSetHorizonOsOverride` (mirrors
  `debugSetAppleTVOverride` / `debugSetAutomotiveOverride`; cleared by
  `debugReset`). Needed to test the player gate on the Linux test host,
  where `_detect` never runs the Android branch.
- Diagnostic-reason fix (found by the re-scoped test): `'horizon_os'`
  was added to `reasons` BEFORE the `isTv` verdict was computed, and
  `isTv` is `reasons.isNotEmpty` — so with the veto gone, Horizon OS
  alone (touchscreen present, no other TV signal) read as a TV on the
  strength of the diagnostic reason. Fixed in both Dart and Kotlin: the
  verdict is computed BEFORE `'horizon_os'` is added to `reasons`. On a
  real Quest it never mattered (no touchscreen, so `no_touchscreen` fires
  anyway), but a diagnostic reason must not vote.

### 2. Thumbstick bridge on the rail (the core new mechanism)

- NEW `lib/widgets/tv_rail_scroll_bridge.dart`: `TvRailScrollBridge`
  converts `PointerScrollEvent.scrollDelta` into selection moves.
  Accumulator shape copied from `AppleTvRemoteTouchService`
  (`lib/services/apple_tv_remote_touch_service.dart`): per-axis progress
  against thresholds derived from the focused item's geometry; a 60 ms
  repeat cooldown after each step, with re-anchoring (travel during the
  cooldown is discarded, not banked); axis hysteresis (the other axis
  needs 1.5x the progress to take over mid-gesture); one scroll event
  emits at most one step, the remainder is discarded (re-anchored), like
  the touch service.
- `lib/widgets/tv_browse_rail.dart`: the rail's root (the `Focus`) is
  wrapped in a `Listener` (`HitTestBehavior.translucent`,
  `onPointerSignal` only — it observes, never consumes). The bridge is
  constructed in `initState` with DIRECT callbacks to `_moveHub` /
  `_moveItem` — no `KeyEventSimulatorController` synthesis was needed;
  direct-call placement did not fight the rows' scrollables.
  `_railStepThresholds()` prices step travel by geometry: the focused
  card's width for an item step, the active section's height for a hub
  step, clamped 120–480 (fallbacks 240 / 320). `_moveHub`, `_moveItem`,
  `_setHoveredItem`, and `_selectHubItem` all call
  `discardPendingProgress()` so stale scroll travel cannot fire a step
  after an explicit move.
- Re-entrancy note: the bridge calls `_moveHub` / `_moveItem`, which call
  `discardPendingProgress()` — safe, because the bridge zeroes its own
  progress and sets `_lastStepAxis` / `_lastStepAt` AFTER the callback
  returns. Verified by the widget tests, not just by reading.
- Scoped to the rail ONLY — other screens keep direct scrolling. Rows
  were NOT made `NeverScrollable` (that would break trigger-drag).

### 3. Kept from v1 unchanged

- `lib/utils/app_scroll_behavior.dart` + `lib/main.dart` wiring (mouse in
  `dragDevices`, both `MaterialApp`s).
- ••• menu buttons (`lib/widgets/media_card.dart`,
  `lib/widgets/episode_card.dart`,
  `lib/screens/playlist/playlist_item_card.dart`,
  `lib/screens/libraries/folder_tree_item.dart` +
  `test/widgets/quest_card_menu_buttons_test.dart`).
- Manifest entries (`android/app/src/main/AndroidManifest.xml`):
  `resizeableActivity`, `<layout>`, `com.oculus` entries.

### 4. Player gate exception — with a correction, and a second fix the research missed

- `lib/widgets/video_controls/parts/playback_input.dart`:
  `_mobileTouchGesturesAllowed` becomes
  `(isMobile || isHorizonOs) && (!isTV() || isHorizonOs) && ...`.
  **DEVIATION from the research's formula**
  `isMobile && (!isTV() || isHorizonOs())`: that form is inert —
  `isMobile()` returns false on TV, so the whole conjunction is false on
  Quest. The corrected form is what ships.
- **SECOND FIX (found by the failing-first test):** the gate alone was
  NOT enough. `lib/widgets/video_controls/video_controls.dart:1206,1230-1235`
  — the root `Listener` attached `_handleTouchPointerDown/Move/Up/Cancel`
  only when `isMobile`, so on TV the handlers were never called at all
  and no edge gesture could start. New local
  `touchPointerHandlersAllowed = isMobile || PlatformDetector.isHorizonOs()`
  gates the Listener wiring. The `isMobile` local itself is UNCHANGED —
  skip zones, the edge indicator, chrome sizing, and key handling keep
  their existing TV behaviour. Everything else in these handlers stays
  inert for a mouse pointer (the two-finger tap chord is touch-only), so
  attaching them only opens the edge path.
- Known follow-ups (NOT fixed here): the on-screen edge indicator is
  `if (isMobile)`-gated (`video_controls.dart:1449`), so Quest gets no
  visual feedback for the edge drag — the volume/brightness still change;
  and `_handleDeviceAdjustmentResume()` (`video_controls.dart:1044`) is
  mobile-only, so a brightness set on Quest won't auto-restore on resume.
  Both are one-line follow-ups for the tester to confirm as real gaps on
  the headset.

## Deliberately NOT done

No global hover→focus (the rail already has model-level hover; global
hover-focus would fight the auto-scroll guard, issue #2031); no native
joystick→D-pad bridge; no guide changes (out of scope); no search/IPTV
catalog changes; no version bump; no Trex credentials used.

## Verification (builder's own)

- `flutter analyze`: **49 issues — the baseline**. The first run showed
  53 (4 new: unused/unnecessary imports in the two new test files);
  fixed, re-run is back to 49.
- New tests:
  - `test/widgets/tv_rail_scroll_bridge_test.dart`: **16/16 pass**
    (accumulator → `_moveHub`/`_moveItem`, cooldown, hysteresis,
    discard/reset, thresholds re-read per event, non-scroll signals
    ignored).
  - `test/widgets/tv_browse_rail_scroll_bridge_test.dart`: **5/5 pass**
    (vertical scroll moves hub, back the other way, horizontal scroll
    moves item, sub-threshold scroll is a no-op, scroll over a real
    scrollable outside the rail leaves the rail alone).
  - `test/widgets/video_controls_horizon_os_edge_gestures_test.dart`:
    **2/2 pass** (mouse drag on the volume edge writes the volume on
    Horizon OS TV; the same drag does nothing on plain TV). This test
    FAILED first with the gate-only fix — it is what caught the missing
    Listener wiring above.
- Affected suites, all green:
  - `test/utils/`: **865/865 pass**. First run was 863/865: one failure
    was the `'horizon_os'` diagnostic-reason bug above (fixed, 25/25 in
    the detector file after the fix); the other was unidentified (the run
    output was truncated) and green on the full re-run — a parallel-load
    flake of the kind the v1 notes document for this repo, not a code
    failure.
  - Existing rail tests (`test/widgets/tv_browse_rail_test.dart`):
    **53/53 pass**.
  - Card widgets (media_card ×5, episode_card, folder_tree_item,
    quest_card_menu_buttons): **66/66 pass** (matches the v1 baseline).
  - Video-controls suites (all `video_controls_*`, incl. the new
    Horizon OS gate test): **271/271 pass**.
  - `test/services/iptv/` + `test/screens/livetv/`: **331 tests; run 1:
    329/331, run 2: 330/331.** The failures are parallel-load flakes in
    cache tests, not this build: the EPG cache test failed in run 1 only
    and passes alone (1/1); the catalog cache test failed in both runs
    and passes alone (1/1) and as a whole file (22/22). This build
    touches no catalog/cache code (see the diff stat — no file under
    `lib/services/iptv/` or the cache code). The separate tester runs
    the full suite.
- Full suite NOT run (the separate tester does that).
- Kotlin is NOT type-checked by `flutter analyze` — the Codemagic cloud
  build is the Kotlin compile gate. The Kotlin change is a 2-line
  removal plus a verdict-ordering reorder, re-read; it mirrors the Dart
  fallback line for line.

## UNPROVEN (can only be settled on the headset)

- **Thumbstick arrival**: whether the Quest thumbstick's scroll events
  reach the app as `PointerScrollEvent`s.
- **Pointer kind**: whether the laser pointer arrives as mouse (the
  bridge and the player gate both assume mouse-kind).
- **railHasFocus on entry, horizontal transient, panel sizing, Kotlin
  compile** (Codemagic gate).
- The v1 UNPROVEN items that carried over: panel sizing, Kotlin compile.
  The veto-on-hardware item is DEAD (veto removed — nothing to prove).
  The "TV veto pre-fix log check" is dead too.

## Phone / Quest verification steps (for Matt, when the build lands)

1. Sideload on Quest: the app should open in the TV interface (left
   rail, focus UI) — NOT the phone layout.
2. Discover/Home: push the thumbstick up/down — the hub selection should
   move (spotlight follows); push left/right — the item selection moves
   along the row.
3. Library poster grid: trigger-drag vertically still scrolls (as before).
4. Long-press menus: hover a poster card — a ••• appears bottom-right;
   tap it — the same menu as a long-press opens. List rows, episode rows,
   playlist rows and library folder rows show a trailing •••.
5. Video player: drag from the left/right screen edge with the pointer —
   brightness/volume adjust. Note: no on-screen indicator pill appears on
   Quest (known gap) — judge by the actual volume/brightness changing.
6. Thumbstick: push the thumbstick up/down on a list and say whether it
   moves the selection (this is the one open question — report it either
   way).
