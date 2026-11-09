// RESEARCH PROBES — PlezTV build #19 (scoped search leaks a Plex movie).
//
// THE PHONE FAILURE (v1.0.0-2.25.0, 2026-11-09 ~03:48 EST, screenshot
// ~/workspace/user/files/9642_1_xhrd.jpg):
//   * Search screen, query "game of" (PARTIAL — still typing), scope chip
//     "Trex — Series" SELECTED (white/active).
//   * The ONLY result is "Sherlock Holmes: A Game of Shadows" — PG-13,
//     2011 — sourced "HOME PC · Movies". A PLEX MOVIE under a Trex —
//     Series scope. No Trex series rows at all.
//   * Matt: "Now the trex tab is searching my plex movies."
//   * This is DIFFERENT from v2.25.13 (which returned plain "No results
//     in Trex — Series"). Build #18's 7/7 probes passed in-harness but
//     never modeled a Plex server alongside Trex — that is the gap these
//     probes close.
//
// WHAT THE TRACE ALREADY PROVED (code, not guesses — see
// RESEARCH_BUILD19.md for the full walk):
//   * The screenshot is a COMPLETED scoped search, not a stale list:
//     SearchScreen renders a spinner while isSearching, so a finished
//     screen with exactly one row means the scoped search returned
//     exactly [Sherlock Holmes]. Suspect (c) (stale list) is DEAD as the
//     screenshot's explanation.
//   * Scope is enforced in TWO places, and BOTH have a hole:
//     (1) DataAggregationService._withoutHiddenLibraries drops rows whose
//         libraryGlobalKey is hidden — but KEEPS rows with a null
//         libraryGlobalKey BY DESIGN ("Plex search and /library/shared/all
//         return shared and external rows that have no local section").
//         PlexClient.searchItems IGNORES excludedLibraryIds entirely
//         (plex_client.dart:4380: "every row carries its librarySectionID,
//         so the caller filters hidden libraries out") — so a Plex row
//         that carries NO section id is filtered by NOBODY: Plex does not
//         scope it server-side (its own comment says /library/search has
//         no section-scoping parameter) and the caller keeps it because
//         it cannot attribute it. That is the leak path P2 proves.
//     (2) The scope itself is built from LibrariesProvider.libraries ONLY
//         (search_screen.dart:145-186): hiddenKeys = every loaded
//         library's globalKey except the scope. If the Plex libraries are
//         NOT in that list (fetch failed / stale / not yet loaded), the
//         Plex Movies key is never hidden and an ATTRIBUTED Plex row leaks
//         through the post-filter untouched. That is the leak path P3
//         proves. The scope strip in the screenshot shows Trex chips
//         first, consistent with Plex libraries absent (or merely
//         ordered after Trex — ordering is not decidable from code).
//   * The series leg is a SEPARATE, second failure: the Trex series leg
//     returned nothing. Build #18's heal (warm 0-match -> sweep
//     categories missing from the disk list) is proven in-harness at
//     zero latency, but the sweep must reach category 1219 (LAST of 237)
//     inside a 45 s deadline, and on the real phone every per-category
//     call is a real round trip. P4 measures that threshold.
//   * LIVE-PANEL UPDATE (parent, 2026-11-09 ~04:0x EST — redacted
//     findings only, no credentials here): the panel is currently
//     DEGRADED for series — unfiltered get_series returns only 635 rows
//     (all Netflix), GoT NOT among them, category 1219 returns 0 rows
//     per-category. VOD (200,010) and live (55,164) are FULL. Same call
//     returned 46,527 series with GoT on 2026-11-08, so this is a
//     current partial outage, not a stable fact. The first live run also
//     got transient HTTP 400s on every panel call, then 200s minutes
//     later — the panel is flaky right now. CONSEQUENCES for this file:
//     - P6 pins the degraded-panel shape: while the panel has no GoT,
//       no app-side fix can find it — the series-empty half is
//       panel-confounded RIGHT NOW and live-panel series validation is
//       BLOCKED until the series count recovers to ~46k.
//     - P5a/P5b pin a NEW app-side gap the degradation exposes:
//       _loadSeries() treats ANY non-empty unfiltered response as
//       complete, so a PARTIAL 635-row list is persisted to disk as the
//       catalog (build #18 only guards crawl-shaped writes). A partial
//       write poisons the disk for the 24 h TTL even after the panel
//       recovers — and the heal never repairs the disk, so every search
//       must heal again (and a disk-only read finds nothing).
//     - The scoped Plex leak (P2/P3) is a real app-side bug REGARDLESS
//       of panel state. That is build #19's primary target.
//
// These probes FAIL on 967cad6da (P2, P2b, P3, P4-slow, P5a, P5b) and are
// the proof the build #19 fix has to turn green. P1, P4-fast, P6, P7 are
// controls that PASS on base.
//
// BUILD #19 FIX NOTE (builder): the scoped probes (P1/P2/P2b/P3) now
// pass scopedLibraryKey exactly as performSearchQuery does — the scope
// key is the fix, so a probe that withheld it would still fail by
// design. The ORIGINAL probe (hiddenKeys only) was run on base first
// and confirmed 4 pass / 6 fail; it is preserved in the research
// worktree (~/workspace/tmp_work/plezy-tv-research19/repo) for the
// tester to re-run failing-first.
//
// Fidelity notes:
//   * Trex scale: 46,527 series rows / 237 categories, GoT category
//     "|EN| TOP SERIES" (id 1219) LAST, 110 rows; 199,762 VOD; 55,164 live.
//   * Plex "HOME PC": Movies (id 1) + TV Shows (id 2). The Plex fake
//     models the REAL PlexClient.searchItems contract: it accepts
//     excludedLibraryIds and IGNORES it, returning rows unfiltered.
//   * Partial query "game of" throughout, as in the screenshot.
//   * Disk cache seeded exactly as v1.0.0-2.25.0 writes it (via
//     IptvCatalogDiskCache.debugDirectoryProvider); Matt's migrated
//     state is modeled by the hidden-initials parameter (EN visible).
//   * No login, no live panel: fakes only.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_person.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/search_hit.dart';
import 'package:plezy/services/data_aggregation_service.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/media_server_http_client.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/prefs.dart';

// Redaction-safe test password (never a real credential).
const testPassword = 'pa' 'ss';

const _gotSeriesId = 219;
const _gotCategoryId = '1219';
const _gotCategoryName = '|EN| TOP SERIES';
const _gotName = 'EN - Game Of Thrones (2011)';
const _sherlockTitle = 'Sherlock Holmes: A Game of Shadows';

/// The 12 region prefixes the fake's 236 filler categories cycle through.
const _regions = [
  'EN',
  'FR',
  'DE',
  'AR',
  'ES',
  'IT',
  'NL',
  'PL',
  'PT',
  'TR',
  'HI',
  'UR',
];

/// Full Trex-scale series catalog: 46,527 rows.
/// GoT (series_id 219) in category 1219, which holds 110 rows total;
/// the other 46,417 rows spread over categories 1..236.
List<XtreamSeries> allSeriesRows() {
  final rows = <XtreamSeries>[
    const XtreamSeries(seriesId: _gotSeriesId, name: _gotName, categoryId: _gotCategoryId),
  ];
  for (var i = 0; i < 109; i++) {
    rows.add(XtreamSeries(seriesId: 20000 + i, name: 'Top Series Filler $i', categoryId: _gotCategoryId));
  }
  for (var i = 0; i < 46417; i++) {
    rows.add(
      XtreamSeries(
        seriesId: 100000 + i,
        name: 'Filler Series $i',
        categoryId: '${(i % 236) + 1}',
      ),
    );
  }
  return rows;
}

/// Exactly what _loadSeries()'s per-category crawl writes to disk when
/// category 1219 was hidden: every row EXCEPT the 110 in 1219 (46,417).
List<XtreamSeries> crawlShapedSeriesRows() =>
    allSeriesRows().where((r) => r.categoryId != _gotCategoryId).toList();

/// The panel's CURRENT degraded shape (parent live probe, 2026-11-09):
/// unfiltered get_series returns only 635 rows, all Netflix titles.
/// GoT is not among them. Category ids 9001..9005 are the Netflix buckets.
List<XtreamSeries> netflixOnlySeriesRows() => [
  for (var i = 0; i < 635; i++)
    XtreamSeries(seriesId: 500000 + i, name: 'Netflix Series $i', categoryId: '${9001 + (i % 5)}'),
];

/// 237 series categories, 1219 LAST. Filler categories cycle the 12 regions.
/// Netflix buckets (9001..9005) are appended only when the fake runs in
/// degraded-panel mode, so P4's sweep batch counts stay at 237.
List<XtreamCategory> seriesCategories({bool includeNetflix = false}) {
  final cats = <XtreamCategory>[
    for (var i = 1; i <= 236; i++)
      XtreamCategory(id: '$i', name: '|${_regions[(i - 1) % _regions.length]}| Series $i'),
  ];
  cats.add(const XtreamCategory(id: _gotCategoryId, name: _gotCategoryName));
  if (includeNetflix) {
    for (var i = 1; i <= 5; i++) {
      cats.add(XtreamCategory(id: '${9000 + i}', name: 'NETFLIX Series $i'));
    }
  }
  return cats;
}

Map<String, List<XtreamSeries>> seriesByCategory() {
  final map = <String, List<XtreamSeries>>{};
  for (final row in allSeriesRows()) {
    (map[row.categoryId ?? ''] ??= <XtreamSeries>[]).add(row);
  }
  return map;
}

/// Fake panel. Modes (all default to the HEALTHY panel):
/// [unfilteredSeriesOverride] — unfiltered returns these rows instead of
///   the full list (P5/P6: the 635-row partial list).
/// [unfilteredSeriesThrows] — unfiltered throws (P7: transient HTTP 400).
/// [category1219Empty] — per-category 1219 returns [] (P6: degraded panel).
/// [perCallDelay] — delay on every per-category getSeries call (P4: the
///   real phone pays a round trip per call; the zero-latency harness does not).
/// [includeNetflixCategories] — category list gains the Netflix buckets.
class _Build19FakeApi extends XtreamApi {
  _Build19FakeApi({
    this.unfilteredSeriesOverride,
    this.unfilteredSeriesThrows = false,
    this.category1219Empty = false,
    this.perCallDelay = Duration.zero,
    this.includeNetflixCategories = false,
  }) : super(
         serverUrl: 'https://panel.example.com:8080',
         username: 'user',
         password: testPassword,
       );

  final List<XtreamSeries>? unfilteredSeriesOverride;
  final bool unfilteredSeriesThrows;
  final bool category1219Empty;
  final Duration perCallDelay;
  final bool includeNetflixCategories;
  int unfilteredSeriesCalls = 0;
  int perCategorySeriesCalls = 0;

  final Map<String, List<XtreamSeries>> _buckets = seriesByCategory();

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async =>
      seriesCategories(includeNetflix: includeNetflixCategories);

  @override
  Future<List<XtreamCategory>> getVodCategories() async =>
      [const XtreamCategory(id: '1', name: 'Movies')];

  @override
  Future<List<XtreamCategory>> getLiveCategories() async =>
      [const XtreamCategory(id: '1', name: 'Live')];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    if (categoryId == null) {
      unfilteredSeriesCalls++;
      if (unfilteredSeriesThrows) throw Exception('HTTP 400');
      final rows = unfilteredSeriesOverride ?? allSeriesRows();
      lastSeriesBody = jsonEncode(rows.map((r) => r.toJson()).toList());
      return rows;
    }
    perCategorySeriesCalls++;
    lastSeriesBody = null; // A per-category body is never the full catalog.
    if (perCallDelay > Duration.zero) await Future.delayed(perCallDelay);
    if (category1219Empty && categoryId == _gotCategoryId) {
      return const <XtreamSeries>[];
    }
    return _buckets[categoryId] ?? const <XtreamSeries>[];
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => [
    const XtreamVodStream(
      streamId: 1,
      name: 'NF - Game of Thrones: A Day in...',
      categoryId: '1',
    ),
  ];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => [
    const XtreamLiveStream(streamId: 1, name: 'EN| GAME OF THRONES 4K', categoryId: '1'),
    const XtreamLiveStream(streamId: 2, name: 'EN| GAME OF THRONES 4K +1', categoryId: '1'),
  ];
}

IptvClient clientWith({XtreamApi? api, List<String> hiddenInitials = const []}) {
  final connection = XtreamConnection(
    id: 'conn-xt-1',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    hiddenCategoryInitials: hiddenInitials,
    createdAt: DateTime.utc(2026, 11, 5),
  );
  final client = IptvClient.forConnection(connection);
  client.testXtreamApi = api ?? _Build19FakeApi();
  return client;
}

/// Warm the series catalog exactly as the phone does: the bind warm-up
/// reads the disk copy, so by the time the user reaches Search the leg is
/// warm. warmUpSeriesCatalog() is fire-and-forget, so a throwaway search
/// is the public-API way to wait for the shared load to land.
Future<void> warmSeries(IptvClient client) async {
  client.warmUpSeriesCatalog();
  await client.searchItems('zz-no-match-zz');
}

/// Warm WITHOUT triggering the heal: the throwaway query matches rows in
/// the seeded disk file, so the warm filter returns matches and the
/// 0-match sweep never fires. (P4: the asserted search must be the one
/// that pays the sweep, or the warm-up eats the budget first.)
Future<void> warmSeriesNoHeal(IptvClient client) async {
  client.warmUpSeriesCatalog();
  await client.searchItems('Filler Series 0');
}

Future<List<XtreamSeries>> readDiskSeriesRows() async {
  final hit = await IptvCatalogDiskCache().read(
    'conn-xt-1',
    IptvCatalogDiskCache.seriesDataset,
  );
  if (hit == null) return const <XtreamSeries>[];
  final decoded = jsonDecode(hit.body) as List<dynamic>;
  return decoded.map((e) => XtreamSeries.fromJson(e as Map<String, dynamic>)).toList();
}

/// Make the seeded disk file STALE (older than the 24 h TTL) by pushing
/// its mtime back, so the next warm-up triggers the background refresh.
Future<void> makeDiskSeriesStale() async {
  final tempDir = await IptvCatalogDiskCache.debugDirectoryProvider!();
  final files = await tempDir
      .list(recursive: true)
      .where((e) => e.path.endsWith('/series.json'))
      .toList();
  expect(files, hasLength(1));
  await (files.single as File).setLastModified(
    DateTime.now().subtract(const Duration(hours: 25)),
  );
}

/// Poll until the disk series file's row count changes from [fromCount]
/// (the background refresh landing) or the timeout expires. A mid-write
/// read (empty / truncated body — the write is fire-and-forget) is not a
/// failure, just "not landed yet": keep polling.
Future<List<XtreamSeries>> waitForDiskSeriesChange(
  int fromCount, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      final rows = await readDiskSeriesRows();
      if (rows.length != fromCount) return rows;
    } on FormatException {
      // Mid-write read — the file is being replaced; poll again.
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return readDiskSeriesRows();
}

// ---------------------------------------------------------------------------
// Plex side: "HOME PC" with Movies (id 1) + TV Shows (id 2).
// ---------------------------------------------------------------------------

/// Global keys, exactly as buildGlobalKey(serverId, libraryId) builds them.
const _plexMoviesKey = 'plex:1';
const _plexTvKey = 'plex:2';
const _trexMoviesKey = 'conn-xt-1:iptv:conn-xt-1:movies';

/// The Trex — Series library's global key, exactly as the scope chip
/// passes it (buildGlobalKey('conn-xt-1', 'iptv:conn-xt-1:series')).
/// Build #19: the scope is conveyed EXPLICITLY to the aggregation via
/// [DataAggregationService.searchAcrossServers]' scopedLibraryKey —
/// hiddenKeys alone cannot enforce it. P3 is unsatisfiable from
/// hiddenKeys: it is structurally identical, from the aggregation's
/// perspective, to a two-server unscoped hide, and bridge test :724 pins
/// that a single hide keeps unattributed rows — so no hiddenKeys-only
/// rule can satisfy P3 + :724 + the unscoped hide together. The scope
/// key is what closes both holes; these probes pass it exactly as
/// performSearchQuery does.
const _trexSeriesKey = 'conn-xt-1:iptv:conn-xt-1:series';

/// The hiddenKeys a Trex — Series scope builds when the provider list is
/// COMPLETE: every loaded library except the scope.
const _scopeTrexSeriesHiddenKeys = {_plexMoviesKey, _plexTvKey, _trexMoviesKey};

/// The Sherlock row as the REAL Plex client returns it: a local movie in
/// the Movies library, WITH its librarySectionID — the post-filter drops it.
MediaItem _sherlockAttributed() => testMediaItem(
  id: 'sherlock-1',
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  title: _sherlockTitle,
  year: 2011,
  serverId: 'plex',
  serverName: 'HOME PC',
  libraryId: '1',
  libraryTitle: 'Movies',
);

/// The Sherlock row as an EXTERNAL / shared row: /library/search with
/// includeExternalMedia=1 returns rows that carry NO librarySectionID.
/// The screenshot's card renders "HOME PC · Movies", which is the
/// libraryTitle the row carries — a title WITHOUT a section id is the
/// shape the label evidence points at. (P2b covers the no-title variant.)
MediaItem _sherlockUnattributed() => testMediaItem(
  id: 'sherlock-ext-1',
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  title: _sherlockTitle,
  year: 2011,
  serverId: 'plex',
  serverName: 'HOME PC',
  libraryTitle: 'Movies',
);

/// Same as [_sherlockUnattributed] but with no libraryTitle either — the
/// purest external-row shape.
MediaItem _sherlockUnattributedNoTitle() => testMediaItem(
  id: 'sherlock-ext-2',
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  title: _sherlockTitle,
  year: 2011,
  serverId: 'plex',
  serverName: 'HOME PC',
);

/// Models the REAL PlexClient.searchItems (plex_client.dart:4380):
/// excludedLibraryIds is accepted and IGNORED — "/library/search has no
/// section-scoping parameter" — and the rows are returned unfiltered.
/// The aggregation's post-filter is then the ONLY thing standing between
/// a Plex row and a Trex-scoped search.
class _PlexLikeFakeClient implements MediaServerClient {
  _PlexLikeFakeClient({required this.searchResults});

  @override
  final ServerId serverId = ServerId('plex');
  @override
  final String serverName = 'HOME PC';
  @override
  MediaBackend get backend => MediaBackend.plex;

  final List<MediaItem> searchResults;
  Set<String>? lastExcludedLibraryIds;

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    lastExcludedLibraryIds = excludedLibraryIds;
    return searchResults;
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async => const [];

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => const [];

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<String> _hitTitles(SearchAggregationResult result) => [
  for (final hit in result.hits)
    if (hit is MediaSearchHit) hit.item.title ?? '',
];

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build19_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('build19: scoped Trex — Series search leaks a Plex movie', () {
    late AppDatabase db;
    late MultiServerManager manager;
    late DataAggregationService service;

    setUp(() {
      SettingsService.resetForTesting();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      PlexApiCache.initialize(db);
      JellyfinApiCache.initialize(db);
      manager = MultiServerManager();
      service = DataAggregationService(manager);
    });

    tearDown(() async {
      manager.dispose();
      await db.close();
    });

    /// Seeds the COMPLETE series disk file and warms the Trex client, so
    /// the series leg is warm and fast — the leak probes are about scope,
    /// not about the catalog.
    Future<IptvClient> warmedTrex() async {
      final cache = IptvCatalogDiskCache();
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(allSeriesRows().map((r) => r.toJson()).toList()),
      );
      final trex = clientWith(api: _Build19FakeApi());
      await warmSeries(trex);
      return trex;
    }

    test('P1 (control): attributed Plex row is dropped under a Trex — Series scope', () async {
      final trex = await warmedTrex();
      final plex = _PlexLikeFakeClient(searchResults: [_sherlockAttributed()]);
      manager.debugRegisterClientForTesting(trex);
      manager.debugRegisterClientForTesting(plex);

      final result = await service.searchAcrossServers(
        'game of',
        hiddenLibraryKeys: _scopeTrexSeriesHiddenKeys,
        scopedLibraryKey: _trexSeriesKey,
      );
      // ignore: avoid_print
      print(
        'BUILD19-P1 scoped: titles=${_hitTitles(result)} '
        'plexExcluded=${plex.lastExcludedLibraryIds}',
      );
      // The aggregation DID pass the Plex exclusions (its part is correct).
      expect(plex.lastExcludedLibraryIds, {'1', '2'});
      // And the attributed row is dropped by the post-filter.
      expect(_hitTitles(result), [_gotName]);
    });

    test('P2: unattributed Plex row (external/shared shape) leaks under a Trex — Series scope', () async {
      final trex = await warmedTrex();
      final plex = _PlexLikeFakeClient(searchResults: [_sherlockUnattributed()]);
      manager.debugRegisterClientForTesting(trex);
      manager.debugRegisterClientForTesting(plex);

      final result = await service.searchAcrossServers(
        'game of',
        hiddenLibraryKeys: _scopeTrexSeriesHiddenKeys,
        scopedLibraryKey: _trexSeriesKey,
      );
      // ignore: avoid_print
      print(
        'BUILD19-P2 scoped: titles=${_hitTitles(result)} '
        'plexExcluded=${plex.lastExcludedLibraryIds}',
      );
      expect(plex.lastExcludedLibraryIds, {'1', '2'});
      // Build #19: the explicit scope key drops the unattributed row —
      // Plex ignores excludedLibraryIds (no server-side scoping) and
      // the hidden-library filter keeps unattributed rows by design, so
      // only the scope key stands between a Plex movie and a Trex —
      // Series scope. The phone's exact failure: Sherlock Holmes under
      // "Trex — Series".
      expect(_hitTitles(result), [_gotName]);
    });

    test('P2b: unattributed Plex row with no libraryTitle leaks the same way', () async {
      final trex = await warmedTrex();
      final plex = _PlexLikeFakeClient(searchResults: [_sherlockUnattributedNoTitle()]);
      manager.debugRegisterClientForTesting(trex);
      manager.debugRegisterClientForTesting(plex);

      final result = await service.searchAcrossServers(
        'game of',
        hiddenLibraryKeys: _scopeTrexSeriesHiddenKeys,
        scopedLibraryKey: _trexSeriesKey,
      );
      // ignore: avoid_print
      print('BUILD19-P2b scoped: titles=${_hitTitles(result)}');
      // Build #19: same leak with the purest external-row shape — the
      // libraryTitle is not what saves it; the missing section id is.
      // The scope key drops it regardless of attribution.
      expect(_hitTitles(result), [_gotName]);
    });

    test('P3: Plex libraries missing from the provider list leak an ATTRIBUTED row', () async {
      final trex = await warmedTrex();
      final plex = _PlexLikeFakeClient(searchResults: [_sherlockAttributed()]);
      manager.debugRegisterClientForTesting(trex);
      manager.debugRegisterClientForTesting(plex);

      // The scope code (search_screen.dart) builds hiddenKeys from
      // LibrariesProvider.libraries ONLY. Model the Plex libraries being
      // absent from that list (fetch failed / stale / not yet loaded):
      // hiddenKeys then contains just the Trex Movies key.
      final result = await service.searchAcrossServers(
        'game of',
        hiddenLibraryKeys: {_trexMoviesKey},
        scopedLibraryKey: _trexSeriesKey,
      );
      // ignore: avoid_print
      print(
        'BUILD19-P3 scoped: titles=${_hitTitles(result)} '
        'plexExcluded=${plex.lastExcludedLibraryIds}',
      );
      // The aggregation was never even told to exclude Plex.
      expect(plex.lastExcludedLibraryIds, isEmpty);
      // Build #19: the attributed Plex movie used to survive the scope
      // because its library was never in hiddenKeys — the scope's
      // correctness depended on the provider list being complete, and
      // the aggregation had no backstop when it was not. The explicit
      // scope key is that backstop: it drops every row not attributable
      // to Trex — Series, whatever hiddenKeys contains.
      expect(_hitTitles(result), [_gotName]);
    });
  });

  group('build19: Trex series leg — heal timing + partial-list persistence', () {
    test('P4-fast (control): heal reaches 1219 when the sweep fits the 45 s deadline', () async {
      // Disk holds rows from categories 1..5 only, so the heal must sweep
      // the other 232 categories (1219 last) to find GoT.
      final cache = IptvCatalogDiskCache();
      final seed = allSeriesRows()
          .where((r) => {'1', '2', '3', '4', '5'}.contains(r.categoryId))
          .toList();
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(seed.map((r) => r.toJson()).toList()),
      );
      final client = clientWith(api: _Build19FakeApi(perCallDelay: const Duration(seconds: 1)));
      try {
        await warmSeriesNoHeal(client);
        final results = await client.searchItems('game of thrones');
        final diag = client.lastSearchDiagnostics!;
        // ignore: avoid_print
        print(
          'BUILD19-P4-fast: titles=${results.map((i) => i.title).toList()} '
          'series loadRows=${diag.series.loadRows} sweepMatches=${diag.series.sweepMatches} '
          'ms=${diag.series.ms}',
        );
        expect(diag.series.loadRows, seed.length);
        expect(results.map((i) => i.title), contains(_gotName));
      } finally {
        client.close();
      }
    });

    test(
      'P4-slow: heal MISSES 1219 when per-call latency pushes the sweep past the 45 s deadline',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        final cache = IptvCatalogDiskCache();
        final seed = allSeriesRows()
            .where((r) => {'1', '2', '3', '4', '5'}.contains(r.categoryId))
            .toList();
        await cache.write(
          'conn-xt-1',
          IptvCatalogDiskCache.seriesDataset,
          jsonEncode(seed.map((r) => r.toJson()).toList()),
        );
        final api = _Build19FakeApi(perCallDelay: const Duration(seconds: 6));
        final client = clientWith(api: api);
        try {
          await warmSeriesNoHeal(client);
          final results = await client.searchItems('game of thrones');
          final diag = client.lastSearchDiagnostics!;
          // ignore: avoid_print
          print(
            'BUILD19-P4-slow: titles=${results.map((i) => i.title).toList()} '
            'series loadRows=${diag.series.loadRows} sweepMatches=${diag.series.sweepMatches} '
            'ms=${diag.series.ms} perCategoryCalls=${api.perCategorySeriesCalls}',
          );
          // FAILING-FIRST: 232 categories / 32 per batch = 8 batches;
          // 8 x 6 s = 48 s > the 45 s sweep deadline, so the last batch
          // (holding 1219) times out and GoT is never appended. The
          // zero-latency harness always passes; the real phone pays a
          // round trip per call. The threshold is what matters, not the
          // exact 6 s: any per-call latency above ~5.6 s breaks the heal
          // for a worst-case wanted set — and a throttled panel serialises
          // the batch the same way.
          expect(results.map((i) => i.title), contains(_gotName));
        } finally {
          client.close();
        }
      },
    );

    test('P5a: a PARTIAL unfiltered list must not overwrite a larger good disk file', () async {
      // The panel's current degraded shape: unfiltered returns 635 rows.
      final cache = IptvCatalogDiskCache();
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(allSeriesRows().map((r) => r.toJson()).toList()),
      );
      await makeDiskSeriesStale();
      final api = _Build19FakeApi(
        unfilteredSeriesOverride: netflixOnlySeriesRows(),
        includeNetflixCategories: true,
      );
      final client = clientWith(api: api);
      try {
        await warmSeries(client);
        // The stale disk triggers a background refresh; the refresh's
        // unfiltered call returns the 635-row partial list.
        final diskRows = await waitForDiskSeriesChange(46527);
        // ignore: avoid_print
        print(
          'BUILD19-P5a: disk rows after refresh=${diskRows.length} '
          'hasGoT=${diskRows.any((r) => r.seriesId == _gotSeriesId)} '
          'unfilteredCalls=${api.unfilteredSeriesCalls}',
        );
        expect(api.unfilteredSeriesCalls, greaterThan(0));
        // FAILING-FIRST: _loadSeries() treats ANY non-empty unfiltered
        // response as complete, so the 635-row partial list overwrites
        // the 46,527-row good file — poisoning the disk for the 24 h TTL
        // even after the panel recovers. Build #18 only guards
        // crawl-shaped writes, not partial unfiltered ones.
        expect(diskRows.length, 46527);
        expect(diskRows.any((r) => r.seriesId == _gotSeriesId), isTrue);
      } finally {
        client.close();
      }
    });

    test('P5b: a healing search must repair the disk, not just the one result', () async {
      // Poisoned disk (build #18 D3 shape): 46,417 rows, no 1219.
      final cache = IptvCatalogDiskCache();
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(crawlShapedSeriesRows().map((r) => r.toJson()).toList()),
      );
      final client = clientWith(api: _Build19FakeApi());
      try {
        await warmSeries(client);
        final results = await client.searchItems('game of thrones');
        // The heal itself works on base (build #18): GoT is found.
        expect(results.map((i) => i.title), contains(_gotName));
        // But the disk is untouched — the heal only appends matches to
        // the returned list, it never persists the swept rows.
        final diskRows = await readDiskSeriesRows();
        // ignore: avoid_print
        print(
          'BUILD19-P5b: after healing search, disk rows=${diskRows.length} '
          'hasGoT=${diskRows.any((r) => r.seriesId == _gotSeriesId)}',
        );
        // FAILING-FIRST: the next search (or a disk-only read) must heal
        // all over again, and a disk-only read finds nothing at all.
        // The fix repairs the disk when a search heals it.
        expect(diskRows.any((r) => r.seriesId == _gotSeriesId), isTrue);
      } finally {
        client.close();
      }
    });

    test('P6 (control): while the panel is degraded, the series leg is CORRECTLY empty', () async {
      // The parent's live probe (2026-11-09): unfiltered returns 635
      // Netflix rows, category 1219 returns 0 rows. No app-side fix can
      // find GoT while the panel has no GoT — this pins that dependency
      // so a future live-panel validation does not blame the app.
      final client = clientWith(
        api: _Build19FakeApi(
          unfilteredSeriesOverride: netflixOnlySeriesRows(),
          category1219Empty: true,
          includeNetflixCategories: true,
        ),
      );
      try {
        final results = await client.searchItems('game of thrones');
        final diag = client.lastSearchDiagnostics!;
        // ignore: avoid_print
        print(
          'BUILD19-P6 degraded panel: titles=${results.map((i) => i.title).toList()} '
          'series loadRows=${diag.series.loadRows}',
        );
        expect(results.map((i) => i.title), isNot(contains(_gotName)));
        // The other legs still work — the search as a whole is healthy.
        expect(results.where((i) => (i.title ?? '').contains('A Day in')).length, 1);
        expect(results.where((i) => (i.title ?? '').contains('GAME OF THRONES 4K')).length, 2);
      } finally {
        client.close();
      }
    });

    test('P7 (control): a transient 400 on the unfiltered call degrades to the sweep, not a throw', () async {
      // The parent's live probe also saw transient HTTP 400s on every
      // panel call, then 200s minutes later. The cold path catches the
      // load error and falls back to the per-category sweep.
      final client = clientWith(api: _Build19FakeApi(unfilteredSeriesThrows: true));
      try {
        final results = await client.searchItems('game of thrones');
        // ignore: avoid_print
        print('BUILD19-P7 400 on unfiltered: titles=${results.map((i) => i.title).toList()}');
        expect(results.map((i) => i.title), contains(_gotName));
      } finally {
        client.close();
      }
    });
  });
}
