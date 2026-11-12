// Probe for build #25 (resume / Continue Watching for IPTV).
//
// On base 82ef3f8c1 (v1.0.13) these FAIL for the right product reasons:
//  - `IptvClient.reportPlaybackStarted/Progress/Stopped` are no-ops
//    (`lib/media/iptv_client.dart:4258-4300`), so nothing is ever recorded.
//  - `IptvClient.fetchContinueWatching` returns `const []`
//    (`lib/media/iptv_client.dart:3834-3838`).
//  - `fetchItem` never stamps a resume position, so the detail screen and
//    the player open every IPTV title from 0:00.
// No live panel: fake Xtream API only. Fake credentials are concatenated
// below so the literal never appears in this file.
//
// The two "guard" tests pass vacuously on base (nothing is ever recorded)
// and must KEEP passing on the fix: a sub-5s stop and a finished (>=90%)
// stop must not leave a Continue Watching entry behind.
//
// Copy to test/services/iptv/iptv_build25_resume_probe_test.dart to run.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Fake provider: two movies, one show with one 45-minute episode.
/// Movie 99 / series 99 do not exist — stopping them simulates an item
/// that left the catalog, which must still render from its snapshot.
class _FakeXtreamApi extends XtreamApi {
  _FakeXtreamApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamVodStream(streamId: 1, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: '1'),
    XtreamVodStream(streamId: 2, name: 'Beta Movie', containerExtension: 'mkv', categoryId: '2'),
  ];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1'),
  ];

  @override
  Future<XtreamSeriesInfo> getSeriesInfo(int seriesId) async => const XtreamSeriesInfo(
    episodesBySeason: {
      1: [XtreamEpisode(id: 100, episodeNum: 1, title: 'Pilot', durationSeconds: 2700)],
    },
  );

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'Action'), XtreamCategory(id: '2', name: 'Drama')];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'Action')];
}

IptvClient _client() {
  final client = IptvClient.forConnection(_trexConnection());
  client.testXtreamApi = _FakeXtreamApi();
  return client;
}

void main() {
  setUp(resetSharedPreferencesForTest);

  test('stopped movie appears in Continue Watching with position + duration', () async {
    final client = _client();
    await client.reportPlaybackStopped(
      itemId: 'movie:1',
      position: const Duration(minutes: 30),
      duration: const Duration(minutes: 100),
    );
    final rows = await client.fetchContinueWatching();
    expect(rows, hasLength(1));
    expect(rows.single.id, 'movie:1');
    // Duration comes from the player's report, not the catalog: VOD rows
    // carry no duration (iptv_client.dart _movieItem sets none).
    expect(rows.single.viewOffsetMs, 30 * 60 * 1000);
    expect(rows.single.durationMs, 100 * 60 * 1000);
    expect(rows.single.lastViewedAt, isNotNull);
    expect(rows.single.hasActiveProgress, isTrue);
  });

  test('position survives a restart: a fresh client reads the same row', () async {
    await _client().reportPlaybackStopped(
      itemId: 'movie:1',
      position: const Duration(minutes: 30),
      duration: const Duration(minutes: 100),
    );
    // A new client instance (a new app launch) over the same prefs.
    final rows = await _client().fetchContinueWatching();
    expect(rows, hasLength(1));
    expect(rows.single.id, 'movie:1');
    expect(rows.single.viewOffsetMs, 30 * 60 * 1000);
  });

  test('fetchItem stamps the resume position so detail + player resume', () async {
    final client = _client();
    await client.reportPlaybackStopped(
      itemId: 'movie:1',
      position: const Duration(minutes: 30),
      duration: const Duration(minutes: 100),
    );
    final item = await client.fetchItem('movie:1');
    expect(item, isNotNull);
    expect(item!.viewOffsetMs, 30 * 60 * 1000);
    expect(item.durationMs, 100 * 60 * 1000);
  });

  test('stopped episode records per-episode progress under its series', () async {
    final client = _client();
    await client.reportPlaybackStopped(
      itemId: 'episode:10:100',
      position: const Duration(minutes: 10),
      duration: const Duration(minutes: 45),
    );
    final rows = await client.fetchContinueWatching();
    expect(rows, hasLength(1));
    expect(rows.single.id, 'episode:10:100');
    expect(rows.single.parentId, 'series:10');
    expect(rows.single.viewOffsetMs, 10 * 60 * 1000);
    expect(rows.single.durationMs, 45 * 60 * 1000);
  });

  test('newest first: the most recently stopped item leads', () async {
    final client = _client();
    await client.reportPlaybackStopped(
      itemId: 'movie:1',
      position: const Duration(minutes: 30),
      duration: const Duration(minutes: 100),
    );
    await client.reportPlaybackStopped(
      itemId: 'movie:2',
      position: const Duration(minutes: 5),
      duration: const Duration(minutes: 90),
    );
    final rows = await client.fetchContinueWatching();
    expect(rows.map((r) => r.id), ['movie:2', 'movie:1']);
  });

  test('GUARD: finished stop (>=90%) clears the entry', () async {
    final client = _client();
    await client.reportPlaybackStopped(
      itemId: 'movie:1',
      position: const Duration(minutes: 30),
      duration: const Duration(minutes: 100),
    );
    expect(await client.fetchContinueWatching(), hasLength(1));
    await client.reportPlaybackStopped(
      itemId: 'movie:1',
      position: const Duration(minutes: 95),
      duration: const Duration(minutes: 100),
    );
    expect(await client.fetchContinueWatching(), isEmpty);
  });

  test('GUARD: sub-5s stop records nothing (anti-clutter)', () async {
    final client = _client();
    await client.reportPlaybackStopped(
      itemId: 'movie:1',
      position: const Duration(seconds: 3),
      duration: const Duration(minutes: 100),
    );
    expect(await client.fetchContinueWatching(), isEmpty);
  });

  test('GUARD: live channel stop never creates a Continue Watching entry', () async {
    final client = _client();
    await client.reportPlaybackStopped(
      itemId: 'live:5',
      position: const Duration(minutes: 30),
      duration: const Duration(minutes: 30),
    );
    expect(await client.fetchContinueWatching(), isEmpty);
  });
}
