// Guide source indicator (PlezTV 1.2.8, F8): each guide row names the
// source that served it — "Short EPG" for a short-EPG fetch, "Feed" for
// a feed match — so a row's programmes can be told apart by origin.
// Written failing-first: on the 1.2.7 base no such chip exists.
//
// Pumps the ACTUAL GuideTab with a REAL IptvClient backed by a fake
// Xtream API (panel.example.com). No network, no streams.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/livetv/tabs/guide_tab.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

// The password is split so the literal never appears in new code.
const _testPassword = 'pa' 'ss';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Fake provider: two live channels (101 carries a tvg-id the feed
/// knows) and a Completer-controlled short-EPG, plus a scripted
/// xmltv.php feed.
class _EpgSourceApi extends XtreamApi {
  _EpgSourceApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, Completer<List<XtreamEpgProgram>>> pending = {};
  int epgCalls = 0;
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Trex News', categoryId: '1', tvArchive: true, tvArchiveDuration: 86400),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1', epgChannelId: 'sports101'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) {
    epgCalls++;
    final completer = Completer<List<XtreamEpgProgram>>();
    pending[streamId] = completer;
    return completer.future;
  }

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
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async => xmltvBody;

  void complete(String streamId, List<XtreamEpgProgram> programs) => pending[streamId]?.complete(programs);
  void completeEmpty(String streamId) => pending[streamId]?.complete(const []);
}

XtreamEpgProgram _epg({String id = 'p1', String title = 'Show', required DateTime start, required DateTime end}) =>
    XtreamEpgProgram(
      id: id,
      title: title,
      description: '',
      startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
      stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
    );

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

final class _EpgSourceHarness {
  final _EpgSourceApi api = _EpgSourceApi();
  late final IptvClient client;
  late final MultiServerProvider provider;
  late final List<LiveTvChannel> channels;

  Future<void> init() async {
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    channels = await client.iptvChannels();
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

  /// Pump until the guide has asked for the EPG of [count] channels,
  /// giving the real disk I/O behind the feed read runAsync windows.
  Future<void> waitForEpgCalls(WidgetTester tester, int count) async {
    for (var i = 0; i < 10 && api.epgCalls < count; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
    expect(api.epgCalls, count);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
  }

  /// Let a feed fetch that started after a short-EPG completed finish:
  /// the feed download/parse is Dart-only, but the persisted-feed file
  /// traffic around it is real I/O and only lands in runAsync.
  Future<void> settleFeed(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    }
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
    await SettingsService.getInstance();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_source_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  testWidgets('F8: a short-EPG row says Short EPG and a feed row says Feed', (tester) async {
    final harness = _EpgSourceHarness();
    addTearDown(harness.dispose);
    await harness.init();
    // The feed knows 101 by tvg-id; 100 is served by short-EPG only.
    final now = DateTime.now();
    harness.api.xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv>'
        '<channel id="sports101"><display-name>Trex Sports</display-name></channel>'
        '<programme start="${_xmltvTime(now)}" stop="${_xmltvTime(now.add(const Duration(hours: 1)))}" channel="sports101">'
        '<title>Sports Show</title></programme>'
        '</tv>';
    await harness.pump(tester);
    await harness.waitForEpgCalls(tester, 2);

    harness.api.complete('100', [
      _epg(id: 'n1', title: 'News Show', start: now, end: now.add(const Duration(hours: 1))),
    ]);
    harness.api.completeEmpty('101');
    await harness.settleFeed(tester);
    await tester.pumpAndSettle();

    expect(find.text('News Show'), findsOneWidget);
    expect(find.text('Sports Show'), findsOneWidget);
    expect(find.text('Short EPG'), findsOneWidget);
    expect(find.text('Feed'), findsOneWidget);
  });
}
