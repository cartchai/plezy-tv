import 'dart:async';

import '../../../media/ids.dart';
import '../../../mpv/player/player.dart';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../exceptions/media_server_exceptions.dart';
import '../../../focus/dpad_navigator.dart';
import '../../../focus/dpad_select_long_press_controller.dart';
import '../../../focus/focus_theme.dart';
import '../../../focus/input_mode_tracker.dart';
import '../../../focus/key_event_utils.dart';
import '../../../i18n/app_locale_utils.dart';
import '../../../i18n/strings.g.dart';
import '../../../mixins/mounted_set_state_mixin.dart';
import '../../../models/livetv_channel.dart';
import '../../../models/livetv_program.dart';
import '../../../models/media_grab_operation.dart';
import '../../../providers/multi_server_provider.dart';
import '../../../media/iptv_live_tv.dart';
import '../../../media/media_server_client.dart';
import '../../../theme/mono_tokens.dart';
import '../../../utils/app_logger.dart';
import '../epg_channel_detail_sheet.dart';
import '../live_tv_actions_mixin.dart';
import '../live_tv_mini_player.dart';
import '../live_tv_refresh_mixin.dart';
import '../live_tv_server_iteration.dart';
import '../guide_category.dart';
import '../../video_player/live_tv_session_args.dart';
import '../../../utils/formatters.dart';
import '../../../utils/live_tv_grouping.dart';
import '../../../utils/live_tv_matching.dart';
import '../../../utils/live_tv_player_navigation.dart';
import '../../../utils/platform_detector.dart';
import '../../../utils/tone_mapped_logo_image.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/app_menu.dart';
import '../../../widgets/clickable_cursor.dart';
import '../../../widgets/optimized_media_image.dart';
import '../livetv_styles.dart';

class GuideTab extends StatefulWidget {
  final List<LiveTvChannel> channels;
  final bool Function(LiveTvChannel channel)? isFavoriteChannel;
  final void Function(LiveTvChannel)? onToggleFavorite;

  /// Hide a channel (build #17, §9): the long-press menu's "Hide channel"
  /// item calls this; the screen persists it and drops the row. IPTV
  /// channels only — Plex/Jellyfin/Emby have no hide store, so the menu
  /// omits the item for them.
  final void Function(LiveTvChannel)? onHideChannel;

  /// The channel's category for the long-press menu (v1.0.16): the id,
  /// display name, and whether it is currently hidden. Resolved at
  /// menu-open time so the submenu reads the current state. Null when
  /// the channel has no IPTV category (Plex/Jellyfin/Emby) — the menu
  /// then omits the category row.
  final Future<({String id, String name, bool hidden})?> Function(LiveTvChannel channel)? channelCategory;

  /// Flip a whole category's hidden state (v1.0.16): the submenu's
  /// Hide/Show action calls this with the resolved id + name. The screen
  /// persists it the same way the categories screen does (per-category
  /// id, same hidden state the download/cache skip uses).
  final void Function(LiveTvChannel channel, String categoryId, String categoryName)? onToggleCategory;
  final VoidCallback? onNavigateUp;
  final VoidCallback? onBack;

  /// Show the catch-up badge on channels that offer catch-up TV
  /// ([LiveTvChannel.hasCatchUp]). Wired to the IPTV settings toggle.
  final bool showCatchUpBadge;

  /// Guide category picker (build #17, §11): the visible live TV
  /// categories on the current source scope, the selected one, and the
  /// callback that applies the selection. An empty list (Plex-only
  /// lineups, or categories not loaded yet) hides the picker.
  final List<GuideCategoryEntry> guideCategories;
  final GuideCategoryEntry? selectedGuideCategory;
  final void Function(GuideCategoryEntry? entry)? onSelectGuideCategory;

  /// Test seams for the portrait mini-player (build #12): a fake player
  /// factory, a placeholder video surface, and a fullscreen stub. The
  /// real paths construct a native [Player], render the real video
  /// surface, and open the full player — no native surface is ever
  /// created in widget tests.
  final Player Function()? debugPlayerFactory;
  final Widget Function(BuildContext context, Player player)? debugVideoBuilder;
  final Future<void> Function(LiveTvChannel channel)? debugFullscreenHandler;

  const GuideTab({
    super.key,
    required this.channels,
    this.isFavoriteChannel,
    this.onToggleFavorite,
    this.onHideChannel,
    this.channelCategory,
    this.onToggleCategory,
    this.onNavigateUp,
    this.onBack,
    this.showCatchUpBadge = true,
    this.guideCategories = const [],
    this.selectedGuideCategory,
    this.onSelectGuideCategory,
    this.debugPlayerFactory,
    this.debugVideoBuilder,
    this.debugFullscreenHandler,
  });

  @override
  State<GuideTab> createState() => GuideTabState();
}

@visibleForTesting
({String channelScopeKey, ({String kind, String value})? programId, int? beginsAt, int? endsAt}) guideAiringIdentity(
  LiveTvChannel channel,
  LiveTvProgram program,
) {
  ({String kind, String value})? programId;
  if (program.ratingKey case final ratingKey? when ratingKey.isNotEmpty) {
    programId = (kind: 'ratingKey', value: ratingKey);
  } else if (program.guid case final guid? when guid.isNotEmpty) {
    programId = (kind: 'guid', value: guid);
  } else if (program.key case final key? when key.isNotEmpty) {
    programId = (kind: 'key', value: key);
  }

  // Keep the slot even with an ID so repeated airings cannot inherit each
  // other's hold; with no ID, channel scope plus timing is the fallback.
  return (
    channelScopeKey: liveTvChannelScopeKey(channel),
    programId: programId,
    beginsAt: program.beginsAt,
    endsAt: program.endsAt,
  );
}

enum _GuideZone { timeNav, grid }

/// One item in the guide channel long-press menu (build #17, §9): a stable
/// [id], a label, an icon, and the action that runs after the menu closes.
/// The menu is built from a list of these so more items slot in later
/// without touching the menu code.
class ChannelMenuItem {
  final String id;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  const ChannelMenuItem({required this.id, required this.label, required this.icon, required this.onPressed});
}

typedef _GuideFocusSnapshot = ({
  bool hasFocus,
  _GuideZone zone,
  int timeNavIndex,
  int channelIndex,
  int gridColumn,
  LiveTvProgram? program,
});

sealed class _GuideRow {
  const _GuideRow();
}

final class _GuideSourceHeaderRow extends _GuideRow {
  final String label;

  const _GuideSourceHeaderRow({required this.label});
}

final class _GuideChannelRow extends _GuideRow {
  final LiveTvChannel channel;
  final int channelIndex;

  const _GuideChannelRow({required this.channel, required this.channelIndex});
}

class GuideTabState extends State<GuideTab>
    with LiveTvActionsMixin<GuideTab>, MountedSetStateMixin, WidgetsBindingObserver, LiveTvRefreshMixin<GuideTab> {
  static const _slotWidth = 180.0;
  static const _channelColumnWidth = 132.0;
  static const _rowHeight = 64.0;
  static const _sourceHeaderRowHeight = 40.0;
  static const _timeHeaderHeight = 40.0;
  static const _minutesPerSlot = 30;

  /// Minimum time away (backgrounded or on another section) before the
  /// viewport is realigned to the live line on return.
  static const _realignAfterAway = Duration(minutes: 30);

  // Live TV mini-player (build #12): one player owned by the guide, shown
  // above the grid on portrait phones only. The controller notifies on
  // every play/pause/buffer change, but the guide itself only rebuilds
  // when the slot appears or disappears ([_onMiniPlayerChanged]) — the
  // slot's own ListenableBuilder handles its internal state, so scrolling
  // the grid never rebuilds the player.
  late final LiveTvMiniPlayerController _miniPlayer;
  bool _miniPlayerVisible = false;

  /// The mini-player exists only on phones in portrait: the Plex
  /// reference is a portrait layout (video on top, guide below). Rotating
  /// to landscape behaves as today — fullscreen video as normal — so the
  /// guide has no mini-player there, and TV/tablet/desktop are untouched.
  bool get _miniPlayerEnabled =>
      PlatformDetector.isPhone(context) && MediaQuery.orientationOf(context) == Orientation.portrait;

  void _onMiniPlayerChanged() {
    final visible = _miniPlayer.status != LiveTvMiniPlayerStatus.idle;
    if (visible == _miniPlayerVisible) return;
    _miniPlayerVisible = visible;
    setStateIfMounted(() {});
  }

  /// Guide tap-to-tune (build #12): on a portrait phone the channel plays
  /// in the mini-player above the guide; everywhere else the tap opens
  /// the full player exactly as before. Catch-up keeps its archive start
  /// on both paths — the mini-player opens the timeshift URL, the full
  /// player navigates with the same catch-up epoch as today.
  /// [catchUpProgrammeTitle] names the programme for the
  /// missing-recording card (build #17).
  Future<void> _tuneFromGuide(
    LiveTvChannel channel, {
    int? catchUpStartEpoch,
    String? catchUpProgrammeTitle,
  }) async {
    if (_miniPlayerEnabled) {
      await _miniPlayer.tune(
        channel: channel,
        multiServer: context.read<MultiServerProvider>(),
        catchUpStartEpoch: catchUpStartEpoch,
        catchUpProgrammeTitle: catchUpProgrammeTitle,
      );
      return;
    }
    if (catchUpStartEpoch != null) {
      await navigateToLiveTv(
        context,
        multiServer: context.read<MultiServerProvider>(),
        channel: channel,
        channels: liveTvChannels,
        startPosition: LiveTvStartPosition.beginning,
        catchUpStartEpoch: catchUpStartEpoch,
      );
      return;
    }
    await tuneChannel(channel);
  }

  /// Mini-player fullscreen: release the stream, then open the full
  /// player for the same channel. The mini-player stays as a stopped
  /// card, so one tap resumes it on return.
  Future<void> _openMiniPlayerFullscreen() async {
    final channel = _miniPlayer.channel;
    if (channel == null) return;
    await _miniPlayer.stopForFullscreen();
    if (!mounted) return;
    final handler = widget.debugFullscreenHandler;
    if (handler != null) {
      await handler(channel);
      return;
    }
    await navigateToLiveTv(
      context,
      multiServer: context.read<MultiServerProvider>(),
      channel: channel,
      channels: liveTvChannels,
    );
  }

  Future<void> _resumeMiniPlayer() async {
    if (!mounted) return;
    await _miniPlayer.retry(multiServer: context.read<MultiServerProvider>());
  }

  /// Missing-recording card's Watch live (build #17): the same channel,
  /// live — the panel has no recording for the programme, but the live
  /// stream works.
  Future<void> _watchLiveMiniPlayer() async {
    if (!mounted) return;
    await _miniPlayer.watchLive(multiServer: context.read<MultiServerProvider>());
  }

  /// Title of the programme currently airing on [channel], from the
  /// guide's EPG — the mini-player's "now playing" line.
  String? _nowPlayingTitleFor(LiveTvChannel? channel) {
    if (channel == null) return null;
    final index = widget.channels.indexWhere((c) => c.key == channel.key);
    if (index < 0) return null;
    return _findCurrentProgram(index)?.title;
  }

  List<LiveTvProgram> _programs = [];
  Map<String, List<LiveTvProgram>> _programsByChannelScope = const {};
  Set<String> _scheduledRecordingKeys = const {};

  /// Recording keys the user just scheduled/unscheduled from this guide.
  /// Local actions stay authoritative until the next full grid load returns
  /// fresh subscription attributes: the grab refresh below races the server
  /// materializing (or tearing down) grab operations, and the rendered
  /// programs keep their stale `subscriptionID` attributes until refetched.
  Map<String, bool> _recordingOverrides = const {};
  bool _isLoading = true;

  /// Whether a load has completed at least once for this tab. Until the
  /// first successful load the guide shows a full-screen spinner; in-session
  /// window reloads keep the existing grid mounted and only overlay a
  /// lightweight loading indicator. Never reset on channel-list changes:
  /// `didUpdateWidget` re-indexes the loaded programs and fires no fetch, and
  /// a reset would restore the unmount (and D-pad focus loss) this flag fixes.
  bool _hasLoadedOnce = false;
  int _programLoadGeneration = 0;

  // IPTV EPG, loaded lazily per visible channel (Tasks A/B/G). The
  // server-wide fetchSchedule cannot name the channels the guide is showing,
  // and one call per channel across a 55k-row catalog is not an option — so
  // each visible row triggers one cached fetch for its own channel through
  // [IptvLiveTvSupport.fetchEpgForChannel]. State is keyed by channel scope
  // key and reset whenever the guide window changes or the EPG cache is
  // busted (Update now / Clear guide bumps the support's epgVersion).
  final Set<String> _iptvEpgInFlight = {};
  final Set<String> _iptvEpgLoaded = {};
  final Set<String> _iptvEpgFailed = {};
  final Map<String, int> _iptvEpgVersionByServer = {};

  /// Merged per-channel program lists (real programs + "No information"
  /// hour placeholders). Cached so focus tracking — which compares programs
  /// by identity — sees stable objects across builds; cleared whenever the
  /// underlying programs or the window change.
  final Map<String, List<LiveTvProgram>> _mergedProgramsCache = {};

  late DateTime _gridStart;
  late DateTime _gridEnd;

  final ScrollController _headerHorizontalController = ScrollController();
  final ScrollController _gridHorizontalController = ScrollController();
  final ScrollController _channelVerticalController = ScrollController();
  final ScrollController _gridVerticalController = ScrollController();
  bool _syncingScroll = false;

  final _selectLongPressController = DpadSelectLongPressController();
  final _dayPickerKey = GlobalKey();

  // Stale-window catch-up state (#1297). The grid window is only auto
  // re-anchored when it was live-anchored and has drifted fully into the
  // past — deliberately picked day/time windows are never yanked.
  DateTime? _hiddenSince;
  bool _nowWasInWindow = true;

  // Focus state
  final FocusNode _guideFocusNode = FocusNode(debugLabel: 'guide_tab');
  _GuideZone _focusZone = _GuideZone.timeNav;
  int _timeNavIndex = 1; // 0=left arrow, 1=day picker, 2=right arrow
  int _gridChannelIndex = 0;
  int _gridColumn = 0; // 0=channel, 1=program
  bool _hasFocus = false;
  final ValueNotifier<_GuideFocusSnapshot> _focusSnapshot = ValueNotifier((
    hasFocus: false,
    zone: _GuideZone.timeNav,
    timeNavIndex: 1,
    channelIndex: 0,
    gridColumn: 0,
    program: null,
  ));
  LiveTvProgram? _focusedProgram;
  bool _pendingFocus = false;

  @override
  List<LiveTvChannel> get liveTvChannels => widget.channels;

  // Jump requested while programs were still loading (guide search from
  // another tab lands on a freshly built guide) — replayed by _loadPrograms.
  LiveTvChannel? _pendingJumpChannel;
  LiveTvProgram? _pendingJumpProgram;

  /// Focus into the guide content (called from tab bar navigation or initial load).
  void focusContent() {
    if (!InputModeTracker.isKeyboardMode(context)) return;
    // If still loading programs, defer until the Focus widget is in the tree.
    if (_isLoading) {
      _pendingFocus = true;
      return;
    }
    _pendingFocus = false;
    _guideFocusNode.requestFocus();
    _updateFocus(() {
      if (widget.channels.isNotEmpty) {
        _focusZone = _GuideZone.grid;
        _gridColumn = 0;
        _gridChannelIndex = 0;
        _focusedProgram = null;
      } else {
        _focusZone = _GuideZone.timeNav;
        _timeNavIndex = 1;
      }
    });
  }

  /// Jump the guide to [channel] (from guide search): scroll to its row and
  /// land d-pad focus on the channel cell in keyboard mode. Returns false
  /// when the channel is not in the current rows (build #15, item 2) — the
  /// caller switches source and retries instead of silently doing nothing.
  /// A jump stashed while loading returns true: it runs when the load lands.
  bool jumpToChannel(LiveTvChannel channel) {
    if (_isLoading) {
      _pendingJumpChannel = channel;
      _pendingJumpProgram = null;
      return true;
    }
    final index = _channelIndexFor(channel);
    if (index == null) return false;

    // Focus state renders through _focusSnapshot listeners; _updateFocus
    // publishes it (a bare setState would leave the cells unchanged).
    _updateFocus(() {
      _focusZone = _GuideZone.grid;
      _gridChannelIndex = index;
      _gridColumn = 0;
      _focusedProgram = null;
    });
    if (InputModeTracker.isKeyboardMode(context)) _guideFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToChannel(index);
    });
    return true;
  }

  /// Jump the guide to [program] on [channel] (from guide search), shifting
  /// the time window first when the airing isn't visible in the current one.
  /// Same contract as [jumpToChannel]: false when the channel is not in the
  /// current rows, true when stashed while loading.
  Future<bool> jumpToProgram(LiveTvChannel channel, LiveTvProgram program) async {
    if (_isLoading) {
      _pendingJumpChannel = channel;
      _pendingJumpProgram = program;
      return true;
    }
    final index = _channelIndexFor(channel);
    if (index == null) return false;

    final begin = program.startTime;
    final end = program.endTime ?? begin;
    final intersectsWindow = begin != null && end != null && begin.isBefore(_gridEnd) && end.isAfter(_gridStart);
    if (begin != null && !intersectsWindow) {
      // Same window mechanics as the day/time-slot picker: anchor a fresh
      // 6-hour window one slot before the program and reload.
      var start = DateTime(begin.year, begin.month, begin.day, begin.hour, begin.minute >= 30 ? 30 : 0);
      start = start.subtract(const Duration(minutes: 30));
      setState(() {
        _gridStart = start;
        _gridEnd = start.add(const Duration(hours: 6));
        _nowWasInWindow = _nowInWindow(DateTime.now());
      });
      await _loadPrograms();
      if (!mounted) return false;
    }

    // Re-resolve against the loaded list — the search sheet's program objects
    // come from its own fetch and never match _programs by identity.
    final target = _getProgramsForChannel(
      widget.channels[index],
    ).where((p) => p.beginsAt == program.beginsAt).firstOrNull;

    _updateFocus(() {
      _focusZone = _GuideZone.grid;
      _gridChannelIndex = index;
      _gridColumn = target != null ? 1 : 0;
      _focusedProgram = target;
    });
    if (InputModeTracker.isKeyboardMode(context)) _guideFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToChannel(index);
      if (target != null) _scrollToProgramTime(target);
    });
    return true;
  }

  int? _channelIndexFor(LiveTvChannel channel) {
    final scopeKey = liveTvChannelScopeKey(channel);
    for (var i = 0; i < widget.channels.length; i++) {
      if (liveTvChannelScopeKey(widget.channels[i]) == scopeKey) return i;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _miniPlayer = LiveTvMiniPlayerController(playerFactory: widget.debugPlayerFactory);
    _miniPlayer.addListener(_onMiniPlayerChanged);
    _initTimeRange();
    _loadPrograms();

    // PlezTV 1.2.0 (§3.3): the quiet-hour guide refresh — an in-app
    // interval check on guide open, never a background-job promise.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_maybeRefreshForQuietHour()));

    _gridHorizontalController.addListener(_syncGridToHeader);
    _headerHorizontalController.addListener(_syncHeaderToGrid);
  }

  /// The quiet-hour check (§3.3): the first IPTV support in the guide
  /// refreshes when the update time passed since the last data landed.
  /// Once per boundary, never twice, never on manual-only.
  Future<void> _maybeRefreshForQuietHour() async {
    if (!mounted) return;
    for (final channel in widget.channels) {
      final support = _iptvSupportFor(channel);
      if (support == null) continue;
      await support.maybeRefreshForQuietHour();
      return;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Rotating to landscape (or leaving the phone form factor) releases
    // the stream: landscape behaves as today — fullscreen video as
    // normal — and there is no video surface in the landscape guide, so a
    // mini-player left playing would be audio with no picture.
    if (!_miniPlayerEnabled && _miniPlayer.status != LiveTvMiniPlayerStatus.idle) {
      unawaited(_miniPlayer.stop());
    }
  }

  // Not the gated data-refresh timer the other tabs run: the tick is a
  // per-minute UI ticker that advances the time indicator and re-anchors a
  // live-anchored window that drifted fully into the past.
  @override
  Duration get refreshInterval => const Duration(minutes: 1);

  @override
  void onRefreshTick() {
    _checkWindowDrift();
    // ignore: no-empty-block - setState triggers rebuild to update time indicator
    setStateIfMounted(() {});
  }

  // Pause has to stamp _hiddenSince on a tab switch, a section hide, and an
  // app background alike so _catchUpIfStale can measure the absence.
  @override
  void onRefreshPaused() {
    _hiddenSince ??= DateTime.now();
  }

  @override
  void onRefreshResumed(LiveTvRefreshResumeReason reason) {
    unawaited(_refreshScheduledRecordingKeys());
    // Post-frame: resume fires during tab transitions/build and the catch-up
    // may setState (reload or scroll).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _catchUpIfStale();
    });
  }

  @override
  void didUpdateWidget(GuideTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.channels, widget.channels)) {
      _programsByChannelScope = _indexProgramsByChannel(_programs, widget.channels);
      _mergedProgramsCache.clear();
    }
    if (widget.channels.isNotEmpty && _gridChannelIndex >= widget.channels.length) {
      _gridChannelIndex = widget.channels.length - 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _publishFocusSnapshot();
      });
    }
  }

  @override
  void dispose() {
    _programLoadGeneration++;
    _miniPlayer.removeListener(_onMiniPlayerChanged);
    unawaited(_miniPlayer.dispose());
    _selectLongPressController.dispose();
    _guideFocusNode.dispose();
    _gridVerticalController.dispose();
    _gridHorizontalController.removeListener(_syncGridToHeader);
    _headerHorizontalController.removeListener(_syncHeaderToGrid);
    _headerHorizontalController.dispose();
    _gridHorizontalController.dispose();
    _channelVerticalController.dispose();
    _focusSnapshot.dispose();
    super.dispose();
  }

  void _handleGuideFocusChange(bool hasFocus) {
    if (_hasFocus == hasFocus) return;
    if (!hasFocus) _resetSelectLongPressState();
    _hasFocus = hasFocus;
    _publishFocusSnapshot();
  }

  void _updateFocus(VoidCallback update) {
    update();
    _publishFocusSnapshot();
  }

  void _publishFocusSnapshot() {
    _focusSnapshot.value = (
      hasFocus: _hasFocus,
      zone: _focusZone,
      timeNavIndex: _timeNavIndex,
      channelIndex: _gridChannelIndex,
      gridColumn: _gridColumn,
      program: _focusedProgram,
    );
  }

  void _resetSelectLongPressState() => _selectLongPressController.reset();

  void _syncGridToHeader() {
    if (_syncingScroll) return;
    _syncingScroll = true;
    if (_headerHorizontalController.hasClients) {
      _headerHorizontalController.jumpTo(_gridHorizontalController.offset);
    }
    _syncingScroll = false;
  }

  void _syncHeaderToGrid() {
    if (_syncingScroll) return;
    _syncingScroll = true;
    if (_gridHorizontalController.hasClients) {
      _gridHorizontalController.jumpTo(_headerHorizontalController.offset);
    }
    _syncingScroll = false;
  }

  void _initTimeRange() {
    final now = DateTime.now();
    _gridStart = DateTime(now.year, now.month, now.day, now.hour);
    if (now.minute >= 30) {
      _gridStart = _gridStart.add(const Duration(minutes: 30));
    }
    _gridStart = _gridStart.subtract(const Duration(hours: 1));
    _gridEnd = _gridStart.add(const Duration(hours: 6));
    _nowWasInWindow = true;
  }

  void _shiftTimeRange(int hours) {
    setState(() {
      _gridStart = _gridStart.add(Duration(hours: hours));
      _gridEnd = _gridStart.add(const Duration(hours: 6));
      _nowWasInWindow = _nowInWindow(DateTime.now());
    });
    _loadPrograms();
  }

  void _jumpToNow() {
    _initTimeRange();
    _loadPrograms();
  }

  bool _nowInWindow(DateTime now) => !now.isBefore(_gridStart) && now.isBefore(_gridEnd);

  /// Timer path: re-anchor only when a live-anchored window drifted fully past.
  void _checkWindowDrift() {
    if (!isRefreshSubtreeVisible || _isLoading) return;
    if (_nowWasInWindow && !_nowInWindow(DateTime.now())) _jumpToNow();
  }

  /// Active path (app resume / guide became visible): drift-jump, else
  /// realign the viewport to the live line after a meaningful absence (#1297).
  void _catchUpIfStale() {
    if (!isRefreshSubtreeVisible) return; // still hidden — keep _hiddenSince
    final hiddenSince = _hiddenSince;
    _hiddenSince = null; // evaluated while visible — consume it
    if (_isLoading) return; // in-flight load already ends in _scrollToNow()
    final now = DateTime.now();
    if (_nowWasInWindow && !_nowInWindow(now)) {
      _jumpToNow();
    } else if (_nowInWindow(now) && hiddenSince != null && now.difference(hiddenSince) >= _realignAfterAway) {
      _scrollToNow();
    }
  }

  bool _isCurrentProgramLoad(int generation) => mounted && generation == _programLoadGeneration;

  Future<void> _loadPrograms() async {
    if (!mounted) return;
    // A window change (or refresh) invalidates the per-channel IPTV EPG
    // state; visible rows re-fetch from the support's cache (no network
    // while the settings window still covers the new grid window).
    _resetIptvEpgState();
    final loadGeneration = ++_programLoadGeneration;
    final requestGridStart = _gridStart;
    final requestGridEnd = _gridEnd;
    final startEpoch = requestGridStart.millisecondsSinceEpoch ~/ 1000;
    final endEpoch = requestGridEnd.millisecondsSinceEpoch ~/ 1000;
    final from = DateTime.fromMillisecondsSinceEpoch(startEpoch * 1000, isUtc: true);
    final to = DateTime.fromMillisecondsSinceEpoch(endEpoch * 1000, isUtc: true);
    setState(() => _isLoading = true);

    try {
      final allPrograms = <LiveTvProgram>[];
      final scheduledRecordingKeys = <String>{};
      final multiServer = context.read<MultiServerProvider>();

      await forEachLiveTvServer(
        multiServer,
        resolveClient: multiServer.getClientForServer,
        isCurrent: () => _isCurrentProgramLoad(loadGeneration),
        body: (client, serverInfo) async {
          final programs = await client.liveTv.fetchSchedule(from: from, to: to);
          if (!_isCurrentProgramLoad(loadGeneration)) return;
          allPrograms.addAll(programs);
          await _addScheduledRecordingKeysForServer(
            client: client,
            serverId: ServerId(serverInfo.serverId),
            keys: scheduledRecordingKeys,
            isCurrent: () => _isCurrentProgramLoad(loadGeneration),
          );
        },
        onError: (client, serverInfo, error, stackTrace) {
          if (!_isCurrentProgramLoad(loadGeneration)) return;
          appLogger.e('Failed to load programs from server ${serverInfo.serverId}', error: error);
        },
      );

      if (!_isCurrentProgramLoad(loadGeneration)) return;
      final shouldFocus = _pendingFocus;
      final programsByChannelScope = _indexProgramsByChannel(allPrograms, widget.channels);
      final pendingJumpChannel = _pendingJumpChannel;
      final pendingJumpProgram = _pendingJumpProgram;
      _pendingJumpChannel = null;
      _pendingJumpProgram = null;

      setState(() {
        _programs = allPrograms;
        _programsByChannelScope = programsByChannelScope;
        _scheduledRecordingKeys = scheduledRecordingKeys;
        _recordingOverrides = const {};
        _isLoading = false;
        _hasLoadedOnce = true;
        // The server-wide index replaced per-channel lists; merged
        // placeholder lists built from the old index are stale.
        _mergedProgramsCache.clear();
        // Focus tracking compares by identity, so a reload orphans the
        // focused program — re-resolve it against the fresh list.
        if (_focusZone == _GuideZone.grid && _gridColumn == 1 && _focusedProgram != null) {
          final focused = _focusedProgram;
          if (!_programs.any((p) => identical(p, focused))) {
            _focusedProgram = _findCurrentProgram(_gridChannelIndex);
          }
        }
      });
      _publishFocusSnapshot();

      if (pendingJumpChannel != null) {
        // A stashed search jump wins over the default live-line anchoring and
        // over any focus request queued during the load.
        _pendingFocus = false;
        if (pendingJumpProgram != null) {
          unawaited(jumpToProgram(pendingJumpChannel, pendingJumpProgram));
        } else {
          jumpToChannel(pendingJumpChannel);
        }
        return;
      }

      _scrollToNow(loadGeneration: loadGeneration);

      if (shouldFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_isCurrentProgramLoad(loadGeneration)) focusContent();
        });
      }
    } catch (e) {
      if (!_isCurrentProgramLoad(loadGeneration)) return;
      appLogger.e('Failed to load guide programs', error: e);
      setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshScheduledRecordingKeys() async {
    if (!mounted) return;
    final multiServer = context.read<MultiServerProvider>();
    final scheduledRecordingKeys = <String>{};

    await forEachLiveTvServer(
      multiServer,
      resolveClient: multiServer.getClientForServer,
      body: (client, serverInfo) => _addScheduledRecordingKeysForServer(
        client: client,
        serverId: ServerId(serverInfo.serverId),
        keys: scheduledRecordingKeys,
      ),
    );

    if (!mounted) return;
    setState(() => _scheduledRecordingKeys = scheduledRecordingKeys);
  }

  Future<void> _addScheduledRecordingKeysForServer({
    required MediaServerClient client,
    required ServerId serverId,
    required Set<String> keys,
    bool Function()? isCurrent,
  }) async {
    final dvr = client.liveTvDvr;
    if (dvr == null) return;
    try {
      final grabs = await dvr.fetchScheduledRecordings();
      if (isCurrent?.call() == false) return;
      for (final grab in grabs) {
        _addRecordingKeysForGrab(grab, serverId: ServerId(serverId), keys: keys);
      }
    } catch (e) {
      if (isCurrent?.call() == false) return;
      appLogger.d('Failed to load scheduled recordings for $serverId', error: e);
    }

    try {
      final rules = await dvr.fetchRecordingRules(includeGrabs: true, includeStorage: false);
      if (isCurrent?.call() == false) return;
      for (final rule in rules) {
        for (final grab in rule.grabOperations) {
          _addRecordingKeysForGrab(grab, serverId: ServerId(serverId), keys: keys);
        }
      }
    } catch (e) {
      if (isCurrent?.call() == false) return;
      appLogger.d('Failed to load active recording grabs for $serverId', error: e);
    }
  }

  void _addRecordingKeysForGrab(MediaGrabOperation grab, {required ServerId serverId, required Set<String> keys}) {
    if (!_isActiveScheduledGrab(grab)) return;
    final program = grab.program;
    if (program == null) return;
    keys.addAll(_recordingKeysForProgram(program, fallbackServerId: serverId));
  }

  bool _isActiveScheduledGrab(MediaGrabOperation grab) {
    final status = grab.status?.trim().toLowerCase();
    return status == null || status.isEmpty || status == 'scheduled' || status == 'grabbing' || status == 'recording';
  }

  bool _isRecordingScheduled(LiveTvProgram program) {
    final keys = _recordingKeysForProgram(program);
    for (final key in keys) {
      final override = _recordingOverrides[key];
      if (override != null) return override;
    }
    // The grid response tags subscribed airings itself (subscriptionID /
    // grandparentSubscriptionID) — the signal the official client renders
    // its record badges from. Grab matching below stays as the secondary
    // signal for airings the server did not tag.
    if (program.recordingRuleKey != null) return true;
    return keys.any(_scheduledRecordingKeys.contains);
  }

  void _handleRecordingStateChanged(LiveTvProgram program, bool isScheduled) {
    final keys = _recordingKeysForProgram(program);
    if (keys.isNotEmpty) {
      setState(() {
        _recordingOverrides = {..._recordingOverrides, for (final key in keys) key: isScheduled};
      });
    }
    unawaited(_refreshScheduledRecordingKeys());
  }

  Set<String> _recordingKeysForProgram(LiveTvProgram program, {String? fallbackServerId}) {
    final serverId = liveTvNonEmpty(program.serverId) ?? liveTvNonEmpty(fallbackServerId);
    if (serverId == null) return const <String>{};

    final keys = <String>{};
    void addMediaId(String? value) {
      final normalized = liveTvNonEmpty(value);
      if (normalized != null) keys.add(_recordingKey(ServerId(serverId), 'media', normalized));
    }

    addMediaId(program.ratingKey);
    addMediaId(program.guid);
    addMediaId(program.key);

    final channelIdentifier = liveTvNonEmpty(program.channelIdentifier);
    final beginsAt = program.beginsAt;
    if (channelIdentifier != null && beginsAt != null) {
      keys.add(_recordingKey(ServerId(serverId), 'slot', '$channelIdentifier|$beginsAt|${program.endsAt ?? ''}'));
    }

    return keys;
  }

  String _recordingKey(ServerId serverId, String type, String value) => '$serverId\u0000$type\u0000$value';

  List<_GuideRow> get _guideRows {
    final groups = groupLiveTvChannelsBySource(widget.channels);
    if (groups.length <= 1) {
      return [
        for (var i = 0; i < widget.channels.length; i++) _GuideChannelRow(channel: widget.channels[i], channelIndex: i),
      ];
    }

    final channelIndexes = <LiveTvChannel, int>{};
    for (var i = 0; i < widget.channels.length; i++) {
      channelIndexes[widget.channels[i]] = i;
    }

    return [
      for (final group in groups) ...[
        _GuideSourceHeaderRow(label: group.label),
        for (final channel in group.channels)
          _GuideChannelRow(channel: channel, channelIndex: channelIndexes[channel] ?? 0),
      ],
    ];
  }

  /// Flat [GuideTab.channels] indexes in displayed row order. Differs from
  /// ascending index order when multiple source groups exist: the flat list is
  /// number-sorted across sources, while rows are grouped by source.
  List<int> get _displayOrderChannelIndexes => [
    for (final row in _guideRows)
      if (row is _GuideChannelRow) row.channelIndex,
  ];

  double _guideRowHeight(_GuideRow row) {
    return switch (row) {
      _GuideSourceHeaderRow() => _sourceHeaderRowHeight,
      _GuideChannelRow() => _rowHeight,
    };
  }

  double _guideContentHeight(List<_GuideRow> rows) {
    var height = 0.0;
    for (final row in rows) {
      height += _guideRowHeight(row);
    }
    return height;
  }

  double _rowTopForChannelIndex(int channelIndex) {
    var top = 0.0;
    for (final row in _guideRows) {
      if (row is _GuideChannelRow && row.channelIndex == channelIndex) return top;
      top += _guideRowHeight(row);
    }
    return channelIndex * _rowHeight;
  }

  void _scrollToNow({int? loadGeneration}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || (loadGeneration != null && !_isCurrentProgramLoad(loadGeneration))) return;
      final now = DateTime.now();
      final minutesSinceStart = now.difference(_gridStart).inMinutes;
      final offset = (minutesSinceStart / _minutesPerSlot) * _slotWidth;
      if (_gridHorizontalController.hasClients) {
        _gridHorizontalController.jumpTo(
          (offset - MediaQuery.sizeOf(context).width / 3).clamp(0, _gridHorizontalController.position.maxScrollExtent),
        );
      }
    });
  }

  Map<String, List<LiveTvProgram>> _indexProgramsByChannel(List<LiveTvProgram> programs, List<LiveTvChannel> channels) {
    final programsByIdentifier = <String, List<LiveTvProgram>>{};
    for (final program in programs) {
      final identifier = program.channelIdentifier?.trim();
      if (identifier == null || identifier.isEmpty) continue;
      (programsByIdentifier[identifier] ??= []).add(program);
    }

    final indexed = <String, List<LiveTvProgram>>{};
    for (final channel in channels) {
      final candidates = <LiveTvProgram>{};
      candidates.addAll(programsByIdentifier[channel.key] ?? const []);
      final identifier = channel.identifier;
      if (identifier != null && identifier != channel.key) {
        candidates.addAll(programsByIdentifier[identifier] ?? const []);
      }
      final matching = candidates.where((program) => liveTvProgramMatchesChannel(program, channel)).toList()
        ..sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
      indexed[liveTvChannelScopeKey(channel)] = matching;
    }
    return indexed;
  }

  List<LiveTvProgram> _getProgramsForChannel(LiveTvChannel channel) {
    final scopeKey = liveTvChannelScopeKey(channel);
    final cached = _mergedProgramsCache[scopeKey];
    if (cached != null) return cached;
    final real = _programsByChannelScope[scopeKey] ?? const <LiveTvProgram>[];
    // Hour placeholders are an IPTV concept (missing guide data). A
    // Plex/Jellyfin/Emby row with no programs is genuinely empty — it keeps
    // the old behaviour (D-pad down focuses the channel cell, the row shows
    // "No program data available") and must never gain placeholders.
    final merged = _iptvSupportFor(channel) != null && _isChannelEpgReady(channel)
        ? _withHourPlaceholders(channel, real)
        : real;
    _mergedProgramsCache[scopeKey] = merged;
    return merged;
  }

  /// Whether this channel's EPG load has finished (with data or without),
  /// so the row may render hour placeholders instead of a loading state.
  /// Non-IPTV channels are ready once the server-wide load completed;
  /// IPTV channels are ready only once their own per-channel fetch finished
  /// (loaded or failed) — never while it is still in flight.
  bool _isChannelEpgReady(LiveTvChannel channel) {
    if (!_hasLoadedOnce) return false;
    if (_iptvSupportFor(channel) == null) return true;
    final scopeKey = liveTvChannelScopeKey(channel);
    return _iptvEpgLoaded.contains(scopeKey) || _iptvEpgFailed.contains(scopeKey);
  }

  /// The IPTV live-TV support for [channel]'s server, or null when the
  /// channel is not served by an IPTV connection.
  IptvLiveTvSupport? _iptvSupportFor(LiveTvChannel channel) {
    final serverId = channel.serverId;
    if (serverId == null) return null;
    final client = context.read<MultiServerProvider>().getClientForServer(ServerId(serverId));
    final liveTv = client?.liveTv;
    return liveTv is IptvLiveTvSupport ? liveTv : null;
  }

  /// Fill the guide window's uncovered hours with clickable "No information
  /// available" hour blocks (Task G). Real programs are kept as-is; every
  /// hour-aligned stretch the real programs do not cover becomes one block
  /// per clock hour (partial hours at the window edges are clipped to the
  /// window). A channel with no EPG at all gets one block per hour of the
  /// whole window instead of dead empty space.
  List<LiveTvProgram> _withHourPlaceholders(LiveTvChannel channel, List<LiveTvProgram> real) {
    final gridStartEpoch = _gridStart.millisecondsSinceEpoch ~/ 1000;
    final gridEndEpoch = _gridEnd.millisecondsSinceEpoch ~/ 1000;
    if (gridEndEpoch <= gridStartEpoch) return real;

    // Covered intervals, clipped to the window and merged.
    final covered = <(int, int)>[];
    for (final program in real) {
      final begin = (program.beginsAt ?? gridStartEpoch).clamp(gridStartEpoch, gridEndEpoch);
      final end = (program.endsAt ?? gridEndEpoch).clamp(gridStartEpoch, gridEndEpoch);
      if (end > begin) covered.add((begin, end));
    }
    covered.sort((a, b) => a.$1.compareTo(b.$1));
    final mergedCovered = <(int, int)>[];
    for (final interval in covered) {
      if (mergedCovered.isNotEmpty && interval.$1 <= mergedCovered.last.$2) {
        final last = mergedCovered.removeLast();
        mergedCovered.add((last.$1, interval.$2 > last.$2 ? interval.$2 : last.$2));
      } else {
        mergedCovered.add(interval);
      }
    }

    final placeholders = <LiveTvProgram>[];
    // Walk clock hours in local time; the first/last partial hours are
    // clipped to the window edge by the loop bounds.
    var hourStart = DateTime(_gridStart.year, _gridStart.month, _gridStart.day, _gridStart.hour);
    var cursor = gridStartEpoch;
    while (cursor < gridEndEpoch) {
      final nextHour = hourStart.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      final blockEnd = nextHour < gridEndEpoch ? nextHour : gridEndEpoch;
      _addPlaceholdersForGap(channel, cursor, blockEnd, mergedCovered, placeholders);
      cursor = blockEnd;
      hourStart = hourStart.add(const Duration(hours: 1));
    }

    if (placeholders.isEmpty) return real;
    return [...real, ...placeholders]..sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
  }

  /// Add placeholder blocks for the uncovered parts of [start, end).
  void _addPlaceholdersForGap(
    LiveTvChannel channel,
    int start,
    int end,
    List<(int, int)> covered,
    List<LiveTvProgram> out,
  ) {
    var cursor = start;
    for (final (coverStart, coverEnd) in covered) {
      if (coverEnd <= cursor) continue;
      if (coverStart >= end) break;
      if (coverStart > cursor) out.add(_hourPlaceholder(channel, cursor, coverStart));
      if (coverEnd > cursor) cursor = coverEnd;
      if (cursor >= end) return;
    }
    if (cursor < end) out.add(_hourPlaceholder(channel, cursor, end));
  }

  /// One "No information available" block. It is a real program entry (same
  /// tap target, same detail sheet) with no invented title, description or
  /// times beyond its own hour slot — and it is marked [LiveTvProgram.isPlaceholder]
  /// so the grid renders it muted and the sheet offers only the actions
  /// that make sense for the slot.
  LiveTvProgram _hourPlaceholder(LiveTvChannel channel, int beginsAt, int endsAt) {
    return LiveTvProgram(
      key: 'no-info:${channel.key}:$beginsAt',
      title: t.liveTv.noInformationAvailable,
      beginsAt: beginsAt,
      endsAt: endsAt,
      channelIdentifier: channel.key,
      serverId: channel.serverId,
      serverName: channel.serverName,
      isPlaceholder: true,
    );
  }

  /// Start the lazy per-channel EPG fetch for [channel] when it is an IPTV
  /// channel whose guide has not been loaded (or failed) for this window.
  /// Called from the row builder, so only rows the grid actually builds —
  /// the visible ones plus cache extent — ever fetch. A fetch in flight is
  /// never duplicated, and a completed fetch merges its programs into the
  /// indexed grid state so rows, focus and search all see them.
  void _ensureIptvEpg(LiveTvChannel channel, {bool force = false}) {
    final support = _iptvSupportFor(channel);
    if (support == null) return;
    final scopeKey = liveTvChannelScopeKey(channel);
    final serverId = channel.serverId;
    // Update now / Clear guide bumps the support version: drop this
    // server's per-channel state so visible rows re-fetch. In-flight
    // fetches are left alone — their completions clean themselves up.
    if (serverId != null && _iptvEpgVersionByServer[serverId] != support.epgVersion) {
      _iptvEpgVersionByServer[serverId] = support.epgVersion;
      _iptvEpgLoaded.clear();
      _iptvEpgFailed.clear();
      _mergedProgramsCache.clear();
    }
    if (_iptvEpgLoaded.contains(scopeKey) || _iptvEpgInFlight.contains(scopeKey)) return;
    // A failed channel stays failed for this window (its row shows a
    // retry state — tap to retry); a window change or cache bust clears
    // the failure via [_resetIptvEpgState].
    if (_iptvEpgFailed.contains(scopeKey)) return;

    _iptvEpgInFlight.add(scopeKey);
    // The row build that triggered this runs before the next frame; a
    // post-frame setState surfaces the loading indicator while the fetch
    // is in flight (a setState here would throw: build in progress).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });

    final requestStart = _gridStart;
    final requestEnd = _gridEnd;
    unawaited(
      support
          .fetchEpgForChannel(channel.key, from: requestStart, to: requestEnd, force: force)
          .then((programs) {
            if (!mounted) return;
            // A window change superseded this fetch; its programs belong to
            // the old window and must not land in the new grid — but the
            // in-flight entry must still be cleared, or the channel would
            // never fetch again.
            final superseded = _gridStart != requestStart || _gridEnd != requestEnd;
            setState(() {
              _iptvEpgInFlight.remove(scopeKey);
              if (superseded) return;
              _iptvEpgLoaded.add(scopeKey);
              _programsByChannelScope = {
                ..._programsByChannelScope,
                scopeKey: programs,
              };
              // Drop this channel's previous EPG programs from the flat
              // list (same keys, stale window) before merging the fresh ones.
              _programs = [
                ..._programs.where(
                  (p) => !(p.channelIdentifier == channel.key && (p.key?.startsWith('epg:') ?? false)),
                ),
                ...programs,
              ];
              _mergedProgramsCache.remove(scopeKey);
            });
          })
          .catchError((Object e) {
            if (!mounted) return;
            setState(() {
              _iptvEpgInFlight.remove(scopeKey);
              // Build #28: a cancellation (row scrolled away / app
              // backgrounded) is not a failure — the channel is NOT
              // marked failed, so scrolling back refetches it instead
              // of showing the retry state for a fetch nobody watched.
              if (MediaServerHttpException.from(e).isCancellation) return;
              // Fail open: the row renders hour placeholders for this
              // window instead of retrying in a loop.
              _iptvEpgFailed.add(scopeKey);
              _mergedProgramsCache.remove(scopeKey);
            });
          }),
    );
  }

  /// True while any visible IPTV channel's EPG is still loading — drives
  /// the subtle header loading indicator (Task B).
  bool get _isIptvEpgLoading => _iptvEpgInFlight.isNotEmpty;

  /// Reset per-channel IPTV EPG state (window change or full reload).
  /// In-flight fetches are NOT cleared: their completions remove
  /// themselves, and the setState they trigger restarts the fetch for the
  /// new window.
  void _resetIptvEpgState() {
    _iptvEpgLoaded.clear();
    _iptvEpgFailed.clear();
    _mergedProgramsCache.clear();
  }

  /// Retry a failed channel's EPG fetch (build #8 Task 3): clears the
  /// failed flag (and the merged placeholders) so the row re-fetches
  /// instead of staying dead for the window. A failed fetch writes no
  /// cache entry, so the retry refetches rather than serving stale data.
  /// 1.1.2 D8: the retry forces a fresh feed download, bypassing the
  /// feed's 5-minute negative cache — the tap actually tries again
  /// instead of failing instantly with "failed recently".
  void _retryIptvEpg(LiveTvChannel channel) {
    final scopeKey = liveTvChannelScopeKey(channel);
    _iptvEpgFailed.remove(scopeKey);
    _iptvEpgLoaded.remove(scopeKey);
    _mergedProgramsCache.remove(scopeKey);
    _ensureIptvEpg(channel, force: true);
    if (mounted) setState(() {});
  }

  /// The visible failed state for a channel whose EPG fetch failed (build
  /// #8 Task 3): an error icon + "Guide couldn't load — tap to retry".
  /// Tapping retries the fetch. Distinct from the loaded-but-empty state
  /// (hour placeholders) and the loading state (spinner).
  Widget _buildEpgFailedRow(LiveTvChannel channel, ThemeData theme) {
    final tk = tokens(context);
    return SizedBox(
      height: _rowHeight,
      child: Padding(
        padding: EdgeInsets.only(right: tk.groupGap, bottom: tk.groupGap),
        child: Material(
          color: Color.alphaBlend(tk.surface.withValues(alpha: 0.5), tk.bg),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(tk.radiusXs)),
          child: InkWell(
            onTap: () => _retryIptvEpg(channel),
            borderRadius: BorderRadius.circular(tk.radiusXs),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(Symbols.error_rounded, size: 16, color: tk.textMuted),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      t.liveTv.guideLoadFailed,
                      style: theme.textTheme.bodySmall?.copyWith(color: tk.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _totalGridWidth() {
    final totalMinutes = _gridEnd.difference(_gridStart).inMinutes;
    return (totalMinutes / _minutesPerSlot) * _slotWidth;
  }

  void _activateProgram(LiveTvChannel channel, LiveTvProgram program) {
    if (PlatformDetector.isTV() && program.isCurrentlyAiring) {
      tuneChannel(channel);
      return;
    }

    _showProgramDetails(channel, program);
  }

  ({LiveTvChannel channel, LiveTvProgram program})? _focusedProgramTarget() {
    if (_focusZone != _GuideZone.grid || _gridColumn != 1) return null;
    final program = _focusedProgram;
    if (program == null) return null;
    if (_gridChannelIndex < 0 || _gridChannelIndex >= widget.channels.length) return null;

    return (channel: widget.channels[_gridChannelIndex], program: program);
  }

  KeyEventResult _handleFocusedProgramSelectKey(KeyEvent event) {
    final target = _focusedProgramTarget();
    if (target == null) return KeyEventResult.ignored;

    final ownerChannelIndex = _gridChannelIndex;
    final targetIdentity = guideAiringIdentity(target.channel, target.program);
    return _selectLongPressController.handleKeyEvent(
      event,
      isOwnerActive: () {
        if (!mounted || _focusZone != _GuideZone.grid || _gridColumn != 1 || _gridChannelIndex != ownerChannelIndex) {
          return false;
        }

        final activeTarget = _focusedProgramTarget();
        return activeTarget != null &&
            guideAiringIdentity(activeTarget.channel, activeTarget.program) == targetIdentity;
      },
      onShortPress: () => _activateProgram(target.channel, target.program),
      onLongPress: () {
        _selectLongPressController.reset();
        _showProgramDetails(target.channel, target.program);
      },
    );
  }

  LiveTvChannel? _focusedChannelTarget() {
    if (_focusZone != _GuideZone.grid || _gridColumn != 0) return null;
    if (_gridChannelIndex < 0 || _gridChannelIndex >= widget.channels.length) return null;
    return widget.channels[_gridChannelIndex];
  }

  /// One item in the guide channel long-press menu (build #17, §9). The
  /// menu is built from a list of these, so more items (e.g. "Channel
  /// info", "Record this channel") slot in without touching the menu code.
  /// [id] is stable for tests; [onPressed] runs after the menu closes.
  /// Async (v1.0.16): the category row resolves the channel's category
  /// at menu-open time, so the submenu reads the current hidden state.
  Future<List<ChannelMenuItem>> _channelMenuItems(LiveTvChannel channel, {required Rect anchor, required Size size}) async {
    final items = <ChannelMenuItem>[];
    // Hide is IPTV-only: the hide store lives on IptvLiveTvSupport, per
    // IPTV connection. Plex/Jellyfin/Emby channels get the favorite item
    // only.
    if (widget.onHideChannel != null && _iptvSupportFor(channel) != null) {
      items.add(
        ChannelMenuItem(
          id: 'hide',
          label: t.liveTv.hideChannel,
          icon: Symbols.visibility_off_rounded,
          onPressed: () => widget.onHideChannel!(channel),
        ),
      );
    }
    // EPG details (PlezTV 1.2.0, §3.2): the channel's assigned source,
    // matched id, match method and why-no-match. IPTV-only — the
    // details live on IptvLiveTvSupport.
    if (_iptvSupportFor(channel) != null) {
      items.add(
        ChannelMenuItem(
          id: 'epg-details',
          label: t.iptv.epgDetailsTitle,
          icon: Symbols.info_rounded,
          onPressed: () => unawaited(_showEpgDetails(channel)),
        ),
      );
    }
    // Whole-category row (v1.0.16): the channel's category with a
    // chevron; tapping it opens the submenu to show or hide the WHOLE
    // category. Live TV only — a channel with no IPTV category resolves
    // to null and the row is omitted.
    if (widget.channelCategory != null && widget.onToggleCategory != null) {
      final category = await widget.channelCategory!(channel);
      if (category != null) {
        items.add(
          ChannelMenuItem(
            id: 'category',
            label: t.liveTv.channelCategory(name: category.name),
            icon: Symbols.category_rounded,
            onPressed: () => unawaited(_showCategorySubmenu(channel, category, anchor, size)),
          ),
        );
      }
    }
    if (widget.onToggleFavorite != null) {
      final isFavorite = widget.isFavoriteChannel?.call(channel) ?? false;
      items.add(
        ChannelMenuItem(
          id: isFavorite ? 'remove-favorite' : 'add-favorite',
          label: isFavorite ? t.mediaMenu.removeFromFavorites : t.mediaMenu.addToFavorites,
          icon: isFavorite ? Symbols.star_rounded : Symbols.star_outline_rounded,
          onPressed: () => widget.onToggleFavorite!(channel),
        ),
      );
    }
    return items;
  }

  /// One row of the guide channel long-press menu (build #17, §9): icon
  /// + label, with a trailing chevron on the category row (v1.0.16) to
  /// show it opens a submenu.
  Widget _channelMenuItemRow(ChannelMenuItem item, {bool chevron = false}) {
    return Row(
      mainAxisSize: .min,
      children: [
        Icon(item.icon, size: 20),
        const SizedBox(width: 12),
        Flexible(child: Text(item.label)),
        if (chevron) ...[
          const SizedBox(width: 12),
          const Icon(Symbols.chevron_right_rounded, size: 20),
        ],
      ],
    );
  }

  /// The category submenu (v1.0.16): a second dropdown at the same
  /// anchor with the whole-category Show/Hide action, reflecting the
  /// current state (Hide when shown, Show when hidden). Flutter's popup
  /// menu has no nested submenus, so the submenu is a second `showMenu`
  /// at the same position, opened after the first menu closes.
  Future<void> _showCategorySubmenu(
    LiveTvChannel channel,
    ({String id, String name, bool hidden}) category,
    Rect anchor,
    Size size,
  ) async {
    final item = ChannelMenuItem(
      id: 'toggle-category',
      label: category.hidden ? t.liveTv.showCategory : t.liveTv.hideCategory,
      icon: category.hidden ? Symbols.visibility_rounded : Symbols.visibility_off_rounded,
      onPressed: () => widget.onToggleCategory!(channel, category.id, category.name),
    );
    final selected = await showMenu<ChannelMenuItem>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & size),
      items: [
        PopupMenuItem<ChannelMenuItem>(
          value: item,
          child: _channelMenuItemRow(item),
        ),
      ],
    );
    selected?.onPressed();
  }

  /// The EPG details sheet (PlezTV 1.2.0, §3.2) for one channel.
  Future<void> _showEpgDetails(LiveTvChannel channel) async {
    final support = _iptvSupportFor(channel);
    if (support == null || !mounted) return;
    await showEpgChannelDetailSheet(context, support: support, channel: channel);
  }

  /// The guide channel long-press menu (build #17, §9): a dropdown
  /// anchored to the channel cell (or the screen centre for keyboard
  /// triggers, which have no cell rect). Long-press opens the menu — it
  /// never toggles anything directly.
  Future<void> _showChannelMenu(LiveTvChannel channel, {BuildContext? anchorContext}) async {
    final size = MediaQuery.sizeOf(context);
    var anchor = Offset.zero & size;
    final box = anchorContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      anchor = box.localToGlobal(Offset.zero) & box.size;
    }
    final items = await _channelMenuItems(channel, anchor: anchor, size: size);
    if (!mounted) return;
    if (items.isEmpty) return;
    final selected = await showMenu<ChannelMenuItem>(
      context: context,
      position: RelativeRect.fromRect(anchor, Offset.zero & size),
      items: [
        for (final item in items)
          PopupMenuItem<ChannelMenuItem>(
            value: item,
            child: _channelMenuItemRow(item, chevron: item.id == 'category'),
          ),
      ],
    );
    selected?.onPressed();
  }

  /// TV SELECT on a channel cell: a short press tunes and a hold opens the
  /// channel menu, the same split as a tap and a long press on the cell.
  KeyEventResult _handleFocusedChannelSelectKey(KeyEvent event) {
    final channel = _focusedChannelTarget();
    if (channel == null) return KeyEventResult.ignored;
    if (widget.onToggleFavorite == null && widget.onHideChannel == null) return KeyEventResult.ignored;

    final ownerChannelIndex = _gridChannelIndex;
    return _selectLongPressController.handleKeyEvent(
      event,
      isOwnerActive: () => mounted && _focusedChannelTarget() != null && _gridChannelIndex == ownerChannelIndex,
      onShortPress: () => tuneChannel(channel),
      onLongPress: () {
        _selectLongPressController.reset();
        unawaited(_showChannelMenu(channel));
      },
    );
  }

  /// The context-menu key (gamepad X, keyboard Menu) opens the focused
  /// channel's menu. Down only, so a held key cannot re-open it
  /// repeatedly.
  KeyEventResult _handleFocusedChannelContextMenuKey(KeyEvent event) {
    if (!event.logicalKey.isContextMenuKey) return KeyEventResult.ignored;
    final channel = _focusedChannelTarget();
    if (channel == null) return KeyEventResult.ignored;
    if (widget.onToggleFavorite == null && widget.onHideChannel == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) unawaited(_showChannelMenu(channel));
    return KeyEventResult.handled;
  }

  KeyEventResult _handleFocusedProgramContextMenuKey(KeyEvent event) {
    if (!event.logicalKey.isContextMenuKey || !event.isActionable) return KeyEventResult.ignored;
    final target = _focusedProgramTarget();
    if (target == null) return KeyEventResult.ignored;

    _resetSelectLongPressState();
    _showProgramDetails(target.channel, target.program);
    return KeyEventResult.handled;
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    final key = event.logicalKey;

    if (SelectKeyUpSuppressor.consumeIfSuppressed(event)) {
      if (event is KeyUpEvent && key.isSelectKey) {
        _resetSelectLongPressState();
      }
      return KeyEventResult.handled;
    }

    // Back key
    if (key.isBackKey) {
      if (BackKeyUpSuppressor.consumeIfSuppressed(event)) {
        return KeyEventResult.handled;
      }
      if (_focusZone == _GuideZone.grid) {
        if (event is KeyUpEvent) {
          _updateFocus(() {
            _focusZone = _GuideZone.timeNav;
            _timeNavIndex = 1;
          });
        }
        return KeyEventResult.handled;
      }
      return handleBackKeyAction(event, () => widget.onBack?.call());
    }

    if (PlatformDetector.isTV()) {
      final selectResult = _handleFocusedProgramSelectKey(event);
      if (selectResult != KeyEventResult.ignored) return selectResult;
      final channelSelectResult = _handleFocusedChannelSelectKey(event);
      if (channelSelectResult != KeyEventResult.ignored) return channelSelectResult;
    }

    final contextMenuResult = _handleFocusedProgramContextMenuKey(event);
    if (contextMenuResult != KeyEventResult.ignored) return contextMenuResult;
    final channelContextMenuResult = _handleFocusedChannelContextMenuKey(event);
    if (channelContextMenuResult != KeyEventResult.ignored) return channelContextMenuResult;

    if (!event.isActionable) return KeyEventResult.ignored;

    return _focusZone == _GuideZone.timeNav ? _handleTimeNavKey(key) : _handleGridKey(key);
  }

  KeyEventResult _handleTimeNavKey(LogicalKeyboardKey key) {
    if (key.isLeftKey) {
      if (_timeNavIndex > 0) {
        _updateFocus(() => _timeNavIndex--);
      } else {
        widget.onBack?.call();
      }
      return KeyEventResult.handled;
    }
    if (key.isRightKey) {
      if (_timeNavIndex < 2) _updateFocus(() => _timeNavIndex++);
      return KeyEventResult.handled;
    }
    if (key.isDownKey) {
      if (widget.channels.isNotEmpty) {
        _updateFocus(() {
          _focusZone = _GuideZone.grid;
          _gridColumn = 0;
          _focusedProgram = null;
        });
        _scrollToChannel(_gridChannelIndex);
      }
      return KeyEventResult.handled;
    }
    if (key.isUpKey) {
      widget.onNavigateUp?.call();
      return KeyEventResult.handled;
    }
    if (key.isSelectKey) {
      switch (_timeNavIndex) {
        case 0:
          _shiftTimeRange(-2);
        case 1:
          // The menu takes focus; suppress the in-flight SELECT key-up so the
          // press that opened it cannot also activate the first menu item.
          SelectKeyUpSuppressor.suppressSelectUntilKeyUp();
          _showDayPicker();
        case 2:
          _shiftTimeRange(2);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleGridKey(LogicalKeyboardKey key) {
    if (key.isUpKey || key.isDownKey) {
      // Move through rows in displayed (source-grouped) order. Stepping the
      // flat channel index would interleave sources whose channel numbers
      // overlap and could dead-end before the last displayed row.
      final order = _displayOrderChannelIndexes;
      final position = order.indexOf(_gridChannelIndex);
      if (key.isUpKey && position <= 0) {
        _updateFocus(() {
          _focusZone = _GuideZone.timeNav;
          _timeNavIndex = 1;
        });
      } else if (key.isUpKey || (position != -1 && position < order.length - 1)) {
        _updateFocus(() {
          _gridChannelIndex = order[key.isUpKey ? position - 1 : position + 1];
          if (_gridColumn == 1) {
            // Keep the focused time rather than jumping back to what airs now,
            // which may be scrolled out of view (or outside a picked window).
            final anchor = _focusedProgram;
            _focusedProgram = anchor == null
                ? _findCurrentProgram(_gridChannelIndex)
                : _programNearTime(_gridChannelIndex, _programAnchorEpoch(anchor));
            // A row with nothing in this window has no program cell; land on
            // its channel cell instead of nowhere.
            if (_focusedProgram == null) _gridColumn = 0;
          }
        });
        _scrollToChannel(_gridChannelIndex);
        if (_gridColumn == 1) _scrollToProgramTime(_focusedProgram);
      }
      return KeyEventResult.handled;
    }
    if (key.isRightKey) {
      if (_gridColumn == 0) {
        final program = _findCurrentProgram(_gridChannelIndex);
        if (program != null) {
          _updateFocus(() {
            _gridColumn = 1;
            _focusedProgram = program;
          });
          _scrollToProgramTime(program);
        }
      } else {
        // Already in program column — move to next program
        _navigateToAdjacentProgram(_gridChannelIndex, forward: true);
      }
      return KeyEventResult.handled;
    }
    if (key.isLeftKey) {
      if (_gridColumn == 1) {
        // Try moving to previous program; if at first program, go back to channel column
        if (!_navigateToAdjacentProgram(_gridChannelIndex, forward: false)) {
          _updateFocus(() {
            _gridColumn = 0;
            _focusedProgram = null;
          });
        }
      } else {
        widget.onBack?.call();
      }
      return KeyEventResult.handled;
    }
    if (key.isSelectKey) {
      if (_gridChannelIndex >= 0 && _gridChannelIndex < widget.channels.length) {
        final channel = widget.channels[_gridChannelIndex];
        if (_gridColumn == 0) {
          _tuneFromGuide(channel);
        } else if (_focusedProgram != null) {
          _activateProgram(channel, _focusedProgram!);
        }
      }
      return KeyEventResult.handled;
    }
    // 'F' key toggles favorite on focused channel
    if (key == LogicalKeyboardKey.keyF && _gridColumn == 0) {
      if (_gridChannelIndex >= 0 && _gridChannelIndex < widget.channels.length) {
        widget.onToggleFavorite?.call(widget.channels[_gridChannelIndex]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  LiveTvProgram? _findCurrentProgram(int channelIndex) {
    if (channelIndex < 0 || channelIndex >= widget.channels.length) return null;
    final channel = widget.channels[channelIndex];
    final programs = _getProgramsForChannel(channel);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    // Currently airing
    for (final p in programs) {
      if ((p.beginsAt ?? 0) <= now && (p.endsAt ?? 0) > now) return p;
    }
    // First future program
    for (final p in programs) {
      if ((p.endsAt ?? 0) > now) return p;
    }
    return programs.firstOrNull;
  }

  /// Epoch second a vertical move should stay at: the focused program's start,
  /// or the window start when it began before the window.
  int _programAnchorEpoch(LiveTvProgram program) {
    final gridStartEpoch = _gridStart.millisecondsSinceEpoch ~/ 1000;
    final begin = program.beginsAt ?? gridStartEpoch;
    return begin < gridStartEpoch ? gridStartEpoch : begin;
  }

  /// The program on [channelIndex] airing at [epoch], else the one closest to
  /// it, or null when the channel has nothing in this window.
  LiveTvProgram? _programNearTime(int channelIndex, int epoch) {
    if (channelIndex < 0 || channelIndex >= widget.channels.length) return null;
    LiveTvProgram? nearest;
    var nearestDistance = 0;
    for (final program in _getProgramsForChannel(widget.channels[channelIndex])) {
      final begin = program.beginsAt ?? 0;
      final end = program.endsAt ?? begin;
      if (begin <= epoch && end > epoch) return program;
      final distance = begin > epoch ? begin - epoch : epoch - end;
      if (nearest == null || distance < nearestDistance) {
        nearest = program;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  /// Navigate to the next or previous program on the same channel.
  /// Returns true if navigation succeeded, false if at the boundary.
  bool _navigateToAdjacentProgram(int channelIndex, {required bool forward}) {
    if (channelIndex < 0 || channelIndex >= widget.channels.length) return false;
    final channel = widget.channels[channelIndex];
    final programs = _getProgramsForChannel(channel);
    if (programs.isEmpty || _focusedProgram == null) return false;

    final currentIndex = programs.indexWhere((p) => identical(p, _focusedProgram));
    if (currentIndex < 0) return false;

    final nextIndex = forward ? currentIndex + 1 : currentIndex - 1;
    if (nextIndex < 0 || nextIndex >= programs.length) return false;

    final nextProgram = programs[nextIndex];
    _updateFocus(() => _focusedProgram = nextProgram);
    _scrollToProgramTime(nextProgram);
    return true;
  }

  void _scrollToChannel(int index) {
    if (!_gridVerticalController.hasClients) return;
    final targetTop = _rowTopForChannelIndex(index);
    final targetBottom = targetTop + _rowHeight;
    final viewportTop = _gridVerticalController.offset;
    final viewportBottom = viewportTop + _gridVerticalController.position.viewportDimension;

    double? newOffset;
    if (targetTop < viewportTop) {
      newOffset = targetTop;
    } else if (targetBottom > viewportBottom) {
      newOffset = targetBottom - _gridVerticalController.position.viewportDimension;
    }

    if (newOffset != null) {
      final clamped = newOffset.clamp(0.0, _gridVerticalController.position.maxScrollExtent);
      _gridVerticalController.animateTo(clamped, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      if (_channelVerticalController.hasClients) {
        _channelVerticalController.animateTo(
          clamped.clamp(0.0, _channelVerticalController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    }
  }

  void _scrollToProgramTime(LiveTvProgram? program) {
    if (program == null || !_gridHorizontalController.hasClients) return;

    final gridStartEpoch = _gridStart.millisecondsSinceEpoch ~/ 1000;
    final gridEndEpoch = _gridEnd.millisecondsSinceEpoch ~/ 1000;
    final progStart = (program.beginsAt ?? gridStartEpoch).clamp(gridStartEpoch, gridEndEpoch);
    final startOffset = progStart - gridStartEpoch;
    final left = (startOffset / (_minutesPerSlot * 60)) * _slotWidth;

    final viewportWidth = _gridHorizontalController.position.viewportDimension;
    final currentOffset = _gridHorizontalController.offset;

    if (left < currentOffset || left > currentOffset + viewportWidth - 100) {
      final maxScroll = _gridHorizontalController.position.maxScrollExtent;
      _gridHorizontalController.jumpTo((left - 50).clamp(0.0, maxScroll));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Full-screen spinner only before the first window has loaded. In-session
    // window reloads keep the grid mounted (so the day/time pickers and the
    // guide Focus stay alive for D-pad navigation) and show a lightweight
    // overlay instead — stale programs stay tappable while it settles.
    if (_isLoading && !_hasLoadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      fit: StackFit.passthrough,
      children: [
        Focus(
          focusNode: _guideFocusNode,
          onFocusChange: _handleGuideFocusChange,
          onKeyEvent: _handleKeyEvent,
          child: _buildGuideGrid(theme),
        ),
        if (_isLoading)
          const Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 3))),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildGuideGrid(ThemeData theme) {
    final rows = _guideRows;
    return Column(
      children: [
        // Live TV mini-player (build #12): video on top, guide below,
        // both visible at once — the Plex reference layout, portrait
        // phones only. The slot appears once a channel is tuned and hides
        // when playback stops; scrolling the grid never touches it.
        if (_miniPlayerEnabled && _miniPlayer.status != LiveTvMiniPlayerStatus.idle)
          LiveTvMiniPlayer(
            controller: _miniPlayer,
            nowPlayingTitle: _nowPlayingTitleFor(_miniPlayer.channel),
            onFullscreen: _openMiniPlayerFullscreen,
            onResume: _resumeMiniPlayer,
            onWatchLive: _watchLiveMiniPlayer,
            videoBuilder: widget.debugVideoBuilder,
          ),
        _buildCategoryPicker(),
        _buildTimeNavigation(theme),
        // Subtle EPG loading indicator (Task B): a thin bar under the time
        // navigation, visible only while a visible IPTV channel's guide is
        // still loading. It never takes over the screen or blocks
        // interaction, and Plex/Jellyfin/Emby loads keep their existing
        // spinner/overlay behaviour unchanged.
        if (_isIptvEpgLoading)
          const SizedBox(
            height: 3,
            child: LinearProgressIndicator(minHeight: 3),
          ),
        Expanded(
          child: ListenableBuilder(
            listenable: _gridHorizontalController,
            builder: (context, child) {
              return Stack(children: [child!, _buildNowIndicatorOverlay(theme)]);
            },
            child: Column(
              children: [
                Row(
                  children: [
                    const SizedBox(width: _channelColumnWidth, height: _timeHeaderHeight),
                    Expanded(
                      child: SingleChildScrollView(
                        controller: _headerHorizontalController,
                        scrollDirection: Axis.horizontal,
                        physics: const ClampingScrollPhysics(),
                        child: SizedBox(
                          width: _totalGridWidth(),
                          height: _timeHeaderHeight,
                          child: _buildTimeHeader(theme),
                        ),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Row(
                    children: [
                      SizedBox(
                        width: _channelColumnWidth,
                        child: CustomScrollView(
                          controller: _channelVerticalController,
                          physics: const NeverScrollableScrollPhysics(),
                          slivers: [
                            SliverVariedExtentList.builder(
                              itemCount: rows.length,
                              itemExtentBuilder: (index, _) => _guideRowHeight(rows[index]),
                              itemBuilder: (context, index) {
                                final row = rows[index];
                                return switch (row) {
                                  _GuideSourceHeaderRow(:final label) => _buildSourceHeaderCell(label, theme),
                                  _GuideChannelRow(:final channel, :final channelIndex) => _buildChannelCell(
                                    channel,
                                    theme,
                                    index: channelIndex,
                                  ),
                                };
                              },
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            if (notification is ScrollUpdateNotification &&
                                notification.metrics.axis == Axis.vertical) {
                              if (_channelVerticalController.hasClients) {
                                _channelVerticalController.jumpTo(notification.metrics.pixels);
                              }
                            }
                            return false;
                          },
                          child: SingleChildScrollView(
                            controller: _gridHorizontalController,
                            scrollDirection: Axis.horizontal,
                            physics: const ClampingScrollPhysics(),
                            child: SizedBox(
                              width: _totalGridWidth(),
                              child: CustomScrollView(
                                controller: _gridVerticalController,
                                slivers: [
                                  SliverVariedExtentList.builder(
                                    itemCount: rows.length,
                                    itemExtentBuilder: (index, _) => _guideRowHeight(rows[index]),
                                    itemBuilder: (context, index) {
                                      final row = rows[index];
                                      return switch (row) {
                                        _GuideSourceHeaderRow(:final label) => _buildSourceHeaderGridRow(label, theme),
                                        _GuideChannelRow(:final channel, :final channelIndex) => _buildProgramRow(
                                          channel,
                                          _getProgramsForChannel(channel),
                                          theme,
                                          channelIndex: channelIndex,
                                        ),
                                      };
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNowIndicatorOverlay(ThemeData _) {
    final now = DateTime.now();
    if (now.isBefore(_gridStart) || now.isAfter(_gridEnd)) {
      return const SizedBox.shrink();
    }
    final minutesSinceStart = now.difference(_gridStart).inMinutes.toDouble();
    final nowOffset = (minutesSinceStart / _minutesPerSlot) * _slotWidth;
    final scrollOffset = _gridHorizontalController.hasClients ? _gridHorizontalController.offset : 0.0;
    final left = _channelColumnWidth + nowOffset - scrollOffset;

    // Hide when scrolled behind the channel column
    if (left < _channelColumnWidth) return const SizedBox.shrink();

    final gridHeight = _timeHeaderHeight + _guideContentHeight(_guideRows);

    return Positioned(
      left: left,
      top: 0,
      height: gridHeight,
      child: IgnorePointer(child: Container(width: 2, color: Colors.red)),
    );
  }

  String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(day.year, day.month, day.day);

    if (target == today) return t.liveTv.today;
    // Calendar arithmetic: across a DST change a day is 23 or 25 hours.
    if (target == DateTime(today.year, today.month, today.day + 1)) return t.liveTv.tomorrow;

    return DateFormat('EEEE', LocaleSettings.currentLocale.intlLocaleName).format(target);
  }

  List<(String, int)> get _timeSlots => [
    (t.liveTv.midnight, 0),
    (t.liveTv.overnight, 2),
    (t.liveTv.morning, 6),
    (t.liveTv.daytime, 12),
    (t.liveTv.evening, 18),
    (t.liveTv.lateNight, 22),
  ];

  Rect? _menuAnchorRect() {
    final renderBox = _dayPickerKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return null;

    final buttonPos = renderBox.localToGlobal(Offset.zero);
    final buttonSize = renderBox.size;
    return Rect.fromLTWH(buttonPos.dx, buttonPos.dy, buttonSize.width, buttonSize.height);
  }

  Future<void> _showDayPicker() async {
    final anchorRect = _menuAnchorRect();
    if (anchorRect == null) return;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final gridDay = DateTime(_gridStart.year, _gridStart.month, _gridStart.day);

    final days = <DateTime>[];
    for (var i = 0; i < 8; i++) {
      days.add(DateTime(today.year, today.month, today.day + i));
    }

    final value = await showAppMenu<Object>(
      context,
      anchorRect: anchorRect,
      focusFirstItem: InputModeTracker.isKeyboardMode(context),
      entries: [
        AppMenuItem<Object>(value: 'now', label: t.liveTv.now),
        ...days.map((day) {
          final isSelected = day == gridDay;
          final label = _dayLabel(day);
          return AppMenuItem<Object>(value: day, label: label, selected: isSelected);
        }),
      ],
    );
    if (!mounted) return;
    if (value == null) {
      _guideFocusNode.requestFocus();
      return;
    }
    if (value is String && value == 'now') {
      _jumpToNow();
      _guideFocusNode.requestFocus();
    } else if (value is DateTime) {
      // Apply the picked day right away; the slot menu that follows only
      // refines it (dismissing it keeps this window).
      _applyDay(value);
      await _showTimeSlotPicker(value);
    }
  }

  /// Re-anchors the 6h window onto [day] keeping the current window's
  /// time-of-day. Picking 'Now' instead re-anchors live via [_jumpToNow].
  /// #1297: a deliberately picked day is never yanked back by the drift
  /// checker — [_nowWasInWindow] stays false when now is outside it.
  void _applyDay(DateTime day) {
    final hour = _gridStart.hour;
    final minute = _gridStart.minute;
    setState(() {
      _gridStart = DateTime(day.year, day.month, day.day, hour, minute);
      _gridEnd = _gridStart.add(const Duration(hours: 6));
      _nowWasInWindow = _nowInWindow(DateTime.now());
    });
    unawaited(_loadPrograms());
  }

  Future<void> _showTimeSlotPicker(DateTime day) async {
    final anchorRect = _menuAnchorRect();
    if (anchorRect == null) return;

    final label = _dayLabel(day).toUpperCase();

    final value = await showAppMenu<int>(
      context,
      anchorRect: anchorRect,
      focusFirstItem: InputModeTracker.isKeyboardMode(context),
      entries: [
        AppMenuItem<int>(
          value: -1,
          icon: Symbols.chevron_left_rounded,
          child: Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: .bold)),
        ),
        const AppMenuDivider<int>(),
        ..._timeSlots.map((slot) {
          return AppMenuItem<int>(value: slot.$2, label: slot.$1);
        }),
      ],
    );
    if (!mounted) return;
    if (value == null) {
      _guideFocusNode.requestFocus();
      return;
    }
    if (value == -1) {
      await _showDayPicker();
      return;
    }
    setState(() {
      _gridStart = DateTime(day.year, day.month, day.day, value);
      _gridEnd = _gridStart.add(const Duration(hours: 6));
      _nowWasInWindow = _nowInWindow(DateTime.now());
    });
    unawaited(_loadPrograms());
    _guideFocusNode.requestFocus();
  }

  Widget _timeNavFocusWrap({required Widget child, required int index}) {
    return _GuideFocusSelector(
      valueListenable: _focusSnapshot,
      isSelected: (focus) => focus.hasFocus && focus.zone == _GuideZone.timeNav && focus.timeNavIndex == index,
      builder: (context, isFocused) {
        if (!isFocused) return child;
        return Container(
          decoration: FocusTheme.textFillFocusDecoration(context, isFocused: true, borderRadius: MonoTokens.radiusFull),
          child: child,
        );
      },
    );
  }

  /// Guide category picker (build #17, §11): a horizontal chip row above
  /// the time navigation — "All categories" plus one chip per visible
  /// live TV category on the current source scope. Hidden categories
  /// never appear (the entries come from
  /// [IptvClient.visibleLiveCategories], the same hidden rule as the
  /// guide rows). Switching is an in-memory filter over the loaded rows
  /// — no network call, no reload — so the rows appear immediately.
  /// Empty when the lineup has no IPTV categories (Plex-only) or the
  /// entries have not loaded yet.
  Widget _buildCategoryPicker() {
    final categories = widget.guideCategories;
    if (categories.isEmpty) return const SizedBox.shrink();
    final selected = widget.selectedGuideCategory;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          children: [
            ChoiceChip(
              label: Text(t.liveTv.allCategories),
              selected: selected == null,
              showCheckmark: false,
              onSelected: (_) => widget.onSelectGuideCategory?.call(null),
            ),
            for (final entry in categories) ...[
              const SizedBox(width: 8),
              ChoiceChip(
                label: Text(entry.label),
                selected: selected?.serverId == entry.serverId && selected?.categoryId == entry.categoryId,
                showCheckmark: false,
                onSelected: (_) => widget.onSelectGuideCategory?.call(entry),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTimeNavigation(ThemeData theme) {
    final timeLabel = formatClockTime(_gridStart, is24Hour: MediaQuery.alwaysUse24HourFormatOf(context));
    final dayLabel = _dayLabel(_gridStart);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          _timeNavFocusWrap(
            index: 0,
            child: IconButton(
              icon: const AppIcon(Symbols.chevron_left_rounded),
              onPressed: () => _shiftTimeRange(-2),
              iconSize: 20,
              visualDensity: VisualDensity.compact,
            ),
          ),
          Expanded(
            child: Row(
              mainAxisAlignment: .center,
              children: [
                _timeNavFocusWrap(
                  index: 1,
                  child: ClickableCursor(
                    child: GestureDetector(
                      key: _dayPickerKey,
                      onTap: _showDayPicker,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: tokens(context).text.withValues(alpha: 0.08),
                          borderRadius: const BorderRadius.all(Radius.circular(MonoTokens.radiusFull)),
                        ),
                        child: Row(
                          mainAxisSize: .min,
                          children: [
                            Text(dayLabel, style: theme.textTheme.labelLarge),
                            const SizedBox(width: 2),
                            AppIcon(Symbols.arrow_drop_down_rounded, size: 18, color: theme.colorScheme.onSurface),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(timeLabel, style: theme.textTheme.labelLarge),
              ],
            ),
          ),
          _timeNavFocusWrap(
            index: 2,
            child: IconButton(
              icon: const AppIcon(Symbols.chevron_right_rounded),
              onPressed: () => _shiftTimeRange(2),
              iconSize: 20,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeHeader(ThemeData theme) {
    final is24Hour = MediaQuery.alwaysUse24HourFormatOf(context);
    final slots = <Widget>[];
    var current = _gridStart;

    while (current.isBefore(_gridEnd)) {
      final timeStr = formatClockTime(current, is24Hour: is24Hour);
      slots.add(
        SizedBox(
          width: _slotWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Align(
              alignment: .centerLeft,
              child: Text(timeStr, style: theme.textTheme.labelSmall?.copyWith(color: tokens(context).textMuted)),
            ),
          ),
        ),
      );
      current = current.add(const Duration(minutes: _minutesPerSlot));
    }

    return Row(children: slots);
  }

  Widget _buildSourceHeaderCell(String label, ThemeData theme) {
    return Container(
      height: _sourceHeaderRowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: .centerLeft,
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: tokens(context).textMuted, fontWeight: .w700),
        maxLines: 2,
        overflow: .ellipsis,
      ),
    );
  }

  Widget _buildSourceHeaderGridRow(String label, ThemeData theme) {
    return SizedBox(
      height: _sourceHeaderRowHeight,
      child: ClipRect(
        child: ListenableBuilder(
          listenable: _gridHorizontalController,
          builder: (context, child) {
            final scrollOffset = _gridHorizontalController.hasClients ? _gridHorizontalController.offset : 0.0;
            return Transform.translate(offset: Offset(scrollOffset, 0), child: child);
          },
          child: Align(
            alignment: .centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: tokens(context).textMuted,
                  fontWeight: .w700,
                  letterSpacing: 0.3,
                ),
                maxLines: 1,
                overflow: .ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChannelCell(LiveTvChannel channel, ThemeData theme, {required int index}) {
    final multiServer = context.read<MultiServerProvider>();
    final serverId = serverIdOrNull(channel.serverId);
    final client = serverId == null ? null : multiServer.getClientForServer(serverId);

    return _GuideFocusSelector(
      valueListenable: _focusSnapshot,
      isSelected: (focus) =>
          focus.hasFocus && focus.zone == _GuideZone.grid && focus.gridColumn == 0 && focus.channelIndex == index,
      builder: (context, isFocused) {
        return _ChannelCell(
          rowHeight: _rowHeight,
          channelColumnWidth: _channelColumnWidth,
          channelThumb: channel.thumb,
          client: client,
          channel: channel,
          theme: theme,
          onTap: () => _tuneFromGuide(channel),
          // Long-press opens the channel menu (build #17, §9) — it never
          // toggles anything directly. The menu is anchored to the cell
          // via the builder context.
          onLongPress: widget.onToggleFavorite != null || widget.onHideChannel != null
              ? () => unawaited(_showChannelMenu(channel, anchorContext: context))
              : null,
          isFocused: isFocused,
          isFavorite: widget.isFavoriteChannel?.call(channel) ?? false,
          showCatchUpBadge: widget.showCatchUpBadge,
          fallbackBuilder: () => _buildChannelNameFallback(channel, theme),
        );
      },
    );
  }

  Widget _buildChannelNameFallback(LiveTvChannel channel, ThemeData theme) {
    return Column(
      mainAxisAlignment: .center,
      children: [
        if (channel.number != null)
          Text(
            channel.number!,
            style: theme.textTheme.labelSmall?.copyWith(color: tokens(context).textMuted),
            maxLines: 1,
          ),
        Text(
          channel.displayName,
          style: theme.textTheme.bodySmall?.copyWith(fontWeight: .w500),
          maxLines: 1,
          overflow: .ellipsis,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildProgramRow(
    LiveTvChannel channel,
    List<LiveTvProgram> programs,
    ThemeData theme, {
    required int channelIndex,
  }) {
    // Visible rows drive the lazy IPTV EPG fetch for their own channel.
    _ensureIptvEpg(channel);
    // Build #28: the row's lifecycle owns the fetch — when the row
    // scrolls out of the viewport (the sliver disposes it), the fetch
    // stops instead of running to completion unobserved. The stable key
    // keeps the state across rebuilds, so a setState while the row is
    // visible never cancels a fetch that is still wanted.
    return _IptvEpgRowLifecycle(
      key: ValueKey(liveTvChannelScopeKey(channel)),
      channelKey: channel.key,
      support: _iptvSupportFor(channel),
      child: _buildProgramRowContent(channel, programs, theme, channelIndex: channelIndex),
    );
  }

  Widget _buildProgramRowContent(
    LiveTvChannel channel,
    List<LiveTvProgram> programs,
    ThemeData theme, {
    required int channelIndex,
  }) {
    final scopeKey = liveTvChannelScopeKey(channel);
    // Build #8 Task 3: a failed channel shows a visible retry state, not
    // silent hour placeholders — but only when it has no real programs at
    // all; a channel with partial programs keeps them. (The merged
    // `programs` below already contain placeholders for a failed channel,
    // so this checks the real programs, not the merged list.)
    final realPrograms = _programsByChannelScope[scopeKey] ?? const <LiveTvProgram>[];
    if (_iptvSupportFor(channel) != null && _iptvEpgFailed.contains(scopeKey) && realPrograms.isEmpty) {
      return _buildEpgFailedRow(channel, theme);
    }
    if (programs.isEmpty) {
      // Three states, visibly distinct (build #8 Task 3): an IPTV row
      // still loading shows a spinner + "Loading guide…" (never a blank
      // row — the old blank row plus a 3px header line was the whole reason
      // Matt could not tell the guide was loading); a ready channel with
      // genuinely no programs shows "No program data available"; a
      // Plex/Jellyfin/Emby row with genuinely no programs keeps the old
      // "No program data available" bar.
      final iptvLoading = _iptvSupportFor(channel) != null && !_isChannelEpgReady(channel);
      final tk = tokens(context);
      return SizedBox(
        height: _rowHeight,
        child: Padding(
          padding: EdgeInsets.only(right: tk.groupGap, bottom: tk.groupGap),
          child: Material(
            color: Color.alphaBlend(tk.surface.withValues(alpha: 0.5), tk.bg),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(tk.radiusXs)),
            child: iptvLoading
                ? Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          t.liveTv.loadingGuide,
                          style: theme.textTheme.bodySmall?.copyWith(color: tk.textMuted),
                        ),
                      ],
                    ),
                  )
                : Center(
                    child: Text(
                      t.liveTv.noPrograms,
                      style: theme.textTheme.bodySmall?.copyWith(color: tk.textMuted),
                    ),
                  ),
          ),
        ),
      );
    }

    final gridStartEpoch = _gridStart.millisecondsSinceEpoch ~/ 1000;
    final gridEndEpoch = _gridEnd.millisecondsSinceEpoch ~/ 1000;

    return SizedBox(
      height: _rowHeight,
      child: ListenableBuilder(
        listenable: _gridHorizontalController,
        builder: (context, _) {
          final scrollOffset = _gridHorizontalController.hasClients ? _gridHorizontalController.offset : 0.0;
          // Keep one slot of overscan so the next D-pad target exists before the horizontal jump.
          final visibleStart = scrollOffset > _slotWidth ? scrollOffset - _slotWidth : 0.0;
          final visibleEnd = scrollOffset + MediaQuery.sizeOf(context).width + _slotWidth;
          final blocks = <Widget>[];

          for (final program in programs) {
            final progStart = (program.beginsAt ?? gridStartEpoch).clamp(gridStartEpoch, gridEndEpoch);
            final progEnd = (program.endsAt ?? gridEndEpoch).clamp(gridStartEpoch, gridEndEpoch);
            if (progEnd <= progStart) continue;

            final startOffset = progStart - gridStartEpoch;
            final duration = progEnd - progStart;
            final left = (startOffset / (_minutesPerSlot * 60)) * _slotWidth;
            final width = (duration / (_minutesPerSlot * 60)) * _slotWidth;
            final clampedWidth = width.clamp(6.0, double.infinity);
            if (left + clampedWidth < visibleStart || left > visibleEnd) continue;

            blocks.add(
              Positioned(
                key: ObjectKey(program),
                left: left,
                width: clampedWidth,
                top: 0,
                bottom: 0,
                child: _buildProgramBlock(
                  channel,
                  program,
                  theme,
                  channelIndex: channelIndex,
                  tileLeft: left,
                  tileWidth: clampedWidth,
                  scrollOffset: scrollOffset,
                ),
              ),
            );
          }

          return Stack(children: blocks);
        },
      ),
    );
  }

  Widget _buildProgramBlock(
    LiveTvChannel channel,
    LiveTvProgram program,
    ThemeData theme, {
    required int channelIndex,
    required double tileLeft,
    required double tileWidth,
    required double scrollOffset,
  }) {
    return _GuideFocusSelector(
      valueListenable: _focusSnapshot,
      isSelected: (focus) =>
          focus.hasFocus &&
          focus.zone == _GuideZone.grid &&
          focus.gridColumn == 1 &&
          focus.channelIndex == channelIndex &&
          identical(focus.program, program),
      builder: (context, isFocused) {
        final tk = tokens(context);
        final isCurrentlyAiring = program.isCurrentlyAiring;
        final isPast = program.endsAt != null && program.endsAt! < DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final isRecordingScheduled = _isRecordingScheduled(program);

        final Color fillColor;
        final Color titleColor;
        final Color subtitleColor;
        if (isFocused) {
          // Inverted focus card: primary == text in the mono theme, so the cursor
          // reads as a solid inverted cell (white card, dark text in dark mode).
          fillColor = theme.colorScheme.primary;
          titleColor = theme.colorScheme.onPrimary;
          subtitleColor = theme.colorScheme.onPrimary.withValues(alpha: 0.7);
        } else if (program.isPlaceholder) {
          // "No information available" hour block: deliberately muted and
          // distinct from a real program — it carries no invented content.
          // Focus still inverts it (branch above) so D-pad users can land
          // on it and open its detail sheet.
          fillColor = Color.alphaBlend(tk.surface.withValues(alpha: 0.3), tk.bg);
          titleColor = tk.text.withValues(alpha: 0.45);
          subtitleColor = tk.text.withValues(alpha: 0.3);
        } else if (isPast) {
          fillColor = Color.alphaBlend(tk.surface.withValues(alpha: 0.5), tk.bg);
          titleColor = tk.text.withValues(alpha: 0.5);
          subtitleColor = tk.text.withValues(alpha: 0.3);
        } else if (isCurrentlyAiring) {
          fillColor = airingFill(context);
          titleColor = tk.text;
          subtitleColor = tk.textMuted;
        } else {
          fillColor = tk.surface;
          titleColor = tk.text;
          subtitleColor = tk.textMuted;
        }
        final radius = BorderRadius.circular(isFocused ? tk.radiusSm : tk.radiusXs);

        return Padding(
          padding: EdgeInsets.only(right: tk.groupGap, bottom: tk.groupGap),
          child: Material(
            color: fillColor,
            shape: RoundedRectangleBorder(borderRadius: radius),
            child: InkWell(
              borderRadius: radius,
              mouseCursor: SystemMouseCursors.click,
              canRequestFocus: false,
              onTap: () => _activateProgram(channel, program),
              onLongPress: () => _showProgramDetails(channel, program),
              onSecondaryTap: () => _showProgramDetails(channel, program),
              child: Padding(
                padding: .fromLTRB(
                  6 + (scrollOffset - tileLeft).clamp(0.0, (tileWidth - tk.groupGap - 32).clamp(0.0, double.infinity)),
                  4,
                  6,
                  4,
                ),
                child: Column(
                  crossAxisAlignment: .start,
                  mainAxisAlignment: .center,
                  children: [
                    Row(
                      children: [
                        if (isRecordingScheduled) ...[
                          _RecordingDot(color: Colors.red, tooltip: t.liveTv.recordingScheduled),
                          const SizedBox(width: 5),
                        ],
                        if (program.premiere == true) ...[
                          StatusPill(label: t.liveTv.premiereBadge, color: titleColor, dense: true),
                          const SizedBox(width: 5),
                        ],
                        Expanded(
                          child: Text(
                            program.grandparentTitle ?? program.title,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: .w600,
                              color: titleColor,
                              fontStyle: program.isPlaceholder ? FontStyle.italic : FontStyle.normal,
                            ),
                            maxLines: 1,
                            overflow: .ellipsis,
                          ),
                        ),
                      ],
                    ),
                    if (program.grandparentTitle != null)
                      Text(
                        '${program.parentIndex != null && program.index != null ? 'S${program.parentIndex}E${program.index} · ' : ''}${program.title}',
                        style: theme.textTheme.labelSmall?.copyWith(color: subtitleColor),
                        maxLines: 1,
                        overflow: .ellipsis,
                      ),
                    if (program.startTime != null)
                      Text(
                        '${formatClockTime(program.startTime!, is24Hour: MediaQuery.alwaysUse24HourFormatOf(context))} · ${formatDurationTextual(program.durationMinutes * 60_000)}',
                        style: theme.textTheme.labelSmall?.copyWith(color: subtitleColor),
                        maxLines: 1,
                        overflow: .ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showProgramDetails(LiveTvChannel channel, LiveTvProgram program) {
    showProgramDetails(
      program: program,
      channel: channel,
      posterThumb: program.thumb,
      posterServerId: channel.serverId,
      onRecordingStateChanged: (isScheduled) => _handleRecordingStateChanged(program, isScheduled),
      onCatchUp: _catchUpActionFor(channel, program),
      onTuneChannel: () => _tuneFromGuide(channel),
    );
  }

  /// Catch-up for any programme that has already started on a channel
  /// that offers it (Xtream `tv_archive = 1`). Past programmes start at
  /// their own beginning; the programme currently airing starts at its
  /// beginning too ("Start from beginning" in the details sheet). Future
  /// programmes get no catch-up action. The old code gated this on
  /// "No information" placeholders only, so every programme WITH guide
  /// data — i.e. everything Matt could actually see — had no catch-up
  /// entry at all. The player starts the archive at the programme's own
  /// start time ([_catchUpToProgram]).
  VoidCallback? _catchUpActionFor(LiveTvChannel channel, LiveTvProgram program) {
    if (!channel.hasCatchUp) return null;
    final beginsAt = program.beginsAt;
    if (beginsAt == null) return null;
    if (beginsAt >= DateTime.now().millisecondsSinceEpoch ~/ 1000) return null;
    return () => _catchUpToProgram(channel, program);
  }

  Future<void> _catchUpToProgram(LiveTvChannel channel, LiveTvProgram program) async {
    final beginsAt = program.beginsAt;
    if (beginsAt == null) return;
    await _tuneFromGuide(channel, catchUpStartEpoch: beginsAt, catchUpProgrammeTitle: program.title);
  }
}

class _GuideFocusSelector extends StatefulWidget {
  const _GuideFocusSelector({required this.valueListenable, required this.isSelected, required this.builder});

  final ValueListenable<_GuideFocusSnapshot> valueListenable;
  final bool Function(_GuideFocusSnapshot focus) isSelected;
  final Widget Function(BuildContext context, bool isSelected) builder;

  @override
  State<_GuideFocusSelector> createState() => _GuideFocusSelectorState();
}

class _GuideFocusSelectorState extends State<_GuideFocusSelector> {
  late bool _isSelected;

  @override
  void initState() {
    super.initState();
    _isSelected = widget.isSelected(widget.valueListenable.value);
    widget.valueListenable.addListener(_handleValueChanged);
  }

  @override
  void didUpdateWidget(_GuideFocusSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valueListenable != widget.valueListenable) {
      oldWidget.valueListenable.removeListener(_handleValueChanged);
      widget.valueListenable.addListener(_handleValueChanged);
    }
    _isSelected = widget.isSelected(widget.valueListenable.value);
  }

  @override
  void dispose() {
    widget.valueListenable.removeListener(_handleValueChanged);
    super.dispose();
  }

  void _handleValueChanged() {
    final isSelected = widget.isSelected(widget.valueListenable.value);
    if (isSelected == _isSelected) return;
    setState(() => _isSelected = isSelected);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _isSelected);
}

class _RecordingDot extends StatelessWidget {
  final Color color;
  final String tooltip;

  const _RecordingDot({required this.color, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

class _ChannelCell extends StatefulWidget {
  final double rowHeight;
  final double channelColumnWidth;
  final String? channelThumb;
  final MediaServerClient? client;
  final LiveTvChannel channel;
  final ThemeData theme;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isFocused;
  final bool isFavorite;
  final bool showCatchUpBadge;
  final Widget Function() fallbackBuilder;

  const _ChannelCell({
    required this.rowHeight,
    required this.channelColumnWidth,
    required this.channelThumb,
    required this.client,
    required this.channel,
    required this.theme,
    required this.onTap,
    this.onLongPress,
    required this.isFocused,
    this.isFavorite = false,
    this.showCatchUpBadge = true,
    required this.fallbackBuilder,
  });

  @override
  State<_ChannelCell> createState() => _ChannelCellState();
}

class _ChannelCellState extends State<_ChannelCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final tk = tokens(context);
    final showAction = _hovered || widget.isFocused;
    final radius = BorderRadius.circular(widget.isFocused ? tk.radiusSm : tk.radiusXs);
    // Inverted focus card, matching the program-block cursor.
    final contentColor = widget.isFocused ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTap: widget.onLongPress,
        child: SizedBox(
          height: widget.rowHeight,
          child: Padding(
            padding: EdgeInsets.only(right: tk.groupGap, bottom: tk.groupGap),
            child: Material(
              color: widget.isFocused ? theme.colorScheme.primary : tk.surface,
              shape: RoundedRectangleBorder(borderRadius: radius),
              child: InkWell(
                borderRadius: radius,
                canRequestFocus: false,
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Stack(
                    alignment: .center,
                    children: [
                      AnimatedOpacity(
                        opacity: showAction ? 0.3 : 1.0,
                        duration: FocusTheme.getAnimationDuration(context),
                        child: widget.channelThumb != null && widget.client != null
                            ? OptimizedMediaImage.thumb(
                                client: widget.client!,
                                imagePath: widget.channelThumb,
                                width: widget.channelColumnWidth - 16,
                                height: widget.rowHeight - 16,
                                fit: BoxFit.contain,
                                logoToneTarget: logoToneTargetFor(
                                  surface: widget.isFocused ? theme.colorScheme.primary : tk.surface,
                                  foreground: widget.isFocused
                                      ? theme.colorScheme.onPrimary
                                      : theme.colorScheme.onSurface,
                                ),
                              )
                            : widget.fallbackBuilder(),
                      ),
                      if (showAction) AppIcon(Symbols.play_arrow_rounded, size: 32, color: contentColor),
                      if (widget.isFavorite)
                        Positioned(
                          top: 2,
                          right: 0,
                          child: AppIcon(
                            Symbols.star_rounded,
                            size: 14,
                            color: widget.isFocused ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
                          ),
                        ),
                      // Catch-up badge (top-left, mirroring the favorite
                      // star): the channel offers catch-up TV.
                      if (widget.showCatchUpBadge && widget.channel.hasCatchUp)
                        Positioned(
                          top: 2,
                          left: 0,
                          child: AppIcon(
                            Symbols.history_rounded,
                            size: 14,
                            color: widget.isFocused ? theme.colorScheme.onPrimary : theme.colorScheme.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lifecycle owner for one guide row's IPTV EPG fetch (build #28).
///
/// The sliver disposes rows that scroll out of the viewport (+ cache
/// extent); this widget's [State.dispose] cancels that channel's
/// in-flight fetch, so a row nobody sees stops talking to the panel.
/// The stable [ValueKey] (the channel's scope key, set by the caller)
/// keeps the state across rebuilds, so a setState while the row is
/// visible never cancels a fetch that is still wanted. A null [support]
/// (a Plex/Jellyfin row) disposes to a no-op.
class _IptvEpgRowLifecycle extends StatefulWidget {
  const _IptvEpgRowLifecycle({super.key, required this.channelKey, required this.support, required this.child});

  final String channelKey;
  final IptvLiveTvSupport? support;
  final Widget child;

  @override
  State<_IptvEpgRowLifecycle> createState() => _IptvEpgRowLifecycleState();
}

class _IptvEpgRowLifecycleState extends State<_IptvEpgRowLifecycle> {
  @override
  void dispose() {
    widget.support?.cancelEpgFetchForChannel(widget.channelKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
