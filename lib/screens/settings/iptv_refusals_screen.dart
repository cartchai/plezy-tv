import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/app_locale_utils.dart';
import '../../i18n/strings.g.dart';
import '../../services/iptv/iptv_refusal_log.dart';
import '../../utils/formatters.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';

/// "Connection refusals" (build #27): every time the provider refuses a
/// request — the status, the response headers and the first bit of the
/// response body — listed newest-first so the cause can be read off the
/// phone instead of guessed at. Record-only: this screen never talks to
/// the panel. Copy shares the whole log as text; Clear empties it.
/// No usernames or passwords are ever stored here (see
/// [IptvRefusalEntry]).
class IptvRefusalsScreen extends StatefulWidget {
  const IptvRefusalsScreen({super.key});

  @override
  State<IptvRefusalsScreen> createState() => _IptvRefusalsScreenState();
}

class _IptvRefusalsScreenState extends State<IptvRefusalsScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(IptvRefusalLog.instance.ensureLoaded());
  }

  /// Android binder transactions are capped around 1 MiB and
  /// `Clipboard.setData` crosses one (same cap as the logs screen).
  /// Trimming drops the oldest entries, keeping the newest.
  static const int _maxClipboardBytes = 256 * 1024;

  String _formatAll(List<IptvRefusalEntry> entries) {
    final buffer = StringBuffer();
    for (final entry in entries) {
      final text = entry.toShareText();
      if (buffer.isNotEmpty) buffer.write('\n\n');
      if (utf8.encode(buffer.toString()).length + utf8.encode(text).length > _maxClipboardBytes) break;
      buffer.write(text);
    }
    return buffer.toString();
  }

  void _copy(List<IptvRefusalEntry> entries) {
    if (entries.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _formatAll(entries)));
    showSuccessSnackBar(context, t.iptv.refusalsCopied);
  }

  Future<void> _clear() async {
    await IptvRefusalLog.instance.clear();
    if (!mounted) return;
    showSuccessSnackBar(context, t.iptv.refusalsCleared);
  }

  String _formatTime(DateTime time) =>
      '${DateFormat.MMMd(LocaleSettings.currentLocale.intlLocaleName).format(time)} · '
      '${formatClockTime(time, is24Hour: MediaQuery.alwaysUse24HourFormatOf(context))}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<List<IptvRefusalEntry>>(
      valueListenable: IptvRefusalLog.instance.entriesNotifier,
      builder: (context, entries, _) {
        return FocusedScrollScaffold(
          title: Text(t.iptv.refusalsTitle),
          actions: [
            IconButton(
              icon: const AppIcon(Symbols.content_copy_rounded),
              tooltip: t.iptv.refusalsCopy,
              onPressed: entries.isEmpty ? null : () => _copy(entries),
            ),
            IconButton(
              icon: const AppIcon(Symbols.delete_rounded),
              tooltip: t.iptv.refusalsClear,
              onPressed: entries.isEmpty ? null : _clear,
            ),
          ],
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              sliver: SliverToBoxAdapter(
                child: Text(t.iptv.refusalsDescription, style: theme.textTheme.bodyMedium),
              ),
            ),
            if (entries.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverToBoxAdapter(
                  child: Text(t.iptv.refusalsEmpty, style: theme.textTheme.bodyMedium),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _RefusalTile(
                    entry: entries[index],
                    timeText: _formatTime(entries[index].timestamp.toLocal()),
                  ),
                ),
              ),
            const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
          ],
        );
      },
    );
  }
}

/// One refusal, collapsed to status + action + time, expandable to the
/// full record: headers, body snippet, User-Agent, network, connection.
class _RefusalTile extends StatelessWidget {
  const _RefusalTile({required this.entry, required this.timeText});

  final IptvRefusalEntry entry;
  final String timeText;

  String get _statusLabel => entry.statusCode == null ? entry.failureKind : 'HTTP ${entry.statusCode}';

  Widget _row(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(text: '$label: ', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
            TextSpan(text: value, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      leading: const AppIcon(Symbols.block_rounded, fill: 1),
      title: Text('$_statusLabel · ${entry.action}'),
      subtitle: Text(timeText),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(theme, t.iptv.refusalsStatus, _statusLabel),
              _row(theme, t.iptv.refusalsTime, timeText),
              if (entry.connectionName.isNotEmpty)
                _row(theme, t.iptv.refusalsConnection, entry.connectionName),
              _row(theme, t.iptv.refusalsNetwork, entry.network),
              if (entry.userAgent.isNotEmpty) _row(theme, t.iptv.refusalsUserAgent, entry.userAgent),
              if (entry.headers.isNotEmpty) ...[
                _row(theme, t.iptv.refusalsHeaders, ''),
                SelectableText(
                  entry.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ],
              if (entry.bodySnippet.isNotEmpty) ...[
                _row(theme, t.iptv.refusalsBody, ''),
                SelectableText(
                  entry.bodySnippet,
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
