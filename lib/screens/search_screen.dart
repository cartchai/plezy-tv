import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../connection/connection.dart';
import '../exceptions/media_server_exceptions.dart';
import '../focus/focusable_text_field.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/iptv_client.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_library.dart';
import '../media/media_item_merge.dart';
import '../media/media_person.dart';
import '../media/search_hit.dart';
import '../mixins/debounced_media_search.dart';
import '../mixins/mounted_set_state_mixin.dart';
import '../mixins/refreshable.dart';
import '../providers/hidden_libraries_provider.dart';
import '../providers/libraries_provider.dart';
import '../providers/multi_server_provider.dart';
import '../services/data_aggregation_service.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/platform_detector.dart';
import '../utils/provider_extensions.dart';
import '../utils/snackbar_helper.dart';
import '../utils/media_server_http_client.dart';
import '../utils/search_relevance.dart';
import '../utils/search_sections.dart';
import '../widgets/desktop_app_bar.dart';
import '../widgets/loading_indicator_box.dart';
import '../widgets/search_input_field.dart';
import '../widgets/focusable_media_card.dart';
import '../widgets/focusable_tab_chip.dart';
import '../widgets/person_search_row.dart';
import 'settings/iptv_categories_screen.dart';
import '../utils/focus_utils.dart';
import 'libraries/state_messages.dart';
import 'main_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with
        Refreshable,
        ManualRefreshable,
        FullRefreshable,
        SearchInputFocusable,
        FocusableTab,
        MountedSetStateMixin,
        DebouncedMediaSearch<SearchScreen, SearchHit> {
  String? _focusResultsForQuery;
  final _tvTextInputController = TvTextInputController();
  AbortController? _activeSearchAbort;
  ({String query, SearchAggregationResult result})? _pendingSearchOutcome;

  /// Filter over the current results: everything, one media kind, or only
  /// people. Chips and the filtered views derive from [_searchCandidates] and
  /// [_searchPeople] — the pre-rank pools behind the ranked [searchResults] —
  /// so a kind ranked out of the "All" top-N still gets a chip, and selecting
  /// a chip shows everything the servers returned for it.
  _SearchFilter _selectedFilter = const _AllResults();
  List<MediaItem> _searchCandidates = const [];
  List<MediaPerson> _searchPeople = const [];
  List<MediaKind> _candidateKinds = const [];
  List<SearchHit>? _filteredResults;
  late final FocusNode _allChipFocusNode = FocusNode(debugLabel: 'SearchKindChipAll');
  late final FocusNode _peopleChipFocusNode = FocusNode(debugLabel: 'SearchPeopleChip');
  final Map<MediaKind, FocusNode> _kindChipFocusNodes = {};

  /// Library scope for the search (build #9 Task 1b): null = all
  /// libraries. The scope strip under the search field always offers every
  /// visible library — even before a search runs or when the scoped library
  /// returns nothing — so the option is never hidden. Selecting a scope
  /// re-runs the query scoped to that library; the scope survives query
  /// refinements and clearing the field, and resets only via "All
  /// libraries". Hidden libraries are never offered as a scope.
  String? _selectedLibraryKey;
  late final FocusNode _allLibrariesScopeFocusNode = FocusNode(debugLabel: 'SearchScopeChipAll');
  final Map<String, FocusNode> _libraryScopeFocusNodes = {};

  HiddenLibrariesProvider? _hiddenLibraries;
  Set<String> _lastSeenHiddenKeys = const {};

  @override
  void initState() {
    super.initState();
    FocusUtils.requestFocusAfterBuild(this, searchFocusNode);
    unawaited(_bindHiddenLibraries());
  }

  @override
  void dispose() {
    _hiddenLibraries?.removeListener(_onHiddenLibrariesChanged);
    _allChipFocusNode.dispose();
    _peopleChipFocusNode.dispose();
    for (final node in _kindChipFocusNodes.values) {
      node.dispose();
    }
    _allLibrariesScopeFocusNode.dispose();
    for (final node in _libraryScopeFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Re-run the visible query when a library is hidden or unhidden while
  /// results are on screen. The listener is attached only after the provider
  /// has hydrated, so its initial load notification cannot race the first
  /// query — which awaits that same hydration — into running twice.
  Future<void> _bindHiddenLibraries() async {
    final hiddenLibraries = context.read<HiddenLibrariesProvider>();
    await hiddenLibraries.ensureInitialized();
    if (!mounted) return;
    _lastSeenHiddenKeys = Set.of(hiddenLibraries.hiddenLibraryKeys);
    _hiddenLibraries = hiddenLibraries..addListener(_onHiddenLibrariesChanged);
  }

  void _onHiddenLibrariesChanged() {
    final hiddenLibraries = _hiddenLibraries;
    if (hiddenLibraries == null || !mounted) return;
    final currentKeys = hiddenLibraries.hiddenLibraryKeys;
    if (currentKeys.length == _lastSeenHiddenKeys.length && currentKeys.containsAll(_lastSeenHiddenKeys)) {
      return;
    }
    _lastSeenHiddenKeys = Set.of(currentKeys);
    final query = searchController.text.trim();
    if (query.isEmpty || !hasSearched) return;
    unawaited(runSearch(query));
  }

  @override
  String get searchDebugLabel => 'Search';

  @override
  Future<List<SearchHit>> performSearchQuery(String query) async {
    final multiServerProvider = Provider.of<MultiServerProvider>(context, listen: false);
    if (!multiServerProvider.hasConnectedServers) {
      throw const _SearchUnavailableException();
    }

    // Hidden-library keys must be hydrated before the first query, or a cold
    // start would filter nothing. Read before any await: the profile subtree
    // can be torn down mid-search.
    final hiddenLibraries = context.read<HiddenLibrariesProvider>();
    final librariesProvider = context.read<LibrariesProvider>();
    await hiddenLibraries.ensureInitialized();
    if (!mounted) return const [];

    // Library scope (build #9 Task 1b): a selected library keeps only
    // itself visible — every other loaded library joins the hidden set for
    // this query, so the aggregation drops its candidates and hits and the
    // IPTV client skips its sections entirely. A stale scope (library no
    // longer loaded) behaves as All rather than hiding everything.
    final hiddenKeys = {...hiddenLibraries.hiddenLibraryKeys};
    final scope = _selectedLibraryKey;
    final libraries = librariesProvider.libraries;
    if (scope != null && libraries.any((library) => library.globalKey == scope)) {
      for (final library in libraries) {
        if (library.globalKey != scope) hiddenKeys.add(library.globalKey);
      }
    }
    // The scope is ALSO conveyed explicitly (build #19): the hidden set
    // alone cannot enforce it — it is only as complete as the loaded
    // library list (a server whose libraries are missing from it leaks
    // attributed rows), and unattributed rows survive a hide by design.
    // The aggregation drops every title row not attributable to this key.
    final scopedKey =
        scope != null && libraries.any((library) => library.globalKey == scope) ? scope : null;

    final abort = AbortController();
    _activeSearchAbort = abort;
    try {
      final result = await multiServerProvider.aggregationService.searchAcrossServers(
        query,
        hiddenLibraryKeys: hiddenKeys,
        scopedLibraryKey: scopedKey,
        abort: abort,
      );
      abort.throwIfAborted();
      if (result.succeededServerIds.isEmpty && result.failedServerIds.isNotEmpty) {
        throw const _SearchUnavailableException();
      }
      if (result.succeededServerIds.isEmpty && result.cancelledServerIds.isNotEmpty) {
        throw MediaServerHttpException(
          type: MediaServerHttpErrorType.cancelled,
          message: 'Search was cancelled before any server completed',
        );
      }
      _pendingSearchOutcome = (query: query, result: result);
      return result.hits;
    } finally {
      if (identical(_activeSearchAbort, abort)) _activeSearchAbort = null;
    }
  }

  @override
  void onSearchInvalidated() {
    _activeSearchAbort?.abort();
    _activeSearchAbort = null;
    _pendingSearchOutcome = null;
  }

  @override
  void onSearchError(Object error) {
    _focusResultsForQuery = null;
    _pendingSearchOutcome = null;
    _resetFilter();
    final message = error is _SearchUnavailableException
        ? t.errors.searchUnavailable
        : t.errors.searchFailed(error: error);
    showErrorSnackBar(context, message);
  }

  @override
  void onSearchCleared() {
    _focusResultsForQuery = null;
    _pendingSearchOutcome = null;
    _resetFilter();
  }

  @override
  void onSearchCompleted(String query, List<SearchHit> results) {
    final outcome = _pendingSearchOutcome;
    _pendingSearchOutcome = null;
    final matched = outcome != null && outcome.query == query ? outcome.result : null;

    // Committed alongside the results the pending setState renders (build has
    // not run yet): the pre-rank pools the filter chips derive from. A selected
    // filter survives a refined query as long as it still has candidates;
    // otherwise it falls back to "All".
    _searchCandidates =
        matched?.candidates ??
        [
          for (final hit in results)
            if (hit case MediaSearchHit(:final item)) item,
        ];
    _searchPeople =
        matched?.people ??
        [
          for (final hit in results)
            if (hit case PersonSearchHit(:final person)) person,
        ];
    _candidateKinds = _kindsIn(_searchCandidates);
    if (!_hasCandidatesFor(_selectedFilter)) _selectedFilter = const _AllResults();
    _filteredResults = _rankFilteredResults(_selectedFilter, query);

    if (matched != null && matched.failedServerIds.isNotEmpty) {
      showAppSnackBar(context, t.messages.searchPartialResults);
    }

    if (_focusResultsForQuery == null || _focusResultsForQuery != query) return;
    _focusResultsForQuery = null;
    if (results.isEmpty) return;
    if (searchController.text.trim() != query) return; // user kept editing
    FocusUtils.requestFocusAfterBuild(this, firstResultFocusNode);
  }

  /// OSK "Search" / hardware Enter on TV additionally focuses the results
  /// when the forced search lands.
  @override
  void handleSearchSubmit() {
    final query = searchController.text.trim();
    if (query.isEmpty) return;
    if (searchResults.isEmpty || isSearching || query != lastSearchedQuery) {
      _focusResultsForQuery = query;
    }
    super.handleSearchSubmit();
  }

  @override
  void refresh() {
    if (!mounted) return;
    runSearch(searchController.text.trim());
  }

  /// Cmd+R / Ctrl+R re-runs the query currently on screen; `runSearch` no-ops
  /// on an empty field.
  @override
  void manualRefresh() => refresh();

  /// Focus the search input field
  @override
  void focusSearchInput() {
    if (!mounted) return;
    searchFocusNode.requestFocus();
  }

  @override
  void focusActiveTabIfReady() {
    if (!mounted) return;
    searchFocusNode.requestFocus();
  }

  /// Apply a complete query submitted from the Plezy companion remote: set the
  /// text, dismiss any open on-screen keyboard, land focus on the input without
  /// (re)opening the OSK, and run the search now — the first result takes focus
  /// when it lands (via onSearchCompleted). The user already typed the query on
  /// their phone, so the TV keyboard must never be up afterwards.
  @override
  void submitSearchQuery(String query) {
    if (!mounted) return;
    final trimmed = query.trim();
    searchController.text = trimmed; // listener arms the debounce / resets state

    // Focusing the field normally auto-opens the OSK; a remote search must not
    // show it, and must dismiss one the TV user already had open (the phone's
    // Search chip sends tabSearch before the query arrives).
    _tvTextInputController.closeTextInput();
    if (trimmed.isEmpty) return;

    // Land focus on the (visible) input immediately so the D-pad remote is
    // never stranded on the hidden previous tab — while the search is in
    // flight, when it fails, and when it returns nothing.
    _tvTextInputController.focusInputWithoutOpening();

    // Same path as the OSK Search key: jumps straight to already-matching
    // results, or cancels the debounce and runs now; the screen override arms
    // _focusResultsForQuery so results take focus when they land.
    handleSearchSubmit();
  }

  // Public method to fully reload all content (for profile switches)
  @override
  void fullRefresh() {
    if (!mounted) return;
    appLogger.d('SearchScreen.fullRefresh() called - clearing search and reloading');
    // Clearing the field resets the search state through the text listener.
    _focusResultsForQuery = null;
    searchController.clear();
  }

  Future<void> updateItem(MediaItem source) async {
    if (!mounted) return;
    final serverId = source.serverId;
    if (serverId == null) return;

    try {
      final multiServer = context.read<MultiServerProvider>();
      final updated = await multiServer.getClientForServer(ServerId(serverId))?.fetchItem(source.id);
      if (!mounted || updated == null) return;
      // A fresh Jellyfin `fetchItem` carries no library field, and a
      // library-less row would lose its label (#1970); keep the identity
      // and library context the search stamped on the original row.
      final merged = mergeFetchedMediaItem(fetched: updated, fallbackServerId: ServerId(serverId), existing: source);
      // The same row can sit in the ranked "All" list, the filtered view,
      // and the candidate pool; refresh every copy so a later chip switch
      // cannot resurrect the stale row.
      var replaced = _replaceHitByGlobalKey(searchResults, source.globalKey, merged);
      replaced = _replaceByGlobalKey(_searchCandidates, source.globalKey, merged) || replaced;
      final filtered = _filteredResults;
      if (filtered != null) {
        replaced = _replaceHitByGlobalKey(filtered, source.globalKey, merged) || replaced;
      }
      if (replaced) setState(() {});
    } catch (e) {
      appLogger.d('Search item refresh skipped for ${source.globalKey}', error: e);
    }
  }

  void _navigateToSidebar() {
    MainScreenFocusScope.focusSidebarOf(context);
  }

  /// Chip display order. `folder`/`unknown` are never search kinds, and
  /// `clip`/`photo` rows (Plex extras, Jellyfin/Emby home and music videos)
  /// stay reachable under "All" without a chip of their own.
  static const List<MediaKind> _kindFilterOrder = [
    MediaKind.movie,
    MediaKind.show,
    MediaKind.season,
    MediaKind.episode,
    MediaKind.artist,
    MediaKind.album,
    MediaKind.track,
    MediaKind.collection,
    MediaKind.playlist,
  ];

  static List<MediaKind> _kindsIn(List<MediaItem> candidates) {
    if (candidates.isEmpty) return const [];
    final present = {for (final item in candidates) item.kind};
    return [
      for (final kind in _kindFilterOrder)
        if (present.contains(kind)) kind,
    ];
  }

  static bool _replaceByGlobalKey(List<MediaItem> items, String globalKey, MediaItem replacement) {
    final index = items.indexWhere((item) => item.globalKey == globalKey);
    if (index == -1) return false;
    items[index] = replacement;
    return true;
  }

  static bool _replaceHitByGlobalKey(List<SearchHit> hits, String globalKey, MediaItem replacement) {
    final index = hits.indexWhere((hit) => hit is MediaSearchHit && hit.globalKey == globalKey);
    if (index == -1) return false;
    hits[index] = MediaSearchHit(replacement);
    return true;
  }

  /// The list the results sliver renders: the aggregation's ranked list, or
  /// the selected filter's pool re-ranked with the full display budget.
  List<SearchHit> get _visibleResults => _filteredResults ?? searchResults;

  /// Chip order: All, the media kinds present, then People.
  List<_SearchFilter> get _filterOptions => [
    const _AllResults(),
    for (final kind in _candidateKinds) _KindResults(kind),
    if (_searchPeople.isNotEmpty) const _PeopleResults(),
  ];

  /// "All" plus a single other option (one kind, or only people) has nothing
  /// to filter.
  bool get _showFilterChips => _candidateKinds.length + (_searchPeople.isEmpty ? 0 : 1) > 1;

  bool _hasCandidatesFor(_SearchFilter filter) => switch (filter) {
    _AllResults() => true,
    _KindResults(:final kind) => _candidateKinds.contains(kind),
    _PeopleResults() => _searchPeople.isNotEmpty,
  };

  /// The selected filter's pool re-ranked with the full display budget, or
  /// null for "All" (the aggregation's ranked list).
  List<SearchHit>? _rankFilteredResults(_SearchFilter filter, String query) {
    switch (filter) {
      case _AllResults():
        return null;
      case _KindResults(:final kind):
        final ofKind = [
          for (final candidate in _searchCandidates)
            if (candidate.kind == kind) candidate,
        ];
        return [
          for (final item in rankMediaSearchResults(ofKind, query, limit: defaultMediaSearchLimit))
            MediaSearchHit(item),
        ];
      case _PeopleResults():
        return [
          for (final person in rankPeopleSearchResults(_searchPeople, query, limit: defaultMediaSearchLimit))
            PersonSearchHit(person),
        ];
    }
  }

  void _selectFilter(_SearchFilter filter) {
    if (filter == _selectedFilter) return;
    setState(() {
      _selectedFilter = filter;
      _filteredResults = _rankFilteredResults(filter, lastSearchedQuery);
    });
  }

  void _resetFilter() {
    _selectedFilter = const _AllResults();
    _searchCandidates = const [];
    _searchPeople = const [];
    _candidateKinds = const [];
    _filteredResults = null;
  }

  FocusNode _chipFocusNode(_SearchFilter filter) => switch (filter) {
    _AllResults() => _allChipFocusNode,
    _KindResults(:final kind) => _kindChipFocusNodes.putIfAbsent(
      kind,
      () => FocusNode(debugLabel: 'SearchKindChip_${kind.id}'),
    ),
    _PeopleResults() => _peopleChipFocusNode,
  };

  /// D-pad landing point for the chip row: the chip that is currently active.
  void _focusFilterChips() => _chipFocusNode(_selectedFilter).requestFocus();

  void _focusFirstResult() {
    if (_visibleResults.isNotEmpty) firstResultFocusNode.requestFocus();
  }

  String _filterLabel(_SearchFilter filter) => switch (filter) {
    _AllResults() => t.libraries.groupings.all,
    _KindResults(:final kind) => _kindFilterLabel(kind),
    _PeopleResults() => t.search.people,
  };

  String _kindFilterLabel(MediaKind kind) => switch (kind) {
    MediaKind.movie => t.libraries.groupings.movies,
    MediaKind.show => t.libraries.groupings.shows,
    MediaKind.season => t.libraries.groupings.seasons,
    MediaKind.episode => t.libraries.groupings.episodes,
    MediaKind.artist => t.libraries.groupings.artists,
    MediaKind.album => t.libraries.groupings.albums,
    MediaKind.track => t.libraries.groupings.tracks,
    MediaKind.collection => t.libraries.tabs.collections,
    MediaKind.playlist => t.libraries.tabs.playlists,
    // Unreachable: excluded from _kindFilterOrder.
    MediaKind.clip || MediaKind.photo || MediaKind.folder || MediaKind.unknown => kind.id,
  };

  Widget _buildFilterChips() {
    // Chips trap RIGHT to keep focus inside the strip (see
    // FocusableChipStateMixin), so left/right neighbors are wired explicitly,
    // like every other tab-chip strip.
    final filters = _filterOptions;
    return SliverToBoxAdapter(
      child: Padding(
        // The search field's own bottom padding provides the gap above; the
        // results sliver below shrinks its top padding to match (16/16 visual
        // rhythm around the strip instead of the default 24/24).
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TabChipStrip(
          children: [
            for (final (index, filter) in filters.indexed) ...[
              if (index > 0) const SizedBox(width: 8),
              FocusableTabChip(
                label: _filterLabel(filter),
                isSelected: _selectedFilter == filter,
                focusNode: _chipFocusNode(filter),
                onSelect: () => _selectFilter(filter),
                onNavigateLeft: index == 0
                    ? _navigateToSidebar
                    : () => _chipFocusNode(filters[index - 1]).requestFocus(),
                onNavigateRight: index < filters.length - 1
                    ? () => _chipFocusNode(filters[index + 1]).requestFocus()
                    : null,
                onNavigateUp: focusSearchInput,
                onNavigateDown: _focusFirstResult,
                onBack: _navigateToSidebar,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The library scope currently in effect, or null for All. A scope whose
  /// library is no longer loaded (or was hidden) reads as All.
  String? _effectiveScopeKey(List<MediaLibrary> visibleLibraries) =>
      visibleLibraries.any((library) => library.globalKey == _selectedLibraryKey) ? _selectedLibraryKey : null;

  FocusNode _scopeChipFocusNode(String? libraryKey) => libraryKey == null
      ? _allLibrariesScopeFocusNode
      : _libraryScopeFocusNodes.putIfAbsent(
          libraryKey,
          () => FocusNode(debugLabel: 'SearchScopeChip_$libraryKey'),
        );

  void _selectLibraryScope(String? libraryKey) {
    if (_selectedLibraryKey == libraryKey) return;
    setState(() => _selectedLibraryKey = libraryKey);
    final query = searchController.text.trim();
    if (query.isNotEmpty) unawaited(runSearch(query));
  }

  /// The always-visible library scope strip (build #9 Task 1b): "All
  /// libraries" plus one chip per visible library, rendered under the
  /// search field whether or not a search has run — so Matt can scope a
  /// search to one library even when that library currently returns
  /// nothing. Same chip pattern as the kind filters (explicit left/right
  /// neighbours, up to the input, down to the first result).
  Widget _buildLibraryScopeStrip(List<MediaLibrary> visibleLibraries, String? effectiveScopeKey) {
    final options = <String?>[null, for (final library in visibleLibraries) library.globalKey];
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: TabChipStrip(
          children: [
            for (final (index, libraryKey) in options.indexed) ...[
              if (index > 0) const SizedBox(width: 8),
              FocusableTabChip(
                label: libraryKey == null
                    ? t.search.allLibraries
                    : visibleLibraries.firstWhere((library) => library.globalKey == libraryKey).title,
                isSelected: effectiveScopeKey == libraryKey,
                focusNode: _scopeChipFocusNode(libraryKey),
                onSelect: () => _selectLibraryScope(libraryKey),
                onNavigateLeft: index == 0
                    ? _navigateToSidebar
                    : () => _scopeChipFocusNode(options[index - 1]).requestFocus(),
                onNavigateRight: index < options.length - 1
                    ? () => _scopeChipFocusNode(options[index + 1]).requestFocus()
                    : null,
                onNavigateUp: focusSearchInput,
                onNavigateDown: _focusFirstResult,
                onBack: _navigateToSidebar,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The results slivers. The "All" view groups the ranked hits into
  /// sections by library — Movies, TV Shows, Live TV, then other libraries,
  /// People last — each with a header (build #8 Task 2: "add sections for
  /// search so I can easily skip through movies TV or live or other
  /// libraries"). A selected filter chip still shows that kind's full pool
  /// as a flat list — a kind ranked out of the "All" top-N stays reachable
  /// that way — and the chips are the jump control: tapping one takes you
  /// straight to that kind's results.
  List<Widget> _buildResultsList(BuildContext context) {
    final multiServer = context.watch<MultiServerProvider>();
    final libraries = context.watch<LibrariesProvider>();
    final showServerName = multiServer.totalServerCount > 1;
    final showChips = _showFilterChips;
    final visible = _visibleResults;
    // Half the default top padding when the chip strip sits directly above:
    // the strip already separates results from the search field.
    final topPadding = showChips ? const EdgeInsets.fromLTRB(16, 8, 16, 16) : const EdgeInsets.all(16);
    Widget flatList(List<SearchHit> hits, {required EdgeInsets padding}) => buildResultsSliver(
      childCount: hits.length,
      padding: padding,
      (context, index) => _buildResultRow(
        hits[index],
        isFirst: index == 0,
        showChips: showChips,
        showServerName: showServerName,
        libraries: libraries,
      ),
    );
    if (_filteredResults != null) return [flatList(visible, padding: topPadding)];
    final sections = groupSearchResults(
      visible,
      libraryLabel: (item) =>
          libraries.libraryLabelFor(item) ?? item.libraryTitle ?? item.serverName ?? _kindFilterLabel(item.kind),
      peopleLabel: t.search.people,
    );
    if (sections.length <= 1) return [flatList(visible, padding: topPadding)];
    final theme = Theme.of(context);
    final slivers = <Widget>[];
    for (final (sectionIndex, section) in sections.indexed) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, sectionIndex == 0 ? (showChips ? 8 : 16) : 24, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    section.label,
                    key: Key('SearchSectionHeader:${section.label}'),
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '${section.hits.length}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      slivers.add(
        buildResultsSliver(
          childCount: section.hits.length,
          padding: EdgeInsets.fromLTRB(16, 0, 16, sectionIndex == sections.length - 1 ? 16 : 0),
          (context, index) => _buildResultRow(
            section.hits[index],
            isFirst: sectionIndex == 0 && index == 0,
            showChips: showChips,
            showServerName: showServerName,
            libraries: libraries,
          ),
        ),
      );
    }
    return slivers;
  }

  Widget _buildResultRow(
    SearchHit hit, {
    required bool isFirst,
    required bool showChips,
    required bool showServerName,
    required LibrariesProvider libraries,
  }) {
    final onNavigateUp = isFirst ? (showChips ? _focusFilterChips : focusSearchInput) : null;
    return switch (hit) {
      MediaSearchHit(:final item) => FocusableMediaCard(
        key: Key(item.globalKey),
        item: item,
        viewModeOverride: ViewMode.list,
        disableScale: true,
        focusNode: isFirst ? firstResultFocusNode : null,
        onRefresh: updateItem,
        onListRefresh: refresh,
        onNavigateLeft: _navigateToSidebar,
        onNavigateUp: onNavigateUp,
        showServerName: showServerName,
        libraryName: libraries.libraryLabelFor(item),
      ),
      PersonSearchHit(:final person) => PersonSearchRow(
        key: Key(person.globalKey),
        person: person,
        focusNode: isFirst ? firstResultFocusNode : null,
        showServerName: showServerName,
        onNavigateLeft: _navigateToSidebar,
        onNavigateUp: onNavigateUp,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    // The scope strip watches the library list, so it appears as soon as
    // libraries load and stays visible in every search state — before a
    // search runs, while one loads, and when the scoped library is empty.
    final librariesProvider = context.watch<LibrariesProvider>();
    final hiddenKeys = context.watch<HiddenLibrariesProvider>().hiddenLibraryKeys;
    final visibleLibraries = [
      for (final library in librariesProvider.libraries)
        if (!hiddenKeys.contains(library.globalKey)) library,
    ];
    final effectiveScopeKey = _effectiveScopeKey(visibleLibraries);
    final scopeTitle = effectiveScopeKey == null
        ? null
        : visibleLibraries.firstWhere((library) => library.globalKey == effectiveScopeKey).title;
    // (build #17) When a scoped search returns [] but the hidden-category
    // filter removed matches, the empty state says so and links to the
    // categories screen — instead of a bare "No results" that looks like
    // the show does not exist. The diagnostics are set by searchItems
    // before the results arrive, so they are consistent here.
    int hiddenMatches = 0;
    Connection? scopedIptvConnection;
    if (effectiveScopeKey != null) {
      final scopedLibrary = visibleLibraries.firstWhere((library) => library.globalKey == effectiveScopeKey);
      final serverId = serverIdOrNull(scopedLibrary.serverId);
      final client = serverId == null ? null : context.tryGetMediaClientForServer(serverId);
      if (client is IptvClient) {
        hiddenMatches = client.lastSearchHiddenMatchesForLibrary(scopedLibrary.id);
        if (hiddenMatches > 0) scopedIptvConnection = client.connection;
      }
    }
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          primary: false,
          slivers: [
            DesktopSliverAppBar(title: Text(t.common.search), floating: true),
            SliverToBoxAdapter(
              child: SearchInputField(
                controller: searchController,
                focusNode: searchFocusNode,
                debugLabel: searchDebugLabel,
                hintText: t.search.hint,
                tvTextInputController: _tvTextInputController,
                onNavigateLeft: _navigateToSidebar,
                onNavigateDown: searchResults.isNotEmpty && !isSearching
                    ? (_showFilterChips ? _focusFilterChips : firstResultFocusNode.requestFocus)
                    : null,
                onEditingComplete: PlatformDetector.isTV() ? handleSearchSubmit : null,
                onBack: () {
                  if (searchController.text.isNotEmpty) {
                    searchController.clear();
                  } else {
                    _navigateToSidebar();
                  }
                },
              ),
            ),
            if (visibleLibraries.isNotEmpty) _buildLibraryScopeStrip(visibleLibraries, effectiveScopeKey),
            if (isSearching)
              LoadingIndicatorBox.sliver
            else if (!hasSearched)
              SliverFillRemaining(
                child: StateMessageWidget(
                  message: t.search.searchYourMedia,
                  subtitle: t.search.enterTitleActorOrKeyword,
                  icon: Symbols.search_rounded,
                  iconSize: 80,
                ),
              )
            else if (lastSearchFailed)
              SliverFillRemaining(
                child: StateMessageWidget(message: t.explore.searchFailed, icon: Symbols.error_rounded, iconSize: 80),
              )
            else if (searchResults.isEmpty)
              SliverFillRemaining(
                child: StateMessageWidget(
                  message: scopeTitle == null
                      ? t.messages.noResultsFound
                      : t.search.noResultsInLibrary(library: scopeTitle),
                  subtitle: hiddenMatches > 0
                      ? t.search.hiddenByCategoryFilter(n: hiddenMatches, count: hiddenMatches)
                      : t.search.tryDifferentTerm,
                  icon: Symbols.search_off_rounded,
                  iconSize: 80,
                  onAction: scopedIptvConnection == null
                      ? null
                      : () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => IptvCategoriesScreen(connection: scopedIptvConnection!),
                            ),
                          );
                        },
                  actionLabel: scopedIptvConnection == null
                      ? null
                      : t.iptvCategories.title(name: scopedIptvConnection.displayName),
                ),
              )
            else ...[
              if (_showFilterChips) _buildFilterChips(),
              ..._buildResultsList(context),
            ],
          ],
        ),
      ),
    );
  }
}

final class _SearchUnavailableException implements Exception {
  const _SearchUnavailableException();
}

/// One chip of the search results filter strip.
sealed class _SearchFilter {
  const _SearchFilter();
}

final class _AllResults extends _SearchFilter {
  const _AllResults();
}

final class _KindResults extends _SearchFilter {
  final MediaKind kind;

  const _KindResults(this.kind);

  @override
  bool operator ==(Object other) => other is _KindResults && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;
}

final class _PeopleResults extends _SearchFilter {
  const _PeopleResults();
}
