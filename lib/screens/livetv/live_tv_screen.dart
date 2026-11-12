import 'dart:async';
import '../../media/ids.dart';
import '../../media/library_change_event.dart';
import '../../utils/library_content_notifier.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../focus/focusable_action_bar.dart';
import '../../i18n/strings.g.dart';
import '../../media/iptv_client.dart';
import '../../media/iptv_live_tv.dart';
import '../../media/live_tv_support.dart';
import '../../media/media_server_client.dart';
import '../../models/livetv_channel.dart';
import '../../models/livetv_dvr.dart';
import '../../models/livetv_program.dart';
import '../../mixins/refreshable.dart';
import '../../mixins/tab_navigation_mixin.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/settings_service.dart';
import '../../widgets/settings_builder.dart';
import '../../utils/app_logger.dart';
import '../../utils/error_message_utils.dart';
import '../../utils/desktop_window_padding.dart';
import '../../utils/live_tv_matching.dart';
import '../../utils/platform_detector.dart';
import '../../utils/serial_future_queue.dart';
import 'guide_category.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/focusable_tab_chip.dart';
import '../../widgets/overlay_sheet.dart';
import '../libraries/state_messages.dart';
import 'guide_search_sheet.dart';
import 'live_tv_server_iteration.dart';
import 'reorder_favorites_sheet.dart';
import 'tabs/guide_tab.dart';
import 'tabs/recordings_tab.dart';
import 'tabs/whats_on_tab.dart';

typedef _FavoriteScope = ({String source, String storeKey, FavoriteChannelPersistenceMode mode});

enum LiveTvTab { guide, whatsOn, recordings }

class LiveTvScreen extends StatefulWidget {
  const LiveTvScreen({super.key});

  @override
  State<LiveTvScreen> createState() => _LiveTvScreenState();
}

class _LiveTvScreenState extends State<LiveTvScreen>
    with TickerProviderStateMixin, TabNavigationMixin
    implements FocusableTab, ManualRefreshable {
  final _guideTabFocusNode = FocusNode(debugLabel: 'tab_chip_guide');
  final _whatsOnTabFocusNode = FocusNode(debugLabel: 'tab_chip_whats_on');
  final _recordingsTabFocusNode = FocusNode(debugLabel: 'tab_chip_recordings');
  final _guideTabKey = GlobalKey<GuideTabState>();
  final _whatsOnTabKey = GlobalKey<WhatsOnTabState>();
  final _recordingsTabKey = GlobalKey<RecordingsTabState>();

  /// Focus target for the "Show all channels" action shown when the favorites
  /// filter empties the guide; lets D-pad users reach the action from the tab bar.
  final _guideEmptyStateActionFocusNode = FocusNode(debugLabel: 'guide_empty_state_action');

  /// Visible tabs in the current session. What's On is included only when a
  /// Live TV server is Plex (the only backend with Live TV hubs), Recordings
  /// only when at least one Live TV server has `liveTvDvr` capability.
  List<LiveTvTab> _visibleTabs = [LiveTvTab.guide];

  /// Whether any connected DVR supports Plex-style rule re-evaluation;
  /// gates the recordings tab's bolt action.
  bool _canProcessRules = false;

  // App bar action bar
  final _actionBarKey = GlobalKey<FocusableActionBarState>();

  List<LiveTvChannel> _channels = [];
  bool _isLoading = true;
  String? _error;

  /// Saved in initState: dispose() cannot use context.read (the widget is
  /// already deactivated), so the provider reference lives here.
  late final MultiServerProvider _multiServer;

  /// Live TV source the guide shows: a server id, or null for all sources.
  /// When more than one live-TV server is connected (e.g. Plex + an IPTV
  /// playlist), the picker above the guide switches between them.
  String? _selectedLiveTvServerId;

  /// Guide category picker (build #17): the selected live TV category, or
  /// null for all categories. Reset whenever the source changes, so a
  /// category picked on one source never hides another source's channels.
  GuideCategoryEntry? _selectedGuideCategory;

  /// Visible live categories per live-TV server id, as (id, name) pairs
  /// from [IptvClient.visibleLiveCategories] — the same hidden rule as
  /// the guide rows. Plex/Jellyfin/Emby servers have no entry. Loaded
  /// after the channels (disk-first, no extra network when warm) and
  /// reloaded with them on catalog changes, so a category turned off in
  /// settings disappears from the picker at the same time as its rows.
  final Map<String, List<({String id, String name})>> _guideCategoriesByServer = {};

  /// Picker entries for the current source scope: one server's categories
  /// when a source is picked, the union otherwise. A category name that
  /// exists on more than one visible source is prefixed with its source
  /// ("Trex — US"), so a category never shows another source's channels.
  List<GuideCategoryEntry> get _guideCategoryEntries {
    final selected = _selectedLiveTvServerId;
    final servers = selected == null ? _guideCategoriesByServer.keys.toList(growable: false) : [selected];
    final nameCounts = <String, int>{};
    for (final id in servers) {
      for (final c in _guideCategoriesByServer[id] ?? const <({String id, String name})>[]) {
        nameCounts[c.name] = (nameCounts[c.name] ?? 0) + 1;
      }
    }
    final entries = <GuideCategoryEntry>[];
    for (final id in servers) {
      for (final c in _guideCategoriesByServer[id] ?? const <({String id, String name})>[]) {
        final label = (nameCounts[c.name] ?? 0) > 1 ? '${_multiServer.liveTvServerName(id)} — ${c.name}' : c.name;
        entries.add((serverId: id, categoryId: c.id, label: label));
      }
    }
    return entries;
  }

  /// Live-TV server ids seen at the last channel load. A listener on the
  /// provider reloads channels when a server binds late (e.g. an IPTV
  /// connection finishing its health probe after this screen opened).
  Set<String> _knownLiveTvServerIds = {};
  bool _reloadAfterLoad = false;

  /// Catalog changes (a filter toggle rebinding an IPTV client, a
  /// background refresh landing) reload the guide's channels (build
  /// #13): before this the guide only reloaded when the server-id SET
  /// changed, so a rebind with the same ids left toggled categories
  /// visible until a restart.
  StreamSubscription<LibraryChangeEvent>? _catalogSubscription;

  // Favorites
  bool _showFavoritesOnly = false;
  Set<String> _favoriteKeys = {};
  List<FavoriteChannel> _favoriteChannels = [];

  /// Favorite source URI, store key and persistence mode per Live TV server/DVR.
  /// The source is built from machineIdentifier + EPG provider identifier.
  final Map<String, _FavoriteScope> _favoriteScopeByLiveServer = {};
  final Map<String, String> _liveServerKeyByChannel = {};

  /// Store key per favorite source. A superset of the scope sources: it also
  /// collects sources of fetched and toggled favorites that belong to other
  /// servers sharing an account-scoped store.
  final Map<String, String> _favoriteStoreBySource = {};
  Future<void>? _channelsLoadFuture;
  int _favoritesLoadGeneration = 0;
  Future<void>? _favoritesLoadFuture;
  final SerialFutureQueue _favoritesMutationQueue = SerialFutureQueue();

  /// True while [_favoriteChannels] holds an authoritative set. A refresh keeps the previous set live until the new
  /// one commits, so the favorites filter never widens mid-load.
  bool _favoritesLoaded = false;
  bool _favoritesWritable = false;

  // Hidden channels (build #17, §9): per-IPTV-connection hidden keys,
  // loaded alongside favorites. The guide filters them out of every
  // channel list (rows, search sheet, counts); hide wins over favorite
  // for display, the favorite itself is kept, so un-hiding restores it.
  Set<String> _hiddenChannelKeys = {};
  bool _hiddenChannelsLoaded = false;

  /// Guide channels with hidden channels removed (build #17, §9). Until
  /// the hidden sets have loaded, nothing is filtered (same flash-guard
  /// as favorites: a hidden channel may show briefly on first load).
  List<LiveTvChannel> get _visibleChannels => _hiddenChannelsLoaded
      ? _channels.where((c) => !_hiddenChannelKeys.contains(_favoriteKeyForChannel(c))).toList(growable: false)
      : _channels;

  /// True when every loaded channel is hidden, so the guide tab shows an
  /// explanatory empty state instead of the favorites one.
  bool get _guideShowsHiddenEmptyState => _channels.isNotEmpty && _visibleChannels.isEmpty;

  List<LiveTvChannel> get _filteredChannels => filterLiveTvChannelsForFavorites(
    channels: _visibleChannels,
    favoritesOnly: _showFavoritesOnly,
    favoritesLoaded: _favoritesLoaded,
    favorites: _favoriteChannels,
    sourceForChannel: _sourceForChannel,
  );

  /// Guide channels after the source picker and the category picker:
  /// only the selected server's channels when one is picked, and only
  /// the selected live TV category's channels when one is picked —
  /// filtered in memory over the loaded rows, never re-fetched (build
  /// #17, §11). Switching the category composes with the favorites
  /// filter above and the source picker.
  List<LiveTvChannel> get _sourceFilteredChannels => filterGuideChannels(
    channels: _filteredChannels,
    sourceId: _selectedLiveTvServerId,
    category: _selectedGuideCategory,
  );

  /// Search-sheet channels: the selected server's channels, but WITHOUT
  /// the favorites filter — the sheet searches the full lineup of the
  /// current source, and the jump drops the favorites filter so the
  /// target row exists to land on (build #15, item 2). The selected
  /// guide category DOES apply here (build #17, §11): searching runs
  /// within the selected category. Hidden channels (build #17, §9) never
  /// appear here either — they have no guide row to jump to.
  List<LiveTvChannel> get _searchSheetChannels => filterGuideChannels(
    channels: _visibleChannels,
    sourceId: _selectedLiveTvServerId,
    category: _selectedGuideCategory,
  );

  /// True when a source is picked but none of its channels loaded — a
  /// provider fetch failure, not an empty playlist — so the guide shows a
  /// reload action instead of a bare grid.
  bool get _selectedSourceHasNoChannels {
    final selected = _selectedLiveTvServerId;
    return selected != null && !_channels.any((c) => c.serverId == selected);
  }

  /// True when the favorites filter removed every loaded channel, so the guide
  /// tab shows an explanatory empty state instead of a bare timeline.
  bool get _guideShowsFavoritesEmptyState => _channels.isNotEmpty && _filteredChannels.isEmpty;

  /// True when the selected guide category removed every loaded channel,
  /// so the guide tab shows a category empty state (not the favorites
  /// one) instead of a bare timeline. A category can be empty when its
  /// channels failed to load, or when the favorites filter removed them.
  bool get _guideShowsCategoryEmptyState =>
      _selectedGuideCategory != null && _sourceFilteredChannels.isEmpty && _channels.isNotEmpty;

  String _liveServerScopeKey(LiveTvServerInfo serverInfo) => '${serverInfo.serverId}\u0000${serverInfo.dvrKey}';

  _FavoriteScope? _favoriteScopeForChannel(LiveTvChannel channel) {
    final liveServerKey = _liveServerKeyByChannel[liveTvChannelScopeKey(channel)];
    return liveServerKey == null ? null : _favoriteScopeByLiveServer[liveServerKey];
  }

  String _sourceForChannel(LiveTvChannel channel) {
    return channel.favoriteSource ?? _favoriteScopeForChannel(channel)?.source ?? '';
  }

  String _favoriteKeyForChannel(LiveTvChannel channel) => favoriteChannelKey(_sourceForChannel(channel), channel.key);

  bool _isFavoriteChannel(LiveTvChannel channel) => _favoriteKeys.contains(_favoriteKeyForChannel(channel));

  void _refreshFavoriteKeys() {
    _favoriteKeys = _favoriteChannels.map((f) => f.stableKey).toSet();
  }

  @override
  List<FocusNode> get tabChipFocusNodes => [for (final tab in _visibleTabs) _focusNodeForTab(tab)];

  FocusNode _focusNodeForTab(LiveTvTab tab) => switch (tab) {
    LiveTvTab.guide => _guideTabFocusNode,
    LiveTvTab.whatsOn => _whatsOnTabFocusNode,
    LiveTvTab.recordings => _recordingsTabFocusNode,
  };

  @override
  void initState() {
    super.initState();
    suppressAutoFocus = true;
    _showFavoritesOnly = context.settingsRead(SettingsService.liveTvDefaultFavorites);
    final provider = context.read<MultiServerProvider>();
    _multiServer = provider;
    _knownLiveTvServerIds = provider.liveTvServers.map((s) => s.serverId).toSet();
    provider.addListener(_onLiveTvServersChanged);
    _catalogSubscription = LibraryContentNotifier().stream.listen((event) {
      // Only our own servers' catalogs matter; other servers' refreshes
      // must not reload this guide (and a rebind of one of ours is
      // exactly what this is for).
      if (!_multiServer.liveTvServers.any((s) => s.serverId == event.serverId)) return;
      // A VOD- or series-only refresh (movies/series background refresh
      // landing) changes nothing the guide shows — reloading here rebuilt
      // the whole channel list and re-fetched EPG for visible channels
      // for nothing (build #14, SA-4 partial).
      if (!event.liveCatalogChanged) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_channelsLoadFuture != null) {
          _reloadAfterLoad = true;
        } else {
          unawaited(_loadChannels());
        }
      });
    });
    final initialTabs = _tabStateFor(provider);
    _visibleTabs = initialTabs.tabs;
    _canProcessRules = initialTabs.canProcessRules;
    initTabNavigation();
    _loadChannels();
  }

  @override
  void dispose() {
    _catalogSubscription?.cancel();
    _multiServer.removeListener(_onLiveTvServersChanged);
    _guideTabFocusNode.dispose();
    _whatsOnTabFocusNode.dispose();
    _recordingsTabFocusNode.dispose();
    _guideEmptyStateActionFocusNode.dispose();
    disposeTabNavigation();
    super.dispose();
  }

  /// Reload channels when the live-TV server set changes (a late-bound
  /// IPTV connection, or one going offline). Deferred a frame: the
  /// provider can notify mid-build, and [_loadChannels] calls setState.
  void _onLiveTvServersChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final currentIds = _multiServer.liveTvServers.map((s) => s.serverId).toSet();
      if (setEquals(currentIds, _knownLiveTvServerIds)) return;
      _knownLiveTvServerIds = currentIds;
      // Drop a selection whose server went away, so the guide falls back
      // to all sources instead of an empty list.
      if (_selectedLiveTvServerId != null && !currentIds.contains(_selectedLiveTvServerId)) {
        _selectedLiveTvServerId = null;
      }
      final selectedCategory = _selectedGuideCategory;
      if (selectedCategory != null && !currentIds.contains(selectedCategory.serverId)) {
        _selectedGuideCategory = null;
      }
      if (_channelsLoadFuture != null) {
        // A load is already running without the new server; run one more
        // pass when it finishes (see [_loadChannels]).
        _reloadAfterLoad = true;
      } else {
        unawaited(_loadChannels());
      }
    });
  }

  @override
  void onTabChanged() {
    if (!tabController.indexIsChanging) {
      super.onTabChanged();
      // Pause/resume timers based on active tab
      if (tabController.index >= _visibleTabs.length) return;
      switch (_visibleTabs[tabController.index]) {
        case LiveTvTab.guide:
          _whatsOnTabKey.currentState?.pauseRefresh();
          _recordingsTabKey.currentState?.pauseRefresh();
          _guideTabKey.currentState?.resumeRefresh();
        case LiveTvTab.whatsOn:
          _guideTabKey.currentState?.pauseRefresh();
          _recordingsTabKey.currentState?.pauseRefresh();
          _whatsOnTabKey.currentState?.resumeRefresh();
        case LiveTvTab.recordings:
          _guideTabKey.currentState?.pauseRefresh();
          _whatsOnTabKey.currentState?.pauseRefresh();
          _recordingsTabKey.currentState?.resumeRefresh();
      }
    }
  }

  LiveTvTab? get _currentTab {
    if (tabController.index < 0 || tabController.index >= _visibleTabs.length) return null;
    return _visibleTabs[tabController.index];
  }

  @override
  void manualRefresh() => unawaited(_onRefresh());

  /// Tab-aware refresh handler bound to the AppBar refresh button.
  /// - Guide / What's On: server-side `reloadGuide` per DVR-capable client +
  ///   client-side channel re-fetch.
  /// - Recordings: re-fetches scheduled recordings + rules.
  Future<void> _onRefresh() async {
    if (_currentTab == LiveTvTab.recordings) {
      await _recordingsTabKey.currentState?.reload();
      return;
    }
    await _broadcastToDvrs(
      actionLabel: 'Reload guide',
      successMessage: t.liveTv.guideReloadRequested,
      failureMessage: t.liveTv.guideReloadFailed,
      action: (dvr, serverInfo) => dvr.reloadGuide(serverInfo.dvrKey),
    );
    await _loadChannels();
  }

  /// Runs [action] on every DVR-capable Live TV server in parallel, then
  /// reports the outcome: [successMessage] once every DVR accepted the
  /// request, otherwise an error naming the failure — `dvrAdminRequired`
  /// when every failure was a 403 (admin only), else [failureMessage].
  /// Per-DVR failures never abort the broadcast; they are logged under
  /// [actionLabel] and the remaining DVRs still run, since callers re-fetch
  /// their own client-side state regardless. Returns `true` once at least
  /// one DVR was reached and this widget is still mounted.
  Future<bool> _broadcastToDvrs({
    required String actionLabel,
    required String successMessage,
    required String failureMessage,
    required Future<void> Function(LiveTvDvrSupport dvr, LiveTvServerInfo serverInfo) action,
  }) async {
    final multiServer = context.read<MultiServerProvider>();
    var failed = 0;
    var adminBlocked = 0;
    Future<void> runSafely(LiveTvDvrSupport dvr, LiveTvServerInfo serverInfo) async {
      try {
        await action(dvr, serverInfo);
      } catch (e, stackTrace) {
        failed++;
        if (e is MediaServerHttpException && e.statusCode == 403) adminBlocked++;
        appLogger.w('$actionLabel failed for DVR ${serverInfo.dvrKey}', error: e, stackTrace: stackTrace);
      }
    }

    final futures = <Future<void>>[];
    for (final serverInfo in multiServer.liveTvServers) {
      final dvr = multiServer.getClientForServer(ServerId(serverInfo.serverId))?.liveTvDvr;
      if (dvr == null) continue;
      futures.add(runSafely(dvr, serverInfo));
    }
    if (futures.isEmpty) return false;
    await Future.wait(futures);
    if (!mounted) return false;
    if (failed == 0) {
      showSnackBar(context, successMessage);
    } else {
      final message = adminBlocked == failed ? t.liveTv.dvrAdminRequired : failureMessage;
      showSnackBar(context, message, type: SnackBarType.error);
    }
    return true;
  }

  Future<void> _processRecordingRules() async {
    final reached = await _broadcastToDvrs(
      actionLabel: 'processRecordingRules',
      successMessage: t.liveTv.rulesProcessRequested,
      failureMessage: t.liveTv.rulesProcessFailed,
      action: (dvr, _) => dvr.processRecordingRules(),
    );
    if (!reached) return;
    await _recordingsTabKey.currentState?.reload();
  }

  ({List<LiveTvTab> tabs, bool canProcessRules}) _tabStateFor(MultiServerProvider multiServer) {
    var hasPlexServer = false;
    var hasDvr = false;
    var canProcessRules = false;
    for (final s in multiServer.liveTvServers) {
      final serverId = ServerId(s.serverId);
      // What's On lists Plex's Live TV hubs; Jellyfin and Emby have none, so
      // the tab would only ever be empty for them.
      hasPlexServer = hasPlexServer || multiServer.getPlexClientForServer(serverId) != null;
      final dvr = multiServer.getClientForServer(serverId)?.liveTvDvr;
      if (dvr == null) continue;
      hasDvr = true;
      canProcessRules = canProcessRules || dvr.supportsRuleProcessing;
    }
    return (
      tabs: [LiveTvTab.guide, if (hasPlexServer) LiveTvTab.whatsOn, if (hasDvr) LiveTvTab.recordings],
      canProcessRules: canProcessRules,
    );
  }

  /// Recompute visible tabs from the current MultiServerProvider state.
  /// Re-inits the tab controller when the visible set changes (matches the
  /// libraries-screen pattern at libraries_screen.dart:365).
  void _refreshVisibleTabs(MultiServerProvider multiServer) {
    final (tabs: newTabs, :canProcessRules) = _tabStateFor(multiServer);
    if (canProcessRules != _canProcessRules) {
      setState(() => _canProcessRules = canProcessRules);
    }
    if (listEquals(_visibleTabs, newTabs)) return;
    final currentTab = tabController.index < _visibleTabs.length ? _visibleTabs[tabController.index] : null;
    disposeTabNavigation();
    _visibleTabs = newTabs;
    initTabNavigation();
    if (currentTab != null) {
      final newIndex = newTabs.indexOf(currentTab);
      if (newIndex >= 0) tabController.index = newIndex;
    }
  }

  /// Extracts enabled channel keys from DVR mappings, returning null if no DVR has mapping data.
  Set<String>? _extractEnabledChannelKeys(List<LiveTvDvr> dvrs) {
    final enabledKeys = <String>{};
    bool hasMappings = false;
    for (final dvr in dvrs) {
      if (dvr.channelMappings.isEmpty) continue;
      hasMappings = true;
      for (final m in dvr.channelMappings) {
        if (m.enabled == true && m.channelKey != null) {
          enabledKeys.add(m.channelKey!);
        }
      }
    }
    return hasMappings ? enabledKeys : null;
  }

  Set<String>? _extractEnabledChannelKeysForServerInfo(LiveTvServerInfo serverInfo) {
    final matching = serverInfo.dvrs.where((dvr) => dvr.key == serverInfo.dvrKey).toList();
    return _extractEnabledChannelKeys(matching.isNotEmpty ? matching : serverInfo.dvrs);
  }

  String? _sourceTitleForServerInfo(LiveTvServerInfo serverInfo) {
    for (final dvr in serverInfo.dvrs) {
      if (dvr.key == serverInfo.dvrKey) {
        return liveTvNonEmpty(dvr.lineupTitle) ?? liveTvNonEmpty(dvr.lineupURL) ?? liveTvNonEmpty(dvr.lineup);
      }
    }
    return liveTvNonEmpty(serverInfo.lineup);
  }

  Future<void> _loadChannels() {
    final inFlight = _channelsLoadFuture;
    if (inFlight != null) return inFlight;
    late final Future<void> load;
    load = _loadChannelsOnce().whenComplete(() {
      if (identical(_channelsLoadFuture, load)) _channelsLoadFuture = null;
      // A server bound while this load was running: fetch once more so its
      // channels are included instead of waiting for a manual refresh.
      if (_reloadAfterLoad) {
        _reloadAfterLoad = false;
        unawaited(_loadChannels());
      }
    });
    _channelsLoadFuture = load;
    return load;
  }

  Future<void> _loadChannelsOnce() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final multiServer = context.read<MultiServerProvider>();
      final liveTvServers = multiServer.liveTvServers;

      if (liveTvServers.isEmpty) {
        setState(() {
          _isLoading = false;
          _error = t.liveTv.noDvr;
        });
        return;
      }

      final allChannels = <LiveTvChannel>[];
      final seenChannels = <String>{};
      final favoriteScopeByLiveServer = <String, _FavoriteScope>{};
      final liveServerKeyByChannel = <String, String>{};
      final favoriteStoreBySource = <String, String>{};

      appLogger.d(
        'Live TV DVRs: ${liveTvServers.map((s) => '${s.serverId}/${s.dvrKey} lineup=${s.lineup}').join(', ')}',
      );

      // Build a set of enabled channel keys per Live TV DVR from cached DVR data.
      final enabledKeysByLiveServer = <String, Set<String>>{};
      for (final serverInfo in liveTvServers) {
        final enabledKeys = _extractEnabledChannelKeysForServerInfo(serverInfo);
        if (enabledKeys != null) {
          enabledKeysByLiveServer[_liveServerScopeKey(serverInfo)] = enabledKeys;
        }
      }

      var serversTried = 0;
      var serversFailed = 0;
      Object? firstFailure;

      // One liveTvServers entry per DVR: visit them all; channels dedupe below.
      await forEachLiveTvServer(
        multiServer,
        resolveClient: multiServer.getClientForServer,
        dedupeByServerId: false,
        body: (genericClient, serverInfo) async {
          serversTried++;
          final liveTv = genericClient.liveTv;
          final source = await liveTv.buildFavoriteChannelSource(lineup: serverInfo.lineup);
          final sourceTitle = _sourceTitleForServerInfo(serverInfo);
          final storeKey = liveTv.favoriteStoreKey;
          final liveServerKey = _liveServerScopeKey(serverInfo);
          favoriteScopeByLiveServer[liveServerKey] = (
            source: source,
            storeKey: storeKey,
            mode: liveTv.favoritePersistenceMode,
          );
          favoriteStoreBySource[source] = storeKey;

          final channels = await genericClient.liveTv.fetchChannels(lineup: serverInfo.lineup);
          // Plex's DVR exposes a separate enabled-channel mapping; Jellyfin
          // already filters to subscribed channels server-side.
          final enabledKeys = enabledKeysByLiveServer[liveServerKey];
          appLogger.d(
            'Channels from ${serverInfo.dvrKey}: ${channels.length} channels (${enabledKeys?.length ?? 'all'} enabled)',
          );
          for (final channel in channels) {
            if (enabledKeys != null && !enabledKeys.contains(channel.key)) continue;
            final scopedChannel = channel.copyWith(
              liveDvrKey: serverInfo.dvrKey,
              liveTvSourceTitle: sourceTitle,
              favoriteSource: source,
              favoriteStoreKey: storeKey,
            );
            final dedupKey = liveTvChannelScopeKey(scopedChannel);
            if (seenChannels.add(dedupKey)) {
              liveServerKeyByChannel[dedupKey] = liveServerKey;
              allChannels.add(scopedChannel);
            }
          }
        },
        onError: (client, serverInfo, error, stackTrace) {
          serversFailed++;
          firstFailure ??= error;
          appLogger.e('Failed to load channels from server ${serverInfo.serverId}', error: error);
        },
      );

      final failure = firstFailure;
      if (failure != null && serversFailed == serversTried) {
        if (!mounted) return;
        // Every server failed, so there is nothing to replace the loaded
        // channels with: keep them and report the failure, or show the error
        // state when there were none (not an empty "no channels" guide).
        final message = localizedLoadErrorText(failure, context: t.liveTv.title);
        final keepChannels = _channels.isNotEmpty;
        setState(() {
          _isLoading = false;
          if (!keepChannels) _error = message;
        });
        if (keepChannels) showErrorSnackBar(context, message);
        return;
      }

      allChannels.sort((a, b) {
        final aNum = double.tryParse(a.number ?? '') ?? 999999;
        final bNum = double.tryParse(b.number ?? '') ?? 999999;
        return aNum.compareTo(bNum);
      });

      if (!mounted) return;

      appLogger.d('Live TV: loaded ${allChannels.length} channels');

      setState(() {
        _channels = allChannels;
        _favoriteScopeByLiveServer
          ..clear()
          ..addAll(favoriteScopeByLiveServer);
        _liveServerKeyByChannel
          ..clear()
          ..addAll(liveServerKeyByChannel);
        _favoriteStoreBySource
          ..clear()
          ..addAll(favoriteStoreBySource);
        _isLoading = false;
      });

      _refreshVisibleTabs(multiServer);

      // Guide category picker entries (build #17, §11): disk-first and
      // cheap, so they load after the channels without delaying the grid.
      // Reloads with the channels on catalog changes (a toggle in IPTV
      // settings rebinds the client and re-runs _loadChannels), so a
      // category turned off disappears from the picker with its rows.
      unawaited(_loadGuideCategories());

      // Load favorites by backend store: Plex is cloud/account-scoped, Jellyfin per server.
      final favoritesLoad = _loadFavorites(multiServer);
      _favoritesLoadFuture = favoritesLoad;
      unawaited(
        favoritesLoad.whenComplete(() {
          if (identical(_favoritesLoadFuture, favoritesLoad)) {
            _favoritesLoadFuture = null;
          }
        }),
      );

      // Hidden channels (build #17, §9): the per-IPTV-connection hidden
      // sets, loaded alongside favorites so the guide filters them from
      // the first paint. Plex/Jellyfin channels have no hide store.
      unawaited(_loadHiddenChannels(multiServer));

      if (allChannels.isNotEmpty && PlatformDetector.shouldUseSideNavigation(context)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusCurrentTab();
        });
      }
    } catch (e, stackTrace) {
      final message = localizedLoadErrorMessage(e, stackTrace, context: t.liveTv.title);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = message;
        });
      }
    }
  }

  /// Guide category picker entries (build #17, §11): the visible live
  /// categories of every connected IPTV server. One failure never loses
  /// the other servers' entries. A selection whose category went away
  /// (turned off in IPTV settings) falls back to all categories.
  Future<void> _loadGuideCategories() async {
    final multiServer = _multiServer;
    final byServer = <String, List<({String id, String name})>>{};
    for (final serverInfo in multiServer.liveTvServers) {
      final client = multiServer.getClientForServer(ServerId(serverInfo.serverId));
      if (client is! IptvClient) continue;
      try {
        byServer[serverInfo.serverId] = await client.visibleLiveCategories();
      } catch (e) {
        appLogger.w('Live TV: guide categories unavailable for ${serverInfo.serverId}: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      _guideCategoriesByServer
        ..clear()
        ..addAll(byServer);
      final selected = _selectedGuideCategory;
      if (selected != null) {
        final stillThere = (byServer[selected.serverId] ?? const <({String id, String name})>[]).any(
          (c) => c.id == selected.categoryId,
        );
        if (!stillThere) _selectedGuideCategory = null;
      }
    });
  }

  Future<void> _loadFavorites(MultiServerProvider multiServer) async {    final loadGeneration = ++_favoritesLoadGeneration;
    _favoritesWritable = false;
    final previousStoreBySource = Map<String, String>.of(_favoriteStoreBySource);
    final scopeByLiveServer = Map<String, _FavoriteScope>.of(_favoriteScopeByLiveServer);
    final storeBySource = Map<String, String>.of(_favoriteStoreBySource);
    final merged = <FavoriteChannel>[];
    final successfulStores = <String>{};
    final failedStores = <String>{};
    final seenFavorites = <String>{};

    // One liveTvServers entry per DVR: register every favorite scope, but
    // fetch each favorite store only once.
    await forEachLiveTvServer(
      multiServer,
      resolveClient: multiServer.getClientForServer,
      dedupeByServerId: false,
      body: (client, serverInfo) async {
        final liveTv = client.liveTv;
        final storeKey = liveTv.favoriteStoreKey;
        final liveServerKey = _liveServerScopeKey(serverInfo);

        final source = await liveTv.buildFavoriteChannelSource(lineup: serverInfo.lineup);
        scopeByLiveServer[liveServerKey] = (source: source, storeKey: storeKey, mode: liveTv.favoritePersistenceMode);
        storeBySource[source] = storeKey;
        if (successfulStores.contains(storeKey)) return;

        final serverFavorites = await liveTv.fetchFavoriteChannels();
        successfulStores.add(storeKey);
        failedStores.remove(storeKey);
        for (final favorite in serverFavorites) {
          storeBySource[favorite.source] = storeKey;
          if (seenFavorites.add(favorite.stableKey)) merged.add(favorite);
        }
      },
      onError: (client, serverInfo, error, stackTrace) {
        final storeKey = client.liveTv.favoriteStoreKey;
        if (!successfulStores.contains(storeKey)) failedStores.add(storeKey);
        appLogger.e('Failed to load favorite channels for $storeKey', error: error, stackTrace: stackTrace);
      },
    );

    // A failed store keeps its last committed in-memory slice. Healthy stores
    // still refresh, but mutations stay disabled until every store has loaded
    // so a later persist cannot replace the failed store with an empty list.
    for (final favorite in _favoriteChannels) {
      final storeKey = previousStoreBySource[favorite.source];
      if (storeKey != null && failedStores.contains(storeKey) && seenFavorites.add(favorite.stableKey)) {
        merged.add(favorite);
      }
    }

    if (!mounted || loadGeneration != _favoritesLoadGeneration) return;
    setState(() {
      _favoriteScopeByLiveServer
        ..clear()
        ..addAll(scopeByLiveServer);
      _favoriteStoreBySource
        ..clear()
        ..addAll(storeBySource);
      _favoriteChannels = merged;
      _refreshFavoriteKeys();
      _favoritesLoaded = failedStores.isEmpty || successfulStores.isNotEmpty || merged.isNotEmpty;
      _favoritesWritable = failedStores.isEmpty;
    });
    appLogger.d(
      'Live TV: loaded ${merged.length} favorite channels'
      '${failedStores.isEmpty ? '' : ' (${failedStores.length} store(s) deferred)'}',
    );
  }

  void _toggleFavoritesFilter() {
    setState(() {
      _showFavoritesOnly = !_showFavoritesOnly;
    });
  }

  /// Clears the favorites filter from the guide's empty state. When the action
  /// button owned the focus (TV/D-pad), hand focus to the guide content that
  /// replaces it so focus is not dropped.
  void _showAllChannelsFromEmptyState() {
    final hadFocus = _guideEmptyStateActionFocusNode.hasFocus;
    _toggleFavoritesFilter();
    if (!hadFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusCurrentTab();
    });
  }

  void _toggleFavorite(LiveTvChannel channel) {
    _enqueueFavoriteMutation(() {
      final source = _sourceForChannel(channel);
      final favoriteKey = favoriteChannelKey(source, channel.key);
      final storeKey = channel.favoriteStoreKey ?? _favoriteScopeForChannel(channel)?.storeKey;
      if (storeKey != null) _favoriteStoreBySource[source] = storeKey;

      setState(() {
        if (_favoriteKeys.contains(favoriteKey)) {
          _favoriteChannels = _favoriteChannels.where((f) => f.id != channel.key || f.source != source).toList();
        } else {
          _favoriteChannels = [..._favoriteChannels, FavoriteChannel.fromLiveTvChannel(channel, source)];
        }
        _refreshFavoriteKeys();
      });
    });
  }

  /// Load the per-IPTV-connection hidden-channel sets (build #17, §9) and
  /// union them into [_hiddenChannelKeys]. Runs alongside favorites on
  /// every channel load, so a rebind/refresh re-reads the store and a
  /// hidden channel stays hidden.
  Future<void> _loadHiddenChannels(MultiServerProvider multiServer) async {
    final hidden = <String>{};
    var loaded = false;
    for (final server in multiServer.liveTvServers) {
      final client = multiServer.getClientForServer(ServerId(server.serverId));
      if (client is! IptvClient) continue;
      final support = client.liveTv;
      if (support is! IptvLiveTvSupport) continue;
      hidden.addAll(await support.loadHiddenChannels());
      loaded = true;
    }
    if (!mounted) return;
    setState(() {
      _hiddenChannelKeys = hidden;
      _hiddenChannelsLoaded = loaded;
    });
  }

  IptvLiveTvSupport? _iptvSupportForChannel(LiveTvChannel channel) {
    final serverId = serverIdOrNull(channel.serverId);
    if (serverId == null) return null;
    final client = context.read<MultiServerProvider>().getClientForServer(serverId);
    if (client is! IptvClient) return null;
    final support = client.liveTv;
    return support is IptvLiveTvSupport ? support : null;
  }

  /// Hide a channel (build #17, §9): persist it, drop its row from the
  /// guide immediately, and offer Undo. The favorite is kept, so
  /// un-hiding restores it.
  Future<void> _hideChannel(LiveTvChannel channel) async {
    final support = _iptvSupportForChannel(channel);
    if (support == null) return;
    await support.hideChannel(channel);
    if (!mounted) return;
    setState(() => _hiddenChannelKeys.add(_favoriteKeyForChannel(channel)));
    if (!mounted) return;
    showSnackBar(
      context,
      t.iptv.channelHidden(name: channel.title ?? channel.key),
      actionLabel: t.common.undo,
      onAction: () => unawaited(_unhideChannel(channel)),
    );
  }

  Future<void> _unhideChannel(LiveTvChannel channel) async {
    final support = _iptvSupportForChannel(channel);
    if (support == null) return;
    await support.unhideChannel(channel);
    if (!mounted) return;
    setState(() => _hiddenChannelKeys.remove(_favoriteKeyForChannel(channel)));
  }

  /// The IPTV client behind a channel, or null for Plex/Jellyfin/Emby
  /// channels (v1.0.16, guide category submenu).
  IptvClient? _iptvClientForChannel(LiveTvChannel channel) {
    final serverId = serverIdOrNull(channel.serverId);
    if (serverId == null) return null;
    final client = context.read<MultiServerProvider>().getClientForServer(serverId);
    return client is IptvClient ? client : null;
  }

  /// The channel's category for the long-press menu (v1.0.16): the id,
  /// display name, and whether it is currently hidden. The name comes
  /// from the client's live categories (an M3U group's title IS its
  /// name — the group title is both id and name). Null when the channel
  /// has no IPTV category.
  Future<({String id, String name, bool hidden})?> _channelCategory(LiveTvChannel channel) async {
    final categoryId = channel.categoryId;
    if (categoryId == null) return null;
    final client = _iptvClientForChannel(channel);
    if (client == null) return null;
    var name = categoryId;
    if (client.connection is XtreamConnection) {
      final categories = await client.liveCategories();
      name = categories.where((c) => c.id == categoryId).firstOrNull?.name ?? categoryId;
    }
    return (id: categoryId, name: name, hidden: client.isCategoryHidden(categoryId, name));
  }

  /// Flip a whole category's hidden state (v1.0.16): the submenu's
  /// Hide/Show action. Flips the per-category id — the same rule as the
  /// categories screen's per-category row — and swaps the client in
  /// place, so the guide re-renders immediately. A category hidden by
  /// its initial can only be shown again from the categories screen
  /// (un-hiding the initial would un-hide every category sharing it);
  /// the menu only ever offers this for visible channels, so the
  /// per-category flip is exact there. The download/cache skip for the
  /// newly hidden rows happens at the next sync — no second purge path.
  Future<void> _toggleChannelCategory(LiveTvChannel channel, String categoryId, String categoryName) async {
    final client = _iptvClientForChannel(channel);
    if (client == null) return;
    final connection = client.connection;
    final hidden = client.isCategoryHidden(categoryId, categoryName);
    final hiddenIds = switch (connection) {
      M3uConnection(:final hiddenCategoryIds) => hiddenCategoryIds.toSet(),
      XtreamConnection(:final hiddenCategoryIds) => hiddenCategoryIds.toSet(),
      _ => null,
    };
    if (hiddenIds == null) return;
    if (hidden) {
      hiddenIds.remove(categoryId);
    } else {
      hiddenIds.add(categoryId);
    }
    final updated = switch (connection) {
      final M3uConnection c => c.copyWith(hiddenCategoryIds: hiddenIds.toList()),
      final XtreamConnection c => c.copyWith(hiddenCategoryIds: hiddenIds.toList()),
      _ => null,
    };
    if (updated == null) return;
    try {
      await context.read<ConnectionRegistry>().upsert(updated);
      if (!mounted) return;
      unawaited(context.read<MultiServerProvider>().refreshIptvConnection(updated));
    } catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, t.iptvCategories.persistFailed);
    }
  }

  /// Unhide every hidden channel on every loaded IPTV connection (the
  /// all-hidden empty state's action, build #17, §9).
  Future<void> _unhideAllChannels() async {
    final multiServer = context.read<MultiServerProvider>();
    for (final server in multiServer.liveTvServers) {
      final client = multiServer.getClientForServer(ServerId(server.serverId));
      if (client is! IptvClient) continue;
      final support = client.liveTv;
      if (support is! IptvLiveTvSupport) continue;
      await support.unhideAllChannels();
    }
    if (!mounted) return;
    setState(() => _hiddenChannelKeys = {});
  }

  void _enqueueFavoriteMutation(VoidCallback mutation) {
    final pendingLoad = _favoritesLoadFuture;
    unawaited(
      _favoritesMutationQueue
          .run(() async {
            if (pendingLoad != null) await pendingLoad;
            if (!mounted) return;
            if (!_favoritesWritable) {
              showErrorSnackBar(context, t.liveTv.favoritesLoadFailed);
              return;
            }
            mutation();
            await _persistFavorites();
          })
          .catchError((Object error, StackTrace stackTrace) {
            appLogger.e('Failed to mutate favorite channels', error: error, stackTrace: stackTrace);
            if (mounted) {
              showErrorSnackBar(context, t.liveTv.favoritesUpdateFailed);
            }
          }),
    );
  }

  void _showGuideSearch() {
    OverlaySheetController.showAdaptive(
      context,
      isScrollControlled: true,
      builder: (sheetContext) => GuideSearchSheet(
        // Build #15, item 2: the current source's full lineup, not every
        // channel — results must be jumpable in the current tab — and
        // not the favorites-filtered list, so the sheet searches the
        // full lineup of that source.
        channels: _searchSheetChannels,
        selectedServerId: _selectedLiveTvServerId,
        onChannelSelected: _jumpToGuideChannel,
        onProgramSelected: (channel, program) => _jumpToGuideChannel(channel, program: program),
      ),
    );
  }

  void _jumpToGuideChannel(LiveTvChannel channel, {LiveTvProgram? program}) {
    // The guide only shows favorite rows while the filter is on — drop it so
    // the target channel's row exists to land on.
    if (_showFavoritesOnly && !_isFavoriteChannel(channel)) {
      setState(() => _showFavoritesOnly = false);
    }
    // Search opens from any tab, but results live in the guide grid. A tab
    // switch builds GuideTab fresh (no keep-alive); its jump methods stash
    // the request until the initial program load completes.
    final guideIndex = _visibleTabs.indexOf(LiveTvTab.guide);
    if (guideIndex >= 0 && tabController.index != guideIndex) {
      setState(() => tabController.index = guideIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _jumpToGuideChannelOnce(channel, program: program);
    });
  }

  /// One jump attempt. On a miss, switch the source picker to the result's
  /// server and try once more, so a tap never silently does nothing (build
  /// #15, item 2). If it still misses, say so — the channel left the guide
  /// between the search and the tap (a reload dropped it).
  void _jumpToGuideChannelOnce(LiveTvChannel channel, {LiveTvProgram? program, bool retried = false}) {
    final guide = _guideTabKey.currentState;
    if (guide == null) return;
    Future<bool> attempt() async {
      if (program != null) return guide.jumpToProgram(channel, program);
      return guide.jumpToChannel(channel);
    }

    unawaited(
      attempt().then((landed) {
        if (landed || retried || !mounted) return;
        final serverId = channel.serverId;
        if (serverId == null || serverId == _selectedLiveTvServerId) {
          showErrorSnackBar(context, t.liveTv.searchJumpNotFound);
          return;
        }
        setState(() {
          _selectedLiveTvServerId = serverId;
          // The jump target lives on the new source; a category picked
          // on the old source would hide it (build #17, §11).
          _selectedGuideCategory = null;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _jumpToGuideChannelOnce(channel, program: program, retried: true);
        });
      }),
    );
  }

  void _showReorderFavorites() {
    final channelMap = {for (final c in _channels) _favoriteKeyForChannel(c): c};

    OverlaySheetController.showAdaptive(
      context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => ReorderFavoritesSheet(
        favorites: List.from(_favoriteChannels),
        channelMap: channelMap,
        onReorder: (reordered) {
          _enqueueFavoriteMutation(() {
            setState(() {
              _favoriteChannels = reordered;
              _refreshFavoriteKeys();
            });
          });
        },
        onRemove: (removed) {
          _enqueueFavoriteMutation(() {
            setState(() {
              _favoriteChannels = _favoriteChannels.where((f) => f.stableKey != removed.stableKey).toList();
              _refreshFavoriteKeys();
            });
          });
        },
      ),
    );
  }

  Future<void> _persistFavorites() async {
    final multiServer = context.read<MultiServerProvider>();
    final byStore = <String, List<FavoriteChannel>>{};
    for (final favorite in _favoriteChannels) {
      final storeKey = _favoriteStoreBySource[favorite.source];
      if (storeKey == null) continue;
      byStore.putIfAbsent(storeKey, () => []).add(favorite);
    }
    final writtenStores = <String>{};
    final writes = <Future<void>>[];
    for (final serverInfo in multiServer.liveTvServers) {
      final client = multiServer.getClientForServer(ServerId(serverInfo.serverId));
      if (client == null) continue;
      final scope = _favoriteScopeByLiveServer[_liveServerScopeKey(serverInfo)];
      if (scope == null || !writtenStores.add(scope.storeKey)) continue;
      final storeChannels = byStore[scope.storeKey] ?? const <FavoriteChannel>[];
      final channels = switch (scope.mode) {
        FavoriteChannelPersistenceMode.sharedFullList => storeChannels,
        FavoriteChannelPersistenceMode.serverSlice =>
          storeChannels.where((favorite) => favorite.source == scope.source).toList(),
      };
      writes.add(client.liveTv.setFavoriteChannels(channels));
    }
    await Future.wait(writes);
  }

  void _focusCurrentTab() {
    if (tabController.index < _visibleTabs.length) {
      switch (_visibleTabs[tabController.index]) {
        case LiveTvTab.guide:
          final guideState = _guideTabKey.currentState;
          if (guideState != null) {
            guideState.focusContent();
          } else if (_guideShowsFavoritesEmptyState && _guideEmptyStateActionFocusNode.context != null) {
            _guideEmptyStateActionFocusNode.requestFocus();
          }
        case LiveTvTab.whatsOn:
          _whatsOnTabKey.currentState?.focusFirstHub();
        case LiveTvTab.recordings:
          _recordingsTabKey.currentState?.focusContent();
      }
    }
    setState(() {
      suppressAutoFocus = false;
    });
  }

  @override
  void focusActiveTabIfReady() => _focusCurrentTab();

  String _getTabLabel(LiveTvTab tab) {
    return switch (tab) {
      LiveTvTab.guide => t.liveTv.guide,
      LiveTvTab.whatsOn => t.liveTv.whatsOn,
      LiveTvTab.recordings => t.liveTv.recordings,
    };
  }

  List<Widget> _buildTabChipItems() {
    return [
      for (int i = 0; i < _visibleTabs.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        buildTabChip(
          _getTabLabel(_visibleTabs[i]),
          i,
          onSelectWhenActive: _focusCurrentTab,
          onNavigateDown: _focusCurrentTab,
          onNavigateToActions: () => _actionBarKey.currentState?.requestFocusOnFirst(),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final useSideNav = PlatformDetector.shouldUseSideNavigation(context);

    final isRecordings = _currentTab == LiveTvTab.recordings;
    return Scaffold(
      // Build #17: transparent, so the Live TV mini-player's video hole
      // can reveal the native surface below the Flutter view. The
      // MainScreen portrait Scaffold is transparent on this tab too —
      // both layers must be clear. The background behind is the Android
      // window, synced to the theme mode by PlezyActivity. The AppBar
      // above and the guide cells below still paint their own colors.
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: useSideNav ? TabChipStrip(children: _buildTabChipItems()) : Text(t.liveTv.title),
        actions: DesktopAppBarHelper.buildAdjustedActions([
          FocusableActionBar(
            key: _actionBarKey,
            onNavigateLeft: () => getTabChipFocusNode(tabCount - 1).requestFocus(),
            onNavigateDown: _focusCurrentTab,
            actions: [
              // Shown on every tab: the d-pad route into this bar traverses
              // the tab chips, and RIGHT selects each tab it crosses — a
              // guide-only action would be unmounted before focus could ever
              // reach it. Selecting a result switches back to the guide tab.
              FocusableAction(icon: Symbols.search_rounded, tooltip: t.liveTv.searchGuide, onPressed: _showGuideSearch),
              if (!isRecordings)
                FocusableAction(
                  icon: _showFavoritesOnly ? Symbols.star_rounded : Symbols.star_outline_rounded,
                  iconFill: _showFavoritesOnly ? 1.0 : 0.0,
                  tooltip: t.liveTv.favorites,
                  onPressed: _toggleFavoritesFilter,
                ),
              if (!isRecordings && _showFavoritesOnly && _favoriteChannels.length > 1)
                FocusableAction(
                  icon: Symbols.swap_vert_rounded,
                  tooltip: t.liveTv.reorderFavorites,
                  onPressed: _showReorderFavorites,
                ),
              // Rule re-evaluation is a Plex-only server operation; hide the
              // bolt when no connected DVR supports it (MediaBrowser).
              if (isRecordings && _canProcessRules)
                FocusableAction(
                  icon: Symbols.bolt_rounded,
                  tooltip: t.liveTv.processRecordingRules,
                  onPressed: _processRecordingRules,
                ),
              FocusableAction(
                icon: Symbols.refresh_rounded,
                tooltip: isRecordings ? t.common.refresh : t.liveTv.reloadGuide,
                onPressed: manualRefresh,
              ),
            ],
          ),
        ]),
      ),
      // Horizontal-only SafeArea: chips, guide, and lists clear a landscape
      // notch or iPhone Duo's portrait sensor column.
      body: SafeArea(top: false, bottom: false, child: _buildLiveTvBody(useSideNav)),
    );
  }

  Widget _buildTabContent(LiveTvTab tab, List<LiveTvChannel> guideChannels) {
    return switch (tab) {
      LiveTvTab.guide => _selectedSourceHasNoChannels
          ? EmptyStateWidget(
              icon: Symbols.live_tv_rounded,
              message: t.liveTv.noChannelsFromSource(
                name: context.read<MultiServerProvider>().liveTvServerName(_selectedLiveTvServerId!),
              ),
              subtitle: t.liveTv.noChannelsFromSourceHint,
              actionLabel: t.liveTv.reloadGuide,
              actionIcon: Symbols.refresh_rounded,
              actionFocusNode: _guideEmptyStateActionFocusNode,
              onAction: () => unawaited(_loadChannels()),
              onActionNavigateUp: focusTabBar,
              onActionBack: onTabBarBack,
            )
          : _guideShowsCategoryEmptyState
              ? EmptyStateWidget(
                  icon: Symbols.category_rounded,
                  message: t.liveTv.noChannelsInCategory,
                  subtitle: t.liveTv.noChannelsInCategoryHint,
                  actionLabel: t.liveTv.showAllCategories,
                  actionIcon: Symbols.list_rounded,
                  actionFocusNode: _guideEmptyStateActionFocusNode,
                  onAction: () => setState(() => _selectedGuideCategory = null),
                  onActionNavigateUp: focusTabBar,
                  onActionBack: onTabBarBack,
                )
              : _guideShowsHiddenEmptyState
              ? EmptyStateWidget(
                  icon: Symbols.visibility_off_rounded,
                  message: t.liveTv.allChannelsHidden,
                  subtitle: t.liveTv.allChannelsHiddenHint,
                  actionLabel: t.liveTv.unhideAllChannels,
                  actionIcon: Symbols.visibility_rounded,
                  actionFocusNode: _guideEmptyStateActionFocusNode,
                  onAction: () => unawaited(_unhideAllChannels()),
                  onActionNavigateUp: focusTabBar,
                  onActionBack: onTabBarBack,
                )
              : guideChannels.isEmpty && _channels.isNotEmpty
                  ? EmptyStateWidget(
                      icon: Symbols.star_outline_rounded,
                      message: t.liveTv.noFavoriteChannels,
                      subtitle: t.liveTv.noFavoriteChannelsHint,
                      actionLabel: t.liveTv.showAllChannels,
                      actionIcon: Symbols.list_rounded,
                      actionFocusNode: _guideEmptyStateActionFocusNode,
                      onAction: _showAllChannelsFromEmptyState,
                      onActionNavigateUp: focusTabBar,
                      onActionBack: onTabBarBack,
                    )
                  : GuideTab(
                      key: _guideTabKey,
                      channels: guideChannels,
                      showCatchUpBadge: context.settingsRead(SettingsService.iptvShowCatchUpBadge),
                      isFavoriteChannel: _isFavoriteChannel,
                      onToggleFavorite: _toggleFavorite,
                      onHideChannel: _hideChannel,
                      channelCategory: _channelCategory,
                      onToggleCategory: _toggleChannelCategory,
                      onNavigateUp: focusTabBar,
                      onBack: onTabBarBack,
                      guideCategories: _guideCategoryEntries,
                      selectedGuideCategory: _selectedGuideCategory,
                      onSelectGuideCategory: (entry) => setState(() => _selectedGuideCategory = entry),
                    ),
      LiveTvTab.whatsOn => WhatsOnTab(
        key: _whatsOnTabKey,
        channels: _channels,
        onNavigateUp: focusTabBar,
        onBack: onTabBarBack,
      ),
      LiveTvTab.recordings => RecordingsTab(key: _recordingsTabKey, onNavigateUp: focusTabBar, onBack: onTabBarBack),
    };
  }

  Widget _buildLiveTvBody(bool useSideNav) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return ErrorStateWidget(
        message: _error!,
        icon: Symbols.error_rounded,
        onRetry: _loadChannels,
        actionAutofocus: true,
        actionUseBackgroundFocus: true,
      );
    }
    if (_channels.isEmpty && !_visibleTabs.contains(LiveTvTab.recordings)) {
      return Center(child: Text(t.liveTv.noChannels));
    }

    final guideChannels = _sourceFilteredChannels;

    return Column(
      children: [
        if (!useSideNav)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            alignment: .centerLeft,
            child: TabChipStrip(children: _buildTabChipItems()),
          ),
        _buildSourcePicker(),
        Expanded(
          child: TabBarView(
            controller: tabController,
            children: [for (final tab in _visibleTabs) _buildTabContent(tab, guideChannels)],
          ),
        ),
      ],
    );
  }

  /// Source picker chips, shown only when more than one live-TV server is
  /// connected. Picks which server's channels the guide shows; What's On
  /// and Recordings are unaffected. Plex entries are deduped by server id
  /// (one entry per DVR, but one source to pick).
  Widget _buildSourcePicker() {
    final multiServer = context.read<MultiServerProvider>();
    final seenIds = <String>{};
    final servers = <LiveTvServerInfo>[];
    for (final server in multiServer.liveTvServers) {
      if (seenIds.add(server.serverId)) servers.add(server);
    }
    if (servers.length < 2) return const SizedBox.shrink();
    final selected = _selectedLiveTvServerId;
    return SingleChildScrollView(
      scrollDirection: .horizontal,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          children: [
            Text(t.liveTv.source, style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(width: 8),
            ChoiceChip(
              label: Text(t.liveTv.allSources),
              selected: selected == null,
              showCheckmark: false,
              onSelected: (_) => setState(() {
                _selectedLiveTvServerId = null;
                _selectedGuideCategory = null;
              }),
            ),
            for (final server in servers) ...[
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text(multiServer.liveTvServerName(server.serverId)),
                selected: selected == server.serverId,
                showCheckmark: false,
                onSelected: (_) => setState(() {
                  _selectedLiveTvServerId = server.serverId;
                  _selectedGuideCategory = null;
                }),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
