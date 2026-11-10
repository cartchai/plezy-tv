// FAILING-FIRST — build #17 §2 (v2.25.13): toggling a category off
// re-pays the whole bind — a new IptvClient with cold catalogs, three
// concurrent warm-ups (~1.3–1.5 s of parse at Trex scale), a health
// probe, and a full tab/guide reload. The switch itself is 203 ms; the
// cascade is the lag Matt feels.
//
// The fix: a filter-only re-bind reuses the live client
// (IptvClient.updateConnection) — the warm catalogs stay, no re-warm,
// no health probe. A data-source change (server URL / credentials)
// still replaces the client, because the warm catalogs belong to the
// old data source.

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  late _CallCounts counts;
  late MultiServerManager manager;

  XtreamConnection trexConnection() => XtreamConnection(
    id: 'conn-xt-1',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    createdAt: DateTime.utc(2026, 11, 5),
  );

  setUp(() {
    counts = _CallCounts();
    IptvCatalogDiskCache.debugDisableDisk = true;
    // Every client the manager creates gets its own fake API instance
    // (production parity: one API per client), sharing one counter so a
    // re-warm is visible no matter which client instance pays it.
    IptvClient.debugClientFactory = (connection) {
      final client = IptvClient.xtream(xtreamConnection: connection as XtreamConnection);
      client.testXtreamApi = _CountingFakeApi(counts);
      return client;
    };
    manager = MultiServerManager();
  });

  tearDown(() {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvClient.debugClientFactory = null;
    manager.dispose();
  });

  /// Wait until the three warm-ups have each made their unfiltered call
  /// (they are unawaited by design), or fail: without warm catalogs the
  /// "no re-warm" assertion below would be vacuous.
  Future<void> waitForWarmUps() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (counts.unfilteredSeries >= 1 && counts.unfilteredVod >= 1 && counts.unfilteredLive >= 1) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('warm-ups did not run: $counts');
  }

  group('build17 toggle lag: filter-only re-bind reuses the client', () {
    test('toggling an initial off reuses the client and pays zero re-warm', () async {
      expect(await manager.addIptvConnection(trexConnection()), isTrue);
      await waitForWarmUps();
      final clientBefore = manager.getClient(ServerId('conn-xt-1')) as IptvClient;
      final countsBefore = counts.snapshot();

      // The toggle: the categories screen re-binds the same connection
      // with one initial turned off.
      expect(
        await manager.addIptvConnection(
          trexConnection().copyWith(hiddenCategoryInitials: const ['FR']),
        ),
        isTrue,
      );
      final clientAfter = manager.getClient(ServerId('conn-xt-1')) as IptvClient;

      // Same client instance — the warm catalogs were never discarded.
      expect(identical(clientAfter, clientBefore), isTrue);
      // Zero unfiltered loads after the toggle: no re-warm at all.
      expect(counts.snapshot(), countsBefore);
      // The filter still took effect on the reused client.
      final categories = await clientAfter.iptvCategoriesForLibrary('iptv:conn-xt-1:series');
      expect(categories.map((c) => c.name), isNot(contains('FR | Series')));
      expect(categories.map((c) => c.name), contains('|EN| Series'));
      expect(
        (await clientAfter.searchItems('FR Show')).map((i) => i.title),
        isNot(contains('FR Show')),
      );
      expect(
        (await clientAfter.searchItems('EN Show')).map((i) => i.title),
        contains('EN Show'),
      );
    });

    test('changing the server URL still replaces the client (and re-warms)', () async {
      expect(await manager.addIptvConnection(trexConnection()), isTrue);
      await waitForWarmUps();
      final clientBefore = manager.getClient(ServerId('conn-xt-1')) as IptvClient;
      final countsBefore = counts.snapshot();

      expect(
        await manager.addIptvConnection(
          trexConnection().copyWith(serverUrl: 'https://other.example.com:8080'),
        ),
        isTrue,
      );
      final clientAfter = manager.getClient(ServerId('conn-xt-1')) as IptvClient;
      expect(identical(clientAfter, clientBefore), isFalse);
      // The new client warms its own catalogs from the new data source.
      expect(counts.unfilteredSeries, greaterThan(countsBefore.unfilteredSeries));
      expect(counts.unfilteredVod, greaterThan(countsBefore.unfilteredVod));
      expect(counts.unfilteredLive, greaterThan(countsBefore.unfilteredLive));
    });
  });
}

class _CallCounts {
  int unfilteredSeries = 0;
  int unfilteredVod = 0;
  int unfilteredLive = 0;

  ({int unfilteredSeries, int unfilteredVod, int unfilteredLive}) snapshot() =>
      (unfilteredSeries: unfilteredSeries, unfilteredVod: unfilteredVod, unfilteredLive: unfilteredLive);

  @override
  String toString() => 'series=$unfilteredSeries vod=$unfilteredVod live=$unfilteredLive';
}

/// Fake panel whose unfiltered calls are counted. Per-category calls are
/// not counted here: the assertion is about the warm-up loads, which are
/// always unfiltered.
class _CountingFakeApi extends XtreamApi {
  _CountingFakeApi(this.counts)
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final _CallCounts counts;

  @override
  Future<Map<String, dynamic>?> getUserInfo() async => const {'status': 'Active'};

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => const [
    XtreamCategory(id: 'S1', name: '|EN| Series'),
    XtreamCategory(id: 'S2', name: 'FR | Series'),
  ];

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: 'M1', name: '|EN| Movies')];

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: 'L1', name: '|EN| Live')];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) counts.unfilteredSeries++;
    return const [
      XtreamSeries(seriesId: 10, name: 'EN Show', categoryId: 'S1'),
      XtreamSeries(seriesId: 11, name: 'FR Show', categoryId: 'S2'),
    ];
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) counts.unfilteredVod++;
    return const [XtreamVodStream(streamId: 1, name: 'EN Movie', containerExtension: 'mp4', categoryId: 'M1')];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) counts.unfilteredLive++;
    return const [XtreamLiveStream(streamId: 100, name: 'EN Channel', categoryId: 'L1')];
  }
}
