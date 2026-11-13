import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/app_locale_utils.dart';
import '../../i18n/strings.g.dart';
import '../../media/iptv_live_tv.dart';
import '../../models/livetv_channel.dart';
import '../../services/iptv/iptv_epg_sources.dart';
import '../../utils/formatters.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../settings/iptv_epg_assign_screen.dart';

/// One channel's EPG details (§3.2, the "see my assigned EPG" view):
/// which source serves it, which XMLTV id matched and how, programmes
/// in the window, when it was fetched and when it expires — or, when
/// it has nothing, why. Opened from the guide's long-press menu.
Future<void> showEpgChannelDetailSheet(
  BuildContext context, {
  required IptvLiveTvSupport support,
  required LiveTvChannel channel,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _EpgChannelDetailSheet(support: support, channel: channel),
  );
}

class _EpgChannelDetailSheet extends StatefulWidget {
  final IptvLiveTvSupport support;
  final LiveTvChannel channel;

  const _EpgChannelDetailSheet({required this.support, required this.channel});

  @override
  State<_EpgChannelDetailSheet> createState() => _EpgChannelDetailSheetState();
}

class _EpgChannelDetailSheetState extends State<_EpgChannelDetailSheet> {
  IptvChannelEpgDetail? _detail;
  IptvEpgMapping? _assignment;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final detail = await widget.support.channelEpgDetail(widget.channel.key);
    final assignment = await widget.support.epgAssignmentFor(widget.channel.key);
    if (!mounted) return;
    setState(() {
      _detail = detail;
      _assignment = assignment;
      _loading = false;
    });
  }

  String _formatTime(DateTime time) =>
      '${DateFormat.MMMd(LocaleSettings.currentLocale.intlLocaleName).format(time.toLocal())} · '
      '${formatClockTime(time.toLocal(), is24Hour: MediaQuery.alwaysUse24HourFormatOf(context))}';

  String _matchMethodLabel(String? method) {
    return switch (method) {
      'tvg-id' => t.iptv.epgMatchMethodTvgId,
      'name' => t.iptv.epgMatchMethodName,
      'manual' => t.iptv.epgMatchMethodManual,
      _ => '—',
    };
  }

  String _reasonLabel(IptvEpgNoGuideReason reason) {
    return switch (reason) {
      IptvEpgNoGuideReason.noSource => t.iptv.epgNoGuideReasonNoSource,
      IptvEpgNoGuideReason.noMatch => t.iptv.epgNoGuideReasonNoMatch,
      IptvEpgNoGuideReason.sourceFailed => t.iptv.epgNoGuideReasonSourceFailed,
      IptvEpgNoGuideReason.notLoaded => t.iptv.epgNoGuideReasonNotLoaded,
    };
  }

  Future<void> _assign() async {
    final assigned = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => IptvEpgAssignScreen(
          support: widget.support,
          channelKey: widget.channel.key,
          channelName: widget.channel.title ?? widget.channel.key,
        ),
      ),
    );
    if (assigned == true && mounted) {
      setState(() => _loading = true);
      await _load();
    }
  }

  Future<void> _clear() async {
    await widget.support.clearEpgAssignment(widget.channel.key);
    if (!mounted) return;
    showSuccessSnackBar(context, t.iptv.epgAssignmentCleared);
    setState(() => _loading = true);
    await _load();
  }

  Future<void> _refresh() async {
    final now = DateTime.now();
    await widget.support.fetchEpgForChannel(
      widget.channel.key,
      from: now,
      to: now.add(const Duration(hours: 6)),
      force: true,
    );
    if (!mounted) return;
    setState(() => _loading = true);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.channel.title ?? widget.channel.key, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(t.iptv.epgDetailsTitle, style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (detail != null) ...[
              _Row(label: t.iptv.epgDetailsSource, value: detail.sourceName ?? '—'),
              _Row(label: t.iptv.epgDetailsMatchedId, value: detail.matchedXmltvId ?? '—'),
              _Row(label: t.iptv.epgDetailsMatchMethod, value: _matchMethodLabel(detail.matchMethod)),
              _Row(
                label: t.iptv.epgDetailsPrograms,
                value: t.iptv.epgDetailsProgramsCount(n: detail.programCount),
              ),
              if (detail.lastFetch != null)
                _Row(label: t.iptv.epgDetailsLastFetch, value: _formatTime(detail.lastFetch!)),
              if (detail.nextFetch != null)
                _Row(label: t.iptv.epgDetailsNextFetch, value: _formatTime(detail.nextFetch!)),
              if (!detail.hasGuide && detail.noGuideReason != null)
                _Row(label: t.iptv.epgDetailsWhyNoMatch, value: _reasonLabel(detail.noGuideReason!)),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _loading ? null : () => unawaited(_assign()),
                  icon: const AppIcon(Symbols.edit_rounded),
                  label: Text(t.iptv.epgAssignTitle),
                ),
                const SizedBox(width: 8),
                if (_assignment != null)
                  OutlinedButton(
                    onPressed: _loading ? null : () => unawaited(_clear()),
                    child: Text(t.iptv.epgClearAssignment),
                  ),
                const Spacer(),
                IconButton(
                  icon: const AppIcon(Symbols.refresh_rounded),
                  tooltip: t.iptv.epgDetailsRefresh,
                  onPressed: _loading ? null : () => unawaited(_refresh()),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: '$label: ', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
            TextSpan(text: value, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
