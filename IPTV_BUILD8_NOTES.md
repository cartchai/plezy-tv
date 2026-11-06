# PlezTV build #8 notes (v2.25.4, unreleased — parent bumps version, commits, pushes)

Matt is on v2.25.3 (one-reinstall path worked). Four items, all from his 2026-11-06 ~10:05 EST report.

## Task 1 — Series search returns nothing

### Diagnosis (proven by code + failing-first test)
`IptvClient.searchItems` (`lib/media/iptv_client.dart:1016`) merges movies
first, then series, into ONE list capped at the shared `limit` (100). Any
query matching ≥100 movies starves series entirely — before the aggregation's
relevance ranking ever runs. On the real provider (199,762 movies) a
common-word query easily matches 100+ movies, so series never reach the
search screen. Failing-first test: `iptv_stage2_test.dart` — 100+ matching
movies + a matching series → series missing from `searchItems` results
(before fix). A slow series fetch also blocks the whole search: `Future.wait`
holds both sections under the aggregation's 60s IPTV leg deadline, so a cold
46k-row series catalog can kill the movies leg too. Both fixed:

- Per-section result caps: each section gets its own `limit` budget (movies
  ≤ limit, series ≤ limit); the merged list is capped at `2 * limit` and the
  aggregation's `rankSearchHits` picks the top 100 by relevance, so an exact
  series-title match now beats partial movie matches instead of never being
  seen.
- Per-section time budget: each section races a budget (50s, inside the 60s
  leg deadline — `@visibleForTesting static` so tests can shrink it). A timed-out
  section returns `[]` for that search while its underlying catalog fetch
  keeps running and warms the cache, so the next search finds it. The other
  section's results are never held hostage.

Ruled out: `_seriesList()` DOES cover the search path (build #7 per-category
fallback is shared by browse and search); `_isDisabled` and the category-prefix
strip do not drop series in search (covered by existing tests); the search
screen does not exclude the series library (it shows whatever the aggregation
returns — verified in the Task 2 work). The hidden-library exclusion only
fires when the user hides a library.

### Tests (iptv_stage2_test.dart, new "Task 1" group)
- `searchItems returns series matches when movies fill the shared cap`
- `searchItems returns movie results when the series section fails`
- `searchItems returns series results when the movies section fails`
- `searchItems returns a slow section's results on the next search after
  the budget expires` (slow series fetch + fast movies → movies returned,
  then series returned once warm)

## Task 2 — Search sections

### Design
The Search screen (`lib/screens/search_screen.dart`) keeps its kind chips, but
they become JUMP chips: tapping Movies / Shows / Live TV / People scrolls to
that section instead of filtering to one kind. The "All" view is no longer a
flat ranked list — results group into sections by library, ordered Movies,
TV Shows, Live TV, then other libraries (Plex etc.), each with a header
(library title + count). A series result lands in the TV Shows section
(Task 1's fix feeds it). Plex results keep their own library sections.
Placement: sections are built in `_buildResultsList` via `buildResultsSliver`
per section, headers keyed with `GlobalKey`s for `Scrollable.ensureVisible`.

### Tests (search_screen_test.dart)
- results group into Movies / TV Shows / Live TV sections in that order
- tapping the Shows jump chip scrolls to the TV Shows section
- a Plex library result appears in its own section, not under IPTV

## Task 3 — EPG still doesn't load + the loader never shows

### Diagnosis (two distinct root causes, both in the guide path)
1. **Silent failure is recorded as success.** `IptvLiveTvSupport.fetchEpgForChannel`
   (`lib/media/iptv_live_tv.dart:124`) catches every fetch error and returns
   `[]`; the guide tab then marks the channel LOADED (line 952) — so a failed
   xmltv.php download + empty get_short_epg is indistinguishable from "this
   channel has no programmes", is cached as loaded, and never retried.
   `_iptvEpgFailed` is nearly dead code.
2. **The loader is invisible.** While a channel loads, its row renders a
   BLANK `Material` with `child: null` and the only loading signal is a 3px
   `LinearProgressIndicator` under the time navigation — on a phone, Matt
   cannot see it. Rows show nothing until the fetch resolves, then jump
   straight to hour placeholders. Loading / loaded-empty / failed all look
   the same: silent placeholders.

Scale (Matt's hypothesis) is real too: the xmltv.php file covers 55k channels
(tens of MB, 120s timeout) and every visible channel's fetch waits on that one
shared download before any row shows data.

### Fix
- `fetchEpgForChannel` now THROWS when the fetch itself fails (both sources
  failed) and returns `[]` only when the fetch succeeded but the channel
  genuinely has no programmes in the window. The guide marks thrown fetches
  FAILED and keeps them retryable.
- **get_short_epg first, xmltv in the background.** `_fetchXtreamEpg` kicks
  off the xmltv.php download in the background (shared/deduped future) and
  awaits per-channel `getShortEpg` first, so visible rows populate in seconds.
  If get_short_epg is empty, it awaits the xmltv guide (already in flight)
  and uses it. The persisted per-channel cache and TTL are unchanged.
- **Truthful rows.** While a channel loads, its row shows a visible
  "Loading guide…" state (spinner + label), not a blank row. A failed channel
  shows "Guide couldn't load — tap to retry" (tapping clears the failed flag
  and re-fetches). Loaded-but-empty keeps the hour placeholders. The 3px
  header line stays as the global signal.
- Failed channels now retry on tap, on window change, and on guide refresh —
  never stuck dead for the session.

### Tests
- `guide_tab_iptv_test.dart` (new): loader visible during a slow fetch (row
  shows "Loading guide…"); failed fetch shows the retry state, not silent
  placeholders; tapping retry re-fetches; a failed channel retries on window
  change.
- `iptv_epg_cache_test.dart` (updated Task 7 tests to the new ordering):
  xmltv failure falls back to getShortEpg; getShortEpg-first returns fast
  while xmltv is still downloading; both sources failing throws (failed state
  propagates).

## Task 4 — Initials filter (final design, after Matt's three refinements)

### What Matt actually wants (supersedes the original brief's ISO 639-1 part)
- **NO language mapping, NO ISO list, NO language names.** Do NOT figure out
  what each initial means. Detect each set of initials exactly as it appears
  in the content (EN, ES, IT, NF, UK, US, whatever the provider uses) and
  offer one toggle per set. **EVERY initial-set is toggleable, including
  provider tags like "NF"** — there is no allow-list of "real" languages.
- **Detection by repetition.** An initial only counts when it KEEPS REPEATING
  across many items — the same prefix showing up over and over is what makes
  it a grouping, not a one-off. **Repeat threshold: 5** — an initial must
  appear on at least 5 items (in the scanned catalog: channels + movies +
  series names and category names) before it is offered as a toggle. One-off
  prefixes are never offered, so the filter list stays short.
- **Placement: in the category, on the IPTV settings screen.** The toggles
  live WITH the category groupings (same filter area, same collapsible
  Show/Hide pattern, grouped by initial inside the category system) and the
  IPTV settings screen (`lib/screens/settings/iptv_settings_screen.dart`) is
  their home. They are ALSO surfaced on the connection edit screen alongside
  the Live TV / Movies / Series category sections (same shared section
  widget, same state), because that is where the category toggles live.
- **Scope: per-connection** (same as `disabledCategoryIds`) — each IPTV
  connection keeps its own `disabledInitials` list. The settings screen
  shows one initials section per IPTV connection (collapsible, with the
  connection name), so the toggle always applies to the connection it was
  set on. Changing it rebinds the active profile, exactly like the category
  filter does.

### Detection rule (as implemented)
- `lib/utils/iptv_initials.dart` (pure): `detectInitial(name)` — a 2–3
  capital-letter prefix followed by a separator (`-`, `|`, `:`, `/`, with
  optional spaces): "EN - Title" → EN, "UK|Channel" → UK, "ES: Show" → ES.
  **A bare space is NOT a separator** — "IT Crowd" is a title, not an
  initial, and is never offered. `initialOf(name)` is the same plus the
  bare case: a name that IS just an initial (a category named "NF" — the
  provider's category names are the initials themselves) counts as that
  initial. The scan and the filter use the same definition (`initialOf`).
- Counted across the connection's whole catalog (live channel names, VOD
  names, series names, AND category names) by `IptvClient.iptvInitials()`,
  which reuses the client's cached catalog futures. `countInitials` +
  `initialsMeetingThreshold` (threshold **5**) → most-common first, ties by
  initial. Below 5, never offered.

### Storage / wiring (as implemented)
- `disabledInitials` (List<String>) on `M3uConnection` / `XtreamConnection`
  (`lib/connection/connection.dart`), JSON-serialized, `copyWith` — same
  pattern as `disabledCategoryIds`.
- `IptvClient._isDisabledInitial(name)` (via `initialOf`) + `_disabledInitials`
  set. Honoured everywhere `disabledCategoryIds` is: browse
  (`_moviesItems` / `_seriesItems`), search (`_searchMovies` /
  `_searchSeries` / `_searchM3uEntries` — M3U checks the entry name AND its
  group title), categories (`iptvCategoriesForLibrary` — a category whose
  NAME carries a disabled initial is hidden; `iptvItemsForCategory`), and
  Live TV (`iptvChannels`, both Xtream and M3U). NOT applied to the
  per-category catalog-fallback fetch lists (the items are filtered
  downstream anyway, so the result is the same).
- Shared widget `lib/widgets/iptv_initials_checklist.dart`
  (`IptvInitialsChecklist`): loads its own initials lazily through its own
  `IptvClient` (created from the connection, closed on dispose), shows a
  loading row / failed row with Retry / "no repeating initials" / the
  checklist (one `FocusableSwitchListTile` per initial, label "EN (142)"),
  with its own Show all / Hide all. The parent owns the disabled set:
  `onDisabledChanged` reports the new set, `onLoaded` reports the detected
  list (for the parent header's count).
- **Edit screen** (`edit_iptv_connection_screen.dart`): a fifth section kind
  (`_CategorySectionKind.initials`) appended after the category sections in
  the flat row list — header ("Name initials", count / "N of M hidden"
  subtitle, expand chevron) + one checklist row. Deferred save, same as
  categories: `_save` writes `disabledInitials` via `copyWith` + `upsert
  (expected:)`. Expansion persisted via new pref
  `iptvCategoriesInitialsExpanded`. The header's Show all / Hide all apply
  to categories only; the checklist has its own pair for initials.
- **Settings screen** (`iptv_settings_screen.dart`): one
  `_IptvConnectionInitials` section per IPTV connection, directly under its
  connection tile (collapsed by default, local state, not persisted).
  A toggle persists IMMEDIATELY (registry `upsert` + `rebindIfActive`,
  same as the tile's edit flow), so the filter applies everywhere at once.
- Test seam: `IptvClient.debugClientFactory` (static, `@visibleForTesting`,
  same pattern as the edit screen's `debugHttpClient`) — when set,
  `forConnection` returns the factory's client, so the checklist can load
  catalogs from a fake API in widget tests. Always null in production;
  tests clear it in tearDown.
- Known edge: on the edit screen, if a connection has NO categories at all
  the screen shows its empty state and the initials section is unreachable
  there — the settings screen still offers it (it does not depend on the
  category fetch).

### Tests (as implemented)
- `test/utils/iptv_initials_test.dart` (7 tests): prefix detection incl.
  all separators; bare space is not a separator ("IT Crowd" never offered);
  bare-initial names ("NF" category) count via `initialOf`; threshold 5
  (EN 6 + ES 5 offered, IT 4 + NF one-off not); "NF" IS offered (no
  allow-list); ordering most-common first.
- `test/services/iptv/iptv_stage2_test.dart`, group "IptvClient initials
  filter" (6 tests, `_InitialsFakeXtreamApi`: EN ×11, NF ×9, ES ×1):
  `iptvInitials()` detects only the repeating sets; a disabled initial
  hides its content in browse (movies + series), search, Live TV, and a
  category whose name carries it; JSON round-trip persists
  `disabledInitials`.
- `test/widgets/iptv_initials_checklist_test.dart` (4 tests): renders EN
  (11) / NF (9), never ES; toggling NF reports `{'NF'}`; Hide all / Show
  all cover every detected initial; a disabled initial renders off.
- `test/screens/settings/edit_iptv_connection_screen_test.dart` (+1 test,
  6 total): the "Name initials" section lives with the category groupings;
  toggling updates only its own switch (deferred save); the section
  collapses/expands on its own. (The pre-existing "toggling a shared
  category id" test needed its Show/Hide all finder scoped to `.first` —
  there are two "Hide all" buttons on the screen now.)
- `test/screens/iptv/iptv_screens_test.dart` (+1 test): the settings screen
  shows the initials section under the Trex tile; expanding shows EN/NF;
  toggling NF off flips the switch AND the registry's stored connection
  reads back `disabledInitials == ['NF']`. The rebind step is NOT exercised
  (no active profile in the test — `rebindIfActive` is skipped when there
  is none), so "toggle hides content after rebind" is proven up to the
  persist; the live rebind + content hiding is for Matt's phone.

## Verification (run 2026-11-06, build #8 complete)
- `flutter analyze --no-pub`: **49 issues — exactly the pre-existing
  `packages/wakelock_plus/` baseline; zero issues in build #8 code.**
- Test suites (per directory, never combined, never two at once):
  - `test/services/iptv/`: **89/89 pass** (incl. stage2 search + initials
    groups, epg + epg-cache).
  - `test/utils/`: all pass **except one pre-existing flaky test**,
    `memory_pressure_breadcrumbs_test.dart` ("records the image cache…",
    `Expected >= 384, Actual 383` — an RSS measurement, in a file build #8
    never touched; fails in isolation too). `iptv_initials_test.dart` 7/7
    + `search_sections_test.dart` 4/4 = **11/11 pass** on the touched files.
  - `test/widgets/`: **1038/1038 pass** (incl. 4 new checklist tests).
  - `test/screens/settings/`: **199 pass, 3 skipped, 0 fail** (incl. 6
    edit-screen tests, 1 new initials test).
  - `test/screens/iptv/`: **17/17 pass** (incl. 1 new settings-screen
    toggle-persists test).
  - `test/screens/search_screen_test.dart` + `test/screens/livetv/guide_tab_iptv_test.dart`:
    **33/33 pass** (Task 2/3 regression check after the Task 4 client edits).
- Kernel-blob / APK checks: NOT done here (parent builds via Codemagic).
- Environment notes from this session: `/tmp` is a 512 MB tmpfs and a big
  test dir's compiler output (~460 MB) fills it — killed/overlapping runs
  leave stale `flutter_tools.*` dirs behind; clean them (`rm -rf
  /tmp/flutter_tools.*`) before re-running a big suite, or the compile
  fails with "No space left on device". Also: the settings-screen toggle
  test needs the screen unmounted mid-test (`pumpWidget(SizedBox.shrink())`
  + settle) or drift's watch-stream close timer trips the binding's
  "timer still pending" check at teardown.

## Unproven against the real provider (for the parent / Matt's phone)
- Series search returning matches on a real query (the cap-starvation fix is
  proven by test; whether Matt's actual queries hit the cap on the real
  199k-movie catalog can only be seen on his phone).
- EPG: whether get_short_epg returns data for Trex channels (the xmltv
  tvg-id matching is unproven — if the file's channel ids don't match the
  provider's epg_channel_id, the xmltv fallback still misses), and whether
  the guide now populates in seconds.
- Initials: which initial sets actually repeat on Trex content (EN/ES/NF/…)
  — the detector runs against the real catalog on his phone. Also: the
  settings-screen toggle → rebind → content-hides loop is proven only up to
  the persist in tests (no active profile in the widget test, so
  `rebindIfActive` is skipped there) — Matt toggling EN off and watching
  channels disappear is the proof that step needs.
- 60s leg deadline vs a cold 46k-row series fetch on LTE (the per-section
  budget should contain it, but the real fetch time is unproven).
