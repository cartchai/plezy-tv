import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
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
///   available" block per hour of the guide window (and only in the hours
///   a partial EPG leaves uncovered); tapping one opens the program detail,
///   with a catch-up action only where the channel offers it.

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

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async => const [
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
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout}) {
    epgCalls++;
    final completer = Completer<List<XtreamEpgProgram>>();
    pending[streamId] = completer;
    return completer.future;
  }

  void complete(String streamId, List<XtreamEpgProgram> programs) =>
      pending[streamId]?.complete(programs);

  void completeEmpty(String streamId) => pending[streamId]?.complete(const []);
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
  Future<void> waitForEpgCalls(WidgetTester tester, int count) async {
    for (var i = 0; i < 10 && api.epgCalls < count; i++) {
      await tester.pump();
    }
    expect(api.epgCalls, count);
  }

  void dispose() => provider.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));
  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  testWidgets('loading indicator shows while the EPG is in flight, never hour blocks', (tester) async {
    final harness = _IptvGuideHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    // The thin header bar — not a full-screen spinner — and no
    // placeholders pretending the load already finished empty.
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('No information available'), findsNothing);

    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    // 5 hour blocks per row are in the tree at this viewport (1280px wide,
    // 180px slots + one slot of overscan) — the rest are virtualized away.
    expect(find.text('No information available'), findsNWidgets(10));
  });

  testWidgets('channel with no EPG renders one hour block per hour of the window', (tester) async {
    final harness = _IptvGuideHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    // Two channels x 5 visible hour blocks per row (see the loading test
    // above for why 5, not 6-7: the row virtualizes past the viewport).
    expect(find.text('No information available'), findsNWidgets(10));
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
    // viewport); channel 101 lost none: 3 + 5 = 8 blocks.
    expect(find.text('No information available'), findsNWidgets(8));
  });

  testWidgets('tapping a no-information block opens the detail with catch-up', (tester) async {
    final harness = _IptvGuideHarness();
    addTearDown(harness.dispose);
    await harness.init();
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    harness.api.completeEmpty('100');
    harness.api.completeEmpty('101');
    await tester.pumpAndSettle();

    // First block belongs to channel 100 (catch-up) and is in the past.
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

    expect(find.text('Watch Channel'), findsOneWidget);
    expect(find.textContaining('Watch from start'), findsNothing);
  });
}
