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
import '../../services/background_work_diagnostics_service.dart';
import '../../services/iptv/iptv_background_sync.dart';
import '../../services/iptv/iptv_catalog_cache.dart';
import '../../services/iptv/iptv_refusal_log.dart';
import '../../services/iptv/iptv_search_index.dart';
import '../../services/iptv/xtream_api.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../screens/livetv/live_tv_mini_player.dart';
import '../../services/settings_service.dart' as settings;
import '../../utils/formatters.dart';
import '../../utils/media_server_http_client.dart' show AbortController;
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_section.dart';
import 'add_connection_screen.dart';
import 'iptv_categories_screen.dart';
import 'iptv_refusals_screen.dart';
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
/// Things TiviMate has that PlezTV cannot do yet (recording, multi-view,
/// a parental PIN) are deliberately left out; see IPTV_FIXES_NOTES.md.
class IptvSettingsScreen extends StatelessWidget {
  const IptvSettingsScreen({super.key, this.backgroundWorkDiagnosticsService});

  /// Injectable diagnostics service for tests; defaults to the singleton.
  final BackgroundWorkDiagnosticsService? backgroundWorkDiagnosticsService;

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
                // Build #23: the catalog (channels, movies, series) is
                // synced to a local index once and searched locally —
                // how often it re-downloads, plus a manual refresh.
                SettingSelectionTile<int>(
                  pref: settings.SettingsService.iptvCatalogSyncIntervalHours,
                  // Build v1.0.13 (R4): the periodic job follows the
                  // interval — a change re-registers it (update, so the
                  // schedule is preserved); manual-only cancels it.
                  onAfterWrite: (hours) => IptvBackgroundSync.applyInterval(hours),
                  icon: Symbols.schedule_rounded,
                  title: t.iptv.catalogSyncInterval,
                  subtitleBuilder: (hours) => hours == 0
                      ? t.iptv.epgManualOnly
                      : hours == 168
                          ? t.iptv.catalogSyncWeekly
                          : t.iptv.epgHoursCount(n: hours),
                  options: [6, 12, 24, 168, 0]
                      .map(
                        (hours) => DialogOption(
                          value: hours,
                          title: hours == 0
                              ? t.iptv.epgManualOnly
                              : hours == 168
                                  ? t.iptv.catalogSyncWeekly
                                  : t.iptv.epgHoursCount(n: hours),
                        ),
                      )
                      .toList(),
                ),
                SettingNavigationTile(
                  icon: Symbols.sync_rounded,
                  title: t.iptv.catalogSyncNow,
                  subtitle: t.iptv.catalogSyncNowDescription,
                  onTap: () => _syncCatalogNow(context),
                ),
                const _CatalogCacheSizeTile(),
                _BackgroundSyncTile(
                  diagnostics: backgroundWorkDiagnosticsService,
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
            child: ValueListenableBuilder<String>(
              // The User-Agent row's subtitle shows the resolved value, so
              // it must rebuild when the custom text changes too — not
              // just when the choice changes (the selection tile only
              // listens to the choice pref).
              valueListenable: settings.SettingsService.instance.listenable(
                settings.SettingsService.iptvXtreamUserAgentCustom,
              ),
              builder: (_, _, _) => SettingsGroup(
                title: t.iptv.xtreamSection,
                children: [
                  SettingSelectionTile<String>(
                    pref: settings.SettingsService.iptvXtreamUserAgent,
                    icon: Symbols.badge_rounded,
                    title: t.iptv.xtreamUserAgent,
                    subtitleBuilder: _xtreamUserAgentSubtitle,
                    options: [
                      DialogOption(value: XtreamUserAgent.choiceVlc, title: t.iptv.xtreamUserAgentVlc),
                      DialogOption(
                        value: XtreamUserAgent.choiceSmarters,
                        title: t.iptv.xtreamUserAgentSmarters,
                      ),
                      DialogOption(
                        value: XtreamUserAgent.choiceBrowser,
                        title: t.iptv.xtreamUserAgentBrowser,
                      ),
                      DialogOption(value: XtreamUserAgent.choiceCustom, title: t.iptv.xtreamUserAgentCustom),
                    ],
                  ),
                  ValueListenableBuilder<String>(
                    valueListenable: settings.SettingsService.instance.listenable(
                      settings.SettingsService.iptvXtreamUserAgent,
                    ),
                    builder: (_, choice, _) {
                      if (choice != XtreamUserAgent.choiceCustom) return const SizedBox.shrink();
                      return SettingTextTile(
                        pref: settings.SettingsService.iptvXtreamUserAgentCustom,
                        icon: Symbols.edit_rounded,
                        title: t.iptv.xtreamUserAgentCustomTitle,
                        emptyHint: t.iptv.xtreamUserAgentCustomHint,
                        emptyError: t.iptv.xtreamUserAgentCustomEmpty,
                      );
                    },
                  ),
                  // The refusal log is about the Xtream connection, so its
                  // row lives in this section (not its own group — a group
                  // titled "Connection refusals" holding a row titled the
                  // same would say it twice).
                  const _RefusalsTile(),
                ],
              ),
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
        const SliverPadding(padding: EdgeInsets.only(top: 24)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: SettingsGroup(
              title: t.iptv.miniPlayerTitle,
              children: [const _MiniPlayerDiagnosticTile()],
            ),
          ),
        ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }

  /// Subtitle for the Xtream User-Agent row: the UA string that will
  /// actually be sent, so Custom shows the custom text — or "Custom · VLC"
  /// when the custom text is blank, which is the fallback the resolver
  /// applies. Reads the custom pref synchronously; the row rebuilds when
  /// the choice or the custom text changes (see the group wrapper above).
  String _xtreamUserAgentSubtitle(String choice) {
    final custom = settings.SettingsService.instance.read(settings.SettingsService.iptvXtreamUserAgentCustom);
    final resolved = XtreamUserAgent.resolve(choice, custom);
    return choice == XtreamUserAgent.choiceCustom && custom.trim().isEmpty
        ? '${t.iptv.xtreamUserAgentCustom} · $resolved'
        : resolved;
  }

  /// Drop every IPTV client's in-memory catalog so the next Live TV /
  /// Library load re-fetches channels, movies and series from the
  /// provider. A rebind would recreate every server's client (including
  /// Plex/Jellyfin); this only touches IPTV. The EPG cache is busted too
  /// (TiviMate's "update on playlist change": a refreshed playlist gets a
  /// fresh guide with it).
  /// "Sync catalog now" (build #23): a manual refresh of the local
  /// search index — the popup Matt asked for, "refreshing Trex details"
  /// while it loads all the titles for movies, TV (series) and
  /// channels. The dialog shows per-type progress, Cancel stops it
  /// (already-synced types stay), and dismissing it leaves the sync
  /// running in the background.
  Future<void> _syncCatalogNow(BuildContext context) async {
    final registry = context.read<ConnectionRegistry>();
    final multiServer = context.read<MultiServerProvider>();
    final connections = await registry.list();
    final clients = <IptvClient>[];
    for (final connection in connections) {
      if (connection is! XtreamConnection) continue;
      final client = multiServer.getClientForServer(ServerId(connection.id));
      if (client is IptvClient) clients.add(client);
    }
    if (!context.mounted) return;
    if (clients.isEmpty) {
      showSuccessSnackBar(context, t.iptv.noConnections);
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _CatalogSyncDialog(clients: clients),
    );
  }

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

/// "Connection refusals" row (build #27): opens the refusal log. The
/// subtitle is the count (or the empty line); it rebuilds when a refusal
/// lands because it listens to the log's notifier.
class _RefusalsTile extends StatefulWidget {
  const _RefusalsTile();

  @override
  State<_RefusalsTile> createState() => _RefusalsTileState();
}

class _RefusalsTileState extends State<_RefusalsTile> {
  @override
  void initState() {
    super.initState();
    unawaited(IptvRefusalLog.instance.ensureLoaded());
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<IptvRefusalEntry>>(
      valueListenable: IptvRefusalLog.instance.entriesNotifier,
      builder: (context, entries, _) {
        return SettingNavigationTile(
          icon: Symbols.block_rounded,
          title: t.iptv.refusalsTitle,
          subtitle: entries.isEmpty ? t.iptv.refusalsEmpty : t.iptv.refusalsCount(n: entries.length),
          destinationBuilder: (context) => const IptvRefusalsScreen(),
        );
      },
    );
  }
}

/// "Refreshing Trex details" popup (build #23): a manual catalog sync
/// with per-type progress (Live TV / Movies / TV Series) and a Cancel
/// button. The sync runs in the background even if the dialog is
/// dismissed (barrier-dismissible); Cancel aborts between types and
/// already-synced types stay. Done closes it once every type has
/// finished or been skipped.
class _CatalogSyncDialog extends StatefulWidget {
  const _CatalogSyncDialog({required this.clients});

  final List<IptvClient> clients;

  @override
  State<_CatalogSyncDialog> createState() => _CatalogSyncDialogState();
}

class _CatalogSyncDialogState extends State<_CatalogSyncDialog> {
  final _abort = AbortController();
  final _progress = <String, IptvSearchSyncProgress>{};
  bool _done = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    var failed = false;
    for (final client in widget.clients) {
      if (_abort.isAborted) break;
      try {
        final result = await client.syncSearchIndex(
          force: true,
          abort: _abort,
          onProgress: (p) {
            if (!mounted) return;
            setState(() => _progress[p.type] = p);
          },
        );
        // A per-type fetch failure is recorded in the result's skipped
        // map, not thrown — without this the dialog said "Catalog
        // synced" with every row reading "failed" (Matt, 2026-11-11:
        // manual refresh, all three types timed out). `hasFailure`
        // (v1.0.16) is the rule: a skipped type is a failure except
        // 'up-to-date' and 'partial-kept' — a warm-partial refuse keeps
        // the landed rows, so the footer must read Done, not Failed.
        if (result.hasFailure) {
          failed = true;
        }
      } catch (_) {
        // Aborted between types, or a client-level failure: the other
        // types/clients keep their last state; the dialog reports it.
        failed = true;
      }
    }
    if (!mounted) return;
    setState(() {
      _done = true;
      _failed = failed;
    });
  }

  String _typeLabel(String type) => switch (type) {
    IptvSearchIndex.typeLive => t.iptv.catalogSyncLive,
    IptvSearchIndex.typeMovie => t.iptv.catalogSyncMovies,
    _ => t.iptv.catalogSyncSeries,
  };

  String _phaseText(IptvSearchSyncProgress p) {
    if (p.phase == 'done') return p.partial ? '${p.rows} · partial' : '${p.rows}';
    // 'partial-kept' reads as 'partial' on the row (v1.0.16): the type
    // kept its landed rows and the row already read "partial" on a
    // refuse — the distinct reason is for the footer, not the row.
    if (p.phase == 'skipped') return p.reason == 'partial-kept' ? 'partial' : (p.reason ?? '');
    if (p.phase == 'fetching') return '…';
    if (p.phase == 'writing') return '${p.rows}…';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.iptv.catalogSyncTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final type in IptvSearchIndex.types)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_typeLabel(type)),
              trailing: _progress[type] == null
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_phaseText(_progress[type]!), style: theme.textTheme.bodyMedium),
            ),
          if (_done)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _failed ? t.iptv.catalogSyncFailed : t.iptv.catalogSyncDone,
                style: theme.textTheme.bodyMedium,
              ),
            ),
        ],
      ),
      actions: [
        if (!_done)
          TextButton(
            onPressed: () {
              _abort.abort();
              Navigator.of(context).pop();
            },
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
      ],
    );
  }
}

/// "IPTV cache size" status row (build #23): how big the local catalog
/// is — the search index file plus the disk catalogs across all IPTV
/// connections. Not tappable — it is a status, not an action. Rebuilds
/// when the first Xtream client's index state changes (a sync finishing
/// updates the size).
class _CatalogCacheSizeTile extends StatefulWidget {
  const _CatalogCacheSizeTile();

  @override
  State<_CatalogCacheSizeTile> createState() => _CatalogCacheSizeTileState();
}

class _CatalogCacheSizeTileState extends State<_CatalogCacheSizeTile> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final multiServer = context.watch<MultiServerProvider>();
    final clients = [
      for (final id in multiServer.serverIds)
        multiServer.getClientForServer(ServerId(id)),
    ].whereType<IptvClient>().toList();
    final notifier = clients.isNotEmpty ? clients.first.searchIndexStateNotifier : null;
    return ValueListenableBuilder<IptvSearchIndexState>(
      valueListenable: notifier ?? ValueNotifier(const IptvSearchIndexState.empty()),
      builder: (context, state, _) {
        return FutureBuilder<int>(
          future: _totalCacheBytes(clients),
          builder: (context, snapshot) {
            final bytes = snapshot.data ?? 0;
            final size = bytes == 0 ? t.iptv.catalogCacheEmpty : ByteFormatter.formatBytes(bytes);
            final counts = state.totalRows == 0
                ? ''
                : ' · ${state.rowCounts[IptvSearchIndex.typeLive] ?? 0} / '
                    '${state.rowCounts[IptvSearchIndex.typeMovie] ?? 0} / '
                    '${state.rowCounts[IptvSearchIndex.typeSeries] ?? 0}';
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                crossAxisAlignment: .start,
                children: [
                  AppIcon(Symbols.storage_rounded, fill: 1),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: .start,
                      children: [
                        Text(t.iptv.catalogCacheSize, style: theme.textTheme.titleMedium),
                        const SizedBox(height: 2),
                        Text('$size$counts', style: theme.textTheme.bodyMedium),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<int> _totalCacheBytes(List<IptvClient> clients) async {
    var total = await IptvSearchIndex.totalFileSizeBytes();
    const cache = IptvCatalogDiskCache();
    for (final client in clients) {
      total += await cache.sizeBytes(client.connection.id);
    }
    return total;
  }
}

/// "Background sync" status tile (build v1.0.13, R4.3): the last
/// periodic background run — when it ran, what happened — plus the
/// background-work diagnostics verdict when the OS is deferring the
/// job, so a run that never lands explains itself instead of looking
/// broken. Not tappable — it is a status, not an action. Re-reads the
/// last-run record whenever a run writes one (via
/// [IptvBackgroundSync.lastRunVersion]).
class _BackgroundSyncTile extends StatefulWidget {
  const _BackgroundSyncTile({this.diagnostics});

  final BackgroundWorkDiagnosticsService? diagnostics;

  @override
  State<_BackgroundSyncTile> createState() => _BackgroundSyncTileState();
}

class _BackgroundSyncTileState extends State<_BackgroundSyncTile> {
  Map<String, Object?>? _record;
  bool _loaded = false;

  BackgroundWorkDiagnosticsService get _diagnostics =>
      widget.diagnostics ?? BackgroundWorkDiagnosticsService.instance;

  @override
  void initState() {
    super.initState();
    _load();
    IptvBackgroundSync.lastRunVersion.addListener(_load);
  }

  @override
  void dispose() {
    IptvBackgroundSync.lastRunVersion.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final record = await IptvBackgroundSync.readLastRun();
    if (!mounted) return;
    setState(() {
      _record = record;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: _diagnostics,
      builder: (context, _) {
        final status = _diagnostics.status;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            crossAxisAlignment: .start,
            children: [
              AppIcon(Symbols.schedule_rounded, fill: 1),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: .start,
                  children: [
                    Text(t.iptv.backgroundSync, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(_summaryLine(), style: theme.textTheme.bodyMedium),
                    if (_diagnostics.isSupported && status.probed && !status.isHealthy) ...[
                      const SizedBox(height: 2),
                      Text(_verdictLine(status), style: theme.textTheme.bodyMedium),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _summaryLine() {
    final record = _record;
    if (!_loaded) return '';
    if (record == null) return t.iptv.backgroundSyncNever;
    final ranAtMs = record['ranAtMs'] as int?;
    final date = ranAtMs == null
        ? ''
        : DateFormat.MMMd(LocaleSettings.currentLocale.intlLocaleName).add_jm().format(
              DateTime.fromMillisecondsSinceEpoch(ranAtMs),
            );
    final skipped = record['skipped'] as String?;
    final outcome = switch (skipped) {
      'playing' => t.iptv.backgroundSyncSkippedPlaying,
      'already-running' => t.iptv.backgroundSyncSkippedRunning,
      'load-failed' => t.iptv.backgroundSyncSkippedLoad,
      _ => _outcomeSummary(record),
    };
    if (date.isEmpty) return outcome;
    return '${t.iptv.backgroundSyncLastRun(date: date)} \u00b7 $outcome';
  }

  String _outcomeSummary(Map<String, Object?> record) {
    final connections = record['connections'];
    var synced = 0;
    var failed = 0;
    var total = 0;
    if (connections is Map) {
      for (final outcomes in connections.values) {
        if (outcomes is! Map) continue;
        for (final outcome in outcomes.values) {
          total++;
          if (outcome == 'synced' || outcome == 'up-to-date') {
            synced++;
          } else if (outcome == 'failed') {
            failed++;
          }
        }
      }
    }
    if (total == 0) return t.iptv.backgroundSyncNoConnections;
    if (failed == 0 && synced == total) return t.iptv.backgroundSyncAllSynced;
    return t.iptv.backgroundSyncPartial(synced: synced, failed: failed);
  }

  String _verdictLine(BackgroundWorkStatus status) {
    if (status.isBlocked) return t.downloads.backgroundWarning.statusBlocked;
    return t.downloads.backgroundWarning.statusDegraded;
  }
}

/// "Last updated" status lines for the EPG section (1.1.2 D9): the stored
/// timestamp of the last EPG fetch that stored a programme across all IPTV
/// clients ("Last updated", or "Never" before the first load), plus the
/// stored timestamp of the last fetch ATTEMPT ("Last attempt: ...") — an
/// attempt that failed or returned empty still stamps the attempt line,
/// so the two can never be confused again. Not tappable — it is a status,
/// not an action.
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
        // 1.1.2 D9: the attempt line is its own listenable — a fetch that
        // failed or returned empty stamps the attempt without touching
        // "Last updated" above. The full line is one Text widget
        // ("Last attempt: ...") so the bare "Never" finder in the
        // settings test still matches only the data line above.
        return ValueListenableBuilder<String>(
          valueListenable: settings.SettingsService.instance.listenable(
            settings.SettingsService.iptvEpgLastAttempt,
          ),
          builder: (context, attemptStamp, _) {
            final attempted = DateTime.tryParse(attemptStamp);
            final attemptText = attempted == null
                ? t.iptv.epgNeverUpdated
                : '${DateFormat.MMMd(LocaleSettings.currentLocale.intlLocaleName).format(attempted)} · '
                      '${formatClockTime(attempted, is24Hour: MediaQuery.alwaysUse24HourFormatOf(context))}';
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
                        const SizedBox(height: 4),
                        Text(
                          t.iptv.epgLastAttemptLine(stamp: attemptText),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// "Mini-player" diagnostic (build #15): what the last Live TV tune did —
/// which channel, which backend (mpv / ExoPlayer), whether a first frame
/// was ever reported, how the surface was revealed, and whether the native
/// video rect was sent. If the video is black again, this row names the
/// failed step instead of another "still black". Not tappable — a status.
class _MiniPlayerDiagnosticTile extends StatelessWidget {
  const _MiniPlayerDiagnosticTile();

  String _revealLine(LiveTvMiniPlayerDiagnostic diagnostic) {
    final ms = diagnostic.msToReveal;
    return switch (diagnostic.reveal) {
      LiveTvMiniPlayerReveal.event => t.iptv.miniPlayerRevealEvent(ms: ms ?? 0),
      LiveTvMiniPlayerReveal.latch => t.iptv.miniPlayerRevealLatch(ms: ms ?? 0),
      LiveTvMiniPlayerReveal.watchdog => t.iptv.miniPlayerRevealWatchdog(ms: ms ?? 0),
      LiveTvMiniPlayerReveal.none => t.iptv.miniPlayerRevealNone,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diagnostic = LiveTvMiniPlayerController.lastDiagnostic;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(Symbols.live_tv_rounded, fill: 1),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.iptv.miniPlayerTitle, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                if (diagnostic == null)
                  Text(t.iptv.miniPlayerNone, style: theme.textTheme.bodyMedium)
                else ...[
                  Text(
                    t.iptv.miniPlayerChannel(channel: diagnostic.channelName, backend: diagnostic.backend),
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(_revealLine(diagnostic), style: theme.textTheme.bodyMedium),
                  Text(
                    diagnostic.restartObserved ? t.iptv.miniPlayerRestartYes : t.iptv.miniPlayerRestartNo,
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    diagnostic.videoRectSent ? t.iptv.miniPlayerRectYes : t.iptv.miniPlayerRectNo,
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (diagnostic.videoRect != null)
                    Text(
                      t.iptv.miniPlayerRectValues(rect: diagnostic.videoRect!),
                      style: theme.textTheme.bodyMedium,
                    ),
                  if (diagnostic.failReason != null)
                    Text(
                      t.iptv.miniPlayerFailReason(reason: diagnostic.failReason!),
                      style: theme.textTheme.bodyMedium,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The user's IPTV connections, live from the registry. Each row shows the
/// user-given name plus its source label (M3U / Xtream Codes) and how many
/// categories are turned off; tapping one opens the Categories screen for
/// that connection (build #15, item 5).
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
              if (connection is XtreamConnection || connection is M3uConnection)
                _HiddenChannelsTile(connection: connection),
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
    final (ids, initials) = switch (connection) {
      M3uConnection(:final hiddenCategoryIds, :final hiddenCategoryInitials) =>
        (hiddenCategoryIds.length, hiddenCategoryInitials.length),
      XtreamConnection(:final hiddenCategoryIds, :final hiddenCategoryInitials) =>
        (hiddenCategoryIds.length, hiddenCategoryInitials.length),
      _ => (0, 0),
    };
    // Both lists hide categories — the initials hide whole groups at once
    // — so "All categories on" is only true when BOTH are empty.
    final filter = switch ((ids, initials)) {
      (0, 0) => t.iptv.categoriesAllOn,
      (_, 0) => t.iptv.categoriesOff(count: ids),
      (0, _) => t.iptv.groupsOff(count: initials),
      (_, _) => '${t.iptv.categoriesOff(count: ids)} · ${t.iptv.groupsOff(count: initials)}',
    };
    return '$_sourceLabel · $filter';
  }

  @override
  Widget build(BuildContext context) {
    return SettingNavigationTile(
      icon: Symbols.live_tv_rounded,
      title: connection.displayName,
      subtitle: _subtitle(context),
      // Build #15, item 5: the tile opens the ONE Categories screen for
      // this connection. Toggles there apply immediately (persist + swap
      // in place), so there is no result to handle and no rebind.
      onTap: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => IptvCategoriesScreen(connection: connection)));
      },
    );
  }
}

/// Hidden channels for one IPTV connection (build #17, §9): the un-hide
/// path for the guide's long-press "Hide channel". The count loads on
/// first build (a cheap prefs read); channel names resolve from the live
/// lineup only when first expanded (disk-first, no extra network when
/// warm). Each row has an Unhide button, plus an "Unhide all" action. A
/// channel gone from the playlist keeps its raw channel key as its name.
class _HiddenChannelsTile extends StatefulWidget {
  final Connection connection;

  const _HiddenChannelsTile({required this.connection});

  @override
  State<_HiddenChannelsTile> createState() => _HiddenChannelsTileState();
}

class _HiddenChannelsTileState extends State<_HiddenChannelsTile> {
  Set<String> _hiddenKeys = {};
  Map<String, String> _namesByKey = {};
  bool _namesLoaded = false;
  bool _loadingNames = false;

  IptvLiveTvSupport? _boundSupport() {
    try {
      final client = context.read<MultiServerProvider>().getClientForServer(ServerId(widget.connection.id));
      if (client is! IptvClient) return null;
      final support = client.liveTv;
      return support is IptvLiveTvSupport ? support : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadKeys());
  }

  Future<void> _loadKeys() async {
    final support = _boundSupport();
    if (support == null) return;
    final keys = await support.loadHiddenChannels();
    if (!mounted) return;
    setState(() => _hiddenKeys = keys);
  }

  Future<void> _loadNames() async {
    if (_namesLoaded || _loadingNames) return;
    setState(() => _loadingNames = true);
    try {
      final client = context.read<MultiServerProvider>().getClientForServer(ServerId(widget.connection.id));
      if (client is IptvClient) {
        final channels = await client.iptvChannels();
        if (!mounted) return;
        setState(() {
          _namesByKey = {for (final c in channels) c.key: c.title ?? c.key};
          _namesLoaded = true;
        });
      }
    } finally {
      if (mounted) setState(() => _loadingNames = false);
    }
  }

  String _channelKey(String stored) => stored.split('\u0000').last;

  String _nameFor(String stored) => _namesByKey[_channelKey(stored)] ?? _channelKey(stored);

  Future<void> _unhide(String stored) async {
    final support = _boundSupport();
    if (support == null) return;
    await support.unhideChannelKey(_channelKey(stored));
    if (!mounted) return;
    setState(() => _hiddenKeys = _hiddenKeys.where((k) => k != stored).toSet());
  }

  Future<void> _unhideAll() async {
    final support = _boundSupport();
    if (support == null) return;
    await support.unhideAllChannels();
    if (!mounted) return;
    setState(() => _hiddenKeys = {});
  }

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Symbols.visibility_off_rounded),
      title: Text(t.iptv.hiddenChannelsTitle),
      subtitle: Text(
        _hiddenKeys.isEmpty
            ? t.iptv.hiddenChannelsNone
            : t.iptv.hiddenChannelsCount(count: _hiddenKeys.length),
      ),
      onExpansionChanged: (expanded) {
        if (expanded) unawaited(_loadNames());
      },
      children: [
        if (_loadingNames)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
        else
          for (final stored in _hiddenKeys)
            ListTile(
              title: Text(_nameFor(stored)),
              trailing: TextButton(
                onPressed: () => unawaited(_unhide(stored)),
                child: Text(t.liveTv.unhide),
              ),
            ),
        if (_hiddenKeys.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: .centerRight,
              child: TextButton(
                onPressed: () => unawaited(_unhideAll()),
                child: Text(t.iptv.unhideAll),
              ),
            ),
          ),
      ],
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

  /// The BOUND client (the one that ran the searches), resolved without
  /// awaiting anything — the "Last search" readout is an in-memory getter
  /// on it, so it renders synchronously (build #14, UI-2). It used to be
  /// set in [_load] next to the series probe, which meant the row only
  /// appeared after the probe finished — up to ~40s on a slow panel, never
  /// if the probe failed (and then it wrongly read "No search yet").
  IptvClient? _boundClient() {
    try {
      final bound = context.read<MultiServerProvider>().getClientForServer(ServerId(widget.connection.id));
      if (bound is IptvClient) return bound;
    } catch (_) {
      // No provider above us, or the connection is not bound: a fresh
      // client has no last-search record, so the row reads "no search yet".
    }
    return null;
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    // The probe runs on the BOUND client (the one that ran the searches),
    // not a fresh one — resolve it, falling back to a fresh client when
    // the connection isn't bound.
    IptvClient? liveClient;
    try {
      final bound = context.read<MultiServerProvider>().getClientForServer(ServerId(widget.connection.id));
      if (bound is IptvClient) liveClient = bound;
    } catch (_) {
      liveClient = null;
    }
    final client = liveClient ?? IptvClient.forConnection(widget.connection);
    try {
      final diagnostics = await client.seriesCatalogDiagnostics();
      if (!mounted) return;
      setState(() {
        _diagnostics = diagnostics;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    } finally {
      // Only close a client we created; the bound one belongs to the manager.
      if (liveClient == null) client.close();
      if (mounted) setState(() => _loading = false);
    }
  }

  /// One section line of the last-search readout.
  String _lastSearchSectionLine(String section, IptvSearchSectionDiagnostics s) {
    if (s.skipped) return t.iptv.lastSearchSectionSkipped(section: section);
    if (s.loadRows < 0) {
      return t.iptv.lastSearchSectionLoadNeverLanded(
        section: section,
        returned: s.returned,
        sweep: s.sweepMatches,
        partial: s.partialMatches,
        hidden: s.hiddenMatches,
        ms: s.ms,
      );
    }
    return t.iptv.lastSearchSection(
      section: section,
      returned: s.returned,
      loadRows: s.loadRows,
      loadMs: s.loadMs,
      source: s.loadSource.isEmpty ? '?' : s.loadSource,
      sweep: s.sweepMatches,
      partial: s.partialMatches,
      hidden: s.hiddenMatches,
      ms: s.ms,
    );
  }

  /// The "Last search" readout, rendered synchronously from the bound
  /// client's in-memory getter — never gated on the series probe (UI-2).
  /// Lives above the probe section so it is visible the moment the row is
  /// expanded, even while the probe is still spinning.
  Widget _buildLastSearch(ThemeData theme) {
    final lastSearch = _boundClient()?.lastSearchDiagnostics;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.iptv.lastSearchTitle, style: theme.textTheme.titleSmall),
        if (lastSearch == null)
          Text(t.iptv.lastSearchNone, style: theme.textTheme.bodySmall)
        else ...[
          Text(
            t.iptv.lastSearchQuery(
              query: lastSearch.query,
              totalMs: lastSearch.totalMs,
              scoped: lastSearch.scoped ? t.iptv.lastSearchScopedSuffix : '',
            ),
            style: theme.textTheme.bodySmall,
          ),
          Text(
            _lastSearchSectionLine('Movies', lastSearch.movies),
            style: theme.textTheme.bodySmall,
          ),
          Text(
            _lastSearchSectionLine('Series', lastSearch.series),
            style: theme.textTheme.bodySmall,
          ),
          Text(
            _lastSearchSectionLine('Live TV', lastSearch.live),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  /// The "Guide coverage" readout (build #17, §10), rendered
  /// synchronously from the bound client's in-memory EPG cache — the
  /// guide only fetches visible rows, so the cached set IS the visible
  /// guide. Shows the share of loaded channels with programmes, the
  /// split by source (feed by tvg-id / feed by name / short guide /
  /// none), and the feed's distinct channel-id count.
  Widget _buildGuideCoverage(ThemeData theme) {
    final client = _boundClient();
    final support = client?.liveTv;
    final coverage = support is IptvLiveTvSupport ? support.guideCoverage() : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.iptv.guideCoverageTitle, style: theme.textTheme.titleSmall),
        if (coverage == null || coverage.total == 0)
          Text(t.iptv.guideCoverageNone, style: theme.textTheme.bodySmall)
        else ...[
          Text(
            t.iptv.guideCoverageLine(
              percent: coverage.percentWithPrograms,
              withPrograms: coverage.withPrograms,
              total: coverage.total,
            ),
            style: theme.textTheme.bodySmall,
          ),
          Text(
            t.iptv.guideCoverageSplit(
              byId: coverage.fromFeedById,
              byName: coverage.fromFeedByName,
              shortEpg: coverage.fromShortEpg,
              none: coverage.none,
            ),
            style: theme.textTheme.bodySmall,
          ),
          if (coverage.unknown > 0)
            Text(t.iptv.guideCoverageUnknown(count: coverage.unknown), style: theme.textTheme.bodySmall),
          if (coverage.feedChannelIds > 0)
            Text(t.iptv.guideCoverageFeedIds(count: coverage.feedChannelIds), style: theme.textTheme.bodySmall),
        ],
      ],
    );
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildLastSearch(theme),
                const SizedBox(height: 8),
                _buildGuideCoverage(theme),
                const SizedBox(height: 8),
                _loading
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
                                      count: diagnostics.hiddenCategoryInitialsCount,
                                    ),
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  Text(
                                    t.iptv.catalogDiagnosticsDisabledCategories(
                                      count: diagnostics.hiddenCategoriesCount,
                                    ),
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
              ],
            ),
          ),
      ],
    );
  }
}
