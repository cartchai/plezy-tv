import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/iptv_client.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/settings_service.dart' as settings;
import '../../utils/snackbar_helper.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_section.dart';
import 'add_connection_screen.dart';
import 'edit_iptv_connection_screen.dart';
import 'playback_settings_screen.dart';

/// IPTV settings area (Settings → IPTV), modelled on TiviMate's Settings.
///
/// One screen for everything IPTV: the connections (M3U + Xtream Codes),
/// per-connection channel-group enable/disable, playlist refresh, the
/// guide/catch-up badge, and a link to the player settings IPTV uses.
/// Every row here is wired to real behaviour — nothing is a dead toggle.
/// Things TiviMate has that Plezy TV cannot do yet (EPG data itself,
/// recording, multi-view, a parental PIN) are deliberately left out; see
/// IPTV_FIXES_NOTES.md.
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
  /// Plex/Jellyfin); this only touches IPTV.
  Future<void> _refreshPlaylists(BuildContext context) async {
    final registry = context.read<ConnectionRegistry>();
    final multiServer = context.read<MultiServerProvider>();
    final connections = await registry.list();
    for (final connection in connections) {
      if (connection is! M3uConnection && connection is! XtreamConnection) continue;
      final client = multiServer.getClientForServer(ServerId(connection.id));
      if (client is IptvClient) client.clearCatalogCache();
    }
    if (!context.mounted) return;
    showSuccessSnackBar(context, t.iptv.refreshDone);
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
          children: [for (final connection in connections) _IptvConnectionTile(connection: connection)],
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
