// SERIES-EMPTY RESEARCH PROBE — PlezTV #series-empty (Matt's phone, 2026-11-12).
//
// THE PHONE FAILURE (v1.0.14-2.25.0+186, 2026-11-12 ~12:26–12:33 EST):
//   * Series search returns ZERO — not ranked low, empty. Logs show the
//     server leg finding 141 results {movie: 100, unknown: 41} (unknown =
//     live channels, MediaKind.unknown) and the aggregation returning 0
//     (a Series scope / hidden-library filter dropping the non-series
//     hits — the leg itself ran fine).
//   * Manual refresh ("Refreshing Trex details") shows Live TV 55257,
//     Movies 200209, TV/Series "partial", footer "Catalog sync failed".
//   * Settings → IPTV cache reads 594.1 MB · 55257 / 200209 / 0 — the
//     SEARCH-INDEX series rows are literally 0 (the three numbers are
//     index rowCounts, not disk rows).
//   * Browse is ALSO partial: the Series library shows some posters and
//     a show plays, but "there should be way more" than the ~46k catalog.
//
// WHAT THE CODE SAYS (no live panel — fakes only):
//   * The sync's series leg reports skipped reason 'partial', which by
//     elimination is writeIndexTypeInBackground's completeness guard
//     (iptv_search_index.dart): the fetched rows cover fewer than half
//     the fetched categories, so NOTHING is written and the index stays
//     at 0 rows. Live + movies pass the same guard on the same run.
//   * The seed refuses the disk series file the same way ('partial'),
//     so the index can never heal from disk either.
//   * The disk file itself is a stale partial catalog (written when a
//     partial unfiltered list was treated as complete — the P5a shape:
//     the Nov 9 panel returned a 635-row Netflix-only series list).
//   * Browse reads the disk catalog; search reads the index. That split
//     is why browse shows some series while search shows none.
//
// WHAT THESE PROBES PIN (desired outcomes, not mechanisms):
//   P1a  a partial series list must still land what it fetched —
//        FAILS on base (index stays 0, 'NF - Alice' unfindable).
//   P1b  a full series list heals — PASSES on base (control: the sync
//        machinery works; the variable is the panel's partial shape).
//   P1c  partial then full completes the catalog — FAILS on base at the
//        first step; passes after the fix.
//   P2a  the seed must land partial disk rows for a cold type — FAILS
//        on base (seed refuses 'partial', rows stay 0).
//   P2b  the seed lands a complete disk file — PASSES on base (control).
//   P3   a partial unfiltered browse load must not be persisted as the
//        complete disk catalog — FAILS on base (635 rows written).
//   P4   cold search reads the partial disk — PASSES on base
//        (characterization: the leg runs; the gap is the data).
//   P5   the series leg ignores scope — PASSES on base (characterization:
//        the leg returns movies+live under a Series scope; the
//        aggregation is what drops them to 0).
//
// Copy to test/services/iptv/iptv_series_empty_probe_test.dart to run.
// No repo files are touched by the probe itself.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';
const _connId = 'conn-xt-1';

/// The Trex — Series scope: exclude the Movies library (live is excluded
/// whenever the set is non-empty), so only the series section is wanted
/// — the shape Matt's aggregation-0 log implies.
const _seriesOnlyScope = {'iptv:conn-xt-1:movies'};

List<XtreamCategory> _cats(String prefix, int count) =>
    [for (var i = 1; i <= count; i++) XtreamCategory(id: '$prefix$i', name: 'Category $i')];

/// The Nov 9 degraded shape: 635 Netflix-only rows in a single category
/// of 237 — the panel's partial series list, as modelled by the build19
/// P5a probe. 'NF - Alice' is a show Matt actually sees in Browse.
List<XtreamSeries> _partialSeriesRows() => [
      const XtreamSeries(seriesId: 7001, name: 'NF - Alice', categoryId: 'cat1'),
      for (var i = 0; i < 634; i++)
        XtreamSeries(seriesId: 80000 + i, name: 'Netflix Filler $i', categoryId: 'cat1'),
    ];

/// A full Trex-scale series list: GoT in the LAST category (cat237) plus
/// fillers spanning all 237 categories (46,527 rows total).
List<XtreamSeries> _fullSeriesRows() => [
      const XtreamSeries(seriesId: 219, name: 'EN - Game Of Thrones (2011)', categoryId: 'cat237'),
      for (var i = 0; i < 109; i++)
        XtreamSeries(seriesId: 20000 + i, name: 'Top Series Filler $i', categoryId: 'cat237'),
      for (var i = 0; i < 46417; i++)
        XtreamSeries(
          seriesId: 100000 + i,
          name: 'Filler Series $i',
          categoryId: 'cat${(i % 236) + 1}',
        ),
    ];

/// A fake panel that answers each Xtream endpoint with a minimal valid
/// payload. Live + movies are always complete; the series list is
/// swappable between the partial and full shapes mid-test.
class _DegradedSeriesPanel extends http.BaseClient {
  _DegradedSeriesPanel({required this.seriesRows});

  List<XtreamSeries> seriesRows;

  int totalRequests = 0;
  int seriesUnfilteredCalls = 0;

  static const _liveCategories = [
    XtreamCategory(id: 'live1', name: 'Live 1'),
    XtreamCategory(id: 'live2', name: 'Live 2'),
    XtreamCategory(id: 'live3', name: 'Live 3'),
  ];
  static const _liveRows = [
    XtreamLiveStream(streamId: 1, name: 'Live One', categoryId: 'live1'),
    XtreamLiveStream(streamId: 2, name: 'Live Two', categoryId: 'live2'),
    XtreamLiveStream(streamId: 3, name: 'Live Three', categoryId: 'live3'),
  ];
  static const _movieCategories = [
    XtreamCategory(id: 'mov1', name: 'Movies 1'),
    XtreamCategory(id: 'mov2', name: 'Movies 2'),
    XtreamCategory(id: 'mov3', name: 'Movies 3'),
  ];
  static const _movieRows = [
    XtreamVodStream(streamId: 11, name: 'Movie One', categoryId: 'mov1'),
    XtreamVodStream(streamId: 12, name: 'Movie Two', categoryId: 'mov2'),
    XtreamVodStream(streamId: 13, name: 'Movie Three', categoryId: 'mov3'),
  ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final action = request.url.queryParameters['action'];
    final categoryId = request.url.queryParameters['category_id'];
    if (action == 'get_series' && categoryId == null) seriesUnfilteredCalls++;
    final body = _bodyFor(action, categoryId);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }

  String _bodyFor(String? action, String? categoryId) {
    switch (action) {
      case null:
        return jsonEncode({
          'user_info': {'status': 'Active', 'exp_date': '1790000000'},
        });
      case 'get_live_categories':
        return jsonEncode(_liveCategories.map((c) => c.toJson()).toList());
      case 'get_vod_categories':
        return jsonEncode(_movieCategories.map((c) => c.toJson()).toList());
      case 'get_series_categories':
        return jsonEncode(_cats('cat', 237).map((c) => c.toJson()).toList());
      case 'get_live_streams':
        return jsonEncode(_liveRows.map((r) => r.toJson()).toList());
      case 'get_vod_streams':
        return jsonEncode(_movieRows.map((r) => r.toJson()).toList());
      case 'get_series':
        if (categoryId != null) {
          final rows = seriesRows.where((r) => r.categoryId == categoryId).toList();
          return jsonEncode(rows.map((r) => r.toJson()).toList());
        }
        return jsonEncode(seriesRows.map((r) => r.toJson()).toList());
      case 'get_series_info':
        return jsonEncode({
          'info': {'name': 'Show'},
          'episodes': <String, dynamic>{},
        });
      default:
        return '[]';
    }
  }
}

IptvClient _clientWith(_DegradedSeriesPanel panel) {
  final connection = XtreamConnection(
    id: _connId,
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    createdAt: DateTime.utc(2026, 11, 5),
  );
  final client = IptvClient.forConnection(connection);
  client.testXtreamApi = XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    httpClient: panel,
  );
  addTearDown(client.close);
  return client;
}

int _seriesRows(IptvClient client) =>
    client.searchIndexState.rowCounts[IptvSearchIndex.typeSeries] ?? 0;

Future<void> _writeSeriesDisk({
  required List<XtreamSeries> rows,
  required List<XtreamCategory> categories,
}) async {
  final cache = IptvCatalogDiskCache();
  await cache.write(
    _connId,
    IptvCatalogDiskCache.seriesDataset,
    jsonEncode(rows.map((r) => r.toJson()).toList()),
  );
  await cache.write(
    _connId,
    IptvCatalogDiskCache.seriesCategoriesDataset,
    jsonEncode(categories.map((c) => c.toJson()).toList()),
  );
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_series_empty_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    IptvClient.searchSectionBudget = const Duration(seconds: 50);
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!await tempDir.exists()) break;
      try {
        await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 2) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  });

  group('series-empty probe — partial series list', () {
    test('P1a: a partial series list lands what it fetched (FAILS on base)', () async {
      final panel = _DegradedSeriesPanel(seriesRows: _partialSeriesRows());
      final client = _clientWith(panel);

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('P1a: skipped=${result.skipped} rows=${result.rows} seriesIndexRows=${_seriesRows(client)}');

      // Diagnosis pin — the fix lands the partial list instead of
      // refusing it (on base this was skipped['series'] == 'partial',
      // Matt's dialog): the type lands partial, live + movies write
      // full counts.
      expect(result.skipped['series'], isNull);
      expect(result.partialTypes, contains(IptvSearchIndex.typeSeries));
      expect(result.rows[IptvSearchIndex.typeSeries], 635);
      expect(result.rows[IptvSearchIndex.typeLive], 3);
      expect(result.rows[IptvSearchIndex.typeMovie], 3);

      // Desired outcome (FAILS on base — the index stays at 0 rows):
      // the 635 fetched shows land in the index and become searchable.
      expect(_seriesRows(client), greaterThan(0),
          reason: 'a partial list must land what it fetched for a cold type');
      final found = await client.searchItems('alice');
      expect(found.map((m) => m.title), contains('NF - Alice'));
    });

    test('P1b: a full series list heals (control — PASSES on base)', () async {
      final panel = _DegradedSeriesPanel(seriesRows: _fullSeriesRows());
      final client = _clientWith(panel);

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('P1b: skipped=${result.skipped} rows=${result.rows}');
      expect(result.rows[IptvSearchIndex.typeSeries], 46527);
      expect(_seriesRows(client), 46527);
      final found = await client.searchItems('game of thrones');
      expect(found.map((m) => m.title), contains('EN - Game Of Thrones (2011)'));
    });

    test('P1c: partial then full completes the catalog (FAILS on base at step 1)', () async {
      final panel = _DegradedSeriesPanel(seriesRows: _partialSeriesRows());
      final client = _clientWith(panel);

      await client.syncSearchIndex(force: true);
      expect(_seriesRows(client), greaterThan(0),
          reason: 'the partial list lands first');
      expect(
        (await client.searchItems('alice')).map((m) => m.title),
        contains('NF - Alice'),
      );

      panel.seriesRows = _fullSeriesRows();
      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('P1c: second sync skipped=${result.skipped} rows=${result.rows}');
      expect(_seriesRows(client), 46527);
      final found = await client.searchItems('game of thrones');
      expect(found.map((m) => m.title), contains('EN - Game Of Thrones (2011)'));
      // The partial rows survive the full sync (upsert/merge, not wipe).
      expect(
        (await client.searchItems('alice')).map((m) => m.title),
        contains('NF - Alice'),
      );
    });

    test('P2a: the seed lands partial disk rows for a cold type (FAILS on base)', () async {
      final panel = _DegradedSeriesPanel(seriesRows: _partialSeriesRows());
      final client = _clientWith(panel);
      // Matt's disk: rows in categories 1-5 only, against 237 categories.
      await _writeSeriesDisk(
        rows: [
          for (var i = 0; i < 5; i++)
            XtreamSeries(seriesId: 1000 + i, name: 'Filler Series $i', categoryId: 'cat${i + 1}'),
        ],
        categories: _cats('cat', 237),
      );

      await client.seedSearchIndexFromDisk();
      await client.searchIndexReady;
      // ignore: avoid_print
      print('P2a: seriesIndexRows after seed=${_seriesRows(client)}');
      expect(_seriesRows(client), greaterThan(0),
          reason: 'a cold type must seed from the partial disk rows it has');
    });

    test('P2b: the seed lands a complete disk file (control — PASSES on base)', () async {
      final panel = _DegradedSeriesPanel(seriesRows: _partialSeriesRows());
      final client = _clientWith(panel);
      await _writeSeriesDisk(
        rows: [
          for (var i = 0; i < 2370; i++)
            XtreamSeries(
              seriesId: 100000 + i,
              name: 'Filler Series $i',
              categoryId: 'cat${(i % 237) + 1}',
            ),
        ],
        categories: _cats('cat', 237),
      );

      await client.seedSearchIndexFromDisk();
      await client.searchIndexReady;
      expect(_seriesRows(client), 2370);
    });

    test('P3: a partial unfiltered browse load is not persisted as complete (FAILS on base)', () async {
      final panel = _DegradedSeriesPanel(seriesRows: _partialSeriesRows());
      final client = _clientWith(panel);

      // The Series browse first load (no disk file yet): the unfiltered
      // call returns the 635-row partial list.
      final hubs = await client.fetchGlobalHubs();
      expect(hubs.map((h) => h.title), contains('Trex — Series'));

      // The fire-and-forget disk write lands shortly after the load.
      final cache = IptvCatalogDiskCache();
      ({String body, DateTime fetchedAt})? entry;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (entry == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        entry = await cache.read(_connId, IptvCatalogDiskCache.seriesDataset);
      }
      // ignore: avoid_print
      print('P3: disk series file after partial load: ${entry == null ? 'absent' : '${entry.body.length} chars'}');
      expect(entry, isNull,
          reason: 'a partial unfiltered list must never be written as the complete disk catalog');
    });

    test('P4: cold search reads the partial disk (characterization — PASSES on base)', () async {
      final panel = _DegradedSeriesPanel(seriesRows: _partialSeriesRows());
      final client = _clientWith(panel);
      await _writeSeriesDisk(
        rows: [
          for (var i = 0; i < 5; i++)
            XtreamSeries(seriesId: 1000 + i, name: 'Filler Series $i', categoryId: 'cat${i + 1}'),
        ],
        categories: _cats('cat', 237),
      );

      // The leg runs and the cold fallback answers from disk rows.
      final diskHit = await client.searchItems('filler series 0');
      expect(diskHit.map((m) => m.title), contains('Filler Series 0'));
      // But GoT's category (cat237) is not in the partial disk, so the
      // series leg finds nothing — Matt's log shape.
      final noHit = await client.searchItems('game of thrones');
      expect(noHit.where((m) => (m.title ?? '').contains('Game Of Thrones')), isEmpty);
    });

    test('P5: the series leg ignores scope (characterization — PASSES on base)', () async {
      final panel = _DegradedSeriesPanel(seriesRows: _partialSeriesRows());
      final client = _clientWith(panel);
      await client.syncSearchIndex(force: true);

      // Scope inversion (#23): the leg answers globally even under a
      // Series-only scope — the aggregation is what drops the
      // non-series hits to 0, not the leg failing.
      final scoped = await client.searchItems('movie one', excludedLibraryIds: _seriesOnlyScope);
      expect(scoped.map((m) => m.title), contains('Movie One'));
    });
  });
}
