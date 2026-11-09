import 'dart:ui';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/providers/download_provider.dart';
import 'package:plezy/providers/watch_state_store.dart';
import 'package:plezy/screens/libraries/folder_tree_item.dart';
import 'package:plezy/screens/playlist/playlist_item_card.dart';
import 'package:plezy/services/download_manager_service.dart';
import 'package:plezy/services/download_storage_service.dart';
import 'package:plezy/services/jellyfin_api_cache.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/episode_card.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:provider/provider.dart';

import '../test_helpers/media_items.dart';
import '../test_helpers/prefs.dart';

/// Quest fix: every long-press-only context menu needs a clickable •••
/// button alternative, because a Quest controller cannot long-press
/// reliably. The grid-card button is hover-revealed (a laser pointer
/// hovers, a finger never does); list rows carry a trailing button.
///
/// Wiring is proven through [MediaCard]'s `onLongPress` override seam:
/// tapping the ••• must invoke exactly the handler a long-press would.
/// The other cards have no override seam, so their tests assert the
/// button is present and correctly placed; the menu itself is the
/// shared, unchanged `MediaContextMenu` path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
  });

  testWidgets('grid card hides the menu button until hovered, then it fires the long-press seam', (tester) async {
    final item = testMediaItem(
      id: 'hover-menu-movie',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'Hover Menu Movie',
    );
    var longPressCount = 0;

    await tester.pumpWidget(
      _TestApp(
        child: SizedBox(
          width: 200,
          height: 330,
          child: MediaCard(
            item: item,
            viewModeOverride: ViewMode.grid,
            isOffline: true,
            onTap: () {},
            onLongPress: () => longPressCount++,
          ),
        ),
      ),
    );
    await tester.pump();

    // No hover yet: the button is not in the tree (touch users never see it).
    expect(find.byTooltip(t.common.options), findsNothing);

    final center = tester.getCenter(find.byType(MediaCard));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: center);
    await tester.pump();

    expect(find.byTooltip(t.common.options), findsOneWidget);

    await tester.tap(find.byTooltip(t.common.options));
    await tester.pump();
    expect(longPressCount, 1);
  });

  testWidgets('list card carries a trailing menu button that fires the long-press seam', (tester) async {
    final item = testMediaItem(
      id: 'list-menu-movie',
      backend: MediaBackend.plex,
      kind: MediaKind.movie,
      title: 'List Menu Movie',
    );
    var longPressCount = 0;

    await tester.pumpWidget(
      _TestApp(
        child: SizedBox(
          width: 500,
          height: 120,
          child: MediaCard(
            item: item,
            viewModeOverride: ViewMode.list,
            isOffline: true,
            onTap: () {},
            onLongPress: () => longPressCount++,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip(t.common.options), findsOneWidget);

    await tester.tap(find.byTooltip(t.common.options));
    await tester.pump();
    expect(longPressCount, 1);
  });

  testWidgets('episode card carries a menu button over the thumbnail', (tester) async {
    final episode = testMediaItem(
      id: 'menu-episode',
      backend: MediaBackend.jellyfin,
      kind: MediaKind.episode,
      title: 'Menu Episode',
      index: 1,
      durationMs: 42 * 60 * 1000,
    );

    await _pumpEpisodeCard(tester, episode);

    // The episode button has no Tooltip (one splits the card's merged
    // semantics node — see _EpisodeMenuButton); assert on its icon.
    expect(find.byIcon(Symbols.more_vert_rounded), findsOneWidget);
  });

  testWidgets('playlist row carries a trailing menu button', (tester) async {
    final store = WatchStateStore();
    addTearDown(store.dispose);
    final item = testMediaItem(
      id: 'menu-playlist-movie',
      kind: MediaKind.movie,
      title: 'Menu Playlist Movie',
      serverId: 'server-1',
      durationMs: 120000,
    );

    await tester.pumpWidget(
      TranslationProvider(
        child: ChangeNotifierProvider<WatchStateStore>.value(
          value: store,
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: Scaffold(
              body: SizedBox(
                width: 500,
                child: PlaylistItemCard(item: item, index: 0, onRemove: () {}, canReorder: false),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip(t.common.options), findsOneWidget);
    expect(find.byIcon(Symbols.more_vert_rounded), findsOneWidget);
  });

  testWidgets('folder tree media row carries a menu button; plain folders do not', (tester) async {
    final mediaItem = testMediaItem(
      id: 'menu-media-row',
      backend: MediaBackend.jellyfin,
      kind: MediaKind.movie,
      title: 'Menu Media Row',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Material(child: FolderTreeItem(item: mediaItem, depth: 0, isFolder: false)),
      ),
    );
    expect(find.byTooltip(t.common.options), findsOneWidget);

    final folderItem = testMediaItem(
      id: 'plain-folder',
      backend: MediaBackend.jellyfin,
      kind: MediaKind.unknown,
      title: 'Videos',
      raw: const {'Type': 'Folder', 'IsFolder': true},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: FolderTreeItem(
            item: folderItem,
            depth: 0,
            isFolder: true,
            onPlayAll: () {},
            onShuffle: () {},
          ),
        ),
      ),
    );
    // A plain folder's menu holds just Play/Shuffle, which are already
    // trailing buttons — no ••• is added.
    expect(find.byTooltip(t.common.options), findsNothing);
    expect(find.byType(IconButton), findsNWidgets(2));
  });
}

class _TestApp extends StatelessWidget {
  final Widget child;

  const _TestApp({required this.child});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: monoTheme(MonoPalette.dark),
      home: Scaffold(body: Center(child: child)),
    );
  }
}

Future<void> _pumpEpisodeCard(WidgetTester tester, MediaItem episode) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  PlexApiCache.initialize(db);
  JellyfinApiCache.initialize(db);
  final downloadManager = DownloadManagerService(
    database: db,
    storageService: DownloadStorageService.instance,
    clientResolver: (serverId, {clientScopeId}) => null,
  );
  downloadManager.recoveryFuture = Future<void>.value();
  final downloadProvider = DownloadProvider.forTesting(downloadManager: downloadManager, database: db);
  await downloadProvider.ensureInitialized();
  addTearDown(() async {
    downloadProvider.dispose();
    downloadManager.dispose();
    await db.close();
  });

  await tester.pumpWidget(
    TranslationProvider(
      child: ChangeNotifierProvider<DownloadProvider>.value(
        value: downloadProvider,
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              child: EpisodeCard(episode: episode, isOffline: true, onTap: () {}),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
