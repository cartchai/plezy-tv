import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/iptv_live_tv.dart';
import '../../services/iptv/iptv_epg_sources.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import 'iptv_epg_assign_screen.dart';

/// Channels without guide (§3.2, the "see my assigned EPGs per channel"
/// overview): every channel with no EPG, grouped by reason, each row
/// with an Assign action. The reason groups read in the order a fix is
/// most actionable — no source at all, no match, a failed source, not
/// loaded yet.
class IptvEpgNoGuideScreen extends StatefulWidget {
  final IptvLiveTvSupport support;

  const IptvEpgNoGuideScreen({super.key, required this.support});

  @override
  State<IptvEpgNoGuideScreen> createState() => _IptvEpgNoGuideScreenState();
}

class _IptvEpgNoGuideScreenState extends State<IptvEpgNoGuideScreen> {
  List<IptvChannelWithoutGuide>? _channels;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final channels = await widget.support.channelsWithoutGuide();
    if (!mounted) return;
    setState(() {
      _channels = channels;
      _loading = false;
    });
  }

  String _reasonLabel(IptvEpgNoGuideReason reason) {
    return switch (reason) {
      IptvEpgNoGuideReason.noSource => t.iptv.epgNoGuideReasonNoSource,
      IptvEpgNoGuideReason.noMatch => t.iptv.epgNoGuideReasonNoMatch,
      IptvEpgNoGuideReason.sourceFailed => t.iptv.epgNoGuideReasonSourceFailed,
      IptvEpgNoGuideReason.notLoaded => t.iptv.epgNoGuideReasonNotLoaded,
      IptvEpgNoGuideReason.ambiguous => t.iptv.epgNoGuideReasonAmbiguous,
      IptvEpgNoGuideReason.foreign => t.iptv.epgNoGuideReasonForeign,
      IptvEpgNoGuideReason.matchedButNoPrograms => t.iptv.epgNoGuideReasonMatchedButNoPrograms,
    };
  }

  static const _reasonOrder = [
    IptvEpgNoGuideReason.noSource,
    IptvEpgNoGuideReason.ambiguous,
    IptvEpgNoGuideReason.foreign,
    IptvEpgNoGuideReason.matchedButNoPrograms,
    IptvEpgNoGuideReason.noMatch,
    IptvEpgNoGuideReason.sourceFailed,
    IptvEpgNoGuideReason.notLoaded,
  ];

  Future<void> _assign(IptvChannelWithoutGuide channel) async {
    final assigned = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => IptvEpgAssignScreen(
          support: widget.support,
          channelKey: channel.channelKey,
          channelName: channel.channelName,
        ),
      ),
    );
    if (assigned == true && mounted) {
      setState(() => _loading = true);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channels = _channels ?? const <IptvChannelWithoutGuide>[];
    final grouped = <IptvEpgNoGuideReason, List<IptvChannelWithoutGuide>>{};
    for (final channel in channels) {
      grouped.putIfAbsent(channel.reason, () => []).add(channel);
    }
    return FocusedScrollScaffold(
      title: Text(t.iptv.epgNoGuideTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Text(t.iptv.epgNoGuideDescription, style: theme.textTheme.bodyMedium),
          ),
        ),
        if (_loading)
          const SliverPadding(
            padding: EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(child: Center(child: CircularProgressIndicator())),
          )
        else if (channels.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Text(t.iptv.epgNoGuideEmpty, style: theme.textTheme.bodyMedium),
            ),
          )
        else
          for (final reason in _reasonOrder)
            if (grouped[reason] != null) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                sliver: SliverToBoxAdapter(
                  child: Text(_reasonLabel(reason), style: theme.textTheme.titleSmall),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: grouped[reason]!.length,
                  itemBuilder: (context, index) {
                    final channel = grouped[reason]![index];
                    return ListTile(
                      leading: const AppIcon(Symbols.live_tv_rounded),
                      title: Text(channel.channelName),
                      subtitle: channel.candidates.isEmpty
                          ? null
                          : Text(
                              t.iptv.epgNoGuideCandidates(candidates: channel.candidates.take(3).join(', ')),
                            ),
                      trailing: TextButton(
                        onPressed: () => unawaited(_assign(channel)),
                        child: Text(t.iptv.epgAssignTitle),
                      ),
                    );
                  },
                ),
              ),
            ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }
}
