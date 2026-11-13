// HIDDEN CATEGORIES, PRUNED AT WRITE TIME — PlezTV v1.2.4 (FORK §45).
//
// Matt's prune decision (2026-11-13, supersedes the v1.1.0 Option B
// "disk stays full" split this file pinned): rows in hidden (turned-off)
// categories are PRUNED from the search index, the seed, and the disk
// catalog at write time — all three types. The wire still downloads
// the full lists; only the stored catalog is visible-only. The hidden
// state is the country/region filter: per-category ids plus
// letter-group initials, resolved by `IptvClient._isHiddenCategory`
// (id OR initial) at read time AND by `VisibleCatalogFilter` at write
// time. The trade-off Matt accepted: un-hiding a category does NOT
// bring its rows back until a re-sync (the un-hide notice + Refresh
// action guards that — see iptv_catalog_memory_test.dart T2/T2b).
// The search diagnostics' hiddenMatches/hiddenInitials now read 0 /
// empty after a prune: a pruned row is not stored, so it can never
// match a search to be counted as hidden.
//
// The v1.1.0 suite pinned Option B (rows 12, disk full, no purge).
// Every test below is rewritten to the 1.2.4 expectation; the test
// numbers H1-H13 are kept so the history stays readable.

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

// Six series categories with real initial shapes (verified against
// `categoryInitial`): EN x2, AR x2, NF, UK.
const _seriesCategories = [
  XtreamCategory(id: 'cat1', name: '|EN| Drama'),
  XtreamCategory(id: 'cat2', name: '|EN| Comedy'),
  XtreamCategory(id: 'cat3', name: 'AR - Series'),
  XtreamCategory(id: 'cat4', name: 'AR - Kids'),
  XtreamCategory(id: 'cat5', name: '[NF] Series'),
  XtreamCategory(id: 'cat6', name: 'UK: Series'),
];

List<XtreamSeries> _seriesRows() => [
      for (final c in _seriesCategories)
        for (var i = 1; i <= 2; i++)
          XtreamSeries(seriesId: 7000 + int.parse(c.id.substring(3)) * 10 + i, name: '${c.name} Show $i', categoryId: c.id),
    ];

const _liveCategories = [
  XtreamCategory(id: 'live1', name: '|EN| News'),
  XtreamCategory(id: 'live2', name: 'AR - Live'),
  XtreamCategory(id: 'live3', name: '[NF] Live'),
];
const _liveRows = [
  XtreamLiveStream(streamId: 1, name: 'EN News', categoryId: 'live1'),
  XtreamLiveStream(streamId: 2, name: 'AR Live', categoryId: 'live2'),
  XtreamLiveStream(streamId: 3, name: 'NF Live', categoryId: 'live3'),
];
const _movieCategories = [
  XtreamCategory(id: 'mov1', name: '|EN| Movies'),
  XtreamCategory(id: 'mov2', name: 'AR - Movies'),
  XtreamCategory(id: 'mov3', name: '[NF] Movies'),
];
const _movieRows = [
  XtreamVodStream(streamId: 11, name: 'EN Movie', categoryId: 'mov1'),
  XtreamVodStream(streamId: 12, name: 'AR Movie', categoryId: 'mov2'),
  XtreamVodStream(streamId: 13, name: 'NF Movie', categoryId: 'mov3'),
];

List<XtreamCategory> get _bigLiveCategories =>
    [for (var i = 1; i <= 600; i++) XtreamCategory(id: 'L$i', name: 'Live $i')];
List<XtreamLiveStream> get _bigLiveRows =>
    [for (var i = 1; i <= 600; i++) XtreamLiveStream(streamId: i, name: 'Live $i', categoryId: 'L$i')];

/// Fake panel: complete lists for all three types.
class _HiddenPanel extends http.BaseClient {
  int totalRequests = 0;
  // Test switches (each defaults to the healthy panel):
  // fail — every request throws a transport error (panel down);
  // bigLive — a 600-category / 600-row live catalog (purge chunking);
  // partialSeries — get_series returns only cat1's 2 rows (warm
  // partial-kept guard: 2 < 8 ~/ 2).
  bool fail = false;
  bool bigLive = false;
  bool partialSeries = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    if (fail) throw http.ClientException('panel unreachable (test)', request.url);
    final action = request.url.queryParameters['action'];
    final body = _bodyFor(action);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }

  String _bodyFor(String? action) {
    switch (action) {
      case null:
        return jsonEncode({
          'user_info': {'status': 'Active', 'exp_date': '1790000000'},
        });
      case 'get_live_categories':
        return jsonEncode((bigLive ? _bigLiveCategories : _liveCategories).map((c) => c.toJson()).toList());
      case 'get_vod_categories':
        return jsonEncode(_movieCategories.map((c) => c.toJson()).toList());
      case 'get_series_categories':
        return jsonEncode(_seriesCategories.map((c) => c.toJson()).toList());
      case 'get_live_streams':
        return jsonEncode((bigLive ? _bigLiveRows : _liveRows).map((r) => r.toJson()).toList());
      case 'get_vod_streams':
        return jsonEncode(_movieRows.map((r) => r.toJson()).toList());
      case 'get_series':
        final rows = partialSeries ? _seriesRows().where((r) => r.categoryId == 'cat1').toList() : _seriesRows();
        return jsonEncode(rows.map((r) => r.toJson()).toList());
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

IptvClient _clientWith(
  _HiddenPanel panel, {
  List<String> hiddenCategoryIds = const [],
  List<String> hiddenCategoryInitials = const [],
}) {
  final connection = XtreamConnection(
    id: _connId,
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    hiddenCategoryIds: hiddenCategoryIds,
    hiddenCategoryInitials: hiddenCategoryInitials,
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

int _rows(IptvClient client, String type) => client.searchIndexState.rowCounts[type] ?? 0;

void _setHidden(IptvClient client, {List<String> ids = const [], List<String> initials = const []}) {
  client.connection = (client.connection as XtreamConnection).copyWith(
    hiddenCategoryIds: ids,
    hiddenCategoryInitials: initials,
  );
}

Future<List<Map<String, dynamic>>> _readDiskSeriesRows() async {
  final cache = IptvCatalogDiskCache();
  final entry = await cache.read(_connId, IptvCatalogDiskCache.seriesDataset);
  if (entry == null) return const [];
  final decoded = jsonDecode(entry.body);
  if (decoded is! List) return const [];
  return decoded.whereType<Map<String, dynamic>>().toList();
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_hidden_cats_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
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

  group('hidden categories, pruned at write time v1.2.4', () {
    test('H1: hidden-by-id rows are pruned at write time and stay unsearchable', () async {
      final client = _clientWith(_HiddenPanel(), hiddenCategoryIds: const ['cat3', 'cat4']);

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H1: rows=${result.rows} seriesIndexRows=${_rows(client, IptvSearchIndex.typeSeries)}');

      // 1.2.4: only the 8 visible rows land (cat3/cat4's 4 are pruned).
      expect(result.rows[IptvSearchIndex.typeSeries], 8);
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect((await client.searchItems('|EN| Drama Show 1')).map((m) => m.title), contains('|EN| Drama Show 1'));
      expect(
        (await client.searchItems('AR - Series Show 1')).map((m) => m.title),
        isNot(contains('AR - Series Show 1')),
        reason: 'a hidden category must not be searchable',
      );
      // The pruned row is not stored, so it can never match a search:
      // the hidden-match diagnostic reads 0 now (see the file header).
      expect(client.lastSearchDiagnostics!.series.hiddenMatches, 0);
      expect(client.lastSearchDiagnostics!.series.hiddenInitials, isEmpty);
    });

    test('H2: hidden-by-initial rows are pruned at write time and stay unsearchable', () async {
      final client = _clientWith(_HiddenPanel(), hiddenCategoryInitials: const ['AR']);

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H2: rows=${result.rows} seriesIndexRows=${_rows(client, IptvSearchIndex.typeSeries)}');

      // 1.2.4: only the 8 visible rows land (both AR categories pruned).
      expect(result.rows[IptvSearchIndex.typeSeries], 8);
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect(
        (await client.searchItems('AR - Kids Show 1')).map((m) => m.title),
        isNot(contains('AR - Kids Show 1')),
        reason: 'hiding the AR initial hides every AR category',
      );
      expect(client.lastSearchDiagnostics!.series.hiddenMatches, 0);
      expect(client.lastSearchDiagnostics!.series.hiddenInitials, isEmpty);
    });

    test('H3: the 0.5 guard counts visible categories — hiding most is not partial', () async {
      // 5 of 6 categories hidden: only cat1 is visible (2 rows), and
      // the fetch covers the whole VISIBLE catalog, so it is complete
      // — not partial. (1.2.4: the guard compares visible-fetched
      // against visible-indexed, not against the full catalog.)
      final client = _clientWith(
        _HiddenPanel(),
        hiddenCategoryIds: const ['cat2', 'cat3', 'cat4', 'cat5', 'cat6'],
      );

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H3: rows=${result.rows} partial=${result.partialTypes}');

      expect(result.rows[IptvSearchIndex.typeSeries], 2);
      expect(result.partialTypes, isNot(contains(IptvSearchIndex.typeSeries)),
          reason: '2 of 2 visible categories is complete, not partial');
      expect(client.searchIndexState.lastSync[IptvSearchIndex.typeSeries], isNotNull,
          reason: 'a complete land stamps lastSync like any complete sync');
    });

    test('H3b: hiding every category lands an empty, stamped type', () async {
      final client = _clientWith(
        _HiddenPanel(),
        hiddenCategoryIds: const ['cat1', 'cat2', 'cat3', 'cat4', 'cat5', 'cat6'],
      );

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H3b: rows=${result.rows} skipped=${result.skipped}');

      // 1.2.4: a complete land with every category hidden stamps 0
      // rows — a deliberate empty land, not a cold type (FORK §45.7).
      expect(result.rows[IptvSearchIndex.typeSeries], 0);
      expect(result.skipped[IptvSearchIndex.typeSeries], isNull);
      expect(_rows(client, IptvSearchIndex.typeSeries), 0);
      expect(client.searchIndexState.lastSync[IptvSearchIndex.typeSeries], isNotNull,
          reason: 'a stamped empty land is not re-fetched every bind');
      // Every row is hidden at read time, so search finds nothing.
      expect((await client.searchItems('Show 1')).map((m) => m.title), isEmpty);
    });

    test('H4: hiding a category prunes its rows at the next sync — the index drops them', () async {
      final client = _clientWith(_HiddenPanel());

      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 12);
      expect((await client.searchItems('AR - Series Show 1')).map((m) => m.title), contains('AR - Series Show 1'));

      _setHidden(client, ids: const ['cat3', 'cat4']);
      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H4: rows=${result.rows} seriesIndexRows=${_rows(client, IptvSearchIndex.typeSeries)}');

      // 1.2.4: the sync prunes cat3/cat4's rows from the index (the
      // read-time filter still hides them too, for a legacy full index).
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect(
        (await client.searchItems('AR - Series Show 1')).map((m) => m.title),
        isNot(contains('AR - Series Show 1')),
        reason: 'a hidden category must not be searchable',
      );
      expect(client.lastSearchDiagnostics!.series.hiddenMatches, 0);
    });

    test('H5: re-enabling a category does NOT restore its rows without a sync (prune trade-off)', () async {
      final client = _clientWith(_HiddenPanel());

      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 12);
      _setHidden(client, ids: const ['cat3', 'cat4']);
      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect(
        (await client.searchItems('AR - Series Show 1')).map((m) => m.title),
        isNot(contains('AR - Series Show 1')),
      );

      // Turn cat3/cat4 back on. 1.2.4: the rows were PRUNED, so the
      // show stays unfindable until a re-sync — the trade-off Matt
      // accepted (the un-hide notice + Refresh guards it in the app).
      _setHidden(client);
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect(
        (await client.searchItems('AR - Series Show 1')).map((m) => m.title),
        isNot(contains('AR - Series Show 1')),
        reason: 'pruned rows need a re-sync, they do not come back on toggle alone',
      );

      // The re-sync brings them back.
      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 12);
      expect((await client.searchItems('AR - Series Show 1')).map((m) => m.title), contains('AR - Series Show 1'));
    });

    test('H6: the disk catalog holds visible rows only', () async {
      final client = _clientWith(_HiddenPanel(), hiddenCategoryIds: const ['cat3', 'cat4']);

      await client.syncSearchIndex(force: true);
      final diskRows = await _readDiskSeriesRows();
      // ignore: avoid_print
      print('H6: disk series rows=${diskRows.length}');

      // 1.2.4 (Matt's prune decision): cat3/cat4's rows are pruned
      // from the disk file too, not just the index.
      expect(diskRows.length, 8);
      expect(diskRows.map((r) => r['category_id']), isNot(contains('cat3')));
      expect(diskRows.map((r) => r['category_id']), isNot(contains('cat4')));
    });

    test('H7: the seed lands visible rows from a full disk file (prunes at write time)', () async {
      final client = _clientWith(_HiddenPanel(), hiddenCategoryIds: const ['cat3', 'cat4']);
      final cache = IptvCatalogDiskCache();
      await cache.write(
        _connId,
        IptvCatalogDiskCache.seriesDataset,
        jsonEncode(_seriesRows().map((r) => r.toJson()).toList()),
      );
      await cache.write(
        _connId,
        IptvCatalogDiskCache.seriesCategoriesDataset,
        jsonEncode(_seriesCategories.map((c) => c.toJson()).toList()),
      );

      await client.seedSearchIndexFromDisk();
      await client.searchIndexReady;
      // ignore: avoid_print
      print('H7: seriesIndexRows after seed=${_rows(client, IptvSearchIndex.typeSeries)}');

      // 1.2.4: the seed prunes the hidden rows at write time — a
      // pre-1.2.4 full disk file lands visible-only in the index.
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect(
        (await client.searchItems('AR - Series Show 1')).map((m) => m.title),
        isNot(contains('AR - Series Show 1')),
        reason: 'pruned by the seed, not just hidden at read time',
      );
    });

    test('H8: a first-load browse write prunes hidden rows from disk', () async {
      final client = _clientWith(_HiddenPanel(), hiddenCategoryIds: const ['cat3', 'cat4']);

      final hubs = await client.fetchGlobalHubs();
      expect(hubs.map((h) => h.title), contains('Trex — Series'));

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      var diskRows = const <Map<String, dynamic>>[];
      while (diskRows.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        diskRows = await _readDiskSeriesRows();
      }
      // ignore: avoid_print
      print('H8: disk series rows=${diskRows.length}');
      expect(diskRows.length, 8);
      expect(diskRows.map((r) => r['category_id']), isNot(contains('cat3')));
      expect(diskRows.map((r) => r['category_id']), isNot(contains('cat4')));
    });

    test('H9: sync counts reflect the full catalog across all three types', () async {
      final client = _clientWith(
        _HiddenPanel(),
        hiddenCategoryIds: const ['live2', 'mov2', 'cat3', 'cat4'],
      );

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H9: rows=${result.rows}');

      // 1.2.4: the counts are the VISIBLE landed counts (one hidden
      // category per type: live2, mov2, cat3+cat4).
      expect(result.rows, {
        IptvSearchIndex.typeLive: 2,
        IptvSearchIndex.typeMovie: 2,
        IptvSearchIndex.typeSeries: 8,
      });
    });

    test('H10: all-hidden sync lands an empty, stamped catalog on disk and in the index', () async {
      // 1.2.4: an all-hidden type writes an empty-array disk file, not
      // no file — so the next load reads the deliberate empty instead
      // of re-fetching (FORK §45.3). The land still stamps lastSync.
      final client = _clientWith(
        _HiddenPanel(),
        hiddenCategoryIds: const ['cat1', 'cat2', 'cat3', 'cat4', 'cat5', 'cat6'],
      );

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H10: rows=${result.rows} skipped=${result.skipped}');

      expect(result.rows[IptvSearchIndex.typeSeries], 0);
      expect(_rows(client, IptvSearchIndex.typeSeries), 0);
      expect(client.searchIndexState.lastSync[IptvSearchIndex.typeSeries], isNotNull);
      final diskRows = await _readDiskSeriesRows();
      expect(diskRows.length, 0,
          reason: 'the disk file holds visible rows only — here, none');
    });

    test('H11: hiding 600 categories prunes all 600 rows at the next sync', () async {
      final panel = _HiddenPanel()..bigLive = true;
      final client = _clientWith(panel);

      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeLive), 600);

      _setHidden(client, ids: [for (var i = 1; i <= 600; i++) 'L$i']);
      await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H11: liveIndexRows=${_rows(client, IptvSearchIndex.typeLive)}');

      // 1.2.4: the prune deletes the hidden rows in one transaction
      // (upsertType deleteCategoryIds) — no 500-row chunking concern.
      expect(_rows(client, IptvSearchIndex.typeLive), 0);
      expect((await client.searchItems('Live 599')).map((m) => m.title), isNot(contains('Live 599')));
      expect(client.lastSearchDiagnostics!.live.hiddenMatches, 0);
    });

    test('H12: a failed sync after re-enable leaves the type up-to-date — and the rows still pruned', () async {
      // D1, 1.2.4 shape: the hide-sync pruned cat3/cat4's rows. Re-enable,
      // then the panel goes down for the whole sync: the failed run
      // changes nothing, and the next plain sync correctly skips the
      // type as up-to-date instead of re-fetching it — so the rows
      // stay pruned until a FORCED sync (the notice's Refresh).
      final panel = _HiddenPanel();
      final client = _clientWith(panel);

      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 12);
      _setHidden(client, ids: const ['cat3', 'cat4']);
      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);

      _setHidden(client);
      panel.fail = true;
      final failed = await client.syncSearchIndex(force: true);
      expect(failed.skipped[IptvSearchIndex.typeSeries], 'failed');
      panel.fail = false;

      final retry = await client.syncSearchIndex();
      // ignore: avoid_print
      print('H12: retry skipped=${retry.skipped} rows=${retry.rows} seriesIndexRows=${_rows(client, IptvSearchIndex.typeSeries)}');
      expect(retry.skipped[IptvSearchIndex.typeSeries], 'up-to-date',
          reason: 'nothing is due: the last sync stamped recently');
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect(
        (await client.searchItems('AR - Series Show 1')).map((m) => m.title),
        isNot(contains('AR - Series Show 1')),
        reason: 'up-to-date skips the re-fetch, so the pruned rows stay pruned',
      );

      // A forced sync (the notice's Refresh) restores them.
      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 12);
      expect((await client.searchItems('AR - Series Show 1')).map((m) => m.title), contains('AR - Series Show 1'));
    });

    test('H13: a partial-kept sync after re-enable leaves the type up-to-date — and the rows still pruned', () async {
      // D1, second trigger, 1.2.4 shape: the panel answers but with a
      // partial list (2 visible rows < half of 8 visible-indexed), so
      // the warm guard keeps the old rows. The re-enabled rows were
      // pruned, so nothing is owed — the next plain sync correctly
      // skips the type as up-to-date, and the show stays unfindable
      // until a FORCED sync.
      final panel = _HiddenPanel();
      final client = _clientWith(panel);

      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 12);
      _setHidden(client, ids: const ['cat3', 'cat4']);
      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);

      _setHidden(client);
      panel.partialSeries = true;
      final partial = await client.syncSearchIndex(force: true);
      expect(partial.skipped[IptvSearchIndex.typeSeries], 'partial-kept');
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      panel.partialSeries = false;

      final retry = await client.syncSearchIndex();
      // ignore: avoid_print
      print('H13: retry skipped=${retry.skipped} rows=${retry.rows} seriesIndexRows=${_rows(client, IptvSearchIndex.typeSeries)}');
      expect(retry.skipped[IptvSearchIndex.typeSeries], 'up-to-date',
          reason: 'nothing is due: the last sync stamped recently');
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect(
        (await client.searchItems('AR - Series Show 1')).map((m) => m.title),
        isNot(contains('AR - Series Show 1')),
        reason: 'up-to-date skips the re-fetch, so the pruned rows stay pruned',
      );

      // A forced sync (the notice's Refresh) restores them.
      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 12);
      expect((await client.searchItems('AR - Series Show 1')).map((m) => m.title), contains('AR - Series Show 1'));
    });
  });
}
