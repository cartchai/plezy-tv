// R2.1 — no-match FTS gate: a section whose type holds no row for the
// needle must answer in ~10 ms (one EXISTS + LIKE over the type's rows),
// not ~280 ms (a trigram posting-list walk over the whole table).
//
// The gate lives inside [IptvSearchIndex.search]: it must never change
// the result SET — a section that has matches still runs the full
// probe-then-rank path unchanged.
//
// Failing-first: [hasMatch] does not exist on base (the file fails to
// load), and the Trex-scale timing assertions fail on the ungated FTS
// walk (~280 ms per no-match section).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/r2_fake_xtream_api.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build_r2_gate_');
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });

  tearDown(() async {
    IptvSearchIndex.debugDirectoryProvider = null;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<IptvSearchIndex> openSmallIndex() async {
    final index = await IptvSearchIndex.open();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    index.replaceType(
      connectionId: 'conn-xt-1',
      type: IptvSearchIndex.typeLive,
      rows: r2FixtureLiveRows().map(IptvSearchIndexRow.fromLive).toList(),
      categories: {for (final c in r2FixtureLiveCategories()) c.id: c.name},
      syncStampMs: stamp,
    );
    index.replaceType(
      connectionId: 'conn-xt-1',
      type: IptvSearchIndex.typeMovie,
      rows: r2FixtureVodRows().map(IptvSearchIndexRow.fromMovie).toList(),
      categories: {for (final c in r2FixtureVodCategories()) c.id: c.name},
      syncStampMs: stamp,
    );
    index.replaceType(
      connectionId: 'conn-xt-1',
      type: IptvSearchIndex.typeSeries,
      rows: r2FixtureSeriesRows().map(IptvSearchIndexRow.fromSeries).toList(),
      categories: {for (final c in r2FixtureSeriesCategories()) c.id: c.name},
      syncStampMs: stamp,
    );
    return index;
  }

  group('hasMatch', () {
    test('false when no row in the type contains the needle tokens', () async {
      final index = await openSmallIndex();
      addTearDown(index.close);
      // 'Filler Movie' matches movies only — series and live hold no row
      // containing both tokens.
      expect(index.hasMatch('conn-xt-1', IptvSearchIndex.typeSeries, 'Filler Movie'), isFalse);
      expect(index.hasMatch('conn-xt-1', IptvSearchIndex.typeLive, 'Filler Movie'), isFalse);
      expect(index.hasMatch('conn-xt-1', IptvSearchIndex.typeMovie, 'Filler Movie'), isTrue);
    });

    test('true when a row exists, even for a substring token', () async {
      final index = await openSmallIndex();
      addTearDown(index.close);
      expect(index.hasMatch('conn-xt-1', IptvSearchIndex.typeSeries, 'thrones'), isTrue);
      expect(index.hasMatch('conn-xt-1', IptvSearchIndex.typeSeries, 'game of thrones'), isTrue);
    });

    test('true when the needle has no token >= 3 chars — the LIKE arm decides', () async {
      final index = await openSmallIndex();
      addTearDown(index.close);
      expect(index.hasMatch('conn-xt-1', IptvSearchIndex.typeSeries, 'of'), isTrue);
      expect(index.hasMatch('conn-xt-1', IptvSearchIndex.typeLive, 'a&e'), isTrue);
    });
  });

  group('search() with the gate — the result set never changes', () {
    test('a needle matching movies only returns [] for series/live, movies intact', () async {
      final index = await openSmallIndex();
      addTearDown(index.close);
      // The FTS arm is a documented superset: MATCH searches every FTS
      // column, including `type` — so the term 'movie' matches every
      // movie row through its type column, and 'Filler Common 0' comes
      // along. The caller's RegExp is authoritative and drops it; the
      // gate's job is only to leave a matching section's set untouched,
      // which this asserts exactly.
      final movies = index.search('conn-xt-1', IptvSearchIndex.typeMovie, 'Filler Movie');
      expect(movies.map((r) => r.streamId), unorderedEquals([1, 200, 201, 202, 203, 204]));
      expect(index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'Filler Movie'), isEmpty);
      expect(index.search('conn-xt-1', IptvSearchIndex.typeLive, 'Filler Movie'), isEmpty);
    });

    test('a needle matching all three types returns all three sets', () async {
      final index = await openSmallIndex();
      addTearDown(index.close);
      // 'Filler Common 0' is one row in every type.
      expect(index.search('conn-xt-1', IptvSearchIndex.typeMovie, 'Filler Common').map((r) => r.streamId), [1]);
      expect(index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'Filler Common').map((r) => r.streamId), [2]);
      expect(index.search('conn-xt-1', IptvSearchIndex.typeLive, 'Filler Common').map((r) => r.streamId), [1]);
    });

    test('a needle with no token >= 3 chars still falls back to LIKE', () async {
      final index = await openSmallIndex();
      addTearDown(index.close);
      // 'of' matches only the GoT series row (normalized 'game of thrones 2011').
      final series = index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'of');
      expect(series.map((r) => r.streamId), [219]);
    });
  });

  group('Trex-scale timing', () {
    test(
      'a common needle costs < 50 ms per no-match section at Trex scale',
      timeout: const Timeout(Duration(minutes: 5)),
      () async {
        final index = await IptvSearchIndex.open();
        addTearDown(index.close);
        final stamp = DateTime.now().millisecondsSinceEpoch;
        index.replaceType(
          connectionId: 'conn-xt-1',
          type: IptvSearchIndex.typeLive,
          rows: [
            for (var i = 0; i < 55000; i++)
              IptvSearchIndexRow.fromLive(
                XtreamLiveStream(streamId: 300000 + i, name: 'EN - Channel $i', categoryId: '${(i % 833) + 1}', epgChannelId: 'ch$i'),
              ),
          ],
          categories: {for (var i = 1; i <= 833; i++) '$i': '|EN| Live $i'},
          syncStampMs: stamp,
        );
        index.replaceType(
          connectionId: 'conn-xt-1',
          type: IptvSearchIndex.typeMovie,
          rows: [
            for (var i = 0; i < 200000; i++)
              IptvSearchIndexRow.fromMovie(
                XtreamVodStream(streamId: 200000 + i, name: 'Movie Title $i (2020)', categoryId: '${(i % 368) + 1}'),
              ),
          ],
          categories: {for (var i = 1; i <= 368; i++) '$i': '|EN| Movies $i'},
          syncStampMs: stamp,
        );
        index.replaceType(
          connectionId: 'conn-xt-1',
          type: IptvSearchIndex.typeSeries,
          rows: [
            IptvSearchIndexRow.fromSeries(const XtreamSeries(seriesId: 219, name: 'EN - Game Of Thrones (2011)', categoryId: '1219')),
            for (var i = 0; i < 46526; i++)
              IptvSearchIndexRow.fromSeries(
                XtreamSeries(seriesId: 100000 + i, name: 'Filler Series $i', categoryId: '${(i % 236) + 1}'),
              ),
          ],
          categories: {
            for (var i = 1; i <= 236; i++) '$i': '|EN| Series $i',
            '1219': '|EN| TOP SERIES',
          },
          syncStampMs: stamp,
        );
        expect(index.rowCounts('conn-xt-1'), {'live': 55000, 'movie': 200000, 'series': 46527});

        // 'Movie Title' matches ~200k movies and nothing else. Warm-up
        // run first (first search pays the FTS warm-up), then 3 timed
        // runs per section; the median is the number.
        int timeMs(String type, String needle) {
          index.search('conn-xt-1', type, needle);
          final times = <int>[];
          for (var i = 0; i < 3; i++) {
            final stopwatch = Stopwatch()..start();
            index.search('conn-xt-1', type, needle);
            times.add(stopwatch.elapsedMilliseconds);
          }
          times.sort();
          return times[1];
        }

        final moviesMs = timeMs(IptvSearchIndex.typeMovie, 'Movie Title');
        final seriesMs = timeMs(IptvSearchIndex.typeSeries, 'Movie Title');
        final liveMs = timeMs(IptvSearchIndex.typeLive, 'Movie Title');
        // ignore: avoid_print
        print('R2.1-bench: movies=${moviesMs}ms series=${seriesMs}ms live=${liveMs}ms total=${moviesMs + seriesMs + liveMs}ms');
        expect(index.search('conn-xt-1', IptvSearchIndex.typeMovie, 'Movie Title'), isNotEmpty);
        expect(index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'Movie Title'), isEmpty);
        expect(index.search('conn-xt-1', IptvSearchIndex.typeLive, 'Movie Title'), isEmpty);
        // The ungated FTS walk costs ~280 ms per no-match section on
        // this VM (RESEARCH_R2 §2.1); the gate answers in ~10 ms.
        expect(seriesMs, lessThan(50), reason: 'series has no match for this needle');
        expect(liveMs, lessThan(50), reason: 'live has no match for this needle');
        expect(moviesMs + seriesMs + liveMs, lessThan(100));
      },
    );
  });
}
