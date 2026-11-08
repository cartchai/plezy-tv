# PlezTV build #16 — v2.25.12 (2.25.12+169)

Three phone reports from Matt on v2.25.11 (2026-11-08), all fixed in this
build. Research: `~/workspace/tmp_work/plezy-tv-research16/RESEARCH_BUILD16.md`
(proves all three root causes; read it first — this file records what was
built, not the investigation).

## 1. Categories scroll lag — virtualized

**Report (Matt, 2026-11-08 ~09:55 EST):** the build #15 "Trex categories"
screen is "really laggy to scroll".

**Root cause (proven by the research probe):** `IptvCategoriesScreen` built
every section as ONE `SliverToBoxAdapter` wrapping a `SettingsGroup` Column
— all 1,236 rows (`FocusableSwitchListTile`, each a StatefulWidget with its
own FocusNode) built eagerly at load. `build()` also rescanned all rows for
the "N categories hidden" line, and every section rescanned its rows for its
heading. Measured pre-fix: fling + 30 frames 4,991 ms total, 1,236 rows
built at load, one toggle 770 ms.

**Fix** (`lib/screens/settings/iptv_categories_screen.dart`):
- Each section is now a `SliverList.builder`: item 0 is the
  `SettingsSectionHeader`, items 1..n are the rows. Only the viewport (+
  cache extent) is built — **36 rows at load** at 800×1600, not 1,236.
- Rows build their own card via `_groupCard` (same `Material` surface,
  same `groupItemRadii(context, i, total)` corner shapes, same `groupGap`
  spacing as `SettingsGroup` — the look is unchanged; `SettingsGroup` is a
  plain Column, so a builder row has to build the card itself). The
  initials section is virtualized the same way: subheading + Show/Hide
  buttons are card items 0–1, initials follow.
- Hidden counts are cached (`_liveHidden` / `_moviesHidden` /
  `_seriesHidden` / `_groupsHidden` / `_hiddenTotal`, recomputed only in
  `_load` and `_persist` via `_recomputeCounts`) — `build()` no longer
  scans rows, and neither do the headings. The `_allRows` getter is gone.
- Behaviour unchanged: every category visible with its count, every toggle
  immediate, no Save button.

**Measured post-fix** (new test file, see below): fling + 30 frames
~1,100–2,200 ms total across runs (was 4,991); the 30 ballistic frames
average ~12 ms (max ~50 ms); one toggle under the 400 ms threshold. The
22-row "baseline" in the research report (133 ms) measures a list that
does not scroll at all, so the comparable number is the total, not
per-frame — the test asserts the total (< 3,000 ms) AND the frame sum
(< 1,000 ms for 30 frames) AND the max single frame (< 100 ms).

**Tests:** `test/screens/settings/iptv_categories_screen_scroll_test.dart`
(3 tests, Trex-scale fixture: 833 live + 200 VOD + 200 series):
- rows built at load are viewport-sized, not all 1,236 (manual element
  walk — `find.byType` under-counts by design on this screen);
- scrolling to the bottom still reaches every row (and back to the top);
- scroll-frame cost at real scale stays near baseline (total + frame sum +
  max frame + one toggle + the toggle takes effect).
Two test-harness notes worth keeping: `scrollUntilVisible` needs
`maxScrolls: 100` — the default 50 drags of 1,000 px (50,000 px) cannot
reach the bottom of a ~60,000 px list; and after a fling the first row is
off-screen and *unmounted*, so the toggle section scrolls back to the top
first (a virtualized row that is off-screen is not built).

## 2. Mini-player still black — Android video-rect path implemented

**Report (Matt, 2026-11-08 ~09:58 EST, screenshot `9616_1_qx07.jpg`):**
mini-player STILL BLACK on v2.25.11. The build #15 diagnostic row WORKED
and named the failed step: US| COMEDY CENTRAL HD · mpv · First frame:
restart event · 3969 ms · Restart seen: yes · **Video rect sent: no**.

**Root cause (proven by research):** build #15's premise was wrong —
"Video rect sent: no" can NEVER be yes on Android. `VideoRectSupport`
was mixed in only by `PlayerLinux`/`PlayerWindows`; neither Android
player implemented it and no `setVideoRect` existed in the Android native
plugin. On Android both backends fit the video into the FULL window
centered in a full-window `SurfaceView` below the Flutter view, so the
mini-player's 16:9 picture sat in the vertical middle behind opaque
Flutter UI (audio plays, first frame arrived, cover lifted — all
consistent). The full player works because its hole IS the full window.

**Fix — Dart:**
- `lib/mpv/player/video_rect_support.dart`: the mixin is now
  `on PlayerBase` (it only needs `PlayerBase.invoke`), not `on
  PlayerNative`.
- NEW `lib/mpv/player/platform/player_native_android.dart`:
  `PlayerNativeAndroid extends PlayerNative with VideoRectSupport` — same
  shape as `PlayerLinux`/`PlayerWindows`. The `Player` factory returns it
  for Android mpv (`lib/mpv/player/player.dart`); iOS/macOS still get the
  plain `PlayerNative` (no native handler there — `Video` keeps its plain
  branch), and the audio-only player stays rect-less.
- `lib/mpv/player/platform/player_android.dart`: `PlayerAndroid extends
  PlayerBase with VideoRectSupport` (ExoPlayer).
- `Video` (`lib/mpv/video.dart`) needed NO change: its LayoutBuilder +
  post-frame machinery, `_hasSentRect` dedup, and reset-on-player-swap
  already send the rect whenever the layout changes, and
  `onVideoRectSent` feeds the diagnostic — once the path exists, the
  diagnostic's "yes" is a real signal.

**Fix — Kotlin** (both backends fit the video into the surface container,
so a hole-sized container yields the right picture):
- NEW method on the shared `SurfacePlayerCore` interface
  (`android/.../shared/SurfacePlayerCore.kt`):
  `setVideoRect(left, top, right, bottom)` (physical pixels).
- `MpvPlayerCore.setVideoRect` / `ExoPlayerCore.setVideoRect`: remember
  the last rect (`requestedVideoRect`) and resize/reposition the
  **surface container** via `FrameLayout.LayoutParams` (width/height +
  left/top margins + `Gravity.TOP|START`; full window = MATCH_PARENT,
  margins 0). Params are only written when they change, so the
  global-layout listener cannot re-trigger forever. The stored rect is
  applied right after `attachToContent`, so a rect arriving before the
  container exists is not lost. The video surface re-fits itself into the
  resized container on the next layout pass (mpv:
  `applyVideoRectLayout`; ExoPlayer: `updateSurfaceViewSize` via the
  layout listener); the OSD/subtitle plane is full-container, so
  subtitles follow the hole.
- `MpvPlayerPlugin` / `ExoPlayerPlugin`: `"setVideoRect"` method-channel
  handler. The mpv plugin keeps a `pendingVideoRect` when no core exists
  yet and applies it when init succeeds (the mini-player's `Video`
  mounts before the first open initializes the core). The ExoPlayer
  plugin keeps `lastVideoRect`, routes through `activeSurfaceCore` (so a
  backend switch reaches the right core), applies it at initialize, and
  re-applies it to a fresh mpv fallback core in `dispatchMpvOpen` — Dart's
  `Video` dedups by value and will not resend it, so the fallback would
  otherwise leave a full-window container behind.

**Risks / honest limits (phone is the judge):**
- The container is shared by the video surface + OSD plane + subtitle
  views; subtitles should follow the hole, and the mpv OSD margins are
  derived from the published `vo-mediacodec-video-rect` (which tracks the
  surface view inside the container) — verify on the phone that ASS
  subtitles sit inside the mini-player picture, not at the old full-window
  position.
- Retune/zap re-sends the rect via `Video`'s player-swap reset (tested in
  harness); fullscreen↔mini-player transitions rely on each `Video`
  instance sending its own rect on mount/layout (tested: full-window rect
  sent for a fullscreen-sized `Video`).
- The Kotlin compiles only on the cloud build — `flutter analyze` does
  not type-check Kotlin. The Codemagic build is the compile gate for the
  native side; if it fails there, the failure is in the new Kotlin, not
  in the Dart.
- The diagnostic row in Settings → IPTV now reads "Video rect sent:
  yes" when the path works. If the mini-player is STILL black with "yes",
  the fault is downstream of positioning (surface/vo), not geometry.

**Tests:** `test/mpv/video_android_rect_test.dart` (7 tests, all passing):
rect sent for the mini-player hole after mount (320×180 hole → rect
0,0,320,180); re-sent when the hole moves; re-sent for a replacement
player (retune); full-window video sends the full-window rect;
`onVideoRectSent` fires once the rect lands (diagnostic); the real
ExoPlayer backend sends the rect on its own channel; the production
Android players expose rect support while plain `PlayerNative` does not.
The widget tests drive the REAL production players
(`PlayerNativeAndroid`, `PlayerAndroid`), not fakes.
Three test-hygiene lessons, all learned the hard way in this file and
recorded in its header comment:
- Never dispose a real `PlayerBase` in a widget test (dispose awaits
  native-ownership waits + event-channel cancels that never resolve in
  fake async and stalls the runner with no output).
- One real player per channel per file: `PlayerBase.invoke` waits on the
  previous instance's native-ownership release, and an undisposed
  predecessor never releases — a second real player on the same channel
  never reaches the method channel (its invoke times out after 8 s and
  returns null). The single-player tests share one player per channel;
  the retune test uses `_FakeRectPlayer` fakes (no `PlayerBase`, no
  ownership gate).
- The rect is in PHYSICAL pixels: pin the test device pixel ratio to 1.0
  (at the test default 3.0 a 320-wide hole sends right=960 — correct
  behaviour, confusing assertion).

## 3. Catch-up isn't working — timeshift start stamp had seconds

**Report (Matt, 2026-11-08 ~10:38 EST, screenshot `9619_0_6lz5.jpg`):**
tapping a past programme (The Office 9:30 AM) gives "Could not start the
live channel". The guide, the times, and the mini-player bar were all
correct — the tune itself failed.

**Root cause (code-read + documented format):** the timeshift start stamp
has seconds; the panel's format does not. Every documented source agrees
— UniPlayer catch-up spec (`/timeshift/USER/PASS/{duration_min}/
{YYYY-MM-DD:HH-MM}/{stream_id}.ts|.m3u8`, "Strict `YYYY-MM-DD:HH-MM`"),
Dispatcharr/pvr.dispatcharr `BuildCatchupUrl` (same shape, UTC via
`gmtime_r()`), Xtream API docs (`/timeshift/{username}/{password}/
{duration}/{start}/{stream_id}`, start `YYYY-MM-DD:HH-MM or YYYYMMDD-HH`).
Our builder (`XtreamApi.timeshiftUrl`) sent `YYYY-MM-DD:HH-MM-SS`, so the
panel's strict parse fails, no archive segment resolves, and mpv's open
fails → "Could not start the live channel". Build #9's own notes flagged
this as unverified ("the panel's exact behaviour is unverified"). Duration
in minutes and the UTC choice match the documented clients and are
unchanged. Also ruled out in the trace: the channel key IS the numeric
stream id (`liveUrlForChannelKey` uses it directly), the EPG times are
correct epochs, and `tv_archive_duration` was already fixed to seconds in
build #9.

**Fix** (`lib/services/iptv/xtream_api.dart`): `timeshiftUrl` now formats
the start as `YYYY-MM-DD:HH-MM` (seconds dropped). One line + comment.

**The "Could not start" card hid the error** — `tune()` caught all
failures with `catch (_)` and discarded them, so a failed catch-up left
nothing to diagnose. That is fixed too, minimally:
- `LiveTvMiniPlayerDiagnostic` gains `failReason`
  (`lib/screens/livetv/live_tv_mini_player.dart`); the controller records
  a short stage label at each tune failure point ("no live server for this
  channel", "startPlayback returned no session", "no stream URL for the
  requested offset", "open failed (<type>)") and the player error's cause
  tag (`server-http-404` etc.) or its first line when an error arrives
  mid-stream. `_reasonForError` strips any `://user:pass@` credentials and
  truncates to 120 chars — a stream URL must never land in a readout the
  user might screenshot.
- Settings → IPTV mini-player diagnostic row renders it
  (`lib/screens/settings/iptv_settings_screen.dart`,
  `t.iptv.miniPlayerFailReason`: "Could not start: {reason}").
- The existing controller test "tune with a catch-up start opens the
  archive URL" now also asserts the stamp shape (no seconds), and the
  no-live-server test asserts the diagnostic records the reason.

**Tests:** `test/services/iptv/iptv_timeshift_url_test.dart` (3 tests,
failing-first, all passing): stamp is `YYYY-MM-DD:HH-MM` with no seconds;
seconds in the input are dropped; duration stays in minutes.

**Honest limit:** the stamp format is proven against the documented
specs, but whether THIS panel accepts it is proven only on Matt's phone
— if catch-up still fails, the diagnostic row now names the stage
("open failed" vs a `server-http-404` cause vs no URL), which is the next
evidence step. Duration semantics (programme start→now vs programme
duration) is unchanged; Dispatcharr says duration = programme duration,
and if the panel rejects the window that is the next suspect.

## Version / changelog

- `pubspec.yaml`: `2.25.12+169`.
- `changelog2262` (plain words) + About entry first + slang regen
  (`lib/i18n/strings_en.g.dart`, `strings.g.dart`).

## Verification (builder's own runs, worktree `plezy-tv-build16`)

- `flutter analyze`: **49 issues, exactly the pre-existing wakelock_plus
  baseline, zero in new code** (first run showed 57 — 8 warnings all in
  new code: a duplicate import in `player.dart`, two statically-known
  type checks in the rect test, unused imports/locals in the scroll
  test; all fixed, re-run is 49).
- New tests: timeshift 3/3, rect 7/7, Categories scroll 3/3,
  mini-player controller (incl. strengthened catch-up + fail-reason
  assertions) 6/6 in its file (9/9 combined with the timeshift file).
- Affected suites, run one at a time, `TMPDIR=~/workspace/tmp_flutter`:
  - `test/services/iptv/`: **186/186** (sequential `--concurrency=1` run).
    Three default-concurrency runs each showed 1–2 failures in files this
    build did NOT touch, a different test each time
    (`iptv_catalog_cache_test` teardown race — "Directory not empty";
    `iptv_epg_cache_test` "Clear guide" — background feed write landing
    after the clear; `iptv_build13_diagnosis_test` B1 — the timing test
    build #14 already flagged as thin-margin under load). Every one of
    them passes alone (cache 22/22, EPG 21/21, B1 9/9). Pre-existing
    parallel-load flakes, not regressions from this build.
  - `test/screens/livetv/`: **89/89**.
  - `test/screens/iptv/`: **17/17**.
  - `test/screens/settings/`: **204 pass + 3 skipped**.
  - `test/mpv/`: **193/193**.
- One pre-existing test updated for the intentional format change:
  `test/services/iptv/iptv_stage2_test.dart` "timeshift URL shape" now
  expects `...:20-30/...` (no seconds) instead of `...:20-30-00/...`.
- Kotlin: NOT type-checked by `flutter analyze` — the Codemagic build is
  the compile gate for the native side.
- Kernel-blob + cert checks are the parent's release step (not run here —
  no cloud build was started from this worktree).

## Phone checks owed (do not ship without the tester's pass + these)

1. Categories screen with the real 833 categories: scroll top-to-bottom
   and back, smooth; every category visible with counts; a toggle takes
   effect immediately and the "N categories hidden" line updates.
2. Mini-player: play a live channel — video visible in the 16:9 hole, not
   black. Settings → IPTV → Mini-player row should read "Video rect
   sent: yes". Check subtitles sit inside the picture, and that going
   fullscreen and back restores both sizes.
3. Catch-up: tap a past programme (e.g. The Office 9:30 AM) — it plays
   from the programme start. If it still fails, screenshot the
   Mini-player diagnostic row — the "Could not start:" line names the
   stage now.
4. ExoPlayer backend (if enabled in settings): same mini-player check —
   the rect path is implemented there too but mpv is the default.
