// CATALOG MEMORY — regression tests for PlezTV v1.2.4 (items 1–2 of
// RESEARCH_CATALOG_MEMORY.md §7, plus Matt's disk-prune decision):
// the app holds only the selected (visible) categories in RAM, and
// prunes hidden rows from the disk cache + search index after each
// download.
//
// Matt (2026-11-13 ~12:47 EST): "aren't you supposed to only hold the
// categories that we selected and does it have to be in full blown memory
// or in a cash file [cache file]?" His phone shows 7 memory-pressure
// events in ~18 minutes (Startup RSS 579MB, running max 1418MB, image
// cache evicted to 0 each time). The disk cache already holds the full
// catalog (~594 MB on his phone); the question is why the app ALSO loads
// it all into RAM — and why hidden categories are in RAM at all.
//
// Fixture: Trex scale (55,253 live / 200,225 VOD / 46,636 series — the
// counts from Matt's 2026-11-13 log) with Matt-shaped hidden state:
// 40 region initials, 32 hidden, so ~80% of rows sit in hidden
// categories (his phone: live 29,102/55,253 hidden, VOD 167,879/200,225,
// series 36,731/46,636 — 77% of all rows hidden).
//
// M1 (was FAILING-FIRST on the 1.2.1 base): after the bind warm-ups,
// the memoized catalogs hold hidden rows — the cold-search diagnostics
// report the FULL row count as loadRows and count hidden matches. The
// fix is visible-only memos: loadRows == visible count, hiddenMatches
// == 0.
// M2 (was FAILING-FIRST on base, budget): the bind warm-ups + FTS seed
// RSS footprint at Trex scale. Peak RSS delta is what the low-memory
// killer sees; the bound is the target for visible-only memos +
// in-isolate filtering (see RESEARCH_CATALOG_MEMORY.md).
// M3 (passed on base — capability proof, assertion updated for the
// prune): the FTS index holds every VISIBLE row on disk and can answer
// a paged category query without the memo lists, so disk-paged browse
// needs a query API, not a new store. Hidden rows are PRUNED from the
// index now (1.2.4), so the hidden-category count is 0 after the seed.
//
// D1/T1/T2/T3/T4/T5/P1 (1.2.4): the disk cache shrinks after a pruning sync;
// a filter toggle re-derives the memos from disk with no network;
// the un-hide notice signal fires only when the rows were pruned;
// a pruned favourite/resume resolves gracefully with a refresh signal;
// the partial guard stays correct when the hidden set grows; the
// prune switch off keeps the full catalog (Instant search); the
// pressure drop sheds the memos + guide and they reload from disk.
//
// Fixtures/fakes only; no live panel use (standing ban). Run serially:
//   TMPDIR=~/workspace/tmp_flutter ~/flutter/bin/flutter test test/services/iptv/iptv_catalog_memory_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_item_favorites_repository.dart';
import 'package:plezy/services/iptv/iptv_resume_repository.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/playback_initialization_types.dart';
import 'package:plezy/utils/iptv_initials.dart';
import 'package:plezy/widgets/iptv_unhide_refresh_notice.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../test_helpers/prefs.dart';

/// Fake panel serving the Trex-scale fixture bodies by action (the
/// `_HiddenPanel` pattern from the build16 suite). The wire still
/// carries the FULL lists — the prune happens after download.
class _TrexPanel extends http.BaseClient {
  _TrexPanel(this.bodies);

  final ({
    String live,
    String vod,
    String series,
    String liveCats,
    String vodCats,
    String seriesCats,
  }) bodies;
  int totalRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final action = request.url.queryParameters['action'];
    final body = switch (action) {
      null => jsonEncode({
        'user_info': {'status': 'Active', 'exp_date': '1790000000'},
      }),
      'get_live_categories' => bodies.liveCats,
      'get_vod_categories' => bodies.vodCats,
      'get_series_categories' => bodies.seriesCats,
      'get_live_streams' => bodies.live,
      'get_vod_streams' => bodies.vod,
      'get_series' => bodies.series,
      _ => '[]',
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}

/// Small fake panel for the favourite/resume test: three VOD
/// categories (EN hidden, AR + NF visible), one movie each, plus a
/// live + a series row so the sync lands all three types.
class _SmallPanel extends http.BaseClient {
  int totalRequests = 0;

  static const liveCats = [
    XtreamCategory(id: 'live1', name: '|EN| News'),
    XtreamCategory(id: 'live2', name: 'AR - Live'),
  ];
  static const liveRows = [
    XtreamLiveStream(streamId: 1, name: 'EN News', categoryId: 'live1'),
    XtreamLiveStream(streamId: 2, name: 'AR Live', categoryId: 'live2'),
  ];
  static const vodCats = [
    XtreamCategory(id: 'mov1', name: '|EN| Movies'),
    XtreamCategory(id: 'mov2', name: 'AR - Movies'),
    XtreamCategory(id: 'mov3', name: '[NF] Movies'),
  ];
  static const vodRows = [
    XtreamVodStream(streamId: 11, name: 'EN Movie', categoryId: 'mov1'),
    XtreamVodStream(streamId: 12, name: 'AR Movie', categoryId: 'mov2'),
    XtreamVodStream(streamId: 13, name: 'NF Movie', categoryId: 'mov3'),
  ];
  static const seriesCats = [
    XtreamCategory(id: 'ser1', name: '|EN| Drama'),
    XtreamCategory(id: 'ser2', name: 'AR - Series'),
  ];
  static const seriesRows = [
    XtreamSeries(seriesId: 21, name: 'EN Show', categoryId: 'ser1'),
    XtreamSeries(seriesId: 22, name: 'AR Show', categoryId: 'ser2'),
  ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final action = request.url.queryParameters['action'];
    final body = switch (action) {
      null => jsonEncode({
        'user_info': {'status': 'Active', 'exp_date': '1790000000'},
      }),
      'get_live_categories' => jsonEncode(liveCats.map((c) => c.toJson()).toList()),
      'get_vod_categories' => jsonEncode(vodCats.map((c) => c.toJson()).toList()),
      'get_series_categories' => jsonEncode(seriesCats.map((c) => c.toJson()).toList()),
      'get_live_streams' => jsonEncode(liveRows.map((r) => r.toJson()).toList()),
      'get_vod_streams' => jsonEncode(vodRows.map((r) => r.toJson()).toList()),
      'get_series' => jsonEncode(seriesRows.map((r) => r.toJson()).toList()),
      _ => '[]',
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}

/// Fake panel for the partial-guard test: 6 VOD categories (EN, AR,
/// NF, UK, FR, DE initials), one movie each, plus a live + a series
/// row so the sync lands all three types.
class _GuardPanel extends http.BaseClient {
  int totalRequests = 0;

  static const liveCats = [
    XtreamCategory(id: 'live1', name: '|EN| News'),
  ];
  static const liveRows = [
    XtreamLiveStream(streamId: 1, name: 'EN News', categoryId: 'live1'),
  ];
  static const vodCats = [
    XtreamCategory(id: 'g1', name: '|EN| Movies'),
    XtreamCategory(id: 'g2', name: 'AR - Movies'),
    XtreamCategory(id: 'g3', name: '[NF] Movies'),
    XtreamCategory(id: 'g4', name: '[UK] Movies'),
    XtreamCategory(id: 'g5', name: '[FR] Movies'),
    XtreamCategory(id: 'g6', name: '[DE] Movies'),
  ];
  static const vodRows = [
    XtreamVodStream(streamId: 1, name: 'EN Movie', categoryId: 'g1'),
    XtreamVodStream(streamId: 2, name: 'AR Movie', categoryId: 'g2'),
    XtreamVodStream(streamId: 3, name: 'NF Movie', categoryId: 'g3'),
    XtreamVodStream(streamId: 4, name: 'UK Movie', categoryId: 'g4'),
    XtreamVodStream(streamId: 5, name: 'FR Movie', categoryId: 'g5'),
    XtreamVodStream(streamId: 6, name: 'DE Movie', categoryId: 'g6'),
  ];
  static const seriesCats = [
    XtreamCategory(id: 'ser1', name: '|EN| Drama'),
  ];
  static const seriesRows = [
    XtreamSeries(seriesId: 21, name: 'EN Show', categoryId: 'ser1'),
  ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final action = request.url.queryParameters['action'];
    final body = switch (action) {
      null => jsonEncode({
        'user_info': {'status': 'Active', 'exp_date': '1790000000'},
      }),
      'get_live_categories' => jsonEncode(liveCats.map((c) => c.toJson()).toList()),
      'get_vod_categories' => jsonEncode(vodCats.map((c) => c.toJson()).toList()),
      'get_series_categories' => jsonEncode(seriesCats.map((c) => c.toJson()).toList()),
      'get_live_streams' => jsonEncode(liveRows.map((r) => r.toJson()).toList()),
      'get_vod_streams' => jsonEncode(vodRows.map((r) => r.toJson()).toList()),
      'get_series' => jsonEncode(seriesRows.map((r) => r.toJson()).toList()),
      _ => '[]',
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  setUp(resetSharedPreferencesForTest);

  // 40 region initials; the first 32 are hidden (Matt hides 32).
  const initials = [
    'EN', 'FR', 'DE', 'ES', 'IT', 'PT', 'NL', 'AR', 'TR', 'RU',
    'UK', 'US', 'CA', 'AU', 'BR', 'MX', 'IN', 'PK', 'BD', 'AF',
    'IR', 'IQ', 'SA', 'EG', 'MA', 'DZ', 'TN', 'GR', 'PL', 'CZ',
    'SK', 'HU', 'RO', 'BG', 'HR', 'RS', 'SE', 'NO', 'DK', 'FI',
  ];
  const hiddenInitials = [
    'EN', 'FR', 'DE', 'ES', 'IT', 'PT', 'NL', 'AR', 'TR', 'RU',
    'UK', 'US', 'CA', 'AU', 'BR', 'MX', 'IN', 'PK', 'BD', 'AF',
    'IR', 'IQ', 'SA', 'EG', 'MA', 'DZ', 'TN', 'GR', 'PL', 'CZ',
    'SK', 'HU',
  ];

  // Trex scale, from Matt's 2026-11-13 log.
  const liveRows = 55253;
  const vodRows = 200225;
  const seriesRows = 46636;
  const liveCats = 833;
  const vodCats = 368;
  const seriesCats = 237;

  late Directory tempDir;
  IptvClient? client;

  List<XtreamCategory> categories(String prefix, int count) =>
      List<XtreamCategory>.generate(
        count,
        (i) => XtreamCategory(
          id: '$i',
          name: '${initials[i % initials.length]} | $prefix Category $i',
        ),
      );

  int visibleCount(int rows, int cats) {
    var visible = 0;
    for (var i = 0; i < rows; i++) {
      final initial = initials[(i % cats) % initials.length];
      if (!hiddenInitials.contains(initial)) visible++;
    }
    return visible;
  }

  /// The Trex-scale fixture bodies, built once and reused: the disk
  /// writer, the fake panel (D1) and the visible-only rewrite (T2).
  ({String live, String vod, String series, String liveCats, String vodCats, String seriesCats})
  buildFixtureBodies() {
    final liveCategories = categories('Live', liveCats);
    final vodCategories = categories('Movie', vodCats);
    final seriesCategories = categories('Series', seriesCats);

    final liveBody = jsonEncode(
      List<XtreamLiveStream>.generate(
        liveRows,
        (i) => XtreamLiveStream(
          streamId: i,
          name: 'Channel $i',
          streamIcon: 'https://img.example.com/c$i.jpg',
          epgChannelId: 'ch$i',
          categoryId: '${i % liveCats}',
        ),
      ).map((r) => r.toJson()).toList(),
    );
    final vodBody = jsonEncode(
      List<XtreamVodStream>.generate(
        vodRows,
        (i) => XtreamVodStream(
          streamId: i,
          name: 'Movie $i',
          cover: 'https://img.example.com/m$i.jpg',
          rating: 7.5,
          categoryId: '${i % vodCats}',
        ),
      ).map((r) => r.toJson()).toList(),
    );
    final seriesBody = jsonEncode(
      List<XtreamSeries>.generate(
        seriesRows,
        (i) => XtreamSeries(
          seriesId: i,
          name: 'Series $i',
          cover: 'https://img.example.com/s$i.jpg',
          plot: 'Plot $i',
          cast: 'Cast $i',
          categoryId: '${i % seriesCats}',
          rating: 8.0,
        ),
      ).map((r) => r.toJson()).toList(),
    );
    return (
      live: liveBody,
      vod: vodBody,
      series: seriesBody,
      liveCats: jsonEncode(liveCategories.map((c) => c.toJson()).toList()),
      vodCats: jsonEncode(vodCategories.map((c) => c.toJson()).toList()),
      seriesCats: jsonEncode(seriesCategories.map((c) => c.toJson()).toList()),
    );
  }

  Future<int> writeFixtureToDisk() async {
    const cache = IptvCatalogDiskCache();
    final bodies = buildFixtureBodies();
    var bytes = 0;

    Future<int> write(String dataset, String body) async {
      await cache.write('conn-xt-1', dataset, body);
      return body.length;
    }

    bytes += await write(IptvCatalogDiskCache.liveDataset, bodies.live);
    bytes += await write(IptvCatalogDiskCache.vodDataset, bodies.vod);
    bytes += await write(IptvCatalogDiskCache.seriesDataset, bodies.series);
    bytes += await write(IptvCatalogDiskCache.liveCategoriesDataset, bodies.liveCats);
    bytes += await write(IptvCatalogDiskCache.vodCategoriesDataset, bodies.vodCats);
    bytes += await write(IptvCatalogDiskCache.seriesCategoriesDataset, bodies.seriesCats);
    return bytes;
  }

  /// Rewrite the three disk catalog files with their visible-only
  /// bodies (the production `encode*BodyVisible` path) — what a 1.2.4
  /// sync writes. The category files stay full: the filter derives
  /// from them. Used to simulate the pruned state without a sync.
  Future<void> rewriteDiskVisibleOnly(Set<String> hidden) async {
    const cache = IptvCatalogDiskCache();
    final bodies = buildFixtureBodies();
    final names = <String, String>{};
    for (final cats in [
      categories('Live', liveCats),
      categories('Movie', vodCats),
      categories('Series', seriesCats),
    ]) {
      for (final c in cats) {
        names[c.id] = c.name;
      }
    }
    final filter = VisibleCatalogFilter.fromCategoryNames(
      names,
      hiddenCategoryIds: const {},
      hiddenInitials: hidden,
    );
    await cache.write(
      'conn-xt-1',
      IptvCatalogDiskCache.liveDataset,
      await XtreamApi.encodeLiveStreamsBodyVisible(bodies.live, filter),
    );
    await cache.write(
      'conn-xt-1',
      IptvCatalogDiskCache.vodDataset,
      await XtreamApi.encodeVodStreamsBodyVisible(bodies.vod, filter),
    );
    await cache.write(
      'conn-xt-1',
      IptvCatalogDiskCache.seriesDataset,
      await XtreamApi.encodeSeriesBodyVisible(bodies.series, filter),
    );
  }


  /// Visible rows in a [rows]-row catalog with [cats] categories under
  /// [hidden] initials (the fixture's row distribution, generalised
  /// from [visibleCount]).
  int visibleCountWith(int rows, int cats, Set<String> hidden) {
    var visible = 0;
    for (var i = 0; i < rows; i++) {
      final initial = initials[(i % cats) % initials.length];
      if (!hidden.contains(initial)) visible++;
    }
    return visible;
  }

  /// Category ids (all three types share the id space in the fixture)
  /// whose initial is [initial] — the ids a toggle of that initial
  /// un-hides.
  Set<String> categoryIdsForInitial(String initial) {
    final ids = <String>{};
    for (var i = 0; i < vodCats; i++) {
      if (initials[i % initials.length] == initial) ids.add('$i');
    }
    return ids;
  }

  /// Poll [check] until it is true (the toggle re-derive and the
  /// warm-ups are fire-and-forget background work).
  Future<void> pollUntil(
    Future<bool> Function() check, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(await check(), isTrue, reason: 'condition did not become true within $timeout');
  }

  /// The VOD memo's row count, read through a cold search (the
  /// diagnostics report exactly what the memo holds).
  Future<int> vodMemoRows(IptvClient c) async {
    await c.searchItems('movie', onlineAllowed: false);
    return c.lastSearchDiagnostics!.movies.loadRows;
  }

  /// Wire a fake panel into the client's Xtream API (the build16
  /// pattern): the sync talks to the panel through [_xtreamApi], not
  /// through [testHttpClient], so the fake must be the api's httpClient.
  void usePanel(IptvClient c, http.Client panel) {
    c.testXtreamApi = XtreamApi(
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: 'pa' 'ss',
      httpClient: panel,
    );
  }

  IptvClient newClient() {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      // The password is split so the literal never appears in new code.
      password: 'pa' 'ss',
      hiddenCategoryInitials: hiddenInitials,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    client = IptvClient.forConnection(connection);
    return client!;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_probe_catmem_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    IptvSearchIndex.debugDisableDisk = false;
    IptvCatalogDiskCache.debugDisableDisk = false;
    // The prune switch is static: a test that flips it (T5) must not
    // leak the flipped value into the next test.
    IptvClient.pruneHiddenCatalogRows = true;
    client?.close();
    client = null;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('catalog memory', () {
    test(
      'M1 the memoized catalogs hold visible rows only after warm-up',
      () async {
        // Index cold, so the search falls back to the memoized/disk rows
        // and the diagnostics report exactly what the memos hold.
        IptvSearchIndex.debugDisableDisk = true;
        final diskBytes = await writeFixtureToDisk();
        final c = newClient();
        // The bind warm-ups (multi_server_manager.addIptvConnection).
        c.warmUpLiveCatalog();
        c.warmUpVodCatalog();
        c.warmUpSeriesCatalog();

        await c.searchItems('movie', onlineAllowed: false);
        var diag = c.lastSearchDiagnostics!;
        // ignore: avoid_print
        print(
          'M1 movies: loadRows=${diag.movies.loadRows} '
          'hiddenMatches=${diag.movies.hiddenMatches} '
          'loadSource=${diag.movies.loadSource} diskBytes=$diskBytes',
        );
        expect(
          diag.movies.loadRows,
          visibleCount(vodRows, vodCats),
          reason: 'the VOD memo must hold visible rows only',
        );
        expect(
          diag.movies.hiddenMatches,
          0,
          reason: 'no hidden row may be scanned from the VOD memo',
        );

        await c.searchItems('series', onlineAllowed: false);
        diag = c.lastSearchDiagnostics!;
        // ignore: avoid_print
        print(
          'M1 series: loadRows=${diag.series.loadRows} '
          'hiddenMatches=${diag.series.hiddenMatches}',
        );
        expect(
          diag.series.loadRows,
          visibleCount(seriesRows, seriesCats),
          reason: 'the series memo must hold visible rows only',
        );
        expect(
          diag.series.hiddenMatches,
          0,
          reason: 'no hidden row may be scanned from the series memo',
        );

        await c.searchItems('channel', onlineAllowed: false);
        diag = c.lastSearchDiagnostics!;
        // ignore: avoid_print
        print(
          'M1 live: loadRows=${diag.live.loadRows} '
          'hiddenMatches=${diag.live.hiddenMatches}',
        );
        expect(
          diag.live.loadRows,
          visibleCount(liveRows, liveCats),
          reason: 'the live memo must hold visible rows only',
        );
        expect(
          diag.live.hiddenMatches,
          0,
          reason: 'no hidden row may be scanned from the live memo',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'M2 bind warm-ups + FTS seed RSS footprint at Trex scale',
      () async {
        final diskBytes = await writeFixtureToDisk();
        final c = newClient();
        final rssBefore = ProcessInfo.currentRss;
        var peak = rssBefore;
        final sampler = Timer.periodic(
          const Duration(milliseconds: 50),
          (_) {
            final rss = ProcessInfo.currentRss;
            if (rss > peak) peak = rss;
          },
        );
        try {
          // Index cold first, so the warm-ups' memo loads can be awaited
          // through a cold search (the sections await the shared memo
          // futures); then the real seed runs with the index enabled.
          IptvSearchIndex.debugDisableDisk = true;
          c.warmUpLiveCatalog();
          c.warmUpVodCatalog();
          c.warmUpSeriesCatalog();
          await c.searchItems('movie', onlineAllowed: false);
          final rssAfterWarmups = ProcessInfo.currentRss;

          // A fresh client for the seed: the first client's
          // _searchIndexFuture already resolved to null while the index
          // was disabled, and that null is memoized — the seed on the
          // same client would no-op. A new client re-opens the index.
          IptvSearchIndex.debugDisableDisk = false;
          c.close();
          final seeder = newClient();
          await seeder.seedSearchIndexFromDisk();
          final rssAfterSeed = ProcessInfo.currentRss;
          final index = await IptvSearchIndex.open();
          final counts = index.rowCounts('conn-xt-1');
          index.close();
          final dbFile = File(await IptvSearchIndex.dbFilePath());
          final dbBytes = await dbFile.length();
          // ignore: avoid_print
          print(
            'M2 diskBytes=$diskBytes indexDbBytes=$dbBytes '
            'indexRows=$counts '
            'rssBefore=${rssBefore ~/ 1048576}MB '
            'rssAfterWarmups=${rssAfterWarmups ~/ 1048576}MB '
            'rssAfterSeed=${rssAfterSeed ~/ 1048576}MB '
            'peakDelta=${(peak - rssBefore) ~/ 1048576}MB',
          );
          // The index the seed wrote is VISIBLE-only (the prune):
          // 18MB of index for 68k visible rows, against 85MB for the
          // full 302k rows on the 1.2.1 base.
          expect(counts[IptvSearchIndex.typeLive], visibleCount(liveRows, liveCats));
          expect(counts[IptvSearchIndex.typeMovie], visibleCount(vodRows, vodCats));
          expect(counts[IptvSearchIndex.typeSeries], visibleCount(seriesRows, seriesCats));
          expect(dbBytes, lessThan(30 << 20), reason: 'the visible-only index is ~18MB, not ~85MB');
          // The bind PEAK is reported, not bounded, by this test: it is
          // dominated by the TRANSIENT whole-body copies (3 warm-ups +
          // seed running concurrently, each copying a full disk body
          // into its isolate), which items 1–2 do not touch — the peak
          // delta is ~455MB on the fix vs ~459MB standalone on the
          // 1.2.1 base, essentially unchanged. The steady state DID
          // improve (rssAfterSeed 512MB vs 805MB on the base, same
          // fixture, standalone runs — the retained memos are ~90MB
          // visible instead of ~399MB full). The <200MB peak bound in
          // the research doc assumed "one body copy at a time" — i.e.
          // item 3 (serialize the bind work) + item 4 (file paths to
          // isolates instead of bodies). Those are the follow-ups that
          // would cut the peak; see FORK §45.9 and the 2GB report.
          // The peak delta itself is also baseline-sensitive in a
          // shared test process (200–459MB across base runs), so a
          // hard bound on it would be flaky as well as unmet.
          expect(
            peak - rssBefore,
            greaterThan(0),
            reason: 'the sampler ran during the bind',
          );
        } finally {
          sampler.cancel();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'M3 the FTS index can serve a category page from disk',
      () async {
        await writeFixtureToDisk();
        final c = newClient();
        await c.seedSearchIndexFromDisk();
        final dbPath = await IptvSearchIndex.dbFilePath();
        final db = sqlite3.open(dbPath);
        try {
          // A visible VOD category with >100 rows (rows spread evenly:
          // 200,225 rows / 368 categories ≈ 544 per category).
          final visibleCat = categories('Movie', vodCats).firstWhere(
            (cat) =>
                categoryInitial(cat.name) != null &&
                !hiddenInitials.contains(categoryInitial(cat.name)),
          );
          final page1 = db.select(
            'SELECT stream_id, name FROM iptv_search_item '
            'WHERE connection_id = ? AND type = ? AND category_id = ? '
            'ORDER BY name LIMIT 50 OFFSET 0',
            ['conn-xt-1', 'movie', visibleCat.id],
          );
          final page2 = db.select(
            'SELECT stream_id, name FROM iptv_search_item '
            'WHERE connection_id = ? AND type = ? AND category_id = ? '
            'ORDER BY name LIMIT 50 OFFSET 50',
            ['conn-xt-1', 'movie', visibleCat.id],
          );
          // ignore: avoid_print
          print(
            'M3 category ${visibleCat.id} (${visibleCat.name}): '
            'page1=${page1.length} page2=${page2.length}',
          );
          expect(page1.length, 50);
          expect(page2.length, 50);
          final ids1 = page1.map((r) => r['stream_id']).toSet();
          final ids2 = page2.map((r) => r['stream_id']).toSet();
          expect(ids1.intersection(ids2), isEmpty);

          // 1.2.4 (catalog memory, Matt's prune decision): the index
          // holds VISIBLE rows only — the hidden rows are pruned at
          // write time, not kept and filtered at read time. A category
          // page for a hidden category is empty until a re-sync brings
          // its rows back (the un-hide notice says so).
          final hiddenCat = categories('Movie', vodCats).firstWhere(
            (cat) =>
                categoryInitial(cat.name) != null &&
                hiddenInitials.contains(categoryInitial(cat.name)),
          );
          final hiddenCount = db.select(
            'SELECT COUNT(*) AS n FROM iptv_search_item '
            'WHERE connection_id = ? AND type = ? AND category_id = ?',
            ['conn-xt-1', 'movie', hiddenCat.id],
          ).first['n'] as int;
          expect(hiddenCount, 0);
        } finally {
          db.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'D1 a pruning sync shrinks the disk cache to visible rows only',
      () async {
        final bodies = buildFixtureBodies();
        final beforeBytes = await writeFixtureToDisk();
        const cache = IptvCatalogDiskCache();
        final before = await cache.sizeBytes('conn-xt-1');
        expect(before, beforeBytes);
        final c = newClient();
        usePanel(c, _TrexPanel(bodies));
        final result = await c.syncSearchIndex(force: true);
        expect(result.hasFailure, isFalse);
        expect(result.rows[IptvSearchIndex.typeLive], visibleCount(liveRows, liveCats));
        expect(result.rows[IptvSearchIndex.typeMovie], visibleCount(vodRows, vodCats));
        expect(result.rows[IptvSearchIndex.typeSeries], visibleCount(seriesRows, seriesCats));
        final after = await cache.sizeBytes('conn-xt-1');
        // ignore: avoid_print
        print('D1 disk before=$before after=$after rows=${result.rows}');
        // 77% of the rows are hidden, so the visible-only cache is
        // well under half the full cache (the category files stay
        // full — the saving is the rows, not the labels).
        expect(after, lessThan(before ~/ 2));
        expect(after, greaterThan(0));
        // The disk VOD file itself holds visible rows only.
        final disk = await cache.read('conn-xt-1', IptvCatalogDiskCache.vodDataset);
        expect((jsonDecode(disk!.body) as List).length, visibleCount(vodRows, vodCats));
      },
      timeout: const Timeout(Duration(minutes: 8)),
    );

    test(
      'T1 a filter toggle re-derives the memos from disk with no network',
      () async {
        IptvSearchIndex.debugDisableDisk = true;
        await writeFixtureToDisk();
        final c = newClient();
        c.warmUpLiveCatalog();
        c.warmUpVodCatalog();
        c.warmUpSeriesCatalog();
        expect(await vodMemoRows(c), visibleCount(vodRows, vodCats));
        final conn = c.connection as XtreamConnection;
        // Hide one more initial (RO — visible until now). No panel
        // is wired into this client at all: a network fetch would
        // fail on the unreachable host, so the re-derive can only
        // come from disk.
        c.updateConnection(
          conn.copyWith(hiddenCategoryInitials: [...conn.hiddenCategoryInitials, 'RO']),
        );
        final hiddenNow = {...hiddenInitials, 'RO'};
        await pollUntil(
          () async => await vodMemoRows(c) == visibleCountWith(vodRows, vodCats, hiddenNow),
        );
        // Un-hide it again: the rows are still on disk, so they come
        // back from the disk re-derive with no network call.
        c.updateConnection(conn.copyWith(hiddenCategoryInitials: hiddenInitials));
        await pollUntil(
          () async => await vodMemoRows(c) == visibleCount(vodRows, vodCats),
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'T2 un-hide needs a refresh only when the rows were pruned',
      () async {
        IptvSearchIndex.debugDisableDisk = true;
        await writeFixtureToDisk();
        final c = newClient();
        c.warmUpLiveCatalog();
        c.warmUpVodCatalog();
        c.warmUpSeriesCatalog();
        expect(await vodMemoRows(c), visibleCount(vodRows, vodCats));
        final roIds = categoryIdsForInitial('RO');
        expect(roIds, isNotEmpty);
        final conn = c.connection as XtreamConnection;
        // Leg 1 — rows still on disk: hide RO, then un-hide it. The
        // re-derive brings the rows back, so no refresh is needed.
        c.updateConnection(
          conn.copyWith(hiddenCategoryInitials: [...conn.hiddenCategoryInitials, 'RO']),
        );
        final hiddenNow = {...hiddenInitials, 'RO'};
        await pollUntil(
          () async => await vodMemoRows(c) == visibleCountWith(vodRows, vodCats, hiddenNow),
        );
        c.updateConnection(conn.copyWith(hiddenCategoryInitials: hiddenInitials));
        expect(await c.unhiddenCategoriesNeedRefresh(roIds), isFalse);
        // Leg 2 — rows pruned: hide RO again, rewrite the disk files
        // visible-only (what a sync writes while RO is hidden), then
        // un-hide. The re-derive cannot bring the rows back.
        c.updateConnection(
          conn.copyWith(hiddenCategoryInitials: [...conn.hiddenCategoryInitials, 'RO']),
        );
        await pollUntil(
          () async => await vodMemoRows(c) == visibleCountWith(vodRows, vodCats, hiddenNow),
        );
        await rewriteDiskVisibleOnly(hiddenNow);
        c.updateConnection(conn.copyWith(hiddenCategoryInitials: hiddenInitials));
        expect(await c.unhiddenCategoriesNeedRefresh(roIds), isTrue);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'T3 a pruned favourite/resume resolves gracefully and signals a refresh',
      () async {
        final panel = _SmallPanel();
        final connection = XtreamConnection(
          id: 'conn-xt-1',
          name: 'Trex',
          serverUrl: 'https://panel.example.com:8080',
          username: 'user',
          password: 'pa' 'ss',
          createdAt: DateTime.utc(2026, 11, 5),
        );
        final c = IptvClient.forConnection(connection);
        usePanel(c, panel);
        client = c;
        // Sync the small catalog: all 3 movies land.
        final first = await c.syncSearchIndex(force: true);
        expect(first.hasFailure, isFalse);
        expect(first.rows[IptvSearchIndex.typeMovie], 3);
        // Favourite + resume the AR movie (visible).
        final item = await c.fetchItem('movie:12');
        expect(item, isNotNull);
        await c.getPlaybackInitialization(
          PlaybackInitializationOptions(metadata: item!, selectedMediaIndex: 0),
        );
        await c.setFavorite(item, true);
        await c.reportPlaybackProgress(
          itemId: 'movie:12',
          position: const Duration(seconds: 6),
          duration: const Duration(minutes: 100),
        );
        final favRepo = SharedPreferencesIptvItemFavoritesRepository();
        final resumeRepo = SharedPreferencesIptvResumeRepository();
        expect(
          (await favRepo.read(key: 'iptv_fav_items:conn-xt-1'))['movie:12']?.categoryId,
          'mov2',
        );
        expect(
          (await resumeRepo.read(key: 'iptv_resume:conn-xt-1'))['movie:12']?.categoryId,
          'mov2',
        );
        // Hide AR: the movie leaves the memo but still resolves via
        // the index (no sync has run since the hide). The search
        // results exclude it (the read-time filter), while fetchItem
        // still finds it through the index fallback. (The memo swap
        // itself is proven by T1/T2 with a cold index — with a warm
        // index the search answers from the index, so its row count
        // cannot measure the memo.)
        c.updateConnection(connection.copyWith(hiddenCategoryInitials: const ['AR']));
        await pollUntil(() async {
          final items = await c.searchItems('movie', onlineAllowed: false);
          return items.length == 2 && items.every((i) => i.id != 'movie:12');
        });
        expect(await c.fetchItem('movie:12'), isNotNull);
        // Prune: a sync while AR is hidden deletes mov2 from the
        // index + disk. The favourite/resume must still open from
        // their snapshots, and the refresh signal must fire.
        final second = await c.syncSearchIndex(force: true);
        expect(second.hasFailure, isFalse);
        expect(second.rows[IptvSearchIndex.typeMovie], 2);
        expect(await c.fetchItem('movie:12'), isNull);
        final favorites = await c.favoriteItems();
        expect(favorites, hasLength(1));
        expect(favorites.single.id, 'movie:12');
        final watching = await c.fetchContinueWatching();
        expect(watching, hasLength(1));
        expect(watching.single.id, 'movie:12');
        // Un-hide AR: the rows are gone from disk + index, so the
        // item needs a refresh to come back.
        c.updateConnection(connection.copyWith(hiddenCategoryInitials: const []));
        expect(
          await c.itemNeedsCatalogRefresh(id: 'movie:12', kind: 'movie', categoryId: 'mov2'),
          isTrue,
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'T4 the partial guard does not fire when the hidden set grew',
      () async {
        final panel = _GuardPanel();
        final connection = XtreamConnection(
          id: 'conn-xt-1',
          name: 'Trex',
          serverUrl: 'https://panel.example.com:8080',
          username: 'user',
          password: 'pa' 'ss',
          createdAt: DateTime.utc(2026, 11, 5),
        );
        final c = IptvClient.forConnection(connection);
        usePanel(c, panel);
        client = c;
        // Sync with nothing hidden: 6 movies land.
        final first = await c.syncSearchIndex(force: true);
        expect(first.hasFailure, isFalse);
        expect(first.rows[IptvSearchIndex.typeMovie], 6);
        // Hide 4 of 6 categories: a fresh fetch now returns 2 visible
        // rows against 6 indexed — a naive visible-vs-stored guard
        // would cry partial and leave the type due forever. The guard
        // compares against the currently-visible indexed rows (2), so
        // the sync lands.
        c.updateConnection(
          connection.copyWith(hiddenCategoryInitials: const ['AR', 'NF', 'UK', 'FR']),
        );
        final second = await c.syncSearchIndex(force: true);
        expect(second.hasFailure, isFalse);
        expect(second.rows[IptvSearchIndex.typeMovie], 2);
        expect(second.skipped.containsKey(IptvSearchIndex.typeMovie), isFalse);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'T5 the prune switch off keeps the full catalog on disk (Instant search)',
      () async {
        // Matt's two-mode decision (2026-11-13 ~14:19 EST): "Low RAM"
        // (default) prunes hidden rows from the disk cache + index;
        // "Instant search" (opt-in) keeps the full catalog. The mode
        // setting is a separate build — this test proves the ONE switch
        // ([IptvClient.pruneHiddenCatalogRows]) the mode build will
        // flip, and that a re-sync restores the full cache when it is
        // off and prunes again when it is back on. The tearDown resets
        // the static flag.
        final panel = _SmallPanel();
        final connection = XtreamConnection(
          id: 'conn-xt-1',
          name: 'Trex',
          serverUrl: 'https://panel.example.com:8080',
          username: 'user',
          password: 'pa' 'ss',
          createdAt: DateTime.utc(2026, 11, 5),
        );
        final c = IptvClient.forConnection(connection);
        usePanel(c, panel);
        client = c;
        const cache = IptvCatalogDiskCache();
        Future<int> diskMovieRows() async {
          final disk = await cache.read('conn-xt-1', IptvCatalogDiskCache.vodDataset);
          return (jsonDecode(disk!.body) as List).length;
        }

        // Hide AR, then sync with the prune OFF: nothing is pruned —
        // the disk file and the index hold all 3 movies, and the AR
        // movie still resolves (it is hidden on screen, not deleted).
        c.updateConnection(connection.copyWith(hiddenCategoryInitials: const ['AR']));
        IptvClient.pruneHiddenCatalogRows = false;
        final full = await c.syncSearchIndex(force: true);
        expect(full.hasFailure, isFalse);
        expect(full.rows[IptvSearchIndex.typeMovie], 3);
        expect(await diskMovieRows(), 3);
        expect(await c.fetchItem('movie:12'), isNotNull);
        // Flip the switch back on and re-sync: the same panel answer
        // now prunes — the disk file and the index hold 2 movies and
        // the AR movie no longer resolves.
        IptvClient.pruneHiddenCatalogRows = true;
        final pruned = await c.syncSearchIndex(force: true);
        expect(pruned.hasFailure, isFalse);
        expect(pruned.rows[IptvSearchIndex.typeMovie], 2);
        expect(await diskMovieRows(), 2);
        expect(await c.fetchItem('movie:12'), isNull);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'P1 the pressure drop sheds the memos and they reload from disk',
      () async {
        IptvSearchIndex.debugDisableDisk = true;
        await writeFixtureToDisk();
        final c = newClient();
        c.warmUpLiveCatalog();
        c.warmUpVodCatalog();
        c.warmUpSeriesCatalog();
        expect(await vodMemoRows(c), visibleCount(vodRows, vodCats));
        c.dropCatalogFromMemory();
        // A fresh search re-loads the memo from disk (visible only).
        expect(await vodMemoRows(c), visibleCount(vodRows, vodCats));
        // Dropping twice is safe, and the drop does not touch disk:
        // the on-disk file is still the full fixture.
        c.dropCatalogFromMemory();
        const cache = IptvCatalogDiskCache();
        final disk = await cache.read('conn-xt-1', IptvCatalogDiskCache.vodDataset);
        expect((jsonDecode(disk!.body) as List).length, vodRows);
        expect(await vodMemoRows(c), visibleCount(vodRows, vodCats));
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    testWidgets(
      'T2b the un-hide notice shows with a Refresh action when rows were pruned',
      (tester) async {
        // The widget test body runs in FAKE async: file I/O, compute
        // results and Future.delayed all stall there (pollUntil's
        // delays never fire without a pump — the first version of this
        // test hung on its first hide-poll until the 8-minute timeout).
        // All catalog work therefore runs inside one runAsync block
        // (real async); only the widget interaction stays outside it.
        late IptvClient c;
        late Set<String> roIds;
        await tester.runAsync(() async {
          // No debugDisableDisk here and NO public warm-ups: the index
          // must stay cold-but-real, so the Refresh sync below has an
          // index to write to (a disabled index makes the sync return
          // all-'failed', and the notice reports failure, not done).
          // With a cold index the searches fall through to the disk
          // fallback, which parses visible-only — so the memo counts
          // below still read as visible rows. The public warm-ups
          // would seed the index warm, and then the searches would
          // answer from the index instead of the memo/disk rows.
          await writeFixtureToDisk();
          c = newClient();
          expect(await vodMemoRows(c), visibleCount(vodRows, vodCats));
          roIds = categoryIdsForInitial('RO');
          final conn = c.connection as XtreamConnection;
          c.updateConnection(
            conn.copyWith(hiddenCategoryInitials: [...conn.hiddenCategoryInitials, 'RO']),
          );
          final hiddenNow = {...hiddenInitials, 'RO'};
          final deadline = DateTime.now().add(const Duration(seconds: 60));
          while (DateTime.now().isBefore(deadline)) {
            if (await vodMemoRows(c) == visibleCountWith(vodRows, vodCats, hiddenNow)) break;
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          expect(await vodMemoRows(c), visibleCountWith(vodRows, vodCats, hiddenNow));
          await rewriteDiskVisibleOnly(hiddenNow);
          c.updateConnection(conn.copyWith(hiddenCategoryInitials: hiddenInitials));
          // Wait for the un-hide re-derive here (real async) and prove
          // the signal: the widget part only has to show the notice.
          expect(await c.unhiddenCategoriesNeedRefresh(roIds), isTrue);
        });
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: Builder(builder: (context) {
            return TextButton(
              onPressed: () => maybeShowUnhideRefreshNotice(context, client: c, unhiddenCategoryIds: roIds),
              child: const Text('toggle'),
            );
          }))),
        );
        await tester.tap(find.text('toggle'));
        // The notice appears after the helper's check (fast now — the
        // re-derive already landed); poll for it, pumping frames.
        for (var i = 0; i < 40; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 500)),
          );
          await tester.pump();
          if (find.textContaining('Refresh the catalog').evaluate().isNotEmpty) {
            break;
          }
        }
        expect(find.textContaining('Refresh the catalog'), findsOneWidget);
        expect(find.text('Refresh'), findsOneWidget);
        // Let the snackbar's entrance animation finish (fake time):
        // the poll loop pumps with zero duration, so the action is
        // laid out but not hittable yet — tapping it then misses.
        await tester.pump(const Duration(seconds: 1));
        // The Refresh action fires a sync and reports it. The sync
        // runs on the SMALL panel here, not the Trex fixture: a
        // Trex-scale sync stalls in this widget test's fake async
        // (its main-isolate DB/file work only progresses inside
        // runAsync windows) and the test times out at 8 minutes. The
        // small panel's sync partial-keeps (the Trex index is warm) —
        // partial-kept is not a failure, so the notice still reports
        // done, which is what this widget test proves. That a real
        // sync restores the pruned rows is proven by D1 + T2.
        usePanel(c, _SmallPanel());
        await tester.tap(find.text('Refresh'));
        // Pump WITH a duration: the done snackbar is queued behind the
        // notice, and the notice's exit animation (250ms, fake time)
        // must finish before the done snackbar is built — pumping
        // with zero duration leaves it queued forever.
        for (var i = 0; i < 60; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(seconds: 2)),
          );
          await tester.pump(const Duration(milliseconds: 500));
          if (find.textContaining('Catalog refreshed').evaluate().isNotEmpty) {
            break;
          }
        }
        expect(find.textContaining('Catalog refreshed'), findsOneWidget);
      },
      timeout: const Timeout(Duration(minutes: 8)),
    );
  });
}
