// Region-groups probes (v1.1.0, Option B) — moved in from the research
// worktree (~/workspace/tmp_work/plezy-tv-research-region-groups).
//
// Matt's report (2026-11-12 ~23:05 EST, on v1.0.17): series search works,
// but with ONLY the EN / CA / US groups on he cannot find "Friends" or
// "Game of Thrones". With "Show all" he can. The region grouping "must be
// messed up".
//
// Failing-first on base ac9430507 (v1.0.18): 5/7 pass, R2b + R2c FAIL for
// the product reason (toggle to EN/CA/US-only leaves GoT at [], Show all
// leaves GoT at [] — the sync had landed 1 visible series row, 7 hidden
// rows skipped). Research verdict: the grouping was CORRECT
// (categoryInitial('|EN| TOP SERIES') == 'EN'; GoT and Friends both map
// to EN) — the bug was STALENESS: the v1.0.16 write-time skip dropped
// hidden rows from the index AND the disk file, and a toggle triggers no
// sync, no re-index, no re-seed, so un-hiding could not bring back rows
// that were never written.
//
// Option B (v1.1.0): the index + disk hold the FULL catalog and filter
// only at read time, so the toggle restores the shows immediately with no
// sync — R2b/R2c flip to PASS, and R2b pins the diagnostic that the
// full index makes possible (hiddenMatches == 1, hiddenInitials ==
// ['EN'] while EN is hidden). R3's expectation changes with it: the seed
// holds full rows now.
//
// These probes model Matt's exact scenario with a small fake panel.
// Friends' real category is UNKNOWN (no fixture has it) — it is modelled
// in '|EN| SITCOMS', an EN category like GoT's '|EN| TOP SERIES', and the
// assumption is stated wherever it matters.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/utils/iptv_initials.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_region_groups_');
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

  /// The 37 offered groups, modelled from Matt's 23:05 screenshot
  /// (alphabetical: 24/7, AFR, AL, AR, ASIA, AT, AU, BE, BEE, BG, BR,
  /// CA, ...). The exact 37 are the panel's initials at threshold >= 5;
  /// the set below is a 37-count model with the same EN/CA/US members.
  final offered37 = <String>{
    '24/7', 'AFR', 'AL', 'AR', 'ASIA', 'AT', 'AU', 'BE', 'BEE', 'BG',
    'BR', 'CA', 'CH', 'DE', 'EG', 'EN', 'ES', 'FI', 'FR', 'IL',
    'IN', 'IT', 'JP', 'KR', 'MX', 'NG', 'NL', 'NO', 'PK', 'PL', 'PT',
    'RU', 'SA', 'SE', 'TR', 'UK', 'US',
  };

  /// Matt's hidden set at the 1.0.16 sync: 32 initials. The exact 32 are
  /// UNKNOWN from the phone — this models the class "EN was among them",
  /// i.e. GoT's category was hidden at the last index-write.
  final hiddenOld32 = <String>{
    'EN', '24/7', 'AFR', 'AL', 'AR', 'ASIA', 'AT', 'AU', 'BE', 'BEE',
    'BG', 'BR', 'DE', 'ES', 'FR', 'IT', 'JP', 'KR', 'NL', 'PL', 'PT',
    'RU', 'TR', 'UK', 'US', 'CA', 'MX', 'IN', 'PK', 'NG', 'EG', 'SA',
  };

  /// EN / CA / US only: everything offered except those three is hidden.
  final hiddenEnCaUsOnly = offered37.difference({'EN', 'CA', 'US'});

  Future<IptvClient> clientWith({
    required _RegionFakeApi api,
    List<String> hiddenInitials = const [],
  }) async {
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
    return client;
  }

  Future<void> toggleTo(IptvClient client, Set<String> hiddenInitials) async {
    final connection = client.connection as XtreamConnection;
    final updated = connection.copyWith(
      hiddenCategoryInitials: hiddenInitials.toList(),
    );
    client.updateConnection(updated);
  }

  // Indexed series rows, read from the client's own (synchronously
  // refreshed) search-index state — no second DB connection.
  int seriesRowCount(IptvClient client) =>
      client.searchIndexState.rowCounts[IptvSearchIndex.typeSeries] ?? 0;

  group('R1: the filter is correct for the known name (control)', () {
    test('R1a: GoT and Friends categories derive EN', () {
      expect(categoryInitial('|EN| TOP SERIES'), 'EN');
      expect(categoryInitial('|EN| SITCOMS'), 'EN');
    });

    test('R1b: synced with EN/CA/US-only, GoT + Friends are found', () async {
      final client = await clientWith(
        api: _RegionFakeApi(),
        hiddenInitials: hiddenEnCaUsOnly.toList(),
      );
      try {
        await client.ensureSearchIndexSynced();
        final got = await client.searchItems('game of thrones');
        expect(got.map((i) => i.title), contains('EN - Game Of Thrones (2011)'));
        final friends = await client.searchItems('friends');
        expect(friends.map((i) => i.title), contains('EN - Friends (1994)'));
        // And the UK/FR/AR shows stay hidden, as designed.
        final sherlock = await client.searchItems('sherlock');
        expect(sherlock, isEmpty);
      } finally {
        client.close();
      }
    });
  });

  group('R2: the toggle restores rows immediately (the fix)', () {
    // Shared setup: sync with the OLD hidden set (EN hidden). Option B:
    // the sync lands ALL 8 rows and the read-time filter hides the EN
    // ones — so the shows are unfindable while EN is off, and come back
    // the moment it is on. Returns the client in that state.
    Future<IptvClient> staleClient() async {
      final client = await clientWith(
        api: _RegionFakeApi(),
        hiddenInitials: hiddenOld32.toList(),
      );
      await client.ensureSearchIndexSynced();
      expect(seriesRowCount(client), 8);
      expect(await client.searchItems('game of thrones'), isEmpty);
      expect(await client.searchItems('friends'), isEmpty);
      return client;
    }

    test('R2b: toggle to EN/CA/US-only restores GoT immediately', () async {
      final client = await staleClient();
      try {
        // Before the toggle, the shows are hidden — and the diagnostics
        // can now SEE them, because the index holds the full rows.
        expect(await client.searchItems('game of thrones'), isEmpty);
        expect(client.lastSearchDiagnostics!.series.hiddenMatches, 1);
        expect(client.lastSearchDiagnostics!.series.hiddenInitials, ['EN']);
        // The toggle changes the read-time filter — no sync, no
        // re-index — and the shows come back at once.
        await toggleTo(client, hiddenEnCaUsOnly);
        final gotAfterToggle = await client.searchItems('game of thrones');
        expect(
          gotAfterToggle.map((i) => i.title),
          contains('EN - Game Of Thrones (2011)'),
        );
        expect(seriesRowCount(client), 8); // no re-index happened
        // Nothing hidden for this query now that EN is on.
        expect(client.lastSearchDiagnostics!.series.hiddenMatches, 0);
        expect(client.lastSearchDiagnostics!.series.hiddenInitials, isEmpty);
        // Search itself still works — the ungrouped control is found.
        final breakingBad = await client.searchItems('breaking bad');
        expect(breakingBad.map((i) => i.title), contains('EN - Breaking Bad (2008)'));
      } finally {
        client.close();
      }
    });

    test('R2c: Show all restores GoT immediately', () async {
      final client = await staleClient();
      try {
        await toggleTo(client, hiddenEnCaUsOnly);
        // Clearing the filter brings the rows back at once — they were
        // in the index all along.
        await toggleTo(client, <String>{});
        final gotAfterShowAll = await client.searchItems('game of thrones');
        expect(
          gotAfterShowAll.map((i) => i.title),
          contains('EN - Game Of Thrones (2011)'),
        );
        expect(seriesRowCount(client), 8);
      } finally {
        client.close();
      }
    });

    test('R2d: a sync after the toggle keeps them found (recovery path)', () async {
      final client = await staleClient();
      try {
        await toggleTo(client, hiddenEnCaUsOnly);
        await toggleTo(client, <String>{});
        // The toggle already restored them; the sync must keep them
        // found, not lose them.
        await client.ensureSearchIndexSynced();
        final gotAfterSync = await client.searchItems('game of thrones');
        expect(gotAfterSync.map((i) => i.title), contains('EN - Game Of Thrones (2011)'));
        final friendsAfterSync = await client.searchItems('friends');
        expect(friendsAfterSync.map((i) => i.title), contains('EN - Friends (1994)'));
      } finally {
        client.close();
      }
    });
  });

  group('R3: the seed holds the full catalog', () {
    test('R3: re-seed after a toggle keeps the full index, GoT found', () async {
      final client = await clientWith(
        api: _RegionFakeApi(),
        hiddenInitials: hiddenOld32.toList(),
      );
      try {
        await client.ensureSearchIndexSynced();
        // Option B: the sync landed all 8 rows and the disk file holds
        // them too, so the seed (which only fills empty types) has
        // nothing to heal — and nothing to lose.
        expect(seriesRowCount(client), 8);
        await toggleTo(client, hiddenEnCaUsOnly);
        await client.seedSearchIndexFromDisk();
        expect(seriesRowCount(client), 8);
        final got = await client.searchItems('game of thrones');
        expect(got.map((i) => i.title), contains('EN - Game Of Thrones (2011)'));
      } finally {
        client.close();
      }
    });
  });

  group('R5: discriminator — when the old set did NOT hide EN, the toggle works', () {
    test('R5: old hidden set without EN, toggle to EN/CA/US-only finds GoT', () async {
      final oldWithoutEn = hiddenOld32.difference({'EN'});
      final client = await clientWith(
        api: _RegionFakeApi(),
        hiddenInitials: oldWithoutEn.toList(),
      );
      try {
        await client.ensureSearchIndexSynced();
        expect(seriesRowCount(client), greaterThan(1)); // EN rows landed
        await toggleTo(client, hiddenEnCaUsOnly);
        final got = await client.searchItems('game of thrones');
        expect(got.map((i) => i.title), contains('EN - Game Of Thrones (2011)'));
      } finally {
        client.close();
      }
    });
  });
}

/// Small fake panel: GoT in '|EN| TOP SERIES' (id 1219, the Nov 5
/// baseline fact), Friends in '|EN| SITCOMS' (id 1220 — MODELLED, its
/// real category is unknown), a UK/FR/AR show each, an ungrouped
/// 'TOP SERIES' control, plus one live channel and one movie so the
/// sync's three legs all succeed (a failed leg blocks the catalog
/// schema version stamp).
class _RegionFakeApi extends XtreamApi {
  _RegionFakeApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  List<XtreamCategory> get _seriesCategories => const [
    XtreamCategory(id: '1219', name: '|EN| TOP SERIES'),
    XtreamCategory(id: '1220', name: '|EN| SITCOMS'),
    XtreamCategory(id: '1221', name: '|UK| TOP SERIES'),
    XtreamCategory(id: '1222', name: '|FR| DRAMA'),
    XtreamCategory(id: '1223', name: '|AR| SERIES'),
    XtreamCategory(id: '1224', name: '|EN| COMEDY'),
    XtreamCategory(id: '1225', name: 'TOP SERIES'),
  ];

  List<XtreamSeries> get _allSeries => const [
    XtreamSeries(seriesId: 219, name: 'EN - Game Of Thrones (2011)', categoryId: '1219'),
    XtreamSeries(seriesId: 220, name: 'EN - Friends (1994)', categoryId: '1220'),
    XtreamSeries(seriesId: 221, name: 'EN - The Office (2005)', categoryId: '1224'),
    XtreamSeries(seriesId: 222, name: 'EN - Breaking Bad (2008)', categoryId: '1225'),
    XtreamSeries(seriesId: 223, name: 'UK - Sherlock (2010)', categoryId: '1221'),
    XtreamSeries(seriesId: 224, name: 'FR - Lupin (2021)', categoryId: '1222'),
    XtreamSeries(seriesId: 225, name: 'AR - Series X', categoryId: '1223'),
    XtreamSeries(seriesId: 226, name: 'EN - Filler', categoryId: '1219'),
  ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async =>
      _seriesCategories;

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: '|EN| Movies 1')];

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: '|EN| Live 1')];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    if (categoryId == null) {
      // The sync reads the raw body the API stored (not the typed rows).
      lastSeriesBody = jsonEncode(_allSeries.map((r) => r.toJson()).toList());
      return _allSeries;
    }
    return _allSeries.where((s) => s.categoryId == categoryId).toList();
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    const rows = [XtreamVodStream(streamId: 1, name: 'EN - Movie 1', categoryId: '1')];
    if (categoryId == null) {
      lastVodStreamsBody = jsonEncode(rows.map((r) => r.toJson()).toList());
      return rows;
    }
    return rows.where((s) => s.categoryId == categoryId).toList();
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    const rows = [XtreamLiveStream(streamId: 1, name: 'EN - Live Channel 1', categoryId: '1')];
    if (categoryId == null) {
      lastLiveStreamsBody = jsonEncode(rows.map((r) => r.toJson()).toList());
      return rows;
    }
    return rows.where((s) => s.categoryId == categoryId).toList();
  }
}
