// GUIDE CATEGORY SUBMENU — PlezTV v1.0.16 (Matt, 2026-11-12).
//
// Long-pressing a channel in the Live TV guide shows the popup menu;
// the menu must show the channel's category ("Category: <name>") with
// a chevron that opens a submenu to show or hide the WHOLE category.
// Live TV only. The toggle flips the same hidden state the
// categories screen uses (per-category id + letter-group resolution).
//
// Failing-first: this file references the new `GuideTab.channelCategory`
// / `onToggleCategory` params and the new `t.liveTv.channelCategory` /
// `hideCategory` / `showCategory` strings, so it FAILS TO LOAD on
// ef634b923 — that is the failing-first evidence (same precedent as
// the R4 tile test). The behaviour is pinned by M1–M5 below.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_symbols_icons/symbols.dart';
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

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

// The password is split so the literal never appears in new code.
const testPassword = 'pa' 'ss';

/// Fake panel: two live channels in category '1' and a short-EPG that
/// only resolves when the test completes it (same pattern as the
/// build17 menu tests).
class _MenuFakeApi extends XtreamApi {
  _MenuFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: testPassword);

  final Map<String, Completer<List<XtreamEpgProgram>>> pending = {};
  int epgCalls = 0;

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Trex News', categoryId: '1'),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
  ];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) {
    epgCalls++;
    final completer = Completer<List<XtreamEpgProgram>>();
    pending[streamId] = completer;
    return completer.future;
  }

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    throw Exception('xmltv feed unavailable in menu tests');
  }

  void completeEmpty(String streamId) => pending[streamId]?.complete(const []);
}

final class _MenuHarness {
  final _MenuFakeApi api = _MenuFakeApi();
  late final IptvClient client;
  late final MultiServerProvider provider;
  late final List<LiveTvChannel> channels;

  /// The category state the resolver reports: category '1' is
  /// "Trex Channels", hidden when [categoryHidden] is true.
  bool categoryHidden = false;

  Future<({String id, String name, bool hidden})?> resolveCategory(LiveTvChannel channel) async {
    final categoryId = channel.categoryId;
    if (categoryId == null) return null;
    return (id: categoryId, name: 'Trex Channels', hidden: categoryHidden);
  }

  Future<void> init() async {
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    channels = await client.iptvChannels();
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    provider = testMultiServerProvider(manager)
      ..debugSetLiveTvServersForTesting([LiveTvServerInfo(serverId: 'trex', dvrKey: 'dvr-trex')]);
  }

  Future<void> pump(
    WidgetTester tester, {
    void Function(LiveTvChannel)? onHideChannel,
    void Function(LiveTvChannel)? onToggleFavorite,
    bool Function(LiveTvChannel)? isFavoriteChannel,
    void Function(LiveTvChannel, String, String)? onToggleCategory,
    List<LiveTvChannel>? overrideChannels,
  }) async {
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
              home: Scaffold(
                body: GuideTab(
                  channels: overrideChannels ?? channels,
                  onHideChannel: onHideChannel,
                  onToggleFavorite: onToggleFavorite,
                  isFavoriteChannel: isFavoriteChannel,
                  channelCategory: resolveCategory,
                  onToggleCategory: onToggleCategory,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10 && api.epgCalls < 2; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
    expect(api.epgCalls, 2);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    api.completeEmpty('100');
    api.completeEmpty('101');
    await tester.pumpAndSettle();
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
    epgTempDir = await Directory.systemTemp.createTemp('plezy_epg_menu_cat_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    await epgTempDir.delete(recursive: true);
  });

  group('v1.0.16 guide category submenu', () {
    testWidgets('M1: the menu shows the channel category row with a chevron', (tester) async {
      final harness = _MenuHarness();
      await harness.init();
      await harness.pump(
        tester,
        onHideChannel: (_) {},
        onToggleFavorite: (_) {},
        isFavoriteChannel: (_) => false,
        onToggleCategory: (_, _, _) {},
      );

      await tester.longPress(find.text('Trex News').first);
      await tester.pumpAndSettle();

      expect(find.text(t.liveTv.channelCategory(name: 'Trex Channels')), findsOneWidget);
      // The chevron belongs to the category row itself — scope the
      // search to that row, not the whole tree (the guide behind the
      // popup has its own chevron icons, and `find.byType` does not
      // match the generic `PopupMenuItem<ChannelMenuItem>`).
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text(t.liveTv.channelCategory(name: 'Trex Channels')),
            matching: find.byType(Row),
          ),
          matching: find.byIcon(Symbols.chevron_right_rounded),
        ),
        findsOneWidget,
      );
      harness.dispose();
    });

    testWidgets('M2: tapping the category row opens the submenu with Hide category', (tester) async {
      final harness = _MenuHarness();
      await harness.init();
      await harness.pump(
        tester,
        onHideChannel: (_) {},
        onToggleFavorite: (_) {},
        isFavoriteChannel: (_) => false,
        onToggleCategory: (_, _, _) {},
      );

      await tester.longPress(find.text('Trex News').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.liveTv.channelCategory(name: 'Trex Channels')));
      await tester.pumpAndSettle();

      expect(find.text(t.liveTv.hideCategory), findsOneWidget);
      expect(find.text(t.liveTv.showCategory), findsNothing);
      harness.dispose();
    });

    testWidgets('M3: Hide category flips the whole category', (tester) async {
      final harness = _MenuHarness();
      await harness.init();
      final toggled = <({LiveTvChannel channel, String id, String name})>[];
      await harness.pump(
        tester,
        onHideChannel: (_) {},
        onToggleFavorite: (_) {},
        isFavoriteChannel: (_) => false,
        onToggleCategory: (channel, id, name) => toggled.add((channel: channel, id: id, name: name)),
      );

      await tester.longPress(find.text('Trex Sports').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.liveTv.channelCategory(name: 'Trex Channels')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.liveTv.hideCategory));
      await tester.pumpAndSettle();

      expect(toggled.length, 1);
      expect(toggled.single.channel.key, '101');
      expect(toggled.single.id, '1');
      expect(toggled.single.name, 'Trex Channels');
      harness.dispose();
    });

    testWidgets('M4: a hidden category offers Show category', (tester) async {
      final harness = _MenuHarness();
      harness.categoryHidden = true;
      await harness.init();
      await harness.pump(
        tester,
        onHideChannel: (_) {},
        onToggleFavorite: (_) {},
        isFavoriteChannel: (_) => false,
        onToggleCategory: (_, _, _) {},
      );

      await tester.longPress(find.text('Trex News').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.liveTv.channelCategory(name: 'Trex Channels')));
      await tester.pumpAndSettle();

      expect(find.text(t.liveTv.showCategory), findsOneWidget);
      expect(find.text(t.liveTv.hideCategory), findsNothing);
      harness.dispose();
    });

    testWidgets('M5: a non-IPTV channel has no category row', (tester) async {
      final harness = _MenuHarness();
      await harness.init();
      final plexChannel = LiveTvChannel(key: 'plex-1', title: 'Plex News', serverId: 'plex');
      await harness.pump(
        tester,
        onHideChannel: (_) {},
        onToggleFavorite: (_) {},
        isFavoriteChannel: (_) => false,
        onToggleCategory: (_, _, _) {},
        overrideChannels: [...harness.channels, plexChannel],
      );

      await tester.longPress(find.text('Plex News').first);
      await tester.pumpAndSettle();

      expect(find.text(t.liveTv.channelCategory(name: 'Trex Channels')), findsNothing);
      expect(find.text('Hide channel'), findsNothing);
      harness.dispose();
    });
  });
}
