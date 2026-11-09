# PlezTV build #18 — v1.0.0-2.25.0 — series search, for real this time

Search-only build. Version scheme changes with this build (Matt's decision):
PlezTV is now **1.0.0**, built on Plezy **2.25.0** — version
`1.0.0-2.25.0+171`, versionCode 171 (keeps climbing from 170, so it
installs over the top). The next updates are 1.0.1, 1.0.2… and the
upstream suffix tracks the Plezy base until a rebase.

## The bug (v2.25.13, Matt's screen recording 2026-11-08 21:42 EST)

Search "game of thrones": Trex — Movies finds 1 (the NF documentary),
Trex — Live TV finds 2 channels, Plex TV Shows finds the show — but
**Trex — Series is absent unscoped and "No results in Trex — Series"
scoped**. The fifth build to touch series search (#8, #9, #10, #13, #17).

Root cause (research `~/workspace/tmp_work/plezy-tv-research18/
RESEARCH_BUILD18.md`): the series disk cache held a **filter-shaped
(partial) list, and the warm search trusted it unconditionally**.

1. `_loadSeries()` falls back to a per-category crawl over
   `wanted = categories minus hidden` when unfiltered `getSeries()`
   returns `[]` — rows in hidden categories are never fetched.
2. `_loadSeriesCached()` wrote whatever `_loadSeries()` returned to
   disk as the catalog — including crawl-shaped rows — contradicting
   `IptvCatalogDiskCache`'s own rule ("filtering is applied at read
   time on the parsed rows, never baked into storage").
3. `_searchSeries`'s warm branch, when `_seriesListLoaded`, filtered
   only the cached list and returned — no sweep, no network, no
   fallback — unfindable for the 24h TTL.
4. The cold path's sweep could not rescue it either: it stops when
   `loadLanded` fires (the disk load lands in ~300 ms), and category
   1219 ("|EN| TOP SERIES", where "EN - Game Of Thrones (2011)" sits)
   is in the LAST batch of the 237-category sweep.

Why the build #17 diagnosis is dead: a race returns [] after ~50 s;
the phone returned [] in ~1–2 s unscoped and <1 s scoped. A search
that completes that fast with zero matches COMPLETED — the warm path
over a list that lacks the row. The #17 probes never modeled the disk
cache (unit tests can't resolve the documents dir; widget tests disable
disk), so no probe ever ran the search against a disk-populated catalog.

## What changed

### 1. Never persist a crawl-shaped list (`lib/media/iptv_client.dart`)

- `_loadSeries()` / `_loadVodStreams()` now return
  `({rows, complete})` — `complete: true` only when the unfiltered
  call returned non-empty rows; the crawl returns `complete: false`
  (including the `wanted.isEmpty` early return).
- `_loadSeriesCached()` / `_loadVodStreamsCached()` write to disk
  ONLY when `complete`. The refresh wrappers return `[]` for a crawl
  so a stale refresh never overwrites a good disk file with a partial
  one (served rows stay the disk rows, source stays 'disk').
- Live has NO crawl fallback (`getLiveStreams()` directly) — verified,
  no write-side fix needed there; live only gains source tracking.

### 2. Heal already-poisoned files — the safety net (MUST ship)

New `_sweepMissingCategories<T>`: when a warm search returns 0
matches for a section, it sweeps the categories the user has NOT
turned off AND that no cached row belongs to (`represented` set),
deadline-bounded, batch `_searchSweepBatchSize` (32 — unchanged),
before answering []. A complete disk list sweeps nothing (`wanted`
empty → immediate return), so a genuine no-match costs no extra
calls. Wired into the warm branches of `_searchMovies` and
`_searchSeries` (same poison class for VOD — the panel returns `[]`
for the unfiltered VOD call at 199k rows, so VOD poisoning is the
normal path, not hypothetical). `_searchLive` gets source tracking
only — no crawl, no heal.

### 3. Diagnostics (`lib/media/iptv_client.dart`,
`lib/screens/settings/iptv_settings_screen.dart`,
`lib/i18n/en.i18n.json` + regen)

- New `_vodLoadSource` / `_seriesLoadSource` / `_liveLoadSource`
  ('' before any load; 'disk' / 'network' / 'crawl'), carried through
  `_SectionTrace.loadSource` → `IptvSearchSectionDiagnostics.loadSource`
  (in-memory only, not serialized).
- The Last search row now renders both: `… load 46417 rows in 36 ms
  (disk) · sweep 0 · partial 0 · hidden 0 · 36 ms` — the `(source)`
  after the load and `· hidden ${hidden}` (previously carried but not
  rendered). One screenshot from Matt now discriminates the source.

### 4. Version + updater (`pubspec.yaml`, `lib/screens/settings/
about_screen.dart`, `lib/services/update_service.dart`)

- `version: 1.0.0-2.25.0+171`. Android picks it up from pubspec
  (`android/app/build.gradle.kts:307-308` uses `flutter.versionCode` /
  `flutter.versionName` — verified).
- About: new entry `1.0.0-2.25.0` → `changelog2264` (sequential key,
  one per build since changelog2250 for 2.25.0); the 2.25.13 entry is
  left untouched — history, not rewritten. Slang regen verified:
  `changelog2264` resolves in `strings_en.g.dart`.
- Updater fix (required in this build): `_extractVersion` took the
  first numeric run ("1.0.0" from tag "v1.0.0-2.25.0") and
  `_isNewerVersion("1.0.0", "2.25.13")` returned false — the updater
  would NEVER have offered this build to a 2.25.13 install.
  `_extractVersion` now keeps the upstream suffix
  (`\d+\.\d+(?:\.\d+)?(?:-[0-9A-Za-z.+-]+)?`); `_isNewerVersion` is
  PlezTV-aware: a PlezTV-scheme version (version-shaped `-` suffix)
  is always newer than a bare version; among two PlezTV versions the
  core compares first, then the upstream suffix (a 2.25.1 rebase reads
  newer than 2.25.0); among two bare versions the numeric comparison
  is unchanged; a non-version suffix ("-rc1") is ignored. The
  skipped-version check uses the cleaned version string consistently
  (string equality — unchanged).

## The D3 probe, corrected

The researcher's D3 as written asserted the disk WAS written in step
1 (`expect(diskRows, isNotEmpty)`) — that asserts the poisoning
behaviour fix 1 removes, so the probe could never go green under the
correct fix. D3 now asserts the fixed behaviour: step 1 proves the
crawl writes NOTHING (`expect(diskRows, isEmpty)`), step 1b seeds the
poisoned file exactly as v2.25.13 wrote it (42,483 rows, every EN
category missing, no 1219 — the count matches the base run exactly),
and step 2 proves the heal finds the show with
`unfilteredCalls == 0` on the still-poisoned disk. New D5 proves the
VOD write-side fix the same way (unfiltered VOD `[]` → crawl → disk
stays empty, documentary still found). The probe file is otherwise
unchanged from research.

## Test-only changes (no product code)

- `test/services/iptv/iptv_catalog_cache_test.dart`: the
  "clearCatalogCache deletes the disk files and the next load
  refetches" test let the refetch's fire-and-forget writes (vod.json +
  vod_categories.json, the last scheduled inside `_vodPageItems`)
  race tearDown's recursive temp-dir delete — ENOTEMPTY. It now waits
  for both files to land after the refetch (the same `waitForDataset`
  pattern the test already uses in step 1). No assertion weakened.
  It failed 3× consecutively on this commit before the fix (base
  passed 4/4) and passes 3/3 after.
- `test/services/iptv/iptv_build18_probes_test.dart` tearDown: same
  retry guard the EPG cache tests already use (2 attempts, 100 ms
  yield) for a fire-and-forget write landing mid-delete.

## Verification (builder's own runs, sequential,
TMPDIR=~/workspace/tmp_flutter)

- Failing-first on base (ffa69dd87): probes 2 pass / 3 fail (D1, D1b,
  D3 fail; D2, D4 pass) — reproduced before any product change.
- After the fix: probes **6/6** (D1, D1b, D2, D3 rewritten, D5 new,
  D4). D3 step 1: disk rows=0; step 2: titles include
  "EN - Game Of Thrones (2011)", loadRows=42483, unfilteredCalls=0.
- `test/services/update_service_test.dart`: **25/25** (17 pre-existing
  + 8 new build #18 tests: v1.0.0-2.25.0 / bare / "PlezTV v…" tags vs
  2.25.13 → update; v2.25.13 vs 2.25.13 → no update; v1.0.0-2.25.0 vs
  1.0.0-2.25.0 → no update; v1.0.1-2.25.0 and v1.0.0-2.25.1 vs
  1.0.0-2.25.0 → update; bare v2.25.14 vs 1.0.0-2.25.0 → no update).
- `test/services/iptv/`: **228/228** (final run; see the flake note
  below).
- `test/screens/livetv/`: **102/102**.
- `flutter analyze`: **49** (pre-existing wakelock_plus baseline, no
  new issues).
- Full suite NOT run — the independent tester does that.
- Version confirmed: pubspec reads `1.0.0-2.25.0+171`; changelog2264
  resolves in the generated strings; About entry added.

Flake note (for the tester): the services/iptv directory runs showed
moving intermittent failures before settling green — all in the
fire-and-forget-write vs temp-dir-delete family, all passing alone:
the catalog-cache tearDown race (fixed test-side, see above), D4's
tearDown (guarded, see above), and the EPG "Clear guide deletes the
persisted files" test (failed in 2 of 4 directory runs, passes alone
21/21 and in the final 228/228 run; EPG code untouched by this build).
Same family as build #17's documented full-suite load flakes.

## UNPROVEN (stays marked so)

- The exact write event on Matt's phone (which crawl, when, what the
  panel returned); whether the panel returns `[]` for unfiltered
  get_series intermittently (transient empty / throttling — the 884
  seen in earlier probes; the parent probe got 46,527 rows).
- Whether EN / category 1219 is hidden in Matt's migrated state (no
  longer matters for this bug — the heal sweeps unrepresented
  categories regardless — but the Last search screenshot would still
  settle it).
- Keystroke/cancellation mechanics end-to-end (no widget probe driving
  real keystrokes).
- Everything outside series search. The mini-player, catch-up, EPG,
  categories and all other v2.25.13 phone checks are untouched by this
  build.

## Phone-verification checklist (Matt)

1. Search "game of thrones" scoped to Trex — Series AND unscoped:
   Trex — Series finds "EN - Game Of Thrones (2011)".
2. Settings → IPTV → Last search → Series line: `loadRows` ≈ 46,527
   (or the new `(source)` note) — and the row now shows hidden
   matches.
3. The first search after the update may take a few seconds if the
   warm-path sweep fallback runs — that is the heal happening, not a
   regression.
4. Settings → About shows **1.0.0-2.25.0** at the top of the
   changelog, with the series-search entry.
5. The in-app updater (Settings → App updates → Check for updates)
   on a 2.25.13 install offers 1.0.0-2.25.0 — this is the first build
   on the new scheme, so the updater path matters as much as the fix.
