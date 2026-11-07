import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../i18n/app_locale_utils.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/iptv_client.dart';
import '../../media/iptv_live_tv.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/settings_service.dart' as settings;
import '../../utils/formatters.dart';
import '../../utils/iptv_initials.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/iptv_initials_checklist.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_section.dart';
import 'add_connection_screen.dart';
import 'edit_iptv_connection_screen.dart';
import 'playback_settings_screen.dart';
import 'settings_utils.dart';

/// IPTV settings area (Settings → IPTV), modelled on TiviMate's Settings.
///
/// One screen for everything IPTV: the connections (M3U + Xtream Codes),
/// per-connection channel-group enable/disable, playlist refresh, the
/// guide/catch-up badge, the EPG / TV guide settings (days, interval,
/// past days, update on start, time offset, manual update/clear), and a
/// link to the player settings IPTV uses. Every row here is wired to real
/// behaviour — nothing is a dead toggle.
/// Things TiviMate has that Plezy TV cannot do yet (recording, multi-view,
/// a parental PIN) are deliberately left out; see IPTV_FIXES_NOTES.md.
class IptvSettingsScreen extends StatelessWidget {
  const IptvSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(t.iptv.title),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(child: Text(t.iptv.intro, style: Theme.of(context).textTheme.bodyMedium)),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: SettingsGroup(
              title: t.iptv.connections,
              children: [
                _IptvConnectionsList(),
                SettingNavigationTile(
                  icon: Symbols.add_link_rounded,
                  title: t.iptv.addConnection,
                  subtitle: t.iptv.addConnectionDescription,
                  onTap: () {
                    final active = context.read<ActiveProfileProvider>().active;
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => AddConnectionScreen(targetProfile: active)),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(top: 24)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: SettingsGroup(
              title: t.iptv.playlist,
              children: [
                SettingNavigationTile(
                  icon: Symbols.refresh_rounded,
                  title: t.iptv.refreshPlaylists,
                  subtitle: t.iptv.refreshPlaylistsDescription,
                  onTap: () => _refreshPlaylists(context),
                ),
              ],
            ),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(top: 24)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: SettingsGroup(
              title: t.iptv.guideAndCatchUp,
              children: [
                SettingSwitchTile(
                  pref: settings.SettingsService.iptvShowCatchUpBadge,
                  icon: Symbols.history_rounded,
                  title: t.iptv.showCatchUpBadge,
                  subtitle: t.iptv.showCatchUpBadgeDescription,
                ),
              ],
            ),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(top: 24)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: SettingsGroup(
              title: t.iptv.epgSection,
              children: [
                SettingSelectionTile<int>(
                  pref: settings.SettingsService.iptvEpgDaysToLoad,
                  icon: Symbols.calendar_month_rounded,
                  title: t.iptv.epgDaysToLoad,
                  subtitleBuilder: (days) => t.iptv.epgDaysCount(n: days),
                  options: [1, 2, 3, 4, 7]
                      .map((days) => DialogOption(value: days, title: t.iptv.epgDaysCount(n: days)))
                      .toList(),
                ),
                SettingSelectionTile<int>(
                  pref: settings.SettingsService.iptvEpgUpdateIntervalHours,
                  icon: Symbols.schedule_rounded,
                  title: t.iptv.epgUpdateInterval,
                  subtitleBuilder: (hours) =>
                      hours == 0 ? t.iptv.epgManualOnly : t.iptv.epgHoursCount(n: hours),
                  options: [6, 12, 24, 0]
                      .map(
                        (hours) => DialogOption(
                          value: hours,
                          title: hours == 0 ? t.iptv.epgManualOnly : t.iptv.epgHoursCount(n: hours),
                        ),
                      )
                      .toList(),
                ),
                SettingSelectionTile<int>(
                  pref: settings.SettingsService.iptvEpgPastDays,
                  icon: Symbols.history_rounded,
                  title: t.iptv.epgPastDays,
                  subtitleBuilder: (days) =>
                      days == 0 ? t.iptv.epgPastDaysNone : t.iptv.epgDaysCount(n: days),
                  options: [0, 1, 2, 3, 7]
                      .map(
                        (days) => DialogOption(
                          value: days,
                          title: days == 0 ? t.iptv.epgPastDaysNone : t.iptv.epgDaysCount(n: days),
                        ),
                      )
                      .toList(),
                ),
                SettingSwitchTile(
                  pref: settings.SettingsService.iptvEpgUpdateOnStart,
                  icon: Symbols.rocket_launch_rounded,
                  title: t.iptv.epgUpdateOnStart,
                  subtitle: t.iptv.epgUpdateOnStartDescription,
                ),
                SettingSelectionTile<int>(
                  pref: settings.SettingsService.iptvEpgTimeOffsetMinutes,
                  icon: Symbols.timelapse_rounded,
                  title: t.iptv.epgTimeOffset,
                  subtitleBuilder: (minutes) =>
                      minutes == 0 ? t.iptv.epgNoOffset : t.iptv.epgOffsetMinutes(n: minutes),
                  options: [-120, -60, -30, 0, 30, 60, 120]
                      .map(
                        (minutes) => DialogOption(
                          value: minutes,
                          title: minutes == 0 ? t.iptv.epgNoOffset : t.iptv.epgOffsetMinutes(n: minutes),
                        ),
                      )
                      .toList(),
                ),
                SettingNavigationTile(
                  icon: Symbols.refresh_rounded,
                  title: t.iptv.epgUpdateNow,
                  subtitle: t.iptv.epgUpdateNowDescription,
                  onTap: () => _updateEpgNow(context),
                ),
                SettingNavigationTile(
                  icon: Symbols.delete_sweep_rounded,
                  title: t.iptv.epgClearGuide,
                  subtitle: t.iptv.epgClearGuideDescription,
                  onTap: () => _clearEpgGuide(context),
                ),
                const _EpgLastUpdatedTile(),
              ],
            ),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(top: 24)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: SettingsGroup(
              title: t.iptv.player,
              children: [
                SettingNavigationTile(
                  icon: Symbols.play_circle_rounded,
                  title: t.iptv.playerSettings,
                  subtitle: t.iptv.playerSettingsDescription,
                  destinationBuilder: (context) => const PlaybackSettingsScreen(),
                ),
              ],
            ),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }

  /// Drop every IPTV client's in-memory catalog so the next Live TV /
  /// Library load re-fetches channels, movies and series from the
  /// provider. A rebind would recreate every server's client (including
  /// Plex/Jellyfin); this only touches IPTV. The EPG cache is busted too
  /// (TiviMate's "update on playlist change": a refreshed playlist gets a
  /// fresh guide with it).
  Future<void> _refreshPlaylists(BuildContext context) async {
    final registry = context.read<ConnectionRegistry>();
    final multiServer = context.read<MultiServerProvider>();
    final connections = await registry.list();
    for (final connection in connections) {
      if (connection is! M3uConnection && connection is! XtreamConnection) continue;
      final client = multiServer.getClientForServer(ServerId(connection.id));
      if (client is IptvClient) {
        client.clearCatalogCache();
        final liveTv = client.liveTv;
        if (liveTv is IptvLiveTvSupport) await liveTv.refreshEpgCache();
      }
    }
    if (!context.mounted) return;
    showSuccessSnackBar(context, t.iptv.refreshDone);
  }

  /// "Update now": bust every IPTV client's EPG cache and force a fresh
  /// fetch. The guide refetches lazily on its next build (scroll, window
  /// shift or refresh), so the user sees fresh listings without a reload.
  Future<void> _updateEpgNow(BuildContext context) async {
    final registry = context.read<ConnectionRegistry>();
    final multiServer = context.read<MultiServerProvider>();
    final connections = await registry.list();
    for (final connection in connections) {
      if (connection is! M3uConnection && connection is! XtreamConnection) continue;
      final client = multiServer.getClientForServer(ServerId(connection.id));
      final liveTv = client?.liveTv;
      if (liveTv is IptvLiveTvSupport) await liveTv.refreshEpgCache();
    }
    if (!context.mounted) return;
    showSuccessSnackBar(context, t.iptv.epgUpdated);
  }

  /// "Clear guide": empty every IPTV client's EPG cache and leave the
  /// guide empty (hour placeholders) until the next refresh.
  Future<void> _clearEpgGuide(BuildContext context) async {
    final registry = context.read<ConnectionRegistry>();
    final multiServer = context.read<MultiServerProvider>();
    final connections = await registry.list();
    for (final connection in connections) {
      if (connection is! M3uConnection && connection is! XtreamConnection) continue;
      final client = multiServer.getClientForServer(ServerId(connection.id));
      final liveTv = client?.liveTv;
      if (liveTv is IptvLiveTvSupport) await liveTv.clearEpgCache();
    }
    if (!context.mounted) return;
    showSuccessSnackBar(context, t.iptv.epgCleared);
  }
}

/// "Last updated" status line for the EPG section: the stored timestamp of
/// the last successful EPG fetch across all IPTV clients, or "Never" before
/// the first load. Not tappable — it is a status, not an action.
class _EpgLastUpdatedTile extends StatelessWidget {
  const _EpgLastUpdatedTile();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<String>(
      valueListenable: settings.SettingsService.instance.listenable(
        settings.SettingsService.iptvEpgLastUpdated,
      ),
      builder: (context, stamp, _) {
        final updated = DateTime.tryParse(stamp);
        final text = updated == null
            ? t.iptv.epgNeverUpdated
            : '${DateFormat.MMMd(LocaleSettings.currentLocale.intlLocaleName).format(updated)} · '
                  '${formatClockTime(updated, is24Hour: MediaQuery.alwaysUse24HourFormatOf(context))}';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: .start,
            children: [
              AppIcon(Symbols.update_rounded, fill: 1),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: .start,
                  children: [
                    Text(t.iptv.epgLastUpdated, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(text, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The user's IPTV connections, live from the registry. Each row shows the
/// user-given name plus its source label (M3U / Xtream Codes) and how many
/// categories are turned off; tapping one opens its edit screen, where the
/// country/region filter (Manage groups) lives.
class _IptvConnectionsList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final registry = context.read<ConnectionRegistry>();
    return StreamBuilder<List<Connection>>(
      stream: registry.watchConnections(),
      builder: (context, snapshot) {
        final connections = (snapshot.data ?? const <Connection>[])
            .where((c) => c is M3uConnection || c is XtreamConnection)
            .toList(growable: false);
        if (connections.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              crossAxisAlignment: .start,
              children: [
                Text(t.iptv.noConnections, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(t.iptv.noConnectionsHint, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          );
        }
        return Column(
          children: [
            for (final connection in connections) ...[
              _IptvConnectionTile(connection: connection),
              _IptvConnectionInitials(connection: connection),
              if (connection is XtreamConnection)
                _IptvCatalogDiagnostics(connection: connection),
            ],
          ],
        );
      },
    );
  }
}

class _IptvConnectionTile extends StatelessWidget {
  final Connection connection;

  const _IptvConnectionTile({required this.connection});

  String get _sourceLabel => switch (connection) {
    M3uConnection() => 'M3U',
    XtreamConnection() => 'Xtream Codes',
    _ => connection.displayLabel,
  };

  String _subtitle(BuildContext context) {
    final disabledCount = switch (connection) {
      M3uConnection(:final disabledCategoryIds) => disabledCategoryIds.length,
      XtreamConnection(:final disabledCategoryIds) => disabledCategoryIds.length,
      _ => 0,
    };
    final filter = disabledCount == 0
        ? t.iptv.categoriesAllOn
        : t.iptv.categoriesOff(count: disabledCount);
    return '$_sourceLabel · $filter';
  }

  @override
  Widget build(BuildContext context) {
    return SettingNavigationTile(
      icon: Symbols.live_tv_rounded,
      title: connection.displayName,
      subtitle: _subtitle(context),
      onTap: () async {
        final changed = await Navigator.of(
          context,
        ).push<bool>(MaterialPageRoute(builder: (_) => EditIptvConnectionScreen(connection: connection)));
        if (changed != true || !context.mounted) return;
        // The edit screen persisted the new filter; rebind so the client
        // is recreated with it (the filter is baked in at construction).
        final activeId = context.read<ActiveProfileProvider>().active?.id;
        if (activeId != null) {
          unawaited(context.read<ActiveProfileBinder>().rebindIfActive(activeId));
        }
      },
    );
  }
}

/// The category-initials filter for one IPTV connection (build #8 Task 4,
/// redesigned build #10), grouped with the categories on the IPTV settings
/// screen: the initials that keep repeating across this connection's
/// CATEGORY names, each with a switch to turn every category carrying it
/// off. Collapsed by default; the checklist loads its initials only when
/// first expanded.
///
/// Unlike the edit screen's deferred save, a toggle here persists
/// immediately (registry upsert + rebind, like the edit screen's caller
/// does after Save), so the filter applies everywhere at once.
class _IptvConnectionInitials extends StatefulWidget {
  final Connection connection;

  const _IptvConnectionInitials({required this.connection});

  @override
  State<_IptvConnectionInitials> createState() => _IptvConnectionInitialsState();
}

class _IptvConnectionInitialsState extends State<_IptvConnectionInitials> {
  bool _expanded = false;
  List<IptvInitial>? _initials;

  Set<String> get _disabled => switch (widget.connection) {
    M3uConnection(:final disabledInitials) => disabledInitials.toSet(),
    XtreamConnection(:final disabledInitials) => disabledInitials.toSet(),
    _ => <String>{},
  };

  Future<void> _persist(Set<String> disabled) async {
    final registry = context.read<ConnectionRegistry>();
    final updated = switch (widget.connection) {
      final M3uConnection c => c.copyWith(disabledInitials: disabled.toList()),
      final XtreamConnection c => c.copyWith(disabledInitials: disabled.toList()),
      _ => widget.connection,
    };
    await registry.upsert(updated);
    if (!mounted) return;
    final activeId = context.read<ActiveProfileProvider>().active?.id;
    if (activeId != null) {
      unawaited(context.read<ActiveProfileBinder>().rebindIfActive(activeId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final offCount = _disabled.length;
    final total = _initials?.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FocusableListTile(
          title: Text(t.connections.iptvFilterInitials, style: theme.textTheme.titleSmall),
          subtitle: total == null
              ? null
              : offCount == 0
                  ? Text(
                      t.connections.iptvFilterInitialsCount(n: total),
                      style: theme.textTheme.bodySmall,
                    )
                  : Text(
                      t.connections.iptvFilterSectionOff(off: offCount, total: total),
                      style: theme.textTheme.bodySmall,
                    ),
          trailing: AppIcon(
            _expanded ? Symbols.expand_less_rounded : Symbols.expand_more_rounded,
            fill: 1,
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: IptvInitialsChecklist(
              connection: widget.connection,
              disabled: _disabled,
              onDisabledChanged: (next) => unawaited(_persist(next)),
              onLoaded: (initials) => setState(() => _initials = initials),
            ),
          ),
      ],
    );
  }
}

/// On-device series catalog readout (build #10, diagnosis recommendation
/// 6): what this phone loaded from the series catalog — the unfiltered
/// row count, the series category count, per-category row counts for the
/// first few categories, and how many initials/categories are turned off.
/// Collapsed by default; loads only when first expanded, through its own
/// [IptvClient] (created from [connection], closed on dispose), like the
/// initials checklist. Xtream only — M3U has no series catalog.
class _IptvCatalogDiagnostics extends StatefulWidget {
  final XtreamConnection connection;

  const _IptvCatalogDiagnostics({required this.connection});

  @override
  State<_IptvCatalogDiagnostics> createState() => _IptvCatalogDiagnosticsState();
}

class _IptvCatalogDiagnosticsState extends State<_IptvCatalogDiagnostics> {
  bool _expanded = false;
  bool _loading = false;
  bool _failed = false;
  IptvCatalogDiagnostics? _diagnostics;

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final client = IptvClient.forConnection(widget.connection);
    try {
      final diagnostics = await client.seriesCatalogDiagnostics();
      if (!mounted) return;
      setState(() => _diagnostics = diagnostics);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    } finally {
      client.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diagnostics = _diagnostics;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FocusableListTile(
          title: Text(t.iptv.catalogDiagnosticsTitle, style: theme.textTheme.titleSmall),
          subtitle: Text(t.iptv.catalogDiagnosticsHint, style: theme.textTheme.bodySmall),
          trailing: AppIcon(
            _expanded ? Symbols.expand_less_rounded : Symbols.expand_more_rounded,
            fill: 1,
          ),
          onTap: () {
            setState(() => _expanded = !_expanded);
            if (_expanded && diagnostics == null) unawaited(_load());
          },
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: _loading
                ? Text(t.iptv.catalogDiagnosticsLoading, style: theme.textTheme.bodySmall)
                : _failed
                    ? Row(
                        children: [
                          Expanded(
                            child: Text(t.iptv.catalogDiagnosticsFailed, style: theme.textTheme.bodySmall),
                          ),
                          TextButton(
                            onPressed: _load,
                            child: Text(t.common.retry),
                          ),
                        ],
                      )
                    : diagnostics == null
                        ? Text(t.iptv.catalogDiagnosticsFailed, style: theme.textTheme.bodySmall)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.iptv.catalogDiagnosticsUnfilteredRows(count: diagnostics.unfilteredSeriesRows),
                                style: theme.textTheme.bodySmall,
                              ),
                              Text(
                                t.iptv.catalogDiagnosticsCategoryCount(count: diagnostics.seriesCategoryCount),
                                style: theme.textTheme.bodySmall,
                              ),
                              for (final entry in diagnostics.perCategorySeriesRows.entries)
                                Text(
                                  t.iptv.catalogDiagnosticsPerCategory(
                                    category: entry.key,
                                    count: entry.value,
                                  ),
                                  style: theme.textTheme.bodySmall,
                                ),
                              Text(
                                t.iptv.catalogDiagnosticsDisabledInitials(
                                  count: diagnostics.disabledInitialsCount,
                                ),
                                style: theme.textTheme.bodySmall,
                              ),
                              Text(
                                t.iptv.catalogDiagnosticsDisabledCategories(
                                  count: diagnostics.disabledCategoriesCount,
                                ),
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
          ),
      ],
    );
  }
}
