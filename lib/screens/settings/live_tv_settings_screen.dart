import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../providers/multi_server_provider.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/settings_section.dart';

/// Settings → Live TV (build #15, item 1): one switch per live-TV server.
/// Turning a server off hides its channels from the guide, search, What's
/// On and the mini-player — the server's libraries are untouched. On by
/// default; hiding the last live-TV server hides the Live TV tab itself.
class LiveTvSettingsScreen extends StatelessWidget {
  const LiveTvSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(t.liveTv.title),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Text(t.liveTv.settingsHint, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverToBoxAdapter(
            child: Consumer<MultiServerProvider>(
              builder: (context, multiServer, _) {
                final serverIds = multiServer.liveTvServerIds;
                if (serverIds.isEmpty) {
                  return SettingsGroup(
                    title: t.liveTv.title,
                    children: [
                      ListTile(
                        leading: const AppIcon(Symbols.live_tv_rounded, fill: 1),
                        title: Text(t.liveTv.settingsEmpty),
                        subtitle: Text(t.liveTv.settingsEmptyHint),
                      ),
                    ],
                  );
                }
                return SettingsGroup(
                  title: t.liveTv.title,
                  children: [
                    for (final serverId in serverIds)
                      FocusableSwitchListTile(
                        secondary: const AppIcon(Symbols.live_tv_rounded, fill: 1),
                        title: Text(t.liveTv.fromServer(server: multiServer.liveTvServerName(serverId))),
                        value: !multiServer.isLiveTvServerHidden(serverId),
                        onChanged: (value) => multiServer.setLiveTvServerHidden(serverId, !value),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
