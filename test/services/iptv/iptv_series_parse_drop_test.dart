// TOLERANT SERIES PARSE — v1.0.17.
//
// Matt's phone on v1.0.16+188: the series sync dropped 45,991 of ~48k rows
// in parse and landed 246. Root cause: `XtreamSeries.fromJson` cast
// `backdrop_path` as `String?`, but the panel sends it as a JSON ARRAY
// (the documented Xtream shape — `[]` when a series has no backdrops,
// `["url", ...]` when it does). Both shapes threw, and
// `parseFlexibleJsonListCounted` dropped the whole row. The field is never
// used by the app. The fix coerces every string read in the series, VOD
// and live readers (`flexibleString`) so a mistyped field can never drop
// a row. Moved in from the research probes
// (`probe_series_parse_drop_test.dart`); the failing-first run on base
// f06949d89 was 2/6 pass, 4/6 fail for the product reason (P-D4: 50 of
// 1,000 survive — the phone's exact ~5%). Zero panel requests.

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/utils/json_utils.dart';

/// One `get_series` row in the documented Xtream shape (see the public
/// Xtream Codes Player API docs: `backdrop_path` is an ARRAY of backdrop
/// image URLs; `cover`/`plot`/`cast`/`director`/`genre`/`releaseDate`/
/// `youtube_trailer` are strings; `rating`/`episode_run_time` are
/// flexible; `category_ids` is an array the parser ignores).
Map<String, dynamic> seriesRow({
  required int id,
  required Object? name,
  required String categoryId,
  Object? backdropPath = const <dynamic>[],
  Object? cover = 'http://example.com/cover.jpg',
  Object? plot = 'A plot.',
  Object? cast = 'Actor One, Actor Two',
  Object? director = 'Director One',
  Object? genre = 'Drama',
  Object? releaseDate = '2011-04-17',
  Object? youtubeTrailer = 'abc123',
}) {
  final row = <String, dynamic>{
    'num': id,
    'name': name,
    'series_id': id,
    'cover': cover,
    'plot': plot,
    'cast': cast,
    'director': director,
    'genre': genre,
    'releaseDate': releaseDate,
    'last_modified': '1699999999',
    'rating': '8.9',
    'rating_5based': 4.5,
    'youtube_trailer': youtubeTrailer,
    'episode_run_time': '60',
    'category_id': categoryId,
    'category_ids': [int.parse(categoryId.replaceAll('cat', ''))],
  };
  if (backdropPath != null) row['backdrop_path'] = backdropPath;
  return row;
}

void main() {
  group('series tolerant parse (v1.0.17)', () {
    test('REGRESSION: a get_series row with backdrop_path [] parses', () {
      // The standard API shape: an empty backdrop array is the normal
      // "no backdrops" value. It must never regress into a dropped row.
      final rows = [
        for (var i = 0; i < 100; i++)
          seriesRow(id: 1000 + i, name: 'Show $i', categoryId: 'cat1', backdropPath: const <dynamic>[]),
      ];
      final parsed = parseFlexibleJsonListCounted(rows, XtreamSeries.fromJson);
      expect(parsed.rows.length, 100);
      expect(parsed.dropped, 0);
    });

    test('P-D2: rows with a populated backdrop_path array parse', () {
      final rows = [
        for (var i = 0; i < 100; i++)
          seriesRow(
            id: 2000 + i,
            name: 'Show $i',
            categoryId: 'cat1',
            backdropPath: ['http://example.com/bd$i.jpg'],
          ),
      ];
      final parsed = parseFlexibleJsonListCounted(rows, XtreamSeries.fromJson);
      expect(parsed.rows.length, 100);
      expect(parsed.dropped, 0);
      // The first backdrop survives the round trip.
      expect(parsed.rows.first.backdropPath, 'http://example.com/bd0.jpg');
    });

    test('P-D3: each other mistyped string field keeps its row', () {
      final rows = <Map<String, dynamic>>[
        seriesRow(id: 3001, name: 'Numeric cover', categoryId: 'cat1', cover: 42),
        seriesRow(id: 3002, name: 'Array cast', categoryId: 'cat1', cast: ['Actor One']),
        seriesRow(id: 3003, name: 'Array genre', categoryId: 'cat1', genre: ['Drama']),
        seriesRow(id: 3004, name: 'Array director', categoryId: 'cat1', director: ['Director One']),
        seriesRow(id: 3005, name: 'Int releaseDate', categoryId: 'cat1', releaseDate: 2011),
        seriesRow(id: 3006, name: 'Numeric trailer', categoryId: 'cat1', youtubeTrailer: 12345),
        seriesRow(id: 3007, name: 123, categoryId: 'cat1'),
        seriesRow(id: 3008, name: 'Numeric plot', categoryId: 'cat1', plot: 42),
        seriesRow(id: 3009, name: 'Numeric backdrop', categoryId: 'cat1', backdropPath: 7),
      ];
      final parsed = parseFlexibleJsonListCounted(rows, XtreamSeries.fromJson);
      expect(parsed.rows.length, 9);
      expect(parsed.dropped, 0);
      // Coercion keeps a usable value, not a stringified list.
      expect(parsed.rows[1].cast, 'Actor One');
      expect(parsed.rows[2].genre, 'Drama');
      expect(parsed.rows[6].name, '123');
    });

    test('P-D4: phone-scale list — 95% carry a backdrop array', () {
      // Phone log model: ~46k visible rows, ~95% carry backdrop_path as
      // an array (uniform-rate inference from the log: 45,991 dropped,
      // 246 landed). 1,000 rows over 18 categories, 950 with the array.
      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < 1000; i++) {
        final hasBackdrop = i % 20 != 0; // 950 of 1,000
        rows.add(
          seriesRow(
            id: 4000 + i,
            name: 'Show $i',
            categoryId: 'cat${(i % 18) + 1}',
            backdropPath: hasBackdrop ? ['http://example.com/bd$i.jpg'] : null,
          ),
        );
      }
      final parsed = parseFlexibleJsonListCounted(rows, XtreamSeries.fromJson);
      expect(parsed.rows.length, greaterThanOrEqualTo(990));
      expect(parsed.dropped, lessThanOrEqualTo(10));
    });

    test('P-D5 CONTROL: VOD/live ignore backdrop_path arrays', () {
      final vodRows = [
        for (var i = 0; i < 100; i++)
          {
            'stream_id': 5000 + i,
            'name': 'Movie $i',
            'stream_icon': 'http://example.com/icon.jpg',
            'cover': 'http://example.com/cover.jpg',
            'rating': '7.5',
            'category_id': 'mov1',
            'container_extension': 'mp4',
            'backdrop_path': ['http://example.com/bd.jpg'],
          },
      ];
      final vod = parseFlexibleJsonListCounted(vodRows, XtreamVodStream.fromJson);
      expect(vod.rows.length, 100);
      expect(vod.dropped, 0);
      final liveRows = [
        for (var i = 0; i < 100; i++)
          {
            'stream_id': 6000 + i,
            'name': 'Channel $i',
            'stream_icon': 'http://example.com/icon.jpg',
            'epg_channel_id': 'ch$i',
            'category_id': 'live1',
            'backdrop_path': <dynamic>[],
          },
      ];
      final live = parseFlexibleJsonListCounted(liveRows, XtreamLiveStream.fromJson);
      expect(live.rows.length, 100);
      expect(live.dropped, 0);
    });

    test('P-D6 CONTROL: clean rows (no backdrop field) parse', () {
      final rows = [
        for (var i = 0; i < 100; i++)
          seriesRow(id: 7000 + i, name: 'Show $i', categoryId: 'cat1', backdropPath: null),
      ];
      final parsed = parseFlexibleJsonListCounted(rows, XtreamSeries.fromJson);
      expect(parsed.rows.length, 100);
      expect(parsed.dropped, 0);
    });

    test('P-D7: VOD/live mistyped string fields keep their rows', () {
      // The same tolerance as series: a numeric cover or a list-shaped
      // icon must not drop a movie or a channel.
      final vodRows = [
        {'stream_id': 8001, 'name': 'Numeric cover', 'cover': 42, 'category_id': 'mov1'},
        {'stream_id': 8002, 'name': 'Array icon', 'stream_icon': ['http://example.com/icon.jpg'], 'category_id': 'mov1'},
        {'stream_id': 8003, 'name': 99, 'category_id': 'mov1'},
      ];
      final vod = parseFlexibleJsonListCounted(vodRows, XtreamVodStream.fromJson);
      expect(vod.rows.length, 3);
      expect(vod.dropped, 0);
      expect(vod.rows[1].streamIcon, 'http://example.com/icon.jpg');
      final liveRows = [
        {'stream_id': 8101, 'name': 'Numeric icon', 'stream_icon': 7, 'epg_channel_id': 'ch1', 'category_id': 'live1'},
        {'stream_id': 8102, 'name': 'Array epg id', 'epg_channel_id': ['ch2'], 'category_id': 'live1'},
      ];
      final live = parseFlexibleJsonListCounted(liveRows, XtreamLiveStream.fromJson);
      expect(live.rows.length, 2);
      expect(live.dropped, 0);
      expect(live.rows[1].epgChannelId, 'ch2');
    });

    test('droppedRows still counts rows a throwing parser rejects', () {
      // The tolerant readers no longer throw, so the counting itself is
      // pinned at the mechanism level: a parser that rejects a row must
      // still surface it as dropped, never swallow it silently. (This is
      // what F3 in iptv_build_series_fix_test.dart used to pin with
      // mistyped series rows before 1.0.17 made them parse.)
      int parseOrThrow(Map<String, dynamic> json) {
        if (json['bad'] == true) throw const FormatException('sentinel');
        return 1;
      }

      final parsed = parseFlexibleJsonListCounted(
        [
          {'bad': false},
          {'bad': true},
          {'bad': false},
        ],
        parseOrThrow,
      );
      expect(parsed.rows, [1, 1]);
      expect(parsed.dropped, 1);
    });
  });
}
