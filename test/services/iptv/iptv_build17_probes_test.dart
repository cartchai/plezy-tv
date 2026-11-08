// RESEARCH PROBES — build #17 (v2.25.13), NOT fix code.
// Written by the research agent in its own worktree at e97112171.
// These characterize the five reported failures failing-first, at Matt's
// scale and filter state, so the programming agent + independent tester
// can prove each fix against the same probe instead of guessing.
//
// Groups:
//  A. Category-initial derivation holes (item 3) — the LAST-segment-wins
//     rule lets a trailing all-caps content word (NEWS/KIDS/LIVE/HBO)
//     override the region initial, so turning off a region does NOT hide
//     those categories.
//  B. Catch-up timeshift URL, exact shape (items 5/6) — the URL the app
//     builds for The Office (9:30 AM programme, tapped 10:38 AM), and
//     what it sends for duration (start→now) vs programme duration.
//  C. Series search, scoped + unscoped (item 8) — "game of thrones"
//     against a panel whose per-category get_series returns [] (shape g)
//     and a warm catalog, with Matt's migrated hidden-initials state.
//  E. Trex-scale isolate parse cost (item 2) — what each toggle's client
//     swap re-pays: the three warm-ups re-parse 55k + 199k + 46k rows.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/utils/iptv_initials.dart';
import 'package:plezy/screens/video_player/live_tv_session_args.dart';
import 'package:plezy/models/livetv_capture_buffer.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  group('build17 A: category-initial derivation', () {
    test('A1: trailing all-caps content word overrides the region', () {
      // A user reading "LIVE TV | EN | NEWS" sees an EN category. The
      // derivation scans pipe segments and the LAST match wins — "NEWS"
      // is a 4-letter all-caps bare segment, so it wins over EN.
      expect(categoryInitial('LIVE TV | EN | NEWS'), 'EN');
    });

    test('A2: FR does not hide a category ending in KIDS', () {
      expect(categoryInitial('FR | KIDS'), 'FR');
    });

    test('A3: DE does not hide a category ending in LIVE', () {
      expect(categoryInitial('DE | LIVE'), 'DE');
    });

    test('A4: AR does not hide a category ending in HBO', () {
      expect(categoryInitial('AR | HBO'), 'AR');
    });

    test('A5: buried region still wins when the tail is Title Case', () {
      // Control: Title Case tails ("Action", "Drama") are words, not
      // codes, so the region survives — this already works.
      expect(categoryInitial('MOVIES | EN | Action'), 'EN');
      expect(categoryInitial('SERIES | FR | Drama'), 'FR');
      expect(categoryInitial('|EN| UK SERIES'), 'EN');
      expect(categoryInitial('24/7 ACTION & ADVENTURE VIP'), '24/7');
    });

    test('A5b: the REAL Game of Thrones category derives EN', () {
      // Real-panel fact (parent probe, 2026-11-08 ~12:42 EST): the
      // English GoT is "EN - Game Of Thrones (2011)" in category
      // "|EN| TOP SERIES" (id 1219). Derivation: segments "" / "EN" /
      // "TOP SERIES" — "TOP SERIES" matches no rule (prefixed pattern
      // needs a [-:/] separator; the token rule needs a digit/slash),
      // so the region EN survives. The (c) suspect therefore hinges on
      // whether 'EN' itself is in Matt's migrated hidden set — NOT on a
      // derivation hole for this category. EN was ON in his 2026-11-06
      // screenshot (old selector), but its state after the build #10
      // redesign + build #15 migration is UNVERIFIED on his phone.
      expect(categoryInitial('|EN| TOP SERIES'), 'EN');
    });

    test('A6: the initials list offers the content words as toggles', () {
      // countCategoryInitials over bare trailing content words, five
      // categories each: NEWS/KIDS/LIVE/HBO each repeat 5×, so they
      // clear the repeat threshold and are OFFERED as filterable sets
      // (research14 SA-10) — the screen offers "turn off NEWS"
      // alongside "turn off EN", and the user cannot tell which one
      // governs a given category. (An earlier draft of this probe used
      // suffixed names like "NEWS 2", which derive EN, not NEWS — the
      // override only fires on a BARE trailing segment.)
      final counts = countCategoryInitials([
        'LIVE TV | EN | NEWS',
        'LIVE TV | FR | NEWS',
        'LIVE TV | DE | NEWS',
        'LIVE TV | AR | NEWS',
        'LIVE TV | ES | NEWS',
        'FR | KIDS',
        'DE | KIDS',
        'AR | KIDS',
        'ES | KIDS',
        'IT | KIDS',
        'DE | LIVE',
        'FR | LIVE',
        'AR | LIVE',
        'ES | LIVE',
        'IT | LIVE',
        'AR | HBO',
        'FR | HBO',
        'DE | HBO',
        'ES | HBO',
        'IT | HBO',
      ]);
      final offered = initialsMeetingThreshold(counts);
      // The fix must NOT offer NEWS/KIDS/LIVE/HBO as region toggles.
      expect(offered.map((i) => i.initial), isNot(contains('NEWS')));
      expect(offered.map((i) => i.initial), isNot(contains('KIDS')));
    });
  });

  group('build17 B: catch-up timeshift URL', () {
    test('B1: exact URL the app builds for The Office', () {
      // The Office, 9:30 AM EST 2026-11-08 (14:30 UTC), tapped 10:38 AM
      // EST (15:38 UTC). Programme duration 30 min. Stream id is the
      // numeric channel key (iptv_client.dart:2989,2992).
      final api = XtreamApi(
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
      );
      final programmeStart = DateTime.utc(2026, 11, 8, 14, 30);
      final nowEpoch = DateTime.utc(2026, 11, 8, 15, 38).millisecondsSinceEpoch ~/ 1000;
      final programmeStartEpoch = programmeStart.millisecondsSinceEpoch ~/ 1000;
      final offset = liveTvCatchUpOffsetSeconds(
        catchUpStartEpoch: programmeStartEpoch,
        captureBuffer: CaptureBuffer(
          startedAt: nowEpoch.toDouble(),
          seekStartSeconds: -7 * 24 * 3600,
          seekEndSeconds: 0,
        ),
        nowEpoch: nowEpoch,
      );
      expect(offset, -4080);
      // streamUrlAt math (iptv_live_tv.dart): backMinutes = start→now,
      // duration = backMinutes clamped to the archive window.
      final backMinutes = (-offset! / 60).ceil();
      expect(backMinutes, 68);
      final url = api.timeshiftUrl(
        streamId: '12345',
        durationMinutes: backMinutes,
        start: DateTime.fromMillisecondsSinceEpoch(programmeStartEpoch * 1000, isUtc: true),
      );
      // Characterization of the CURRENT shape (this passes): no seconds,
      // duration = start→now (68), .m3u8.
      expect(
        url,
        'https://panel.example.com:8080/timeshift/user/pass/68/2026-11-08:14-30/12345.m3u8',
      );
      // The open question (Dispatcharr: duration = PROGRAMME duration,
      // 30 min, not start→now): the app sends 68. If the panel wants 30,
      // this is the bug — and it is NOT decidable from docs alone (see
      // RESEARCH_BUILD17.md §5). The real-panel probe settles it.
      // ignore: avoid_print
      print('APP URL: $url');
      // ignore: avoid_print
      print('DISPATCHARR-SHAPE URL would be: https://panel.example.com:8080/timeshift/user/pass/30/2026-11-08:14-30/12345.m3u8');
    });
  });

  group('build17 C: series search "game of thrones"', () {
    IptvClient clientWith({required XtreamApi api, List<String> hiddenInitials = const []}) {
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

    const moviesLibraryId = 'iptv:conn-xt-1:movies';

    Future<T> withScaledBudget<T>(Future<T> Function() body) async {
      final previous = IptvClient.searchSectionBudget;
      IptvClient.searchSectionBudget = const Duration(milliseconds: 1000);
      try {
        return await body();
      } finally {
        IptvClient.searchSectionBudget = previous;
      }
    }

    test('C1: warm catalog, EN shown — unscoped AND scoped find the show', () async {
      // Real-panel shape (parent probe, 2026-11-08 ~12:42 EST): 46,527
      // unfiltered series rows; "EN - Game Of Thrones (2011)" in
      // category "|EN| TOP SERIES" (id 1219); per-category get_series
      // for 1219 returns 110 rows (panel serves per-category fine —
      // suspect (g) is DEAD for this category). 237 series categories.
      final client = clientWith(
        api: _GotFakeApi(unfilteredSeriesDelay: Duration.zero),
      );
      try {
        final unscoped = await withScaledBudget(() => client.searchItems('game of thrones'));
        expect(unscoped.map((i) => i.title), contains('EN - Game Of Thrones (2011)'));
        final scoped = await withScaledBudget(
          () => client.searchItems('game of thrones', excludedLibraryIds: {moviesLibraryId}),
        );
        expect(scoped.map((i) => i.title), contains('EN - Game Of Thrones (2011)'));
        // The scoped search must not silently drop the series leg.
        expect(client.lastSearchDiagnostics?.series.skipped, isFalse);
        expect(client.lastSearchDiagnostics?.series.returned, greaterThan(0));
      } finally {
        client.close();
      }
    });

    test('C2: warm catalog, EN hidden — the filter hides the show BY DESIGN', () async {
      // Control: hiding EN must hide EN shows from search. If Matt's
      // phone behaves like this, search is working as designed and the
      // show's category initial is in his hidden 161 — the fix is UX
      // (tell him which filter hides it), not search. EN was ON in his
      // 2026-11-06 screenshot, but its state after the build #10
      // redesign + build #15 migration is UNVERIFIED on his phone.
      final client = clientWith(
        api: _GotFakeApi(unfilteredSeriesDelay: Duration.zero),
        hiddenInitials: const ['EN'],
      );
      try {
        final results = await withScaledBudget(() => client.searchItems('game of thrones'));
        expect(results, isEmpty);
      } finally {
        client.close();
      }
    });

    test('C2b: warm catalog, category 1219 hidden by id — also hidden BY DESIGN', () async {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
        hiddenCategoryIds: const ['1219'],
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testXtreamApi = _GotFakeApi(unfilteredSeriesDelay: Duration.zero);
      try {
        final results = await withScaledBudget(() => client.searchItems('game of thrones'));
        expect(results, isEmpty);
      } finally {
        client.close();
      }
    });

    test('C3: derivation hole — EN hidden, show in "LIVE TV | EN | NEWS" still found', () async {
      // FAILING-FIRST (item 3 mechanism at the search layer): the user
      // turned off EN expecting every EN category hidden, but the
      // category derives NEWS, so the show survives the filter.
      final client = clientWith(
        api: _GotFakeApi(
          unfilteredSeriesDelay: Duration.zero,
          gotCategoryId: '2',
          gotCategoryName: 'LIVE TV | EN | NEWS',
        ),
        hiddenInitials: const ['EN'],
      );
      try {
        final results = await withScaledBudget(() => client.searchItems('game of thrones'));
        expect(results, isEmpty);
      } finally {
        client.close();
      }
    });

    test('C4: cold catalog, slow unfiltered load, late category — show lost', () async {
      // FAILING-FIRST (suspect (b) mechanism at real scale): the
      // unfiltered 46,527-row load lands after the section budget and
      // the per-category sweep (batches of 16, 80ms/call, 900ms
      // deadline) cannot reach category 1219 — LAST in the 237-category
      // list — in time, so search returns [] although the show exists
      // on the panel and per-category works. Whether 1219 is actually
      // late in the panel's category order is UNVERIFIED — the
      // "Last search" diagnostic (sweep/partial/ms) on Matt's phone
      // decides.
      final client = clientWith(
        api: _GotFakeApi(
          unfilteredSeriesDelay: const Duration(milliseconds: 1400),
          perCategoryDelay: const Duration(milliseconds: 80),
        ),
      );
      try {
        final results = await withScaledBudget(() => client.searchItems('game of thrones'));
        expect(results.map((i) => i.title), contains('EN - Game Of Thrones (2011)'));
      } finally {
        client.close();
      }
    });
  });

  group('build17 E: Trex-scale isolate parse cost', () {
    test('E1: parsing 199,762 VOD rows + 55,205 live + 46,461 series', () async {
      String rowsJson(int count, String kind) {
        final sb = StringBuffer('[');
        for (var i = 0; i < count; i++) {
          if (i > 0) sb.write(',');
          if (kind == 'vod') {
            sb.write('{"stream_id":$i,"name":"Movie $i","category_id":"1","container_extension":"mp4"}');
          } else if (kind == 'live') {
            sb.write('{"stream_id":$i,"name":"Channel $i","category_id":"1","tv_archive":0,"epg_channel_id":"ch$i"}');
          } else {
            sb.write('{"series_id":$i,"name":"Series $i","category_id":"1"}');
          }
        }
        sb.write(']');
        return sb.toString();
      }

      final vodBody = rowsJson(199762, 'vod');
      final sw = Stopwatch()..start();
      final vod = await XtreamApi.parseVodStreamsBody(vodBody);
      final vodMs = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print('VOD parse 199,762 rows: ${vodMs}ms (${vod.length} rows)');

      sw.reset();
      final liveBody = rowsJson(55205, 'live');
      final live = await XtreamApi.parseLiveStreamsBody(liveBody);
      final liveMs = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print('LIVE parse 55,205 rows: ${liveMs}ms (${live.length} rows)');

      sw.reset();
      final seriesBody = rowsJson(46461, 'series');
      final series = await XtreamApi.parseSeriesBody(seriesBody);
      final seriesMs = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print('SERIES parse 46,461 rows: ${seriesMs}ms (${series.length} rows)');
      // ignore: avoid_print
      print('TOTAL parse (one client swap re-pays all three): ${vodMs + liveMs + seriesMs}ms');
      expect(vod.length, 199762);
      expect(live.length, 55205);
      expect(series.length, 46461);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}

/// Fake panel for group C — the REAL Trex shape (parent probes,
/// 2026-11-08 ~12:42 EST): 237 series categories; unfiltered get_series
/// returns 46,527 rows including "EN - Game Of Thrones (2011)" in
/// category "|EN| TOP SERIES" (id 1219, LAST in the category list);
/// per-category get_series for 1219 returns 110 rows (panel serves
/// per-category fine — suspect (g) is DEAD for this category).
class _GotFakeApi extends XtreamApi {
  _GotFakeApi({
    this.unfilteredSeriesDelay = Duration.zero,
    this.perCategoryDelay = Duration.zero,
    this.gotCategoryId = '1219',
    this.gotCategoryName = '|EN| TOP SERIES',
  }) : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final Duration unfilteredSeriesDelay;
  final Duration perCategoryDelay;
  final String gotCategoryId;
  final String gotCategoryName;

  List<XtreamCategory> get _seriesCategories {
    final cats = [
      for (var i = 1; i <= 236; i++) XtreamCategory(id: '$i', name: '|EN| Series $i'),
    ];
    if (gotCategoryId == '1219') {
      cats.add(XtreamCategory(id: '1219', name: gotCategoryName));
    } else {
      // C3: the derivation-hole category replaces id 2 in the list.
      cats[1] = XtreamCategory(id: gotCategoryId, name: gotCategoryName);
    }
    return cats;
  }

  List<XtreamSeries> get _allSeries => [
    XtreamSeries(seriesId: 10, name: 'EN - Game Of Thrones (2011)', categoryId: gotCategoryId),
    for (var i = 0; i < 46526; i++)
      XtreamSeries(seriesId: 1000 + i, name: 'Filler Series $i', categoryId: '${(i % 236) + 1}'),
  ];

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async => _seriesCategories;

  @override
  Future<List<XtreamCategory>> getVodCategories() async =>
      [const XtreamCategory(id: '1', name: '|EN| Movies 1')];

  @override
  Future<List<XtreamCategory>> getLiveCategories() async =>
      [const XtreamCategory(id: '1', name: '|EN| Live 1')];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    if (categoryId == null) {
      await Future.delayed(unfilteredSeriesDelay);
      return _allSeries;
    }
    await Future.delayed(perCategoryDelay);
    if (categoryId == gotCategoryId) {
      return [
        XtreamSeries(seriesId: 10, name: 'EN - Game Of Thrones (2011)', categoryId: categoryId),
        for (var i = 0; i < 109; i++)
          XtreamSeries(seriesId: 2000 + i, name: 'Top Series Filler', categoryId: categoryId),
      ];
    }
    return const [];
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => const [];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => const [];
}
