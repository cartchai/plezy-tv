import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../focus/focusable_button.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../services/iptv/m3u_parser.dart';
import '../../services/iptv/xtream_api.dart';
import '../../utils/app_logger.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/loading_indicator_box.dart';
import 'async_form_state_mixin.dart';

/// One toggleable country/region category: the display [name] and the
/// filter key [id] written to `disabledCategoryIds` when turned off.
/// For Xtream the id is the provider category id; for M3U it is the
/// playlist group title (which is also what the client filters on).
class _IptvCategory {
  final String id;
  final String name;
  const _IptvCategory({required this.id, required this.name});
}

/// Edit an IPTV connection's country/region filter: a scrollable checklist
/// of the connection's categories, each with an on/off switch. Turning a
/// category OFF adds its id to the connection's `disabledCategoryIds`;
/// turning it ON removes it. Saving persists the updated connection via
/// the registry (same `upsert(expected:)` pattern as the Jellyfin edit
/// screen); the caller rebinds, so the new filter applies immediately.
///
/// Categories are loaded lazily and rendered with a builder, so the
/// provider's 800+ categories never build all at once.
class EditIptvConnectionScreen extends StatefulWidget {
  final Connection connection;

  const EditIptvConnectionScreen({super.key, required this.connection});

  @override
  State<EditIptvConnectionScreen> createState() => _EditIptvConnectionScreenState();
}

class _EditIptvConnectionScreenState extends State<EditIptvConnectionScreen>
    with AsyncFormStateMixin, ControllerDisposerMixin {
  final _saveFocus = FocusNode(debugLabel: 'EditIptv:Save');
  final _retryFocus = FocusNode(debugLabel: 'EditIptv:Retry');

  List<_IptvCategory> _categories = const [];
  late final Set<String> _disabled = widget.connection is M3uConnection
      ? (widget.connection as M3uConnection).disabledCategoryIds.toSet()
      : (widget.connection as XtreamConnection).disabledCategoryIds.toSet();
  bool _loadingCategories = true;
  // Kept apart from the form's errorText (used by the save path) so a
  // failed category load doesn't also render under the Save button.
  String? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCategories());
  }

  @override
  void dispose() {
    _saveFocus.dispose();
    _retryFocus.dispose();
    super.dispose();
  }

  Future<List<_IptvCategory>> _fetchCategories() async {
    final connection = widget.connection;
    if (connection is XtreamConnection) {
      final api = XtreamApi(
        serverUrl: connection.serverUrl,
        username: connection.username,
        password: connection.password,
      );
      try {
        final lists = await Future.wait([
          api.getLiveCategories(),
          api.getVodCategories(),
          api.getSeriesCategories(),
        ]);
        // A category id can appear in several lists; keep the first name.
        final byId = <String, String>{};
        for (final list in lists) {
          for (final category in list) {
            if (category.id.isEmpty || category.name.isEmpty) continue;
            byId.putIfAbsent(category.id, () => category.name);
          }
        }
        final categories = byId.entries
            .map((e) => _IptvCategory(id: e.key, name: e.value))
            .toList(growable: false);
        categories.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        return categories;
      } finally {
        api.close();
      }
    }
    if (connection is M3uConnection) {
      final response = await http
          .get(Uri.parse(connection.playlistUrl))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('Playlist request failed with HTTP ${response.statusCode}');
      }
      // Group titles are the M3U categories; entries without a group can
      // never be filtered (the client treats a null category as shown).
      final groups = <String>{};
      for (final entry in parseM3u(response.body)) {
        final group = entry.groupTitle?.trim();
        if (group != null && group.isNotEmpty) groups.add(group);
      }
      final categories = groups
          .map((g) => _IptvCategory(id: g, name: g))
          .toList(growable: false);
      categories.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return categories;
    }
    return const [];
  }

  Future<void> _loadCategories() async {
    setState(() {
      _loadingCategories = true;
      _loadError = null;
    });
    try {
      final categories = await _fetchCategories();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _loadingCategories = false;
      });
    } catch (e, st) {
      appLogger.w('Edit IPTV connection: failed to load categories', error: e.runtimeType, stackTrace: st);
      if (!mounted) return;
      setState(() {
        _loadingCategories = false;
        _loadError = t.connections.iptvFilterLoadFailed;
      });
    }
  }

  Future<void> _save() async {
    await runAsync<void>(
      () async {
        final registry = context.read<ConnectionRegistry>();
        final updated = switch (widget.connection) {
          final M3uConnection c => c.copyWith(disabledCategoryIds: _disabled.toList()),
          final XtreamConnection c => c.copyWith(disabledCategoryIds: _disabled.toList()),
          _ => widget.connection,
        };
        await registry.upsert(updated, expected: widget.connection);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      },
      errorMapper: (e) {
        appLogger.e('Edit IPTV connection failed', error: e);
        return t.addServer.couldNotReachServer(error: e.toString());
      },
    );
  }

  String get _productLabel => switch (widget.connection) {
    M3uConnection() => 'M3U',
    XtreamConnection() => 'Xtream Codes',
    _ => widget.connection.displayLabel,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.connections.editMediaBrowserTitle(product: _productLabel)),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: .stretch,
              children: [
                Text(widget.connection.displayName, style: theme.textTheme.titleMedium),
                if (widget.connection.displaySubtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.connection.displaySubtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Text(t.connections.iptvFilterTitle, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(t.connections.iptvFilterIntro, style: theme.textTheme.bodyMedium),
                // TiviMate's Manage groups has "Show all groups / Hide all
                // groups" — the fast way to reset a big country list.
                if (_categories.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: busy ? null : () => setState(() => _disabled.clear()),
                        icon: const AppIcon(Symbols.visibility_rounded, fill: 1),
                        label: Text(t.connections.iptvFilterShowAll),
                      ),
                      const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: busy
                            ? null
                            : () => setState(() => _disabled.addAll(_categories.map((c) => c.id))),
                        icon: const AppIcon(Symbols.visibility_off_rounded, fill: 1),
                        label: Text(t.connections.iptvFilterHideAll),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_loadingCategories)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Row(
                children: [
                  const LoadingIndicatorBox(size: 16),
                  const SizedBox(width: 10),
                  Expanded(child: Text(t.connections.iptvFilterLoading, style: theme.textTheme.bodyMedium)),
                ],
              ),
            ),
          )
        else if (_loadError != null)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: .stretch,
                children: [
                  Text(
                    _loadError!,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 16),
                  FocusableButton(
                    focusNode: _retryFocus,
                    useBackgroundFocus: true,
                    onPressed: _loadCategories,
                    child: FilledButton.icon(
                      onPressed: _loadCategories,
                      icon: const AppIcon(Symbols.refresh_rounded, fill: 1),
                      label: Text(t.common.retry),
                    ),
                  ),
                ],
              ),
            ),
          )
        else if (_categories.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Text(t.connections.iptvFilterEmpty, style: theme.textTheme.bodyMedium),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList.builder(
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final category = _categories[index];
                final shown = !_disabled.contains(category.id);
                return FocusableSwitchListTile(
                  title: Text(category.name),
                  value: shown,
                  onChanged: busy
                      ? null
                      : (value) => setState(() {
                          if (value) {
                            _disabled.remove(category.id);
                          } else {
                            _disabled.add(category.id);
                          }
                        }),
                );
              },
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: .stretch,
              children: [
                FocusableButton(
                  focusNode: _saveFocus,
                  useBackgroundFocus: true,
                  onPressed: (busy || _loadingCategories) ? null : _save,
                  child: FilledButton.icon(
                    onPressed: (busy || _loadingCategories) ? null : _save,
                    icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.save_rounded, fill: 1),
                    label: Text(t.common.save),
                  ),
                ),
                ...buildInlineError(theme),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
