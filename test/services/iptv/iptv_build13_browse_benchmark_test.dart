// BROWSE BENCHMARK — build #13 (v2.25.9): paged browse fluidity.
//
// The Movies/Series browse is paged (50 rows a page), but
// fetchLibraryPagedContent built ALL 199k MediaItems on every page turn
// and then sliced one page out of them — every scroll-page turn froze
// the UI while 199k freezed objects were constructed. Same for the hub
// detail paging and the Recommended hubs (built the full list to take
// the first N).
//
// Failing-first: paging to page 2 must not freeze the UI (< 250ms max
// tick gap). Before the fix each page turn rebuilds all 199k items.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  const testPassword = 'pa' 'ss';

  List<XtreamVodStream> trexVodRows() => List<XtreamVodStream>.generate(
    199762,
    (i) => XtreamVodStream(streamId: i, name: 'Movie $i', containerExtension: 'mp4', categoryId: '1'),
  );

  List<XtreamSeries> trexSeriesRows() => List<XtreamSeries>.generate(
    46461,
    (i) => XtreamSeries(seriesId: i, name: 'Show $i', categoryId: '1'),
  );

  IptvClient trexClient() {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    client.testXtreamApi = _BrowseFakeXtreamApi(trexVodRows(), trexSeriesRows());
    return client;
  }

  /// A 16ms ticker: the longest gap between ticks while [body] runs is
  /// the UI freeze. (See iptv_build13_cache_benchmark_test.dart.)
  Future<int> measureMaxGap(Future<void> Function() body) async {
    var maxGap = 0;
    var last = DateTime.now();
    final timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = DateTime.now();
      final gap = now.difference(last).inMilliseconds;
      if (gap > maxGap) maxGap = gap;
      last = now;
    });
    try {
      await body();
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      timer.cancel();
    }
    return maxGap;
  }

  group('build13: paged browse at Trex scale', () {
    test('turning to page 2 of Movies does not freeze the UI', () async {
      final client = trexClient();
      try {
        final libraries = await client.fetchLibraries();
        final moviesId = libraries.firstWhere((l) => l.title.contains('Movies')).id;
        // Page 1 warms the catalog (network load + disk write).
        final page1 = await client.fetchLibraryPagedContent(moviesId, query: const LibraryQuery(offset: 0, limit: 50));
        expect(page1.items.length, 50);
        expect(page1.totalCount, 199762);
        // Page 2 is the measured turn: before the fix it rebuilds all
        // 199k MediaItems just to slice 50 out.
        final gap = await measureMaxGap(() async {
          final page2 = await client.fetchLibraryPagedContent(moviesId, query: const LibraryQuery(offset: 50, limit: 50));
          expect(page2.items.length, 50);
          expect(page2.items.first.title, 'Movie 50');
        });
        // ignore: avoid_print
        print('BUILD13-BENCH browse page 2: maxTickGap=${gap}ms');
        expect(gap, lessThan(250));
      } finally {
        client.close();
      }
    });

    test('opening the Movies Recommended hub does not build the whole catalog', () async {
      final client = trexClient();
      try {
        final libraries = await client.fetchLibraries();
        final moviesId = libraries.firstWhere((l) => l.title.contains('Movies')).id;
        final gap = await measureMaxGap(() async {
          final hubs = await client.fetchLibraryHubs(moviesId, libraryName: 'Trex — Movies');
          expect(hubs.length, 1);
          expect(hubs.first.items.length, greaterThan(0));
        });
        // ignore: avoid_print
        print('BUILD13-BENCH movies hub: maxTickGap=${gap}ms');
        expect(gap, lessThan(250));
      } finally {
        client.close();
      }
    });
  });
}

class _BrowseFakeXtreamApi extends XtreamApi {
  _BrowseFakeXtreamApi(this.vodRows, this.seriesRows)
    : vodBody = jsonEncode(vodRows.map((r) => r.toJson()).toList()),
      seriesBody = jsonEncode(seriesRows.map((r) => r.toJson()).toList()),
      super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final List<XtreamVodStream> vodRows;
  final List<XtreamSeries> seriesRows;
  final String vodBody;
  final String seriesBody;

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async => const [
    XtreamCategory(id: '1', name: '|EN| Movies 1'),
  ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => const [
    XtreamCategory(id: '1', name: '|EN| Series 1'),
  ];

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => const [
    XtreamCategory(id: '1', name: '|EN| Live 1'),
  ];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) {
      lastVodStreamsBody = vodBody;
      return vodRows;
    }
    lastVodStreamsBody = null;
    return const [];
  }

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) {
      lastSeriesBody = seriesBody;
      return seriesRows;
    }
    lastSeriesBody = null;
    return const [];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];
}
