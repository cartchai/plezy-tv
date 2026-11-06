import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/m3u_parser.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

void main() {
  group('M3U parser', () {
    test('parses EXTINF attributes and pairs the following URL', () {
      const playlist = '''
#EXTM3U
#EXTINF:-1 tvg-id="BBC.One" tvg-logo="https://example.com/bbc.png" group-title="UK" catchup-source="https://example.com/catchup",BBC One
https://example.com/bbc.m3u8
#EXTINF:-1 tvg-id="CNN" group-title="US",CNN
https://example.com/cnn.ts
#EXTGRP:UK
''';
      final entries = parseM3u(playlist);
      expect(entries.length, 2);
      expect(entries[0].name, 'BBC One');
      expect(entries[0].tvgId, 'BBC.One');
      expect(entries[0].tvgLogo, 'https://example.com/bbc.png');
      expect(entries[0].groupTitle, 'UK');
      expect(entries[0].catchupSource, 'https://example.com/catchup');
      expect(entries[0].url, 'https://example.com/bbc.m3u8');
      expect(entries[1].name, 'CNN');
      expect(entries[1].tvgId, 'CNN');
      expect(entries[1].groupTitle, 'US');
    });

    test('bare URL without EXTINF falls back to the last path segment as name', () {
      final entries = parseM3u('https://example.com/only.ts\n');
      expect(entries.length, 1);
      expect(entries[0].name, 'only.ts');
      expect(entries[0].tvgId, isNull);
    });

    test('entry without a following URL is dropped', () {
      final entries = parseM3u('#EXTINF:-1 tvg-id="X",No URL\n');
      expect(entries, isEmpty);
    });
  });

  group('Xtream URL builders', () {
    final api = XtreamApi(serverUrl: 'https://panel.example.com:8080/', username: 'user', password: 'pass');

    test('server URL trailing slash is trimmed', () {
      expect(api.serverUrl, 'https://panel.example.com:8080');
    });

    test('live/movie/series URLs', () {
      expect(api.liveStreamUrl('123'), 'https://panel.example.com:8080/live/user/pass/123.m3u8');
      expect(api.movieStreamUrl('456', 'mkv'), 'https://panel.example.com:8080/movie/user/pass/456.mkv');
      expect(api.movieStreamUrl('456', ''), 'https://panel.example.com:8080/movie/user/pass/456.mp4');
      expect(api.seriesStreamUrl('789', 'mp4'), 'https://panel.example.com:8080/series/user/pass/789.mp4');
    });

    test('timeshift URL shape', () {
      final start = DateTime.utc(2026, 11, 5, 20, 30, 0);
      expect(
        api.timeshiftUrl(streamId: '123', durationMinutes: 60, start: start),
        'https://panel.example.com:8080/timeshift/user/pass/60/2026-11-05:20-30-00/123.m3u8',
      );
    });

    test('EPG program Base64 titles decode', () {
      final program = XtreamEpgProgram.fromJson({
        'id': '1',
        'title': 'TmV3cyBUb25pZ2h0',
        'description': 'RXZlbmluZyBuZXdz',
        'start_timestamp': 1762380000,
        'stop_timestamp': 1762383600,
        'channel_id': 'BBC.One',
      });
      expect(program.title, 'News Tonight');
      expect(program.description, 'Evening news');
    });
  });

  group('IptvClient libraries (no network)', () {
    test('M3U exposes no libraries (live TV lives in the Live TV tab)', () async {
      final connection = M3uConnection(
        id: 'conn-m3u-1',
        name: 'Trex M3U',
        playlistUrl: 'https://example.com/playlist.m3u',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      final libraries = await client.fetchLibraries();
      expect(libraries, isEmpty);
      expect(client.backend.id, 'm3u');
      expect(client.liveTv.dvr, isNull);
      client.close();
    });

    test('Xtream exposes Movies + Series libraries, no Live TV library', () async {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      final libraries = await client.fetchLibraries();
      expect(libraries.map((l) => l.id), ['iptv:conn-xt-1:movies', 'iptv:conn-xt-1:series']);
      expect(client.backend.id, 'xtream');
      expect(client.capabilities.liveTv, isTrue);
      expect(client.capabilities.liveTvDvr, isFalse);
      expect(client.streamHeaders, isEmpty);
      expect(client.watchedThreshold, 0.9);
      client.close();
    });
  });

  group('IptvClient hubs (fake catalog, no network)', () {
    test('fetchLibraryHubs returns a non-empty Recommended hub for Movies', () async {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testXtreamApi = _FakeXtreamApi();
      final hubs = await client.fetchLibraryHubs('iptv:conn-xt-1:movies', libraryName: 'Trex — Movies');
      expect(hubs.length, 1);
      expect(hubs.single.title, 'Recommended');
      expect(hubs.single.items.map((i) => i.title), ['Alpha Movie', 'Beta Movie']);
      expect(hubs.single.more, isFalse);
      expect(hubs.single.libraryId, 'iptv:conn-xt-1:movies');
      client.close();
    });

    test('fetchLibraryHubs returns a non-empty Recommended hub for Series', () async {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testXtreamApi = _FakeXtreamApi();
      final hubs = await client.fetchLibraryHubs('iptv:conn-xt-1:series', libraryName: 'Trex — Series');
      expect(hubs.length, 1);
      expect(hubs.single.items.map((i) => i.title), ['Alpha Show']);
      client.close();
    });

    test('fetchLibraryHubs honours the disabled-category filter', () async {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        disabledCategoryIds: const ['2'],
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testXtreamApi = _FakeXtreamApi();
      final hubs = await client.fetchLibraryHubs('iptv:conn-xt-1:movies', libraryName: 'Trex — Movies');
      // 'Beta Movie' is in disabled category '2', so only 'Alpha Movie' remains.
      expect(hubs.single.items.map((i) => i.title), ['Alpha Movie']);
      client.close();
    });

    test('fetchGlobalHubs returns one hub per on-demand library', () async {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testXtreamApi = _FakeXtreamApi();
      final hubs = await client.fetchGlobalHubs();
      expect(hubs.map((h) => h.title), ['Trex — Movies', 'Trex — Series']);
      client.close();
    });

    test('fetchMoreHubItems expands a Recommended hub', () async {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testXtreamApi = _FakeXtreamApi();
      final hubs = await client.fetchLibraryHubs('iptv:conn-xt-1:movies', libraryName: 'Trex — Movies', limit: 1);
      expect(hubs.single.items.length, 1);
      expect(hubs.single.more, isTrue);
      final expanded = await client.fetchMoreHubItems(hubs.single.id);
      expect(expanded.map((i) => i.title), ['Alpha Movie', 'Beta Movie']);
      client.close();
    });
  });

  group('M3U category filter (fake HTTP, no network)', () {
    const playlist = '''
#EXTM3U
#EXTINF:-1 tvg-id="BBC.One" group-title="UK",BBC One
https://example.com/bbc.m3u8
#EXTINF:-1 tvg-id="CNN" group-title="US",CNN
https://example.com/cnn.m3u8
''';

    IptvClient clientWithPlaylist({List<String> disabled = const []}) {
      final connection = M3uConnection(
        id: 'conn-m3u-1',
        name: 'Trex M3U',
        playlistUrl: 'https://example.com/playlist.m3u',
        disabledCategoryIds: disabled,
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testHttpClient = MockClient((_) async => http.Response(playlist, 200));
      return client;
    }

    test('iptvChannels hides a disabled group', () async {
      final client = clientWithPlaylist(disabled: const ['US']);
      final channels = await client.iptvChannels();
      expect(channels.map((c) => c.title), ['BBC One']);
      client.close();
    });

    test('searchItems hides a disabled group', () async {
      final client = clientWithPlaylist(disabled: const ['US']);
      // 'CNN' matches 'nn' but sits in disabled group 'US'.
      expect(await client.searchItems('nn'), isEmpty);
      expect((await client.searchItems('bbc')).map((i) => i.title), ['BBC One']);
      client.close();
    });
  });
  group('Catalog parsing tolerates malformed rows', () {
    // Regression test for "Series doesn't load": the real provider's
    // get_series payload contains rows with mistyped fields (e.g. a numeric
    // `cover`). The old `.map(X.fromJson)` parse threw the whole 46k-row
    // list away on the first bad row, so Movies loaded and Series showed
    // nothing. Each row must parse independently now.
    XtreamApi apiReturning(String body) => XtreamApi(
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: 'pass',
      httpClient: MockClient((_) async => http.Response(body, 200)),
    );

    test('getSeries drops a mistyped row and keeps its siblings', () async {
      final api = apiReturning(
        jsonEncode([
          {'series_id': 10, 'name': 'Alpha Show', 'category_id': '1'},
          {'series_id': 11, 'name': 'Bad Cover', 'cover': 12345, 'category_id': '1'},
          {'series_id': 12, 'name': 'Beta Show', 'category_id': '1'},
        ]),
      );
      addTearDown(api.close);

      final series = await api.getSeries();
      expect(series.map((s) => s.name), ['Alpha Show', 'Beta Show']);
    });

    test('getVodStreams drops a mistyped row and keeps its siblings', () async {
      final api = apiReturning(
        jsonEncode([
          {'stream_id': 1, 'name': 'Alpha Movie', 'container_extension': 'mp4'},
          {'stream_id': 2, 'name': 'Bad Cover', 'cover': 7},
          {'stream_id': 3, 'name': 'Beta Movie', 'container_extension': 'mkv'},
        ]),
      );
      addTearDown(api.close);

      final streams = await api.getVodStreams();
      expect(streams.map((s) => s.name), ['Alpha Movie', 'Beta Movie']);
    });

    test('getLiveStreams drops a mistyped row and keeps its siblings', () async {
      final api = apiReturning(
        jsonEncode([
          {'stream_id': 100, 'name': 'Good Channel'},
          {'stream_id': 101, 'name': 'Bad Icon', 'stream_icon': 42},
          {'stream_id': 102, 'name': 'Other Channel'},
        ]),
      );
      addTearDown(api.close);

      final streams = await api.getLiveStreams();
      expect(streams.map((s) => s.name), ['Good Channel', 'Other Channel']);
    });
  });
}

/// Fake Xtream API returning a canned catalog (no network). The connection
/// still builds real stream URLs from the fake's server/credentials.
class _FakeXtreamApi extends XtreamApi {
  _FakeXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pass');

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => const [
    XtreamVodStream(streamId: 1, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: '1'),
    XtreamVodStream(streamId: 2, name: 'Beta Movie', containerExtension: 'mkv', categoryId: '2'),
  ];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [
    XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1'),
  ];

  @override
  Future<List<XtreamCategory>> getVodCategories() async =>
      const [XtreamCategory(id: '1', name: 'Action'), XtreamCategory(id: '2', name: 'Drama')];

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async => const [XtreamCategory(id: '1', name: 'Action')];
}
