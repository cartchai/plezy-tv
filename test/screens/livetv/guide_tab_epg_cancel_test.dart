// Build #28 — guide row scrolled away cancels its EPG fetch (v1.0.9).
//
// A guide row's lifecycle owns its channel's EPG fetch: when the row
// scrolls out of the viewport the sliver disposes it, and the dispose
// cancels the in-flight short-EPG fetch instead of letting it run to
// completion unobserved. This test proves it with the real [GuideTab]
// and a real [IptvClient]: thirty channels, the first rows' fetches in
// flight, then a real scroll down — the top row's fetch is aborted at
// the fake panel, while the row scrolled to keeps its fetch and the
// guide keeps fetching for newly visible rows.
//
// Failing-first: on the base (6fe84db64) there is no row lifecycle and no
// per-channel cancel, so the scrolled-away row's fetch is never aborted
// — the "aborted contains 100" assertion fails there. No live panel:
// fake API only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/exceptions/media_server_exceptions.dart';
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

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: 'pa' 'ss',
  createdAt: DateTime.utc(2026, 11, 6),
);

/// Fake provider: thirty live channels and a short-EPG that only resolves
/// when the test completes it — plus an abort observer: when the support
/// cancels a channel's fetch, the abort trigger fires and the channel is
/// recorded in [aborted].
class _EpgControllableApi extends XtreamApi {
  _EpgControllableApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final Map<String, Completer<List<XtreamEpgProgram>>> pending = {};
  final Set<String> aborted = {};
  int epgCalls = 0;

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => [
    for (var i = 0; i < 30; i++)
      XtreamLiveStream(streamId: 100 + i, name: 'Channel ${100 + i}', categoryId: '1'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) {
    epgCalls++;
    final completer = Completer<List<XtreamEpgProgram>>();
    pending[streamId] = completer;
    // The abort trigger is the support's per-channel AbortController: when
    // the row is disposed the controller fires and this future completes.
    // Race it like the real API's AbortableRequest does at the socket, so
    // the support sees the cancellation, releases its concurrency slot,
    // and the queued fetches for newly visible rows can start.
    unawaited(
      abortTrigger?.then((_) {
        aborted.add(streamId);
        if (!completer.isCompleted) {
          completer.completeError(
            MediaServerHttpException(type: MediaServerHttpErrorType.cancelled, message: 'Operation cancelled'),
          );
        }
      }),
    );
    return completer.future;
  }

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
    throw Exception('xmltv feed unavailable in guide tests');
  }

  void completeEmpty(String streamId) {
    final completer = pending[streamId];
    if (completer != null && !completer.isCompleted) completer.complete(const []);
  }
}

final class _IptvGuideHarness {
  final _EpgControllableApi api = _EpgControllableApi();
  late final IptvClient client;
  late final MultiServerProvider provider;
  late final List<LiveTvChannel> channels;

  Future<void> init() async {
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    channels = await client.iptvChannels();
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    provider = testMultiServerProvider(manager)
      ..debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: 'trex', dvrKey: 'dvr-trex')]);
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

  /// Pump until the guide has asked for the EPG of [count] channels (same
  /// real-I/O window as guide_tab_iptv_test.dart — the EPG fetch reads the
  /// persisted cache from disk, which only completes in runAsync).
  Future<void> waitForEpgCalls(WidgetTester tester, int count) async {
    for (var i = 0; i < 30 && api.epgCalls < count; i++) {
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
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_guide_cancel_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  testWidgets('a guide row scrolled away cancels its in-flight EPG fetch', (tester) async {
    final harness = _IptvGuideHarness();
    addTearDown(harness.dispose);
    await harness.init();
    expect(harness.channels, hasLength(30));
    await harness.pump(tester);
    // The short-EPG concurrency cap is 4: only the first four visible
    // rows' fetches start, the rest queue in the support.
    await harness.waitForEpgCalls(tester, 4);
    expect(harness.api.pending.keys, contains('100'), reason: 'the first row fetches first');
    expect(harness.api.aborted, isEmpty);

    final callsBeforeScroll = harness.api.epgCalls;

    // Scroll down until a far row is visible: the top rows leave the
    // viewport (and the cache extent) and the sliver disposes them. Drag
    // the program grid's scrollable (the last CustomScrollView — the
    // channel column comes first in the tree).
    await tester.drag(find.byType(CustomScrollView).last, const Offset(0, -900));
    await tester.pump();
    // Let the aborts propagate and the released concurrency slots feed
    // the queued fetches for the newly visible rows (real time — the
    // support's fetch chain settles outside the fake zone).
    for (var i = 0; i < 20 && harness.api.epgCalls <= callsBeforeScroll; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    }

    expect(
      harness.api.aborted,
      contains('100'),
      reason: 'the scrolled-away row must cancel its in-flight EPG fetch',
    );
    expect(
      harness.api.aborted,
      isNot(contains('124')),
      reason: 'the row scrolled to must keep its fetch',
    );
    expect(
      harness.api.epgCalls,
      greaterThan(callsBeforeScroll),
      reason: 'the guide keeps fetching for newly visible rows',
    );

    // Clean up: complete the surviving fetches so the tree settles.
    // Bounded pumps, not pumpAndSettle — the guide's 15 s first-paint
    // timers for still-queued rows keep firing and pumpAndSettle never
    // drains them.
    for (final key in harness.api.pending.keys.toList()) {
      harness.api.completeEmpty(key);
    }
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
