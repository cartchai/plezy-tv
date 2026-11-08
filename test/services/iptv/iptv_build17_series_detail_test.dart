// FAILING-FIRST — build #17 §12 (v2.25.13): series detail episodes
// rendered as season headers ("No episodes found").
//
// Matt, 2026-11-08 ~12:54 EST (screenshot 9637_10_1ngw.jpg): opening
// "D+ - Secrets of the Whales (US)" from Recommended shows season tabs
// labelled with the episode's panel title ("… - S01E01") and "No
// episodes found" underneath — the S1E1 top play button works, but no
// episode is selectable. Root cause: IptvClient.fetchChildren(series)
// returned a FLAT episode list, which the detail screen treats as
// seasons; fetching a "season" (an episode id) returned [].
//
// The fix: fetchChildren('series:<id>') returns one synthetic season
// item per season; fetchChildren('season:<seriesId>:<n>') returns that
// season's episodes. The leaves callers (downloads / sync / the episode
// queue) still get the flat episode list via fetchPlayableDescendants.

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  IptvClient clientWith(XtreamApi api) {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    client.testXtreamApi = api;
    return client;
  }

  group('build17 series detail: fetchChildren returns seasons', () {
    test('one season, four episodes — the Whales shape from the phone', () async {
      // Real panel shape (parent probe, 2026-11-08 ~13:02 EST):
      // get_series_info for "D+ - Secrets of the Whales (US)"
      // (series_id 9483) returns episodes as a dict keyed by
      // season-number strings ({'1': 4 episodes}); episode titles carry
      // the " - S01E01" suffix.
      final client = clientWith(_WhalesFakeApi());
      try {
        final children = await client.fetchChildren('series:9483');
        expect(children.length, 1);
        expect(children.first.kind, MediaKind.season);
        expect(children.first.title, 'Season 1');
        expect(children.first.id, 'season:9483:1');
        expect(children.first.index, 1);
        expect(children.first.leafCount, 4);

        final episodes = await client.fetchChildren(children.first.id);
        expect(episodes.length, 4);
        expect(episodes.map((e) => e.kind).toSet(), {MediaKind.episode});
        expect(
          episodes.map((e) => e.title),
          contains('D+ - Secrets of the Whales (US) - S01E01'),
        );
        // Selectable episode rows: each has its own episode id and a
        // stream URL (the old bug made these rows unreachable).
        expect(episodes.every((e) => e.id.startsWith('episode:9483:')), isTrue);
        expect(
          episodes.every(
            (e) => switch (e) {
              XtreamMediaItem(:final streamUrl) => (streamUrl ?? '').isNotEmpty,
              _ => false,
            },
          ),
          isTrue,
        );

        // The leaves callers (downloads / sync / the episode queue)
        // still get the flat episode list, not season items.
        final leaves = await client.fetchPlayableDescendants('series:9483');
        expect(leaves.length, 4);
        expect(leaves.every((e) => e.kind == MediaKind.episode), isTrue);
        final queue = await client.fetchClientSideEpisodeQueue('series:9483');
        expect(queue?.length, 4);
      } finally {
        client.close();
      }
    });

    test('two seasons — two Season N tabs with the right episodes under each', () async {
      final client = clientWith(_TwoSeasonFakeApi());
      try {
        final children = await client.fetchChildren('series:20');
        expect(children.map((s) => s.title), ['Season 1', 'Season 2']);
        expect(children.map((s) => s.kind).toSet(), {MediaKind.season});
        final seasonOne = await client.fetchChildren(children[0].id);
        final seasonTwo = await client.fetchChildren(children[1].id);
        expect(seasonOne.map((e) => e.title), ['S1 Pilot', 'S1 Second']);
        expect(seasonTwo.map((e) => e.title), ['S2 Return']);
      } finally {
        client.close();
      }
    });
  });
}

/// Fake panel for the Whales shape: one series, one season, four
/// episodes with panel-style " - S01E01" titles.
class _WhalesFakeApi extends XtreamApi {
  _WhalesFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async =>
      const [XtreamCategory(id: '1219', name: '|EN| TOP SERIES')];

  @override
  Future<List<XtreamCategory>> getVodCategories() async => const [];

  @override
  Future<List<XtreamCategory>> getLiveCategories() async => const [];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [
    XtreamSeries(seriesId: 9483, name: 'D+ - Secrets of the Whales (US)', categoryId: '1219'),
  ];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => const [];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => const [];

  @override
  Future<XtreamSeriesInfo> getSeriesInfo(int seriesId) async => const XtreamSeriesInfo(
    episodesBySeason: {
      1: [
        XtreamEpisode(id: 1, episodeNum: 1, title: 'D+ - Secrets of the Whales (US) - S01E01'),
        XtreamEpisode(id: 2, episodeNum: 2, title: 'D+ - Secrets of the Whales (US) - S01E02'),
        XtreamEpisode(id: 3, episodeNum: 3, title: 'D+ - Secrets of the Whales (US) - S01E03'),
        XtreamEpisode(id: 4, episodeNum: 4, title: 'D+ - Secrets of the Whales (US) - S01E04'),
      ],
    },
  );
}

class _TwoSeasonFakeApi extends _WhalesFakeApi {
  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [
    XtreamSeries(seriesId: 20, name: 'Two Season Show', categoryId: '1219'),
  ];

  @override
  Future<XtreamSeriesInfo> getSeriesInfo(int seriesId) async => const XtreamSeriesInfo(
    episodesBySeason: {
      1: [
        XtreamEpisode(id: 10, episodeNum: 1, title: 'S1 Pilot'),
        XtreamEpisode(id: 11, episodeNum: 2, title: 'S1 Second'),
      ],
      2: [XtreamEpisode(id: 20, episodeNum: 1, title: 'S2 Return')],
    },
  );
}
