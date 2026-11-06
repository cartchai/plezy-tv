import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/iptv_client.dart';
import '../../../media/media_hub.dart';
import '../../../media/media_kind.dart';
import '../../hub_detail_screen.dart';
import 'base_library_tab.dart';

/// Categories tab for IPTV libraries: the provider's own groupings
/// (VOD categories in the Movies library, series categories in the
/// TV/Series library) replace the Plex-shaped Collections tab, which IPTV
/// cannot serve — its fetch threw and the tab showed "Unable to load
/// Collections". Tapping a category opens its items in the hub detail
/// grid. Plex/Jellyfin/Emby libraries never build this tab.
class LibraryCategoriesTab extends BaseLibraryTab<IptvCategory> {
  const LibraryCategoriesTab({
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
  State<LibraryCategoriesTab> createState() => _LibraryCategoriesTabState();
}

class _LibraryCategoriesTabState extends BaseLibraryTabState<IptvCategory, LibraryCategoriesTab> {
  /// One focus node per category row, stable across rebuilds.
  final List<FocusNode> _rowFocusNodes = [];

  @override
  Future<void> loadItems() {
    final client = getMediaClientForLibrary();
    if (client is! IptvClient) {
      // Not an IPTV library: nothing to list. The screen only builds this
      // tab for IPTV libraries, so this is a defensive empty state.
      return runLoadTransaction(() async => const <IptvCategory>[]);
    }
    return runLoadTransaction(() => client.iptvCategoriesForLibrary(widget.library.id));
  }

  @override
  IconData get emptyIcon => Symbols.category_rounded;

  @override
  String get emptyMessage => t.libraries.noCategories;

  @override
  String get errorContext => t.libraries.tabs.categories;

  @override
  void focusFirstItem() {
    if (_rowFocusNodes.isNotEmpty) _rowFocusNodes.first.requestFocus();
  }

  void _openCategory(IptvCategory category) {
    final client = getMediaClientForLibrary();
    if (client is! IptvClient) return;
    final hub = MediaHub(
      id: 'iptv:${widget.library.id}:category:${category.id}',
      title: category.name,
      type: widget.library.kind == MediaKind.movie ? 'movie' : 'show',
      items: const [],
      size: category.itemCount ?? 0,
      // The items arrive through [loadItems]; `more` is what makes the
      // detail screen call it instead of rendering an empty grid.
      more: true,
      libraryId: widget.library.id,
      serverId: widget.library.serverId,
      serverName: widget.library.serverName,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HubDetailScreen(
          hub: hub,
          loadItems: () => client.iptvItemsForCategory(widget.library.id, category.id),
        ),
      ),
    );
  }

  @override
  Widget buildContent(List<IptvCategory> categories) {
    while (_rowFocusNodes.length < categories.length) {
      _rowFocusNodes.add(FocusNode(debugLabel: 'iptv_category_row_${_rowFocusNodes.length}'));
    }
    return CustomScrollView(
      slivers: [
        SliverOverlapInjector(handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context)),
        SliverList.separated(
          itemCount: categories.length,
          itemBuilder: (context, index) {
            final category = categories[index];
            final count = category.itemCount;
            return InkWell(
              focusNode: _rowFocusNodes[index],
              onTap: () => _openCategory(category),
              child: ListTile(
                leading: const Icon(Symbols.folder_rounded),
                title: Text(category.name),
                subtitle: count == null ? null : Text(t.libraries.categoryItemCount(n: count)),
                trailing: const Icon(Symbols.chevron_right_rounded),
              ),
            );
          },
          separatorBuilder: (_, _) => const Divider(height: 1),
        ),
      ],
    );
  }

  @override
  void dispose() {
    for (final node in _rowFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }
}
