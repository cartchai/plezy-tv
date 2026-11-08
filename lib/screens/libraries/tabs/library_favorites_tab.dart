import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../i18n/strings.g.dart';
import '../../../media/iptv_client.dart';
import '../../../media/media_item.dart';
import '../../../media/media_kind.dart';
import '../../../services/settings_service.dart';
import '../../../widgets/focusable_media_card.dart';
import 'base_library_tab.dart';

/// Favourites tab for IPTV libraries (build #15, item 7): the movies or
/// shows Matt long-pressed into his favourites, inside the library they
/// belong to — the Movies library shows only favourited movies, the
/// TV/Series library only favourited shows and episodes (an episode
/// belongs to its show). Live TV is not a library, so it gets no tab;
/// its favourites stay in the guide filter and the build #7 heart screen,
/// which aggregates across connections and stays as the all-in-one view.
///
/// Reads [IptvClient.favoriteItems] (re-resolves against the catalog, so
/// a favourite added on another surface appears here without a restart).
/// Plex/Jellyfin/Emby libraries never build this tab.
class LibraryFavoritesTab extends BaseLibraryTab<MediaItem> {
  const LibraryFavoritesTab({
    super.key,
    required super.library,
    super.viewMode,
    super.density,
    super.onDataLoaded,
    super.isActive,
    super.suppressAutoFocus,
    super.onBack,
  });

  @override
  State<LibraryFavoritesTab> createState() => _LibraryFavoritesTabState();
}

class _LibraryFavoritesTabState extends BaseLibraryTabState<MediaItem, LibraryFavoritesTab> {
  @override
  Future<void> loadItems() {
    final client = getMediaClientForLibrary();
    if (client is! IptvClient) {
      // Not an IPTV library: nothing to list. The screen only builds this
      // tab for IPTV libraries, so this is a defensive empty state.
      return runLoadTransaction(() async => const <MediaItem>[]);
    }
    return runLoadTransaction(() async {
      final all = await client.favoriteItems();
      // Scoped to THIS library: movies in Movies, shows and their episodes
      // in TV/Series. An episode carries its show's parentId, so it lands
      // with the shows it belongs to.
      final wantMovies = widget.library.kind == MediaKind.movie;
      return all.where((item) {
        if (wantMovies) return item.kind == MediaKind.movie;
        return item.kind == MediaKind.show || item.kind == MediaKind.episode;
      }).toList();
    });
  }

  @override
  IconData get emptyIcon => Symbols.favorite_rounded;

  @override
  String get emptyMessage => t.libraries.noFavorites;

  @override
  String get errorContext => t.libraries.tabs.favorites;

  @override
  Widget buildContent(List<MediaItem> items) {
    return CustomScrollView(
      slivers: [
        SliverOverlapInjector(handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context)),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => FocusableMediaCard(
              key: Key(items[index].globalKey),
              item: items[index],
              viewModeOverride: ViewMode.list,
              showServerName: true,
              disableScale: true,
            ),
            childCount: items.length,
          ),
        ),
      ],
    );
  }
}
