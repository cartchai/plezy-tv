import 'dart:async';
import 'dart:convert';

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
import '../services/iptv/iptv_catalog_cache.dart';
import '../services/playback_initialization_types.dart';
import '../services/scrub_preview_source.dart';
import '../utils/app_logger.dart';
import '../utils/external_ids.dart';
import '../utils/iptv_initials.dart';
import '../utils/library_content_notifier.dart';
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
    // Test seam: when set, the factory's client is used instead of a fresh
    // one — widget tests point it at a client backed by a fake API, so
    // screens that create their own client (the initials checklist) can
    // load catalogs without the network. Always null in production;
    // tests must clear it in tearDown.
    final debugFactory = debugClientFactory;
    if (debugFactory != null) return debugFactory(connection);
    return switch (connection) {
      M3uConnection() => IptvClient.m3u(m3uConnection: connection),
      XtreamConnection() => IptvClient.xtream(xtreamConnection: connection),
      _ => throw UnsupportedError('IptvClient cannot wrap ${connection.runtimeType}'),
    };
  }

  @visibleForTesting
  static IptvClient Function(Connection connection)? debugClientFactory;

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
  List<String> get _hiddenCategoryIdList => switch (connection) {
    M3uConnection(:final hiddenCategoryIds) => hiddenCategoryIds,
    XtreamConnection(:final hiddenCategoryIds) => hiddenCategoryIds,
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

  // Disk catalog cache (build #11): raw API payloads under the app
  // documents directory, per connection — a cold start reads these
  // instead of re-fetching tens of thousands of rows. See
  // [_readDiskCatalog] / [_refreshCatalogInBackground].
  static const _catalogCache = IptvCatalogDiskCache();

  /// Generation guard for background refreshes: bumped by
  /// [clearCatalogCache], so a refresh started before a clear can never
  /// resurrect the cleared catalog (memory or disk).
  int _catalogGeneration = 0;

  /// Whether a FULL catalog load has completed with rows (build #9 Task 1).
  /// A future that is merely in flight — or that resolved empty — does not
  /// count: a cold search must sweep per-category instead of awaiting a
  /// load that may take minutes on a 46k-row catalog.
  bool _vodStreamsLoaded = false;
  bool _seriesListLoaded = false;
  bool _liveStreamsLoaded = false;

  /// Rows published so far by an in-flight per-category crawl (build #13):
  /// [_loadVodStreams]/[_loadSeries] append each batch as it lands, so a
  /// cold search can read rows long before the whole catalog completes —
  /// the crawl's partial progress used to be invisible to search, which
  /// is why a cold search on a slow connection returned [] although the
  /// match existed on the panel. Cleared when the full load completes
  /// (the memoized list subsumes them) and by [clearCatalogCache]. The
  /// covered-category sets let the search sweep skip categories the
  /// crawl already fetched instead of re-requesting them.
  final List<XtreamVodStream> _vodPartialRows = [];
  final List<XtreamSeries> _seriesPartialRows = [];
  final Set<String> _vodCrawledCategoryIds = {};
  final Set<String> _seriesCrawledCategoryIds = {};

  /// Readout for the LAST search run on this client (build #13): the
  /// query, the scope, and per section which source supplied the results
  /// and how long each leg took. The IPTV settings diagnostics row shows
  /// it, so one screenshot settles where a search dies instead of a
  /// fourth guessed fix. Null until the first search.
  IptvSearchDiagnostics? _lastSearchDiagnostics;

  /// The last search's readout, for the on-device diagnostics row.
  IptvSearchDiagnostics? get lastSearchDiagnostics => _lastSearchDiagnostics;
  Future<List<XtreamCategory>>? _vodCategoriesFuture;
  Future<List<XtreamCategory>>? _seriesCategoriesFuture;
  Future<List<XtreamCategory>>? _liveCategoriesFuture;
  Future<List<M3uEntry>>? _m3uEntriesFuture;

  // Category-name lookups (id -> name), for stripping the provider's
  // category tag from display titles. Fail open to {} when the list
  // cannot be fetched — titles just keep their prefixes.
  Future<Map<String, String>>? _vodCategoryNamesFuture;
  Future<Map<String, String>>? _seriesCategoryNamesFuture;
  Future<Map<String, String>>? _liveCategoryNamesFuture;

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
  /// 16, not 8 (build #13): at 8 the sweep covered ~72 categories inside
  /// its 900ms deadline on a scaled Trex shape (150 visible categories,
  /// 100ms per call) and missed a match in category 120 — both the sweep
  /// and the crawl walk the list in order, so the batch size IS the
  /// reach. 16 doubles the reach without doubling the per-batch wait
  /// (one batch still costs one slow call, not sixteen), and at Matt's
  /// real scale (~270 series categories) it brings a full sweep inside
  /// ~9s at 500ms per call, well within the 45s sweep deadline.
  static const int _catalogFallbackBatchSize = 16;

  /// Per-section time budget for [searchItems] (build #8 Task 1): a section
  /// that misses its budget returns [] for that search while its catalog
  /// fetch keeps running in the background and warms the cache, so the other
  /// section's results are never held hostage — and the next search finds
  /// the slow section. 50s sits inside the aggregation's 60s IPTV leg
  /// deadline with room for ranking. Tests shrink it.
  @visibleForTesting
  static Duration searchSectionBudget = const Duration(seconds: 50);

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

  Set<String> get _hiddenCategories => _hiddenCategoryIdList.toSet();

  /// Category-initial filter list (only the IPTV connection types carry
  /// it). Build #15, item 5 renamed the storage to `hiddenCategoryIds` /
  /// `hiddenCategoryInitials` with a one-time migration from the build
  /// #6–#14 keys — the values are the same category initials, the keys
  /// are new so the tainted history (build #10 reused the old key with a
  /// new meaning, no migration) cannot repeat.
  List<String> get _hiddenCategoryInitialsList => switch (connection) {
    M3uConnection(:final hiddenCategoryInitials) => hiddenCategoryInitials,
    XtreamConnection(:final hiddenCategoryInitials) => hiddenCategoryInitials,
    _ => const [],
  };

  Set<String> get _hiddenCategoryInitials => _hiddenCategoryInitialsList.toSet();

  /// True when the category with [categoryId] and display [categoryName]
  /// is hidden — by its own switch, or because its category initial is
  /// turned off (build #10 redesign: "Category initials", not "Name
  /// initials"). A category with no initial is only hidden by its own
  /// switch. Items are hidden if and only if their category is hidden;
  /// item names are never filtered — the build #8 name filter hid nearly
  /// every item (Matt hid 161 of 171 initials) while the categories
  /// stayed listed, which emptied every series category and broke search.
  bool _isHiddenCategory(String? categoryId, String? categoryName) {
    if (categoryId != null && _hiddenCategories.contains(categoryId)) return true;
    final initial = categoryInitial(categoryName);
    return initial != null && _hiddenCategoryInitials.contains(initial);
  }

  /// M3U groups ARE the categories (the group title is both id and name),
  /// so a group is hidden by its own switch or its category initial.
  bool _isHiddenGroup(String? groupTitle) => _isHiddenCategory(groupTitle, groupTitle);

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
  /// not cancelled; its result is simply discarded. The disk cache is
  /// deleted too (build #11) — a refresh that only cleared memory would
  /// just re-read the same stale files — and the library views are told
  /// the catalog changed so the visible tab reloads with fresh data.
  /// A background refresh started before this call is dropped by the
  /// generation guard, so it can never resurrect the cleared catalog.
  void clearCatalogCache() {
    _catalogGeneration++;
    _liveStreamsFuture = null;
    _vodStreamsFuture = null;
    _seriesFuture = null;
    _vodStreamsLoaded = false;
    _seriesListLoaded = false;
    _liveStreamsLoaded = false;
    _vodPartialRows.clear();
    _seriesPartialRows.clear();
    _vodCrawledCategoryIds.clear();
    _seriesCrawledCategoryIds.clear();
    _vodCategoriesFuture = null;
    _seriesCategoriesFuture = null;
    _liveCategoriesFuture = null;
    _m3uEntriesFuture = null;
    _vodCategoryNamesFuture = null;
    _seriesCategoryNamesFuture = null;
    _liveCategoryNamesFuture = null;
    _favoriteItemsFuture = null;
    _xtreamChannelByKey.clear();
    _m3uChannelByKey.clear();
    unawaited(_catalogCache.clear(connection.id));
    // A manual clear is the user's own action: the tabs must refresh
    // promptly, not at the pacer cooldown's trailing edge (build #14).
    notifyCatalogRefreshed(userInitiated: true);
  }

  /// Tell the app's library views that this connection's catalog changed
  /// (build #11): the Libraries/Home tabs already listen to
  /// [LibraryContentNotifier] for server pushes, so a background refresh
  /// landing (or a manual clear) reuses their paced, scroll-aware reload
  /// — visible tabs update in place, hidden ones reload when next shown.
  /// The Live TV guide listens to it too (build #13). Public so the
  /// manager can fire it when a rebind replaces this client: without it
  /// a filter toggle shows stale lists until a restart.
  ///
  /// [userInitiated] marks the change as the user's own action (a filter
  /// toggle / connection edit rebind, a manual playlist refresh) so
  /// consumers bypass the [RefreshPacer] cooldown for it (build #14).
  /// Background refresh landings leave it false and stay paced.
  ///
  /// [liveCatalogChanged] marks whether the change can affect the live-TV
  /// catalog; the Live TV guide ignores events that are false (build #14,
  /// SA-4 partial). Defaults to true — a clear, a rebind and an M3U
  /// refresh all touch live channels.
  void notifyCatalogRefreshed({bool userInitiated = false, bool liveCatalogChanged = true}) {
    LibraryContentNotifier().notifyChanged(
      LibraryChangeEvent(
        serverId: ServerId(connection.id),
        itemsUpdated: true,
        userInitiated: userInitiated,
        liveCatalogChanged: liveCatalogChanged,
      ),
    );
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

  // -- Catalog loading (lazy, in-memory + disk) ---------------------------

  /// Read a cached catalog payload from disk and parse it with the same
  /// parser the network path uses. Returns null (a miss) when there is no
  /// file, when it cannot be parsed, or when it parses to no rows — an
  /// empty cached catalog is never served, for the same reason an empty
  /// network result is never cached in memory (this panel returns [] for
  /// the unfiltered call at 199k rows). A corrupt file is deleted so it
  /// reads as a miss exactly once.
  Future<({List<T> rows, DateTime fetchedAt})?> _readDiskCatalog<T>(
    String dataset,
    Future<List<T>> Function(String body) parse,
  ) async {
    final cached = await _catalogCache.read(connection.id, dataset);
    if (cached == null) return null;
    try {
      final rows = await parse(cached.body);
      if (rows.isEmpty) {
        unawaited(_catalogCache.delete(connection.id, dataset));
        return null;
      }
      return (rows: rows, fetchedAt: cached.fetchedAt);
    } catch (e) {
      appLogger.w('IPTV: cached $dataset catalog unreadable; refetching', error: e);
      unawaited(_catalogCache.delete(connection.id, dataset));
      return null;
    }
  }

  /// Best-effort disk write for freshly fetched rows, serialized back to
  /// the API's JSON shape so the cached payload re-parses through the
  /// same parsers. Fire-and-forget: awaiting a tens-of-MB write would
  /// gate the browse on file I/O. Empty results are never written.
  /// Generation-guarded: a write scheduled before a [clearCatalogCache]
  /// deletes its own file afterwards, so a late write can never resurrect
  /// a catalog the user just cleared.
  void _writeDiskCatalog<T>(String dataset, List<T> rows, Map<String, dynamic> Function(T row) toJson) {
    if (rows.isEmpty) return;
    _writeDiskText(dataset, jsonEncode(rows.map(toJson).toList()));
  }

  /// Write a freshly fetched catalog, preferring the raw response body
  /// (build #13): the body is exactly what the panel sent, so caching
  /// it verbatim costs no encode at all — jsonEncode of 199k VOD rows
  /// on the UI isolate froze the app for ~1.3s on first launch. Falls
  /// back to [_writeDiskCatalog] when there is no raw body: a catalog
  /// merged by the per-category crawl has no single body, and a test
  /// fake's rows have none either.
  void _writeCatalogRows<T>(
    String dataset,
    List<T> rows,
    Map<String, dynamic> Function(T row) toJson,
    String? rawBody,
  ) {
    if (rows.isEmpty) return;
    if (rawBody != null && rawBody.isNotEmpty) {
      _writeDiskText(dataset, rawBody);
    } else {
      _writeDiskCatalog(dataset, rows, toJson);
    }
  }

  /// Same generation-guarded fire-and-forget write, for a raw text
  /// payload (the M3U playlist). See [_writeDiskCatalog].
  void _writeDiskText(String dataset, String body) {
    if (body.isEmpty) return;
    final generation = _catalogGeneration;
    unawaited(
      _catalogCache.write(connection.id, dataset, body).then((_) async {
        if (generation != _catalogGeneration) {
          await _catalogCache.delete(connection.id, dataset);
        }
      }),
    );
  }

  /// Fetch a catalog in the background after serving a stale disk copy
  /// (build #11): the fresh rows replace the disk file and the memoized
  /// in-memory future, and the library views are told the catalog
  /// changed. Dropped silently when the fetch fails or when a
  /// [clearCatalogCache] landed first (generation guard) — the stale
  /// rows stay on screen either way.
  void _refreshCatalogInBackground<T>({
    required String dataset,
    required Future<List<T>> Function() fetch,
    required Map<String, dynamic> Function(T row) toJson,
    required void Function(List<T> rows) swap,
    // Raw response body of the fetch, when it has one (build #13) —
    // see [_writeCatalogRows]. Read after fetch() returns; null falls
    // back to re-encoding the rows.
    String? Function()? rawBody,
  }) {
    final generation = _catalogGeneration;
    unawaited(
      fetch().then((rows) async {
        if (generation != _catalogGeneration || rows.isEmpty) return;
        final body = rawBody?.call();
        if (body != null && body.isNotEmpty) {
          await _catalogCache.write(connection.id, dataset, body);
        } else {
          await _catalogCache.write(connection.id, dataset, jsonEncode(rows.map(toJson).toList()));
        }
        if (generation != _catalogGeneration) {
          // A clear landed during the write: drop the resurrected file
          // instead of serving pre-clear rows as fresh.
          await _catalogCache.delete(connection.id, dataset);
          return;
        }
        swap(rows);
        // The Live TV guide subscribes to the same notifier: it must only
        // reload for live rows / live categories. A VOD- or series-only
        // refresh landing used to rebuild the whole 55k-channel guide and
        // re-fetch EPG for the visible channels (build #14, SA-4 partial),
        // so the event carries which catalog actually changed.
        final liveCatalogChanged = dataset == IptvCatalogDiskCache.liveDataset ||
            dataset == IptvCatalogDiskCache.liveCategoriesDataset;
        notifyCatalogRefreshed(liveCatalogChanged: liveCatalogChanged);
      }).catchError((Object e) {
        appLogger.w('IPTV: background $dataset catalog refresh failed', error: e);
      }),
    );
  }

  Future<List<XtreamLiveStream>> _liveStreams() async {
    final cached = _liveStreamsFuture;
    if (cached != null) return cached;
    final future = _loadLiveStreamsCached().catchError((Object e) {
      _liveStreamsFuture = null;
      throw e;
    });
    _liveStreamsFuture = future;
    final result = await future;
    // An empty result is never cached: a transient empty payload must
    // not poison every later view until restart (same rule as VOD/series).
    if (result.isEmpty) {
      _liveStreamsFuture = null;
    } else {
      _liveStreamsLoaded = true;
    }
    return result;
  }

  /// Disk first (build #11): a cached live list is served immediately; a
  /// stale one is served and refreshed in the background. No disk cache
  /// (first run, cleared, corrupt) falls back to the network fetch.
  Future<List<XtreamLiveStream>> _loadLiveStreamsCached() async {
    final disk = await _readDiskCatalog<XtreamLiveStream>(
      IptvCatalogDiskCache.liveDataset,
      XtreamApi.parseLiveStreamsBody,
    );
    if (disk != null) {
      if (IptvCatalogDiskCache.isStale(disk.fetchedAt)) {
        _refreshCatalogInBackground<XtreamLiveStream>(
          dataset: IptvCatalogDiskCache.liveDataset,
          fetch: () => _xtreamApi.getLiveStreams(),
          toJson: (r) => r.toJson(),
          swap: (rows) => _liveStreamsFuture = Future.value(rows),
          rawBody: () => _xtreamApi.lastLiveStreamsBody,
        );
      }
      return disk.rows;
    }
    final rows = await _xtreamApi.getLiveStreams();
    _writeCatalogRows(IptvCatalogDiskCache.liveDataset, rows, (r) => r.toJson(), _xtreamApi.lastLiveStreamsBody);
    return rows;
  }

  Future<List<XtreamVodStream>> _vodStreams() async {
    final cached = _vodStreamsFuture;
    if (cached != null) return cached;
    final future = _loadVodStreamsCached().catchError((Object e) {
      _vodStreamsFuture = null;
      throw e;
    });
    _vodStreamsFuture = future;
    final result = await future;
    // The full list subsumes the crawl's partial rows — drop them so a
    // later search reads the memoized list, not a stale snapshot.
    _vodPartialRows.clear();
    _vodCrawledCategoryIds.clear();
    // An empty result is never cached: a transient empty payload (this
    // panel returns [] for the unfiltered call at 199k rows) must not
    // poison every later view until restart.
    if (result.isEmpty) {
      _vodStreamsFuture = null;
    } else {
      _vodStreamsLoaded = true;
    }
    return result;
  }

  /// Disk first (build #11); the network load (with its per-category
  /// fallback) runs only on a miss, and the merged rows are written to
  /// disk — so a panel whose unfiltered call returns [] still gets a
  /// cached catalog from the fallback sweep.
  Future<List<XtreamVodStream>> _loadVodStreamsCached() async {
    final disk = await _readDiskCatalog<XtreamVodStream>(
      IptvCatalogDiskCache.vodDataset,
      XtreamApi.parseVodStreamsBody,
    );
    if (disk != null) {
      if (IptvCatalogDiskCache.isStale(disk.fetchedAt)) {
        _refreshCatalogInBackground<XtreamVodStream>(
          dataset: IptvCatalogDiskCache.vodDataset,
          fetch: _loadVodStreams,
          toJson: (r) => r.toJson(),
          swap: (rows) {
            _vodStreamsFuture = Future.value(rows);
            _vodStreamsLoaded = true;
          },
          rawBody: () => _xtreamApi.lastVodStreamsBody,
        );
      }
      return disk.rows;
    }
    final rows = await _loadVodStreams();
    _writeCatalogRows(IptvCatalogDiskCache.vodDataset, rows, (r) => r.toJson(), _xtreamApi.lastVodStreamsBody);
    return rows;
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
    final wanted = categories.where((c) => !_isHiddenCategory(c.id, c.name)).toList(growable: false);
    if (wanted.isEmpty) return const [];
    final out = <XtreamVodStream>[];
    final seen = <int>{};
    // Publish each batch as it lands (build #13): a cold search reads
    // [_vodPartialRows] instead of waiting for the whole crawl, and the
    // sweep skips categories this crawl already covered. Generation-
    // guarded — a clear mid-crawl must not publish stale rows.
    final generation = _catalogGeneration;
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
      final fresh = <XtreamVodStream>[];
      for (final rows in results) {
        for (final row in rows) {
          if (seen.add(row.streamId)) {
            out.add(row);
            fresh.add(row);
          }
        }
      }
      if (generation == _catalogGeneration && fresh.isNotEmpty) {
        _vodPartialRows.addAll(fresh);
        _vodCrawledCategoryIds.addAll(batch.map((c) => c.id));
      }
    }
    return out;
  }

  Future<List<XtreamSeries>> _seriesList() async {
    final cached = _seriesFuture;
    if (cached != null) return cached;
    final future = _loadSeriesCached().catchError((Object e) {
      _seriesFuture = null;
      throw e;
    });
    _seriesFuture = future;
    final result = await future;
    // The full list subsumes the crawl's partial rows — see [_vodStreams].
    _seriesPartialRows.clear();
    _seriesCrawledCategoryIds.clear();
    if (result.isEmpty) {
      _seriesFuture = null;
    } else {
      _seriesListLoaded = true;
    }
    return result;
  }

  /// Disk first (build #11), same shape as [_loadVodStreamsCached]: the
  /// startup warm-up ([warmUpSeriesCatalog]) now reads the disk copy, so
  /// the second search after app start finds a warm catalog without ever
  /// touching the network when the cache is fresh.
  Future<List<XtreamSeries>> _loadSeriesCached() async {
    final disk = await _readDiskCatalog<XtreamSeries>(
      IptvCatalogDiskCache.seriesDataset,
      XtreamApi.parseSeriesBody,
    );
    if (disk != null) {
      if (IptvCatalogDiskCache.isStale(disk.fetchedAt)) {
        _refreshCatalogInBackground<XtreamSeries>(
          dataset: IptvCatalogDiskCache.seriesDataset,
          fetch: _loadSeries,
          toJson: (r) => r.toJson(),
          swap: (rows) {
            _seriesFuture = Future.value(rows);
            _seriesListLoaded = true;
          },
          rawBody: () => _xtreamApi.lastSeriesBody,
        );
      }
      return disk.rows;
    }
    final rows = await _loadSeries();
    _writeCatalogRows(IptvCatalogDiskCache.seriesDataset, rows, (r) => r.toJson(), _xtreamApi.lastSeriesBody);
    return rows;
  }

  /// Same empty-unfiltered fallback as [_loadVodStreams], for series.
  Future<List<XtreamSeries>> _loadSeries() async {
    final all = await _xtreamApi.getSeries();
    if (all.isNotEmpty) return all;
    final categories = await _seriesCategories().catchError((Object e) {
      appLogger.w('IPTV: series category list unavailable for fallback: $e');
      return const <XtreamCategory>[];
    });
    final wanted = categories.where((c) => !_isHiddenCategory(c.id, c.name)).toList(growable: false);
    if (wanted.isEmpty) return const [];
    final out = <XtreamSeries>[];
    final seen = <int>{};
    // Publish each batch as it lands (build #13) — see [_loadVodStreams].
    final generation = _catalogGeneration;
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
      final fresh = <XtreamSeries>[];
      for (final rows in results) {
        for (final row in rows) {
          if (seen.add(row.seriesId)) {
            out.add(row);
            fresh.add(row);
          }
        }
      }
      if (generation == _catalogGeneration && fresh.isNotEmpty) {
        _seriesPartialRows.addAll(fresh);
        _seriesCrawledCategoryIds.addAll(batch.map((c) => c.id));
      }
    }
    return out;
  }

  Future<List<M3uEntry>> _m3uEntries() {
    return _m3uEntriesFuture ??= _loadM3uEntriesCached().catchError((Object e) {
      _m3uEntriesFuture = null;
      throw e;
    });
  }

  /// Disk first (build #11): the playlist TEXT is the payload, stored
  /// as-is and parsed with [parseM3u] on demand — no model serialization
  /// needed. A stale playlist is served and refreshed in the background.
  Future<List<M3uEntry>> _loadM3uEntriesCached() async {
    final disk = await _catalogCache.read(connection.id, IptvCatalogDiskCache.m3uDataset);
    if (disk != null) {
      try {
        final entries = await compute(parseM3u, disk.body);
        if (entries.isNotEmpty) {
          if (IptvCatalogDiskCache.isStale(disk.fetchedAt)) _refreshM3uEntriesInBackground();
          return entries;
        }
        unawaited(_catalogCache.delete(connection.id, IptvCatalogDiskCache.m3uDataset));
      } catch (e) {
        appLogger.w('IPTV: cached M3U playlist unreadable; refetching', error: e);
        unawaited(_catalogCache.delete(connection.id, IptvCatalogDiskCache.m3uDataset));
      }
    }
    final text = await _fetchM3uPlaylistText();
    _writeDiskText(IptvCatalogDiskCache.m3uDataset, text);
    return compute(parseM3u, text);
  }

  Future<String> _fetchM3uPlaylistText() async {
    final response = await _http.get(Uri.parse(_m3u.playlistUrl)).timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'M3U playlist fetch failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    return response.body;
  }

  void _refreshM3uEntriesInBackground() {
    final generation = _catalogGeneration;
    unawaited(
      _fetchM3uPlaylistText().then((text) async {
        if (generation != _catalogGeneration || text.isEmpty) return;
        await _catalogCache.write(connection.id, IptvCatalogDiskCache.m3uDataset, text);
        if (generation != _catalogGeneration) {
          // A clear landed during the write: drop the resurrected file.
          await _catalogCache.delete(connection.id, IptvCatalogDiskCache.m3uDataset);
          return;
        }
        _m3uEntriesFuture = Future.value(await compute(parseM3u, text));
        notifyCatalogRefreshed();
      }).catchError((Object e) {
        appLogger.w('IPTV: background M3U playlist refresh failed', error: e);
      }),
    );
  }

  /// The category lists for the Categories screen (build #15, item 5) —
  /// disk-first, shared with the guide and browse, so opening the screen
  /// never calls the provider API again when the catalog is already warm.
  /// A failed list throws; the screen treats each section independently
  /// instead of losing the whole screen to one bad list.
  Future<List<XtreamCategory>> liveCategories() => _liveCategories();
  Future<List<XtreamCategory>> vodCategories() => _vodCategories();
  Future<List<XtreamCategory>> seriesCategories() => _seriesCategories();

  /// The M3U group titles (the playlist's categories), distinct and
  /// sorted, for the Categories screen. Reads the cached playlist entries,
  /// so no second download.
  Future<List<String>> m3uGroups() async {
    final groups = <String>{};
    for (final entry in await _m3uEntries()) {
      final group = entry.groupTitle?.trim();
      if (group != null && group.isNotEmpty) groups.add(group);
    }
    final sorted = groups.toList(growable: false)
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return sorted;
  }

  Future<List<XtreamCategory>> _liveCategories() async {
    final cached = _liveCategoriesFuture;
    if (cached != null) return cached;
    final future = _loadLiveCategoriesCached().catchError((Object e) {
      _liveCategoriesFuture = null;
      throw e;
    });
    _liveCategoriesFuture = future;
    return future;
  }

  /// Disk first (build #11), same shape as the other category lists.
  Future<List<XtreamCategory>> _loadLiveCategoriesCached() async {
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.liveCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    if (disk != null) {
      if (IptvCatalogDiskCache.isStale(disk.fetchedAt)) {
        _refreshCatalogInBackground<XtreamCategory>(
          dataset: IptvCatalogDiskCache.liveCategoriesDataset,
          fetch: () => _xtreamApi.getLiveCategories(),
          toJson: (r) => r.toJson(),
          swap: (rows) => _liveCategoriesFuture = Future.value(rows),
        );
      }
      return disk.rows;
    }
    final rows = await _xtreamApi.getLiveCategories();
    _writeDiskCatalog(IptvCatalogDiskCache.liveCategoriesDataset, rows, (r) => r.toJson());
    return rows;
  }

  Future<List<XtreamCategory>> _vodCategories() async {
    final cached = _vodCategoriesFuture;
    if (cached != null) return cached;
    final future = _loadVodCategoriesCached().catchError((Object e) {
      _vodCategoriesFuture = null;
      throw e;
    });
    _vodCategoriesFuture = future;
    return future;
  }

  /// Disk first (build #11), same shape as [_loadLiveCategoriesCached].
  Future<List<XtreamCategory>> _loadVodCategoriesCached() async {
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.vodCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    if (disk != null) {
      if (IptvCatalogDiskCache.isStale(disk.fetchedAt)) {
        _refreshCatalogInBackground<XtreamCategory>(
          dataset: IptvCatalogDiskCache.vodCategoriesDataset,
          fetch: () => _xtreamApi.getVodCategories(),
          toJson: (r) => r.toJson(),
          swap: (rows) => _vodCategoriesFuture = Future.value(rows),
        );
      }
      return disk.rows;
    }
    final rows = await _xtreamApi.getVodCategories();
    _writeDiskCatalog(IptvCatalogDiskCache.vodCategoriesDataset, rows, (r) => r.toJson());
    return rows;
  }

  Future<List<XtreamCategory>> _seriesCategories() async {
    final cached = _seriesCategoriesFuture;
    if (cached != null) return cached;
    final future = _loadSeriesCategoriesCached().catchError((Object e) {
      _seriesCategoriesFuture = null;
      throw e;
    });
    _seriesCategoriesFuture = future;
    return future;
  }

  /// Disk first (build #11), same shape as [_loadLiveCategoriesCached].
  Future<List<XtreamCategory>> _loadSeriesCategoriesCached() async {
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.seriesCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    if (disk != null) {
      if (IptvCatalogDiskCache.isStale(disk.fetchedAt)) {
        _refreshCatalogInBackground<XtreamCategory>(
          dataset: IptvCatalogDiskCache.seriesCategoriesDataset,
          fetch: () => _xtreamApi.getSeriesCategories(),
          toJson: (r) => r.toJson(),
          swap: (rows) => _seriesCategoriesFuture = Future.value(rows),
        );
      }
      return disk.rows;
    }
    final rows = await _xtreamApi.getSeriesCategories();
    _writeDiskCatalog(IptvCatalogDiskCache.seriesCategoriesDataset, rows, (r) => r.toJson());
    return rows;
  }

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

  /// Category id -> name for live TV, same fail-open contract as
  /// [_vodCategoryNames]. The Live TV list needs it so a channel is
  /// hidden exactly when its category is hidden (build #10 redesign).
  Future<Map<String, String>> _liveCategoryNames() async {
    final cached = _liveCategoryNamesFuture;
    if (cached != null) return cached;
    final future = _liveCategories()
        .then(
          (categories) => {for (final c in categories) c.id: c.name},
          onError: (Object e) {
            _liveCategoryNamesFuture = null;
            appLogger.w('IPTV: live category names unavailable: $e');
            return const <String, String>{};
          },
        );
    _liveCategoryNamesFuture = future;
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

  // -- Libraries -----------------------------------------------------------

  @override
  Future<List<MediaLibrary>> fetchLibraries() async {
    // Live TV is NOT a library: channels are served only through liveTv
    // (the Live TV tab). Only on-demand catalogs become libraries, so the
    // library picker never shows a "Live TV" row. M3U has no on-demand
    // catalog, so it exposes no libraries at all.
    //
    // The Movies and Series libraries are ALWAYS listed for an Xtream
    // connection (build #13): a filter hides content, it must never delete
    // the library row itself. The old "omit this library when ALL its
    // categories are disabled" probe did exactly that — one "Hide all
    // groups" tap in the edit screen made both libraries vanish from the
    // Libraries tab while Live TV kept working, and the only way back was
    // the edit screen. It also cost two provider round trips (up to 5s)
    // on every library fetch, which the build #11 disk cache made fast
    // enough to actually complete — the probe used to fail open on a slow
    // network and hide the libraries once the cache landed. Disabled
    // categories are still hidden from browse/search/guide by the
    // content-level filters (_moviesItems/_seriesItems/_isHiddenCategory);
    // an all-disabled library simply shows its empty state.
    final name = _name;
    final libraries = <MediaLibrary>[];
    if (_isXtream) {
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

  /// Filtered VOD rows: hidden categories removed, query applied on the
  /// stripped title (the same text the old item-level filter matched).
  /// Returns ROWS, not items (build #13): mapping 199k rows to
  /// MediaItems on every page turn froze the UI for ~650ms; callers map
  /// only the slice they show ([_vodPageItems]).
  Future<List<XtreamVodStream>> _filteredVodRows({String? search, String? nameStartsWith}) async {
    final streams = await _vodStreams();
    final categoryNames = await _vodCategoryNames();
    final searchPattern = _searchPattern(search);
    final startsWithPattern = _startsWithPattern(nameStartsWith);
    final isHash = nameStartsWith == '#';
    return streams.where((s) {
      if (_isHiddenCategory(s.categoryId, categoryNames[s.categoryId])) return false;
      final title = stripCategoryPrefix(s.name, categoryNames[s.categoryId]);
      if (searchPattern != null && !searchPattern.hasMatch(title)) return false;
      if (nameStartsWith != null && nameStartsWith.isNotEmpty) {
        final first = title.trimLeft();
        if (isHash) {
          if (first.isNotEmpty && _alphaStart.hasMatch(first)) return false;
        } else if (startsWithPattern != null && !startsWithPattern.hasMatch(first)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Same as [_filteredVodRows], for series rows.
  Future<List<XtreamSeries>> _filteredSeriesRows({String? search, String? nameStartsWith}) async {
    final series = await _seriesList();
    final categoryNames = await _seriesCategoryNames();
    final searchPattern = _searchPattern(search);
    final startsWithPattern = _startsWithPattern(nameStartsWith);
    final isHash = nameStartsWith == '#';
    return series.where((s) {
      if (_isHiddenCategory(s.categoryId, categoryNames[s.categoryId])) return false;
      final title = stripCategoryPrefix(s.name, categoryNames[s.categoryId]);
      if (searchPattern != null && !searchPattern.hasMatch(title)) return false;
      if (nameStartsWith != null && nameStartsWith.isNotEmpty) {
        final first = title.trimLeft();
        if (isHash) {
          if (first.isNotEmpty && _alphaStart.hasMatch(first)) return false;
        } else if (startsWithPattern != null && !startsWithPattern.hasMatch(first)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// Case-insensitive substring pattern for a browse search, built once
  /// per filter call — never per row (see [_appendMovieMatches]).
  static RegExp? _searchPattern(String? search) {
    final s = search?.trim();
    if (s == null || s.isEmpty) return null;
    return RegExp(RegExp.escape(s), caseSensitive: false);
  }

  /// Case-insensitive "starts with" pattern for a browse initial filter.
  static RegExp? _startsWithPattern(String? nameStartsWith) {
    if (nameStartsWith == null || nameStartsWith.isEmpty || nameStartsWith == '#') return null;
    return RegExp('^${RegExp.escape(nameStartsWith)}', caseSensitive: false);
  }

  static final RegExp _alphaStart = RegExp(r'^[A-Za-z]');

  /// Map one page of VOD rows to items — only the rows on the page are
  /// mapped, never the whole catalog.
  Future<List<MediaItem>> _vodPageItems(List<XtreamVodStream> rows, int offset, int limit) async {
    final favorites = await _favoriteItems();
    final categoryNames = await _vodCategoryNames();
    final start = offset.clamp(0, rows.length);
    final end = (offset + limit).clamp(0, rows.length);
    return rows
        .sublist(start, end)
        .map(
          (s) => _movieItem(
            s,
            isFavorite: favorites.containsKey('movie:${s.streamId}'),
            categoryName: categoryNames[s.categoryId],
          ),
        )
        .toList();
  }

  /// Same as [_vodPageItems], for series rows.
  Future<List<MediaItem>> _seriesPageItems(List<XtreamSeries> rows, int offset, int limit) async {
    final favorites = await _favoriteItems();
    final categoryNames = await _seriesCategoryNames();
    final start = offset.clamp(0, rows.length);
    final end = (offset + limit).clamp(0, rows.length);
    return rows
        .sublist(start, end)
        .map(
          (s) => _seriesItem(
            s,
            isFavorite: favorites.containsKey('series:${s.seriesId}'),
            categoryName: categoryNames[s.categoryId],
          ),
        )
        .toList();
  }

  /// Full Movies catalog as items, with hidden categories removed.
  /// Only [fetchMoreHubItems] still needs the whole list (the hub
  /// detail's section filter runs over it); the paged browse and the
  /// hubs map only the slice they show (see [_filteredVodRows]).
  Future<List<MediaItem>> _moviesItems() async {
    final streams = await _vodStreams();
    final favorites = await _favoriteItems();
    final categoryNames = await _vodCategoryNames();
    return streams
        .where((s) => !_isHiddenCategory(s.categoryId, categoryNames[s.categoryId]))
        .map(
          (s) => _movieItem(
            s,
            isFavorite: favorites.containsKey('movie:${s.streamId}'),
            categoryName: categoryNames[s.categoryId],
          ),
        )
        .toList();
  }

  /// Full Series catalog as items, with hidden categories removed.
  Future<List<MediaItem>> _seriesItems() async {
    final series = await _seriesList();
    final favorites = await _favoriteItems();
    final categoryNames = await _seriesCategoryNames();
    return series
        .where((s) => !_isHiddenCategory(s.categoryId, categoryNames[s.categoryId]))
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
    // Full filtered count (build #13): callers now pass only the first
    // `limit` items (mapping 199k to take 20 froze the UI), so `size`
    // and `more` must come from the catalog count, not the passed list.
    // Defaults to the passed list for callers that still pass it all.
    int? totalCount,
  }) {
    final items = all.take(limit).toList();
    final total = totalCount ?? all.length;
    return MediaHub(
      id: 'iptv:$libraryId:recommended',
      title: title,
      type: type,
      items: items,
      size: total,
      more: total > items.length,
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
      final rows = await _filteredVodRows(search: query.search, nameStartsWith: query.nameStartsWith);
      final items = await _vodPageItems(rows, query.offset, query.limit);
      return LibraryPage(items: items, totalCount: rows.length, offset: query.offset.clamp(0, rows.length));
    }
    if (libraryId == _seriesLibraryId) {
      final rows = await _filteredSeriesRows(search: query.search, nameStartsWith: query.nameStartsWith);
      final items = await _seriesPageItems(rows, query.offset, query.limit);
      return LibraryPage(items: items, totalCount: rows.length, offset: query.offset.clamp(0, rows.length));
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
          .where((c) => !_isHiddenCategory(c.id, c.name))
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
          .where((c) => !_isHiddenCategory(c.id, c.name))
          .map((c) => IptvCategory(id: c.id, name: c.name, itemCount: counts[c.id]))
          .toList();
    }
    return const [];
  }

  /// Detected category initials for this connection (build #8 Task 4,
  /// redesigned build #10): the initials that keep repeating across the
  /// connection's CATEGORY names — live, VOD and series — most-common
  /// first. Only initials at or above [iptvInitialRepeatThreshold] are
  /// offered as toggles; one-off prefixes are never offered. The count
  /// on each row is the number of CATEGORIES carrying that initial.
  ///
  /// Xtream needs only the three category lists now — the old version
  /// loaded the whole live/VOD/series catalogs just to count item-name
  /// prefixes, which is also why opening the section was slow on a cold
  /// connection. M3U has no category endpoint, so its initials come from
  /// the playlist's group titles. Call it lazily, on expand.
  Future<List<IptvInitial>> iptvInitials() async {
    final names = <String>[];
    if (_isXtream) {
      final liveCategories = await _liveCategories().catchError((Object e) {
        appLogger.w('IPTV: live category list unavailable for initials: $e');
        return const <XtreamCategory>[];
      });
      names.addAll(liveCategories.map((c) => c.name));
      final vodCategories = await _vodCategories();
      names.addAll(vodCategories.map((c) => c.name));
      final seriesCategories = await _seriesCategories();
      names.addAll(seriesCategories.map((c) => c.name));
    } else {
      final entries = await _m3uEntries();
      for (final entry in entries) {
        final group = entry.groupTitle;
        if (group != null) names.add(group);
      }
    }
    return initialsMeetingThreshold(countCategoryInitials(names));
  }

  /// Warms the series catalog in the background (build #10): starts the
  /// unfiltered series load without awaiting it, so the NEXT search finds
  /// a warm catalog. Called at startup bind (see
  /// MultiServerManager.addIptvConnection). A load already in flight is
  /// shared, so repeated calls are free; a failed load logs and the next
  /// search retries it. Series only — movies search already works and
  /// warming the 199k-row VOD catalog on every rebind is unnecessary cost.
  void warmUpSeriesCatalog() {
    if (!_isXtream || _seriesListLoaded) return;
    unawaited(
      _seriesList().catchError((Object e) {
        appLogger.w('IPTV: background series catalog warm-up failed: $e');
        return const <XtreamSeries>[];
      }),
    );
  }

  /// Same warm-up for the VOD catalog (build #13): the first Movies
  /// browse/search after app start otherwise races the 199k-row load.
  void warmUpVodCatalog() {
    if (!_isXtream || _vodStreamsLoaded) return;
    unawaited(
      _vodStreams().catchError((Object e) {
        appLogger.w('IPTV: background VOD catalog warm-up failed: $e');
        return const <XtreamVodStream>[];
      }),
    );
  }

  /// Same warm-up for the live catalog (build #13): the first Live TV
  /// search after app start otherwise races the 55k-row load.
  void warmUpLiveCatalog() {
    if (!_isXtream || _liveStreamsLoaded) return;
    unawaited(
      _liveStreams().catchError((Object e) {
        appLogger.w('IPTV: background live catalog warm-up failed: $e');
        return const <XtreamLiveStream>[];
      }),
    );
  }

  /// On-device series catalog diagnostics (build #10, diagnosis
  /// recommendation 6): what Matt's phone can report about the series
  /// catalog in one screenshot — the unfiltered row count, the series
  /// category count, per-category row counts for the first few categories
  /// (direct get_series calls, which directly settle (g)), and how many
  /// initials/categories are turned off. Shown in the IPTV settings
  /// screen.
  ///
  /// Build #13: probes DIRECTLY, each call bounded by a short timeout.
  /// The old version awaited the full [_seriesList()] crawl, so on the
  /// exact phone that needs the readout — a (g)-shape panel whose crawl
  /// takes minutes — it never answered. `unfilteredSeriesRows` is now
  /// literally the rows the unfiltered get_series returned (0 on a
  /// (g) panel), not the crawled total.
  Future<IptvCatalogDiagnostics> seriesCatalogDiagnostics() async {
    const probeTimeout = Duration(seconds: 10);
    final unfiltered = await _xtreamApi
        .getSeries()
        .timeout(probeTimeout, onTimeout: () => const <XtreamSeries>[])
        .catchError((Object e) {
          appLogger.w('IPTV: series catalog probe failed for diagnostics: $e');
          return const <XtreamSeries>[];
        });
    final categories = await _seriesCategories()
        .timeout(probeTimeout, onTimeout: () => const <XtreamCategory>[])
        .catchError((Object e) {
          appLogger.w('IPTV: series category list unavailable for diagnostics: $e');
          return const <XtreamCategory>[];
        });
    final perCategory = <String, int>{};
    for (final category in categories.take(3)) {
      final probe = await _xtreamApi
          .getSeries(categoryId: category.id)
          .timeout(probeTimeout, onTimeout: () => const <XtreamSeries>[])
          .catchError((Object e) {
            appLogger.w('IPTV: series probe for ${category.id} failed: $e');
            return const <XtreamSeries>[];
          });
      perCategory['${category.name} (${category.id})'] = probe.length;
    }
    return IptvCatalogDiagnostics(
      unfilteredSeriesRows: unfiltered.length,
      seriesCategoryCount: categories.length,
      perCategorySeriesRows: perCategory,
      hiddenCategoryInitialsCount: _hiddenCategoryInitials.length,
      hiddenCategoriesCount: _hiddenCategories.length,
    );
  }

  /// A hidden category (its own switch, or its category initial turned
  /// off) returns [] without loading the catalog — the tab never lists
  /// it, so reaching here with a hidden id means a stale deep link. A hidden
  /// category (its own switch, or its category initial turned off) returns
  /// [] without loading the catalog — the tab never lists it, so reaching
  /// here with a hidden id means a stale deep link.
  Future<List<MediaItem>> iptvItemsForCategory(String libraryId, String categoryId) async {
    if (!_isXtream) return const [];
    if (libraryId == _moviesLibraryId) {
      final categoryNames = await _vodCategoryNames();
      if (_isHiddenCategory(categoryId, categoryNames[categoryId])) return const [];
      final streams = await _vodStreams();
      final favorites = await _favoriteItems();
      return streams
          .where((s) => s.categoryId == categoryId)
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
      final categoryNames = await _seriesCategoryNames();
      if (_isHiddenCategory(categoryId, categoryNames[categoryId])) return const [];
      final series = await _seriesList();
      final favorites = await _favoriteItems();
      return series
          .where((s) => s.categoryId == categoryId)
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
      case 'live':
        // Build #13: live search results are keyed `live:<streamId>`.
        final liveStreamId = int.tryParse(parts[1]);
        if (liveStreamId == null) return null;
        final liveStreams = await _liveStreams();
        final liveFound = liveStreams.where((s) => s.streamId == liveStreamId).firstOrNull;
        if (liveFound == null) return null;
        final liveCategoryNames = await _liveCategoryNames();
        return _liveChannelItem(liveFound, categoryName: liveCategoryNames[liveFound.categoryId]);
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
    final searchStarted = DateTime.now();
    if (_isXtream) {
      final includeMovies = !excludedLibraryIds.contains(_moviesLibraryId);
      final includeSeries = !excludedLibraryIds.contains(_seriesLibraryId);
      // Live TV is not a real library, so it can never appear in
      // excludedLibraryIds itself — but the search screen's scope strip
      // excludes every OTHER library when a scope is active, so live
      // shows only for an unscoped search (build #13: "search in live
      // TV" was empty by construction before this — Xtream live channels
      // had no search leg at all, only M3U channels did).
      final includeLive = excludedLibraryIds.isEmpty;
      final moviesTrace = _SectionTrace()..skipped = !includeMovies;
      final seriesTrace = _SectionTrace()..skipped = !includeSeries;
      final liveTrace = _SectionTrace()..skipped = !includeLive;
      // Sections fetch concurrently and fail open on their own: a movies
      // failure must not kill series results (and vice versa), and a cold
      // search costs max(movies, series, live), not the sum — the old sequential
      // awaits behind the 20s search leg deadline returned zero IPTV
      // results on a slow connection.
      //
      // Build #8 Task 1: each section gets its OWN `limit` of results.
      // The old merge capped the COMBINED list at `limit` movies-first, so
      // any query matching 100+ movies returned zero series — before the
      // aggregation's relevance ranking ever ran. The merged pool is at most
      // 3 * limit; the aggregation re-ranks it and caps it at its own limit,
      // so an exact series-title match now beats partial movie matches.
      //
      // Each section also races [searchSectionBudget]: a section that misses
      // it returns [] for this search while its catalog fetch keeps running
      // in the background and warms the cache, so a cold 46k-row series
      // catalog can no longer hold the movies leg hostage under the 60s
      // IPTV leg deadline — the next search finds the slow section.
      final sections = await Future.wait([
        if (includeMovies)
          _searchMovies(needle, limit, moviesTrace).timeout(searchSectionBudget, onTimeout: () => moviesTrace.partialOut)
        else
          Future.value(const <MediaItem>[]),
        if (includeSeries)
          _searchSeries(needle, limit, seriesTrace).timeout(searchSectionBudget, onTimeout: () => seriesTrace.partialOut)
        else
          Future.value(const <MediaItem>[]),
        if (includeLive)
          _searchLive(needle, limit, liveTrace).timeout(searchSectionBudget, onTimeout: () => liveTrace.partialOut)
        else
          Future.value(const <MediaItem>[]),
      ]);
      _lastSearchDiagnostics = IptvSearchDiagnostics(
        query: needle,
        scoped: excludedLibraryIds.isNotEmpty,
        totalMs: DateTime.now().difference(searchStarted).inMilliseconds,
        movies: moviesTrace.diagnostics,
        series: seriesTrace.diagnostics,
        live: liveTrace.diagnostics,
        recordedAt: DateTime.now(),
      );
      return sections.expand((items) => items).toList();
    }
    // M3U: the playlist is the catalog; channels surface as playable items.
    final m3uLiveTrace = _SectionTrace();
    final m3uStarted = DateTime.now();
    final m3uResults = await _searchM3uEntries(needle, limit, excludedLibraryIds);
    m3uLiveTrace.loadRows = m3uResults.length;
    m3uLiveTrace.loadMatches = m3uResults.length;
    m3uLiveTrace.ms = DateTime.now().difference(m3uStarted).inMilliseconds;
    final emptyTrace = _SectionTrace()..skipped = true;
    _lastSearchDiagnostics = IptvSearchDiagnostics(
      query: needle,
      scoped: excludedLibraryIds.isNotEmpty,
      totalMs: DateTime.now().difference(searchStarted).inMilliseconds,
      movies: emptyTrace.diagnostics,
      series: emptyTrace.diagnostics,
      live: m3uLiveTrace.diagnostics,
      recordedAt: DateTime.now(),
    );
    return m3uResults;
  }

  /// Append this section's matches from [rows] to [out], honouring the
  /// hidden-category filter and the query, de-duplicated by stream id (a
  /// panel may return the same row under two categories).
  /// Shared by the warm path and the cold sweep so the two cannot drift.
  void _appendMovieMatches(
    List<XtreamVodStream> rows,
    String needle,
    int limit,
    Map<String, IptvFavoriteItem> favorites,
    Map<String, String> categoryNames,
    List<MediaItem> out,
    Set<int> seen,
  ) {
    // One case-insensitive pattern for the whole scan (build #13): the
    // old `name.toLowerCase().contains(needle)` allocated a lowercased
    // copy of every row's name — 199k allocations per search, ~130ms
    // of UI-thread work. hasMatch allocates nothing per row.
    final match = RegExp(RegExp.escape(needle), caseSensitive: false);
    for (final stream in rows) {
      if (out.length >= limit) break;
      if (!seen.add(stream.streamId)) continue;
      if (_isHiddenCategory(stream.categoryId, categoryNames[stream.categoryId])) continue;
      if (!match.hasMatch(stream.name)) continue;
      out.add(
        _movieItem(
          stream,
          isFavorite: favorites.containsKey('movie:${stream.streamId}'),
          categoryName: categoryNames[stream.categoryId],
        ),
      );
    }
  }

  /// Same as [_appendMovieMatches], for series rows.
  void _appendSeriesMatches(
    List<XtreamSeries> rows,
    String needle,
    int limit,
    Map<String, IptvFavoriteItem> favorites,
    Map<String, String> categoryNames,
    List<MediaItem> out,
    Set<int> seen,
  ) {
    // One case-insensitive pattern for the whole scan — see
    // [_appendMovieMatches].
    final match = RegExp(RegExp.escape(needle), caseSensitive: false);
    for (final s in rows) {
      if (out.length >= limit) break;
      if (!seen.add(s.seriesId)) continue;
      if (_isHiddenCategory(s.categoryId, categoryNames[s.categoryId])) continue;
      if (!match.hasMatch(s.name)) continue;
      out.add(
        _seriesItem(
          s,
          isFavorite: favorites.containsKey('series:${s.seriesId}'),
          categoryName: categoryNames[s.categoryId],
        ),
      );
    }
  }

  /// Sweep per-category catalog rows in parallel batches, feeding each
  /// category's rows to [onRows] AS THEY LAND: a slow category must not
  /// hold its batch hostage (the old batched Future.wait did exactly
  /// that). Stops at [deadline] or when [shouldStop] says enough matches
  /// were found; rows landing after the sweep stopped are dropped, never
  /// appended to a list that was already returned.
  Future<void> _sweepCatalogCategories<T>(
    List<XtreamCategory> categories,
    Future<List<T>> Function(String categoryId) loadCategory,
    void Function(List<T> rows) onRows,
    bool Function() shouldStop,
    DateTime deadline,
  ) async {
    var stopped = false;
    for (var i = 0; i < categories.length && !stopped; i += _catalogFallbackBatchSize) {
      if (shouldStop()) break;
      final timeLeft = deadline.difference(DateTime.now());
      if (timeLeft <= Duration.zero) break;
      final end = (i + _catalogFallbackBatchSize).clamp(0, categories.length);
      final batch = categories.sublist(i, end);
      final futures = <Future<void>>[];
      for (final category in batch) {
        futures.add(
          loadCategory(category.id)
              .then((rows) {
                if (!stopped && !shouldStop()) onRows(rows);
              })
              .catchError((Object e) {
                appLogger.w('IPTV: catalog sweep category ${category.id} unavailable: $e');
              }),
        );
      }
      // Wait for the batch, but no longer than the sweep deadline: rows
      // that already landed are kept, the rest are dropped by `stopped`.
      await Future.wait(futures).timeout(timeLeft, onTimeout: () {
        stopped = true;
        return <void>[];
      });
      if (shouldStop()) stopped = true;
    }
  }

  /// Deadline for a cold-catalog sweep, measured from the SECTION start
  /// (build #10): 90% of the section budget, so the sweep returns partial
  /// matches instead of being cut to [] by the outer timeout, with room
  /// left for the merge. Measured from the section start, not the sweep
  /// start — the old version computed it when the sweep began, so a slow
  /// category-names fetch before the sweep pushed the sweep past the
  /// outer 50s timeout and its partial matches were discarded (T3).
  DateTime _sweepDeadline(DateTime sectionStarted) =>
      sectionStarted.add(searchSectionBudget * 0.9);

  Future<List<MediaItem>> _searchMovies(String needle, int limit, _SectionTrace trace) async {
    try {
      final sectionStarted = DateTime.now();
      final favorites = await _favoriteItems();
      final categoryNames = await _vodCategoryNames();
      if (_vodStreamsLoaded) {
        // Warm catalog: filter the cached list (the old path).
        final rows = await _vodStreams();
        final out = <MediaItem>[];
        trace.partialOut = out;
        _appendMovieMatches(rows, needle, limit, favorites, categoryNames, out, <int>{});
        trace.loadRows = rows.length;
        trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
        trace.loadMatches = out.length;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return out;
      }
      // Cold catalog (build #9 Task 1a, reworked build #10): the full
      // 199k-row load may take minutes, and awaiting it before filtering
      // a single title is why a cold search returned [] under the section
      // budget — but the sweep alone is not a safe substitute either. If
      // the panel's per-category calls return [] (the (g) shape), the
      // sweep finds nothing while the unfiltered load would have returned
      // rows — and Recommended proves the unfiltered load DOES return rows
      // on Matt's phone. So search races BOTH sources and returns
      // whichever lands first: the unfiltered load, and the per-category
      // sweep for when the load is the slow one.
      //
      // Build #13: a THIRD source — the load's own crawl publishes each
      // batch into [_vodPartialRows] as it lands, so a search that
      // outlives the sweep can still answer from the crawl's progress
      // instead of waiting for the whole 199k rows. The sweep also skips
      // categories the crawl already covered, so the two never pay for
      // the same category twice.
      final out = <MediaItem>[];
      trace.partialOut = out;
      final seen = <int>{};
      var loadLanded = false;
      var finished = false;
      final loadFuture = _vodStreams().catchError((Object e) {
        appLogger.w('IPTV: VOD catalog load failed during search: $e');
        return const <XtreamVodStream>[];
      });
      unawaited(
        loadFuture.then((rows) {
          if (finished || rows.isEmpty) return;
          loadLanded = true;
          trace.loadRows = rows.length;
          trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
          final before = out.length;
          _appendMovieMatches(rows, needle, limit, favorites, categoryNames, out, seen);
          trace.loadMatches += out.length - before;
        }),
      );
      // One shared category-list fetch (build #10, T1): the names lookup
      // above already fetched it, so this reuses the cached future
      // instead of fetching it a second time — and a failure here does
      // not re-fetch either.
      final categories = await _vodCategories().catchError((Object e) {
        appLogger.w('IPTV: VOD category list unavailable for search sweep: $e');
        return const <XtreamCategory>[];
      });
      final wanted = categories
          .where((c) => !_isHiddenCategory(c.id, c.name) && !_vodCrawledCategoryIds.contains(c.id))
          .toList(growable: false);
      await _sweepCatalogCategories<XtreamVodStream>(
        wanted,
        (id) => _xtreamApi.getVodStreams(categoryId: id),
        (rows) {
          final before = out.length;
          _appendMovieMatches(rows, needle, limit, favorites, categoryNames, out, seen);
          trace.sweepMatches += out.length - before;
        },
        () => out.length >= limit || loadLanded,
        _sweepDeadline(sectionStarted),
      );
      if (out.isEmpty && !loadLanded) {
        // The sweep found NOTHING — instant [] per-category calls, or
        // every category answered empty — before the load landed. The
        // crawl may already have published rows the sweep skipped (its
        // categories are in _vodCrawledCategoryIds): filter those first,
        // then wait out the remaining budget for the load; without this
        // a fast-empty sweep wins over a slow-but-returning load and the
        // search returns []. Only when the sweep found nothing: if it
        // found matches, return them now and let the load keep warming
        // the cache for the next search — waiting here would stall every
        // cold search for the rest of the budget.
        final partialBefore = out.length;
        _appendMovieMatches(
          List.of(_vodPartialRows),
          needle,
          limit,
          favorites,
          categoryNames,
          out,
          seen,
        );
        trace.partialMatches += out.length - partialBefore;
        if (out.isEmpty) {
          final remaining = sectionStarted.add(searchSectionBudget * 0.98).difference(DateTime.now());
          if (!remaining.isNegative) {
            final rows = await loadFuture.timeout(remaining, onTimeout: () => const <XtreamVodStream>[]);
            if (rows.isNotEmpty && !loadLanded) {
              loadLanded = true;
              trace.loadRows = rows.length;
              trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
              final before = out.length;
              _appendMovieMatches(rows, needle, limit, favorites, categoryNames, out, seen);
              trace.loadMatches += out.length - before;
            } else if (rows.isEmpty) {
              // The load landed empty; the crawl may have published more
              // batches while we waited — one last partial read.
              final lastBefore = out.length;
              _appendMovieMatches(
                List.of(_vodPartialRows),
                needle,
                limit,
                favorites,
                categoryNames,
                out,
                seen,
              );
              trace.partialMatches += out.length - lastBefore;
            }
          }
        }
      }
      finished = true;
      trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
      return out;
    } catch (e) {
      appLogger.w('IPTV: movie search failed: $e');
      return const [];
    }
  }

  Future<List<MediaItem>> _searchSeries(String needle, int limit, _SectionTrace trace) async {
    try {
      final sectionStarted = DateTime.now();
      final favorites = await _favoriteItems();
      final categoryNames = await _seriesCategoryNames();
      if (_seriesListLoaded) {
        // Warm catalog: filter the cached list (the old path).
        final rows = await _seriesList();
        final out = <MediaItem>[];
        trace.partialOut = out;
        _appendSeriesMatches(rows, needle, limit, favorites, categoryNames, out, <int>{});
        trace.loadRows = rows.length;
        trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
        trace.loadMatches = out.length;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return out;
      }
      // Cold catalog (build #9 Task 1a, reworked build #10): same race
      // as movies — the unfiltered 46k-row load that Recommended proves
      // works, against the per-category sweep. Matt turned ALL initials
      // back on and search STILL failed, so the sweep alone cannot be
      // trusted: on this panel the per-category calls may return [] while
      // the unfiltered load returns rows (g), or the sweep's pre-work
      // eats the budget before any batch runs (T1/T3).
      //
      // Build #13: same third source as movies — the load's crawl
      // publishes each batch into [_seriesPartialRows] as it lands, and
      // the sweep skips categories the crawl already covered.
      final out = <MediaItem>[];
      trace.partialOut = out;
      final seen = <int>{};
      var loadLanded = false;
      var finished = false;
      final loadFuture = _seriesList().catchError((Object e) {
        appLogger.w('IPTV: series catalog load failed during search: $e');
        return const <XtreamSeries>[];
      });
      unawaited(
        loadFuture.then((rows) {
          if (finished || rows.isEmpty) return;
          loadLanded = true;
          trace.loadRows = rows.length;
          trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
          final before = out.length;
          _appendSeriesMatches(rows, needle, limit, favorites, categoryNames, out, seen);
          trace.loadMatches += out.length - before;
        }),
      );
      // One shared category-list fetch (build #10, T1): the names lookup
      // above already fetched it, so this reuses the cached future
      // instead of fetching it a second time — and a failure here does
      // not re-fetch either.
      final categories = await _seriesCategories().catchError((Object e) {
        appLogger.w('IPTV: series category list unavailable for search sweep: $e');
        return const <XtreamCategory>[];
      });
      final wanted = categories
          .where((c) => !_isHiddenCategory(c.id, c.name) && !_seriesCrawledCategoryIds.contains(c.id))
          .toList(growable: false);
      await _sweepCatalogCategories<XtreamSeries>(
        wanted,
        (id) => _xtreamApi.getSeries(categoryId: id),
        (rows) {
          final before = out.length;
          _appendSeriesMatches(rows, needle, limit, favorites, categoryNames, out, seen);
          trace.sweepMatches += out.length - before;
        },
        () => out.length >= limit || loadLanded,
        _sweepDeadline(sectionStarted),
      );
      if (out.isEmpty && !loadLanded) {
        // The sweep found nothing before the load landed — filter the
        // crawl's published partial rows first, then wait out the
        // remaining budget for the load (see movies above).
        final partialBefore = out.length;
        _appendSeriesMatches(
          List.of(_seriesPartialRows),
          needle,
          limit,
          favorites,
          categoryNames,
          out,
          seen,
        );
        trace.partialMatches += out.length - partialBefore;
        if (out.isEmpty) {
          final remaining = sectionStarted.add(searchSectionBudget * 0.98).difference(DateTime.now());
          if (!remaining.isNegative) {
            final rows = await loadFuture.timeout(remaining, onTimeout: () => const <XtreamSeries>[]);
            if (rows.isNotEmpty && !loadLanded) {
              loadLanded = true;
              trace.loadRows = rows.length;
              trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
              final before = out.length;
              _appendSeriesMatches(rows, needle, limit, favorites, categoryNames, out, seen);
              trace.loadMatches += out.length - before;
            } else if (rows.isEmpty) {
              // The load landed empty; the crawl may have published more
              // batches while we waited — one last partial read.
              final lastBefore = out.length;
              _appendSeriesMatches(
                List.of(_seriesPartialRows),
                needle,
                limit,
                favorites,
                categoryNames,
                out,
                seen,
              );
              trace.partialMatches += out.length - lastBefore;
            }
          }
        }
      }
      finished = true;
      trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
      return out;
    } catch (e) {
      appLogger.w('IPTV: series search failed: $e');
      return const [];
    }
  }

  /// Live TV search (build #13): Xtream live channels had NO search leg
  /// at all — only M3U channels were searchable — so "search in live TV"
  /// was empty by construction. Same shape as movies/series: race the
  /// unfiltered live load (disk-cached, build #11) against a per-category
  /// sweep, so a slow 55k-row load cannot hold the section hostage.
  /// Search never opens a stream (one-stream limit): results are plain
  /// items whose tap resolves through `fetchItem('live:<id>')`.
  Future<List<MediaItem>> _searchLive(String needle, int limit, _SectionTrace trace) async {
    try {
      final sectionStarted = DateTime.now();
      final categoryNames = await _liveCategoryNames();
      if (_liveStreamsLoaded) {
        // Warm catalog: filter the cached list.
        final rows = await _liveStreams();
        final out = <MediaItem>[];
        trace.partialOut = out;
        _appendLiveMatches(rows, needle, limit, categoryNames, out, <int>{});
        trace.loadRows = rows.length;
        trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
        trace.loadMatches = out.length;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return out;
      }
      final out = <MediaItem>[];
      trace.partialOut = out;
      final seen = <int>{};
      var loadLanded = false;
      var finished = false;
      final loadFuture = _liveStreams().catchError((Object e) {
        appLogger.w('IPTV: live catalog load failed during search: $e');
        return const <XtreamLiveStream>[];
      });
      unawaited(
        loadFuture.then((rows) {
          if (finished || rows.isEmpty) return;
          loadLanded = true;
          trace.loadRows = rows.length;
          trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
          final before = out.length;
          _appendLiveMatches(rows, needle, limit, categoryNames, out, seen);
          trace.loadMatches += out.length - before;
        }),
      );
      final categories = await _liveCategories().catchError((Object e) {
        appLogger.w('IPTV: live category list unavailable for search sweep: $e');
        return const <XtreamCategory>[];
      });
      final wanted = categories.where((c) => !_isHiddenCategory(c.id, c.name)).toList(growable: false);
      await _sweepCatalogCategories<XtreamLiveStream>(
        wanted,
        (id) => _xtreamApi.getLiveStreams(categoryId: id),
        (rows) {
          final before = out.length;
          _appendLiveMatches(rows, needle, limit, categoryNames, out, seen);
          trace.sweepMatches += out.length - before;
        },
        () => out.length >= limit || loadLanded,
        _sweepDeadline(sectionStarted),
      );
      if (out.isEmpty && !loadLanded) {
        // The sweep found nothing before the load landed — wait out the
        // remaining budget for the load (see movies).
        final remaining = sectionStarted.add(searchSectionBudget * 0.98).difference(DateTime.now());
        if (!remaining.isNegative) {
          final rows = await loadFuture.timeout(remaining, onTimeout: () => const <XtreamLiveStream>[]);
          if (rows.isNotEmpty && !loadLanded) {
            loadLanded = true;
            trace.loadRows = rows.length;
            trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
            final before = out.length;
            _appendLiveMatches(rows, needle, limit, categoryNames, out, seen);
            trace.loadMatches += out.length - before;
          }
        }
      }
      finished = true;
      trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
      return out;
    } catch (e) {
      appLogger.w('IPTV: live search failed: $e');
      return const [];
    }
  }

  /// Same as [_appendMovieMatches], for live channel rows.
  void _appendLiveMatches(
    List<XtreamLiveStream> rows,
    String needle,
    int limit,
    Map<String, String> categoryNames,
    List<MediaItem> out,
    Set<int> seen,
  ) {
    // One case-insensitive pattern for the whole scan — see
    // [_appendMovieMatches].
    final match = RegExp(RegExp.escape(needle), caseSensitive: false);
    for (final stream in rows) {
      if (out.length >= limit) break;
      if (!seen.add(stream.streamId)) continue;
      if (_isHiddenCategory(stream.categoryId, categoryNames[stream.categoryId])) continue;
      if (!match.hasMatch(stream.name)) continue;
      out.add(_liveChannelItem(stream, categoryName: categoryNames[stream.categoryId]));
    }
  }

  /// A live channel as a searchable/playable item: same shape as the M3U
  /// search items, but with the Xtream /live/ URL, EPG id and catch-up
  /// flags. Keyed `live:<streamId>` so [fetchItem] can resolve it.
  MediaItem _liveChannelItem(XtreamLiveStream stream, {String? categoryName}) {
    return MediaItem.xtream(
      id: 'live:${stream.streamId}',
      kind: MediaKind.unknown,
      title: stripCategoryPrefix(stream.name, categoryName),
      thumbPath: stream.streamIcon,
      streamUrl: _xtreamApi.liveStreamUrl('${stream.streamId}'),
      epgChannelId: stream.epgChannelId,
      hasArchive: stream.tvArchive,
      archiveDuration: stream.tvArchiveDuration,
      categoryId: stream.categoryId,
      libraryId: _liveLibraryId,
      libraryTitle: '$_name — Live TV',
      serverId: connection.id,
      serverName: _name,
    );
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
      // One case-insensitive pattern for the whole scan — see
      // [_appendMovieMatches].
      final match = RegExp(RegExp.escape(needle), caseSensitive: false);
      for (final entry in entries) {
        if (out.length >= limit) break;
        // A hidden group (its own switch, or its category initial) hides
        // its entries from search too. Item names are never filtered.
        if (_isHiddenGroup(entry.groupTitle)) continue;
        if (!match.hasMatch(entry.name)) continue;
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
    // Map only the first `limit` rows (build #13): the old code built
    // all 199k items to take 20 of them.
    final movieRows = await _filteredVodRows();
    if (movieRows.isNotEmpty) {
      final movies = await _vodPageItems(movieRows, 0, limit);
      hubs.add(
        _recommendedHub(
          libraryId: _moviesLibraryId,
          title: '$_name — Movies',
          type: 'movie',
          all: movies,
          limit: limit,
          totalCount: movieRows.length,
        ),
      );
    }
    // Fail open per section: a series catalog failure (network, malformed
    // rows) must not take the Movies hub down with it — the per-library
    // fetch path already isolates the two, so the home path must too.
    try {
      final seriesRows = await _filteredSeriesRows();
      if (seriesRows.isNotEmpty) {
        final series = await _seriesPageItems(seriesRows, 0, limit);
        hubs.add(
          _recommendedHub(
            libraryId: _seriesLibraryId,
            title: '$_name — Series',
            type: 'show',
            all: series,
            limit: limit,
            totalCount: seriesRows.length,
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
      final rows = await _filteredVodRows();
      if (rows.isEmpty) return const [];
      final movies = await _vodPageItems(rows, 0, limit);
      return [
        _recommendedHub(
          libraryId: libraryId,
          title: 'Recommended',
          type: 'movie',
          all: movies,
          limit: limit,
          totalCount: rows.length,
        ),
      ];
    }
    if (libraryId == _seriesLibraryId) {
      final rows = await _filteredSeriesRows();
      if (rows.isEmpty) return const [];
      final series = await _seriesPageItems(rows, 0, limit);
      return [
        _recommendedHub(
          libraryId: libraryId,
          title: 'Recommended',
          type: 'show',
          all: series,
          limit: limit,
          totalCount: rows.length,
        ),
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
    // Row-level paging (build #13): the old code built the full 199k
    // item list through [_itemsForHubId] on every page turn.
    if (!_isXtream) return const LibraryPage(items: [], totalCount: 0);
    final offset = start ?? 0;
    if (hubId.contains(_moviesLibraryId)) {
      final rows = await _filteredVodRows();
      final items = await _vodPageItems(rows, offset, size ?? rows.length);
      return LibraryPage(items: items, totalCount: rows.length, offset: offset.clamp(0, rows.length));
    }
    if (hubId.contains(_seriesLibraryId)) {
      final rows = await _filteredSeriesRows();
      final items = await _seriesPageItems(rows, offset, size ?? rows.length);
      return LibraryPage(items: items, totalCount: rows.length, offset: offset.clamp(0, rows.length));
    }
    return const LibraryPage(items: [], totalCount: 0);
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
      final liveCategoryNames = await _liveCategoryNames();
      final channels = <LiveTvChannel>[];
      for (final stream in streams) {
        if (_isHiddenCategory(stream.categoryId, liveCategoryNames[stream.categoryId])) continue;
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
      // M3U categories are group titles; a hidden group hides its
      // channels from Live TV (same as Xtream's category filter above).
      if (_isHiddenGroup(entry.groupTitle)) continue;
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

/// On-device series catalog diagnostics (build #10): what the phone
/// reports about the series catalog — the unfiltered row count, the
/// series category count, per-category row counts for the first few
/// categories (direct get_series probes), and how many initials /
/// categories are turned off. A series search that still fails with a
/// healthy readout here points at timing, not at the data.
class IptvCatalogDiagnostics {
  const IptvCatalogDiagnostics({
    required this.unfilteredSeriesRows,
    required this.seriesCategoryCount,
    required this.perCategorySeriesRows,
    required this.hiddenCategoryInitialsCount,
    required this.hiddenCategoriesCount,
  });

  /// Rows the unfiltered get_series call returned (what Recommended reads).
  final int unfilteredSeriesRows;

  /// How many series categories the panel lists.
  final int seriesCategoryCount;

  /// Direct per-category get_series row counts, keyed "name (id)", for
  /// the first few series categories.
  final Map<String, int> perCategorySeriesRows;

  /// How many category initials are turned off on this connection.
  final int hiddenCategoryInitialsCount;

  /// How many categories are turned off by their own switch.
  final int hiddenCategoriesCount;
}

/// Per-section readout accumulated by one search (build #13): which
/// source supplied the matches and how long each leg took. A section's
/// methods fill their trace in as they go; [searchItems] turns the three
/// traces into the [IptvSearchDiagnostics] the settings row shows.
/// `loadRows` is -1 while the catalog load has not landed yet (so "load
/// never landed" reads differently from "load landed with 0 rows").
class _SectionTrace {
  int loadRows = -1;
  int loadMs = -1;
  int loadMatches = 0;
  int sweepMatches = 0;
  int partialMatches = 0;
  int ms = 0;
  bool skipped = false;

  /// The section's live result list, shared with the search so a section
  /// that runs out of budget returns what it already found instead of
  /// [] (build #13: the sweep had found the match and the 100ms margin
  /// between the 90% sweep deadline and the 100% section timeout was
  /// eaten, discarding the found match — the timeout must never throw
  /// found results away).
  List<MediaItem> partialOut = const [];

  int get returned => loadMatches + sweepMatches + partialMatches;

  IptvSearchSectionDiagnostics get diagnostics => IptvSearchSectionDiagnostics(
    loadRows: loadRows,
    loadMs: loadMs,
    loadMatches: loadMatches,
    sweepMatches: sweepMatches,
    partialMatches: partialMatches,
    ms: ms,
    skipped: skipped,
  );
}

/// One section of a [IptvSearchDiagnostics] readout: what the movies,
/// series or live leg saw during the last search.
class IptvSearchSectionDiagnostics {
  const IptvSearchSectionDiagnostics({
    required this.loadRows,
    required this.loadMs,
    required this.loadMatches,
    required this.sweepMatches,
    required this.partialMatches,
    required this.ms,
    required this.skipped,
  });

  /// Rows the catalog load produced (-1 when it never landed during the
  /// search, 0 when it landed empty).
  final int loadRows;

  /// Milliseconds the load took to land (-1 when it never landed).
  final int loadMs;

  /// Matches that came from the full catalog load.
  final int loadMatches;

  /// Matches that came from the per-category sweep.
  final int sweepMatches;

  /// Matches that came from the crawl's published partial rows.
  final int partialMatches;

  /// Wall time of the whole section, in milliseconds.
  final int ms;

  /// True when the section was excluded (scoped search).
  final bool skipped;

  /// Matches the section returned in total.
  int get returned => loadMatches + sweepMatches + partialMatches;
}

/// On-device search diagnostics (build #13): the readout for the LAST
/// search on this connection — the query, the scope, and per section
/// which source supplied the results and how long each leg took. One
/// screenshot of the settings row settles where a search dies: a load
/// that never lands (`loadRows: -1` after ~50s) is a slow catalog, a
/// load with rows but zero matches is the filter or the match, and a
/// sweep with zero matches while the load landed empty is the panel's
/// per-category shape. Shown in the IPTV settings screen next to the
/// series catalog diagnostics.
class IptvSearchDiagnostics {
  const IptvSearchDiagnostics({
    required this.query,
    required this.scoped,
    required this.totalMs,
    required this.movies,
    required this.series,
    required this.live,
    required this.recordedAt,
  });

  /// The searched query (trimmed, lower-cased as searched).
  final String query;

  /// True when a scope was active (some libraries excluded).
  final bool scoped;

  /// Wall time of the whole search, in milliseconds.
  final int totalMs;

  /// Movies leg readout.
  final IptvSearchSectionDiagnostics movies;

  /// Series leg readout.
  final IptvSearchSectionDiagnostics series;

  /// Live TV leg readout.
  final IptvSearchSectionDiagnostics live;

  /// When the search ran.
  final DateTime recordedAt;
}
