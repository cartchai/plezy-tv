import 'package:flutter/material.dart';

import '../connection/connection.dart';
import '../i18n/strings.g.dart';
import '../media/iptv_client.dart';
import '../utils/iptv_initials.dart';
import 'focusable_list_tile.dart';
import 'loading_indicator_box.dart';

/// Checklist of detected name initials for one IPTV connection (build #8
/// Task 4): the initials that keep repeating across the connection's
/// catalog — "EN", "ES", "NF", … — each with a switch to turn that whole
/// set off, like the category groupings. No language mapping, no allow-list:
/// every detected set is toggleable, including provider tags like "NF".
///
/// The widget loads its own initials lazily, through its own [IptvClient]
/// (created from [connection], closed on dispose), so it can sit on any
/// screen without the parent fetching a catalog. The parent owns the
/// disabled set: [disabled] is the current set, [onDisabledChanged] is
/// called with the new set on every toggle — the parent decides whether to
/// persist immediately (IPTV settings screen) or defer to a Save button
/// (connection edit screen). [onLoaded] reports the detected initials once
/// they arrive, so a parent header can show the total count.
class IptvInitialsChecklist extends StatefulWidget {
  const IptvInitialsChecklist({
    super.key,
    required this.connection,
    required this.disabled,
    required this.onDisabledChanged,
    this.onLoaded,
    this.enabled = true,
  });

  final Connection connection;
  final Set<String> disabled;
  final ValueChanged<Set<String>> onDisabledChanged;
  final ValueChanged<List<IptvInitial>>? onLoaded;

  /// False while the parent is saving — the switches and Show/Hide all
  /// buttons stop responding (same as the category rows' `busy`).
  final bool enabled;

  @override
  State<IptvInitialsChecklist> createState() => _IptvInitialsChecklistState();
}

class _IptvInitialsChecklistState extends State<IptvInitialsChecklist> {
  IptvClient? _client;
  List<IptvInitial>? _initials;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(IptvInitialsChecklist oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection.id != widget.connection.id) {
      _initials = null;
      _failed = false;
      _load();
    }
  }

  Future<void> _load() async {
    _client?.close();
    IptvClient? client;
    try {
      client = IptvClient.forConnection(widget.connection);
      _client = client;
      final initials = await client.iptvInitials();
      // A newer load (connection changed) supersedes this one.
      if (!mounted || !identical(_client, client)) return;
      setState(() => _initials = initials);
      widget.onLoaded?.call(initials);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  void _toggle(String initial, bool shown) {
    final next = Set<String>.of(widget.disabled);
    if (shown) {
      next.remove(initial);
    } else {
      next.add(initial);
    }
    widget.onDisabledChanged(next);
  }

  void _setAll(bool hide) {
    final initials = _initials;
    if (initials == null) return;
    widget.onDisabledChanged(
      hide ? initials.map((i) => i.initial).toSet() : <String>{},
    );
  }

  @override
  Widget build(BuildContext context) {
    final initials = _initials;
    if (initials == null) {
      if (_failed) {
        return ListTile(
          title: Text(t.iptv.initialsLoadFailed),
          trailing: TextButton(
            onPressed: () {
              setState(() => _failed = false);
              _load();
            },
            child: Text(t.common.retry),
          ),
        );
      }
      return ListTile(
        leading: const LoadingIndicatorBox(size: 16),
        title: Text(t.iptv.initialsLoading),
      );
    }
    if (initials.isEmpty) {
      return ListTile(title: Text(t.iptv.initialsNoneFound));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            TextButton(
              onPressed: widget.enabled ? () => _setAll(false) : null,
              child: Text(t.connections.iptvFilterShowAll),
            ),
            TextButton(
              onPressed: widget.enabled ? () => _setAll(true) : null,
              child: Text(t.connections.iptvFilterHideAll),
            ),
          ],
        ),
        for (final item in initials)
          FocusableSwitchListTile(
            title: Text('${item.initial} (${item.count})'),
            value: !widget.disabled.contains(item.initial),
            onChanged: widget.enabled ? (shown) => _toggle(item.initial, shown) : null,
          ),
      ],
    );
  }
}
