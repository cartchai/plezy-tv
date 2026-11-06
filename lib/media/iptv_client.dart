import 'dart:async';

import 'package:http/http.dart' as http;

import '../connection/connection.dart';
import '../exceptions/media_server_exceptions.dart';
import '../media/artist_discography.dart';
import '../media/download_resolution.dart';
import '../media/ids.dart';
import '../media/library_change_event.dart';
import '../media/library_filter_result.dart';
import '../media/library_query.dart';
import '../media/live_tv_support.dart';
import '../media/lyrics.dart';
import '../media/media_backend.dart';
import '../media/media_file_info.dart';
import '../media/media_hub.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_library.dart';
import '../media/media_person.dart';
import '../media/media_playlist.dart';
import '../media/media_server_client.dart';
import '../media/media_sort.dart';
import '../media/media_source_info.dart';
import '../media/media_version.dart';
import '../media/playback_report_metadata.dart';
import '../media/server_capabilities.dart';
import '../models/livetv_channel.dart';
import '../services/api_cache.dart';
import '../services/playback_initialization_types.dart';
import '../services/scrub_preview_source.dart';
import '../utils/app_logger.dart';
import '../utils/external_ids.dart';
import '../utils/media_server_http_client.dart' show AbortController;
import 'iptv_live_tv.dart';
import '../services/iptv/m3u_parser.dart';
import '../services/iptv/xtream_api.dart';

/// IPTV client: M3U playlists and Xtream Codes accounts behind the neutral
/// [MediaServerClient] surface.
///
/// The provider catalog is huge (tens of thousands of live channels,
/// hundreds of thousands of VOD rows), so nothing here ever hands the whole
/// catalog to the UI at once: libraries page through [LibraryPage], search
/// is client-side over a lazily loaded in-memory list, and live channels
/// are served only through [liveTv].
///
/// Only one stream may be open at a time on this account. This client never
/// opens a stream itself — [getPlaybackInitialization] and
/// [LiveTvSupport.startPlayback] hand out URLs and the player opens exactly
/// one of them. No prefetching, no preview probing.
class IptvClient implements MediaServerClient {
  final Connection connection;

  IptvClient.m3u({required M3uConnection m3uConnection}) : connection = m3uConnection;
  IptvClient.xtream({required XtreamConnection xtreamConnection}) : connection = xtreamConnection;

  factory IptvClient.forConnection(Connection connection) {
    return switch (connection) {
      M3uConnection() => IptvClient.m3u(m3uConnection: connection),
      XtreamConnection() => IptvClient.xtream(xtreamConnection: connection),
      _ => throw UnsupportedError('IptvClient cannot wrap ${connection.runtimeType}'),
    };
  }

  bool get _isXtream => connection is XtreamConnection;
  XtreamConnection get _xtream => connection as XtreamConnection;
  M3uConnection get _m3u => connection as M3uConnection;

  /// User-given library name (the base [Connection] type has no `name`).
  String get _name => switch (connection) {
    M3uConnection(:final name) => name,
    XtreamConnection(:final name) => name,
    _ => connection.displayName,
  };

  /// Country/region filter list (only the IPTV connection types carry it).
  List<String> get _disabledCategoryIdList => switch (connection) {
    M3uConnection(:final disabledCategoryIds) => disabledCategoryIds,
    XtreamConnection(:final disabledCategoryIds) => disabledCategoryIds,
    _ => const [],
  };

  XtreamApi? _api;
  XtreamApi get _xtreamApi => _api ??= XtreamApi(
    serverUrl: _xtream.serverUrl,
    username: _xtream.username,
    password: _xtream.password,
  );

  final http.Client _http = http.Client();
  final Object _authSessionId = Object();
  bool _offline = false;
  late final IptvLiveTvSupport _liveTv = IptvLiveTvSupport(this);

  // In-memory catalog caches (lazy; the provider lists are large).
  Future<List<XtreamLiveStream>>? _liveStreamsFuture;
  Future<List<XtreamVodStream>>? _vodStreamsFuture;
  Future<List<XtreamSeries>>? _seriesFuture;
  Future<List<XtreamCategory>>? _vodCategoriesFuture;
  Future<List<XtreamCategory>>? _seriesCategoriesFuture;
  Future<List<M3uEntry>>? _m3uEntriesFuture;

  /// Live-channel stream info by channel key (populated by [iptvChannels]).
  final Map<String, XtreamLiveStream> _xtreamChannelByKey = {};
  final Map<String, M3uEntry> _m3uChannelByKey = {};

  static const String liveLibrarySuffix = 'live';
  static const String moviesLibrarySuffix = 'movies';
  static const String seriesLibrarySuffix = 'series';

  String _libraryId(String suffix) => 'iptv:${connection.id}:$suffix';

  String get _liveLibraryId => _libraryId(liveLibrarySuffix);
  String get _moviesLibraryId => _libraryId(moviesLibrarySuffix);
  String get _seriesLibraryId => _libraryId(seriesLibrarySuffix);

  Set<String> get _disabledCategories => _disabledCategoryIdList.toSet();

  bool _isDisabled(String? categoryId) => categoryId != null && _disabledCategories.contains(categoryId);

  @override
  ServerId get serverId => ServerId(connection.id);

  @override
  String? get serverName => _name;

  @override
  MediaBackend get backend => connection.kind;

  @override
  ServerCapabilities get capabilities => const ServerCapabilities(
    liveTv: true,
    liveTvDvr: false,
    videoTranscoding: false,
    richHubs: false,
    numericUserRating: false,
    userFavorites: true,
    continueWatchingRemoval: false,
    externalSubtitleSearch: false,
    richMetadataEdit: false,
    scrubThumbnails: false,
    folderGrouping: false,
    instantMix: false,
    libraryChangeEvents: false,
  );

  @override
  Object get authenticationSessionId => _authSessionId;

  @override
  void close() {
    _api?.close();
    _http.close();
  }

  @override
  LibraryEventChannel? createLibraryEventChannel() => null;

  @override
  bool get isOfflineMode => _offline;

  @override
  void setOfflineMode(bool offline) => _offline = offline;

  @override
  ApiCache get cache => ApiCache.forBackend(backend);

  @override
  Map<String, String> get streamHeaders => const {};

  @override
  double get watchedThreshold => 0.9;

  @override
  bool get marksWatchedOnPlaybackStopped => false;

  @override
  LiveTvSupport get liveTv => _liveTv;

  @override
  Future<HealthStatus> checkHealth() async {
    if (_isXtream) {
      try {
        final info = await _xtreamApi.getUserInfo();
        return info == null ? HealthStatus.authError : HealthStatus.online;
      } on MediaServerAuthException {
        return HealthStatus.authError;
      } on MediaServerHttpException catch (e) {
        if (e.statusCode == 403) return HealthStatus.accessDenied;
        return HealthStatus.offline;
      } catch (e) {
        appLogger.d('IPTV health probe failed', error: e);
        return HealthStatus.offline;
      }
    }
    try {
      final response = await _http.head(Uri.parse(_m3u.playlistUrl)).timeout(const Duration(seconds: 15));
      return response.statusCode == 200 ? HealthStatus.online : HealthStatus.offline;
    } catch (e) {
      appLogger.d('IPTV health probe failed', error: e);
      return HealthStatus.offline;
    }
  }

  @override
  Future<String?> getMachineIdentifier() async => connection.id;

  // -- Catalog loading (lazy, in-memory) ----------------------------------

  Future<List<XtreamLiveStream>> _liveStreams() =>
      _liveStreamsFuture ??= _xtreamApi.getLiveStreams().catchError((Object e) {
        _liveStreamsFuture = null;
        throw e;
      });

  Future<List<XtreamVodStream>> _vodStreams() =>
      _vodStreamsFuture ??= _xtreamApi.getVodStreams().catchError((Object e) {
        _vodStreamsFuture = null;
        throw e;
      });

  Future<List<XtreamSeries>> _seriesList() =>
      _seriesFuture ??= _xtreamApi.getSeries().catchError((Object e) {
        _seriesFuture = null;
        throw e;
      });

  Future<List<M3uEntry>> _m3uEntries() {
    return _m3uEntriesFuture ??= () async {
      final response = await _http.get(Uri.parse(_m3u.playlistUrl)).timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MediaServerHttpException(
          type: MediaServerHttpErrorType.unknown,
          message: 'M3U playlist fetch failed with HTTP ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }
      return parseM3u(response.body);
    }().catchError((Object e) {
      _m3uEntriesFuture = null;
      throw e;
    });
  }

  Future<List<XtreamCategory>> _vodCategories() =>
      _vodCategoriesFuture ??= _xtreamApi.getVodCategories().catchError((Object e) {
        _vodCategoriesFuture = null;
        throw e;
      });

  Future<List<XtreamCategory>> _seriesCategories() =>
      _seriesCategoriesFuture ??= _xtreamApi.getSeriesCategories().catchError((Object e) {
        _seriesCategoriesFuture = null;
        throw e;
      });

  /// True when every category of a type is disabled — the library for that
  /// type is then omitted from [fetchLibraries]. Fails open (keeps the
  /// library) when the category list cannot be fetched.
  Future<bool> _allCategoriesDisabled(Future<List<XtreamCategory>> Function() load) async {
    if (_disabledCategories.isEmpty) return false;
    try {
      final categories = await load();
      if (categories.isEmpty) return false;
      return categories.every((c) => _disabledCategories.contains(c.id));
    } catch (e) {
      appLogger.d('IPTV category probe failed; keeping library', error: e);
      return false;
    }
  }

  // -- Libraries -----------------------------------------------------------

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    final name = _name;
    final libraries = <MediaLibrary>[
      MediaLibrary(
        id: _liveLibraryId,
        backend: backend,
        title: '$name — Live TV',
        kind: MediaKind.unknown,
        serverId: connection.id,
        serverName: name,
      ),
    ];
    if (_isXtream) {
      if (!await _allCategoriesDisabled(_vodCategories)) {
        libraries.add(
          MediaLibrary(
            id: _moviesLibraryId,
            backend: backend,
            title: '$name — Movies',
            kind: MediaKind.movie,
            serverId: connection.id,
            serverName: name,
          ),
        );
      }
      if (!await _allCategoriesDisabled(_seriesCategories)) {
        libraries.add(
          MediaLibrary(
            id: _seriesLibraryId,
            backend: backend,
            title: '$name — Series',
            kind: MediaKind.show,
            serverId: connection.id,
            serverName: name,
          ),
        );
      }
    }
    return libraries;
  }

  MediaItem _movieItem(XtreamVodStream stream) {
    final url = _xtreamApi.movieStreamUrl('${stream.streamId}', stream.containerExtension);
    return MediaItem.xtream(
      id: 'movie:${stream.streamId}',
      kind: MediaKind.movie,
      title: stream.name,
      thumbPath: stream.cover ?? stream.streamIcon,
      rating: stream.rating,
      streamUrl: url,
      categoryId: stream.categoryId,
      libraryId: _moviesLibraryId,
      libraryTitle: '$_name — Movies',
      serverId: connection.id,
      serverName: _name,
    );
  }

  MediaItem _seriesItem(XtreamSeries series) {
    return MediaItem.xtream(
      id: 'series:${series.seriesId}',
      kind: MediaKind.show,
      title: series.name,
      summary: series.plot,
      thumbPath: series.cover,
      rating: series.rating,
      categoryId: series.categoryId,
      libraryId: _seriesLibraryId,
      libraryTitle: '$_name — Series',
      serverId: connection.id,
      serverName: _name,
    );
  }

  MediaItem _episodeItem(XtreamSeries series, XtreamEpisode episode, int season) {
    final url = _xtreamApi.seriesStreamUrl('${episode.id}', episode.containerExtension);
    return MediaItem.xtream(
      id: 'episode:${series.seriesId}:${episode.id}',
      kind: MediaKind.episode,
      title: episode.title.isEmpty ? 'Episode ${episode.episodeNum}' : episode.title,
      summary: episode.plot,
      parentId: 'series:${series.seriesId}',
      parentTitle: series.name,
      parentIndex: season,
      index: episode.episodeNum,
      durationMs: episode.durationSeconds == null ? null : episode.durationSeconds! * 1000,
      streamUrl: url,
      categoryId: series.categoryId,
      libraryId: _seriesLibraryId,
      libraryTitle: '$_name — Series',
      serverId: connection.id,
      serverName: _name,
    );
  }

  LibraryPage<MediaItem> _page(List<MediaItem> all, LibraryQuery query) {
    final offset = query.offset.clamp(0, all.length);
    final end = (offset + query.limit).clamp(0, all.length);
    return LibraryPage(items: all.sublist(offset, end), totalCount: all.length, offset: offset);
  }

  List<MediaItem> _applyQueryFilters(List<MediaItem> items, LibraryQuery query) {
    var out = items;
    final search = query.search?.trim().toLowerCase();
    if (search != null && search.isNotEmpty) {
      out = out.where((i) => (i.title ?? '').toLowerCase().contains(search)).toList();
    }
    final startsWith = query.nameStartsWith;
    if (startsWith != null && startsWith.isNotEmpty) {
      if (startsWith == '#') {
        out = out.where((i) {
          final first = (i.title ?? '').trimLeft();
          return first.isEmpty || !RegExp(r'^[A-Za-z]').hasMatch(first);
        }).toList();
      } else {
        out = out.where((i) => (i.title ?? '').trimLeft().toLowerCase().startsWith(startsWith.toLowerCase())).toList();
      }
    }
    return out;
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    // Live channels are served only through liveTv, never as library rows.
    if (libraryId == _liveLibraryId) {
      return const LibraryPage(items: [], totalCount: 0);
    }
    if (!_isXtream) return const LibraryPage(items: [], totalCount: 0);
    abort?.throwIfAborted();
    if (libraryId == _moviesLibraryId) {
      final streams = await _vodStreams();
      final items = streams.where((s) => !_isDisabled(s.categoryId)).map(_movieItem).toList();
      return _page(_applyQueryFilters(items, query), query);
    }
    if (libraryId == _seriesLibraryId) {
      final series = await _seriesList();
      final items = series.where((s) => !_isDisabled(s.categoryId)).map(_seriesItem).toList();
      return _page(_applyQueryFilters(items, query), query);
    }
    return const LibraryPage(items: [], totalCount: 0);
  }

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async {
    return LibraryFilterResult.empty;
  }

  @override
  Future<List<MediaSort>> fetchSortOptions(String libraryId, {String? libraryType}) async => [];

  @override
  Future<void> refreshLibraryMetadata(String libraryId) {
    throw UnsupportedError('IPTV: refreshLibraryMetadata not supported');
  }

  @override
  Future<void> scanLibrary(String libraryId) {
    throw UnsupportedError('IPTV: scanLibrary not supported');
  }

  @override
  Future<MediaItem?> fetchItem(String id) async {
    if (!_isXtream) {
      // M3U: channel items are keyed `m3u:<tvg-id or name>`.
      if (id.startsWith('m3u:')) {
        final entries = await _m3uEntries();
        final key = id.substring(4);
        final entry = entries.where((e) => (e.tvgId ?? e.name) == key).firstOrNull;
        if (entry == null) return null;
        return MediaItem.m3u(
          id: id,
          kind: MediaKind.unknown,
          title: entry.name,
          thumbPath: entry.tvgLogo,
          streamUrl: entry.url,
          epgChannelId: entry.tvgId,
          categoryId: entry.groupTitle,
          libraryId: _liveLibraryId,
          libraryTitle: '$_name — Live TV',
          serverId: connection.id,
          serverName: _name,
        );
      }
      return null;
    }
    final parts = id.split(':');
    if (parts.length < 2) return null;
    switch (parts[0]) {
      case 'movie':
        final streamId = int.tryParse(parts[1]);
        if (streamId == null) return null;
        final streams = await _vodStreams();
        final stream = streams.where((s) => s.streamId == streamId).firstOrNull;
        return stream == null ? null : _movieItem(stream);
      case 'series':
        final seriesId = int.tryParse(parts[1]);
        if (seriesId == null) return null;
        final series = await _seriesList();
        final found = series.where((s) => s.seriesId == seriesId).firstOrNull;
        return found == null ? null : _seriesItem(found);
      case 'episode':
        if (parts.length < 3) return null;
        final seriesId = int.tryParse(parts[1]);
        final episodeId = int.tryParse(parts[2]);
        if (seriesId == null || episodeId == null) return null;
        final info = await _xtreamApi.getSeriesInfo(seriesId);
        for (final seasonEntry in info.episodesBySeason.entries) {
          final episode = seasonEntry.value.where((e) => e.id == episodeId).firstOrNull;
          if (episode == null) continue;
          final series = (await _seriesList()).where((s) => s.seriesId == seriesId).firstOrNull;
          if (series == null) return null;
          return _episodeItem(series, episode, seasonEntry.key);
        }
        return null;
      default:
        return null;
    }
  }

  @override
  Future<({MediaItem? item, MediaItem? onDeckEpisode})> fetchItemWithOnDeck(
    String id, {
    void Function(MediaItem item)? onItemReady,
  }) async {
    final item = await fetchItem(id);
    if (item != null) onItemReady?.call(item);
    return (item: item, onDeckEpisode: null);
  }

  @override
  Future<List<MediaItem>> fetchChildren(String parentId) async {
    if (!_isXtream) return const [];
    final parts = parentId.split(':');
    if (parts.length < 2 || parts[0] != 'series') return const [];
    final seriesId = int.tryParse(parts[1]);
    if (seriesId == null) return const [];
    final series = (await _seriesList()).where((s) => s.seriesId == seriesId).firstOrNull;
    if (series == null) return const [];
    final info = await _xtreamApi.getSeriesInfo(seriesId);
    final episodes = <MediaItem>[];
    final seasons = info.episodesBySeason.keys.toList()..sort();
    for (final season in seasons) {
      final seasonEpisodes = info.episodesBySeason[season]!..sort((a, b) => a.episodeNum.compareTo(b.episodeNum));
      for (final episode in seasonEpisodes) {
        episodes.add(_episodeItem(series, episode, season));
      }
    }
    return episodes;
  }

  @override
  Future<List<MediaItem>> fetchLibraryFolders(String libraryId, {void Function(List<MediaItem> itemsSoFar)? onPage}) {
    throw UnsupportedError('IPTV: fetchLibraryFolders not supported');
  }

  @override
  Future<List<MediaItem>> fetchFolderChildren(
    MediaItem folder, {
    String? libraryId,
    String? libraryTitle,
    void Function(List<MediaItem> itemsSoFar)? onPage,
  }) {
    throw UnsupportedError('IPTV: fetchFolderChildren not supported');
  }

  @override
  Future<LibraryPage<MediaItem>> fetchChildrenPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    final children = await fetchChildren(parentId);
    final offset = (start ?? 0).clamp(0, children.length);
    final end = size == null ? children.length : (offset + size).clamp(0, children.length);
    return LibraryPage(items: children.sublist(offset, end), totalCount: children.length, offset: offset);
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlayableDescendantsPage(
    String parentId, {
    int? start,
    int? size,
    AbortController? abort,
  }) {
    throw UnsupportedError('IPTV: fetchPlayableDescendantsPage not supported');
  }

  @override
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) => fetchChildren(parentId);

  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) async {
    final episodes = await fetchChildren(seriesId);
    return episodes.isEmpty ? null : episodes;
  }

  @override
  Future<List<MediaItem>> fetchArtistAlbums(MediaItem artist) {
    throw UnsupportedError('IPTV: fetchArtistAlbums not supported');
  }

  @override
  Future<List<ArtistDiscographyGroup>> fetchArtistDiscography(MediaItem artist) {
    throw UnsupportedError('IPTV: fetchArtistDiscography not supported');
  }

  @override
  Future<List<MediaItem>> fetchAlbumTracks(String albumId) {
    throw UnsupportedError('IPTV: fetchAlbumTracks not supported');
  }

  @override
  Future<List<MediaItem>> fetchInstantMix(String itemId, {int limit = 100}) {
    throw UnsupportedError('IPTV: fetchInstantMix not supported');
  }

  @override
  Future<Lyrics?> fetchLyrics(MediaItem track) {
    throw UnsupportedError('IPTV: fetchLyrics not supported');
  }

  @override
  Future<List<MediaItem>> searchItems(
    String query, {
    int limit = 100,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    abort?.throwIfAborted();
    final results = <MediaItem>[];
    if (_isXtream) {
      final includeMovies = !excludedLibraryIds.contains(_moviesLibraryId);
      final includeSeries = !excludedLibraryIds.contains(_seriesLibraryId);
      if (includeMovies) {
        final streams = await _vodStreams();
        for (final stream in streams) {
          if (results.length >= limit) break;
          if (_isDisabled(stream.categoryId)) continue;
          if (stream.name.toLowerCase().contains(needle)) results.add(_movieItem(stream));
        }
      }
      if (includeSeries && results.length < limit) {
        final series = await _seriesList();
        for (final s in series) {
          if (results.length >= limit) break;
          if (_isDisabled(s.categoryId)) continue;
          if (s.name.toLowerCase().contains(needle)) results.add(_seriesItem(s));
        }
      }
      return results;
    }
    // M3U: the playlist is the catalog; channels surface as playable items.
    if (!excludedLibraryIds.contains(_liveLibraryId)) {
      final entries = await _m3uEntries();
      for (final entry in entries) {
        if (results.length >= limit) break;
        if (entry.name.toLowerCase().contains(needle)) {
          results.add(
            MediaItem.m3u(
              id: 'm3u:${entry.tvgId ?? entry.name}',
              kind: MediaKind.unknown,
              title: entry.name,
              thumbPath: entry.tvgLogo,
              streamUrl: entry.url,
              epgChannelId: entry.tvgId,
              categoryId: entry.groupTitle,
              libraryId: _liveLibraryId,
              libraryTitle: '$_name — Live TV',
              serverId: connection.id,
              serverName: _name,
            ),
          );
        }
      }
    }
    return results;
  }

  @override
  Future<List<MediaPerson>> searchPeople(
    String query, {
    int limit = defaultPeopleSearchLimit,
    AbortController? abort,
    Set<String> excludedLibraryIds = const {},
  }) {
    throw UnsupportedError('IPTV: searchPeople not supported');
  }

  @override
  Future<List<MediaItem>> fetchContinueWatching({int? count = 20, Set<String> excludedLibraryIds = const {}}) async {
    // Local watch state is a follow-up; return empty so home renders.
    return const [];
  }

  @override
  Future<List<MediaHub>> fetchGlobalHubs({
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    HubFetchDiagnostics? diagnostics,
  }) {
    throw UnsupportedError('IPTV: fetchGlobalHubs not supported');
  }

  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  }) {
    throw UnsupportedError('IPTV: fetchLibraryHubs not supported');
  }

  @override
  Future<List<MediaHub>> fetchRelatedHubs(String id, {int count = 10}) {
    throw UnsupportedError('IPTV: fetchRelatedHubs not supported');
  }

  @override
  Future<List<MediaItem>> fetchExtras(String id) {
    throw UnsupportedError('IPTV: fetchExtras not supported');
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPersonMediaPage(
    String personId, {
    int? start,
    int? size,
    AbortController? abort,
  }) {
    throw UnsupportedError('IPTV: fetchPersonMediaPage not supported');
  }

  @override
  Future<MediaPersonDetails> fetchPersonDetails(String personId, {AbortController? abort}) {
    throw UnsupportedError('IPTV: fetchPersonDetails not supported');
  }

  @override
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) {
    throw UnsupportedError('IPTV: fetchMoreHubItems not supported');
  }

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(String hubId, {int? start, int? size, AbortController? abort}) {
    throw UnsupportedError('IPTV: fetchMoreHubItemsPage not supported');
  }

  // Watch state / favorites are local-only for IPTV (no server API). The
  // mutations complete as no-ops for now so the UI heart does not crash;
  // real local persistence is a follow-up.
  @override
  Future<void> markWatched(MediaItem item) async {}

  @override
  Future<void> markUnwatched(MediaItem item) async {}

  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {}

  @override
  Future<void> rate(MediaItem item, double rating) async {}

  @override
  Future<void> setFavorite(MediaItem item, bool isFavorite) async {}

  @override
  Future<LibraryPage<MediaPlaylist>> fetchPlaylistsPage({
    String playlistType = 'video',
    bool? smart,
    int? start,
    int? size,
    AbortController? abort,
  }) {
    throw UnsupportedError('IPTV: fetchPlaylistsPage not supported');
  }

  @override
  Future<MediaPlaylist?> fetchPlaylistMetadata(String id) {
    throw UnsupportedError('IPTV: fetchPlaylistMetadata not supported');
  }

  @override
  Future<LibraryPage<MediaItem>> fetchPlaylistPage(String id, {int? start, int? size, AbortController? abort}) {
    throw UnsupportedError('IPTV: fetchPlaylistPage not supported');
  }

  @override
  Future<MediaPlaylist?> createPlaylist({required String title, required List<MediaItem> items}) {
    throw UnsupportedError('IPTV: createPlaylist not supported');
  }

  @override
  Future<bool> addToPlaylist({required String playlistId, required List<MediaItem> items}) {
    throw UnsupportedError('IPTV: addToPlaylist not supported');
  }

  @override
  Future<bool> deletePlaylist(MediaPlaylist playlist) {
    throw UnsupportedError('IPTV: deletePlaylist not supported');
  }

  @override
  Future<bool> movePlaylistItem({
    required String playlistId,
    required MediaItem item,
    required int newIndex,
    required MediaItem? afterItem,
  }) {
    throw UnsupportedError('IPTV: movePlaylistItem not supported');
  }

  @override
  Future<bool> removeFromPlaylist({required String playlistId, required MediaItem item}) {
    throw UnsupportedError('IPTV: removeFromPlaylist not supported');
  }

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionsPage(
    String libraryId, {
    int? start,
    int? size,
    AbortController? abort,
  }) {
    throw UnsupportedError('IPTV: fetchCollectionsPage not supported');
  }

  @override
  Future<LibraryPage<MediaItem>> fetchCollectionPage(
    String collectionId, {
    int? start,
    int? size,
    AbortController? abort,
    String? libraryId,
    String? libraryTitle,
  }) {
    throw UnsupportedError('IPTV: fetchCollectionPage not supported');
  }

  @override
  Future<List<CollectionMembership>> fetchCollectionMemberships(Set<String> itemIds, {AbortController? abort}) {
    throw UnsupportedError('IPTV: fetchCollectionMemberships not supported');
  }

  @override
  Future<String?> createCollection({
    required String libraryId,
    required String title,
    required List<MediaItem> items,
    MediaKind? itemKind,
  }) {
    throw UnsupportedError('IPTV: createCollection not supported');
  }

  @override
  Future<bool> addToCollection({required String collectionId, required List<MediaItem> items}) {
    throw UnsupportedError('IPTV: addToCollection not supported');
  }

  @override
  Future<bool> removeFromCollection({required String collectionId, required MediaItem item}) {
    throw UnsupportedError('IPTV: removeFromCollection not supported');
  }

  @override
  Future<bool> deleteCollection(MediaItem collection) {
    throw UnsupportedError('IPTV: deleteCollection not supported');
  }

  @override
  Future<bool> deleteMediaItem(MediaItem item) {
    throw UnsupportedError('IPTV: deleteMediaItem not supported');
  }

  @override
  Future<MediaFileInfo?> getFileInfo(MediaItem item) {
    throw UnsupportedError('IPTV: getFileInfo not supported');
  }

  @override
  String thumbnailUrl(String? path, {int? width, int? height, bool cover = true}) => path ?? '';

  @override
  String externalImageUrl(String url, {int? width, int? height, bool cover = true}) => url;

  @override
  Future<ExternalIds> fetchExternalIds(String itemId) async => const ExternalIds();

  @override
  Future<List<MediaItem>?> findByExternalIds(
    ExternalIds ids, {
    required MediaKind kind,
    List<String> titles = const [],
    int? year,
    String? plexGuid,
    ExternalSeasonRef? season,
  }) async => null;

  @override
  Future<PlaybackExtras> fetchPlaybackExtras(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
    bool forceRefresh = false,
  }) async => PlaybackExtras(chapters: const [], markers: const []);

  @override
  Future<PlaybackExtras?> fetchPlaybackExtrasFromCacheOnly(
    String itemId, {
    String? introPattern,
    String? creditsPattern,
    bool forceChapterFallback = false,
  }) async => null;

  @override
  Future<MediaSourceInfo?> fetchCachedMediaSourceInfo(
    String itemId, {
    int mediaIndex = 0,
    String? mediaSourceId,
    String? preferredVersionSignature,
  }) async => null;

  @override
  Future<ScrubPreviewSource?> createScrubPreviewSource({required MediaItem item, required MediaSourceInfo mediaSource}) {
    throw UnsupportedError('IPTV: createScrubPreviewSource not supported');
  }

  @override
  Future<void> reportPlaybackStarted({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {}

  @override
  Future<void> reportPlaybackProgress({
    required String itemId,
    required Duration position,
    required Duration duration,
    bool isPaused = false,
    String? playSessionId,
    String? playMethod,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {}

  @override
  Future<void> reportPlaybackStopped({
    required String itemId,
    required Duration position,
    Duration? duration,
    String? playSessionId,
    String? liveStreamId,
    String? mediaSourceId,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
    PlaybackReportMetadata report = const PlaybackReportMetadata.live(),
  }) async {}

  @override
  Future<PlaybackInitializationResult> getPlaybackInitialization(PlaybackInitializationOptions options) async {
    final item = options.metadata;
    final streamUrl = switch (item) {
      M3uMediaItem(:final streamUrl) || XtreamMediaItem(:final streamUrl) => streamUrl,
      _ => null,
    };
    if (streamUrl == null || streamUrl.isEmpty) {
      throw PlaybackException('No playable IPTV stream for this item', reason: PlaybackFailureReason.noPlayableSource);
    }
    final mediaInfo = MediaSourceInfo(
      videoUrl: streamUrl,
      audioTracks: const [],
      subtitleTracks: const [],
      chapters: const [],
    );
    return PlaybackInitializationResult(
      availableVersions: [MediaVersion(id: item.id)],
      videoUrl: streamUrl,
      mediaInfo: mediaInfo,
      isTranscoding: false,
      selectedMediaIndex: 0,
    );
  }

  @override
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) {
    throw UnsupportedError('IPTV: resolveDownload not supported');
  }

  @override
  Future<MediaItem> stampLibrary(MediaItem item) async => item;

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) => const [];

  @override
  Future<ExternalPlaybackTarget?> resolveExternalPlayback(
    MediaItem item, {
    int mediaIndex = 0,
    String? mediaSourceId,
    Duration? position,
  }) async {
    final streamUrl = switch (item) {
      M3uMediaItem(:final streamUrl) || XtreamMediaItem(:final streamUrl) => streamUrl,
      _ => null,
    };
    if (streamUrl == null || streamUrl.isEmpty) return null;
    return ExternalPlaybackTarget(url: streamUrl);
  }

  // -- Live TV helpers (used by IptvLiveTvSupport) --------------------------

  /// Live channels as [LiveTvChannel]s, with stream info cached by key for
  /// [startPlayback]. The provider returns the whole list in one call;
  /// callers page it — this method itself does not slice.
  Future<List<LiveTvChannel>> iptvChannels() async {
    if (_isXtream) {
      final streams = await _liveStreams();
      final channels = <LiveTvChannel>[];
      for (final stream in streams) {
        if (_isDisabled(stream.categoryId)) continue;
        _xtreamChannelByKey['${stream.streamId}'] = stream;
        channels.add(
          LiveTvChannel(
            key: '${stream.streamId}',
            identifier: stream.epgChannelId,
            title: stream.name,
            thumb: stream.streamIcon,
            serverId: connection.id,
            serverName: _name,
          ),
        );
      }
      return channels;
    }
    final entries = await _m3uEntries();
    final channels = <LiveTvChannel>[];
    for (final entry in entries) {
      final key = entry.tvgId ?? entry.url;
      _m3uChannelByKey[key] = entry;
      channels.add(
        LiveTvChannel(
          key: key,
          identifier: entry.tvgId,
          title: entry.name,
          thumb: entry.tvgLogo,
          serverId: connection.id,
          serverName: _name,
        ),
      );
    }
    return channels;
  }

  /// Direct live URL for a channel key (throws when unknown).
  String liveUrlForChannelKey(String key) {
    if (_isXtream) {
      return _xtreamApi.liveStreamUrl(key);
    }
    final entry = _m3uChannelByKey[key];
    if (entry == null) throw UnsupportedError('IPTV: unknown M3U channel key $key');
    return entry.url;
  }

  /// Catch-up info for a channel key. Null when the channel has no archive
  /// (M3U never does; Xtream only when tv_archive = 1).
  ({int streamId, int archiveDurationSeconds})? archiveInfoForChannelKey(String key) {
    if (!_isXtream) return null;
    final stream = _xtreamChannelByKey[key];
    if (stream == null || !stream.tvArchive) return null;
    return (streamId: stream.streamId, archiveDurationSeconds: stream.tvArchiveDuration);
  }

  /// Catch-up URL for a channel key at [start] (programme start), with a
  /// [durationMinutes] window. Xtream only.
  String timeshiftUrlForChannelKey(String key, DateTime start, int durationMinutes) {
    return _xtreamApi.timeshiftUrl(streamId: key, durationMinutes: durationMinutes, start: start);
  }
}
