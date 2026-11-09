# PlezTV Quest fix — build notes (unversioned; rebased onto build #19 before release)

Base: `967cad6da` (v1.0.0-2.25.0). Version NOT bumped in this worktree —
pubspec stays `1.0.0-2.25.0+171`; the parent assigns the next versionCode
at release. This commit will be rebased onto the build #19 commit.

## Why

Matt sideloaded PlezTV (and upstream Plezy — same behaviour) onto Meta
Quest and reported: the app uses the TV interface; the Quest controller
acts like a mouse in 2D apps and isn't very responsive; he can't scroll;
he can't pull down certain areas (pull-to-refresh / dropdowns / drawers).

Research: `~/workspace/tmp_work/plezy-tv-research-quest/RESEARCH_QUEST.md`.
Root cause: Quest has no touchscreen, and the app's TV detection treats
"no touchscreen" as a TV — so Quest gets the TV interface, which navigates
by focus + D-pad keys, and a Quest controller sends ZERO D-pad keys (laser
pointer = mouse hover/click/drag, thumbstick = scroll events, B/Y = back;
Touch controllers never appear as Android gamepads, so GamepadService sees
nothing). Upstream vs fork: the TV trigger, D-pad/focus navigation,
gamepad service and missing mouse-drag are byte-identical upstream —
inherited, not fork-introduced.

Evidence from Matt's recording (upstream Plezy on Quest, 48.9s,
`workspace/user/media_library/video/c1/c1bf13f438d72511e858738ebfc986d677d3b61908c87c5cdd5bdccdeb6571e0.mp4`):
TV side-nav rail opens (~7s). The library poster grid DOES scroll
vertically (~9–17s, ~24–27s) — scroll input reaches the app. Discover/Home
does NOT scroll vertically (0–9s, 39–48s — same hero and Continue Watching
rows; the row moves horizontally only). The Live TV guide does NOT scroll
(~27–32s). Series detail sits static (~18–24s). Search keyboard opens
fine (~32–39s). Implication: the Discover failure is structural — in TV
mode Discover renders `TvSpotlightScaffold` with NO vertical Scrollable
(vertical movement is focus traversal, not scrolling), so there is nothing
scrollable to scroll. The TV veto (step 1) is the fix for Discover: the
phone layout has a real `CustomScrollView`.

## Scope (Matt, 2026-11-09)

- **Guide is OUT of scope** (Matt ~04:38 EST: "Dont worry about the tv guide").
  No channel-column scroll forwarding, no ••• menu button on guide channel
  rows, no guide-specific scrolling work. The TV veto + ScrollBehavior may
  still help the guide's grid as a side effect; that is not claimed.
- **Guide data is NOT an app bug** (Matt ~04:39 EST): the "No program data"
  guide in the recording is his Plex server's guide data, which he hasn't
  fixed server-side. Do not chase guide data / EPG here.

## What changed

### 1. Horizon OS TV veto — `PlezyActivity.kt`, `lib/utils/platform_detector.dart`

- Kotlin `getAndroidTvDetection()`: `isHorizonOs =
  pm.hasSystemFeature("horizonos.software.horizon_os")` (Meta's supported
  mechanism — NOT `Build.MANUFACTURER`), reason `'horizon_os'` added,
  `isTv = !isAutomotive && !isHorizonOs && reasons.isNotEmpty()`,
  `"isHorizonOs"` returned in the map.
- Dart fallback mirrors it: `AndroidTvFeatureDetection` gains `isHorizonOs`;
  `detectAndroidTvFromSystemFeatures` vetoes the same way;
  `TvDetectionService` gains `_isHorizonOs` (set from both the native and
  the fallback paths; the double veto is idempotent) + `isHorizonOsSync()`;
  `PlatformDetector.isHorizonOs()` exposed. The force-TV override can still
  force TV on (same as the automotive precedent — the veto is at detection
  level only).
- Effect: Quest gets the phone/tablet layout (real Scrollables, tap targets,
  toolbar buttons) instead of the focus-driven TV layout. The `!isTV()` gates
  in the player (step 4) and elsewhere lift on their own once this lands.
- Tests: `test/utils/platform_detector_test.dart` — Quest with no
  touchscreen → not TV, `isHorizonOs` true, reasons contain `no_touchscreen`
  + `horizon_os`; Horizon vetoes a stray leanback flag; Horizon + touchscreen
  → not TV; ordinary devices not Horizon OS; `PlatformDetector.isHorizonOs()`
  false before init.

### 2. App-wide mouse-drag scrolling — `lib/utils/app_scroll_behavior.dart`, `lib/main.dart`

- New `AppScrollBehavior extends MaterialScrollBehavior`: `dragDevices` =
  the framework default {touch, stylus, invertedStylus, trackpad, unknown}
  + `PointerDeviceKind.mouse` (verified against the pinned SDK's
  `scroll_configuration.dart`). Applied as `scrollBehavior: const
  AppScrollBehavior()` on BOTH `MaterialApp`s in `lib/main.dart` (live
  at :2003, bootstrap shell at :881).
- One change, fixes trigger-drag scrolling in every list. It does NOT fix a
  screen whose vertical movement is focus-driven rather than scroll-driven
  (TV Discover) — that is what step 1 is for.
- Tests: `test/utils/app_scroll_behavior_test.dart` — mouse + touch in
  `dragDevices`; default kinds kept; widget-level proof that a ListView
  scrolls on a mouse drag (`tester.startGesture(..., kind:
  PointerDeviceKind.mouse)`, offset > 0) and a control proving the framework
  default does NOT scroll on a mouse drag.

### 3. Clickable buttons for drag-only / long-press-only actions

**Refresh — verified, no code needed.** Audit of every `RefreshIndicator`
in `lib/`: only 3 real sites — Explore (`explore_screen.dart:392`),
library base tab (`base_library_tab.dart:580`), library browse tab folders
mode (`library_browse_tab.dart:1788`). Every one ALREADY has a visible
refresh button (Explore toolbar, libraries toolbar → each tab's
`Refreshable.refresh()`). Discover has NO RefreshIndicator (the research
report was wrong there) — it has `manualRefresh()` → `_refreshFromToolbar()`
and a toolbar refresh button (`discover_screen.dart:840`). Live TV has a
toolbar refresh button (`live_tv_screen.dart:1157`). Search has
`manualRefresh()` but no visible button and no RefreshIndicator — out of
scope for this build (search re-runs on typing; refresh there is a
keyboard-shortcut affordance).

**Context menus — ••• buttons added.** A Quest controller cannot long-press
reliably and has no right-click, so every long-press-only menu gets a
pointer path to the same menu:

- `lib/widgets/media_card.dart` — grid cards: a ••• over the poster,
  bottom-right (top-right is the watched checkmark/count, top-left the
  catalog badges, bottom edge the progress bar), revealed on hover only
  (`MouseRegion` in `_buildTapRegion`, `_hovered` state; a finger never
  hovers, so touch users never see it and their long-press is unchanged).
  The button opens the same menu as long-press via `showContextMenu()`
  (`_CardMenuButton`, tooltip `t.common.options`). List rows: a trailing
  •••, always visible (the track-row precedent — list rows have no hover
  state to reveal it). Wired via new `onMenuTap` on `_MediaCardList`.
  Hub sections render `MediaCard`, so hub items are covered; the HubSection
  D-pad long-press path (`_showContextMenuForCurrentItem`) is a
  keyboard/gamepad affordance, not a pointer path — it stays. Series/season
  rows render as `MediaCard`s too — covered; no separate season-row menu
  exists in the code.
- `lib/widgets/episode_card.dart` — a ••• over the thumbnail (bottom-right,
  just above the progress bar), calling `showContextMenu`. It lives on the
  thumbnail rather than as a trailing button so the text column keeps its
  full width: a trailing button narrowed it enough to collapse long
  summaries early (caught by the existing semantics test). Always visible
  (list rows have no hover state); the button mirrors the grid-card
  `_CardMenuButton` as a local `_EpisodeMenuButton`, built as a plain
  `GestureDetector` + `Container` (no `Material`/`InkWell`, no `Tooltip`) —
  those split the card's merged semantics node and dropped the summary out
  of the card's accessible label. The grid-card `_CardMenuButton` was
  switched to the same `GestureDetector` + `Container` construction for the
  same reason (its list-row use sits inside `MergeSemantics`); it keeps its
  `Tooltip`, which the MediaCard semantics suite passes with.
- `lib/screens/playlist/playlist_item_card.dart` — trailing ••• IconButton
  before the remove button, calling `showContextMenu`.
- `lib/screens/libraries/folder_tree_item.dart` — trailing ••• (FocusableButton
  + IconButton, mirroring the play/shuffle buttons) calling `_showRowMenu`,
  **media rows only**: a plain folder's menu holds just Play/Shuffle, which
  are already trailing buttons — a ••• there would be pure redundancy.
- Profile switch menu already has a button affordance (`_ProfileTile`
  `onManage`/`onDelete`/`onSignOut`); main-screen nav long-press is a
  shortcut whose function is reachable via the Libraries tab itself.
- **Guide channel-row •••: DROPPED per Matt** (guide out of scope).

Tests: `test/widgets/quest_card_menu_buttons_test.dart` (5 tests) — grid
card hides the button until hovered, then tapping it fires the long-press
seam (`onLongPress` override); list card trailing button fires the same
seam; episode card and playlist row carry the button; folder-tree media
row carries it while a plain folder with Play+Shuffle does not. Wiring is
proven through `MediaCard`'s `onLongPress` override seam; the other cards
have no override seam, so their tests assert presence — the menu itself is
the shared, unchanged `MediaContextMenu` path (opening the real menu in a
test needs the full MultiServer/ActiveProfile provider stack, which the
existing suites already exercise).

### 4. Video player mouse gestures — `lib/widgets/video_controls/parts/playback_input.dart`

- New `_isEdgeGesturePointer` helper (touch OR mouse); all four edge
  handlers (`_handleTouchPointerDown/Move/Up/Cancel`) accept mouse for the
  edge-adjustment path (seek / volume / brightness). The two-finger tap
  tracker stays touch-only (pointerDown/Move/Cancel calls and the
  `pointerUp` → play/pause chord are gated on `event.kind ==
  PointerDeviceKind.touch`).
- Wiring: `video_controls.dart:1206,1230-1235` — `isMobile =
  PlatformDetector.isMobile(context) && !PlatformDetector.isTV()`, handlers
  attached via Listener only when isMobile; `_mobileTouchGesturesAllowed`
  also requires `isMobile && !isTV()` — both gates lift on Quest once
  step 1 lands. No change needed there.

### 5. Manifest / panel hygiene — `android/app/src/main/AndroidManifest.xml`

- `android:resizeableActivity="true"` on PlezyActivity; `<layout
  android:defaultWidth="1024dp" android:defaultHeight="640dp" />` as first
  child of PlezyActivity; `<meta-data
  com.oculus.supportedDevices = quest2|questpro|quest3|quest3s>` and
  `<meta-data com.oculus.application_type = panel>` inside `<application>`.
- LEANBACK_LAUNCHER / leanback declarations KEPT (Quest ignores them;
  removing them would break real Android TV). minSdk unchanged (25 —
  25→29 is only for Horizon Store submission, not sideloading).
- aapt2 acceptance verified by linking a minimal test manifest containing
  `<layout>` + the Oculus meta-data + resizeableActivity — linked cleanly
  into an APK (check in `/tmp/aapt_check/`).

### Deliberately NOT done

No joystick→D-pad bridge, no hover-moves-focus, no VR UI (per the research
report). No native scroll bridge — the library grid scrolling in Matt's
recording is evidence scroll events arrive. No search / IPTV catalog
changes; no re-migration of the 161 initials; no Trex credentials used.

## Verification (builder's own)

- `flutter analyze`: **49 issues — the baseline** (all in
  `packages/wakelock_plus` test files, pre-existing).
- New tests: `test/utils/platform_detector_test.dart` +
  `test/utils/app_scroll_behavior_test.dart`: **29/29 pass** (part of the
  865 below).
- New tests: `test/widgets/quest_card_menu_buttons_test.dart`: **5/5 pass**
  (part of the 66 below).
- Affected suites, all green:
  - `test/utils/`: **865/865 pass**.
  - Card widgets (`media_card` ×5, `episode_card`, `folder_tree_item`,
    `quest_card_menu_buttons`): **66/66 pass**. This run caught one real
    regression (trailing ••• on EpisodeCard collapsed long summaries — the
    button moved onto the thumbnail) and one semantics split
    (`Material`/`InkWell` inside `MergeSemantics` — both menu buttons are
    now `GestureDetector` + `Container`). The episode semantics test was
    verified passing on base (967cad6da) with the changes stashed, failing
    with them, passing again after the fix.
  - Playlist / folder-tree / video-controls edge / main-screen layout:
    **65/65 pass**.
  - `test/services/iptv/` + `test/screens/livetv/`: **331/331 pass** on
    re-run. (First combined run had one failure in
    `iptv_build13_browse_benchmark_test.dart` — a timing-budget flake under
    parallel load: the test passes alone, 2/2, and the full re-run is
    green. My change touches no catalog/hub code.)
- Full suite NOT run (the separate tester does that).
- Kotlin is NOT type-checked by `flutter analyze` — the Codemagic cloud
  build is the Kotlin compile gate. The Kotlin change is 12 lines, kept
  tiny and re-read; it mirrors the Dart fallback line for line.

## UNPROVEN (can only be settled on the headset)

- **Thumbstick scroll**: whether the Quest thumbstick's scroll events reach
  the app as `PointerScrollEvent`s. The library grid scrolling in the
  recording suggests pointer input arrives, but thumbstick-vs-trigger-drag
  is not distinguished there. Marked UNPROVEN — do not claim it works.
- **TV veto on real Quest hardware**: the veto keys on the
  `horizonos.software.horizon_os` system feature, which Meta documents but
  which has not been observed on a headset from here. Pre-fix 2-min check
  for Matt (still owed): export the log on Quest and confirm the TV
  detection reason reads `no_touchscreen` (pre-fix) — post-fix it should
  read `horizon_os` with TV mode off.
- **Panel size / resize behaviour** on Quest: the `<layout>` default size
  and `resizeableActivity` are standard declarations; how the Quest shell
  actually sizes the panel is headset-observed only.
- **Mini-player / fullscreen transitions on Quest**: untouched by this
  build; the player-gesture change covers edge adjustments only.

## Phone / Quest verification steps (for Matt, when the build lands)

1. Sideload on Quest: the app should open in the PHONE/tablet layout
   (bottom tabs, no left TV rail) — NOT the TV interface.
2. Discover/Home: drag vertically with the trigger — the page should scroll
   (hero + rows move); the Continue Watching row still scrolls horizontally.
3. Library poster grid: drag vertically — rows scroll (as before).
4. Long-press menus: hover a poster card — a ••• appears bottom-right;
   tap it — the same menu as a long-press opens. List rows, episode rows,
   playlist rows and library folder rows show a trailing •••.
5. Pull-to-refresh screens (Explore, library tabs): the toolbar refresh
   button refreshes without any pull gesture.
6. Video player: drag from the left/right screen edge with the pointer —
   seek / brightness / volume adjust; two-finger tap is NOT expected to
   work with a controller (touch-only by design).
7. Thumbstick: push the thumbstick up/down on a list and say whether it
   scrolls (this is the one open question — report it either way).
