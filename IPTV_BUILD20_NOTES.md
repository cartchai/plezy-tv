# Build #20 — Trex 403: send a User-Agent (v1.0.3-2.25.0+175)

Builder notes, 2026-11-09 ~21:00–23:00 EST. Worktree
`~/workspace/tmp_work/plezy-tv-build20-ua`, off main ac3ddcbda
(v1.0.2-2.25.0+174). No push, no release, no live panel calls, no
credentials — per the task.

## The failure (from Matt + research)

- Phone (20:47 EST, screenshot `9663_0_vy01.jpg`): Discover banner "trex
  refused access for this account", "Unable to load Discover" — on WiFi
  AND mobile data. TiviMate works, same account, same phone/network.
- Research (`~/workspace/tmp_work/plezy-tv-research-trex-refusal/RESEARCH_TREX_REFUSAL.md`,
  read first): the app sends NO User-Agent, so the panel sees Dart's
  default `Dart/3.13 (dart:io)`. Xtream panels enforce per-user allowed-UA
  lists + global blocked-UA patterns (USER_AGENT_BAN / EMPTY_UA). `VLC` is
  the #1 documented 403 fix. Matt's "the panel detected the AI" theory has
  no mechanism (probes were curl from a cloud IP, a different signature;
  an account-level response would hit TiviMate too; a PlezTV login
  succeeded AFTER the last probe).

## What changed

- `lib/services/iptv/xtream_api.dart` — NEW `XtreamUserAgent` (constants,
  choice keys, `resolve()` with VLC fallback, never empty). `XtreamApi`
  gains `userAgent` / `userAgentProvider` (initializing formals, per the
  `prefer_initializing_formals` lint); `_fetchBody` and `_getText` both
  send `{'User-Agent': _effectiveUserAgent}`. Default VLC.
- `lib/services/settings_service.dart` — NEW prefs
  `iptv_xtream_user_agent` (default 'vlc') +
  `iptv_xtream_user_agent_custom`, both in `_portableOnlyPrefs` (settings
  export/import backup, like `iptvShowCatchUpBadge`).
- `lib/media/iptv_client.dart` — `_xtreamApi` passes a provider closure
  reading both prefs per request (setting change applies to the next
  request, no rebuild); `instanceOrNull` null → VLC.
- `lib/screens/settings/add_xtream_screen.dart` — sign-in probe sends the
  configured UA (same signature the app will use).
- `lib/screens/settings/iptv_settings_screen.dart` — NEW "Xtream Codes"
  group: selection tile (VLC / IPTVSmartersPro / Browser / Custom) with a
  subtitle showing the resolved UA, + Custom text row shown only when
  Custom is picked. Group wrapped in a `ValueListenableBuilder` on the
  custom pref so the subtitle stays live when the text is edited.
- `lib/screens/settings/settings_utils.dart` — NEW `showPlainTextInputDialog`
  (modeled on `showRegexInputDialog`, blank rejected, Reset to default).
- `lib/widgets/setting_tile.dart` — NEW `SettingTextTile` (modeled on
  `SettingRegexTile`; subtitle shows the value or the empty hint).
- `lib/i18n/en.i18n.json` + slang regen — `iptv.xtream*` keys,
  `about.changelog2267`.
- `lib/screens/settings/about_screen.dart` — changelog entry on top.
- `pubspec.yaml` — 1.0.3-2.25.0+175 (both climb; updater compares names).
- `FORK_MAINTENANCE.md` — §19 + scale recount.

## Verification (in-harness only; phone is the final gate)

- Failing-first: the default-UA test FAILS on ac3ddcbda
  ("player_api.php?... carries no User-Agent"); the 403 control passes on
  base. Both new test files pass after the fix (6/6).
- `flutter analyze` on the 10 changed files: clean. Repo-wide: 49
  issues, all vendored `packages/wakelock_plus`, zero in `lib/` — same as
  the ac3ddcbda baseline.
- `test/services/iptv/`: 245/245. `test/screens/livetv/`: 102/102.
  `test/screens/iptv/` + `test/screens/settings/`: 224 pass, 1 failure —
  `iptv_categories_screen_scroll_test` "scroll-frame cost at real scale
  stays near baseline" failed ONCE in the combined run; passes alone
  (3/3) and passed in a second combined run (aborted at +135 by the
  harness, past the scroll test). Load flake, not a regression: this
  change does not touch the categories screen or the scroll path.
- NOT verified: the panel accepting VLC (phone-only); the settings screen
  rendering on the phone (no widget test for the new group — tester:
  worth adding one); settings export/import round-trip of the two new
  prefs (they are in `portablePrefs`, same path as `iptvShowCatchUpBadge`,
  but not exercised in-harness here).

## Gotchas hit during this build

- Do NOT run `dart format` on whole files in this repo. The committed
  code is not formatter-clean even at the repo's 120 width
  (`analysis_options.yaml` page_width 120), so the formatter rewrites
  unrelated lines. Caught twice (first at width 80, then at 120);
  restored from HEAD and re-applied edits by hand both times. Final diff
  is 362 insertions / 11 deletions across 12 files + 2 new test files.
- `dart format --output=none --set-exit-if-changed` uses width 80 by
  default — wrong for this repo. There is no formatter gate; match the
  surrounding 120-col style by hand.
- `flutter test` on a big directory backgrounds after ~120 s; write the
  log to a file and read the file (`tail` on the backgrounded delivery
  comes back empty).
- The background `flutter analyze` delivery also comes back empty — same
  file-log workaround.
- The `SettingRegexTile`/`showRegexInputDialog` pair was the template for
  the Custom row, but the regex validation was wrong for a UA string —
  hence the new plain-text pair instead of reusing it.
- `XtreamUserAgent` doc references to `SettingsService`/`IptvClient` use
  plain text, not `[bracket]` links: xtream_api.dart does not import
  those, and the bracket form would need an import that analyze flags as
  unused.
