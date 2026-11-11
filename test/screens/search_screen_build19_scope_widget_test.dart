import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/dpad_navigator.dart';
import 'package:plezy/focus/key_event_utils.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/media/media_person.dart';
import 'package:plezy/media/media_server_client.dart';
import 'package:plezy/media/server_capabilities.dart';
import 'package:plezy/mixins/refreshable.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/search_screen.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/focusable_tab_chip.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/media_items.dart';
import '../test_helpers/multi_server_fixtures.dart';

/// Build #19 widget probe — the closest harness reproduction of Matt's
/// phone screenshot (v1.0.0-2.25.0, 2026-11-09 ~03:48 EST): query "game
/// of", scope chip "Trex — Series" selected, the ONLY result is the PLEX
/// movie "Sherlock Holmes: A Game of Shadows" from HOME PC · Movies, and
/// no Trex series rows at all.
///
/// The service-level probes (iptv_build19_probes_test.dart) prove the
/// aggregation drops the Plex row when the scope key is passed. These
/// widget tests prove the REAL SearchScreen passes that key: they pump the
/// real screen with a Plex fake + a Trex fake, tap the real scope chip,
/// type the real partial query, and assert no Plex rows appear.
///
/// The Plex fake models a backend that IGNORES excludedLibraryIds entirely
/// (returns its rows regardless) — the worst case, and the old
/// PlexClient's behaviour. If the screen or aggregation failed to enforce
/// the scope, Sherlock would show up here exactly as on the phone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  setUp(() async {
    _resetGlobalTestState();
    resetSharedPreferencesForTest();
    await SettingsService.getInstance();
    await StorageService.getInstance();
  });

  tearDown(_resetGlobalTestState);

  testWidgets(
    'scoped Trex — Series search hides an ATTRIBUTED Plex movie when the '
    'provider list holds Trex libraries only (Hole B)',
    (tester) async {
      // Hole B shape: the provider list never contained the Plex
      // libraries, so hiddenKeys cannot exclude Plex at all. Only the
      // explicit scope key stands between Sherlock and the results.
      final (key, _, _) = await _pumpScopeSearchScreen(
        tester,
        plexItems: [_attributedSherlock()],
        trexItems: [_trexGameOfThrones()],
        libraries: [_trexMoviesLibrary(), _trexSeriesLibrary()],
      );
      await tester.pumpAndSettle();

      // Phone flow: the scope chip is selected, then the query is typed.
      await tester.tap(find.widgetWithText(FocusableTabChip, 'Trex — Series'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FocusableTabChip>(find.widgetWithText(FocusableTabChip, 'Trex — Series')).isSelected,
        isTrue,
      );

      (key.currentState! as SearchInputFocusable).submitSearchQuery('game of');
      await tester.pumpAndSettle();

      expect(find.text('EN - Game Of Thrones (2011)'), findsOneWidget);
      expect(find.text('Sherlock Holmes: A Game of Shadows'), findsNothing);
    },
  );

  testWidgets(
    'scoped Trex — Series search hides an UNATTRIBUTED Plex movie with '
    'the full library list (Hole A)',
    (tester) async {
      // Hole A shape: every library is in the provider list, so Plex IS
      // in hiddenKeys — but the row carries no section id, so the
      // hidden-library filter keeps it by design. Only the explicit
      // scope key drops it.
      final (key, _, _) = await _pumpScopeSearchScreen(
        tester,
        plexItems: [_unattributedSherlock()],
        trexItems: [_trexGameOfThrones()],
        libraries: [
          _trexMoviesLibrary(),
          _trexSeriesLibrary(),
          _plexMoviesLibrary(),
          _plexTvShowsLibrary(),
        ],
      );
      await tester.pumpAndSettle();

      // Type first (unscoped shows both — the leak, pre-scope), then tap
      // the chip: a scope change mid-typing must re-run scoped.
      (key.currentState! as SearchInputFocusable).submitSearchQuery('game of');
      await tester.pumpAndSettle();
      expect(find.text('EN - Game Of Thrones (2011)'), findsOneWidget);
      expect(find.text('Sherlock Holmes: A Game of Shadows'), findsOneWidget);

      await tester.tap(find.widgetWithText(FocusableTabChip, 'Trex — Series'));
      await tester.pumpAndSettle();

      expect(find.text('EN - Game Of Thrones (2011)'), findsOneWidget);
      expect(find.text('Sherlock Holmes: A Game of Shadows'), findsNothing);
    },
  );

  testWidgets('unscoped search shows both rows (control)', (tester) async {
    final (key, _, _) = await _pumpScopeSearchScreen(
      tester,
      plexItems: [_unattributedSherlock()],
      trexItems: [_trexGameOfThrones()],
      libraries: [
        _trexMoviesLibrary(),
        _trexSeriesLibrary(),
        _plexMoviesLibrary(),
        _plexTvShowsLibrary(),
      ],
    );
    await tester.pumpAndSettle();

    (key.currentState! as SearchInputFocusable).submitSearchQuery('game of');
    await tester.pumpAndSettle();

    expect(find.text('EN - Game Of Thrones (2011)'), findsOneWidget);
    expect(find.text('Sherlock Holmes: A Game of Shadows'), findsOneWidget);
  });
}

/// The Plex movie from the phone screenshot: "Sherlock Holmes: A Game of
/// Shadows", PG-13 · 2011, HOME PC · Movies. Attributed shape: it carries
/// librarySectionID "1" (Plex Movies).
MediaItem _attributedSherlock() => testMediaItem(
  id: 'sherlock',
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  title: 'Sherlock Holmes: A Game of Shadows',
  serverId: 'plex-server',
  serverName: 'HOME PC',
  libraryId: '1',
  libraryTitle: 'Movies',
);

/// Same movie, external/shared shape: it carries a library TITLE but no
/// section id, so no filter can attribute it to a library.
MediaItem _unattributedSherlock() => testMediaItem(
  id: 'sherlock',
  backend: MediaBackend.plex,
  kind: MediaKind.movie,
  title: 'Sherlock Holmes: A Game of Shadows',
  serverId: 'plex-server',
  serverName: 'HOME PC',
  libraryTitle: 'Movies',
);

/// The Trex series row the phone search must find. Backend is plex only
/// because testMediaItem has no xtream case yet — scope filtering keys
/// off serverId + libraryId (libraryGlobalKey), never the item backend,
/// so the row is still attributable to Trex — Series exactly as the real
/// XtreamMediaItem would be.
MediaItem _trexGameOfThrones() => testMediaItem(
  id: 'got',
  backend: MediaBackend.plex,
  kind: MediaKind.show,
  title: 'EN - Game Of Thrones (2011)',
  serverId: 'conn-xt-1',
  serverName: 'Trex',
  libraryId: 'iptv:conn-xt-1:series',
  libraryTitle: 'Trex — Series',
);

MediaLibrary _trexMoviesLibrary() => const MediaLibrary(
  id: 'iptv:conn-xt-1:movies',
  backend: MediaBackend.xtream,
  title: 'Trex — Movies',
  kind: MediaKind.movie,
  serverId: 'conn-xt-1',
  serverName: 'Trex',
);

MediaLibrary _trexSeriesLibrary() => const MediaLibrary(
  id: 'iptv:conn-xt-1:series',
  backend: MediaBackend.xtream,
  title: 'Trex — Series',
  kind: MediaKind.show,
  serverId: 'conn-xt-1',
  serverName: 'Trex',
);

MediaLibrary _plexMoviesLibrary() => const MediaLibrary(
  id: '1',
  backend: MediaBackend.plex,
  title: 'Movies',
  kind: MediaKind.movie,
  serverId: 'plex-server',
  serverName: 'HOME PC',
);

MediaLibrary _plexTvShowsLibrary() => const MediaLibrary(
  id: '2',
  backend: MediaBackend.plex,
  title: 'TV Shows',
  kind: MediaKind.show,
  serverId: 'plex-server',
  serverName: 'HOME PC',
);

/// Pumps the real SearchScreen with a Plex fake + a Trex fake registered
/// in the MultiServerManager and [libraries] in the LibrariesProvider.
/// Modeled on _pumpTvSearchScreen in search_screen_test.dart.
Future<(GlobalKey<State<SearchScreen>>, _Build19ScopeFakeClient, _Build19ScopeFakeClient)>
_pumpScopeSearchScreen(
  WidgetTester tester, {
  required List<MediaItem> plexItems,
  required List<MediaItem> trexItems,
  required List<MediaLibrary> libraries,
}) async {
  TvDetectionService.debugSetAppleTVOverride(true);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 720);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  final plexClient = _Build19ScopeFakeClient(
    serverIdValue: 'plex-server',
    serverNameValue: 'HOME PC',
    backendValue: MediaBackend.plex,
    items: plexItems,
  );
  final trexClient = _Build19ScopeFakeClient(
    serverIdValue: 'conn-xt-1',
    serverNameValue: 'Trex',
    backendValue: MediaBackend.xtream,
    items: trexItems,
  );
  final manager = MultiServerManager();
  manager.debugRegisterClientForTesting(plexClient);
  manager.debugRegisterClientForTesting(trexClient);
  final provider = testMultiServerProvider(manager);
  addTearDown(provider.dispose);

  final hiddenLibraries = HiddenLibrariesProvider();
  addTearDown(hiddenLibraries.dispose);

  final librariesProvider = LibrariesProvider();
  addTearDown(librariesProvider.dispose);
  await librariesProvider.updateLibraryOrder(libraries);

  final key = GlobalKey<State<SearchScreen>>();
  await tester.pumpWidget(
    TranslationProvider(
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
          ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hiddenLibraries),
          ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
        ],
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: SearchScreen(key: key),
        ),
      ),
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  return (key, plexClient, trexClient);
}

/// Minimal fake server client: returns its rows for every query and
/// IGNORES [excludedLibraryIds] entirely — the worst case for scope
/// enforcement, and the old PlexClient's behaviour. The scope key in the
/// aggregation is the only thing that can keep its rows out of a scoped
/// search.
class _Build19ScopeFakeClient implements MediaServerClient {
  final String serverIdValue;
  final String serverNameValue;
  final MediaBackend backendValue;
  final List<MediaItem> items;

  _Build19ScopeFakeClient({
    required this.serverIdValue,
    required this.serverNameValue,
    required this.backendValue,
    required this.items,
  });

  @override
  ServerId get serverId => ServerId(serverIdValue);

  @override
  String? get serverName => serverNameValue;

  @override
  MediaBackend get backend => backendValue;

  @override
  ServerCapabilities get capabilities => ServerCapabilities.plex;

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
    bool onlineAllowed = false,
  }) async {
    abort?.throwIfAborted();
    return items;
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async => const [];

  @override
  Future<List<MediaLibrary>> fetchLibraries() async => const [];

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _resetGlobalTestState() {
  FocusManager.instance.primaryFocus?.unfocus();
  HardwareKeyboard.instance.clearState();
  SelectKeyUpSuppressor.clearSuppression();
  BackKeyUpSuppressor.clearSuppression();
  BackKeyCoordinator.clear();
  TvDetectionService.debugSetAppleTVOverride(null);
  TvDetectionService.setForceTVSync(false);
  SettingsService.resetForTesting();
}
