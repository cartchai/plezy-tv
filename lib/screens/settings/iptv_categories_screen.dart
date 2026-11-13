import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/iptv_client.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/iptv/xtream_api.dart';
import '../../theme/mono_tokens.dart';
import '../../utils/iptv_initials.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/iptv_unhide_refresh_notice.dart';
import '../../widgets/loading_indicator_box.dart';
import '../../widgets/settings_section.dart';

/// ONE Categories screen per IPTV connection (build #15, item 5 — the
/// from-scratch rework of the category / initials selector).
///
/// It replaces BOTH old selectors (the connection edit screen's five
/// collapsible sections with their deferred Save, and the IPTV settings
/// screen's per-connection initials list): every category is visible,
/// grouped under plain headings that are just headings, and every toggle
/// applies IMMEDIATELY — no Save button, no deferred state. A toggle
/// persists the connection (new `hiddenCategoryIds` /
/// `hiddenCategoryInitials` keys) and swaps only this IPTV client in
/// place, so Plex is never re-bound by a category change.
///
/// Headings are labels, not separate controls — Matt corrected the
/// per-content-type split: the requirement is SEE them + CONTROL them.
/// The initials group is one clearly-labelled group at the bottom:
/// turning an initial off hides every category starting with it, in
/// Live TV, Movies and TV Series.
class IptvCategoriesScreen extends StatefulWidget {
  final Connection connection;

  const IptvCategoriesScreen({super.key, required this.connection});

  @override
  State<IptvCategoriesScreen> createState() => _IptvCategoriesScreenState();
}

typedef _CategoryRow = ({String id, String name});

class _IptvCategoriesScreenState extends State<IptvCategoriesScreen> {
  late Connection _connection = widget.connection;

  IptvClient? _client;
  bool _ownsClient = false;

  bool _loading = true;
  bool _failed = false;

  List<_CategoryRow>? _live;
  bool _liveFailed = false;
  List<_CategoryRow>? _movies;
  bool _moviesFailed = false;
  List<_CategoryRow>? _series;
  bool _seriesFailed = false;
  List<_CategoryRow>? _groups;
  bool _groupsFailed = false;
  List<IptvInitial>? _initials;
  bool _initialsFailed = false;

  /// Hidden-row counts, cached (build #16): build() used to rescan all
  /// 1,236 rows on EVERY build (`_allRows.where(_isHidden)`) and every
  /// section rescanned its rows for its heading. The counts only change
  /// when the lists load or a toggle changes the connection, so they are
  /// recomputed exactly then ([_recomputeCounts]) and read from the fields
  /// below during build.
  int _liveHidden = 0;
  int _moviesHidden = 0;
  int _seriesHidden = 0;
  int _groupsHidden = 0;
  int _hiddenTotal = 0;

  void _recomputeCounts() {
    _liveHidden = _hiddenCount(_live);
    _moviesHidden = _hiddenCount(_movies);
    _seriesHidden = _hiddenCount(_series);
    _groupsHidden = _hiddenCount(_groups);
    _hiddenTotal = _liveHidden + _moviesHidden + _seriesHidden + _groupsHidden;
  }

  bool get _isXtream => _connection is XtreamConnection;

  Set<String> get _hiddenIds => switch (_connection) {
        M3uConnection(:final hiddenCategoryIds) => hiddenCategoryIds.toSet(),
        XtreamConnection(:final hiddenCategoryIds) => hiddenCategoryIds.toSet(),
        _ => <String>{},
      };

  Set<String> get _hiddenInitials => switch (_connection) {
        M3uConnection(:final hiddenCategoryInitials) => hiddenCategoryInitials.toSet(),
        XtreamConnection(:final hiddenCategoryInitials) => hiddenCategoryInitials.toSet(),
        _ => <String>{},
      };

  /// Collapsed sections (build #17): the section ids the user collapsed
  /// on this screen, persisted per connection so a relaunch restores
  /// them. Display-only — collapsing builds no rows and triggers no
  /// rebind. Default: expanded (empty set).
  Set<String> _collapsed = <String>{};

  String get _collapsedPrefsKey => 'iptv_categories_collapsed:${widget.connection.id}';

  Future<Set<String>> _readCollapsed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_collapsedPrefsKey)?.toSet() ?? <String>{};
    } catch (_) {
      return <String>{};
    }
  }

  void _toggleSection(String sectionId) {
    setState(() {
      if (_collapsed.contains(sectionId)) {
        _collapsed.remove(sectionId);
      } else {
        _collapsed.add(sectionId);
      }
    });
    unawaited(_saveCollapsed());
  }

  Future<void> _saveCollapsed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_collapsedPrefsKey, _collapsed.toList());
    } catch (_) {
      // Display-only state: a failed write just means the collapse does
      // not survive a relaunch. Never surface an error for it.
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_ownsClient) _client?.close();
    super.dispose();
  }

  /// The BOUND client when the connection is active (warm catalogs, no
  /// second network call), else a throwaway client like the old checklist
  /// used — the screen works from the edit entry even for a connection
  /// that isn't bound right now.
  IptvClient _resolveClient() {
    try {
      final bound = context.read<MultiServerProvider>().getClientForServer(ServerId(widget.connection.id));
      if (bound is IptvClient) {
        _ownsClient = false;
        return bound;
      }
    } catch (_) {
      // No provider above us, or the connection isn't bound.
    }
    _ownsClient = true;
    return IptvClient.forConnection(widget.connection);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    // Collapsed state loads with the lists, before anything renders, so
    // a relaunch never flashes expanded sections that then collapse.
    final collapsed = await _readCollapsed();
    if (!mounted) return;
    setState(() => _collapsed = collapsed);
    final client = _resolveClient();
    _client = client;
    List<_CategoryRow> rows(List<XtreamCategory> categories) {
      final seen = <String>{};
      final result = <_CategoryRow>[];
      for (final category in categories) {
        if (category.id.isEmpty || category.name.isEmpty) continue;
        if (!seen.add(category.id)) continue;
        result.add((id: category.id, name: category.name));
      }
      result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return result;
    }

    if (_isXtream) {
      List<_CategoryRow>? live;
      var liveFailed = false;
      try {
        live = rows(await client.liveCategories());
      } catch (_) {
        liveFailed = true;
      }
      List<_CategoryRow>? movies;
      var moviesFailed = false;
      try {
        movies = rows(await client.vodCategories());
      } catch (_) {
        moviesFailed = true;
      }
      List<_CategoryRow>? series;
      var seriesFailed = false;
      try {
        series = rows(await client.seriesCategories());
      } catch (_) {
        seriesFailed = true;
      }
      // Each list loads independently: one bad list must not kill the
      // screen (the old initials list died entirely when the VOD/series
      // fetch threw). The whole screen fails only when NOTHING loaded.
      if (!mounted) return;
      setState(() {
        _live = live;
        _liveFailed = liveFailed;
        _movies = movies;
        _moviesFailed = moviesFailed;
        _series = series;
        _seriesFailed = seriesFailed;
        _failed = live == null && movies == null && series == null;
        _loading = false;
        _recomputeCounts();
      });
    } else {
      List<_CategoryRow>? groups;
      var groupsFailed = false;
      try {
        groups = (await client.m3uGroups()).map((g) => (id: g, name: g)).toList(growable: false);
      } catch (_) {
        groupsFailed = true;
      }
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _groupsFailed = groupsFailed;
        _failed = groups == null;
        _loading = false;
        _recomputeCounts();
      });
    }

    // Initials load separately from the category lists, so a slow initials
    // fetch never holds the categories back.
    try {
      final initials = await client.iptvInitials()
        ..sort((a, b) => a.initial.toUpperCase().compareTo(b.initial.toUpperCase()));
      if (!mounted) return;
      setState(() => _initials = initials);
    } catch (_) {
      if (!mounted) return;
      setState(() => _initialsFailed = true);
    }
  }

  bool _isHidden(_CategoryRow row) {
    if (_hiddenIds.contains(row.id)) return true;
    final initial = categoryInitial(row.name);
    return initial != null && _hiddenInitials.contains(initial);
  }

  int _hiddenCount(List<_CategoryRow>? rows) => rows == null ? 0 : rows.where(_isHidden).length;

  Future<void> _persist(Connection updated) async {
    final previous = _connection;
    // 1.2.4: the newly-unhidden category ids — by id, plus every row
    // whose initial was just un-hidden. Resolved from the loaded rows
    // now: the notice must appear at the moment of the toggle, not
    // buried in Settings.
    final unhidden = _unhiddenCategoryIds(previous, updated);
    // Optimistic: the row and the counts update in the same frame as the
    // tap. The persist below is local storage; if it fails, revert.
    setState(() {
      _connection = updated;
      _recomputeCounts();
    });
    try {
      await context.read<ConnectionRegistry>().upsert(updated);
      if (!mounted) return;
      // Swap only this IPTV client in place (build #15, P-1): no full
      // profile rebind, no Plex involvement. The new client carries the
      // new filter, and the catalog-refreshed event re-renders the guide,
      // libraries and Discover past the RefreshPacer cooldown.
      unawaited(
        context.read<MultiServerProvider>().refreshIptvConnection(updated).then((_) {
          // 1.2.4: the rebind above starts the memo re-derive on the
          // bound client; the notice awaits it and shows only when the
          // un-hidden rows were pruned (a refresh is needed to bring
          // them back). Resolved after the rebind so an unbound
          // connection's fresh client is the one checked — never the
          // screen's throwaway (its memos are cold).
          if (!mounted || unhidden.isEmpty) return;
          final client = _boundClient();
          if (client == null) return;
          unawaited(
            maybeShowUnhideRefreshNotice(
              context,
              client: client,
              unhiddenCategoryIds: unhidden,
            ),
          );
        }),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connection = previous;
        _recomputeCounts();
      });
      showErrorSnackBar(context, t.iptvCategories.persistFailed);
    }
  }

  /// The bound client for this connection, if it is bound right now
  /// (1.2.4): the notice check must run against the bound client's
  /// memos, never a throwaway. Null when unbound (the rebind failed or
  /// has not landed) — then no notice, never a cold-client load.
  IptvClient? _boundClient() {
    try {
      final bound = context.read<MultiServerProvider>().getClientForServer(ServerId(widget.connection.id));
      if (bound is IptvClient) return bound;
    } catch (_) {
      // No provider above us, or the connection isn't bound.
    }
    return null;
  }

  /// Category ids the [updated] connection un-hides relative to
  /// [previous] (1.2.4): ids removed from the hidden list, plus every
  /// loaded row whose initial was removed from the hidden initials.
  Set<String> _unhiddenCategoryIds(Connection previous, Connection updated) {
    Set<String> hiddenIdsOf(Connection c) => switch (c) {
      M3uConnection(:final hiddenCategoryIds) => hiddenCategoryIds.toSet(),
      XtreamConnection(:final hiddenCategoryIds) => hiddenCategoryIds.toSet(),
      _ => <String>{},
    };
    Set<String> hiddenInitialsOf(Connection c) => switch (c) {
      M3uConnection(:final hiddenCategoryInitials) => hiddenCategoryInitials.toSet(),
      XtreamConnection(:final hiddenCategoryInitials) => hiddenCategoryInitials.toSet(),
      _ => <String>{},
    };
    final unhiddenIds = hiddenIdsOf(previous).difference(hiddenIdsOf(updated));
    final unhiddenInitials = hiddenInitialsOf(previous).difference(hiddenInitialsOf(updated));
    if (unhiddenInitials.isEmpty) return unhiddenIds;
    final rows = <_CategoryRow>[...?_live, ...?_movies, ...?_series, ...?_groups];
    return {
      ...unhiddenIds,
      for (final row in rows)
        if (unhiddenInitials.contains(categoryInitial(row.name))) row.id,
    };
  }

  Connection _withHiddenIds(Set<String> next) => switch (_connection) {
        final M3uConnection c => c.copyWith(hiddenCategoryIds: next.toList()),
        final XtreamConnection c => c.copyWith(hiddenCategoryIds: next.toList()),
        _ => _connection,
      };

  Connection _withHiddenInitials(Set<String> next) => switch (_connection) {
        final M3uConnection c => c.copyWith(hiddenCategoryInitials: next.toList()),
        final XtreamConnection c => c.copyWith(hiddenCategoryInitials: next.toList()),
        _ => _connection,
      };

  void _toggleCategory(String id, bool shown) {
    final next = Set<String>.of(_hiddenIds);
    if (shown) {
      next.remove(id);
    } else {
      next.add(id);
    }
    unawaited(_persist(_withHiddenIds(next)));
  }

  void _toggleInitial(String initial, bool shown) {
    final next = Set<String>.of(_hiddenInitials);
    if (shown) {
      next.remove(initial);
    } else {
      next.add(initial);
    }
    unawaited(_persist(_withHiddenInitials(next)));
  }

  void _setAllInitials(bool shown) {
    if (shown) {
      // Show all means show ALL (v1.1.0): clear every hidden initial,
      // including ones below the offer threshold or in the content-word
      // denylist that have no toggle on screen — the old code only
      // cleared the offered ones, so a group hidden that way could
      // never come back from this screen.
      unawaited(_persist(_withHiddenInitials(const <String>{})));
      return;
    }
    final initials = _initials;
    if (initials == null) return;
    final next = Set<String>.of(_hiddenInitials);
    for (final initial in initials) {
      next.add(initial.initial);
    }
    unawaited(_persist(_withHiddenInitials(next)));
  }

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(t.iptvCategories.title(name: _connection.displayName)),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.iptvCategories.intro, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 8),
                Text(
                  t.iptvCategories.hiddenTotal(count: _hiddenTotal),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
        if (_loading)
          const SliverPadding(
            padding: EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(child: LoadingIndicatorBox()),
          )
        else if (_failed)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverToBoxAdapter(
              child: SettingsGroup(
                children: [
                  ListTile(
                    leading: const AppIcon(Symbols.error_rounded, fill: 1),
                    title: Text(t.iptvCategories.loadFailed),
                  ),
                  TextButton(
                    onPressed: () => unawaited(_load()),
                    child: Text(t.iptvCategories.retry),
                  ),
                ],
              ),
            ),
          )
        else ...[
          if (_isXtream) ...[
            _section(
              sectionId: 'live',
              heading: t.iptvCategories.liveTvHeading,
              rows: _live,
              failed: _liveFailed,
              hidden: _liveHidden,
            ),
            _section(
              sectionId: 'movies',
              heading: t.iptvCategories.moviesHeading,
              rows: _movies,
              failed: _moviesFailed,
              hidden: _moviesHidden,
            ),
            _section(
              sectionId: 'series',
              heading: t.iptvCategories.seriesHeading,
              rows: _series,
              failed: _seriesFailed,
              hidden: _seriesHidden,
            ),
          ] else
            _section(
              sectionId: 'groups',
              heading: t.iptvCategories.groupsHeading,
              rows: _groups,
              failed: _groupsFailed,
              hidden: _groupsHidden,
            ),
          _initialsSection(),
          const SliverPadding(padding: EdgeInsets.only(top: 24)),
        ],
      ],
    );
  }

  Widget _section({
    required String sectionId,
    required String heading,
    required List<_CategoryRow>? rows,
    required bool failed,
    required int hidden,
  }) {
    if (rows == null) {
      if (!failed) return const SliverToBoxAdapter(child: SizedBox.shrink());
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        sliver: SliverToBoxAdapter(
          child: SettingsGroup(
            title: heading,
            children: [
              ListTile(
                leading: const AppIcon(Symbols.error_rounded, fill: 1),
                title: Text(t.iptvCategories.sectionLoadFailed),
              ),
            ],
          ),
        ),
      );
    }
    final title = '$heading · ${t.iptvCategories.sectionCount(total: rows.length, hidden: hidden)}';
    // Build #17: tapping the header collapses the section to the header
    // alone (itemCount 1) — the rows are simply not built, exactly like
    // a section scrolled out of view, so the build #16 virtualization
    // holds. The collapsed header keeps showing the count, so it still
    // tells Matt what is inside it. Collapsing changes no counts and
    // triggers no recompute or rebind.
    final collapsed = _collapsed.contains(sectionId);
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      sliver: SliverList.builder(
        itemCount: collapsed ? 1 : rows.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return InkWell(
              onTap: () => _toggleSection(sectionId),
              child: Row(
                children: [
                  Expanded(child: SettingsSectionHeader(title)),
                  Padding(
                    padding: const EdgeInsets.only(right: 16, top: 24),
                    child: Icon(
                      collapsed ? Icons.expand_more : Icons.expand_less,
                      color: tokens(context).textMuted,
                    ),
                  ),
                ],
              ),
            );
          }
          final i = index - 1;
          final row = rows[i];
          return _groupCard(
            context,
            index: i,
            total: rows.length,
            child: FocusableSwitchListTile(
              title: Text(row.name),
              value: !_isHidden(row),
              onChanged: (shown) => _toggleCategory(row.id, shown),
            ),
          );
        },
      ),
    );
  }

  /// One card in a virtualized section (build #16). [SettingsGroup] wraps
  /// every child in the same Material card — a plain Column — so a
  /// [SliverList.builder] row has to build the card itself: same surface,
  /// same corner radii for its position in the group ([groupItemRadii]),
  /// same [groupGap] between cards. The heading is NOT a card (it is the
  /// builder's item 0, a [SettingsSectionHeader]).
  Widget _groupCard(BuildContext context, {required int index, required int total, required Widget child}) {
    final t = tokens(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, index == 0 ? 0 : t.groupGap, 16, 0),
      child: Material(
        color: t.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: groupItemRadii(context, index, total)),
        child: child,
      ),
    );
  }

  Widget _initialsSection() {
    final initials = _initials;
    if (initials == null) {
      if (_initialsFailed) {
        return SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          sliver: SliverToBoxAdapter(
            child: SettingsGroup(
              title: t.iptvCategories.initialsHeading,
              children: [
                ListTile(
                  leading: const AppIcon(Symbols.error_rounded, fill: 1),
                  title: Text(t.iptvCategories.sectionLoadFailed),
                ),
              ],
            ),
          ),
        );
      }
      return const SliverPadding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24),
        sliver: SliverToBoxAdapter(child: LoadingIndicatorBox()),
      );
    }
    final hidden = _hiddenInitials.length;
    // v1.1.0: the header counts GROUPS, not categories — the old
    // sectionCount label said "37 categories" for 37 groups.
    final title =
        '${t.iptvCategories.initialsHeading} · ${t.iptvCategories.groupsSectionCount(total: initials.length, hidden: hidden)}';
    // Build #16: virtualized like the category sections — the subheading
    // and the Show/Hide buttons are card items 0–1, the initials follow.
    // A toggle rebuilds only the rows in view (see [_groupCard]).
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      sliver: SliverList.builder(
        itemCount: initials.length + 3,
        itemBuilder: (context, index) {
          if (index == 0) return SettingsSectionHeader(title);
          final i = index - 1;
          if (i == 0) {
            return _groupCard(
              context,
              index: 0,
              total: initials.length + 2,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  _isXtream ? t.iptvCategories.initialsSubheading : t.iptvCategories.initialsSubheadingM3u,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            );
          }
          if (i == 1) {
            return _groupCard(
              context,
              index: 1,
              total: initials.length + 2,
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => _setAllInitials(true),
                    child: Text(t.iptvCategories.showAll),
                  ),
                  TextButton(
                    onPressed: () => _setAllInitials(false),
                    child: Text(t.iptvCategories.hideAll),
                  ),
                ],
              ),
            );
          }
          final initial = initials[i - 2];
          return _groupCard(
            context,
            index: i,
            total: initials.length + 2,
            child: FocusableSwitchListTile(
              title: Text(
                _isXtream
                    ? t.iptvCategories.initialRow(initial: initial.initial, count: initial.count)
                    : t.iptvCategories.initialRowM3u(initial: initial.initial, count: initial.count),
              ),
              value: !_hiddenInitials.contains(initial.initial),
              onChanged: (shown) => _toggleInitial(initial.initial, shown),
            ),
          );
        },
      ),
    );
  }
}
