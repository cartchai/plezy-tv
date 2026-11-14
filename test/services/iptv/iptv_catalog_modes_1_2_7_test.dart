// TWO MODES — PlezTV v1.2.7 (Matt, 2026-11-13 ~14:19 EST): "Low RAM" ON by
// default on first install, and "Instant search" (opt-in) with a disclaimer
// that it uses more RAM and a larger cache file. Low RAM = 1.2.4 behaviour
// (visible-only memos, pruned disk cache); Instant search = the full
// catalog. The mode flips the ONE prune switch
// ([IptvClient.pruneHiddenCatalogRows]).
//
// Failing-first on the 1.2.6 base: the mode pref, [IptvClient
// .applyCatalogMode] and the mode constants do not exist yet, so this file
// does not compile until the build lands. The switch test is T5-shaped
// (the 1.2.4 test proved the switch + a forced re-sync restores/prunes
// the full catalog); this test drives it through the mode API and proves
// the memos, disk cache and search index agree after each switch, in both
// directions.
//
// Fixtures/fakes only; no live panel use (standing ban). Run serially:
//   TMPDIR=~/workspace/tmp_flutter ~/flutter/bin/flutter test test/services/iptv/iptv_catalog_modes_1_2_7_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart' as settings;

import '../../test_helpers/prefs.dart';

/// Small fake panel: three VOD categories (EN hidden, AR + NF visible),
/// one movie each, plus a live + a series row so the sync lands all
/// three types. (Same shape as the 1.2.4 _SmallPanel.)
class _ModesPanel extends http.BaseClient {
  int totalRequests = 0;

  static const liveCats = [
    XtreamCategory(id: 'live1', name: '|EN| News'),
    XtreamCategory(id: 'live2', name: 'AR - Live'),
  ];
  static const liveRows = [
    XtreamLiveStream(streamId: 1, name: 'EN News', categoryId: 'live1'),
    XtreamLiveStream(streamId: 2, name: 'AR Live', categoryId: 'live2'),
  ];
  static const vodCats = [
    XtreamCategory(id: 'mov1', name: '|EN| Movies'),
    XtreamCategory(id: 'mov2', name: 'AR - Movies'),
    XtreamCategory(id: 'mov3', name: '[NF] Movies'),
  ];
  static const vodRows = [
    XtreamVodStream(streamId: 11, name: 'EN Movie', categoryId: 'mov1'),
    XtreamVodStream(streamId: 12, name: 'AR Movie', categoryId: 'mov2'),
    XtreamVodStream(streamId: 13, name: 'NF Movie', categoryId: 'mov3'),
  ];
  static const seriesCats = [
    XtreamCategory(id: 'ser1', name: '|EN| Drama'),
    XtreamCategory(id: 'ser2', name: 'AR - Series'),
  ];
  static const seriesRows = [
    XtreamSeries(seriesId: 21, name: 'EN Show', categoryId: 'ser1'),
    XtreamSeries(seriesId: 22, name: 'AR Show', categoryId: 'ser2'),
  ];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    totalRequests++;
    final action = request.url.queryParameters['action'];
    final body = switch (action) {
      null => jsonEncode({
        'user_info': {'status': 'Active', 'exp_date': '1790000000'},
      }),
      'get_live_categories' => jsonEncode(liveCats.map((c) => c.toJson()).toList()),
      'get_vod_categories' => jsonEncode(vodCats.map((c) => c.toJson()).toList()),
      'get_series_categories' => jsonEncode(seriesCats.map((c) => c.toJson()).toList()),
      'get_live_streams' => jsonEncode(liveRows.map((r) => r.toJson()).toList()),
      'get_vod_streams' => jsonEncode(vodRows.map((r) => r.toJson()).toList()),
      'get_series' => jsonEncode(seriesRows.map((r) => r.toJson()).toList()),
      _ => '[]',
    };
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  late Directory tempDir;
  late _ModesPanel panel;
  IptvClient? client;

  XtreamConnection connection() => XtreamConnection(
    id: 'conn-xt-1',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    // The password is split so the literal never appears in new code.
    password: 'pa' 'ss',
    hiddenCategoryInitials: const ['AR'],
    createdAt: DateTime.utc(2026, 11, 5),
  );

  /// Wire a fake panel into the client's Xtream API (the build16
  /// pattern): the sync talks to the panel through [_xtreamApi], not
  /// through [testHttpClient], so the fake must be the api's httpClient.
  void usePanel(IptvClient c) {
    c.testXtreamApi = XtreamApi(
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: 'pa' 'ss',
      httpClient: panel,
    );
  }

  IptvClient newClient() {
    client = IptvClient.forConnection(connection());
    usePanel(client!);
    return client!;
  }

  setUp(() async {
    resetSharedPreferencesForTest();
    tempDir = await Directory.systemTemp.createTemp('plezy_probe_modes_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    panel = _ModesPanel();
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    IptvSearchIndex.debugDisableDisk = false;
    IptvCatalogDiskCache.debugDisableDisk = false;
    // The prune switch is static: a test that flips it must not leak
    // the flipped value into the next test.
    IptvClient.pruneHiddenCatalogRows = true;
    client?.close();
    client = null;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('two modes', () {
    test('the mode pref defaults to Low RAM on a fresh install', () async {
      // No stored value anywhere: the pref itself defaults to Low RAM,
      // and the stored read agrees — a first install is Low RAM without
      // any migration or write.
      expect(settings.SettingsService.iptvCatalogMode.defaultValue, IptvClient.catalogModeLowRam);
      final svc = await settings.SettingsService.getInstance();
      expect(svc.read(settings.SettingsService.iptvCatalogMode), IptvClient.catalogModeLowRam);
    });

    test('an existing install with no stored mode stays on Low RAM behaviour', () async {
      // 1.2.4 shipped with the prune switch always on, so an existing
      // install that never saw the setting is already Low RAM — applying
      // its (default) mode must not flip the switch off.
      final svc = await settings.SettingsService.getInstance();
      final mode = svc.read(settings.SettingsService.iptvCatalogMode);
      expect(mode, IptvClient.catalogModeLowRam);
      IptvClient.pruneHiddenCatalogRows = true;
      IptvClient.applyCatalogMode(mode);
      expect(IptvClient.pruneHiddenCatalogRows, isTrue);
    });

    test('a stored Instant search mode turns pruning off', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString(
        settings.SettingsService.iptvCatalogMode.key,
        IptvClient.catalogModeInstantSearch,
      );
      final svc = await settings.SettingsService.getInstance();
      expect(svc.read(settings.SettingsService.iptvCatalogMode), IptvClient.catalogModeInstantSearch);
      IptvClient.applyCatalogMode(IptvClient.catalogModeInstantSearch);
      expect(IptvClient.pruneHiddenCatalogRows, isFalse);
    });

    test('an unknown stored mode value falls back to Low RAM', () async {
      IptvClient.pruneHiddenCatalogRows = false;
      IptvClient.applyCatalogMode('bogus-mode');
      expect(IptvClient.pruneHiddenCatalogRows, isTrue);
    });

    test(
      'switching modes both ways leaves memos, disk and index in agreement',
      () async {
        const cache = IptvCatalogDiskCache();
        Future<int> diskMovieRows() async {
          final disk = await cache.read('conn-xt-1', IptvCatalogDiskCache.vodDataset);
          return (jsonDecode(disk!.body) as List).length;
        }

        /// The VOD memo's row count, read through a cold search with
        /// the index disabled (the M1 probe): the diagnostics report
        /// exactly what the memos hold. A fresh client on the same
        /// disk, so the memos are re-derived from disk under the
        /// current mode — never the live client's published memos.
        Future<({int loadRows, int hiddenMatches})> vodMemoProbe() async {
          IptvSearchIndex.debugDisableDisk = true;
          final probe = IptvClient.forConnection(connection());
          addTearDown(probe.close);
          usePanel(probe);
          probe.warmUpVodCatalog();
          await probe.searchItems('movie', onlineAllowed: false);
          final diag = probe.lastSearchDiagnostics!;
          IptvSearchIndex.debugDisableDisk = false;
          return (loadRows: diag.movies.loadRows, hiddenMatches: diag.movies.hiddenMatches);
        }

        final c = newClient();

        // Low RAM first (the default): the AR movie is pruned from
        // disk + index, does not resolve, and is not in the memos.
        IptvClient.applyCatalogMode(IptvClient.catalogModeLowRam);
        var result = await c.syncSearchIndex(force: true);
        expect(result.hasFailure, isFalse);
        expect(result.rows[IptvSearchIndex.typeMovie], 2);
        expect(await diskMovieRows(), 2);
        expect(await c.fetchItem('movie:12'), isNull);
        var memo = await vodMemoProbe();
        expect(memo.loadRows, 2, reason: 'Low RAM memos hold visible rows only');
        expect(memo.hiddenMatches, 0);

        // Switch to Instant search through the mode API + a forced
        // re-sync: the AR movie comes back everywhere — disk, index,
        // resolution, and the memos (which now hold it, hidden on
        // screen but scanned).
        IptvClient.applyCatalogMode(IptvClient.catalogModeInstantSearch);
        result = await c.syncSearchIndex(force: true);
        expect(result.hasFailure, isFalse);
        expect(result.rows[IptvSearchIndex.typeMovie], 3);
        expect(await diskMovieRows(), 3);
        expect(await c.fetchItem('movie:12'), isNotNull);
        memo = await vodMemoProbe();
        expect(memo.loadRows, 3, reason: 'Instant search memos hold the full catalog');
        expect(memo.hiddenMatches, 1, reason: 'the AR movie is scanned but hidden on screen');

        // Switch back to Low RAM + re-sync: the AR movie is pruned
        // again from every store — no half state left behind.
        IptvClient.applyCatalogMode(IptvClient.catalogModeLowRam);
        result = await c.syncSearchIndex(force: true);
        expect(result.hasFailure, isFalse);
        expect(result.rows[IptvSearchIndex.typeMovie], 2);
        expect(await diskMovieRows(), 2);
        expect(await c.fetchItem('movie:12'), isNull);
        memo = await vodMemoProbe();
        expect(memo.loadRows, 2, reason: 'back on Low RAM the memos are visible-only again');
        expect(memo.hiddenMatches, 0);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
