// Build #25 (resume / Continue Watching for IPTV) — additional tests
// beyond the probe (25.6): update-not-duplicate, the 30-entry cap,
// count/exclusion honoring, snapshot fallback, removal, mark-watched,
// series on-deck, the record-side rules for Started/Progress, and
// per-connection isolation.
//
// Fake Xtream API only — no live panel. Fake credentials are concatenated
// below so the literal never appears in this file.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/playback_initialization_types.dart';

import '../../test_helpers/prefs.dart';

// Concatenated so the literal never appears in this file.
const _testPassword = 'pa' 'ss';

XtreamConnection _trexConnection({String id = 'trex'}) => XtreamConnection(
  id: id,
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

IptvClient _client({String connectionId = 'trex'}) {
  final client = IptvClient.forConnection(_trexConnection(id: connectionId));
  client.testXtreamApi = _FakeXtreamApi();
  return client;
}

Future<void> _stopMovie(IptvClient client, int streamId, {int atMinutes = 30, int durationMinutes = 100}) =>
    client.reportPlaybackStopped(
      itemId: 'movie:$streamId',
      position: Duration(minutes: atMinutes),
      duration: Duration(minutes: durationMinutes),
    );

void main() {
  setUp(resetSharedPreferencesForTest);

  test('a second stop on the same id updates the position instead of duplicating', () async {
    final client = _client();
    await _stopMovie(client, 1, atMinutes: 30);
    await _stopMovie(client, 1, atMinutes: 40);
    final rows = await client.fetchContinueWatching();
    expect(rows, hasLength(1));
    expect(rows.single.viewOffsetMs, 40 * 60 * 1000);
  });

  test('the 30-entry cap evicts the oldest on the 31st insert', () async {
    final client = _client();
    for (var i = 1; i <= 31; i++) {
      await _stopMovie(client, i);
    }
    final rows = await client.fetchContinueWatching(count: 31);
    expect(rows, hasLength(30));
    expect(rows.map((r) => r.id), isNot(contains('movie:1')));
    expect(rows.first.id, 'movie:31');
    expect(rows.last.id, 'movie:2');
  });

  test('fetchContinueWatching(count: 1) returns only the newest row', () async {
    final client = _client();
    await _stopMovie(client, 1);
    await _stopMovie(client, 2, atMinutes: 5, durationMinutes: 90);
    final rows = await client.fetchContinueWatching(count: 1);
    expect(rows.map((r) => r.id), ['movie:2']);
  });

  test('an entry for an item that left the catalog still renders from its snapshot', () async {
    final client = _client();
    await _stopMovie(client, 99);
    final rows = await client.fetchContinueWatching();
    expect(rows, hasLength(1));
    expect(rows.single.id, 'movie:99');
    expect(rows.single.viewOffsetMs, 30 * 60 * 1000);
    expect(rows.single.durationMs, 100 * 60 * 1000);
    expect(rows.single.hasActiveProgress, isTrue);
  });

  test('removeFromContinueWatching removes the entry', () async {
    final client = _client();
    await _stopMovie(client, 1);
    final rows = await client.fetchContinueWatching();
    expect(rows, hasLength(1));
    await client.removeFromContinueWatching(rows.single);
    expect(await client.fetchContinueWatching(), isEmpty);
  });

  test('markWatched clears the resume entry so the item leaves Continue Watching', () async {
    final client = _client();
    await _stopMovie(client, 1);
    final rows = await client.fetchContinueWatching();
    expect(rows, hasLength(1));
    await client.markWatched(rows.single);
    expect(await client.fetchContinueWatching(), isEmpty);
  });

  test('fetchItemWithOnDeck returns the latest-resumed episode for a series', () async {
    final client = _client();
    await client.reportPlaybackStopped(
      itemId: 'episode:10:100',
      position: const Duration(minutes: 10),
      duration: const Duration(minutes: 45),
    );
    final (item: series, onDeckEpisode: episode) = await client.fetchItemWithOnDeck('series:10');
    expect(series, isNotNull);
    expect(series!.id, 'series:10');
    expect(episode, isNotNull);
    expect(episode!.id, 'episode:10:100');
    expect(episode.viewOffsetMs, 10 * 60 * 1000);
  });

  test('fetchItemWithOnDeck has no on-deck episode when nothing was resumed', () async {
    final client = _client();
    final (item: series, onDeckEpisode: episode) = await client.fetchItemWithOnDeck('series:10');
    expect(series, isNotNull);
    expect(episode, isNull);
  });

  test('reportPlaybackStarted at 0 records nothing', () async {
    final client = _client();
    await client.reportPlaybackStarted(itemId: 'movie:1', position: Duration.zero);
    expect(await client.fetchContinueWatching(), isEmpty);
  });

  test('reportPlaybackProgress records from 6s on', () async {
    final client = _client();
    await client.reportPlaybackProgress(
      itemId: 'movie:1',
      position: const Duration(seconds: 6),
      duration: const Duration(minutes: 100),
    );
    final rows = await client.fetchContinueWatching();
    expect(rows, hasLength(1));
    expect(rows.single.viewOffsetMs, 6000);
  });

  test('a report without a usable duration records nothing', () async {
    final client = _client();
    await client.reportPlaybackStarted(
      itemId: 'movie:1',
      position: const Duration(minutes: 10),
    );
    await client.reportPlaybackProgress(
      itemId: 'movie:2',
      position: const Duration(minutes: 10),
      duration: Duration.zero,
    );
    expect(await client.fetchContinueWatching(), isEmpty);
  });

  test('fetchContinueWatching honors excludedLibraryIds', () async {
    final client = _client();
    await _stopMovie(client, 1);
    final rows = await client.fetchContinueWatching();
    expect(rows, hasLength(1));
    final libraryId = rows.single.libraryId;
    expect(libraryId, isNotNull);
    expect(await client.fetchContinueWatching(excludedLibraryIds: {libraryId!}), isEmpty);
    expect(await client.fetchContinueWatching(excludedLibraryIds: {'some-other-library'}), hasLength(1));
  });

  test('resume rows are per-connection: a second line sees none of the first', () async {
    final first = _client(connectionId: 'trex');
    final second = _client(connectionId: 'trex2');
    await _stopMovie(first, 1);
    expect(await second.fetchContinueWatching(), isEmpty);
    expect(await first.fetchContinueWatching(), hasLength(1));
  });

  test('fetchItem stamps the episode position from the store', () async {
    final client = _client();
    await client.reportPlaybackStopped(
      itemId: 'episode:10:100',
      position: const Duration(minutes: 10),
      duration: const Duration(minutes: 45),
    );
    final item = await client.fetchItem('episode:10:100');
    expect(item, isNotNull);
    expect(item!.viewOffsetMs, 10 * 60 * 1000);
    expect(item.durationMs, 45 * 60 * 1000);
  });

  test('opening playback stashes the title so the snapshot carries it', () async {
    final client = _client();
    final item = await client.fetchItem('movie:1');
    expect(item, isNotNull);
    await client.getPlaybackInitialization(
      PlaybackInitializationOptions(metadata: item!, selectedMediaIndex: 0),
    );
    await _stopMovie(client, 1);
    final rows = await client.fetchContinueWatching();
    expect(rows, hasLength(1));
    expect(rows.single.title, 'Alpha Movie');
  });
}
