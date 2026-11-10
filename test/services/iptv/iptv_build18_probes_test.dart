// RESEARCH PROBES — PlezTV build #18 (series search ONLY).
//
// The phone failure (v2.25.13, confirmed installed, 2026-11-08 ~21:41 EST,
// screen recording ~/workspace/tmp_work/plezy-tv-research18/
// screen-recording-20261108-2141.mp4):
//   * "game of thrones" unscoped returns in ~1-2 s: Trex — Movies 1,
//     PLEX TV Shows 1, Trex — Live TV 2, Trex — Series ZERO (no section).
//   * Scoped to "Trex — Series" returns [] in <1 s with the PLAIN empty
//     state ("Try a different search term") — no "hidden by category
//     filter" message, i.e. hiddenMatches == 0 at render time.
//   * Trex Movies (199k rows) and Trex Live (55k rows) search fine; Plex
//     series search finds the show. ONLY the Trex series leg is empty.
//
// WHY THE #17 DIAGNOSIS CANNOT BE THE CAUSE: build #17 fixed a
// cold-catalog race (50 s section budget expiring before the 46k load
// lands). A race returns [] after ~50 s. The phone returns [] in ~1 s.
// A search that completes in ~1 s with zero matches COMPLETED fast —
// the warm path over a list that lacks the row, or a fast-empty cold
// path. The #17 probes never modeled the disk cache (in unit tests
// getApplicationDocumentsDirectory throws, so _readDiskCatalog returns
// null; widget tests set debugDisableDisk = true), so they never ran
// the search against the disk-populated catalog the phone actually uses.
//
// LEADING HYPOTHESIS (D1/D3): the disk series list is FILTER-SHAPED.
// _loadSeries() falls back to a per-category crawl when the unfiltered
// get_series returns [] — and the crawl SKIPS hidden categories —
// and _loadSeriesCached() then WRITES those crawled rows to disk via
// _writeCatalogRows, contradicting IptvCatalogDiskCache's own rule
// ("Filtering … is applied at read time on the parsed rows, never baked
// into storage"). A disk file written from a crawl lacks every hidden
// category's rows. The warm search then trusts it, returns [] with
// hiddenMatches == 0 (the post-load filter never sees the row — it was
// never loaded), and the UI shows plain "No results". The file stays
// poisoned for the 24 h TTL (stale refresh re-fetches the unfiltered
// list, so it heals only if that call returns rows then).
// D3 proves the app can poison its own disk end-to-end with only real
// code paths: hide EN, let the unfiltered call return [], search once,
// un-hide EN, search again on a fresh client — still [].
//
// These probes FAIL on ffa69dd87 (D1, D1b, D3) and are the proof the
// build #18 fix has to turn green. D2 and D4 are controls that PASS on
// base (warm path over a complete disk list; cold path when the crawl
// covers the GoT category).
//
// Fidelity notes:
//   * Trex scale: 46,527 series rows / 237 categories, GoT category
//     "|EN| TOP SERIES" (id 1219) LAST in the category list, 110 rows.
//   * The phone's search is WARM by the time Matt reaches Search: the
//     bind warm-up (warmUpSeriesCatalog) reads the disk copy in ~300 ms.
//     Each probe warms the client the same way before the asserted search
//     (warm-up + one throwaway search, which awaits the shared load).
//   * No budget scaling: the fake has zero delays, so the real 50 s
//     section budget stands and everything completes in seconds.
//   * No login, no live panel: the fake API is the only source.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

// Redaction-safe test password (never a real credential).
const testPassword = 'pa' 'ss';

const _gotSeriesId = 219;
const _gotCategoryId = '1219';
const _gotCategoryName = '|EN| TOP SERIES';
const _gotName = 'EN - Game Of Thrones (2011)';

/// The 12 region prefixes the fake's 236 filler categories cycle through,
/// so hiding one initial (EN) hides only a fraction of the catalog — the
/// real panel's shape, where 237 series categories span many regions.
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

/// 237 series categories, 1219 LAST (the real panel's order for the GoT
/// category — late in the sweep). Filler categories cycle the 12 regions.
List<XtreamCategory> seriesCategories() {
  final cats = <XtreamCategory>[
    for (var i = 1; i <= 236; i++)
      XtreamCategory(id: '$i', name: '|${_regions[(i - 1) % _regions.length]}| Series $i'),
  ];
  cats.add(const XtreamCategory(id: _gotCategoryId, name: _gotCategoryName));
  return cats;
}

Map<String, List<XtreamSeries>> seriesByCategory() {
  final map = <String, List<XtreamSeries>>{};
  for (final row in allSeriesRows()) {
    (map[row.categoryId ?? ''] ??= <XtreamSeries>[]).add(row);
  }
  return map;
}

/// VOD rows in a second category, so a poisoned VOD disk can be shaped
/// like v2.25.13 wrote it when 'Movies' was hidden at crawl time.
List<XtreamVodStream> vodFillerRows() => [
      for (var i = 0; i < 3; i++)
        XtreamVodStream(streamId: 100 + i, name: 'Drama Filler $i', categoryId: '2'),
    ];

/// Fake panel: unfiltered series either returns the full 46,527-row list
/// or [] (which triggers the app's per-category crawl); per-category
/// returns the real bucket. Movies returns the one GoT documentary and
/// Live returns the two GoT channels — the recording's exact signature.
/// Unfiltered VOD can also be made to return [] (D5), to prove the VOD
/// loader's crawl rows are never persisted either.
class _Build18FakeApi extends XtreamApi {
  _Build18FakeApi({this.unfilteredSeriesEmpty = false, this.unfilteredVodEmpty = false})
      : super(
          serverUrl: 'https://panel.example.com:8080',
          username: 'user',
          password: testPassword,
        );

  final bool unfilteredSeriesEmpty;
  final bool unfilteredVodEmpty;
  int unfilteredSeriesCalls = 0;
  int perCategorySeriesCalls = 0;

  final Map<String, List<XtreamSeries>> _buckets = seriesByCategory();

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => seriesCategories();

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async => [
        const XtreamCategory(id: '1', name: 'Movies'),
        const XtreamCategory(id: '2', name: 'Drama'),
      ];

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async =>
      [const XtreamCategory(id: '1', name: 'Live')];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) {
      unfilteredSeriesCalls++;
      lastSeriesBody = jsonEncode(allSeriesRows().map((r) => r.toJson()).toList());
      return unfilteredSeriesEmpty ? const <XtreamSeries>[] : allSeriesRows();
    }
    perCategorySeriesCalls++;
    lastSeriesBody = null; // A per-category body is never the full catalog.
    return _buckets[categoryId] ?? const <XtreamSeries>[];
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null && unfilteredVodEmpty) {
      lastVodStreamsBody = '[]';
      return const <XtreamVodStream>[];
    }
    if (categoryId != null) lastVodStreamsBody = null; // A per-category body is never the full catalog (xtream_api.dart:179).
    if (categoryId != null) {
      return categoryId == '1'
          ? const [
              XtreamVodStream(
                streamId: 1,
                name: 'NF - Game of Thrones: A Day in...',
                categoryId: '1',
              ),
            ]
          : vodFillerRows();
    }
    return [
      const XtreamVodStream(
        streamId: 1,
        name: 'NF - Game of Thrones: A Day in...',
        categoryId: '1',
      ),
      ...vodFillerRows(),
    ];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => [
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
  client.testXtreamApi = api ?? _Build18FakeApi();
  return client;
}

const _moviesLibraryId = 'iptv:conn-xt-1:movies';

/// Warm the series catalog exactly as the phone does: the bind warm-up
/// reads the disk copy, so by the time the user reaches Search the leg is
/// warm. warmUpSeriesCatalog() is fire-and-forget, so a throwaway search
/// is the public-API way to wait for the shared load to land.
Future<void> warmSeries(IptvClient client) async {
  client.warmUpSeriesCatalog();
  await client.searchItems('zz-no-match-zz');
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

/// The disk write inside _loadSeriesCached is fire-and-forget; poll until
/// the series file lands (or the timeout expires).
Future<List<XtreamSeries>> waitForDiskSeries({
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final rows = await readDiskSeriesRows();
    if (rows.isNotEmpty) return rows;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return const <XtreamSeries>[];
}

Future<List<XtreamVodStream>> readDiskVodRows() async {
  final hit = await IptvCatalogDiskCache().read(
    'conn-xt-1',
    IptvCatalogDiskCache.vodDataset,
  );
  if (hit == null) return const <XtreamVodStream>[];
  return XtreamApi.parseVodStreamsBody(hit.body);
}

/// Poll until a VOD disk file lands (or the timeout expires) — the write
/// is fire-and-forget, so an assertion that nothing was written must wait
/// long enough for a write to have landed.
Future<List<XtreamVodStream>> waitForDiskVod({
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final rows = await readDiskVodRows();
    if (rows.isNotEmpty) return rows;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return const <XtreamVodStream>[];
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build18_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    // The catalog writes are fire-and-forget: a write started by the
    // last search can still be in flight when tearDown runs, and a file
    // landing mid-delete makes the recursive delete fail (ENOTEMPTY).
    // Retry once after a short yield instead of failing the test on it
    // (same guard as the EPG cache tests).
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 1) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  group('build18: Trex series search returns [] on the phone (v2.25.13)', () {
    test('D1: warm search over a crawl-shaped disk list returns [] with hiddenMatches=0', () async {
      // Seed the disk series file with exactly what _loadSeries()'s crawl
      // writes when category 1219 was hidden: 46,417 rows, no GoT.
      final cache = IptvCatalogDiskCache();
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(crawlShapedSeriesRows().map((r) => r.toJson()).toList()),
      );
      final client = clientWith(api: _Build18FakeApi());
      try {
        await warmSeries(client);
        final results = await client.searchItems('game of thrones');
        final diag = client.lastSearchDiagnostics!;
        // ignore: avoid_print
        print(
          'BUILD18-D1 unscoped: titles=${results.map((i) => i.title).toList()} '
          'series loadRows=${diag.series.loadRows} hidden=${diag.series.hiddenMatches} '
          'ms=${diag.series.ms} totalMs=${diag.totalMs}',
        );
        // The recording's exact signature: movies 1, live 2, series 0,
        // and the filter did NOT hide anything (hiddenMatches == 0).
        expect(results.where((i) => (i.title ?? '').contains('A Day in')).length, 1);
        expect(results.where((i) => (i.title ?? '').contains('GAME OF THRONES 4K')).length, 2);
        expect(diag.series.loadRows, 46417);
        expect(diag.series.hiddenMatches, 0);
        expect(diag.series.ms, lessThan(5000));
        // FAILING-FIRST: the warm path trusts the disk list and never
        // consults the sweep/network, so the show is unfindable.
        expect(results.map((i) => i.title), contains(_gotName));
      } finally {
        client.close();
      }
    });

    test('D1b: scoped Trex — Series search over the same disk list returns []', () async {
      final cache = IptvCatalogDiskCache();
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(crawlShapedSeriesRows().map((r) => r.toJson()).toList()),
      );
      final client = clientWith(api: _Build18FakeApi());
      try {
        await warmSeries(client);
        final results = await client.searchItems(
          'game of thrones',
          excludedLibraryIds: {_moviesLibraryId},
        );
        final diag = client.lastSearchDiagnostics!;
        // ignore: avoid_print
        print(
          'BUILD18-D1b scoped: titles=${results.map((i) => i.title).toList()} '
          'series loadRows=${diag.series.loadRows} hidden=${diag.series.hiddenMatches} '
          'ms=${diag.series.ms}',
        );
        expect(diag.series.loadRows, 46417);
        expect(diag.series.hiddenMatches, 0);
        // FAILING-FIRST: same warm-path trust, scoped — the phone's f16/f19.
        expect(results.map((i) => i.title), contains(_gotName));
      } finally {
        client.close();
      }
    });

    test('D2 (control): warm search over a COMPLETE disk list finds the show', () async {
      final cache = IptvCatalogDiskCache();
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(allSeriesRows().map((r) => r.toJson()).toList()),
      );
      final client = clientWith(api: _Build18FakeApi());
      try {
        await warmSeries(client);
        final results = await client.searchItems('game of thrones');
        final diag = client.lastSearchDiagnostics!;
        // ignore: avoid_print
        print(
          'BUILD18-D2 control: titles=${results.map((i) => i.title).toList()} '
          'series loadRows=${diag.series.loadRows}',
        );
        expect(diag.series.loadRows, 46527);
        expect(results.map((i) => i.title), contains(_gotName));
      } finally {
        client.close();
      }
    });

    test('D3: a crawl no longer poisons the disk, and a poisoned disk left by an older build still heals', () async {
      // Step 1: EN hidden, panel unfiltered returns [] -> the load crawls
      // (skipping EN categories incl. 1219). Build #18 fix 1: crawl rows
      // are served in memory but NEVER written to disk, so the app can
      // no longer poison its own cache — the disk stays empty here.
      // (As the researcher wrote it, this step asserted the disk WAS
      // written; that asserts the poisoning behaviour fix 1 removes, so
      // the step now asserts the opposite.)
      final api1 = _Build18FakeApi(unfilteredSeriesEmpty: true);
      final hidden = clientWith(api: api1, hiddenInitials: ['EN']);
      try {
        final r1 = await hidden.searchItems('game of thrones');
        expect(r1.map((i) => i.title), isNot(contains(_gotName)));
      } finally {
        hidden.close();
      }
      final diskRows = await waitForDiskSeries();
      // ignore: avoid_print
      print(
        'BUILD18-D3 after step 1: disk rows=${diskRows.length} '
        'has1219=${diskRows.any((r) => r.categoryId == _gotCategoryId)} '
        'unfilteredCalls=${api1.unfilteredSeriesCalls} '
        'perCategoryCalls=${api1.perCategorySeriesCalls}',
      );
      expect(diskRows, isEmpty);

      // Step 1b: seed the poisoned disk file exactly as v2.25.13 wrote
      // it — the crawl's rows with every EN category missing (42,483
      // rows, no 1219). This is the file already on Matt's phone; the
      // heal in step 2 must fix the search without it being rewritten.
      final categoryNames = {
        for (final c in seriesCategories()) c.id: c.name,
      };
      final poisoned = allSeriesRows()
          .where((r) => !(categoryNames[r.categoryId ?? ''] ?? '').startsWith('|EN|'))
          .toList();
      expect(poisoned.length, 42483);
      final cache = IptvCatalogDiskCache();
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(poisoned.map((r) => r.toJson()).toList()),
      );

      // Step 2: EN turned back ON, fresh client, same connection, same
      // disk. The panel would now return the full list — but the warm
      // search never asks it. The heal must find the show via the
      // per-category sweep of the categories the disk does not cover.
      final api2 = _Build18FakeApi();
      final shown = clientWith(api: api2);
      try {
        await warmSeries(shown);
        final r2 = await shown.searchItems('game of thrones');
        final diag = shown.lastSearchDiagnostics!;
        // ignore: avoid_print
        print(
          'BUILD18-D3 step 2: titles=${r2.map((i) => i.title).toList()} '
          'series loadRows=${diag.series.loadRows} hidden=${diag.series.hiddenMatches} '
          'unfilteredCalls=${api2.unfilteredSeriesCalls}',
        );
        expect(diag.series.loadRows, poisoned.length);
        expect(diag.series.hiddenMatches, 0);
        expect(api2.unfilteredSeriesCalls, 0);
        // The poisoned disk survives the un-hide, but the search heals.
        expect(r2.map((i) => i.title), contains(_gotName));
      } finally {
        shown.close();
      }
    });

    test('D5: a VOD crawl does not write a poisoned disk file', () async {
      // Same bug class as series (build #18 fix 1), for VOD: the panel's
      // unfiltered VOD call returns [], the load crawls per-category, and
      // the crawled rows must be served in memory but never persisted —
      // otherwise the next warm search trusts a list missing every
      // category hidden at crawl time.
      final api = _Build18FakeApi(unfilteredVodEmpty: true);
      final client = clientWith(api: api);
      try {
        final results = await client.searchItems('game of thrones');
        // ignore: avoid_print
        print(
          'BUILD18-D5: titles=${results.map((i) => i.title).toList()}',
        );
        expect(results.map((i) => i.title), contains('NF - Game of Thrones: A Day in...'));
        final diskVod = await waitForDiskVod();
        expect(diskVod, isEmpty);
      } finally {
        client.close();
      }
    });

    test('D6: a poisoned VOD disk still heals via the sweep', () async {
      // Same shape as D1, for VOD: seed the disk exactly as v2.25.13
      // wrote it when 'Movies' was hidden at crawl time — rows from
      // every visible category, none from 'Movies', so the documentary
      // is missing from the list the warm search trusts. The warm-up
      // search lands the VOD load (setting _vodStreamsLoaded), so the
      // asserted search takes the warm branch.
      final cache = IptvCatalogDiskCache();
      await cache.write(
        'conn-xt-1',
        IptvCatalogDiskCache.vodDataset,
        jsonEncode(vodFillerRows().map((r) => r.toJson()).toList()),
      );
      final client = clientWith(api: _Build18FakeApi());
      try {
        await warmSeries(client);
        final results = await client.searchItems('game of thrones');
        final diag = client.lastSearchDiagnostics!;
        // ignore: avoid_print
        print(
          'BUILD18-D6: titles=${results.map((i) => i.title).toList()} '
          'movies loadRows=${diag.movies.loadRows} '
          'loadMatches=${diag.movies.loadMatches} sweepMatches=${diag.movies.sweepMatches}',
        );
        // The search read the seeded disk (3 filler rows, no documentary).
        // (loadRows == 3 pins the disk read: a network load would return
        // 4 rows — the documentary plus the fillers. loadSource is a
        // build #18 diagnostics addition, so this test must not reference
        // it — the file has to compile on base too.)
        expect(diag.movies.loadRows, 3);
        expect(diag.movies.loadMatches, 0);
        // FAILING-FIRST on base: the warm VOD path trusts the disk list
        // and never sweeps, so the documentary is unfindable. On the fix,
        // the 0-match warm branch sweeps the categories the disk does not
        // cover ('Movies') and the documentary comes back via the sweep.
        expect(diag.movies.sweepMatches, greaterThan(0));
        expect(results.map((i) => i.title), contains('NF - Game of Thrones: A Day in...'));
      } finally {
        client.close();
      }
    });

    test('D4 (control): cold path, unfiltered [] fast, per-category works — the show is found', () async {
      // No disk seeding: the load IS the crawl, and with EN visible the
      // crawl covers 1219 — so the cold path finds GoT. Proves the
      // sweep/crawl machinery is fine; the bug is the warm path trusting
      // a partial disk list.
      final api = _Build18FakeApi(unfilteredSeriesEmpty: true);
      final client = clientWith(api: api);
      try {
        final results = await client.searchItems('game of thrones');
        final diag = client.lastSearchDiagnostics!;
        // The search returns via the sweep before the background load
        // (crawl) lands — loadRows == -1 is expected in this shape — so
        // a second search is needed before the load's counters can be
        // read: by then the shared _seriesFuture has resolved.
        await client.searchItems('zz-no-match-zz');
        // ignore: avoid_print
        print(
          'BUILD18-D4 control: titles=${results.map((i) => i.title).toList()} '
          'series loadRows=${diag.series.loadRows} '
          'unfilteredCalls=${api.unfilteredSeriesCalls} '
          'perCategoryCalls=${api.perCategorySeriesCalls}',
        );
        expect(api.unfilteredSeriesCalls, 1);
        expect(api.perCategorySeriesCalls, greaterThan(0));
        expect(results.map((i) => i.title), contains(_gotName));
      } finally {
        client.close();
      }
    });
  });
}
