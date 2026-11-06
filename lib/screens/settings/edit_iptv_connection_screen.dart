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
import '../../services/settings_service.dart' as settings;
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

/// Which of the three content types a section lists. M3U groups have no
/// live/VOD/series type, so they get their own single section.
enum _CategorySectionKind { live, movies, series, groups }

/// One collapsible section of the category filter. All sections share the
/// same `disabledCategoryIds` set: a category id that appears in more than
/// one section reads the same state in both, and toggling it in one
/// updates the other.
class _IptvCategorySection {
  final _CategorySectionKind kind;
  final List<_IptvCategory> categories;

  /// The pref that persists this section's expanded/collapsed state.
  final settings.Pref<bool> expandedPref;

  const _IptvCategorySection({
    required this.kind,
    required this.categories,
    required this.expandedPref,
  });
}

settings.Pref<bool> _expandedPrefFor(_CategorySectionKind kind) => switch (kind) {
  _CategorySectionKind.live => settings.SettingsService.iptvCategoriesLiveExpanded,
  _CategorySectionKind.movies => settings.SettingsService.iptvCategoriesMoviesExpanded,
  _CategorySectionKind.series => settings.SettingsService.iptvCategoriesSeriesExpanded,
  _CategorySectionKind.groups => settings.SettingsService.iptvCategoriesGroupsExpanded,
};

/// Edit an IPTV connection's country/region filter: collapsible sections
/// per content type — Live TV, Movies, TV Series for Xtream; a single
/// Groups section for M3U — each a scrollable checklist of that type's
/// categories with an on/off switch. Turning a category OFF adds its id
/// to the connection's `disabledCategoryIds`; turning it ON removes it.
/// Saving persists the updated connection via the registry (same
/// `upsert(expected:)` pattern as the Jellyfin edit screen); the caller
/// rebinds, so the new filter applies immediately.
///
/// Categories are loaded lazily and rendered with a builder, so the
/// provider's 800+ categories never build all at once.
class EditIptvConnectionScreen extends StatefulWidget {
  final Connection connection;

  /// Test seam: when set, category fetches (the Xtream player_api calls
  /// and the M3U playlist fetch) go through this client instead of the
  /// network. Widget tests point it at a MockClient — real socket I/O
  /// does not survive the test binding's faked timers. Always null in
  /// production; tests must clear it in tearDown.
  @visibleForTesting
  static http.Client? debugHttpClient;

  const EditIptvConnectionScreen({super.key, required this.connection});

  @override
  State<EditIptvConnectionScreen> createState() => _EditIptvConnectionScreenState();
}

class _EditIptvConnectionScreenState extends State<EditIptvConnectionScreen>
    with AsyncFormStateMixin, ControllerDisposerMixin {
  final _saveFocus = FocusNode(debugLabel: 'EditIptv:Save');
  final _retryFocus = FocusNode(debugLabel: 'EditIptv:Retry');

  List<_IptvCategorySection> _sections = const [];
  late final Set<String> _disabled = widget.connection is M3uConnection
      ? (widget.connection as M3uConnection).disabledCategoryIds.toSet()
      : (widget.connection as XtreamConnection).disabledCategoryIds.toSet();

  /// Expanded/collapsed state per section, persisted per section (see
  /// [_expandedPrefFor]) so it survives leaving the screen.
  final Map<_CategorySectionKind, bool> _expanded = {};

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

  List<_IptvCategory> _sortedCategories(List<XtreamCategory> categories) {
    final seen = <String>{};
    final result = <_IptvCategory>[];
    for (final category in categories) {
      if (category.id.isEmpty || category.name.isEmpty) continue;
      if (!seen.add(category.id)) continue;
      result.add(_IptvCategory(id: category.id, name: category.name));
    }
    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  Future<List<_IptvCategorySection>> _fetchSections() async {
    final connection = widget.connection;
    if (connection is XtreamConnection) {
      final api = XtreamApi(
        serverUrl: connection.serverUrl,
        username: connection.username,
        password: connection.password,
        httpClient: EditIptvConnectionScreen.debugHttpClient,
      );
      try {
        final lists = await Future.wait([
          api.getLiveCategories(),
          api.getVodCategories(),
          api.getSeriesCategories(),
        ]);
        // The three lists stay separate — one collapsible section each.
        // A category id can appear in several lists; each section shows
        // its own copy, and both switches read the same disabled set.
        return [
          _IptvCategorySection(
            kind: _CategorySectionKind.live,
            categories: _sortedCategories(lists[0]),
            expandedPref: _expandedPrefFor(_CategorySectionKind.live),
          ),
          _IptvCategorySection(
            kind: _CategorySectionKind.movies,
            categories: _sortedCategories(lists[1]),
            expandedPref: _expandedPrefFor(_CategorySectionKind.movies),
          ),
          _IptvCategorySection(
            kind: _CategorySectionKind.series,
            categories: _sortedCategories(lists[2]),
            expandedPref: _expandedPrefFor(_CategorySectionKind.series),
          ),
        ];
      } finally {
        api.close();
      }
    }
    if (connection is M3uConnection) {
      // A client created here is closed after the fetch; the injected
      // test client is shared and left alone.
      final httpClient = EditIptvConnectionScreen.debugHttpClient ?? http.Client();
      try {
        final response = await httpClient
            .get(Uri.parse(connection.playlistUrl))
            .timeout(const Duration(seconds: 30));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError('Playlist request failed with HTTP ${response.statusCode}');
        }
        // Group titles are the M3U categories; entries without a group can
        // never be filtered (the client treats a null category as shown).
        // M3U groups have no live/VOD/series type — one plain section.
        final groups = <String>{};
        for (final entry in parseM3u(response.body)) {
          final group = entry.groupTitle?.trim();
          if (group != null && group.isNotEmpty) groups.add(group);
        }
        final categories = groups
            .map((g) => _IptvCategory(id: g, name: g))
            .toList(growable: false);
        categories.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        return [
          _IptvCategorySection(
            kind: _CategorySectionKind.groups,
            categories: categories,
            expandedPref: _expandedPrefFor(_CategorySectionKind.groups),
          ),
        ];
      } finally {
        if (EditIptvConnectionScreen.debugHttpClient == null) httpClient.close();
      }
    }
    return const [];
  }

  Future<void> _loadCategories() async {
    setState(() {
      _loadingCategories = true;
      _loadError = null;
    });
    try {
      // Persisted expanded/collapsed state per section (defaults: expanded).
      final service = await settings.SettingsService.getInstance();
      for (final kind in _CategorySectionKind.values) {
        _expanded[kind] = service.read(_expandedPrefFor(kind));
      }
      final sections = await _fetchSections();
      if (!mounted) return;
      setState(() {
        _sections = sections;
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

  /// Toggle one section's expanded state and persist it.
  void _toggleSection(_CategorySectionKind kind) {
    final expanded = !(_expanded[kind] ?? true);
    setState(() => _expanded[kind] = expanded);
    unawaited(
      settings.SettingsService.getInstance().then(
        (service) => service.write(_expandedPrefFor(kind), expanded),
      ),
    );
  }

  String _sectionTitle(_CategorySectionKind kind) => switch (kind) {
    _CategorySectionKind.live => t.connections.iptvFilterLiveTv,
    _CategorySectionKind.movies => t.connections.iptvFilterMovies,
    _CategorySectionKind.series => t.connections.iptvFilterSeries,
    _CategorySectionKind.groups => t.connections.iptvFilterGroups,
  };

  /// Flat row list for the builder: one header row per section, then that
  /// section's categories only while it is expanded. Keeps the lazy
  /// builder (the provider's 800+ categories never build all at once).
  List<Object> get _rows {
    final rows = <Object>[];
    for (final section in _sections) {
      rows.add(section);
      if (_expanded[section.kind] ?? true) rows.addAll(section.categories);
    }
    return rows;
  }

  Iterable<_IptvCategory> get _allCategories => _sections.expand((s) => s.categories);

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
                // Applies across all three sections at once.
                if (_allCategories.isNotEmpty) ...[
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
                            : () => setState(() => _disabled.addAll(_allCategories.map((c) => c.id))),
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
        else if (_allCategories.isEmpty)
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
              itemCount: _rows.length,
              itemBuilder: (context, index) {
                final row = _rows[index];
                if (row is _IptvCategorySection) {
                  final expanded = _expanded[row.kind] ?? true;
                  final offCount = row.categories.where((c) => _disabled.contains(c.id)).length;
                  return FocusableListTile(
                    title: Text(
                      _sectionTitle(row.kind),
                      style: theme.textTheme.titleSmall,
                    ),
                    subtitle: offCount == 0
                        ? Text(
                            t.connections.iptvFilterSectionCount(n: row.categories.length),
                            style: theme.textTheme.bodySmall,
                          )
                        : Text(
                            t.connections.iptvFilterSectionOff(
                              off: offCount,
                              total: row.categories.length,
                            ),
                            style: theme.textTheme.bodySmall,
                          ),
                    trailing: AppIcon(
                      expanded ? Symbols.expand_less_rounded : Symbols.expand_more_rounded,
                      fill: 1,
                    ),
                    onTap: busy ? null : () => _toggleSection(row.kind),
                  );
                }
                final category = row as _IptvCategory;
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
