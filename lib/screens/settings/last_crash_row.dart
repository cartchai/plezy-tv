import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/last_crash_store.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';

/// "Last crash" readout (build #14): what the phone recorded the last time
/// the app died, so a crash can be figured out from the phone instead of
/// described.
///
/// The v2.25.9 startup crash was never reproduced in the harness, so the
/// crash itself is the evidence. [LastCrashCatcher] persists the last fatal
/// Dart error + stack to disk; this row reads it back on the next launch.
/// It loads only the one small file — it does not depend on the IPTV or
/// Plex clients, so it is reachable even when the app is otherwise
/// unstable.
///
/// When nothing was recorded, the row says so plainly: if the app still
/// crashed, the crash is outside Dart code (native — mpv/libmpv, or the OS
/// killing the process), and that negative result itself narrows it down.
class LastCrashRow extends StatefulWidget {
  const LastCrashRow({super.key, this.focusNode});

  final FocusNode? focusNode;

  @override
  State<LastCrashRow> createState() => _LastCrashRowState();
}

class _LastCrashRowState extends State<LastCrashRow> {
  bool _expanded = false;
  bool _loading = true;
  LastCrashRecord? _record;
  bool _abnormalExit = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final record = await LastCrashStore.read();
    if (!mounted) return;
    setState(() {
      _record = record;
      // Set at startup by markLaunched(): the previous launch never shut
      // down cleanly. Only shown when no Dart error was recorded — a
      // recorded error is the stronger evidence.
      _abnormalExit = LastCrashStore.abnormalExitDetected;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    await LastCrashStore.clear();
    if (!mounted) return;
    setState(() => _record = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = _record;
    // No Dart error recorded: say whether the previous launch at least
    // ended abnormally (flag) or whether nothing is known at all.
    final noRecordText = _abnormalExit ? t.settings.lastCrashAbnormalExit : t.settings.lastCrashNone;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FocusableListTile(
          key: const Key('LastCrashRowTile'),
          focusNode: widget.focusNode,
          title: Text(t.settings.lastCrash, style: theme.textTheme.titleSmall),
          subtitle: Text(
            _loading
                ? t.settings.lastCrashLoading
                : record == null
                    ? noRecordText
                    : record.headline,
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
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
            child: _loading
                ? Text(t.settings.lastCrashLoading, style: theme.textTheme.bodySmall)
                : record == null
                    ? Text(noRecordText, style: theme.textTheme.bodySmall)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: 240,
                            child: SingleChildScrollView(
                              child: SelectableText(
                                record.describe(),
                                key: const Key('LastCrashDetails'),
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              key: const Key('LastCrashClearButton'),
                              onPressed: _clear,
                              child: Text(t.settings.lastCrashClear),
                            ),
                          ),
                        ],
                      ),
          ),
      ],
    );
  }
}
