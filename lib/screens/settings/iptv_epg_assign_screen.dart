import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/iptv_live_tv.dart';
import '../../services/iptv/iptv_epg_sources.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';

/// Assign EPG (§3.2, TiviMate's Assign EPG): search the LOCAL feed
/// indexes (the feeds already loaded — no network on typing) and pick
/// an entry for the channel. The mapping survives refreshes and catalog
/// syncs. A channel with an existing assignment shows it at the top
/// with a Clear action.
class IptvEpgAssignScreen extends StatefulWidget {
  final IptvLiveTvSupport support;
  final String channelKey;
  final String channelName;

  const IptvEpgAssignScreen({
    super.key,
    required this.support,
    required this.channelKey,
    required this.channelName,
  });

  @override
  State<IptvEpgAssignScreen> createState() => _IptvEpgAssignScreenState();
}

class _IptvEpgAssignScreenState extends State<IptvEpgAssignScreen> {
  final _searchController = TextEditingController();
  List<IptvEpgFeedChannel>? _entries;
  IptvEpgMapping? _current;
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (mounted) setState(() => _query = _searchController.text);
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final entries = await widget.support.epgFeedChannels();
    final current = await widget.support.epgAssignmentFor(widget.channelKey);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _current = current;
      _loading = false;
    });
  }

  List<IptvEpgFeedChannel> get _filtered {
    final entries = _entries ?? const <IptvEpgFeedChannel>[];
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return entries;
    return entries.where((e) => e.xmltvId.toLowerCase().contains(query)).toList(growable: false);
  }

  Future<void> _assign(IptvEpgFeedChannel entry) async {
    await widget.support.assignEpg(
      widget.channelKey,
      xmltvId: entry.xmltvId,
      sourceId: entry.sourceId,
    );
    if (!mounted) return;
    showSuccessSnackBar(context, t.iptv.epgAssigned);
    Navigator.of(context).pop(true);
  }

  Future<void> _clear() async {
    await widget.support.clearEpgAssignment(widget.channelKey);
    if (!mounted) return;
    showSuccessSnackBar(context, t.iptv.epgAssignmentCleared);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _filtered;
    return FocusedScrollScaffold(
      title: Text('${t.iptv.epgAssignTitle} · ${widget.channelName}'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: t.iptv.epgAssignSearchHint,
                prefixIcon: const AppIcon(Symbols.search_rounded),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ),
        if (_current != null)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverToBoxAdapter(
              child: ListTile(
                leading: const AppIcon(Symbols.check_circle_rounded, fill: 1),
                title: Text(_current!.xmltvId),
                subtitle: Text(t.iptv.epgMatchMethodManual),
                trailing: TextButton(
                  onPressed: () => unawaited(_clear()),
                  child: Text(t.iptv.epgClearAssignment),
                ),
              ),
            ),
          ),
        if (_loading)
          const SliverPadding(
            padding: EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(child: Center(child: CircularProgressIndicator())),
          )
        else if (entries.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Text(t.iptv.epgAssignEmpty, style: theme.textTheme.bodyMedium),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile(
                  leading: const AppIcon(Symbols.live_tv_rounded),
                  title: Text(entry.xmltvId),
                  subtitle: Text(
                    '${entry.sourceName} · ${t.iptv.epgDetailsProgramsCount(n: entry.programCount)}',
                  ),
                  onTap: () => unawaited(_assign(entry)),
                );
              },
            ),
          ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }
}
