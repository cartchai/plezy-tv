import 'dart:async';

import 'package:flutter/foundation.dart';
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
import '../services/iptv/iptv_item_favorites_repository.dart';
import '../services/iptv/m3u_parser.dart';
import '../services/iptv/xtream_api.dart';

/// One provider category (a Trex grouping) with its item count, for the
/// Categories tab that replaces Collections for IPTV libraries.
class IptvCategory {
  final String id;
  final String name;
  final int? itemCount;

  const IptvCategory({required this.id, required this.name, this.itemCount});
}

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

  /// Public view of the Xtream API for the live-TV support (EPG fetches).
  XtreamApi get xtreamApi => _xtreamApi;

  /// The tvg-id of the M3U entry behind [channelKey] (the key IS the tvg-id
  /// when the entry has one), or null when the channel has no tvg-id or is
  /// not an M3U channel. The EPG layer matches XMLTV `<programme>` rows
  /// against this id.
  String? tvgIdForChannelKey(String channelKey) => _m3uChannelByKey[channelKey]?.tvgId;

  /// The tvg-id (`epg_channel_id`) of the Xtream channel behind
  /// [channelKey], for matching the xmltv.php feed (some panels use the
  /// stream id as the XMLTV channel id, so the guide path also tries the
  /// key itself). Null when the channel is not a known Xtream channel.
  String? epgChannelIdForChannelKey(String channelKey) => _xtreamChannelByKey[channelKey]?.epgChannelId;

  /// Test-only override for the Xtream API, so unit tests can stub the
  /// catalog instead of hitting the network. Production code never sets this.
  @visibleForTesting
  set testXtreamApi(XtreamApi api) => _api = api;

  http.Client _http = http.Client();
  final Object _authSessionId = Object();

  /// Test-only override for the HTTP client, so unit tests can serve a
  /// canned M3U playlist instead of hitting the network. Production code
  /// never sets this.
  @visibleForTesting
  set testHttpClient(http.Client client) => _http = client;
  bool _offline = false;
  late final IptvLiveTvSupport _liveTv = IptvLiveTvSupport(this);

  // In-memory catalog caches (lazy; the provider lists are large).
  Future<List<XtreamLiveStream>>? _liveStreamsFuture;
  Future<List<XtreamVodStream>>? _vodStreamsFuture;
  Future<List<XtreamSeries>>? _seriesFuture;
  Future<List<XtreamCategory>>? _vodCategoriesFuture;
  Future<List<XtreamCategory>>? _seriesCategoriesFuture;
  Future<List<M3uEntry>>? _m3uEntriesFuture;

  // Category-name lookups (id -> name), for stripping the provider's
  // category tag from display titles. Fail open to {} when the list
  // cannot be fetched — titles just keep their prefixes.
  Future<Map<String, String>>? _vodCategoryNamesFuture;
  Future<Map<String, String>>? _seriesCategoryNamesFuture;

  // Favourited VOD/series items (id -> snapshot), persisted per
  // connection. Loaded lazily; setFavorite updates the cached map so
  // browse/search/detail all agree without re-reading prefs.
  IptvItemFavoritesRepository _itemFavoritesRepository =
      const SharedPreferencesIptvItemFavoritesRepository();
  Future<Map<String, IptvFavoriteItem>>? _favoriteItemsFuture;

  /// Test-only override for the favourites repository, so unit tests can
  /// share one store across client instances. Production code never sets
  /// this.
  @visibleForTesting
  set testItemFavoritesRepository(IptvItemFavoritesRepository repository) {
    _itemFavoritesRepository = repository;
    _favoriteItemsFuture = null;
  }

  /// Prefs key for this connection's favourited VOD/series items.
  String get _itemFavoritesKey => 'iptv_fav_items:${connection.id}';

  Future<Map<String, IptvFavoriteItem>> _favoriteItems() =>
      _favoriteItemsFuture ??= _itemFavoritesRepository.read(key: _itemFavoritesKey);

  /// Concurrent per-category fallback batch size (Task 8): the panel
  /// answers per-category calls even when the unfiltered call returns [].
  static const int _catalogFallbackBatchSize = 8;

  /// Live-channel stream info by channel key (populated by [iptvChannels]).
  final Map<String, XtreamLiveStream> _xtreamChannelByKey = {};
  final Map<String, M3uEntry> _m3uChannelByKey = {};

  static const String liveLibrarySuffix = 'live';
  static const String moviesLibrarySuffix = 'movies';
  static const String seriesLibrarySuffix = 'series';

  String _libraryId(String suffix) => 'iptv:${connection.id}:$suffix';

  /// Internal attribution id for M3U channel items (fetchItem/searchItems).
  /// It is NOT a library anymore — fetchLibraries never returns it — so
  /// the library picker never shows a Live TV row.
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

  /// Drop the in-memory catalog caches so the next browse/guide load
  /// re-fetches channels, movies and series from the provider (the
  /// "Refresh playlists" action in IPTV settings). An in-flight fetch is
  /// not cancelled; its result is simply discarded.
  void clearCatalogCache() {
    _liveStreamsFuture = null;
    _vodStreamsFuture = null;
    _seriesFuture = null;
    _vodCategoriesFuture = null;
    _seriesCategoriesFuture = null;
    _m3uEntriesFuture = null;
    _vodCategoryNamesFuture = null;
    _seriesCategoryNamesFuture = null;
    _favoriteItemsFuture = null;
    _xtreamChannelByKey.clear();
    _m3uChannelByKey.clear();
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

  Future<List<XtreamVodStream>> _vodStreams() async {
    final cached = _vodStreamsFuture;
    if (cached != null) return cached;
    final future = _loadVodStreams().catchError((Object e) {
      _vodStreamsFuture = null;
      throw e;
    });
    _vodStreamsFuture = future;
    final result = await future;
    // An empty result is never cached: a transient empty payload (this
    // panel returns [] for the unfiltered call at 199k rows) must not
    // poison every later view until restart.
    if (result.isEmpty) _vodStreamsFuture = null;
    return result;
  }

  /// Unfiltered first (the fast path when the panel answers); when it
  /// returns [], fall back to a per-category fetch — the panel answers
  /// per-category calls even when the unfiltered call is empty.
  Future<List<XtreamVodStream>> _loadVodStreams() async {
    final all = await _xtreamApi.getVodStreams();
    if (all.isNotEmpty) return all;
    final categories = await _vodCategories().catchError((Object e) {
      appLogger.w('IPTV: VOD category list unavailable for fallback: $e');
      return const <XtreamCategory>[];
    });
    final wanted = categories.where((c) => !_isDisabled(c.id)).toList(growable: false);
    if (wanted.isEmpty) return const [];
    final out = <XtreamVodStream>[];
    final seen = <int>{};
    for (var i = 0; i < wanted.length; i += _catalogFallbackBatchSize) {
      final end = (i + _catalogFallbackBatchSize).clamp(0, wanted.length);
      final batch = wanted.sublist(i, end);
      final results = await Future.wait(
        batch.map(
          (c) => _xtreamApi.getVodStreams(categoryId: c.id).catchError((Object e) {
            appLogger.w('IPTV: VOD category ${c.id} unavailable: $e');
            return const <XtreamVodStream>[];
          }),
        ),
      );
      for (final rows in results) {
        for (final row in rows) {
          if (seen.add(row.streamId)) out.add(row);
        }
      }
    }
    return out;
  }

  Future<List<XtreamSeries>> _seriesList() async {
    final cached = _seriesFuture;
    if (cached != null) return cached;
    final future = _loadSeries().catchError((Object e) {
      _seriesFuture = null;
      throw e;
    });
    _seriesFuture = future;
    final result = await future;
    if (result.isEmpty) _seriesFuture = null;
    return result;
  }

  /// Same empty-unfiltered fallback as [_loadVodStreams], for series.
  Future<List<XtreamSeries>> _loadSeries() async {
    final all = await _xtreamApi.getSeries();
    if (all.isNotEmpty) return all;
    final categories = await _seriesCategories().catchError((Object e) {
      appLogger.w('IPTV: series category list unavailable for fallback: $e');
      return const <XtreamCategory>[];
    });
    final wanted = categories.where((c) => !_isDisabled(c.id)).toList(growable: false);
    if (wanted.isEmpty) return const [];
    final out = <XtreamSeries>[];
    final seen = <int>{};
    for (var i = 0; i < wanted.length; i += _catalogFallbackBatchSize) {
      final end = (i + _catalogFallbackBatchSize).clamp(0, wanted.length);
      final batch = wanted.sublist(i, end);
      final results = await Future.wait(
        batch.map(
          (c) => _xtreamApi.getSeries(categoryId: c.id).catchError((Object e) {
            appLogger.w('IPTV: series category ${c.id} unavailable: $e');
            return const <XtreamSeries>[];
          }),
        ),
      );
      for (final rows in results) {
        for (final row in rows) {
          if (seen.add(row.seriesId)) out.add(row);
        }
      }
    }
    return out;
  }

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

  /// Category id -> name for VOD, for stripping the provider's category
  /// tag from display titles. Fails open to {} — titles just keep their
  /// prefixes when the list cannot be fetched.
  Future<Map<String, String>> _vodCategoryNames() async {
    final cached = _vodCategoryNamesFuture;
    if (cached != null) return cached;
    final future = _vodCategories().then(
      (categories) => {for (final c in categories) c.id: c.name},
      onError: (Object e) {
        _vodCategoryNamesFuture = null;
        appLogger.w('IPTV: VOD category names unavailable: $e');
        return const <String, String>{};
      },
    );
    _vodCategoryNamesFuture = future;
    return future;
  }

  /// Category id -> name for series, same fail-open contract as
  /// [_vodCategoryNames].
  Future<Map<String, String>> _seriesCategoryNames() async {
    final cached = _seriesCategoryNamesFuture;
    if (cached != null) return cached;
    final future = _seriesCategories().then(
      (categories) => {for (final c in categories) c.id: c.name},
      onError: (Object e) {
        _seriesCategoryNamesFuture = null;
        appLogger.w('IPTV: series category names unavailable: $e');
        return const <String, String>{};
      },
    );
    _seriesCategoryNamesFuture = future;
    return future;
  }

  /// Strips a leading "`<categoryName> - `" from a display title, but only
  /// when it duplicates the item's OWN category — the provider bakes its
  /// category tag into names (e.g. "NF - Alice" in the NF category). A
  /// prefix from another category is left alone, and a title that would
  /// be left empty keeps its original form. Case-insensitive.
  @visibleForTesting
  static String stripCategoryPrefix(String title, String? categoryName) {
    if (categoryName == null || categoryName.isEmpty) return title;
    final prefix = '$categoryName - ';
    if (title.length <= prefix.length) return title;
    if (!title.toLowerCase().startsWith(prefix.toLowerCase())) return title;
    final stripped = title.substring(prefix.length);
    return stripped.isEmpty ? title : stripped;
  }

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
    // Live TV is NOT a library: channels are served only through liveTv
    // (the Live TV tab). Only on-demand catalogs become libraries, so the
    // library picker never shows a "Live TV" row. M3U has no on-demand
    // catalog, so it exposes no libraries at all.
    //
    // The "omit this library when ALL its categories are disabled" check
    // needs two provider round trips. Those run in parallel with a short
    // fail-open timeout: the library list itself must never depend on the
    // provider being fast — the aggregation service drops a server whose
    // library fetch misses its 15s deadline, which would hide the whole
    // Trex section. Content-level filtering (in _moviesItems/_seriesItems)
    // still hides disabled categories even when this probe fails open.
    final name = _name;
    final libraries = <MediaLibrary>[];
    if (_isXtream) {
      var allVodDisabled = false;
      var allSeriesDisabled = false;
      if (_disabledCategories.isNotEmpty) {
        final results = await Future.wait([
          _allCategoriesDisabled(_vodCategories),
          _allCategoriesDisabled(_seriesCategories),
        ]).timeout(const Duration(seconds: 5), onTimeout: () => [false, false]);
        allVodDisabled = results[0];
        allSeriesDisabled = results[1];
      }
      if (!allVodDisabled) {
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
      if (!allSeriesDisabled) {
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

  MediaItem _movieItem(XtreamVodStream stream, {bool isFavorite = false, String? categoryName}) {
    final url = _xtreamApi.movieStreamUrl('${stream.streamId}', stream.containerExtension);
    return MediaItem.xtream(
      id: 'movie:${stream.streamId}',
      kind: MediaKind.movie,
      title: stripCategoryPrefix(stream.name, categoryName),
      thumbPath: stream.cover ?? stream.streamIcon,
      rating: stream.rating,
      streamUrl: url,
      categoryId: stream.categoryId,
      libraryId: _moviesLibraryId,
      libraryTitle: '$_name — Movies',
      serverId: connection.id,
      serverName: _name,
      isFavorite: isFavorite,
    );
  }

  MediaItem _seriesItem(XtreamSeries series, {bool isFavorite = false, String? categoryName}) {
    return MediaItem.xtream(
      id: 'series:${series.seriesId}',
      kind: MediaKind.show,
      title: stripCategoryPrefix(series.name, categoryName),
      summary: series.plot,
      thumbPath: series.cover,
      rating: series.rating,
      categoryId: series.categoryId,
      libraryId: _seriesLibraryId,
      libraryTitle: '$_name — Series',
      serverId: connection.id,
      serverName: _name,
      isFavorite: isFavorite,
    );
  }

  MediaItem _episodeItem(
    XtreamSeries series,
    XtreamEpisode episode,
    int season, {
    bool isFavorite = false,
    String? seriesCategoryName,
  }) {
    final url = _xtreamApi.seriesStreamUrl('${episode.id}', episode.containerExtension);
    return MediaItem.xtream(
      id: 'episode:${series.seriesId}:${episode.id}',
      kind: MediaKind.episode,
      title: episode.title.isEmpty ? 'Episode ${episode.episodeNum}' : episode.title,
      summary: episode.plot,
      parentId: 'series:${series.seriesId}',
      parentTitle: stripCategoryPrefix(series.name, seriesCategoryName),
      parentIndex: season,
      index: episode.episodeNum,
      durationMs: episode.durationSeconds == null ? null : episode.durationSeconds! * 1000,
      streamUrl: url,
      categoryId: series.categoryId,
      libraryId: _seriesLibraryId,
      libraryTitle: '$_name — Series',
      serverId: connection.id,
      serverName: _name,
      isFavorite: isFavorite,
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

  /// Full Movies catalog as items, with disabled categories removed.
  /// Shared by the paged browse and the Recommended hub so both agree.
  Future<List<MediaItem>> _moviesItems() async {
    final streams = await _vodStreams();
    final favorites = await _favoriteItems();
    final categoryNames = await _vodCategoryNames();
    return streams
        .where((s) => !_isDisabled(s.categoryId))
        .map(
          (s) => _movieItem(
            s,
            isFavorite: favorites.containsKey('movie:${s.streamId}'),
            categoryName: categoryNames[s.categoryId],
          ),
        )
        .toList();
  }

  /// Full Series catalog as items, with disabled categories removed.
  Future<List<MediaItem>> _seriesItems() async {
    final series = await _seriesList();
    final favorites = await _favoriteItems();
    final categoryNames = await _seriesCategoryNames();
    return series
        .where((s) => !_isDisabled(s.categoryId))
        .map(
          (s) => _seriesItem(
            s,
            isFavorite: favorites.containsKey('series:${s.seriesId}'),
            categoryName: categoryNames[s.categoryId],
          ),
        )
        .toList();
  }

  MediaHub _recommendedHub({
    required String libraryId,
    required String title,
    required String type,
    required List<MediaItem> all,
    required int limit,
  }) {
    final items = all.take(limit).toList();
    return MediaHub(
      id: 'iptv:$libraryId:recommended',
      title: title,
      type: type,
      items: items,
      size: all.length,
      more: all.length > items.length,
      libraryId: libraryId,
      serverId: connection.id,
      serverName: _name,
    );
  }

  @override
  Future<LibraryPage<MediaItem>> fetchLibraryPagedContent(
    String libraryId, {
    required LibraryQuery query,
    MediaKind? libraryKind,
    AbortController? abort,
  }) async {
    if (!_isXtream) return const LibraryPage(items: [], totalCount: 0);
    abort?.throwIfAborted();
    if (libraryId == _moviesLibraryId) {
      return _page(_applyQueryFilters(await _moviesItems(), query), query);
    }
    if (libraryId == _seriesLibraryId) {
      return _page(_applyQueryFilters(await _seriesItems(), query), query);
    }
    return const LibraryPage(items: [], totalCount: 0);
  }

  @override
  Future<LibraryFilterResult> fetchLibraryFiltersWithValues(String libraryId, {MediaKind? libraryKind}) async {
    return LibraryFilterResult.empty;
  }

  /// Provider categories for a library, with item counts — VOD categories
  /// in Movies, series categories in TV/Series. This is what the
  /// Categories tab (which replaces Collections for IPTV) lists. Disabled
  /// categories are omitted. An unknown library id, or M3U (no on-demand
  /// libraries), returns no categories. The counts fail open to null when
  /// the catalog cannot be fetched; a category-list failure throws so the
  /// tab shows its retryable error state.
  Future<List<IptvCategory>> iptvCategoriesForLibrary(String libraryId) async {
    if (!_isXtream) return const [];
    if (libraryId == _moviesLibraryId) {
      final categories = await _vodCategories();
      final streams = await _vodStreams().catchError((Object e) {
        appLogger.w('IPTV: VOD catalog unavailable for category counts: $e');
        return const <XtreamVodStream>[];
      });
      final counts = <String, int>{};
      for (final stream in streams) {
        final id = stream.categoryId;
        if (id != null) counts[id] = (counts[id] ?? 0) + 1;
      }
      return categories
          .where((c) => !_isDisabled(c.id))
          .map((c) => IptvCategory(id: c.id, name: c.name, itemCount: counts[c.id]))
          .toList();
    }
    if (libraryId == _seriesLibraryId) {
      final categories = await _seriesCategories();
      final series = await _seriesList().catchError((Object e) {
        appLogger.w('IPTV: series catalog unavailable for category counts: $e');
        return const <XtreamSeries>[];
      });
      final counts = <String, int>{};
      for (final s in series) {
        final id = s.categoryId;
        if (id != null) counts[id] = (counts[id] ?? 0) + 1;
      }
      return categories
          .where((c) => !_isDisabled(c.id))
          .map((c) => IptvCategory(id: c.id, name: c.name, itemCount: counts[c.id]))
          .toList();
    }
    return const [];
  }

  /// Items in one category of a library, for the Categories tab.
  Future<List<MediaItem>> iptvItemsForCategory(String libraryId, String categoryId) async {
    if (!_isXtream) return const [];
    if (libraryId == _moviesLibraryId) {
      final streams = await _vodStreams();
      final favorites = await _favoriteItems();
      final categoryNames = await _vodCategoryNames();
      return streams
          .where((s) => s.categoryId == categoryId && !_isDisabled(s.categoryId))
          .map(
            (s) => _movieItem(
              s,
              isFavorite: favorites.containsKey('movie:${s.streamId}'),
              categoryName: categoryNames[s.categoryId],
            ),
          )
          .toList();
    }
    if (libraryId == _seriesLibraryId) {
      final series = await _seriesList();
      final favorites = await _favoriteItems();
      final categoryNames = await _seriesCategoryNames();
      return series
          .where((s) => s.categoryId == categoryId && !_isDisabled(s.categoryId))
          .map(
            (s) => _seriesItem(
              s,
              isFavorite: favorites.containsKey('series:${s.seriesId}'),
              categoryName: categoryNames[s.categoryId],
            ),
          )
          .toList();
    }
    return const [];
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
        if (stream == null) return null;
        final movieFavorites = await _favoriteItems();
        final vodCategoryNames = await _vodCategoryNames();
        return _movieItem(
          stream,
          isFavorite: movieFavorites.containsKey('movie:${stream.streamId}'),
          categoryName: vodCategoryNames[stream.categoryId],
        );
      case 'series':
        final seriesId = int.tryParse(parts[1]);
        if (seriesId == null) return null;
        final series = await _seriesList();
        final found = series.where((s) => s.seriesId == seriesId).firstOrNull;
        if (found == null) return null;
        final seriesFavorites = await _favoriteItems();
        final seriesCategoryNames = await _seriesCategoryNames();
        return _seriesItem(
          found,
          isFavorite: seriesFavorites.containsKey('series:${found.seriesId}'),
          categoryName: seriesCategoryNames[found.categoryId],
        );
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
          final episodeFavorites = await _favoriteItems();
          final episodeCategoryNames = await _seriesCategoryNames();
          return _episodeItem(
            series,
            episode,
            seasonEntry.key,
            isFavorite: episodeFavorites.containsKey('episode:${series.seriesId}:${episode.id}'),
            seriesCategoryName: episodeCategoryNames[series.categoryId],
          );
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
    final favorites = await _favoriteItems();
    final categoryNames = await _seriesCategoryNames();
    final seriesCategoryName = categoryNames[series.categoryId];
    for (final season in seasons) {
      // Sort a copy: the info object's lists are shared state (and may be
      // unmodifiable), so sorting them in place mutates the cache.
      final seasonEpisodes = info.episodesBySeason[season]!.toList()
        ..sort((a, b) => a.episodeNum.compareTo(b.episodeNum));
      for (final episode in seasonEpisodes) {
        episodes.add(
          _episodeItem(
            series,
            episode,
            season,
            isFavorite: favorites.containsKey('episode:${series.seriesId}:${episode.id}'),
            seriesCategoryName: seriesCategoryName,
          ),
        );
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
    if (_isXtream) {
      final includeMovies = !excludedLibraryIds.contains(_moviesLibraryId);
      final includeSeries = !excludedLibraryIds.contains(_seriesLibraryId);
      // Sections fetch concurrently and fail open on their own: a movies
      // failure must not kill series results (and vice versa), and a cold
      // search costs max(movies, series), not the sum — the old sequential
      // awaits behind the 20s search leg deadline returned zero IPTV
      // results on a slow connection.
      final sections = await Future.wait([
        if (includeMovies) _searchMovies(needle, limit) else Future.value(const <MediaItem>[]),
        if (includeSeries) _searchSeries(needle, limit) else Future.value(const <MediaItem>[]),
      ]);
      final out = <MediaItem>[];
      for (final section in sections) {
        for (final item in section) {
          if (out.length >= limit) break;
          out.add(item);
        }
        if (out.length >= limit) break;
      }
      return out;
    }
    // M3U: the playlist is the catalog; channels surface as playable items.
    return _searchM3uEntries(needle, limit, excludedLibraryIds);
  }

  Future<List<MediaItem>> _searchMovies(String needle, int limit) async {
    try {
      final streams = await _vodStreams();
      final favorites = await _favoriteItems();
      final categoryNames = await _vodCategoryNames();
      final out = <MediaItem>[];
      for (final stream in streams) {
        if (out.length >= limit) break;
        if (_isDisabled(stream.categoryId)) continue;
        if (!stream.name.toLowerCase().contains(needle)) continue;
        out.add(
          _movieItem(
            stream,
            isFavorite: favorites.containsKey('movie:${stream.streamId}'),
            categoryName: categoryNames[stream.categoryId],
          ),
        );
      }
      return out;
    } catch (e) {
      appLogger.w('IPTV: movie search failed: $e');
      return const [];
    }
  }

  Future<List<MediaItem>> _searchSeries(String needle, int limit) async {
    try {
      final series = await _seriesList();
      final favorites = await _favoriteItems();
      final categoryNames = await _seriesCategoryNames();
      final out = <MediaItem>[];
      for (final s in series) {
        if (out.length >= limit) break;
        if (_isDisabled(s.categoryId)) continue;
        if (!s.name.toLowerCase().contains(needle)) continue;
        out.add(
          _seriesItem(
            s,
            isFavorite: favorites.containsKey('series:${s.seriesId}'),
            categoryName: categoryNames[s.categoryId],
          ),
        );
      }
      return out;
    } catch (e) {
      appLogger.w('IPTV: series search failed: $e');
      return const [];
    }
  }

  Future<List<MediaItem>> _searchM3uEntries(
    String needle,
    int limit,
    Set<String> excludedLibraryIds,
  ) async {
    if (excludedLibraryIds.contains(_liveLibraryId)) return const [];
    try {
      final entries = await _m3uEntries();
      final out = <MediaItem>[];
      for (final entry in entries) {
        if (out.length >= limit) break;
        // Disabled groups (country/region filter) stay out of search too.
        if (_isDisabled(entry.groupTitle)) continue;
        if (!entry.name.toLowerCase().contains(needle)) continue;
        out.add(
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
      return out;
    } catch (e) {
      appLogger.w('IPTV: M3U search failed: $e');
      return const [];
    }
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
  }) async {
    // Home shows one Recommended-style hub per on-demand library, titled
    // with the library name so two IPTV sources stay distinguishable.
    // M3U has no on-demand catalog, so it contributes nothing.
    if (!_isXtream) return const [];
    final hubs = <MediaHub>[];
    final movies = await _moviesItems();
    if (movies.isNotEmpty) {
      hubs.add(
        _recommendedHub(
          libraryId: _moviesLibraryId,
          title: '$_name — Movies',
          type: 'movie',
          all: movies,
          limit: limit,
        ),
      );
    }
    // Fail open per section: a series catalog failure (network, malformed
    // rows) must not take the Movies hub down with it — the per-library
    // fetch path already isolates the two, so the home path must too.
    try {
      final series = await _seriesItems();
      if (series.isNotEmpty) {
        hubs.add(
          _recommendedHub(
            libraryId: _seriesLibraryId,
            title: '$_name — Series',
            type: 'show',
            all: series,
            limit: limit,
          ),
        );
      }
    } catch (e) {
      appLogger.w('IPTV: series hub skipped after catalog failure: $e');
    }
    return hubs;
  }

  @override
  Future<List<MediaHub>> fetchLibraryHubs(
    String libraryId, {
    required String libraryName,
    int limit = defaultHubPreviewLimit,
    bool includePlaybackHubs = true,
    MediaKind? libraryKind,
    HubFetchDiagnostics? diagnostics,
  }) async {
    // The Recommended tab renders whatever hubs come back; throwing here
    // surfaced as "Unable to load Recommended", so always return the one
    // hub the library actually has (or nothing when it has none).
    if (!_isXtream) return const [];
    if (libraryId == _moviesLibraryId) {
      final movies = await _moviesItems();
      if (movies.isEmpty) return const [];
      return [
        _recommendedHub(libraryId: libraryId, title: 'Recommended', type: 'movie', all: movies, limit: limit),
      ];
    }
    if (libraryId == _seriesLibraryId) {
      final series = await _seriesItems();
      if (series.isEmpty) return const [];
      return [
        _recommendedHub(libraryId: libraryId, title: 'Recommended', type: 'show', all: series, limit: limit),
      ];
    }
    return const [];
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
  Future<List<MediaItem>> fetchMoreHubItems(String hubId, {int? limit}) async {
    // Hubs built by [_recommendedHub] carry their library id, so expanding
    // one just re-runs that library's catalog (already cached in memory).
    if (!_isXtream) return const [];
    final all = await _itemsForHubId(hubId);
    if (all == null) return const [];
    return limit == null ? all : all.take(limit).toList();
  }

  @override
  Future<LibraryPage<MediaItem>> fetchMoreHubItemsPage(
    String hubId, {
    int? start,
    int? size,
    AbortController? abort,
  }) async {
    if (!_isXtream) return const LibraryPage(items: [], totalCount: 0);
    final all = await _itemsForHubId(hubId);
    if (all == null) return const LibraryPage(items: [], totalCount: 0);
    final offset = (start ?? 0).clamp(0, all.length);
    final end = size == null ? all.length : (offset + size).clamp(0, all.length);
    return LibraryPage(items: all.sublist(offset, end), totalCount: all.length, offset: offset);
  }

  /// Full item list for a hub built by [_recommendedHub], or null when the
  /// hub id is not one of ours.
  Future<List<MediaItem>?> _itemsForHubId(String hubId) async {
    if (hubId.contains(_moviesLibraryId)) return _moviesItems();
    if (hubId.contains(_seriesLibraryId)) return _seriesItems();
    return null;
  }

  // Watch state is local-only for IPTV (no server API). markWatched /
  // rate stay no-ops; setFavorite persists (Task 1) so the heart sticks.
  @override
  Future<void> markWatched(MediaItem item) async {}

  @override
  Future<void> markUnwatched(MediaItem item) async {}

  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {}

  @override
  Future<void> rate(MediaItem item, double rating) async {}

  @override
  Future<void> setFavorite(MediaItem item, bool isFavorite) async {
    // Only M3U/Xtream movies, shows and episodes can be favourited.
    // Anything else (a live channel, a track, an item from another
    // backend) is a no-op so the heart never crashes.
    final kind = switch (item) {
      M3uMediaItem(:final kind) || XtreamMediaItem(:final kind) => kind,
      _ => null,
    };
    if (kind != MediaKind.movie && kind != MediaKind.show && kind != MediaKind.episode) return;
    final current = Map<String, IptvFavoriteItem>.of(await _favoriteItems());
    if (isFavorite) {
      current[item.id] = IptvFavoriteItem(
        id: item.id,
        kind: switch (kind) {
          MediaKind.movie => 'movie',
          MediaKind.show => 'show',
          MediaKind.episode => 'episode',
          _ => 'movie',
        },
        title: item.title,
        thumbPath: item.thumbPath,
        libraryId: item.libraryId,
        parentId: item.parentId,
        parentTitle: item.parentTitle,
      );
    } else {
      current.remove(item.id);
    }
    await _itemFavoritesRepository.write(_itemFavoritesKey, current);
    // Swap the cached read for the new map so browse/search/detail stamp
    // the new state without re-reading prefs.
    _favoriteItemsFuture = Future.value(current);
  }

  /// Favourited movies/series/episodes as [MediaItem]s, newest first.
  /// Each id is re-resolved against the catalog (fresh titles/posters);
  /// an item that left the catalog renders from its stored snapshot.
  Future<List<MediaItem>> favoriteItems() async {
    final saved = await _favoriteItems();
    if (saved.isEmpty) return const [];
    final out = <MediaItem>[];
    for (final snapshot in saved.values.toList().reversed) {
      final resolved = await _resolveFavoriteItem(snapshot);
      if (resolved != null) out.add(resolved);
    }
    return out;
  }

  Future<MediaItem?> _resolveFavoriteItem(IptvFavoriteItem snapshot) async {
    MediaItem? item;
    try {
      item = await fetchItem(snapshot.id);
    } catch (e) {
      // A catalog failure for one favourite must not kill the list —
      // the snapshot below is the fallback.
      appLogger.w('IPTV: favourite ${snapshot.id} could not re-resolve: $e');
    }
    if (item != null) return item;
    final kind = switch (snapshot.kind) {
      'movie' => MediaKind.movie,
      'show' => MediaKind.show,
      'episode' => MediaKind.episode,
      _ => null,
    };
    if (kind == null) return null;
    return MediaItem.xtream(
      id: snapshot.id,
      kind: kind,
      title: snapshot.title,
      thumbPath: snapshot.thumbPath,
      libraryId: snapshot.libraryId,
      parentId: snapshot.parentId,
      parentTitle: snapshot.parentTitle,
      isFavorite: true,
    );
  }

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
  Future<DownloadResolution> resolveDownload(MediaItem item, {int mediaIndex = 0, String? mediaSourceId}) async {
    // The direct stream URL IS the file (the same URL playback uses), so
    // a download is just a fetch of it. A show has no file, and a .m3u8
    // URL is a playlist, not a file — both resolve to null and let the
    // pipeline's existing retry-then-fail path handle them instead of
    // throwing (the old UnsupportedError is what broke movie downloads).
    final streamUrl = switch (item) {
      M3uMediaItem(:final streamUrl) || XtreamMediaItem(:final streamUrl) => streamUrl,
      _ => null,
    };
    if (streamUrl == null || streamUrl.isEmpty) return const DownloadResolution(videoUrl: null);
    final uri = Uri.tryParse(streamUrl);
    if (uri != null && uri.path.toLowerCase().endsWith('.m3u8')) {
      return const DownloadResolution(videoUrl: null);
    }
    return DownloadResolution(videoUrl: streamUrl);
  }

  @override
  Future<MediaItem> stampLibrary(MediaItem item) async => item;

  @override
  List<DownloadArtworkSpec> resolveDownloadArtwork(MediaItem item) {
    final thumb = item.thumbPath;
    if (thumb == null || thumb.isEmpty) return const [];
    final uri = Uri.tryParse(thumb);
    if (uri == null || !uri.hasScheme) return const [];
    // The absolute URL is the key (Jellyfin does the same) — provider
    // artwork URLs are unique per item, so a downloaded movie keeps its
    // poster offline.
    return [DownloadArtworkSpec(localKey: thumb, url: thumb)];
  }

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
            // Visible catch-up badge in the guide (tv_archive = 1).
            hasCatchUp: stream.tvArchive,
          ),
        );
      }
      return channels;
    }
    final entries = await _m3uEntries();
    final channels = <LiveTvChannel>[];
    for (final entry in entries) {
      // M3U categories are group titles; a disabled group hides its
      // channels from Live TV (same as Xtream's category filter above).
      if (_isDisabled(entry.groupTitle)) continue;
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
