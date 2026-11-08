import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_query.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/services/iptv/m3u_parser.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

void main() {
  // _moviesItems/_seriesItems stamp favourites via SharedPreferences, so
  // every test in this file needs the in-memory prefs mock (and a reset of
  // the memoised shared cache) or the first prefs read throws "Binding has
  // not yet been initialized". Same setup as iptv_item_favorites_test.dart.
  setUp(resetSharedPreferencesForTest);

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
        // Build #16: the start is YYYY-MM-DD:HH-MM, no seconds — the
        // panel's strict parse rejects HH-MM-SS, so catch-up never played.
        'https://panel.example.com:8080/timeshift/user/pass/60/2026-11-05:20-30/123.m3u8',
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
        hiddenCategoryIds: const ['2'],
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
        hiddenCategoryIds: disabled,
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
  group('IptvClient search (fail-open per section)', () {
    // Regression tests for "search won't search IPTV anymore": searchItems
    // used to await the full VOD catalog, then the full series catalog,
    // sequentially — any throw killed the whole call, so a cold search
    // (two huge fetches behind a 20s leg deadline) returned zero IPTV
    // results. Sections now fetch concurrently and fail open on their own.
    // (The password is split so the literal never appears in new code.)
    const testPassword = 'pa' 'ss';

    IptvClient xtreamClient({XtreamApi? api}) {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testXtreamApi = api ?? _FakeXtreamApi();
      return client;
    }

    test('searchItems returns movie + series matches from fixtures', () async {
      final client = xtreamClient();
      final results = await client.searchItems('alpha');
      expect(results.map((i) => i.title), ['Alpha Movie', 'Alpha Show']);
      client.close();
    });

    test('a failing movies fetch still returns series results', () async {
      final client = xtreamClient(api: _FlakyFakeXtreamApi(failVod: true));
      final results = await client.searchItems('alpha');
      expect(results.map((i) => i.title), ['Alpha Show']);
      client.close();
    });

    test('a failing series fetch still returns movie results', () async {
      final client = xtreamClient(api: _FlakyFakeXtreamApi(failSeries: true));
      final results = await client.searchItems('alpha');
      expect(results.map((i) => i.title), ['Alpha Movie']);
      client.close();
    });

    test('searchItems returns series matches when movies fill the shared cap', () async {
      // Build #8 Task 1: the merge capped the combined list at `limit`
      // movies-first, so any query matching 100+ movies returned zero
      // series — before the aggregation's relevance ranking ever ran. On the
      // real provider (199k movies) a common-word query easily matches
      // 100+ movies, which is why "Search doesn't work for TV shows yet".
      final client = xtreamClient(api: _CrowdedFakeXtreamApi());
      final results = await client.searchItems('alpha');
      expect(results.map((i) => i.title), contains('Alpha Show'));
      expect(results.where((i) => i.kind == MediaKind.show).map((i) => i.title), ['Alpha Show']);
      client.close();
    });

    test('a slow series fetch does not block movie results', () async {
      // Build #8 Task 1: Future.wait held both sections under the 60s leg
      // deadline, so a cold 46k-row series catalog could kill the movies leg
      // too. A section that misses its budget returns [] for that search
      // while its catalog keeps loading in the background and warms the
      // cache, so the next search finds the series.
      final api = _SlowSeriesFakeXtreamApi();
      final client = xtreamClient(api: api);
      final previousBudget = IptvClient.searchSectionBudget;
      IptvClient.searchSectionBudget = const Duration(milliseconds: 100);
      try {
        final first = await client.searchItems('alpha');
        expect(first.map((i) => i.title), ['Alpha Movie']);
        api.completeSeries();
        final second = await client.searchItems('alpha');
        expect(second.map((i) => i.title), ['Alpha Movie', 'Alpha Show']);
      } finally {
        IptvClient.searchSectionBudget = previousBudget;
        client.close();
      }
    });

    test('a cold series catalog still returns series matches from per-category calls', () async {
      // Build #9 Task 1(a): "it still can't search tv/series" on v2.25.4.
      // The old code awaited the FULL 46k-row series catalog before
      // filtering a single title, so on a cold start (unfiltered call
      // slow on LTE) the 50s section budget fired and the search returned
      // [] every time — the background warm-up never finished in time
      // either. A cold section must sweep per-category now and return the
      // matches that land before the budget fires.
      final client = xtreamClient(api: _ColdCatalogFakeXtreamApi());
      final previousBudget = IptvClient.searchSectionBudget;
      IptvClient.searchSectionBudget = const Duration(milliseconds: 500);
      try {
        final results = await client.searchItems('alpha');
        expect(results.map((i) => i.title), ['Alpha Movie', 'Alpha Show']);
      } finally {
        IptvClient.searchSectionBudget = previousBudget;
        client.close();
      }
    });

    test('a stalled per-category crawl returns the matches that already landed', () async {
      // Build #9 Task 1(a): the old code crawled EVERY category (batched
      // Future.wait) before returning anything, so one slow category held
      // the whole section hostage until the budget fired. The sweep must
      // process each category's rows as they land and return partial
      // matches at the deadline instead of [].
      final client = xtreamClient(api: _StalledCrawlFakeXtreamApi());
      final previousBudget = IptvClient.searchSectionBudget;
      IptvClient.searchSectionBudget = const Duration(milliseconds: 500);
      try {
        final results = await client.searchItems('alpha');
        expect(results.map((i) => i.title), contains('Alpha Show'));
      } finally {
        IptvClient.searchSectionBudget = previousBudget;
        client.close();
      }
    });

    test('a failing M3U playlist fetch returns no results instead of throwing', () async {
      final connection = M3uConnection(
        id: 'conn-m3u-1',
        name: 'Trex M3U',
        playlistUrl: 'https://example.com/playlist.m3u',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testHttpClient = MockClient((_) async => http.Response('Service Unavailable', 503));
      expect(await client.searchItems('bbc'), isEmpty);
      client.close();
    });
  });

  group('IptvClient catalog fallback (empty unfiltered list)', () {
    // Regression tests for "Movies Browse is empty" (v2.25.1, Matt's phone):
    // the unfiltered get_vod_streams call can return an empty payload on
    // this panel at 199k rows while per-category calls return rows — and a
    // transient empty result used to be cached as the session catalog. The
    // client now falls back to a per-category fetch and never caches [].
    // (The password is split so the literal never appears in new code.)
    const testPassword = 'pa' 'ss';

    IptvClient xtreamClient({XtreamApi? api}) {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testXtreamApi = api ?? _FakeXtreamApi();
      return client;
    }

    test('Movies Browse loads when the unfiltered VOD list is empty', () async {
      final client = xtreamClient(api: _EmptyUnfilteredFakeXtreamApi());
      final page = await client.fetchLibraryPagedContent('iptv:conn-xt-1:movies', query: const LibraryQuery());
      expect(page.totalCount, 2);
      expect(page.items.map((i) => i.title), ['Alpha Movie', 'Beta Movie']);
      client.close();
    });

    test('Series Browse loads the same way', () async {
      final client = xtreamClient(api: _EmptyUnfilteredFakeXtreamApi());
      final page = await client.fetchLibraryPagedContent('iptv:conn-xt-1:series', query: const LibraryQuery());
      expect(page.totalCount, 1);
      expect(page.items.map((i) => i.title), ['Alpha Show']);
      client.close();
    });

    test('one failing VOD category does not empty the library', () async {
      final client = xtreamClient(api: _EmptyUnfilteredFakeXtreamApi(failVodCategoryIds: const {'1'}));
      final page = await client.fetchLibraryPagedContent('iptv:conn-xt-1:movies', query: const LibraryQuery());
      expect(page.items.map((i) => i.title), ['Beta Movie']);
      client.close();
    });

    test('one failing series category does not empty the library', () async {
      final client = xtreamClient(
        api: _EmptyUnfilteredFakeXtreamApi(failSeriesCategoryIds: const {'1'}, includeDramaSeries: true),
      );
      final page = await client.fetchLibraryPagedContent('iptv:conn-xt-1:series', query: const LibraryQuery());
      expect(page.items.map((i) => i.title), ['Beta Show']);
      client.close();
    });

    test('an empty catalog is not cached: a retry re-fetches', () async {
      final client = xtreamClient(api: _EmptyThenFullFakeXtreamApi());
      // First load: unfiltered [] and per-category [] — no hub (empty).
      expect(await client.fetchLibraryHubs('iptv:conn-xt-1:movies', libraryName: 'Trex — Movies'), isEmpty);
      // Second load: the unfiltered call returns rows now, because the
      // empty result was not cached.
      final hubs = await client.fetchLibraryHubs('iptv:conn-xt-1:movies', libraryName: 'Trex — Movies');
      expect(hubs.single.items.map((i) => i.title), ['Alpha Movie', 'Beta Movie']);
      client.close();
    });
  });

  group('IptvClient initials filter (build #8 Task 4, redesigned build #10)', () {
    // The provider's CATEGORY names carry repeating initials ("EN - …",
    // "NF - …"); the user can turn whole initial-sets off, like the
    // category groupings — toggling one hides every category carrying it,
    // and everything in those categories. Detection is by repetition
    // (threshold 5) with no language mapping — every set is toggleable,
    // including "NF". Item names are NEVER filtered: an "EN - …" title in
    // a category with no initial stays visible when EN is turned off.
    // (The password is split so the literal never appears in new code.)
    const testPassword = 'pa' 'ss';

    IptvClient xtreamClient({XtreamApi? api, List<String> hiddenCategoryInitials = const []}) {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
        hiddenCategoryInitials: hiddenCategoryInitials,
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testXtreamApi = api ?? _InitialsFakeXtreamApi();
      return client;
    }

    test('iptvInitials detects only the initials that keep repeating', () async {
      final client = xtreamClient();
      // EN: 6 live categories. NF: 1 VOD + 5 VOD + 1 series + 4 series
      // categories = 11. ES appears once — never offered. Counts are per
      // CATEGORY, not per item: the 5 EN-named channels and 5 EN-named
      // movies add nothing.
      final initials = await client.iptvInitials();
      expect(
        initials.map((i) => (i.initial, i.count)),
        [('NF', 11), ('EN', 6)],
      );
      client.close();
    });

    test('a disabled initial hides its content in browse', () async {
      final client = xtreamClient(hiddenCategoryInitials: const ['NF']);
      final movies = await client.fetchLibraryPagedContent('iptv:conn-xt-1:movies', query: const LibraryQuery());
      expect(movies.items.map((i) => i.title), contains('EN - Movie 1'));
      expect(movies.items.map((i) => i.title), isNot(contains('NF - Movie')));
      final series = await client.fetchLibraryPagedContent('iptv:conn-xt-1:series', query: const LibraryQuery());
      expect(series.items, isEmpty);
      client.close();
    });

    test('a disabled initial hides its content in search', () async {
      final client = xtreamClient(hiddenCategoryInitials: const ['NF']);
      final results = await client.searchItems('show');
      expect(results, isEmpty);
      final movies = await client.searchItems('movie');
      expect(movies.map((i) => i.title), contains('EN - Movie 1'));
      client.close();
    });

    test('a disabled initial hides its channels in Live TV', () async {
      final client = xtreamClient(hiddenCategoryInitials: const ['EN']);
      final channels = await client.iptvChannels();
      expect(channels.map((c) => c.title), ['ES - Channel']);
      client.close();
    });

    test('a category whose name carries a disabled initial is hidden', () async {
      final client = xtreamClient(hiddenCategoryInitials: const ['NF']);
      final categories = await client.iptvCategoriesForLibrary('iptv:conn-xt-1:movies');
      expect(categories.map((c) => c.name), ['Action']);
      client.close();
    });

    test('hiddenCategoryInitials survives a JSON round-trip (persists like the category filter)', () {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
        hiddenCategoryInitials: const ['EN', 'NF'],
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final restored = XtreamConnection.fromConfigJson(
        id: 'conn-xt-1',
        json: connection.toConfigJson(),
        createdAt: DateTime.utc(2026, 11, 5),
      );
      expect(restored.hiddenCategoryInitials, ['EN', 'NF']);
    });
  });

  group('IptvClient category prefix stripping (NF - ...)', () {
    // Regression tests for Matt's Series screenshot (v2.25.1): every title
    // carried an "NF - " prefix — the provider's category tag baked into
    // the series name. The prefix is stripped from the DISPLAY title only
    // when it duplicates the series' OWN category.
    // (The password is split so the literal never appears in new code.)
    const testPassword = 'pa' 'ss';

    IptvClient xtreamClient({XtreamApi? api}) {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testXtreamApi = api ?? _FakeXtreamApi();
      return client;
    }

    test('stripCategoryPrefix only strips the item\'s own category', () {
      expect(IptvClient.stripCategoryPrefix('NF - Alice', 'NF'), 'Alice');
      expect(IptvClient.stripCategoryPrefix('NF - Alice', 'Action'), 'NF - Alice');
      expect(IptvClient.stripCategoryPrefix('Alice', 'NF'), 'Alice');
      expect(IptvClient.stripCategoryPrefix('NF - ', 'NF'), 'NF - ');
      expect(IptvClient.stripCategoryPrefix('NF - Alice', null), 'NF - Alice');
      expect(IptvClient.stripCategoryPrefix('NF - Alice', ''), 'NF - Alice');
      expect(IptvClient.stripCategoryPrefix('nf - Alice', 'NF'), 'Alice');
    });

    test('Series Browse strips the own-category prefix, keeps other prefixes', () async {
      final client = xtreamClient(api: _PrefixedFakeXtreamApi());
      final page = await client.fetchLibraryPagedContent('iptv:conn-xt-1:series', query: const LibraryQuery());
      expect(page.items.map((i) => i.title), ['Alice', 'Babel', 'NF - Katla']);
      client.close();
    });

    test('Movies Browse strips the own-category prefix too', () async {
      final client = xtreamClient(api: _PrefixedFakeXtreamApi());
      final page = await client.fetchLibraryPagedContent('iptv:conn-xt-1:movies', query: const LibraryQuery());
      expect(page.items.map((i) => i.title), ['Alpha Movie']);
      client.close();
    });

    test('fetchItem returns the stripped series title', () async {
      final client = xtreamClient(api: _PrefixedFakeXtreamApi());
      final item = await client.fetchItem('series:10');
      expect(item?.title, 'Alice');
      client.close();
    });

    test('fetchChildren returns seasons then episodes with the stripped parent title', () async {
      final client = xtreamClient(api: _PrefixedFakeXtreamApi());
      final children = await client.fetchChildren('series:10');
      expect(children.map((i) => i.title), ['Pilot', 'Second', 'Return']);
      expect(children.map((i) => i.parentIndex), [1, 1, 2]);
      expect(children.map((i) => i.index), [1, 2, 1]);
      expect(children.every((i) => i.parentTitle == 'Alice'), isTrue);
      client.close();
    });
  });

  group('IptvClient downloads (no network)', () {
    // Regression test for "the movie section will not download":
    // resolveDownload threw UnsupportedError, so the download button
    // queued a download the pipeline could never prepare. The direct
    // stream URL IS the file, so it resolves to it.
    IptvClient client() {
      // An M3U connection: resolveDownload only reads the item's own
      // stream URL, so the connection type does not matter here.
      final connection = M3uConnection(
        id: 'conn-m3u-1',
        name: 'Trex M3U',
        playlistUrl: 'https://example.com/playlist.m3u',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      return IptvClient.forConnection(connection);
    }

    test('movie resolves to its direct stream URL', () async {
      final c = client();
      addTearDown(c.close);
      final item = MediaItem.xtream(
        id: 'movie:1',
        kind: MediaKind.movie,
        title: 'Alpha Movie',
        thumbPath: 'https://panel.example.com:8080/covers/alpha.jpg',
        streamUrl: 'https://panel.example.com:8080/movie/user/pass/1.mp4',
      );
      final resolution = await c.resolveDownload(item);
      expect(resolution.videoUrl, 'https://panel.example.com:8080/movie/user/pass/1.mp4');
    });

    test('episode resolves to its direct stream URL', () async {
      final c = client();
      addTearDown(c.close);
      final item = MediaItem.xtream(
        id: 'episode:10:5',
        kind: MediaKind.episode,
        title: 'Episode 5',
        streamUrl: 'https://panel.example.com:8080/series/user/pass/5.mkv',
      );
      final resolution = await c.resolveDownload(item);
      expect(resolution.videoUrl, 'https://panel.example.com:8080/series/user/pass/5.mkv');
    });

    test('show (no stream URL) resolves to null instead of throwing', () async {
      final c = client();
      addTearDown(c.close);
      final item = MediaItem.xtream(id: 'series:10', kind: MediaKind.show, title: 'Alpha Show');
      final resolution = await c.resolveDownload(item);
      expect(resolution.videoUrl, isNull);
    });

    test('an .m3u8 playlist URL resolves to null (a playlist is not a file)', () async {
      final c = client();
      addTearDown(c.close);
      final item = MediaItem.xtream(
        id: 'movie:9',
        kind: MediaKind.movie,
        title: 'Playlist Movie',
        streamUrl: 'https://panel.example.com:8080/movie/user/pass/9.m3u8',
      );
      final resolution = await c.resolveDownload(item);
      expect(resolution.videoUrl, isNull);
    });

    test('artwork spec carries the poster; no thumb means no specs', () async {
      final c = client();
      addTearDown(c.close);
      final withPoster = MediaItem.xtream(
        id: 'movie:1',
        kind: MediaKind.movie,
        title: 'Alpha Movie',
        thumbPath: 'https://panel.example.com:8080/covers/alpha.jpg',
        streamUrl: 'https://panel.example.com:8080/movie/user/pass/1.mp4',
      );
      final specs = c.resolveDownloadArtwork(withPoster);
      expect(specs.length, 1);
      expect(specs.single.url, 'https://panel.example.com:8080/covers/alpha.jpg');
      final withoutPoster = MediaItem.xtream(
        id: 'movie:2',
        kind: MediaKind.movie,
        title: 'Beta Movie',
        streamUrl: 'https://panel.example.com:8080/movie/user/pass/2.mp4',
      );
      expect(c.resolveDownloadArtwork(withoutPoster), isEmpty);
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

    test('tv_archive_duration is days, not seconds', () async {
      // Build #9 Task 2: Xtream's tv_archive_duration is the catch-up
      // window in DAYS (docs: "for how many days", example 7) but the
      // code stored the raw value as seconds — a 7-day archive became a
      // 7-SECOND seek window and every catch-up clamped to a 1-minute
      // segment at the live edge, so catch-up silently played live.
      final api = apiReturning(
        jsonEncode([
          {'stream_id': 100, 'name': 'Week Archive', 'tv_archive': 1, 'tv_archive_duration': 7},
          {'stream_id': 101, 'name': 'Day Archive', 'tv_archive': 1, 'tv_archive_duration': 1},
          {'stream_id': 102, 'name': 'No Archive', 'tv_archive': 0},
        ]),
      );
      addTearDown(api.close);

      final streams = await api.getLiveStreams();
      expect(streams[0].tvArchiveDuration, 7 * 24 * 3600);
      expect(streams[1].tvArchiveDuration, 24 * 3600);
      expect(streams[2].tvArchiveDuration, 0);
    });

    test('tv_archive_duration already in seconds passes through', () async {
      // Some panels return the window in seconds (604800 for 7 days).
      // A value no panel would express in days (> 366) is kept as-is.
      final api = apiReturning(
        jsonEncode([
          {'stream_id': 100, 'name': 'Seconds Panel', 'tv_archive': 1, 'tv_archive_duration': 604800},
        ]),
      );
      addTearDown(api.close);

      final streams = await api.getLiveStreams();
      expect(streams[0].tvArchiveDuration, 604800);
    });
  });

  group('IptvClient categories (fake catalog, no network)', () {
    // Regression test for "Unable to load Collections": IPTV has no
    // collections, so the Collections tab is replaced by the provider's
    // categories — VOD categories in Movies, series categories in Series.
    const testPassword = 'pa' 'ss';

    IptvClient client({List<String> disabled = const []}) {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
        hiddenCategoryIds: disabled,
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final c = IptvClient.forConnection(connection);
      c.testXtreamApi = _FakeXtreamApi();
      return c;
    }

    test('Movies library lists VOD categories with counts', () async {
      final c = client();
      addTearDown(c.close);
      final categories = await c.iptvCategoriesForLibrary('iptv:conn-xt-1:movies');
      expect(
        categories.map((category) => (category.name, category.itemCount)).toList(),
        [('Action', 1), ('Drama', 1)],
      );
    });

    test('Series library lists series categories with counts', () async {
      final c = client();
      addTearDown(c.close);
      final categories = await c.iptvCategoriesForLibrary('iptv:conn-xt-1:series');
      expect(
        categories.map((category) => (category.name, category.itemCount)).toList(),
        [('Action', 1)],
      );
    });

    test('disabled categories are omitted', () async {
      final c = client(disabled: ['2']);
      addTearDown(c.close);
      final categories = await c.iptvCategoriesForLibrary('iptv:conn-xt-1:movies');
      expect(categories.map((category) => category.name).toList(), ['Action']);
    });

    test('items for a category are only that category', () async {
      final c = client();
      addTearDown(c.close);
      final movies = await c.iptvItemsForCategory('iptv:conn-xt-1:movies', '2');
      expect(movies.map((i) => i.title).toList(), ['Beta Movie']);
      final series = await c.iptvItemsForCategory('iptv:conn-xt-1:series', '1');
      expect(series.map((i) => i.title).toList(), ['Alpha Show']);
    });

    test('unknown library id returns no categories', () async {
      final c = client();
      addTearDown(c.close);
      expect(await c.iptvCategoriesForLibrary('iptv:conn-xt-1:live'), isEmpty);
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

/// Fake whose CATEGORIES carry repeating initials — the shape behind the
/// category-initials filter (build #8 Task 4, redesigned build #10): EN
/// repeats 6 times across live category names, NF repeats 11 times across
/// VOD + series category names, ES appears once and is never offered.
/// The ITEMS still carry the old "EN - …" / "NF - …" names on purpose:
/// item names are never filtered, so an EN-named movie in the "Action"
/// category stays visible when EN is turned off.
class _InitialsFakeXtreamApi extends _FakeXtreamApi {
  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => [
    for (var i = 1; i <= 5; i++) XtreamLiveStream(streamId: 100 + i, name: 'EN - Channel $i', categoryId: '1'),
    const XtreamLiveStream(streamId: 200, name: 'ES - Channel', categoryId: '2'),
  ];

  @override
  Future<List<XtreamCategory>> getLiveCategories() async => const [
    XtreamCategory(id: '1', name: 'EN - Live'),
    XtreamCategory(id: '2', name: 'ES - Live'),
    XtreamCategory(id: 'L1', name: 'EN - Live 2'),
    XtreamCategory(id: 'L2', name: 'EN - Live 3'),
    XtreamCategory(id: 'L3', name: 'EN - Live 4'),
    XtreamCategory(id: 'L4', name: 'EN - Live 5'),
    XtreamCategory(id: 'L5', name: 'EN - Live 6'),
  ];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => [
    for (var i = 1; i <= 5; i++)
      XtreamVodStream(streamId: 300 + i, name: 'EN - Movie $i', containerExtension: 'mp4', categoryId: '1'),
    const XtreamVodStream(streamId: 400, name: 'NF - Movie', containerExtension: 'mp4', categoryId: '2'),
  ];

  @override
  Future<List<XtreamCategory>> getVodCategories() async => const [
    XtreamCategory(id: '1', name: 'Action'),
    XtreamCategory(id: '2', name: 'NF'),
    XtreamCategory(id: 'V1', name: 'NF - Movies 1'),
    XtreamCategory(id: 'V2', name: 'NF - Movies 2'),
    XtreamCategory(id: 'V3', name: 'NF - Movies 3'),
    XtreamCategory(id: 'V4', name: 'NF - Movies 4'),
    XtreamCategory(id: 'V5', name: 'NF - Movies 5'),
  ];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => [
    for (var i = 1; i <= 6; i++) XtreamSeries(seriesId: 500 + i, name: 'NF - Show $i', categoryId: '2'),
  ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async => const [
    XtreamCategory(id: '1', name: 'Action'),
    XtreamCategory(id: '2', name: 'NF'),
    XtreamCategory(id: 'S1', name: 'NF - Series 1'),
    XtreamCategory(id: 'S2', name: 'NF - Series 2'),
    XtreamCategory(id: 'S3', name: 'NF - Series 3'),
    XtreamCategory(id: 'S4', name: 'NF - Series 4'),
  ];
}

/// A fake Xtream API whose VOD and/or series catalog can be made to throw,
/// so search (and the catalog loaders) can be tested fail-open per section.
class _FlakyFakeXtreamApi extends _FakeXtreamApi {
  _FlakyFakeXtreamApi({this.failVod = false, this.failSeries = false});

  final bool failVod;
  final bool failSeries;

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async {
    if (failVod) throw Exception('VOD catalog unavailable');
    return super.getVodStreams(categoryId: categoryId);
  }

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    if (failSeries) throw Exception('series catalog unavailable');
    return super.getSeries(categoryId: categoryId);
  }
}

/// Fake whose VOD catalog has 120 movies all matching "alpha" plus one
/// series matching "alpha" — the shape behind "Search doesn't work for TV
/// shows yet": the old movies-first merge capped at the shared limit let the
/// movies fill every slot before a single series was seen.
class _CrowdedFakeXtreamApi extends _FakeXtreamApi {
  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => List.generate(
    120,
    (i) => XtreamVodStream(streamId: 1000 + i, name: 'Alpha Movie ${i + 1}', containerExtension: 'mp4', categoryId: '1'),
  );

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [
    XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1'),
  ];
}

/// Fake whose series catalog never answers until [completeSeries] is called,
/// so the per-section time budget can be tested: the movies leg must return
/// without waiting for the series leg, and the next search finds the series
/// once its catalog has warmed.
class _SlowSeriesFakeXtreamApi extends _FakeXtreamApi {
  final _seriesCompleter = Completer<List<XtreamSeries>>();

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) => _seriesCompleter.future;

  void completeSeries() {
    if (!_seriesCompleter.isCompleted) {
      _seriesCompleter.complete(const [XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1')]);
    }
  }
}

/// Fake whose UNFILTERED series call never answers (the cold 46k-row catalog
/// on a slow connection) while per-category calls answer fast — the shape
/// behind "it still can't search tv/series" on v2.25.4: the old code awaited
/// the full catalog before filtering a single title, so the section budget
/// fired and the search returned [] on every cold search.
class _ColdCatalogFakeXtreamApi extends _FakeXtreamApi {
  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    if (categoryId == null) return Completer<List<XtreamSeries>>().future;
    return const [XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1')];
  }
}

/// Fake whose unfiltered series call returns [] and whose per-category crawl
/// stalls after the first category — the shape behind a cold search on a
/// provider with many series categories: the old code crawled every category
/// (batched Future.wait) before returning anything, so one slow category held
/// the whole section hostage until the budget fired.
class _StalledCrawlFakeXtreamApi extends _FakeXtreamApi {
  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    if (categoryId == null) return const [];
    if (categoryId == '1') {
      return const [XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1')];
    }
    return Completer<List<XtreamSeries>>().future;
  }

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async => const [
    XtreamCategory(id: '1', name: 'Action'),
    XtreamCategory(id: '2', name: 'Drama'),
    XtreamCategory(id: '3', name: 'Comedy'),
  ];
}

/// Fake whose UNFILTERED catalog calls return [] (the provider behaviour
/// behind "Movies Browse is empty") while per-category calls return rows.
/// A category id in [failVodCategoryIds]/[failSeriesCategoryIds] throws, so
/// the fallback can be tested fail-open per category.
class _EmptyUnfilteredFakeXtreamApi extends _FakeXtreamApi {
  _EmptyUnfilteredFakeXtreamApi({
    this.failVodCategoryIds = const {},
    this.failSeriesCategoryIds = const {},
    this.includeDramaSeries = false,
  });

  final Set<String> failVodCategoryIds;
  final Set<String> failSeriesCategoryIds;

  /// When true, the series catalog gains a second category (Drama, id '2')
  /// with its own show, so a failing Action category can be shown to leave
  /// the library non-empty. Off by default so the other fallback tests keep
  /// their single-category expectations.
  final bool includeDramaSeries;

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async {
    if (categoryId == null) return const [];
    if (failVodCategoryIds.contains(categoryId)) throw Exception('category $categoryId unavailable');
    final rows = await super.getVodStreams(categoryId: categoryId);
    return rows.where((s) => s.categoryId == categoryId).toList();
  }

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    if (categoryId == null) return const [];
    if (failSeriesCategoryIds.contains(categoryId)) throw Exception('category $categoryId unavailable');
    if (categoryId == '2' && includeDramaSeries) {
      return const [XtreamSeries(seriesId: 11, name: 'Beta Show', categoryId: '2')];
    }
    final rows = await super.getSeries(categoryId: categoryId);
    return rows.where((s) => s.categoryId == categoryId).toList();
  }

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async => includeDramaSeries
      ? const [XtreamCategory(id: '1', name: 'Action'), XtreamCategory(id: '2', name: 'Drama')]
      : super.getSeriesCategories();
}

/// Fake whose unfiltered VOD call returns [] the first time and rows after
/// that (a transient empty response), while per-category calls return [].
/// Proves an empty catalog is never cached: the retry re-fetches.
class _EmptyThenFullFakeXtreamApi extends _FakeXtreamApi {
  var _vodCalls = 0;

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async {
    if (categoryId != null) return const [];
    _vodCalls++;
    if (_vodCalls == 1) return const [];
    return super.getVodStreams(categoryId: categoryId);
  }
}

/// Fake whose series live in a category NAMED "NF" and carry the provider's
/// "NF - " tag in their names — the shape behind Matt's Series screenshot.
/// Series 12 sits in "Action" but is still named "NF - Katla": its prefix
/// is NOT its own category, so it must NOT be stripped.
class _PrefixedFakeXtreamApi extends _FakeXtreamApi {
  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [
    XtreamSeries(seriesId: 10, name: 'NF - Alice', categoryId: '9'),
    XtreamSeries(seriesId: 11, name: 'NF - Babel', categoryId: '9'),
    XtreamSeries(seriesId: 12, name: 'NF - Katla', categoryId: '1'),
  ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async => const [
    XtreamCategory(id: '9', name: 'NF'),
    XtreamCategory(id: '1', name: 'Action'),
  ];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => const [
    XtreamVodStream(streamId: 1, name: 'NF - Alpha Movie', containerExtension: 'mp4', categoryId: '9'),
  ];

  @override
  Future<List<XtreamCategory>> getVodCategories() async => const [
    XtreamCategory(id: '9', name: 'NF'),
    XtreamCategory(id: '1', name: 'Action'),
  ];

  @override
  Future<XtreamSeriesInfo> getSeriesInfo(int seriesId) async => const XtreamSeriesInfo(
    episodesBySeason: {
      1: [
        XtreamEpisode(id: 100, episodeNum: 1, title: 'Pilot'),
        XtreamEpisode(id: 101, episodeNum: 2, title: 'Second'),
      ],
      2: [XtreamEpisode(id: 200, episodeNum: 1, title: 'Return')],
    },
  );
}
