// ONE-PARSE SYNC — PlezTV v1.2.10 (research item #2, FORK §51).
//
// The sync used to parse the VOD body THREE times per type and copy it
// across the isolate port twice, while the main isolate held the body
// String + the full parsed list + the visible list. After the fix the
// network response streams straight to a temp disk file and ONE isolate
// job parses once, writes the index, writes the visible-only disk file,
// and returns the counts + visible rows for the memo publish.
//
// Proof T-S1: a sync must never leave the raw body on the main isolate
// (the api's last*StreamsBody stays null) while the index, disk file
// and memos land exactly as before. The guards (empty / partial-kept /
// oversize / failed) keep their semantics — S3/S4 pin the two the
// fixture can reach, the oversize arm is pinned by the existing
// build23 test (its fake throws past the fetch, same arm).
//
// Failing-first: S1, S2, S5, S6 fail on the 1.2.9 base (the sync sets
// last*StreamsBody); S3/S4 pass on the base (guard regression guards).
// S7 could not be written failing-first — the to-file getter did not
// exist on the base (it would not compile). No RSS bound is asserted:
// the peak RSS during a Trex-scale sync is 256-295MB on the fix vs
// 255-270MB on the base (measured 2026-11-14) — indistinguishable in
// this harness, so a bound would pass on the base or flake; the
// deterministic proof is the null-body assertion + identical lands.

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
  XtreamCategory(id: 'mov4', name: 'UK: Movies'),
];
List<XtreamVodStream> _movieRows() => [
      for (final c in _movieCategories)
        for (var i = 1; i <= 2; i++)
          XtreamVodStream(streamId: 10 + int.parse(c.id.substring(3)) * 10 + i, name: '${c.name} Movie $i', categoryId: c.id),
    ];

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

/// Fake panel: complete lists for all three types, over a real
/// [XtreamApi] + fake http client — so the sync's fetch path is the
/// production one (stream-to-file vs buffered body is genuinely
/// exercised, not faked around).
class _OneParsePanel extends http.BaseClient {
  // Test switches (each defaults to the healthy panel):
  // partialSeries — get_series returns only cat1's 2 rows (warm
  // partial-kept guard: 2 < 12 ~/ 2); emptySeries — get_series returns
  // '[]'; fail — every request throws a transport error.
  bool partialSeries = false;
  bool emptySeries = false;
  bool fail = false;

  // Trex-scale VOD override: when set, get_vod_streams serves this
  // pre-encoded body (built once by the test, outside the sync).
  String? trexVodBody;
  List<XtreamCategory>? trexVodCategories;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (fail) throw http.ClientException('panel unreachable (test)', request.url);
    final action = request.url.queryParameters['action'];
    return http.StreamedResponse(
      Stream.value(utf8.encode(_bodyFor(action))),
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
        return jsonEncode((trexVodCategories ?? _movieCategories).map((c) => c.toJson()).toList());
      case 'get_series_categories':
        return jsonEncode(_seriesCategories.map((c) => c.toJson()).toList());
      case 'get_live_streams':
        return jsonEncode(_liveRows.map((r) => r.toJson()).toList());
      case 'get_vod_streams':
        if (trexVodBody != null) return trexVodBody!;
        return jsonEncode(_movieRows().map((r) => r.toJson()).toList());
      case 'get_series':
        if (emptySeries) return '[]';
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

({IptvClient client, XtreamApi api}) _clientWith(
  _OneParsePanel panel, {
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
  final api = XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    httpClient: panel,
  );
  client.testXtreamApi = api;
  addTearDown(client.close);
  return (client: client, api: api);
}

Future<List<Map<String, dynamic>>> _readDiskRows(String dataset) async {
  final cache = IptvCatalogDiskCache();
  final entry = await cache.read(_connId, dataset);
  if (entry == null) return const [];
  final decoded = jsonDecode(entry.body);
  if (decoded is! List) return const [];
  return decoded.whereType<Map<String, dynamic>>().toList();
}

/// Temp dirs alive right now (the sync's own prefix only). The suite
/// shares systemTemp and runs files in parallel, so a test must never
/// assert the global count is zero — another file's sync may be
/// mid-run. Instead each test snapshots this set before its sync and
/// asserts (below) that no NEW dir survives its own sync.
Future<Set<String>> _syncTempEntries() async {
  final tmp = Directory.systemTemp;
  if (!await tmp.exists()) return {};
  final found = <String>{};
  await for (final entity in tmp.list()) {
    if (entity.path.contains('plezy_sync_')) found.add(entity.path);
  }
  return found;
}

/// No temp dir from THIS sync survives it: the post-sync set must
/// settle back to (a subset of) the pre-sync set. An in-flight dir
/// from a concurrent test may appear mid-run, so poll briefly for it
/// to finish rather than failing on it — a real leak (this sync's dir
/// never deleted) never settles and fails at the deadline.
Future<void> _expectNoSyncTempLeftovers(Set<String> before) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    final extra = (await _syncTempEntries()).difference(before);
    if (extra.isEmpty) return;
    if (DateTime.now().isAfter(deadline)) {
      fail('sync left temp dirs behind: $extra');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_one_parse_');
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

  group('one-parse sync v1.2.10', () {
    test('S1: VOD sync never holds the body on main, lands visible rows everywhere', () async {
      final tempBefore = await _syncTempEntries();
      final panel = _OneParsePanel();
      final (:client, :api) = _clientWith(panel, hiddenCategoryIds: const ['mov2']);

      final result = await client.syncSearchIndex(force: true);

      expect(result.skipped, isEmpty, reason: 'skipped=$result.skipped');
      // THE one-parse assertion: the main isolate never held the body.
      expect(api.lastVodStreamsBody, isNull);
      expect(api.lastLiveStreamsBody, isNull);
      expect(api.lastSeriesBody, isNull);
      // Index holds visible rows only (mov2's 2 pruned).
      expect(client.searchIndexState.rowCounts['movie'], 6);
      // Disk file holds exactly the visible rows (mov1: 21,22; mov3:
      // 41,42; mov4: 51,52 — mov2's 31,32 pruned at write time).
      final disk = await _readDiskRows(IptvCatalogDiskCache.vodDataset);
      expect(disk.map((r) => r['stream_id']).toList()..sort(), [21, 22, 41, 42, 51, 52]);
      expect(disk.every((r) => r['category_id'] != 'mov2'), isTrue);
      // No temp files left behind.
      await _expectNoSyncTempLeftovers(tempBefore);
    });

    test('S2: live + series sync never holds the body on main, memos publish', () async {
      final tempBefore = await _syncTempEntries();
      final panel = _OneParsePanel();
      final (:client, :api) = _clientWith(panel, hiddenCategoryIds: const ['live2']);

      final result = await client.syncSearchIndex(force: true);

      expect(result.skipped, isEmpty, reason: 'skipped=$result.skipped');
      expect(api.lastLiveStreamsBody, isNull);
      expect(api.lastSeriesBody, isNull);
      expect(client.searchIndexState.rowCounts['live'], 2);
      expect(client.searchIndexState.rowCounts['series'], 12);
      // The memo publish: iptvChannels reads the live memo — the fresh
      // rows are there without a restart, hidden channel excluded.
      final channels = await client.iptvChannels();
      expect(channels.map((c) => c.title), contains('EN News'));
      expect(channels.map((c) => c.title).any((t) => (t ?? '').contains('AR Live')), isFalse);
      await _expectNoSyncTempLeftovers(tempBefore);
    });

    test('S3: partial-kept guard preserved — warm partial series keeps old rows', () async {
      final tempBefore = await _syncTempEntries();
      final panel = _OneParsePanel();
      final (:client, :api) = _clientWith(panel);

      final first = await client.syncSearchIndex(force: true);
      expect(first.skipped, isEmpty);
      expect(client.searchIndexState.rowCounts['series'], 12);

      panel.partialSeries = true;
      final second = await client.syncSearchIndex(force: true);

      expect(second.skipped['series'], 'partial-kept');
      expect(client.searchIndexState.rowCounts['series'], 12);
      expect(api.lastSeriesBody, isNull);
      await _expectNoSyncTempLeftovers(tempBefore);
    });

    test('S4: empty-response guard preserved — empty series keeps old rows', () async {
      final tempBefore = await _syncTempEntries();
      final panel = _OneParsePanel();
      final (:client, :api) = _clientWith(panel);

      final first = await client.syncSearchIndex(force: true);
      expect(first.skipped, isEmpty);
      expect(client.searchIndexState.rowCounts['series'], 12);

      panel.emptySeries = true;
      final second = await client.syncSearchIndex(force: true);

      expect(second.skipped['series'], 'empty-response');
      expect(client.searchIndexState.rowCounts['series'], 12);
      expect(api.lastSeriesBody, isNull);
      await _expectNoSyncTempLeftovers(tempBefore);
    });

    test('S5: background path (R4) also never holds the body on main', () async {
      final tempBefore = await _syncTempEntries();
      // Stale-warm pattern (R4 tests): write the disk files, backdate
      // them 8 days, warm the catalogs from disk — the background sync
      // then finds all three types warm-but-due and fetches them.
      final panel = _OneParsePanel();
      final cache = IptvCatalogDiskCache();
      await cache.write(_connId, IptvCatalogDiskCache.liveDataset, jsonEncode(_liveRows.map((r) => r.toJson()).toList()));
      await cache.write(_connId, IptvCatalogDiskCache.vodDataset, jsonEncode(_movieRows().map((r) => r.toJson()).toList()));
      await cache.write(_connId, IptvCatalogDiskCache.seriesDataset, jsonEncode(_seriesRows().map((r) => r.toJson()).toList()));
      await cache.write(
        _connId,
        IptvCatalogDiskCache.liveCategoriesDataset,
        jsonEncode(_liveCategories.map((c) => c.toJson()).toList()),
      );
      await cache.write(
        _connId,
        IptvCatalogDiskCache.vodCategoriesDataset,
        jsonEncode(_movieCategories.map((c) => c.toJson()).toList()),
      );
      await cache.write(
        _connId,
        IptvCatalogDiskCache.seriesCategoriesDataset,
        jsonEncode(_seriesCategories.map((c) => c.toJson()).toList()),
      );
      final old = DateTime.now().subtract(const Duration(days: 8));
      await for (final entity in tempDir.list(recursive: true)) {
        if (entity is File) await entity.setLastModified(old);
      }
      final (:client, :api) = _clientWith(panel, hiddenCategoryIds: const ['mov2']);
      client.warmUpLiveCatalog();
      client.warmUpVodCatalog();
      client.warmUpSeriesCatalog();
      final seeded = await () async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline)) {
          final counts = client.searchIndexState.rowCounts;
          if ((counts['live'] ?? 0) > 0 && (counts['movie'] ?? 0) > 0 && (counts['series'] ?? 0) > 0) return true;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        return false;
      }();
      expect(seeded, isTrue);

      final result = await client.syncSearchIndexForBackground();

      // A fetched type lands in `rows`, not `skipped`.
      expect(result.rows.keys, containsAll(['live', 'movie', 'series']));
      expect(result.skipped, isEmpty, reason: 'skipped=$result.skipped');
      expect(api.lastVodStreamsBody, isNull);
      expect(api.lastLiveStreamsBody, isNull);
      expect(api.lastSeriesBody, isNull);
      expect(client.searchIndexState.rowCounts['movie'], 6);
      await _expectNoSyncTempLeftovers(tempBefore);
    });

    test('S6: Trex-scale VOD sync — 199,762 rows, 3 of 4 categories hidden', () async {
      final tempBefore = await _syncTempEntries();
      // 199,762 VOD rows across 4 categories; only mov1 visible, so the
      // isolate returns ~49,940 visible rows while the body + the full
      // 200k-row parse never touch the main isolate.
      //
      // NO RSS BOUND (measured, not assumed): the peak RSS sampled
      // during the sync is 256-295MB on the fix and 255-270MB on the
      // 1.2.9 base — indistinguishable. The process peak is dominated
      // by the isolate's single parse heap in both cases (plus the
      // test's own in-process fixture: the 199,762 typed rows + the
      // 40MB body String the fake panel holds), and the 50ms sampler
      // misses the short-lived main-side copies the fix removes. A
      // bound here would pass on the base (useless) or flake. The
      // deterministic proof is the null-body assertion above + the
      // identical lands; the deltas print for the record only.
      final categories = [
        const XtreamCategory(id: 'mov1', name: '|EN| Movies'),
        const XtreamCategory(id: 'mov2', name: 'AR - Movies'),
        const XtreamCategory(id: 'mov3', name: '[NF] Movies'),
        const XtreamCategory(id: 'mov4', name: 'UK: Movies'),
      ];
      final rows = List<XtreamVodStream>.generate(
        199762,
        (i) => XtreamVodStream(
          streamId: i,
          name: 'Movie $i',
          containerExtension: 'mp4',
          categoryId: 'mov${(i % 4) + 1}',
        ),
      );
      final panel = _OneParsePanel()
        ..trexVodBody = jsonEncode(rows.map((r) => r.toJson()).toList())
        ..trexVodCategories = categories;
      final (:client, :api) = _clientWith(
        panel,
        hiddenCategoryIds: const ['mov2', 'mov3', 'mov4'],
      );

      final rssBefore = ProcessInfo.currentRss;
      // Peak RSS sampled during the sync (the transient that kills
      // low-end devices), not just the end delta.
      var peakRss = rssBefore;
      final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final now = ProcessInfo.currentRss;
        if (now > peakRss) peakRss = now;
      });
      final result = await client.syncSearchIndex(force: true);
      sampler.cancel();
      final rssDeltaMb = (ProcessInfo.currentRss - rssBefore) / (1024 * 1024);
      final peakDeltaMb = (peakRss - rssBefore) / (1024 * 1024);
      // ignore: avoid_print
      print('ONEPARSE-S6 rssDelta=${rssDeltaMb.toStringAsFixed(1)}MB '
          'peakDelta=${peakDeltaMb.toStringAsFixed(1)}MB '
          'rows=${result.rows} skipped=${result.skipped}');

      expect(result.skipped, isEmpty, reason: 'skipped=$result.skipped');
      expect(api.lastVodStreamsBody, isNull);
      // ~1/4 of 199,762 rows are in mov1 (i % 4 == 0).
      expect(client.searchIndexState.rowCounts['movie'], 49941);
      await _expectNoSyncTempLeftovers(tempBefore);
    });

    // TEMP-DISABLED for the base peak measurement (method does not exist on base).
    test('S7: getVodStreamsToFile streams the body to a file without holding it', () async {
      final panel = _OneParsePanel();
      final (:api, client: _) = _clientWith(panel);
      final dir = Directory.systemTemp.createTempSync('oneparse_s7_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/vod.json';

      final returned = await api.getVodStreamsToFile(filePath: path);

      expect(returned, path);
      // The getter never stores the body on the api.
      expect(api.lastVodStreamsBody, isNull);
      expect(
        File(path).readAsStringSync(),
        jsonEncode(_movieRows().map((r) => r.toJson()).toList()),
      );
    });
  });
}
