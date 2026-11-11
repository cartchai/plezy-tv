// BUILD v1.0.11 — R2.0: the SEARCH RULE, two-mode search.
//
// Matt (2026-11-11): as-you-type search is LOCAL/CACHED ONLY — zero panel
// requests in every state, warm or cold. Only Enter (submit) may go online.
//
// These tests use only the new public API, so they FAIL TO LOAD on base
// b6a08b348 (no `onlineAllowed` parameter exists yet) and PASS on the fix.
// The submit group additionally needs R2.3 (the cold sweep is still in
// the submit path at the R2.0 stage, so its request counts fail until
// the sweep is gone). No live panel: fakes only.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/r2_fake_xtream_api.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build_r2_enter_');
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

  group('R2.0 — typing is local-only', () {
    test('typing makes zero panel requests in every state, warm or cold', () async {
      final api = R2FakeXtreamApi();
      final client = r2ClientWith(api);
      await r2SeedDisk();
      await r2WarmMoviesAndLiveOnly();

      // Warm movie needle: answered from the local index.
      api.resetCounts();
      final movies = await client.searchItems('filler movie', onlineAllowed: false);
      expect(api.totalRequests, 0, reason: 'typing must not touch the panel');
      expect(movies.map((m) => m.title), contains('Filler Movie 0'));

      // Five different needles, warm + cold + no-match: still zero.
      for (final needle in ['filler common', 'live channel', 'game of thrones', 'zzzz', 'filler series']) {
        final results = await client.searchItems(needle, onlineAllowed: false);
        expect(api.totalRequests, 0, reason: 'typing "$needle" must not touch the panel');
        if (needle == 'game of thrones') {
          // Series index is cold, but the disk catalog is warm: typing
          // answers from the local disk rows (0 requests) — the SEARCH
          // RULE forbids panel requests, not local data. Only a type
          // with no local rows at all returns [] while typing.
          expect(results.map((m) => m.title), contains(r2GotName));
        }
      }
    });

    test('typing on a fully cold client makes zero panel requests', () async {
      final api = R2FakeXtreamApi();
      final client = r2ClientWith(api);
      // No disk, no index rows at all.
      final results = await client.searchItems('game of thrones', onlineAllowed: false);
      expect(results, isEmpty);
      expect(api.totalRequests, 0, reason: 'a cold client must not fetch while typing');
      expect(api.perCategoryRequests, 0);
    });

    test('the default (no flag passed) is typing: local-only', () async {
      final api = R2FakeXtreamApi();
      final client = r2ClientWith(api);
      await r2SeedDisk();
      await r2WarmMoviesAndLiveOnly();
      final results = await client.searchItems('filler movie');
      expect(api.totalRequests, 0, reason: 'the default must be the safe (local-only) value');
      expect(results.map((m) => m.title), contains('Filler Movie 0'));
    });
  });

  group('R2.0 — submit goes online (needs R2.3 for the counts)', () {
    test('submit on a cold series index syncs once: 6 requests, no sweep', () async {
      final api = R2FakeXtreamApi();
      final client = r2ClientWith(api);
      await r2SeedDisk();
      await r2WarmMoviesAndLiveOnly();
      // Backdate the disk files so the seed stamps series stale too —
      // otherwise the seed warms it fresh and the sync skips it (4, not 6).
      await r2BackdateDisk(tempDir, const Duration(days: 8));

      api.resetCounts();
      final results = await client.searchItems('game of thrones', onlineAllowed: true);
      // The warm disk catalog answers immediately, before the sync lands.
      expect(results.map((m) => m.title), contains(r2GotName));

      await r2WaitForQuiescent(api);
      expect(api.totalRequests, 6, reason: 'one coalesced sync: 3 category lists + 3 catalogs');
      expect(api.perCategoryRequests, 0, reason: 'no per-category sweep requests on submit');

      // The sync landed: the series index is warm now, and a later
      // typing search finds GoT locally with zero requests.
      await client.searchIndexReady;
      api.resetCounts();
      final again = await client.searchItems('game of thrones', onlineAllowed: false);
      expect(api.totalRequests, 0);
      expect(again.map((m) => m.title), contains(r2GotName));
    });
  });

  group('R2.3 — Enter-time cold path: sync-first, sweep removed', () {
    test('submit on a cold index + failing panel returns fast, sync attempted once', () async {
      final api = R2FakeXtreamApi()..failCatalogFetches = true;
      final client = r2ClientWith(api);
      // Cold index + cold disk: nothing seeded, nothing on disk.

      final stopwatch = Stopwatch()..start();
      final results = await client.searchItems('game of thrones', onlineAllowed: true);
      stopwatch.stop();
      expect(results, isEmpty, reason: 'nothing local, panel failing');
      // The old cold path raced a 49 s per-category sweep here; the
      // Enter path answers from local data (none) and lets the sync run
      // behind it.
      expect(stopwatch.elapsedMilliseconds, lessThan(5000), reason: 'no 49 s sweep');
      final diagnostics = client.lastSearchDiagnostics;
      expect(diagnostics, isNotNull);
      expect(diagnostics!.series.cold, isTrue);

      await r2WaitForQuiescent(api);
      await client.searchIndexReady;
      expect(api.totalRequests, 6, reason: 'one coalesced sync attempted all three types');
      expect(api.perCategoryRequests, 0, reason: 'no per-category sweep requests');
      // Honest failure state: the index stays cold — the sync recorded
      // every type failed instead of stamping fresh.
      final index = await IptvSearchIndex.open();
      addTearDown(index.close);
      expect(index.rowCounts('conn-xt-1'), {'live': 0, 'movie': 0, 'series': 0});
    });

    test('submit on a cold index + cold disk syncs once, then finds the show', () async {
      final api = R2FakeXtreamApi();
      final client = r2ClientWith(api);
      // No seed: index + disk both cold.

      final first = await client.searchItems('game of thrones', onlineAllowed: true);
      expect(first, isEmpty, reason: 'nothing local yet — the sync is fetching it');

      await r2WaitForQuiescent(api);
      await client.searchIndexReady;
      expect(api.totalRequests, 6, reason: 'one coalesced sync: 3 category lists + 3 catalogs');
      expect(api.perCategoryRequests, 0, reason: 'no sweep requests at any point');

      // The sync landed — a second search finds GoT from the warm index
      // with zero further requests.
      final second = await client.searchItems('game of thrones', onlineAllowed: true);
      expect(second.map((m) => m.title), contains(r2GotName));
      expect(api.totalRequests, 6, reason: 'the second search adds no requests');
    });
  });

  group('R2.4 — sync-fetch retry: once, transport errors only, forced syncs only', () {
    test('a connection-closed series fetch is retried once and lands (7 requests)', () async {
      // Matt's log: the series leg failed with "Connection closed while
      // receiving data" — a transport error the sync must survive without
      // a manual retry. One retry, one extra request: 6 + 1 = 7.
      final api = R2FakeXtreamApi()..failOnceClosedTypes = {'series'};
      final client = r2ClientWith(api);
      await r2SeedDisk();
      await r2WarmMoviesAndLiveOnly();
      await r2BackdateDisk(tempDir, const Duration(days: 8));
      api.resetCounts();

      final result = await client.syncSearchIndex(force: true);

      expect(result.skipped['series'], isNull, reason: 'the retried series fetch lands');
      expect(result.rows['series'], greaterThan(0));
      expect(client.searchIndexState.rowCounts['series'], greaterThan(0));
      expect(api.totalRequests, 7, reason: '6 + exactly one retry of the series catalog fetch');
      expect(api.perCategoryRequests, 0, reason: 'the retry is a re-fetch, not a sweep');
    });

    test('a timeout is NOT retried: 6 requests, type recorded failed', () async {
      // connectionTimeout is a different failure class — the panel is
      // not answering at all, and re-asking immediately only adds load.
      final api = R2FakeXtreamApi()..failCatalogFetches = true;
      final client = r2ClientWith(api);
      await r2SeedDisk();
      await r2WarmMoviesAndLiveOnly();
      await r2BackdateDisk(tempDir, const Duration(days: 8));
      api.resetCounts();

      final result = await client.syncSearchIndex(force: true);

      expect(api.totalRequests, 6, reason: 'no retries on timeouts');
      expect(result.skipped['series'], 'failed');
      expect(result.skipped['movie'], 'failed');
      expect(result.skipped['live'], 'failed');
    });

    test('a background (non-forced) sync does NOT retry a closed fetch', () async {
      // The retry is for forced syncs only (Enter, manual refresh). A
      // background/interval sync that hits the same closed fetch records
      // the failure and moves on — it must not spend an extra request
      // or hold the sync open for the backoff.
      final api = R2FakeXtreamApi()..failOnceClosedTypes = {'series'};
      final client = r2ClientWith(api);
      await r2SeedDisk();
      await r2WarmMoviesAndLiveOnly();
      await r2BackdateDisk(tempDir, const Duration(days: 8));
      api.resetCounts();

      final result = await client.syncSearchIndex(force: false);

      expect(result.skipped['series'], 'failed', reason: 'no retry on a non-forced sync');
      expect(api.totalRequests, 6, reason: '6, no retry request');
    });

    test('Enter on a cold type with a closed series fetch still finds GoT (7 requests)', () async {
      // The Enter path is a forced sync: the same one-retry rule applies,
      // so the first submit recovers and the re-run finds the show.
      final api = R2FakeXtreamApi()..failOnceClosedTypes = {'series'};
      final client = r2ClientWith(api);
      api.resetCounts();

      final first = await client.searchItems('game of thrones', onlineAllowed: true);
      expect(first, isEmpty, reason: 'nothing local yet; the sync is in flight');
      await r2WaitForQuiescent(api);
      await client.searchIndexReady;
      final second = await client.searchItems('game of thrones', onlineAllowed: true);

      expect(second.map((m) => m.title), contains(r2GotName));
      expect(api.totalRequests, 7, reason: '6 + one retry of the closed series fetch');
      expect(api.perCategoryRequests, 0);
    });
  });
}
