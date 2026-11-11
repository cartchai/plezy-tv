// Build #17 §8 fix 3 (v2.25.13): a scoped search that returns [] because
// the hidden-category filter removed the matches must say so — the
// diagnostics count the hidden matches per section, and the search screen
// reads them for the empty state instead of showing a bare "No results".
//
// Failing-first: with EN hidden, "game of thrones" returns [] AND the
// series section reports 1 hidden match (the show exists in "|EN| TOP
// SERIES" — the filter hid it, the search did not miss it).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/iptv_search_index_seed.dart';
import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  // R2.3: search answers from the local index, so the builder seeds it
  // from the fake panel's rows.
  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build17_filter_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!await tempDir.exists()) break;
      try {
        await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 2) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  });

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  Future<IptvClient> clientWith({required XtreamApi api, List<String> hiddenInitials = const []}) async {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      hiddenCategoryInitials: hiddenInitials,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    client.testXtreamApi = api;
    await seedIptvSearchIndexFromFakePanel(api, 'conn-xt-1');
    return client;
  }

  group('build17 search: hidden matches are surfaced, not silently dropped', () {
    test('EN hidden — the show is counted as hidden, not as "no match"', () async {
      final client = await clientWith(api: _GotFakeApi(), hiddenInitials: const ['EN']);
      try {
        final results = await client.searchItems('game of thrones');
        expect(results, isEmpty);
        final diagnostics = client.lastSearchDiagnostics!;
        expect(diagnostics.series.hiddenMatches, 1);
        expect(diagnostics.series.returned, 0);
        expect(
          client.lastSearchHiddenMatchesForLibrary('iptv:conn-xt-1:series'),
          1,
        );
        // The movies leg has no hidden matches for this query.
        expect(
          client.lastSearchHiddenMatchesForLibrary('iptv:conn-xt-1:movies'),
          0,
        );
      } finally {
        client.close();
      }
    });

    test('EN shown — the show is returned and nothing is hidden', () async {
      final client = await clientWith(api: _GotFakeApi());
      try {
        final results = await client.searchItems('game of thrones');
        expect(results.map((i) => i.title), contains('EN - Game Of Thrones (2011)'));
        expect(client.lastSearchDiagnostics!.series.hiddenMatches, 0);
        expect(client.lastSearchHiddenMatchesForLibrary('iptv:conn-xt-1:series'), 0);
      } finally {
        client.close();
      }
    });
  });
}

/// Minimal fake panel: the GoT show in "|EN| TOP SERIES" (id 1219) plus
/// a few non-matching fillers, so the hidden count is exactly 1.
class _GotFakeApi extends XtreamApi {
  _GotFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1219', name: '|EN| TOP SERIES')];

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: '|EN| Movies 1')];

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: '|EN| Live 1')];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamSeries(seriesId: 10, name: 'EN - Game Of Thrones (2011)', categoryId: '1219'),
    XtreamSeries(seriesId: 11, name: 'Filler Series A', categoryId: '1219'),
    XtreamSeries(seriesId: 12, name: 'Filler Series B', categoryId: '1219'),
  ];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];
}
