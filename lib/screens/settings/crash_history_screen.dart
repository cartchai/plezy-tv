import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/app_locale_utils.dart';
import '../../i18n/strings.g.dart';
import '../../services/last_crash_store.dart';
import '../../utils/formatters.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';

/// "Crash history" (Matt, 2026-11-11): every crash the phone recorded,
/// newest first, each with its date + time and a Copy button sharing the
/// exact text shown — so a crash can be pasted into a message instead of
/// screenshotted.
///
/// The store keeps the last 50 ([LastCrashStore.maxHistoryEntries]); the
/// "Last crash" row still shows only the latest. Record-only: this screen
/// never talks to the panel or the network.
class CrashHistoryScreen extends StatefulWidget {
  const CrashHistoryScreen({super.key});

  @override
  State<CrashHistoryScreen> createState() => _CrashHistoryScreenState();
}

class _CrashHistoryScreenState extends State<CrashHistoryScreen> {
  bool _loading = true;
  List<LastCrashRecord> _records = [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final records = await LastCrashStore.readHistory();
    if (!mounted) return;
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    await LastCrashStore.clear();
    if (!mounted) return;
    setState(() => _records = []);
  }

  void _copy(LastCrashRecord record) {
    Clipboard.setData(ClipboardData(text: record.describe()));
    showSuccessSnackBar(context, t.startup.detailsCopied);
  }

  String _formatTime(DateTime time) =>
      '${DateFormat.yMMMd(LocaleSettings.currentLocale.intlLocaleName).format(time)} · '
      '${formatClockTime(time, is24Hour: MediaQuery.alwaysUse24HourFormatOf(context))}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final records = _records;
    return FocusedScrollScaffold(
      title: Text(t.settings.lastCrashHistory),
      actions: [
        IconButton(
          icon: const AppIcon(Symbols.delete_rounded),
          tooltip: t.settings.lastCrashClear,
          onPressed: _loading || records.isEmpty ? null : _clear,
        ),
      ],
      slivers: [
        if (_loading)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Text(t.settings.lastCrashLoading, style: theme.textTheme.bodyMedium),
            ),
          )
        else if (records.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Text(t.settings.lastCrashNone, style: theme.textTheme.bodyMedium),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.builder(
              itemCount: records.length,
              itemBuilder: (context, index) => _CrashTile(
                record: records[index],
                index: index,
                timeText: _formatTime(records[index].timestamp.toLocal()),
                onCopy: () => _copy(records[index]),
              ),
            ),
          ),
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }
}

/// One crash, collapsed to its headline + date/time, expandable to the
/// full record with a Copy button for that crash alone.
class _CrashTile extends StatelessWidget {
  const _CrashTile({required this.record, required this.index, required this.timeText, required this.onCopy});

  final LastCrashRecord record;
  final int index;
  final String timeText;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      key: Key('CrashHistoryTile-$index'),
      leading: const AppIcon(Symbols.bug_report_rounded, fill: 1),
      title: Text(record.headline),
      subtitle: Text(timeText),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 240,
                child: SingleChildScrollView(
                  child: SelectableText(
                    record.describe(),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  key: Key('CrashHistoryCopyButton-$index'),
                  onPressed: onCopy,
                  child: Text(t.startup.copyDetails),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
