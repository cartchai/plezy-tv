import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/libraries/libraries_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/overlay_sheet.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/download_fixtures.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

/// The library header Matt reported on the Fold 7 cover screen
/// (build #12, Task 2): "trex — Movies" plus the edit / heart / filter /
/// refresh actions overflowed by 5 pixels, producing the yellow/black
/// OVERFLOWED debug banner. The banner only renders in debug builds, but
/// the layout bug is real: the title row must fit at narrow phone width
/// with every action reachable.
const _trexMovies = MediaLibrary(
  id: 'trex-movies',
  backend: MediaBackend.xtream,
  title: 'trex — Movies',
  kind: MediaKind.movie,
  serverId: 'trex',
  serverName: 'trex',
);

const _plexMovies = MediaLibrary(
  id: 'plex-movies',
  backend: MediaBackend.plex,
  title: 'Plex Movies',
  kind: MediaKind.movie,
  serverId: 'plex-server',
  serverName: 'HOME PC',
);

/// Minimal fake provider: the browse tab only needs empty catalogs to
/// render the header; anything else throws and lands in the tab's caught
/// error state, which never touches the app bar.
class _EmptyXtreamApi extends XtreamApi {
  _EmptyXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async => const [];

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
    throw Exception('xmltv feed unavailable in header tests');
  }
}

final class _HeaderHarness {
  _HeaderHarness({required this.libraries, required this.hiddenLibraries, required this.multiServer});

  final LibrariesProvider libraries;
  final HiddenLibrariesProvider hiddenLibraries;
  final MultiServerProvider multiServer;

  static Future<_HeaderHarness> create() async {
    await SettingsService.getInstance();
    await StorageService.getInstance();
    final libraries = LibrariesProvider();
    await libraries.updateLibraryOrder(const [_trexMovies, _plexMovies]);
    final hiddenLibraries = HiddenLibrariesProvider();
    await hiddenLibraries.ensureInitialized();

    final client = IptvClient.xtream(
      xtreamConnection: XtreamConnection(
        id: 'trex',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pa' 'ss',
        createdAt: DateTime.utc(2026, 11, 6),
      ),
    );
    client.testXtreamApi = _EmptyXtreamApi();
    final manager = MultiServerManager()..debugRegisterClientForTesting(client);
    final multiServer = testMultiServerProvider(manager);
    return _HeaderHarness(libraries: libraries, hiddenLibraries: hiddenLibraries, multiServer: multiServer);
  }

  Future<void> pump(WidgetTester tester) async {
    final downloads = NoSyncRulesDownloadProvider();
    addTearDown(downloads.dispose);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<LibrariesProvider>.value(value: libraries),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibraries),
          ChangeNotifierProvider<MultiServerProvider>.value(value: multiServer),
          ChangeNotifierProvider<DownloadProvider>.value(value: downloads),
        ],
        child: InputModeTracker(
          // The platform comes from the theme, not the global
          // debugDefaultTargetPlatformOverride (the binding verifies that
          // debug variable before any tearDown runs, so a global override
          // set in setUp fails the test even when reset in tearDown).
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark).copyWith(platform: TargetPlatform.android),
            home: const OverlaySheetHost(child: LibrariesScreen()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void dispose() {
    libraries.dispose();
    hiddenLibraries.dispose();
    multiServer.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    TvDetectionService.debugSetAppleTVOverride(false);
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
    IptvCatalogDiskCache.debugDisableDisk = false;
  });

  testWidgets('library header fits at narrow phone width with all four actions', (tester) async {
    final harness = await _HeaderHarness.create();
    addTearDown(harness.dispose);
    await harness.pump(tester);

    // The trex library is first in the order, so the screen selects it.
    expect(find.text('trex — Movies'), findsOneWidget);
    expect(find.text('trex'), findsWidgets);

    // Switch to the Browse tab: the filter (tune) action only renders
    // there, and the reported overflow had all four actions visible.
    final dynamic state = tester.state(find.byType(LibrariesScreen));
    final TabController tabController = state.tabController as TabController;
    tabController.index = 1;
    await tester.pumpAndSettle();

    expect(find.byTooltip(t.libraries.manageLibraries), findsOneWidget);
    expect(find.byTooltip(t.iptv.favorites.title), findsOneWidget);
    expect(find.byTooltip(t.libraries.libraryOptions), findsOneWidget);
    expect(find.byTooltip(t.common.refresh), findsOneWidget);

    // A RenderFlex overflow is reported as a FlutterError during pump;
    // takeException surfaces it here. Before the fix this is the
    // "OVERFLOWED BY 5 PIXELS" banner from Matt's screenshot.
    expect(tester.takeException(), isNull);
  });
}
