import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../i18n/app_locale_utils.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/iptv_client.dart';
import '../../media/iptv_live_tv.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/iptv/iptv_epg_sources.dart';
import '../../services/settings_service.dart';
import '../../utils/formatters.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_section.dart';
import 'iptv_epg_no_guide_screen.dart';

/// EPG sources for one IPTV connection (PlezTV 1.2.0, §3.1/§3.2): the
/// provider guide first (unremovable, never disabled or moved), then
/// added XMLTV sources in priority order — each with a status chip, an
/// enable switch, a per-source time shift, reorder and delete — plus the
/// "added sources take precedence" toggle, Reload TV details, and the
/// Channels without guide overview. Adding a source validates the URL
/// first (fetch the first bytes, confirm XMLTV); a failure shows the
/// reason instead of a silent add.
class IptvEpgSourcesScreen extends StatefulWidget {
  final Connection connection;

  const IptvEpgSourcesScreen({super.key, required this.connection});

  @override
  State<IptvEpgSourcesScreen> createState() => _IptvEpgSourcesScreenState();
}

class _IptvEpgSourcesScreenState extends State<IptvEpgSourcesScreen> {
  List<IptvEpgSourceConfig> _sources = [];
  Map<String, IptvEpgSourceStatus> _statuses = {};
  bool _addedFirst = false;
  bool _loading = true;
  // 1.2.3: true while a Reload is running — the Reload row shows a
  // spinner instead of looking dead while the list + feeds load.
  bool _reloading = false;
  int _updateIntervalHours = 24;

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
    unawaited(_load());
  }

  Future<void> _load() async {
    final support = _boundSupport();
    if (support == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final settings = await SettingsService.getInstance();
    final sources = await support.epgSources();
    final statuses = await support.epgSourceStatuses();
    final addedFirst = await support.addedSourcesTakePrecedence();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _statuses = statuses;
      _addedFirst = addedFirst;
      _updateIntervalHours = settings.read(SettingsService.iptvEpgUpdateIntervalHours);
      _loading = false;
    });
  }

  Duration? get _ttl => _updateIntervalHours <= 0 ? null : Duration(hours: _updateIntervalHours);

  String _statusLabel(IptvEpgSourceStatus status, bool enabled) {
    return switch (status.state(enabled: enabled, ttl: _ttl)) {
      IptvEpgSourceState.upToDate => t.iptv.epgSourceStatusUpToDate,
      IptvEpgSourceState.needsRefresh => t.iptv.epgSourceStatusNeedsRefresh,
      IptvEpgSourceState.failed => t.iptv.epgSourceStatusFailed,
      IptvEpgSourceState.disabled => t.iptv.epgSourceStatusDisabled,
    };
  }

  Color _statusColor(IptvEpgSourceState state, ThemeData theme) {
    return switch (state) {
      IptvEpgSourceState.upToDate => Colors.green,
      IptvEpgSourceState.needsRefresh => Colors.amber.shade700,
      IptvEpgSourceState.failed => theme.colorScheme.error,
      IptvEpgSourceState.disabled => theme.disabledColor,
    };
  }

  String _formatTime(DateTime time) =>
      '${DateFormat.MMMd(LocaleSettings.currentLocale.intlLocaleName).format(time.toLocal())} · '
      '${formatClockTime(time.toLocal(), is24Hour: MediaQuery.alwaysUse24HourFormatOf(context))}';

  String? _statusDetail(IptvEpgSourceConfig source, IptvEpgSourceStatus status) {
    final lines = <String>[];
    if (status.lastSuccess != null || status.programs > 0) {
      lines.add(t.iptv.epgSourceStatusDetail(programs: status.programs, channels: status.channels));
    }
    if (status.lastSuccess != null) lines.add(_formatTime(status.lastSuccess!));
    if (status.lastFailure != null && status.lastFailureReason != null) {
      lines.add('${_formatTime(status.lastFailure!)} · ${status.lastFailureReason}');
    }
    if (lines.isEmpty) return t.iptv.epgSourceStatusNeverFetched;
    return lines.join('\n');
  }

  Future<void> _setPrecedence(bool value) async {
    final support = _boundSupport();
    if (support == null) return;
    await support.setAddedSourcesTakePrecedence(value);
    if (!mounted) return;
    setState(() => _addedFirst = value);
  }

  Future<void> _toggleEnabled(IptvEpgSourceConfig source, bool enabled) async {
    final support = _boundSupport();
    if (support == null) return;
    await support.updateEpgSource(source.copyWith(enabled: enabled));
    await _load();
  }

  Future<void> _pickShift(IptvEpgSourceConfig source) async {
    final options = <int?>[null, -120, -60, -30, 30, 60, 120];
    // A null pick means "No offset" AND a dismissed dialog — tell them
    // apart with an explicit flag, so dismissing never clears the shift.
    var chose = false;
    int? picked;
    await showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(t.iptv.epgTimeShift),
        children: [
          for (final minutes in options)
            SimpleDialogOption(
              onPressed: () {
                chose = true;
                picked = minutes;
                Navigator.of(context).pop();
              },
              child: Text(
                minutes == null ? t.iptv.epgNoOffset : t.iptv.epgOffsetMinutes(n: minutes),
              ),
            ),
        ],
      ),
    );
    if (!chose) return;
    final support = _boundSupport();
    if (support == null) return;
    await support.updateEpgSource(source.copyWith(timeShiftMinutes: picked, clearTimeShift: picked == null));
    await _load();
  }

  Future<void> _move(IptvEpgSourceConfig source, int delta) async {
    final support = _boundSupport();
    if (support == null) return;
    await support.moveEpgSource(source.id, delta);
    await _load();
  }

  Future<void> _delete(IptvEpgSourceConfig source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.iptv.epgSourceDelete),
        content: Text(t.iptv.epgSourceDeleteConfirm(name: source.name)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.cancel)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.common.delete)),
        ],
      ),
    );
    if (confirmed != true) return;
    final support = _boundSupport();
    if (support == null) return;
    await support.deleteEpgSource(source.id);
    if (!mounted) return;
    showSuccessSnackBar(context, t.iptv.epgSourceDeleted);
    await _load();
  }

  Future<void> _addSource() async {
    final urlController = TextEditingController();
    final nameController = TextEditingController();
    int? shiftMinutes;
    String? error;
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(t.iptv.epgAddSourceTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: t.iptv.epgAddSourceUrlLabel,
                  hintText: t.iptv.epgAddSourceUrlHint,
                ),
                keyboardType: TextInputType.url,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: t.iptv.epgAddSourceNameLabel,
                  hintText: t.iptv.epgAddSourceNameHint,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                initialValue: shiftMinutes,
                decoration: InputDecoration(labelText: t.iptv.epgTimeShift),
                items: [
                  DropdownMenuItem<int?>(value: null, child: Text(t.iptv.epgNoOffset)),
                  for (final minutes in [-120, -60, -30, 30, 60, 120])
                    DropdownMenuItem<int?>(
                      value: minutes,
                      child: Text(t.iptv.epgOffsetMinutes(n: minutes)),
                    ),
                ],
                onChanged: (value) => setDialogState(() => shiftMinutes = value),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.cancel)),
            TextButton(
              onPressed: () async {
                final support = _boundSupport();
                if (support == null) return;
                try {
                  await support.addEpgSource(
                    urlController.text,
                    name: nameController.text,
                    timeShiftMinutes: shiftMinutes,
                  );
                  if (context.mounted) Navigator.of(context).pop(true);
                } on StateError catch (e) {
                  // Validation failed: show the reason in the dialog, not
                  // a silent add (research §3.1).
                  setDialogState(() => error = e.message);
                }
              },
              child: Text(t.iptv.epgAddSource),
            ),
          ],
        ),
      ),
    );
    urlController.dispose();
    nameController.dispose();
    if (added == true && mounted) {
      showSuccessSnackBar(context, t.iptv.epgSourceAdded);
      await _load();
    }
  }

  Future<void> _reloadTvDetails() async {
    final support = _boundSupport();
    if (support == null || _reloading) return;
    setState(() => _reloading = true);
    IptvReloadTvDetailsResult result;
    try {
      result = await support.reloadTvDetails();
    } catch (e) {
      // 1.2.3 RC1: reloadTvDetails never throws by contract — but a
      // throw must never escape the tap handler either (belt and
      // braces): build the failure into a report dialog so the tap
      // still ends in a report, never in silence.
      if (!mounted) return;
      setState(() => _reloading = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.iptv.epgReloadTvDetails),
          content: Text(t.iptv.epgReloadUnexpectedFailure(reason: epgFeedErrorReason(e))),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.ok))],
        ),
      );
      if (mounted) await _load();
      return;
    }
    if (!mounted) return;
    // Clear the spinner BEFORE the report appears (1.2.3: the
    // indicator shows while the reload runs and clears when the report
    // appears — it must not keep spinning behind the dialog).
    setState(() => _reloading = false);
    final lines = <String>[];
    if (result.channelListFailureKind != null) {
      lines.add(
        t.iptv.epgReloadChannelListFailed(
          reason: switch (result.channelListFailureKind!) {
            IptvEpgFeedOutcomeKind.denied => t.iptv.epgFeedDeniedReason,
            IptvEpgFeedOutcomeKind.notAnswering => t.iptv.epgFeedNotAnsweringReason,
            _ => result.channelListFailureReason ?? '',
          },
        ),
      );
    }
    for (final outcome in result.feedOutcomes) {
      lines.add(epgFeedOutcomeLine(outcome, result.channelsLoaded));
    }
    // 1.2.5 Fix 1: the diagnostics block — how channels matched, why
    // the rest did not, what the feed actually contains, and a sample
    // of each side. Only when a channel list was re-fetched (a Reload
    // whose list failed has no match counts to report).
    if (result.channelListFailureKind == null) {
      final tiers = result.matchTiers;
      lines.add(
        t.iptv.epgReloadMatchBreakdown(
          manual: tiers.manual,
          tvgId: tiers.tvgId,
          name: tiers.name,
          loose: tiers.nameLoose,
        ),
      );
      if (tiers.unmatched > 0) {
        lines.add(
          t.iptv.epgReloadUnmatchedBreakdown(
            ambiguous: tiers.ambiguous,
            foreign: tiers.foreign,
            noTvgId: tiers.noTvgId,
            tvgIdNotInFeed: tiers.tvgIdNotInFeed,
            matchedButNoProgrammes: tiers.matchedButNoProgrammes,
          ),
        );
      }
      for (final outcome in result.feedOutcomes) {
        if (outcome.feedProgramsParsed == null) continue;
        lines.add(
          t.iptv.epgReloadFeedStats(
            source: outcome.sourceName,
            channels: outcome.feedChannelsParsed ?? 0,
            parsed: outcome.feedProgramsParsed ?? 0,
            retained: outcome.feedProgramsRetained ?? 0,
          ),
        );
      }
      if (result.feedSamples.isNotEmpty) {
        lines.add(
          t.iptv.epgReloadFeedSample(
            samples: result.feedSamples
                .map((e) => e.displayNames.isEmpty ? e.xmltvId : '${e.xmltvId} (${e.displayNames.join(', ')})')
                .join(', '),
          ),
        );
      }
      if (result.sampleUnmatched.isNotEmpty) {
        lines.add(
          t.iptv.epgReloadUnmatchedSample(samples: result.sampleUnmatched.map((e) => e.channelName).join(', ')),
        );
      }
      if (result.epgChannelIdCount != null) {
        lines.add(
          t.iptv.epgReloadEpgChannelIds(withId: result.epgChannelIdCount!, total: result.channelsLoaded),
        );
      }
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.iptv.epgReloadTvDetails),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.iptv.epgReloadTvDetailsResult(
                channels: result.channelsLoaded,
                withGuide: result.withGuide,
                withoutGuide: result.withoutGuide,
              ),
            ),
            if (lines.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final line in lines) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(line)),
            ],
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.ok))],
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.iptv.epgSourcesTitle),
      actions: [
        IconButton(
          icon: const AppIcon(Symbols.add_rounded),
          tooltip: t.iptv.epgAddSource,
          onPressed: _loading ? null : _addSource,
        ),
      ],
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Text(
              t.iptv.epgSourcesDescription,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Text(t.iptv.epgSourcesHint, style: theme.textTheme.bodySmall),
          ),
        ),
        if (_loading)
          const SliverPadding(
            padding: EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(child: Center(child: CircularProgressIndicator())),
          )
        else ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverToBoxAdapter(
              child: SettingsGroup(
                title: t.iptv.epgSourcesTitle,
                children: [
                  FocusableSwitchListTile(
                    secondary: const AppIcon(Symbols.low_priority_rounded, fill: 1),
                    title: Text(t.iptv.epgAddedSourcesFirst),
                    subtitle: Text(t.iptv.epgAddedSourcesFirstDescription),
                    value: _addedFirst,
                    onChanged: (v) => unawaited(_setPrecedence(v)),
                  ),
                  for (var i = 0; i < _sources.length; i++) _SourceTile(
                    source: _sources[i],
                    status: _statuses[_sources[i].id] ?? IptvEpgSourceStatus.empty,
                    statusLabel: _statusLabel(
                      _statuses[_sources[i].id] ?? IptvEpgSourceStatus.empty,
                      _sources[i].enabled,
                    ),
                    statusColor: _statusColor(
                      (_statuses[_sources[i].id] ?? IptvEpgSourceStatus.empty).state(
                        enabled: _sources[i].enabled,
                        ttl: _ttl,
                      ),
                      theme,
                    ),
                    statusDetail: _statusDetail(
                      _sources[i],
                      _statuses[_sources[i].id] ?? IptvEpgSourceStatus.empty,
                    ),
                    canMoveUp: !_sources[i].isProvider && i > 1,
                    canMoveDown: !_sources[i].isProvider && i < _sources.length - 1,
                    onToggleEnabled: _sources[i].isProvider
                        ? null
                        : (v) => unawaited(_toggleEnabled(_sources[i], v)),
                    onPickShift: _sources[i].isProvider ? null : () => unawaited(_pickShift(_sources[i])),
                    onMoveUp: () => unawaited(_move(_sources[i], -1)),
                    onMoveDown: () => unawaited(_move(_sources[i], 1)),
                    onDelete: _sources[i].isProvider ? null : () => unawaited(_delete(_sources[i])),
                  ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            sliver: SliverToBoxAdapter(
              child: SettingsGroup(
                title: t.iptv.epgDetailsTitle,
                children: [
                  SettingNavigationTile(
                    icon: Symbols.refresh_rounded,
                    title: t.iptv.epgReloadTvDetails,
                    subtitle: t.iptv.epgReloadTvDetailsDescription,
                    // 1.2.3: visible working feedback while the reload
                    // runs — the row shows a spinner until the report
                    // appears, so the tap never looks dead.
                    trailing: _reloading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : null,
                    onTap: () => unawaited(_reloadTvDetails()),
                  ),
                  SettingNavigationTile(
                    icon: Symbols.help_outline_rounded,
                    title: t.iptv.epgNoGuideTitle,
                    subtitle: t.iptv.epgNoGuideDescription,
                    onTap: () {
                      final support = _boundSupport();
                      if (support == null) return;
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => IptvEpgNoGuideScreen(support: support)),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }
}

/// One source row: name + URL, a status chip, an enable switch, the
/// per-source time shift, and (for added sources) reorder + delete.
class _SourceTile extends StatelessWidget {
  final IptvEpgSourceConfig source;
  final IptvEpgSourceStatus status;
  final String statusLabel;
  final Color statusColor;
  final String? statusDetail;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<bool>? onToggleEnabled;
  final VoidCallback? onPickShift;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback? onDelete;

  const _SourceTile({
    required this.source,
    required this.status,
    required this.statusLabel,
    required this.statusColor,
    required this.statusDetail,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onToggleEnabled,
    required this.onPickShift,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      leading: AppIcon(source.isProvider ? Symbols.rss_feed_rounded : Symbols.link_rounded, fill: 1),
      title: Text(source.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (source.url != null) Text(source.url!, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(statusLabel, style: theme.textTheme.bodySmall?.copyWith(color: statusColor)),
          ),
        ],
      ),
      trailing: onToggleEnabled == null
          ? null
          : Switch(value: source.enabled, onChanged: onToggleEnabled),
      children: [
        if (statusDetail != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(statusDetail!, style: theme.textTheme.bodySmall),
            ),
          ),
        if (onPickShift != null)
          ListTile(
            leading: const AppIcon(Symbols.timelapse_rounded),
            title: Text(t.iptv.epgTimeShift),
            subtitle: Text(
              source.timeShiftMinutes == null
                  ? t.iptv.epgNoOffset
                  : t.iptv.epgOffsetMinutes(n: source.timeShiftMinutes!),
            ),
            onTap: onPickShift,
          ),
        if (!source.isProvider)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                IconButton(
                  icon: const AppIcon(Symbols.arrow_upward_rounded),
                  tooltip: t.iptv.epgSourceMoveUp,
                  onPressed: canMoveUp ? onMoveUp : null,
                ),
                IconButton(
                  icon: const AppIcon(Symbols.arrow_downward_rounded),
                  tooltip: t.iptv.epgSourceMoveDown,
                  onPressed: canMoveDown ? onMoveDown : null,
                ),
                const Spacer(),
                IconButton(
                  icon: const AppIcon(Symbols.delete_rounded),
                  tooltip: t.iptv.epgSourceDelete,
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
