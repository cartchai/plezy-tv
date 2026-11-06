import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../media/iptv_client.dart';
import '../../media/media_item.dart';
import '../../media/media_kind.dart';
import '../../models/livetv_channel.dart';
import '../../navigation/profile_navigation_scope.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/settings_service.dart';
import '../../utils/live_tv_player_navigation.dart';
import '../../utils/tone_mapped_logo_image.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focusable_media_card.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/optimized_media_image.dart';

/// IPTV favourites (build #7 Task 1): one place for everything Matt
/// hearted across his IPTV connections — favourite live channels, movies
/// and shows — because with 55k channels and 199k movies, the favourites
/// are the only list short enough to browse.
///
/// Live TV rows render from the stored favourite snapshot (title, thumb,
/// channel number) so the screen never fetches the whole channel list
/// just to show a few channels. Tapping a channel resolves it against
/// the connection's channel list (cached per client after the first load,
/// same cost as opening Live TV) and tunes it. Movies/shows render from
/// the client's [IptvClient.favoriteItems], which re-resolves each id
/// against the catalog and falls back to its stored snapshot.
///
/// The list reloads when returning from a detail screen, so unfavouriting
/// something there drops it from this list immediately.
class IptvFavoritesScreen extends StatefulWidget {
  const IptvFavoritesScreen({super.key, required this.clients});

  /// The IPTV connections to aggregate favourites across (one per visible
  /// IPTV library). Empty means the caller showed the entry point by
  /// mistake — the screen renders its empty state.
  final List<IptvClient> clients;

  /// Matches a stored favourite channel against a fetched channel list.
  /// The id a [FavoriteChannel] stores is the live channel's key. Null
  /// when the channel left the lineup.
  @visibleForTesting
  static LiveTvChannel? resolveFavoriteChannel(List<LiveTvChannel> channels, FavoriteChannel favorite) =>
      channels.where((c) => c.key == favorite.id).firstOrNull;

  @override
  State<IptvFavoritesScreen> createState() => _IptvFavoritesScreenState();
}

class _FavoriteChannelEntry {
  const _FavoriteChannelEntry({required this.client, required this.channel});

  final IptvClient client;
  final FavoriteChannel channel;
}

class _IptvFavoritesScreenState extends State<IptvFavoritesScreen> with RouteAware {
  final _channels = <_FavoriteChannelEntry>[];
  final _movies = <MediaItem>[];
  final _shows = <MediaItem>[];
  bool _loading = true;

  /// Key of the channel currently resolving for tune (shows a spinner in
  /// its row while the connection's channel list loads).
  String? _tuningChannelKey;

  RouteObserver<PageRoute<dynamic>>? _routeObserver;
  PageRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    RouteObserver<PageRoute<dynamic>>? observer;
    try {
      observer = ProfileNavigationScope.of(context).routeObserver;
    } catch (_) {
      observer = null;
    }
    final route = ModalRoute.of(context);
    if (route is! PageRoute<dynamic> || observer == null) return;
    if (route == _route && observer == _routeObserver) return;
    _routeObserver?.unsubscribe(this);
    _route = route;
    _routeObserver = observer;
    observer.subscribe(this, route);
  }

  @override
  void dispose() {
    _routeObserver?.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    // Back from a detail screen — a favourite may have been removed there.
    _load();
  }

  Future<void> _load() async {
    final channels = <_FavoriteChannelEntry>[];
    final movies = <MediaItem>[];
    final shows = <MediaItem>[];
    for (final client in widget.clients) {
      List<FavoriteChannel> favChannels;
      List<MediaItem> favItems;
      try {
        favChannels = await client.liveTv.fetchFavoriteChannels();
      } catch (_) {
        favChannels = const [];
      }
      try {
        favItems = await client.favoriteItems();
      } catch (_) {
        favItems = const [];
      }
      for (final channel in favChannels) {
        channels.add(_FavoriteChannelEntry(client: client, channel: channel));
      }
      for (final item in favItems) {
        if (item.kind == MediaKind.movie) {
          movies.add(item);
        } else {
          shows.add(item);
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _channels
        ..clear()
        ..addAll(channels);
      _movies
        ..clear()
        ..addAll(movies);
      _shows
        ..clear()
        ..addAll(shows);
      _loading = false;
    });
  }

  Future<void> _tuneChannel(_FavoriteChannelEntry entry) async {
    if (_tuningChannelKey != null) return;
    setState(() => _tuningChannelKey = entry.channel.stableKey);
    List<LiveTvChannel> channels;
    try {
      channels = await entry.client.liveTv.fetchChannels();
    } catch (_) {
      if (!mounted) return;
      setState(() => _tuningChannelKey = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.iptv.favorites.channelUnavailable)));
      return;
    }
    final channel = IptvFavoritesScreen.resolveFavoriteChannel(channels, entry.channel);
    if (!mounted) return;
    setState(() => _tuningChannelKey = null);
    if (channel == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.iptv.favorites.channelUnavailable)));
      return;
    }
    final multiServer = context.read<MultiServerProvider>();
    await navigateToLiveTv(context, multiServer: multiServer, channel: channel, channels: channels);
  }

  @override
  Widget build(BuildContext context) {
    return FocusedScrollScaffold(
      title: Text(t.iptv.favorites.title),
      slivers: [
        if (_loading)
          const SliverFillRemaining(child: Center(child: CircularProgressIndicator()))
        else if (_channels.isEmpty && _movies.isEmpty && _shows.isEmpty)
          SliverFillRemaining(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon(Symbols.favorite_rounded, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    Text(t.iptv.favorites.empty, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      t.iptv.favorites.emptyHint,
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          )
        else ...[
          if (_channels.isNotEmpty) ...[
            _sectionHeader(t.iptv.favorites.liveTv),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _channelTile(_channels[index]),
                childCount: _channels.length,
              ),
            ),
          ],
          if (_movies.isNotEmpty) ...[
            _sectionHeader(t.iptv.favorites.movies),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => FocusableMediaCard(
                  key: Key(_movies[index].globalKey),
                  item: _movies[index],
                  viewModeOverride: ViewMode.list,
                  showServerName: true,
                  disableScale: true,
                ),
                childCount: _movies.length,
              ),
            ),
          ],
          if (_shows.isNotEmpty) ...[
            _sectionHeader(t.iptv.favorites.tvSeries),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => FocusableMediaCard(
                  key: Key(_shows[index].globalKey),
                  item: _shows[index],
                  viewModeOverride: ViewMode.list,
                  showServerName: true,
                  disableScale: true,
                ),
                childCount: _shows.length,
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ],
    );
  }

  Widget _sectionHeader(String title) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
    );
  }

  Widget _channelTile(_FavoriteChannelEntry entry) {
    final channel = entry.channel;
    final tuning = _tuningChannelKey == channel.stableKey;
    return FocusableListTile(
      leading: SizedBox(
        width: 40,
        height: 40,
        child: channel.thumb != null
            ? OptimizedMediaImage.thumb(
                client: entry.client,
                imagePath: channel.thumb,
                width: 40,
                height: 40,
                fit: BoxFit.contain,
                logoToneTarget: logoToneTargetFor(
                  surface: Theme.of(context).colorScheme.surface,
                  foreground: Theme.of(context).colorScheme.onSurface,
                ),
              )
            : Center(
                child: AppIcon(
                  Symbols.live_tv_rounded,
                  fill: 1,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
      ),
      title: Text(channel.title ?? channel.id, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        entry.client.connection.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: tuning ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : null,
      onTap: tuning ? null : () => _tuneChannel(entry),
    );
  }
}
