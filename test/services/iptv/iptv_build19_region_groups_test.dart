// Schema repair — PlezTV v1.0.19 (Option B).
//
// The v1.0.16 write-time skip wrote lossy index + disk files (visible
// rows only). On upgrade, a per-connection schema flag
// (`iptv_catalog_schema_v:<connectionId>`, current 2) forces the next
// sync to re-fetch every type once — the repair — and version 2 is
// stamped only on a clean run (same D1 rule as the old hidden
// fingerprint: a failed/empty/oversize/partial-kept leg, or a transport
// failure, leaves it unstamped so the next sync retries). A hidden-set
// change no longer forces a sync at all.
//
// These tests use the same fake-panel pattern as the region-groups
// probes (XtreamApi subclass, no HTTP plumbing). The version is read
// back through BaseSharedPreferencesService.sharedCache() — the same
// store the client's helpers use.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';
const _connId = 'conn-xt-1';
const _schemaKey = 'iptv_catalog_schema_v:$_connId';

Future<int> _schemaVersion() async {
  final prefs = await BaseSharedPreferencesService.sharedCache();
  return prefs.getInt(_schemaKey) ?? 0;
}

Future<void> _setSchemaVersion(int version) async {
  final prefs = await BaseSharedPreferencesService.sharedCache();
  await prefs.setInt(_schemaKey, version);
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build19_repair_');
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

  Future<IptvClient> clientWith(_RepairFakeApi api) async {
    final connection = XtreamConnection(
      id: _connId,
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    client.testXtreamApi = api;
    addTearDown(client.close);
    return client;
  }

  group('schema repair v1.0.19', () {
    test('a clean first sync stamps schema version 2', () async {
      final client = await clientWith(_RepairFakeApi());
      expect(await _schemaVersion(), 0);

      final result = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('repair-first: rows=${result.rows} version=${await _schemaVersion()}');

      expect(result.rows[IptvSearchIndex.typeSeries], 6);
      expect(await _schemaVersion(), 2);
    });

    test('a pre-1.0.19 install (version 1) re-fetches on the next plain sync', () async {
      final client = await clientWith(_RepairFakeApi());

      await client.syncSearchIndex(force: true);
      expect(await _schemaVersion(), 2);
      // Simulate the upgrade: the stored files are v1.0.16 lossy.
      await _setSchemaVersion(1);

      final repair = await client.syncSearchIndex();
      // ignore: avoid_print
      print('repair-run: skipped=${repair.skipped} rows=${repair.rows} version=${await _schemaVersion()}');

      expect(repair.skipped[IptvSearchIndex.typeSeries], isNull);
      expect(repair.skipped[IptvSearchIndex.typeLive], isNull);
      expect(repair.skipped[IptvSearchIndex.typeMovie], isNull);
      expect(repair.rows[IptvSearchIndex.typeSeries], 6);
      expect(await _schemaVersion(), 2);

      // And the run after the repair is up-to-date again, not a re-fetch.
      final after = await client.syncSearchIndex();
      expect(after.skipped[IptvSearchIndex.typeSeries], 'up-to-date');
    });

    test('a failed repair run does not stamp, the next sync retries', () async {
      final api = _RepairFakeApi();
      final client = await clientWith(api);

      await client.syncSearchIndex(force: true);
      await _setSchemaVersion(1);

      api.fail = true;
      final failed = await client.syncSearchIndex();
      expect(failed.skipped[IptvSearchIndex.typeSeries], 'failed');
      expect(await _schemaVersion(), 1,
          reason: 'a failed run must not claim the repair is done');
      api.fail = false;

      final retry = await client.syncSearchIndex();
      // ignore: avoid_print
      print('repair-retry: skipped=${retry.skipped} rows=${retry.rows} version=${await _schemaVersion()}');
      expect(retry.skipped[IptvSearchIndex.typeSeries], isNull);
      expect(retry.rows[IptvSearchIndex.typeSeries], 6);
      expect(await _schemaVersion(), 2);
    });

    test('a partial-kept repair run does not stamp, the next sync retries', () async {
      final api = _RepairFakeApi();
      final client = await clientWith(api);

      await client.syncSearchIndex(force: true);
      await _setSchemaVersion(1);

      api.partialSeries = true;
      final partial = await client.syncSearchIndex();
      expect(partial.skipped[IptvSearchIndex.typeSeries], 'partial-kept');
      expect(await _schemaVersion(), 1,
          reason: 'a partial-kept run must not claim the repair is done');
      api.partialSeries = false;

      final retry = await client.syncSearchIndex();
      // ignore: avoid_print
      print('repair-retry-partial: skipped=${retry.skipped} rows=${retry.rows} version=${await _schemaVersion()}');
      expect(retry.skipped[IptvSearchIndex.typeSeries], isNull);
      expect(retry.rows[IptvSearchIndex.typeSeries], 6);
      expect(await _schemaVersion(), 2);
    });

    test('hiding and re-enabling needs no sync — the version is untouched by toggles', () async {
      final client = await clientWith(_RepairFakeApi());

      await client.syncSearchIndex(force: true);
      expect(await _schemaVersion(), 2);

      // Hide cat3, then re-enable it. Neither toggle makes anything due:
      // the stored catalog is unaffected by the filter.
      final hidden = (client.connection as XtreamConnection).copyWith(hiddenCategoryIds: const ['cat3']);
      client.updateConnection(hidden);
      final afterHide = await client.syncSearchIndex();
      expect(afterHide.skipped[IptvSearchIndex.typeSeries], 'up-to-date');
      expect(await _schemaVersion(), 2);
      expect((await client.searchItems('AR - Series Show 1')).map((m) => m.title), isNot(contains('AR - Series Show 1')));

      client.updateConnection((client.connection as XtreamConnection).copyWith(hiddenCategoryIds: const []));
      expect((await client.searchItems('AR - Series Show 1')).map((m) => m.title), contains('AR - Series Show 1'));
      expect(await _schemaVersion(), 2);
    });
  });
}

/// Small fake panel: 3 series categories (6 rows), 1 live channel,
/// 1 movie. Switches: fail (every request throws) and partialSeries
/// (get_series returns only cat1's 2 rows — a warm partial-kept).
class _RepairFakeApi extends XtreamApi {
  _RepairFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  bool fail = false;
  bool partialSeries = false;

  static const _seriesCategories = [
    XtreamCategory(id: 'cat1', name: '|EN| Drama'),
    XtreamCategory(id: 'cat2', name: '|EN| Comedy'),
    XtreamCategory(id: 'cat3', name: 'AR - Series'),
  ];

  List<XtreamSeries> _seriesRows() => [
        for (final c in _seriesCategories)
          for (var i = 1; i <= 2; i++)
            XtreamSeries(seriesId: 7000 + int.parse(c.id.substring(3)) * 10 + i, name: '${c.name} Show $i', categoryId: c.id),
      ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async {
    if (fail) throw Exception('panel down (test)');
    return _seriesCategories;
  }

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async {
    if (fail) throw Exception('panel down (test)');
    return const [XtreamCategory(id: '1', name: '|EN| Movies 1')];
  }

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async {
    if (fail) throw Exception('panel down (test)');
    return const [XtreamCategory(id: '1', name: '|EN| Live 1')];
  }

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    if (fail) throw Exception('panel down (test)');
    final rows = partialSeries ? _seriesRows().where((r) => r.categoryId == 'cat1').toList() : _seriesRows();
    if (categoryId == null) {
      lastSeriesBody = jsonEncode(rows.map((r) => r.toJson()).toList());
      return rows;
    }
    return rows.where((s) => s.categoryId == categoryId).toList();
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (fail) throw Exception('panel down (test)');
    const rows = [XtreamVodStream(streamId: 1, name: 'EN - Movie 1', categoryId: '1')];
    if (categoryId == null) {
      lastVodStreamsBody = jsonEncode(rows.map((r) => r.toJson()).toList());
      return rows;
    }
    return rows.where((s) => s.categoryId == categoryId).toList();
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (fail) throw Exception('panel down (test)');
    const rows = [XtreamLiveStream(streamId: 1, name: 'EN - Live Channel 1', categoryId: '1')];
    if (categoryId == null) {
      lastLiveStreamsBody = jsonEncode(rows.map((r) => r.toJson()).toList());
      return rows;
    }
    return rows.where((s) => s.categoryId == categoryId).toList();
  }
}
