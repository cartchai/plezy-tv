// SERIES-SEARCH FIX (v1.0.16) — cold-type upsert/merge tests.
//
// The research probe (iptv_series_empty_probe_test.dart) pins the
// desired outcomes; these tests pin the fix's own properties:
//   F1  a warm index still REFUSES a partial list (P5a protection
//       intact — a partial list must never shrink good rows).
//   F2  a partial land leaves lastSync null, so the type stays due and
//       the next (non-forced) sync refetches it.
//   F3  the isolate writer counts dropped rows, merges (never wipes),
//       and refuses a partial list once warm — verified against the
//       SQLite file directly.
//   F4  a partial seed land leaves lastSync null too (the seed's
//       fetchedAt stamp must not mark a partial type synced).
//   F5  the VOD first-load guard (mirror of probe P3): a partial VOD
//       load is served but never persisted as the disk catalog.
//
// Every new test here must FAIL for the product reason on base
// dd402ea37 — verified by running this file against a base worktree
// before reporting. Zero panel requests: every panel call goes to the
// fake below.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';
const _connId = 'conn-xt-1';

List<XtreamCategory> _cats(String prefix, int count) =>
    [for (var i = 1; i <= count; i++) XtreamCategory(id: '$prefix$i', name: 'Category $i')];

/// The Nov 9 degraded shape: 635 Netflix-only rows in a single category
/// of 237 — the panel's partial series list.
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
/// payload. Live is always complete; the series and VOD lists are
/// swappable between the partial and full shapes mid-test.
class _SwitchablePanel extends http.BaseClient {
  _SwitchablePanel({required this.seriesRows, this.vodRows = _defaultVodRows});

  List<XtreamSeries> seriesRows;
  List<XtreamVodStream> vodRows;

  static const _defaultVodRows = [
    XtreamVodStream(streamId: 11, name: 'Movie One', categoryId: 'mov1'),
    XtreamVodStream(streamId: 12, name: 'Movie Two', categoryId: 'mov2'),
    XtreamVodStream(streamId: 13, name: 'Movie Three', categoryId: 'mov3'),
  ];

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

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final action = request.url.queryParameters['action'];
    final categoryId = request.url.queryParameters['category_id'];
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
        if (categoryId != null) {
          final rows = vodRows.where((r) => r.categoryId == categoryId).toList();
          return jsonEncode(rows.map((r) => r.toJson()).toList());
        }
        return jsonEncode(vodRows.map((r) => r.toJson()).toList());
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

IptvClient _clientWith(_SwitchablePanel panel) {
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

DateTime? _seriesLastSync(IptvClient client) =>
    client.searchIndexState.lastSync[IptvSearchIndex.typeSeries];

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
    tempDir = await Directory.systemTemp.createTemp('plezy_series_fix_');
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

  group('series fix v1.0.16 — cold-type upsert/merge', () {
    test('F1: warm + partial refuses and keeps the good rows (P5a intact)', () async {
      final panel = _SwitchablePanel(seriesRows: _fullSeriesRows());
      final client = _clientWith(panel);

      final first = await client.syncSearchIndex(force: true);
      expect(first.rows[IptvSearchIndex.typeSeries], 46527);
      expect(_seriesRows(client), 46527);
      expect(_seriesLastSync(client), isNotNull);
      expect(
        (await client.searchItems('game of thrones')).map((m) => m.title),
        contains('EN - Game Of Thrones (2011)'),
      );

      // The panel degrades to the partial list on the next sync.
      panel.seriesRows = _partialSeriesRows();
      final second = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('F1: second sync skipped=${second.skipped} rows=${second.rows}');
      expect(second.skipped[IptvSearchIndex.typeSeries], 'partial');
      expect(second.partialTypes, isNot(contains(IptvSearchIndex.typeSeries)));
      expect(_seriesRows(client), 46527);
      expect(_seriesLastSync(client), isNotNull);
      expect(
        (await client.searchItems('game of thrones')).map((m) => m.title),
        contains('EN - Game Of Thrones (2011)'),
      );
      // The refused partial rows never land.
      expect(
        (await client.searchItems('alice')).map((m) => m.title),
        isNot(contains('NF - Alice')),
      );
    });

    test('F2: a partial land stays due — lastSync null, next sync refetches', () async {
      final panel = _SwitchablePanel(seriesRows: _partialSeriesRows());
      final client = _clientWith(panel);

      final first = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('F2: first sync skipped=${first.skipped} rows=${first.rows} partial=${first.partialTypes}');
      expect(first.rows[IptvSearchIndex.typeSeries], 635);
      expect(first.partialTypes, contains(IptvSearchIndex.typeSeries));
      expect(_seriesRows(client), 635);
      expect(_seriesLastSync(client), isNull,
          reason: 'a partial land must not stamp lastSync, or the type is never due again');
      expect(
        (await client.searchItems('alice')).map((m) => m.title),
        contains('NF - Alice'),
      );

      // The panel recovers; a NON-forced sync must refetch the due type.
      panel.seriesRows = _fullSeriesRows();
      final second = await client.syncSearchIndex();
      // ignore: avoid_print
      print('F2: second sync skipped=${second.skipped} rows=${second.rows}');
      expect(second.skipped[IptvSearchIndex.typeSeries], isNull);
      expect(_seriesRows(client), 46527);
      expect(_seriesLastSync(client), isNotNull);
      expect(
        (await client.searchItems('game of thrones')).map((m) => m.title),
        contains('EN - Game Of Thrones (2011)'),
      );
      // The partial rows survive the full sync (upsert/merge, not wipe).
      expect(
        (await client.searchItems('alice')).map((m) => m.title),
        contains('NF - Alice'),
      );
    });

    test('F3: isolate writer counts drops, merges, and refuses once warm', () async {
      final dbPath = '${tempDir.path}/series_fix.db';
      final catBody = jsonEncode(_cats('cat', 237).map((c) => c.toJson()).toList());
      // 3 good rows in cat1 + 2 malformed rows: a numeric name and a
      // numeric cover both throw in XtreamSeries.fromJson (the `as
      // String?` casts), so they must be counted as dropped, not
      // silently swallowed.
      final partialBody = jsonEncode([
        {'series_id': 7001, 'name': 'NF - Alice', 'category_id': 'cat1'},
        {'series_id': 7002, 'name': 'NF - Babel', 'category_id': 'cat1'},
        {'series_id': 7003, 'name': 'NF - Katla', 'category_id': 'cat1'},
        {'series_id': 7004, 'name': 123, 'category_id': 'cat1'},
        {'series_id': 7005, 'name': 'Bad Cover', 'category_id': 'cat1', 'cover': 42},
      ]);

      final landed = await writeIndexTypeInBackground(
        IndexWriteParams(
          dbPath: dbPath,
          connectionId: _connId,
          type: IptvSearchIndex.typeSeries,
          catalogBody: partialBody,
          categoryBody: catBody,
          syncStampMs: 111,
        ),
      );
      expect(landed.partial, isTrue);
      expect(landed.rowCount, 3);
      expect(landed.droppedRows, 2);
      expect(landed.coveredCategories, 1);
      expect(landed.totalCategories, 237);
      expect(landed.skippedReason, isNull);

      // Meta says 3 rows, no stamp (partial land stays due); the FTS
      // table holds exactly the 3 landed rows.
      var db = sqlite3.open(dbPath);
      try {
        expect(
          db
              .select(
                'SELECT COUNT(*) AS n FROM iptv_search_item WHERE connection_id = ? AND type = ?',
                [_connId, IptvSearchIndex.typeSeries],
              )
              .first['n'],
          3,
        );
        final meta = db
            .select(
              'SELECT row_count, last_sync_ms FROM iptv_search_meta WHERE connection_id = ? AND type = ?',
              [_connId, IptvSearchIndex.typeSeries],
            )
            .first;
        expect(meta['row_count'], 3);
        expect(meta['last_sync_ms'], 0,
            reason: 'a partial land stores 0 (reads back as null), never a stamp');
      } finally {
        db.close();
      }

      // The same partial list on the now-warm index is refused.
      final refused = await writeIndexTypeInBackground(
        IndexWriteParams(
          dbPath: dbPath,
          connectionId: _connId,
          type: IptvSearchIndex.typeSeries,
          catalogBody: partialBody,
          categoryBody: catBody,
          syncStampMs: 222,
        ),
      );
      expect(refused.skippedReason, 'partial');
      expect(refused.rowCount, 0);
      expect(refused.droppedRows, 2);

      // A full fetch merges: 238 incoming rows (237 fresh + 'NF - Alice'
      // updated in place) over the 3 landed rows = 240 FTS rows, meta
      // 238 (the latest fetch), stamp set.
      final fullRows = [
        {'series_id': 7001, 'name': 'NF - Alice (Updated)', 'category_id': 'cat1'},
        for (var i = 0; i < 237; i++)
          {'series_id': 90000 + i, 'name': 'Full Series $i', 'category_id': 'cat${i + 1}'},
      ];
      final full = await writeIndexTypeInBackground(
        IndexWriteParams(
          dbPath: dbPath,
          connectionId: _connId,
          type: IptvSearchIndex.typeSeries,
          catalogBody: jsonEncode(fullRows),
          categoryBody: catBody,
          syncStampMs: 456,
        ),
      );
      expect(full.partial, isFalse);
      expect(full.rowCount, 238);
      db = sqlite3.open(dbPath);
      try {
        expect(
          db
              .select(
                'SELECT COUNT(*) AS n FROM iptv_search_item WHERE connection_id = ? AND type = ?',
                [_connId, IptvSearchIndex.typeSeries],
              )
              .first['n'],
          240,
          reason: 'the 3 partial rows survive the full sync (merge, not wipe)',
        );
        final meta = db
            .select(
              'SELECT row_count, last_sync_ms FROM iptv_search_meta WHERE connection_id = ? AND type = ?',
              [_connId, IptvSearchIndex.typeSeries],
            )
            .first;
        expect(meta['row_count'], 238);
        expect(meta['last_sync_ms'], 456);
        final alice = db
            .select(
              'SELECT name FROM iptv_search_item WHERE connection_id = ? AND type = ? AND stream_id = ?',
              [_connId, IptvSearchIndex.typeSeries, 7001],
            )
            .first;
        expect(alice['name'], 'NF - Alice (Updated)');
      } finally {
        db.close();
      }
    });

    test('F4: a partial seed land leaves lastSync null', () async {
      final panel = _SwitchablePanel(seriesRows: _partialSeriesRows());
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
      print('F4: seriesIndexRows after seed=${_seriesRows(client)} lastSync=${_seriesLastSync(client)}');
      expect(_seriesRows(client), greaterThan(0));
      expect(_seriesLastSync(client), isNull,
          reason: 'the seed passes the disk file age as the stamp — a partial land must ignore it');
    });

    test('F5: a partial VOD load is served but never persisted', () async {
      // VOD rows in mov1 only, against 3 movie categories (1/3 < 0.5).
      final panel = _SwitchablePanel(
        seriesRows: _partialSeriesRows(),
        vodRows: const [
          XtreamVodStream(streamId: 11, name: 'Movie One', categoryId: 'mov1'),
          XtreamVodStream(streamId: 12, name: 'Movie Two', categoryId: 'mov1'),
          XtreamVodStream(streamId: 13, name: 'Movie Three', categoryId: 'mov1'),
        ],
      );
      final client = _clientWith(panel);

      final hubs = await client.fetchGlobalHubs();
      expect(hubs.map((h) => h.title), contains('Trex — Movies'));

      // The fire-and-forget disk write lands shortly after the load.
      final cache = IptvCatalogDiskCache();
      ({String body, DateTime fetchedAt})? entry;
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (entry == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        entry = await cache.read(_connId, IptvCatalogDiskCache.vodDataset);
      }
      // ignore: avoid_print
      print('F5: disk VOD file after partial load: ${entry == null ? 'absent' : '${entry.body.length} chars'}');
      expect(entry, isNull,
          reason: 'a partial unfiltered VOD list must never be written as the complete disk catalog');
    });
  });
}
