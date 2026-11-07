# PlezTV Build #10 Diagnosis — series search STILL broken on v2.25.5

Diagnosis only. No fix, no commit, no version bump, no build.

> **Build #10 note (2026-11-06): the (h) fix in this doc is SUPERSEDED by
> the category-initials redesign** — "Name initials" became "Category
> initials" (the initial comes from the category name, not item names;
> see `IPTV_BUILD10_NOTES.md`). Matt also turned ALL initials back on
> and search STILL failed, so (h) is ruled out for search regardless.
> The fix that landed instead: search races the unfiltered catalog that
> Recommended proves works against the per-category sweep, with the T1/T3
> timing fixes, plus a startup warm-up and on-device diagnostics. The H1
> characterization test was flipped to the new behaviour in
> `test/services/iptv/iptv_build10_diagnosis_test.dart` (its header
> carries the same note). The rest of this doc — the (g) analysis, the
> timing shapes, the killed hypotheses — still stands as the diagnosis
> the fix was built from.

## The report (Matt, 2026-11-06)

1. **Series/TV search is still broken** on v2.25.5 (version confirmed by
   Matt — the stale-install hypothesis is dead; both symptoms are real
   v2.25.5 bugs). Third build touching series search: build #8 added
   per-section caps + 50s budgets; build #9 added a cold-catalog
   per-category sweep in batches of 8 returning partial matches. Both
   were proven green by tests. Neither fixed it on his real provider
   (Trex Xtream: 46,461 series, 199,762 movies, 833 categories, LTE).
2. **Second symptom (screenshot `9580_4_f30w.jpg`, 2026-11-06 ~14:31
   EST): TV/Series sub-categories are broken too.** Opening the
   "|EN| UK SERIES" category shows "No items found" — not just search.

## The one-sentence answer

The series catalog itself is almost certainly not loading on his phone —
not the search ranking, not the screen, not the scope. Both symptoms are
the same hole: **the per-category `get_series` calls return nothing (or
never land) on this panel**, so there are no series rows for search to
match OR for a category page to show. The only other joint explanation
is the build #8 initials filter, and only if Matt turned initials off
himself. Everything else in the chain was proven sound by test.

## How the two symptoms share one cause (traced, not guessed)

### Category browse path (the new symptom)

Library → Series → Categories tab → tap "|EN| UK SERIES" →
`LibraryCategoriesTab._openCategory` → hub detail with
`loadItems: () => client.iptvItemsForCategory(library.id, category.id)`
(`lib/screens/libraries/tabs/library_categories_tab.dart:82`) →
`IptvClient.iptvItemsForCategory` (`lib/media/iptv_client.dart:862`):

```dart
final series = await _seriesList();   // <-- THE FULL CATALOG
return series
    .where((s) =>
        s.categoryId == categoryId &&
        !_isDisabled(s.categoryId) &&
        !_isDisabledInitial(s.name))
    ...
```

Three facts that pin the failure down:

- The category **lists**, so `get_series_categories` works on his phone.
  The category list is not the problem.
- The hub detail screen awaits `loader()` with **no timeout** — it
  shows a spinner until the future completes. "No items found" is the
  EMPTY state, so `_seriesList()` **completed** with zero rows matching
  that category id (after the disabled/initials filters). It did not
  time out and it did not error.
- The contents are filtered **client-side from the full catalog** — the
  code never calls `get_series(categoryId)` for the drill-down. So an
  empty category means the full catalog is empty, or no row carries
  that category id, or every row was filtered out.

### Search path (the old symptom)

Search screen → `searchAcrossServers` (60s IPTV leg deadline) →
`IptvClient.searchItems` → `_searchSeries` → cold path kicks the full
load off in the background and sweeps per-category with
`_sweepCatalogCategories` → `_appendSeriesMatches` (substring match on
the raw name) → merged pool (≤200) → `rankSearchHits` caps the ranked
"All" list at 100, but the **uncapped candidate pool feeds the kind
chips** (`search_screen.dart:402-440`).

Downstream of the client, the chain is sound — proven, not assumed:

- The TV Shows chip reads `_searchCandidates` (the uncapped pool), so
  a series the client returned is reachable even when the All-view
  top-100 buries it (test R1 below proves the burial is real for
  generic queries — but the chip rescues it).
- Sections group by library; `sections.length <= 1` renders a flat
  list — a display quirk, not data loss.
- The scope strip defaults to All (null, in-memory, resets when the
  search screen is left). A stale scope can hide series only
  in-session (test S1).
- The client instance is cached per connection
  (`multi_server_manager.dart:196` `_iptvByConnectionId`), so the warm
  catalog persists across searches in a session. The warm path works
  (control test W1).
- The 60s aggregation leg deadline is longer than the 50s section
  budget, so the leg does not cut the series section early.

## Hypothesis verdicts

All verdicts come from the new characterization tests in
`test/services/iptv/iptv_build10_diagnosis_test.dart` (12/12 pass;
full `test/services/iptv/` suite 110/110 with them). Tests marked
DIAGNOSIS assert what the code DOES today under a real-provider shape
— flip the expectation when the fix lands, do not "fix" the test.

### (g) The per-category series fetch returns [] on the real panel — LEADING HYPOTHESIS

- **Test G1 (DIAGNOSIS, passes):** unfiltered `get_series` returns []
  AND every per-category `get_series` returns [] → category browse []
  AND search has no series. **One cause, both symptoms.**
- **Control G2 (passes):** unfiltered [] but per-category returns rows
  → both browse and search work. Proves the per-category calls are the
  load-bearing path when the unfiltered call is empty.
- Why this is the prime suspect: every fix since build #7 assumed the
  per-category calls return rows, and **no test ever modeled them
  returning []**. If the panel's `get_series&category_id=X` returns []
  (or the panel ignores `category_id` and each call downloads the full
  46k rows until the sweep deadline kills it), the series catalog is
  empty and no search-layer fix can ever work. The search work in
  builds #8/#9 was chasing the wrong layer if this holds.
- **Cannot be proven without the panel.** The parent can probe it
  (transient credentials, as on 2026-11-05): `get_series` unfiltered,
  `get_series&category_id=<a real series category id>`,
  `get_series_categories` — what each returns, and how big/slow each
  response is.

### (h) The build #8 initials filter is emptying the category — JOINT EXPLANATION, CONDITIONAL

- **Test H1 (DIAGNOSIS, passes):** every series named "EN - ...",
  EN disabled in settings → category browse [] AND search no series.
  The filter is applied in `_seriesItems`, `iptvItemsForCategory`
  AND the search sweep, so it can produce **both symptoms at once**
  with the catalog loading fine.
- **Conditional on Matt having disabled initials himself.** Default
  `disabledInitials` is `const []` (`connection.dart:409,534`) and the
  only writes are user toggles (settings upsert, edit-screen save) —
  nothing auto-populates it.
- **Why it is the prime REGRESSION suspect:** build #8's initials
  filter is the ONLY browse-affecting change since v2.25.3, when Matt
  reported "Series loads". If series items loaded in v2.25.3, either
  he disabled initials in v2.25.4 testing, or the panel changed, or
  "Series loads" meant only the library/categories list.
- **Quirk that matters for this category:** the initials regex
  `^([A-Z]{2,3})\s*[-|:/]\s*` does NOT match the pipe-first form —
  "|EN| Show" carries NO detected initial, so those items are never
  hidden by the filter. Items named "EN - Show", "EN | Show" or
  "UK | Show" ARE detected. Whether the "|EN| UK SERIES" contents
  are hidden depends on how the provider actually names the shows
  inside it — unknowable from here.
- **One question settles it:** did Matt turn off any initials (EN?
  UK?) in IPTV settings or the Trex edit screen?

### (b) The category list itself is empty/fails — KILLED as the joint cause, ALIVE for search only

- The category **lists** on his phone, so `get_series_categories`
  works. Dead as the joint explanation.
- **But the search-only defect is real and proven. Test T1
  (DIAGNOSIS, passes):** `get_series_categories` takes 600ms of a
  1000ms budget and then throws → `_searchSeries` awaits it once for
  the category NAMES, then **retries it for the sweep** — the second
  fetch is still running when the outer budget fires, so the sweep
  never runs a single per-category call although those calls would
  answer instantly. The log lines in the test run show both failures
  ("series category names unavailable", then "series category list
  unavailable for search sweep"). The names fetch and the sweep fetch
  share no future, and the names fetch runs BEFORE the sweep, eating
  the section budget.

### (c) The sweep deadline fires before any batch lands — PROVEN POSSIBLE for search only

- **Test T2 (DIAGNOSIS, passes):** 24 categories, the only match in
  category 20 (batch 3 of 8), each per-category call 400ms of a 1000ms
  budget → batch 1 lands at 400ms, batch 2 at 800ms, batch 3 would
  land at 1200ms — past both deadlines — so the sweep returns []
  although the match exists on the panel. Control T2b: the same slow
  calls find a match sitting in batch 1.
- **Test T3 (DIAGNOSIS, passes):** a 600ms names fetch plus 250ms
  per-category calls loses a batch-2 match — the **outer section
  budget**, not the sweep's own 90% deadline, is the binding
  constraint, because the names fetch ran before the sweep started.
- Does NOT explain the empty category browse: browse awaits
  `_seriesList()` with no deadline at all. Alive as a search-only
  contributor, and it means the sweep's real-world timing on LTE is
  still unproven even if (g)/(h) are fixed.

### (d) Query matching misses real titles — KILLED as a general cause

- Matching is plain case-insensitive substring on the raw name
  (`_appendSeriesMatches`); prefix stripping is display-only. Only
  exotic cases (accented characters, e.g. "Pokémon" vs "pokemon")
  could miss. Not the shape of "no series at all".

### (e) Aggregation/screen drops the series section — KILLED as the joint cause

- **Test R1 (DIAGNOSIS, passes):** 120 movies "The Movie N" plus one
  series "A Show About The Thing" for query "the" — the series IS cut
  from the ranked top-100 (prefix matches ~914 beat its substring
  ~807), while the uncapped candidate pool still holds it. So the
  All-view burial is real for generic queries — but the TV Shows chip
  reads the candidate pool, so the series stays reachable. (e) cannot
  explain "can't search series at all" while the chip exists.

### (f) Search never reaches the IPTV series leg — KILLED generally

- Scope defaults to All; client is cached; leg deadline (60s) exceeds
  the section budget (50s); the movies leg works on the same path.
  Alive only as the in-session scope trap (**test S1, control**):
  a scope of "Trex — Movies" skips the series section entirely until
  "All libraries" is tapped again.

### (i) Category list vs contents mismatch — PROVEN browse-only, RULED OUT as joint cause

- **Test I1 (DIAGNOSIS, passes):** rows whose `category_id` ('999')
  matches no listed category id ('1') → drill-down [] BUT search
  still finds the show (the sweep matches by name). Explains an empty
  category on its own; does not explain the joint failure.
- Int-vs-string is not it: category ids are stringified on both sides
  (`stringOrEmpty` for categories, `?.toString()` for series rows).
  The live mismatch shape would be rows carrying a category NAME
  instead of an id.

## What the fix must do (specified, NOT implemented)

Do not build until (g) vs (h) is settled — they need different fixes,
and the timing defects are real regardless.

1. **Settle (g) vs (h) first, with one probe or three questions:**
   - Probe the panel (transient credentials): `get_series`
     unfiltered, `get_series&category_id=<real id>`,
     `get_series_categories`. What each returns, row counts, sizes,
     timings. If per-category returns [], the series catalog has no
     source in the current code and the fix is a different data path
     (or an honest empty-catalog state), not another search tweak.
   - Ask Matt: (1) did you turn off any initials (EN? UK?) in IPTV
     settings or the Trex edit screen? (2) does the main TV/Series
     browse page (the full list, not inside a category) show shows,
     or is it empty too? (3) are ALL series categories empty, or just
     "|EN| UK SERIES"?
   - The answers discriminate cleanly: full browse empty + no
     initials disabled → (g). Full browse shows shows + one category
     empty → (i) or (h) for that category. Everything empty + EN/UK
     disabled → (h).
2. **If (h):** the filter must not silently empty a whole category or
   search with a bare "No items found". When a category/search is
   empty SOLELY because of disabled initials/categories, say so on
   screen (and offer to show hidden items). Do not remove the filter
   Matt asked for — make its effect visible.
3. **If (g):** find the real series source on this panel before
   writing code. Do not guess another sweep variant.
4. **Fix the timing defects in the same build regardless (proven by
   tests T1/T3):** (a) do not await `_seriesCategoryNames()` before
   the sweep — fetch names concurrently with the sweep (they are only
   needed for display prefix-stripping); (b) do not re-fetch the
   category list on failure — share one future/result between the
   names lookup and the sweep; (c) measure the sweep deadline from
   section start, not sweep start, so pre-sweep work cannot silently
   eat it.
5. **Lower priority:** the All-view rank cap (R1) should guarantee
   per-section representation so a generic query cannot push all
   series out of the ranked top-100.
6. **Instrumentation (recommended):** the next build should log or
   surface the series catalog state on-device — unfiltered row count,
   per-category row counts, disabled-initials count — so Matt's phone
   can settle (g) vs (h) from one screenshot instead of another
   round of guessing. (Blind-device-diagnostics pattern: instrument
   the app to report its own verdict.)

## What could NOT be proven without the real provider

- Whether `get_series` / `get_series&category_id` return [] on Trex (g).
- Whether Matt disabled any initials (h).
- Whether the full Series browse shows shows on his phone.
- Per-category call latency on LTE, and how many series categories
  there are / their order (both decide sweep coverage under (c)).
- Whether the panel changed server-side between v2.25.3 ("Series
  loads") and v2.25.5.

## Evidence files

- `test/services/iptv/iptv_build10_diagnosis_test.dart` — 12
  characterization tests (12/12 pass; full
  `test/services/iptv/` suite 110/110 with them). No other file was
  modified; nothing committed.
- Key code read: `lib/media/iptv_client.dart` (`searchItems`,
  `_searchSeries`, `_sweepCatalogCategories`, `_seriesList`,
  `_loadSeries`, `iptvItemsForCategory`, `_isDisabledInitial`),
  `lib/services/iptv/xtream_api.dart` (`getSeries`,
  `getSeriesCategories`, `_asObjectList`, `XtreamSeries.fromJson`,
  `XtreamCategory.fromJson`), `lib/utils/iptv_initials.dart`
  (`initialOf`, `detectInitial`), `lib/screens/search_screen.dart`
  (scope, chips, sections), `lib/services/data_aggregation_service.dart`
  (`searchAcrossServers`, `rankSearchHits` cap),
  `lib/utils/search_relevance.dart` (`rankSearchHits`),
  `lib/screens/libraries/tabs/library_categories_tab.dart:82`,
  `lib/screens/hub_detail_screen.dart` (no timeout on `loadItems`).
