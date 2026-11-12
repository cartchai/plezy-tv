// HIDDEN-CATEGORY SKIP — PlezTV v1.0.16 (Matt, 2026-11-12: "make it so
// data from turned off categories doesn't download or cache").
//
// Data from turned-off (hidden) categories must not land in the search
// index, the seed, or the disk catalog — all three types. The hidden
// state is the country/region filter: per-category ids plus
// letter-group initials, resolved by the existing
// `IptvClient._isHiddenCategory` rule (id OR initial).
//
// Failing-first: every test below FAILS on ef634b923 for the product
// reason (hidden rows land in the index/disk) and PASSES with the fix.
// The tests use only pre-existing public API, so they compile on base.

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

/// Fake panel: complete lists for all three types.
class _HiddenPanel extends http.BaseClient {
  int totalRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
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
        return jsonEncode(_liveCategories.map((c) => c.toJson()).toList());
      case 'get_vod_categories':
        return jsonEncode(_movieCategories.map((c) => c.toJson()).toList());
      case 'get_series_categories':
        return jsonEncode(_seriesCategories.map((c) => c.toJson()).toList());
      case 'get_live_streams':
        return jsonEncode(_liveRows.map((r) => r.toJson()).toList());
      case 'get_vod_streams':
        return jsonEncode(_movieRows.map((r) => r.toJson()).toList());
      case 'get_series':
        return jsonEncode(_seriesRows().map((r) => r.toJson()).toList());
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

  group('hidden-category skip v1.0.16', () {
    test('H1: hidden-by-id rows never land in the index', () async {
      final client = _clientWith(_HiddenPanel(), hiddenCategoryIds: const ['cat3', 'cat4']);

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H1: rows=${result.rows} seriesIndexRows=${_rows(client, IptvSearchIndex.typeSeries)}');

      expect(result.rows[IptvSearchIndex.typeSeries], 8);
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect((await client.searchItems('|EN| Drama Show 1')).map((m) => m.title), contains('|EN| Drama Show 1'));
      expect(
        (await client.searchItems('AR - Series Show 1')).map((m) => m.title),
        isNot(contains('AR - Series Show 1')),
        reason: 'a hidden category must not be searchable',
      );
    });

    test('H2: hidden-by-initial rows never land in the index', () async {
      final client = _clientWith(_HiddenPanel(), hiddenCategoryInitials: const ['AR']);

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H2: rows=${result.rows} seriesIndexRows=${_rows(client, IptvSearchIndex.typeSeries)}');

      expect(result.rows[IptvSearchIndex.typeSeries], 8);
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect(
        (await client.searchItems('AR - Kids Show 1')).map((m) => m.title),
        isNot(contains('AR - Kids Show 1')),
        reason: 'hiding the AR initial hides every AR category',
      );
    });

    test('H3: the 0.5 guard counts visible categories only', () async {
      // 5 of 6 categories hidden: the fetch covers the ONE visible
      // category, so it is a complete visible catalog — not partial.
      final client = _clientWith(
        _HiddenPanel(),
        hiddenCategoryIds: const ['cat2', 'cat3', 'cat4', 'cat5', 'cat6'],
      );

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H3: rows=${result.rows} partial=${result.partialTypes}');

      expect(result.rows[IptvSearchIndex.typeSeries], 2);
      expect(result.partialTypes, isNot(contains(IptvSearchIndex.typeSeries)),
          reason: '1 of 1 visible categories is complete, not partial');
      expect(client.searchIndexState.lastSync[IptvSearchIndex.typeSeries], isNotNull,
          reason: 'a complete visible land stamps lastSync like any complete sync');
    });

    test('H3b: hiding every category lands an empty, stamped type', () async {
      final client = _clientWith(
        _HiddenPanel(),
        hiddenCategoryIds: const ['cat1', 'cat2', 'cat3', 'cat4', 'cat5', 'cat6'],
      );

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H3b: rows=${result.rows} skipped=${result.skipped}');

      expect(result.rows[IptvSearchIndex.typeSeries], 0);
      expect(result.skipped[IptvSearchIndex.typeSeries], isNull);
      expect(_rows(client, IptvSearchIndex.typeSeries), 0);
      expect(client.searchIndexState.lastSync[IptvSearchIndex.typeSeries], isNotNull,
          reason: 'an all-hidden land stamps, so the type is not re-fetched every bind');
    });

    test('H4: hiding a category purges its rows at the next sync', () async {
      final client = _clientWith(_HiddenPanel());

      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 12);
      expect((await client.searchItems('AR - Series Show 1')).map((m) => m.title), contains('AR - Series Show 1'));

      _setHidden(client, ids: const ['cat3', 'cat4']);
      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H4: rows=${result.rows} seriesIndexRows=${_rows(client, IptvSearchIndex.typeSeries)}');

      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect(
        (await client.searchItems('AR - Series Show 1')).map((m) => m.title),
        isNot(contains('AR - Series Show 1')),
        reason: 'rows cached before the hide must be purged, not kept by the merge',
      );
    });

    test('H5: re-enabling a category re-fetches its rows even when fresh', () async {
      final client = _clientWith(_HiddenPanel());

      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 12);
      _setHidden(client, ids: const ['cat3', 'cat4']);
      await client.syncSearchIndex(force: true);
      expect(_rows(client, IptvSearchIndex.typeSeries), 8);

      // Turn cat3/cat4 back on. The type looks fresh (stamped minutes
      // ago, 8 rows) — without the hidden-fingerprint the sync would
      // skip it as up-to-date and the rows would never come back.
      _setHidden(client);
      final result = await client.syncSearchIndex();
      // ignore: avoid_print
      print('H5: rows=${result.rows} skipped=${result.skipped} seriesIndexRows=${_rows(client, IptvSearchIndex.typeSeries)}');

      expect(result.skipped[IptvSearchIndex.typeSeries], isNull);
      expect(_rows(client, IptvSearchIndex.typeSeries), 12);
      expect((await client.searchItems('AR - Series Show 1')).map((m) => m.title), contains('AR - Series Show 1'));
    });

    test('H6: the disk catalog holds visible rows only', () async {
      final client = _clientWith(_HiddenPanel(), hiddenCategoryIds: const ['cat3', 'cat4']);

      await client.syncSearchIndex(force: true);
      final diskRows = await _readDiskSeriesRows();
      // ignore: avoid_print
      print('H6: disk series rows=${diskRows.length}');

      expect(diskRows, isNotEmpty);
      expect(diskRows.map((r) => r['category_id']), everyElement(isNot(anyOf('cat3', 'cat4'))));
    });

    test('H7: the seed filters hidden rows out of a disk file', () async {
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

      expect(_rows(client, IptvSearchIndex.typeSeries), 8);
      expect(
        (await client.searchItems('AR - Series Show 1')).map((m) => m.title),
        isNot(contains('AR - Series Show 1')),
      );
    });

    test('H8: a first-load browse write filters hidden rows from disk', () async {
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
      expect(diskRows, isNotEmpty);
      expect(diskRows.map((r) => r['category_id']), everyElement(isNot(anyOf('cat3', 'cat4'))));
    });

    test('H9: sync counts reflect visible data across all three types', () async {
      final client = _clientWith(
        _HiddenPanel(),
        hiddenCategoryIds: const ['live2', 'mov2', 'cat3', 'cat4'],
      );

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('H9: rows=${result.rows}');

      expect(result.rows, {
        IptvSearchIndex.typeLive: 2,
        IptvSearchIndex.typeMovie: 2,
        IptvSearchIndex.typeSeries: 8,
      });
    });
  });
}
