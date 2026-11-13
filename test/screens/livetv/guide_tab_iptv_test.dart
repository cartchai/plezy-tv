import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

/// Guide tests for the IPTV EPG (build #6, Tasks A/B/G): a REAL
/// [IptvClient] backed by a Completer-controlled fake Xtream API, pumped
/// through the ACTUAL [GuideTab]. No network, no streams.
///
/// - Task B: while the EPG is in flight the guide shows a thin linear
///   progress bar in the header area — never a full-screen spinner, never
///   blocking — and it disappears when the programs arrive.
/// - Task G: a channel with no EPG renders one clickable "No information
///   available" block per uncovered clock hour (v1.1.1 restored the hour
///   blocks build #17 §10 had replaced with one "No guide data for this
///   channel" block spanning the window); a partial EPG still gets "No
///   information" blocks only in the hours it leaves uncovered. Tapping a
///   block opens the program detail, with a catch-up action only where the
///   channel offers it.

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: 'pass',
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Fake provider: two live channels (100 has catch-up, 101 does not) and
/// a short-EPG that only resolves when the test completes it — so the
/// tests can observe the loading state as well as the loaded state.
class _EpgControllableApi extends XtreamApi {
  _EpgControllableApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pass');

  final Map<String, Completer<List<XtreamEpgProgram>>> pending = {};
  int epgCalls = 0;

  /// When true the xmltv.php feed throws instead of loading empty — the
  /// two failure tests opt into it so BOTH sources fail (1.1.2 D1a: a
  /// feed that fails is a failure, not an empty answer).
  bool failXmltv = false;

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(
      streamId: 100,
      name: 'Trex News',
      categoryId: '1',
      tvArchive: true,
      tvArchiveDuration: 86400,
    ),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) {
    epgCalls++;
    final completer = Completer<List<XtreamEpgProgram>>();
    pending[streamId] = completer;
    return completer.future;
  }

  // The login's xmltv.php feed is the primary EPG source (Task 7), but
  // these tests control the EPG through get_short_epg's Completers. The
  // feed loads EMPTY by default (1.1.2 D1a): a channel whose short-EPG
  // answers empty and whose feed loads with nothing for it is a genuine
  // empty — hour blocks, not a failure. A feed that FAILS is a failure
  // (retry state), so the two failure tests opt into it with [failXmltv].
  // The persisted feed FILE is still read (build #15 caches the feed on
  // disk); the harness gives that real I/O a runAsync window in
  // waitForEpgCalls so it can settle in the fake async zone.
  /// Build #26: the fake's feed is a small canned String, so the stream
  /// is built on top of [getXmltv] — the production path streams, the fake
  /// does not need to.
  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(await getXmltv(timeout: timeout, abortTrigger: abortTrigger))),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }
  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    if (failXmltv) throw Exception('xmltv feed unavailable in guide tests');
    return '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  }

  void complete(String streamId, List<XtreamEpgProgram> programs) =>
      pending[streamId]?.complete(programs);

  void completeEmpty(String streamId) => pending[streamId]?.complete(const []);

  void completeError(String streamId, Object error) => pending[streamId]?.completeError(error);
}

XtreamEpgProgram _epg({
  String id = 'p1',
  String title = 'Show',
  required DateTime start,
  required DateTime end,
}) => XtreamEpgProgram(
  id: id,
  title: title,
  description: '',
  startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
  stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
);

final class _IptvGuideHarness {
  _IptvGuideHarness({this.onlyChannelKey});

  /// When set, the guide shows only this channel (key '100' or '101').
  final String? onlyChannelKey;

  final _EpgControllableApi api = _EpgControllableApi();
  late final IptvClient client;
  late final MultiServerProvider provider;
  late final List<LiveTvChannel> channels;

  Future<void> init() async {
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    final all = await client.iptvChannels();
    channels = onlyChannelKey == null
        ? all
        : all.where((c) => c.key == onlyChannelKey).toList(growable: false);
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    provider = testMultiServerProvider(manager)
      ..debugSetLiveTvServersForTesting([
        LiveTvServerInfo(serverId: 'trex', dvrKey: 'dvr-trex'),
      ]);
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: ChangeNotifierProvider<MultiServerProvider>.value(
            value: provider,
            child: MaterialApp(
              theme: monoTheme(MonoPalette.dark),
              home: Scaffold(body: GuideTab(channels: channels)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// Pump until the guide has asked for the EPG of [count] channels.
  /// The EPG fetch reads the persisted cache from disk (real dart:io),
  /// which never completes inside `testWidgets`' fake async zone on a
  /// plain pump — yield to the real event loop first so the file I/O can
  /// land, then pump to rebuild.
  Future<void> waitForEpgCalls(WidgetTester tester, int count) async {
    for (var i = 0; i < 10 && api.epgCalls < count; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
    expect(api.epgCalls, count);
    // Build #15: the xmltv feed read is real disk I/O kicked in the
    // background alongside get_short_epg (the persisted feed file is
    // checked before the feed is downloaded). Real I/O only completes
    // inside runAsync in the fake async zone, and pumpAndSettle alone
    // never delivers it — give the background read one more real-async
    // window so the fetch chain can settle before the test completes
    // the short-EPG Completers.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  void dispose() => provider.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory epgTempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    // fetchEpgForChannel reads EPG settings first: prime SettingsService
    // here, or the prefs read started from inside the widget load never
    // completes on pumps (fake async). And the persisted EPG cache
    // resolves its directory through path_provider (no mock in widget
    // tests), so point it at a temp dir. The catalog disk cache (build
    // #11) is switched off in widget tests instead: its real dart:io
    // never completes in testWidgets' fake async zone, and its behaviour
    // is covered by the unit tests — see `debugDisableDisk`.
    await SettingsService.getInstance();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_guide_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  testWidgets('loading indicator shows while the EPG is in flight, never hour blocks', (tester) async {
    final harness = _IptvGuideHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    // The thin header bar AND a visible per-row loading state (build #8
    // Task 3: the row used to stay blank while loading, with only the 3px
    // line as the signal) — never placeholders pretending the load already
    // finished empty.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text(t.liveTv.loadingGuide), findsNWidgets(2));
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    expect(find.text('No information available'), findsNothing);

    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    // v1.1.1: a channel whose fetch finished with no programmes at all
    // fills with one "No information available" block per uncovered
    // clock hour — 5 visible per row at this viewport, 10 across both
    // rows — not one block spanning the window.
    expect(find.text('No information available'), findsNWidgets(10));
    expect(find.text('No guide data for this channel'), findsNothing);
  });

  testWidgets('a failed EPG fetch shows a retry state, and tapping it retries', (tester) async {
    // Build #8 Task 3: both sources fail (get_short_epg errors; the xmltv
    // feed throws in this harness) — the row must show a visible failed
    // state, not silent hour placeholders, and tapping it must refetch.
    final harness = _IptvGuideHarness(onlyChannelKey: '100');
    // 1.1.2 D1a: the feed must actually FAIL here — a loading-empty feed
    // would make this a genuine empty (hour blocks), not a failure.
    harness.api.failXmltv = true;
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 1);

    harness.api.completeError('100', Exception('provider down'));
    await tester.pumpAndSettle();

    // No placeholders pretending the load finished empty; the retry state
    // is visible instead.
    expect(find.text('No information available'), findsNothing);
    expect(find.text(t.liveTv.guideLoadFailed), findsOneWidget);

    // Tapping retries the fetch; completing it with programmes replaces
    // the retry state with the guide.
    await tester.tap(find.text(t.liveTv.guideLoadFailed));
    await harness.waitForEpgCalls(tester, 2);
    final now = DateTime.now();
    final hourStart = DateTime(now.year, now.month, now.day, now.hour).add(const Duration(hours: 1));
    harness.api.complete('100', [
      _epg(id: 'a', title: 'Retried Show', start: hourStart, end: hourStart.add(const Duration(hours: 1))),
    ]);
    await tester.pumpAndSettle();

    expect(find.text(t.liveTv.guideLoadFailed), findsNothing);
    expect(find.text('Retried Show'), findsOneWidget);
  });

  testWidgets('channel with no EPG renders one info block per uncovered hour', (tester) async {
    final harness = _IptvGuideHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    // v1.1.1 (Task G restored): one "No information available" block per
    // uncovered clock hour — 5 visible per row at this viewport, 10
    // across both rows — and no single block spanning the window.
    expect(find.text('No information available'), findsNWidgets(10));
    expect(find.text('No guide data for this channel'), findsNothing);
  });

  testWidgets('channel with partial EPG gets hour blocks only in uncovered hours', (tester) async {
    final harness = _IptvGuideHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    // Two real programs on the next clock hour, covering exactly two
    // clock hours of channel 100's window; channel 101 stays empty.
    final now = DateTime.now();
    final hourStart = DateTime(now.year, now.month, now.day, now.hour).add(const Duration(hours: 1));
    harness.api.complete('100', [
      _epg(id: 'a', title: 'Hour Show One', start: hourStart, end: hourStart.add(const Duration(hours: 1))),
      _epg(id: 'b', title: 'Hour Show Two', start: hourStart.add(const Duration(hours: 1)), end: hourStart.add(const Duration(hours: 2))),
    ]);
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    expect(find.text('Hour Show One'), findsOneWidget);
    expect(find.text('Hour Show Two'), findsOneWidget);
    // Channel 100 lost its two covered hours (both visible at this
    // viewport): 3 "No information" blocks. Channel 101 is empty, so
    // (v1.1.1, Task G restored) it shows 5 more "No information" blocks
    // — one per uncovered hour — for 8 in total, and no single block
    // spanning the window.
    expect(find.text('No information available'), findsNWidgets(8));
    expect(find.text('No guide data for this channel'), findsNothing);
  });

  testWidgets('tapping a past hour block opens the detail with catch-up', (tester) async {
    final harness = _IptvGuideHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    // First block belongs to channel 100 (catch-up) and is the past
    // partial hour: the tune action reads "Watch Channel" and catch-up
    // reads "Watch from start (N min ago)" from that hour's own start.
    await tester.tap(find.text('No information available').first);
    await tester.pumpAndSettle();

    expect(find.text('Watch Channel'), findsOneWidget);
    expect(find.textContaining('Watch from start'), findsOneWidget);
  });

  testWidgets('no catch-up action for a channel without an archive', (tester) async {
    final harness = _IptvGuideHarness(onlyChannelKey: '101');
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 1);

    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    await tester.tap(find.text('No information available').first);
    await tester.pumpAndSettle();

    // Past hour block, so the tune action reads "Watch Channel";
    // channel 101 has no archive, so no catch-up action.
    expect(find.text('Watch Channel'), findsOneWidget);
    expect(find.text(t.liveTv.startFromBeginning), findsNothing);
    expect(find.textContaining('Watch from start'), findsNothing);
  });

  testWidgets('a past programme with guide data shows Watch from start next to Watch Channel', (tester) async {
    // Build #9 Task 2: the old catch-up gate was placeholder-only, so a
    // past programme WITH guide data opened a detail with no catch-up
    // entry at all — the feature looked missing. It must sit next to the
    // play action, clickable.
    final harness = _IptvGuideHarness(onlyChannelKey: '100');
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 1);

    final now = DateTime.now();
    harness.api.complete('100', [
      _epg(
        id: 'past',
        title: 'Past Show',
        start: now.subtract(const Duration(minutes: 50)),
        end: now.subtract(const Duration(minutes: 10)),
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Past Show'));
    await tester.pumpAndSettle();

    expect(find.text('Watch Channel'), findsOneWidget);
    expect(find.textContaining('Watch from start'), findsOneWidget);
  });

  testWidgets('a programme already playing shows Start from beginning next to Play', (tester) async {
    // Build #9 Task 2 refinement: a live programme's catch-up reads
    // "Start from beginning" (not "Watch from start") and starts playback
    // from the beginning of that programme's block.
    final harness = _IptvGuideHarness(onlyChannelKey: '100');
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 1);

    final now = DateTime.now();
    harness.api.complete('100', [
      _epg(
        id: 'live',
        title: 'Live Show',
        start: now.subtract(const Duration(minutes: 30)),
        end: now.add(const Duration(minutes: 30)),
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Live Show'));
    await tester.pumpAndSettle();

    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Start from beginning'), findsOneWidget);
    expect(find.textContaining('Watch from start'), findsNothing);
  });

  testWidgets('no catch-up action for a future programme', (tester) async {
    final harness = _IptvGuideHarness(onlyChannelKey: '100');
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 1);

    final now = DateTime.now();
    harness.api.complete('100', [
      _epg(
        id: 'future',
        title: 'Future Show',
        start: now.add(const Duration(hours: 1)),
        end: now.add(const Duration(hours: 2)),
      ),
    ]);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Future Show'));
    await tester.pumpAndSettle();

    expect(find.text('Watch Channel'), findsOneWidget);
    expect(find.textContaining('Watch from start'), findsNothing);
    expect(find.text('Start from beginning'), findsNothing);
  });

  // Hour-blocks regression suite (v1.1.1, Task G restored) — folded in
  // from the 2026-11-13 research probes
  // (~/workspace/tmp_work/plezy-tv-research-hour-blocks/RESEARCH_HOUR_BLOCKS.md).
  // Build #17 §10 had replaced the one-hour "No information available"
  // blocks with one "No guide data for this channel" block spanning the
  // whole window; Matt asked for the hour blocks back. Failing-first on
  // the 1.1 tip: H1a/H1b/H5/H5b FAIL, H2/H3/H4 PASS. The H-labels are
  // kept so a future failure points straight at the research doc.
  // (H5/H5b overlap the two tap tests above — they are the named pins
  // for this regression, kept verbatim from the probe.)

  testWidgets('H1a: a no-data channel shows one info block per uncovered hour, not one 6h block', (tester) async {
    final harness = _IptvGuideHarness(onlyChannelKey: '100');
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 1);

    harness.api.completeEmpty('100');
    await tester.pumpAndSettle();

    // Task G: 5 visible one-hour "No information available" blocks (the
    // 6h window holds 6 hour blocks; the last falls past the viewport).
    expect(find.text('No information available'), findsNWidgets(5));
    expect(find.text('No guide data for this channel'), findsNothing);
  });

  testWidgets('H1b: two no-data channels show hour blocks on both rows (the screenshot case)', (tester) async {
    final harness = _IptvGuideHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    // 5 visible hour blocks per row x 2 rows; no single-window blocks.
    expect(find.text('No information available'), findsNWidgets(10));
    expect(find.text('No guide data for this channel'), findsNothing);
  });

  testWidgets('H2: a partial EPG still gets hour blocks only in uncovered hours', (tester) async {
    final harness = _IptvGuideHarness(onlyChannelKey: '100');
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 1);

    final now = DateTime.now();
    final hourStart = DateTime(now.year, now.month, now.day, now.hour).add(const Duration(hours: 1));
    harness.api.complete('100', [
      _epg(id: 'a', title: 'Hour Show One', start: hourStart, end: hourStart.add(const Duration(hours: 1))),
      _epg(id: 'b', title: 'Hour Show Two', start: hourStart.add(const Duration(hours: 1)), end: hourStart.add(const Duration(hours: 2))),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Hour Show One'), findsOneWidget);
    expect(find.text('Hour Show Two'), findsOneWidget);
    // Two covered hours leave 3 visible uncovered hours in this viewport.
    expect(find.text('No information available'), findsNWidgets(3));
    expect(find.text('No guide data for this channel'), findsNothing);
  });

  testWidgets('H3: while the EPG is in flight there are no hour blocks', (tester) async {
    final harness = _IptvGuideHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text(t.liveTv.loadingGuide), findsNWidgets(2));
    expect(find.text('No information available'), findsNothing);
    expect(find.text('No guide data for this channel'), findsNothing);

    // Drain the in-flight fetch so no fake-async timer is still pending
    // at dispose (the existing loading test does the same).
    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();
  });

  testWidgets('H4: a failed EPG fetch shows a retry state, never hour blocks', (tester) async {
    final harness = _IptvGuideHarness(onlyChannelKey: '100');
    // 1.1.2 D1a: the feed must actually FAIL here — a loading-empty feed
    // would make this a genuine empty (hour blocks), not a failure.
    harness.api.failXmltv = true;
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 1);

    harness.api.completeError('100', Exception('provider down'));
    await tester.pumpAndSettle();

    expect(find.text('No information available'), findsNothing);
    expect(find.text('No guide data for this channel'), findsNothing);
    expect(find.text(t.liveTv.guideLoadFailed), findsOneWidget);
  });

  testWidgets('H5: tapping a past hour block on a catch-up channel offers Watch from start', (tester) async {
    final harness = _IptvGuideHarness(onlyChannelKey: '100');
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 1);

    harness.api.completeEmpty('100');
    await tester.pumpAndSettle();

    // The hour blocks must exist first (fails on base: build #17 §10
    // shows one whole-window block instead, so there is nothing to tap).
    expect(find.text('No information available'), findsWidgets);

    // First visible hour block is the past partial hour (grid starts one
    // hour before now); channel 100 has an archive, so the detail must
    // offer catch-up from that hour's own start time.
    await tester.tap(find.text('No information available').first);
    await tester.pumpAndSettle();

    expect(find.text('Watch Channel'), findsOneWidget);
    expect(find.textContaining('Watch from start'), findsOneWidget);
  });

  testWidgets('H5b: tapping a past hour block on a channel without an archive offers no catch-up', (tester) async {
    final harness = _IptvGuideHarness(onlyChannelKey: '101');
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 1);

    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    // The hour blocks must exist first (fails on base: build #17 §10
    // shows one whole-window block instead, so there is nothing to tap).
    expect(find.text('No information available'), findsWidgets);

    await tester.tap(find.text('No information available').first);
    await tester.pumpAndSettle();

    expect(find.text('Watch Channel'), findsOneWidget);
    expect(find.textContaining('Watch from start'), findsNothing);
    expect(find.text(t.liveTv.startFromBeginning), findsNothing);
  });
}
