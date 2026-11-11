// R2.2 — decorated-title strip at write time + starts-with arm.
//
// The real Trex title `EN - Game Of Thrones (2011)` normalizes to
// "en game of thrones 2011" (22 chars) and BM25 ranks it 252nd of 252
// behind shorter near-matches, so the 200-row cap cuts it. Stripping
// the `EN - ` prefix + year at write time makes it "game of thrones"
// (rank 1st, tied with the bare title), and the starts-with arm
// prepends exact-prefix matches ahead of the FTS rows.
//
// Failing-first: [stripTitleDecorations] does not exist on base, and
// the GoT searches return the title ranked last / cut by the cap.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/r2_fake_xtream_api.dart';

const _gotId = 219;
const _gotName = 'EN - Game Of Thrones (2011)';

/// 251 near-matches, all containing the tokens game/of/thrones, all with
/// a normalized form SHORTER than the real title's — the shape the #29
/// tester measured (real title 252nd of 252). Copied from the R2
/// research probe (probe_got_test.dart).
List<String> _nearMatches() {
  final out = <String>['Game of Thrones'];
  for (var i = 1; i <= 99; i++) {
    out.add('Game of Thrones $i');
  }
  for (var i = 1; i <= 99; i++) {
    out.add('Game of Thrones S$i');
  }
  for (var i = 1; i <= 52; i++) {
    out.add('Game of Thrones Pt $i');
  }
  assert(out.length == 251, 'near-match count: ${out.length}');
  return out;
}

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build_r2_scorer_');
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });

  tearDown(() async {
    IptvSearchIndex.debugDirectoryProvider = null;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('stripTitleDecorations', () {
    test('strips the language prefix and year (case preserved — normalize lowercases after)', () {
      expect(stripTitleDecorations('EN - Game Of Thrones (2011)'), 'Game Of Thrones');
      expect(stripTitleDecorations('FR - Le Film (2020)'), 'Le Film');
    });

    test('strips whole-token quality markers, case-insensitively', () {
      expect(stripTitleDecorations('Dune 4K'), 'Dune');
      expect(stripTitleDecorations('Dune FHD 1080p'), 'Dune');
      expect(stripTitleDecorations('Dune x265 HEVC'), 'Dune');
      // A quality token mid-title is stripped too (token boundaries).
      expect(stripTitleDecorations('The 4K Movie'), 'The Movie');
    });

    test('leaves plain titles alone and never returns empty', () {
      expect(stripTitleDecorations('Game of Thrones'), 'Game of Thrones');
      expect(stripTitleDecorations('HD'), 'HD');
      expect(stripTitleDecorations('Go - The Story'), 'The Story');
    });
  });

  Future<IptvSearchIndex> openGotIndex() async {
    final index = await IptvSearchIndex.open();
    final rows = <IptvSearchIndexRow>[
      IptvSearchIndexRow.fromSeries(const XtreamSeries(seriesId: _gotId, name: _gotName, categoryId: '1219')),
      for (var i = 0; i < _nearMatches().length; i++)
        IptvSearchIndexRow.fromSeries(XtreamSeries(seriesId: 1000 + i, name: _nearMatches()[i], categoryId: '1219')),
      for (var i = 0; i < 46000; i++)
        IptvSearchIndexRow.fromSeries(XtreamSeries(seriesId: 100000 + i, name: 'Filler Series $i', categoryId: '${(i % 236) + 1}')),
    ];
    index.replaceType(
      connectionId: 'conn-xt-1',
      type: IptvSearchIndex.typeSeries,
      rows: rows,
      categories: const {'1219': '|EN| TOP SERIES'},
      syncStampMs: DateTime.now().millisecondsSinceEpoch,
    );
    return index;
  }

  group('GoT survives the cap', () {
    test('search(limit: 200) contains series 219', () async {
      final index = await openGotIndex();
      addTearDown(index.close);
      final results = index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'game of thrones', limit: 200);
      expect(results.map((r) => r.streamId), contains(_gotId));
      // And the exact title is first — the starts-with arm prepends it.
      expect(results.first.streamId, _gotId);
    });

    test('the stored norm is the stripped title, not the raw one', () async {
      final index = await openGotIndex();
      addTearDown(index.close);
      final results = index.search('conn-xt-1', IptvSearchIndex.typeSeries, 'game of thrones', limit: 200);
      final got = results.firstWhere((r) => r.streamId == _gotId);
      expect(got.name, _gotName, reason: 'display name stays raw');
      expect(got.nameNorm, 'game of thrones');
    });
  });

  group('full client search ranks GoT first among series', () {
    test('searchItems ranks 219 first', () async {
      final api = R2FakeXtreamApi();
      final client = r2ClientWith(api);
      // Seed the client's index with the GoT fixture (the strip runs
      // at write time, through fromSeries). The client opens its own
      // connection to the same file on the first search and reads the
      // committed rows.
      final index = await openGotIndex();
      addTearDown(index.close);
      final results = await client.searchItems('game of thrones');
      final seriesTitles = results.map((m) => m.title).toList();
      expect(seriesTitles, contains(_gotName));
      expect(seriesTitles.first, _gotName, reason: '219 ranks first among series');
      expect(api.totalRequests, 0, reason: 'the search is local-only');
    });
  });

  group('bench stays fast', () {
    test(
      'common median < 1000 ms, rare < 100 ms',
      timeout: const Timeout(Duration(minutes: 5)),
      () async {
        final api = R2FakeXtreamApi();
        final client = r2ClientWith(api);
        final index = await IptvSearchIndex.open();
        addTearDown(index.close);
        final stamp = DateTime.now().millisecondsSinceEpoch;
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
        // The GoT series fixture (252 near-matches + 46k fillers),
        // written through the same connection.
        index.replaceType(
          connectionId: 'conn-xt-1',
          type: IptvSearchIndex.typeSeries,
          rows: <IptvSearchIndexRow>[
            IptvSearchIndexRow.fromSeries(const XtreamSeries(seriesId: _gotId, name: _gotName, categoryId: '1219')),
            for (var i = 0; i < _nearMatches().length; i++)
              IptvSearchIndexRow.fromSeries(XtreamSeries(seriesId: 1000 + i, name: _nearMatches()[i], categoryId: '1219')),
            for (var i = 0; i < 46000; i++)
              IptvSearchIndexRow.fromSeries(XtreamSeries(seriesId: 100000 + i, name: 'Filler Series $i', categoryId: '${(i % 236) + 1}')),
          ],
          categories: const {'1219': '|EN| TOP SERIES'},
          syncStampMs: stamp,
        );

        Future<List<int>> timeSearch(String query, {int runs = 10}) async {
          await client.searchItems(query);
          final times = <int>[];
          for (var i = 0; i < runs; i++) {
            final started = DateTime.now();
            await client.searchItems(query);
            times.add(DateTime.now().difference(started).inMilliseconds);
          }
          times.sort();
          return times;
        }

        final commonTimes = await timeSearch('Movie Title');
        final rareTimes = await timeSearch('game of thrones');
        final commonMedian = commonTimes[commonTimes.length ~/ 2];
        final rareMedian = rareTimes[rareTimes.length ~/ 2];
        // ignore: avoid_print
        print('R2.2-bench: common median=${commonMedian}ms rare median=${rareMedian}ms');
        expect(commonMedian, lessThan(1000));
        expect(rareMedian, lessThan(100));
        expect(api.totalRequests, 0, reason: 'the bench searches are local-only');
      },
    );
  });
}
