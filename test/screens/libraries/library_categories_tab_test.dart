import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_library.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/screens/hub_detail_screen.dart';
import 'package:plezy/screens/libraries/libraries_screen.dart';
import 'package:plezy/screens/libraries/tabs/library_categories_tab.dart';
import 'package:plezy/services/iptv/iptv_item_favorites_repository.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/library_tab_scaffold.dart';
import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

const _testPassword = 'pa' 'ss';

final _moviesLibrary = MediaLibrary(
  id: 'iptv:conn-xt-1:movies',
  backend: MediaBackend.xtream,
  title: 'Trex — Movies',
  kind: MediaKind.movie,
  serverId: 'conn-xt-1',
  serverName: 'Trex',
);

final _seriesLibrary = MediaLibrary(
  id: 'iptv:conn-xt-1:series',
  backend: MediaBackend.xtream,
  title: 'Trex — Series',
  kind: MediaKind.show,
  serverId: 'conn-xt-1',
  serverName: 'Trex',
);

/// Fake Xtream API returning a canned catalog (no network).
class _FakeXtreamApi extends XtreamApi {
  _FakeXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async => const [
    XtreamVodStream(streamId: 1, name: 'Alpha Movie', containerExtension: 'mp4', categoryId: '1'),
    XtreamVodStream(streamId: 2, name: 'Beta Movie', containerExtension: 'mkv', categoryId: '2'),
  ];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async => const [
    XtreamSeries(seriesId: 10, name: 'Alpha Show', categoryId: '1'),
  ];

  @override
  Future<List<XtreamCategory>> getVodCategories() async =>
      const [XtreamCategory(id: '1', name: 'Action'), XtreamCategory(id: '2', name: 'Drama')];

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async => const [XtreamCategory(id: '1', name: 'Action')];
}

/// In-memory favourites store for the tap tests: the real repo reads
/// SharedPreferences, whose async platform channel never completes inside
/// `testWidgets`' fake async zone when started from a widget load (the
/// tap is the first call to `_favoriteItems()` here — the category list
/// itself never reads favourites). Persistence is covered by the unit
/// tests in `iptv_item_favorites_test.dart`.
class _InMemoryItemFavoritesRepository implements IptvItemFavoritesRepository {
  Map<String, IptvFavoriteItem> _items = {};

  @override
  Future<Map<String, IptvFavoriteItem>> read({required String key}) async => Map.of(_items);

  @override
  Future<void> write(String key, Map<String, IptvFavoriteItem> items) async {
    _items = Map.of(items);
  }
}

IptvClient _client({List<String> disabled = const []}) {
  final connection = XtreamConnection(
    id: 'conn-xt-1',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: _testPassword,
    disabledCategoryIds: disabled,
    createdAt: DateTime.utc(2026, 11, 5),
  );
  final client = IptvClient.forConnection(connection);
  client.testXtreamApi = _FakeXtreamApi();
  client.testItemFavoritesRepository = _InMemoryItemFavoritesRepository();
  return client;
}

Future<void> _pumpTab(
  WidgetTester tester, {
  required MediaLibrary library,
  List<String> disabled = const [],
}) async {
  final client = _client(disabled: disabled);
  addTearDown(client.close);
  final harness = testMultiServer(clients: [client]);
  await pumpLibraryTab(
    tester,
    provider: harness.provider,
    tab: LibraryCategoriesTab(library: library, isActive: true),
  );
  await pumpRequestFrames(tester);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
  });

  testWidgets('Movies library lists VOD categories with counts', (tester) async {
    await _pumpTab(tester, library: _moviesLibrary);

    expect(find.text('Action'), findsOneWidget);
    expect(find.text('Drama'), findsOneWidget);
    expect(find.text('1 item'), findsNWidgets(2));
  });

  testWidgets('Series library lists series categories', (tester) async {
    await _pumpTab(tester, library: _seriesLibrary);

    expect(find.text('Action'), findsOneWidget);
    expect(find.text('Drama'), findsNothing);
  });

  testWidgets('disabled categories are omitted', (tester) async {
    await _pumpTab(tester, library: _moviesLibrary, disabled: ['2']);

    expect(find.text('Action'), findsOneWidget);
    expect(find.text('Drama'), findsNothing);
  });

  testWidgets('tapping a category opens its items', (tester) async {
    await _pumpTab(tester, library: _moviesLibrary);

    await tester.tap(find.text('Drama'));
    await tester.pumpAndSettle();

    expect(find.byType(HubDetailScreen), findsOneWidget);
    expect(find.text('Beta Movie'), findsOneWidget);
    expect(find.text('Alpha Movie'), findsNothing);
  });

  testWidgets('tapping a series category opens its shows', (tester) async {
    await _pumpTab(tester, library: _seriesLibrary);

    await tester.tap(find.text('Action'));
    await tester.pumpAndSettle();

    expect(find.byType(HubDetailScreen), findsOneWidget);
    expect(find.text('Alpha Show'), findsOneWidget);
  });

  group('visibleLibraryTabs', () {
  test('Plex libraries keep Collections and gain no Categories tab', () {
    const plex = MediaLibrary(id: 'movies', backend: MediaBackend.plex, title: 'Movies', kind: MediaKind.movie);
    expect(
      visibleLibraryTabs(plex),
      [LibraryTabType.recommended, LibraryTabType.browse, LibraryTabType.collections, LibraryTabType.playlists],
    );
  });

  test('IPTV libraries replace Collections with Categories', () {
    expect(
      visibleLibraryTabs(_moviesLibrary),
      [LibraryTabType.recommended, LibraryTabType.browse, LibraryTabType.categories, LibraryTabType.playlists],
    );
    expect(
      visibleLibraryTabs(_seriesLibrary),
      [LibraryTabType.recommended, LibraryTabType.browse, LibraryTabType.categories, LibraryTabType.playlists],
    );
    const m3u = MediaLibrary(id: 'm3u', backend: MediaBackend.m3u, title: 'M3U', kind: MediaKind.unknown);
    expect(
      visibleLibraryTabs(m3u),
      [LibraryTabType.recommended, LibraryTabType.browse, LibraryTabType.categories, LibraryTabType.playlists],
    );
  });
  });
}
