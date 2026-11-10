import 'dart:async';
import 'dart:collection';
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
import '../services/iptv/iptv_search_index.dart';
import '../services/settings_service.dart';
import '../services/playback_initialization_types.dart';
import '../services/scrub_preview_source.dart';
import '../utils/app_logger.dart';
import '../utils/external_ids.dart';
import '../utils/iptv_initials.dart';
import '../utils/library_content_notifier.dart';
import '../utils/media_server_http_client.dart' show AbortController;
import 'iptv_live_tv.dart';
import '../services/iptv/iptv_item_favorites_repository.dart';
import '../services/iptv/iptv_refusal_log.dart';
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
  /// The connection this client serves. Replaced only via
  /// [updateConnection] (build #17): a filter toggle re-binds the same
  /// connection with new filter state, and the client keeps its warm
  /// catalogs instead of being replaced with a cold one. The catalogs
  /// belong to the data source (server + credentials), not to the
  /// filter — filtering happens at read time — so they stay valid.
  Connection connection;

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

  /// Swap the served connection for [next] (build #17): a filter toggle
  /// (or a display-only edit) re-binds the same connection, and the
  /// client keeps its warm in-memory catalogs, its in-flight loads, and
  /// its disk-cache handles instead of re-paying all three warm-ups
  /// (parse alone is ~1.3–1.5 s at Trex scale, before network, health
  /// probe and tab/guide reloads — that cascade is the toggle lag).
  ///
  /// Only the filter/display fields may differ. Throws [ArgumentError]
  /// when the id or the data source differs (Xtream: server URL /
  /// username / password; M3U: playlist URL / EPG URL) — the caller must
  /// replace the client instead, because the warm catalogs belong to the
  /// old data source. The lazily-built [_xtreamApi] stays valid because
  /// the data source is unchanged.
  void updateConnection(Connection next) {
    if (next.id != connection.id) {
      throw ArgumentError('IptvClient.updateConnection: id changed (${connection.id} -> ${next.id})');
    }
    if (!_sameDataSource(connection, next)) {
      throw ArgumentError('IptvClient.updateConnection: data source changed for ${connection.id}');
    }
    connection = next;
  }

  static bool _sameDataSource(Connection a, Connection b) {
    if (a is XtreamConnection && b is XtreamConnection) {
      return a.serverUrl == b.serverUrl && a.username == b.username && a.password == b.password;
    }
    if (a is M3uConnection && b is M3uConnection) {
      return a.playlistUrl == b.playlistUrl && a.epgUrl == b.epgUrl;
    }
    return false;
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
    // Build #20: the User-Agent is re-read from Settings on every request,
    // so changing Settings → IPTV → Xtream User-Agent applies to the next
    // request without rebuilding the client (or restarting the app).
    userAgentProvider: _xtreamUserAgent,
    // Build #27: every refused response and transport failure is handed
    // to the refusal log (Settings → IPTV → Connection refusals) with
    // its headers and body — the 403 the app used to discard is the
    // diagnostic. Record-only: the exception the caller sees is
    // unchanged, and no request is added.
    onRefusal: (entry) => IptvRefusalLog.instance.record(entry),
    connectionId: connection.id,
    connectionName: _name,
  );

  /// The configured Xtream User-Agent for this client's requests (build
  /// #20). Falls back to VLC when Settings is not initialized yet (tests)
  /// or the stored choice is unknown — a request must never go out with
  /// no User-Agent.
  static String _xtreamUserAgent() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return XtreamUserAgent.vlc;
    return XtreamUserAgent.resolve(
      settings.read(SettingsService.iptvXtreamUserAgent),
      settings.read(SettingsService.iptvXtreamUserAgentCustom),
    );
  }

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

  /// The display name of a live channel by its key (build #17, §10) —
  /// the EPG name-fallback match. Xtream: the stream name; M3U: the
  /// entry name. Null when the key is unknown.
  String? channelNameForChannelKey(String channelKey) {
    if (_isXtream) return _xtreamChannelByKey[channelKey]?.name;
    return _m3uChannelByKey[channelKey]?.name;
  }

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

  /// Where the last catalog load came from (build #18): 'disk', 'network'
  /// or 'crawl'. The search diagnostics render it, so a poisoned disk is
  /// visible on the phone: a disk list written from a per-category crawl
  /// lacks every category hidden when it was written. '' before any load.
  String _vodLoadSource = '';
  String _seriesLoadSource = '';
  String _liveLoadSource = '';

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

  /// Matches the last search found but the hidden-category filter
  /// removed, for one library (build #17): the search screen's empty
  /// state tells the user the filter hid them instead of showing a bare
  /// "No results". 0 when there was no search yet, or when the library
  /// is not one of this connection's movies/series libraries.
  int lastSearchHiddenMatchesForLibrary(String libraryId) {
    final diagnostics = _lastSearchDiagnostics;
    if (diagnostics == null) return 0;
    if (libraryId == _seriesLibraryId) return diagnostics.series.hiddenMatches;
    if (libraryId == _moviesLibraryId) return diagnostics.movies.hiddenMatches;
    return 0;
  }

  // -- Local search index (build #23) -------------------------------------
  //
  // The whole catalog is synced once into a local SQLite FTS5 trigram
  // index ([IptvSearchIndex]), and search queries it instead of the
  // provider — zero panel requests during a search when the index is
  // warm. The index is derived/rebuildable cache data in its own file,
  // so it can never touch the main database; a broken index just reads
  // as cold and the search falls back to the old disk/sweep paths.
  //
  // The index is opened lazily (first search/sync/seed) and shared by
  // the client's search, sync and seed paths. Writes (sync + disk seed)
  // run in a background isolate via compute and are serialized by
  // [_runIndexWrite] — the seed and the sync never write at once.

  Future<IptvSearchIndex?>? _searchIndexFuture;
  IptvSearchIndex? _searchIndexInstance;

  /// True once [close] has run: in-flight seeds/syncs must not touch
  /// the notifier (or re-open the index) after teardown.
  bool _closed = false;

  /// The single in-flight index write (seed or sync), if any. A second
  /// writer joins this future instead of starting its own — the seed
  /// (warm-up) and the sync (bind/manual refresh) serialize through it.
  Future<void>? _indexWriteInFlight;

  /// The index state the search screen's catalog-health line and the
  /// settings cache-size row read. Updated when the index opens, when a
  /// seed/sync starts, and when one lands.
  final ValueNotifier<IptvSearchIndexState> searchIndexStateNotifier =
      ValueNotifier(const IptvSearchIndexState.empty());

  /// The current index state (same value as [searchIndexStateNotifier]).
  IptvSearchIndexState get searchIndexState => searchIndexStateNotifier.value;

  /// The index, opened on first use. Null when this client is M3U (no
  /// VOD/series catalog to index — its playlist search is already
  /// local-only) or when the index is disabled for tests.
  Future<IptvSearchIndex?> _searchIndex() {
    final existing = _searchIndexFuture;
    if (existing != null) return existing;
    final future = () async {
      if (_closed) return null;
      if (!_isXtream || IptvSearchIndex.debugDisableDisk || IptvCatalogDiskCache.debugDisableDisk) return null;
      try {
        final index = await IptvSearchIndex.open();
        _searchIndexInstance = index;
        _refreshSearchIndexState();
        return index;
      } catch (e) {
        appLogger.w('IPTV: search index unavailable, search falls back to disk/sweep: $e');
        return null;
      }
    }();
    _searchIndexFuture = future;
    return future;
  }

  /// Re-read the index meta (row counts + last sync) into the notifier.
  /// Never throws — a broken index reads as empty. No-op after [close]
  /// (an in-flight seed/sync's finally must not touch a disposed
  /// notifier).
  void _refreshSearchIndexState({bool syncing = false, bool seeding = false}) {
    if (_closed) return;
    final index = _searchIndexInstance;
    if (index == null) return;
    try {
      searchIndexStateNotifier.value = IptvSearchIndexState(
        rowCounts: index.rowCounts(connection.id),
        lastSync: index.lastSync(connection.id),
        syncing: syncing,
        seeding: seeding,
      );
    } catch (e) {
      appLogger.w('IPTV: search index state unreadable', error: e);
    }
  }

  /// Run [work] as the single index write (seed or sync). A second
  /// caller waits for the in-flight write, then runs its own work (and
  /// re-checks the warm/interval state then — the first write may have
  /// made it unnecessary). The seed (warm-up) and the sync (bind/manual
  /// refresh) serialize through this, so they can never write the index
  /// at once. Callers already inside a write call the private work
  /// functions directly, never this — re-entering the mutex would
  /// deadlock.
  Future<T> _runIndexWrite<T>(Future<T> Function() work) async {
    while (_indexWriteInFlight != null) {
      await _indexWriteInFlight;
    }
    final future = work();
    _indexWriteInFlight = future;
    try {
      return await future;
    } finally {
      if (identical(_indexWriteInFlight, future)) _indexWriteInFlight = null;
    }
  }

  /// A future that completes when the current index write (seed or sync)
  /// finishes, or immediately when none is running. Tests await this
  /// after a warm-up instead of sleeping for the background seed.
  @visibleForTesting
  Future<void> get searchIndexReady => _indexWriteInFlight ?? Future.value();

  /// Seed the index from the disk catalog (build #23, the upgrade path).
  /// The warm-ups call this fire-and-forget: on the first run after
  /// upgrading to 1.0.6 the disk catalog already holds the full lists,
  /// so the index is warm within seconds with NO network at all, and
  /// search is local-only from the first search. A type that is already
  /// warm is skipped (the sync owns refreshes); a type with no disk
  /// file is skipped (the sync fetches it). The isolate refuses a
  /// partial / category-less source (see [IndexWriteResult]), so a
  /// crawl-shaped disk file can never seed an incomplete index — the
  /// type stays cold and the fallback sweep still heals it.
  Future<void> seedSearchIndexFromDisk() => _runIndexWrite(_seedSearchIndexFromDisk);

  Future<void> _maybeSeedSearchIndexFromDisk() => _runIndexWrite(_seedSearchIndexFromDisk);

  Future<void> _seedSearchIndexFromDisk() async {
    if (!_isXtream) return;
    final index = await _searchIndex();
    if (index == null) return;
    final dbPath = await IptvSearchIndex.dbFilePath();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final counts = index.rowCounts(connection.id);
    _refreshSearchIndexState(seeding: true);
    try {
      for (final type in IptvSearchIndex.types) {
        if ((counts[type] ?? 0) > 0) continue;
        final dataset = _diskDatasetFor(type);
        final catDataset = _diskCategoryDatasetFor(type);
        final catalog = await _catalogCache.read(connection.id, dataset);
        final categories = await _catalogCache.read(connection.id, catDataset);
        if (catalog == null || categories == null) continue;
        if (catalog.body.isEmpty || categories.body.isEmpty) continue;
        try {
          final result = await compute(
            writeIndexTypeInBackground,
            IndexWriteParams(
              dbPath: dbPath,
              connectionId: connection.id,
              type: type,
              catalogBody: catalog.body,
              categoryBody: categories.body,
              syncStampMs: nowMs,
            ),
          );
          if (result.skippedReason != null) {
            appLogger.i(
              'IPTV: search index seed skipped $type (${result.skippedReason}) — the sync will fetch it',
            );
          }
        } catch (e) {
          appLogger.w('IPTV: search index seed failed for $type', error: e);
        }
      }
    } finally {
      _refreshSearchIndexState();
    }
  }

  static String _diskDatasetFor(String type) => switch (type) {
        IptvSearchIndex.typeLive => IptvCatalogDiskCache.liveDataset,
        IptvSearchIndex.typeMovie => IptvCatalogDiskCache.vodDataset,
        _ => IptvCatalogDiskCache.seriesDataset,
      };

  static String _diskCategoryDatasetFor(String type) => switch (type) {
        IptvSearchIndex.typeLive => IptvCatalogDiskCache.liveCategoriesDataset,
        IptvSearchIndex.typeMovie => IptvCatalogDiskCache.vodCategoriesDataset,
        _ => IptvCatalogDiskCache.seriesCategoriesDataset,
      };

  /// Hours between catalog syncs (Settings → IPTV, default once a week,
  /// 0 = manual only). Falls back to weekly when Settings is not
  /// initialized yet (tests).
  int _catalogSyncIntervalHours() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return SettingsService.iptvCatalogSyncIntervalHours.defaultValue;
    return settings.read(SettingsService.iptvCatalogSyncIntervalHours);
  }

  /// Sync the whole catalog into the local search index (build #23).
  /// Fetches each type's category list + unfiltered catalog from the
  /// panel (6 requests total — the only panel traffic search ever
  /// causes), applies the sync-time guards as one choke point, and
  /// replaces that type's index rows atomically. The guards (OpenTV
  /// `replaceCatalogue` + IPTVMac SyncService, generalising build #19's
  /// P5a): an empty response keeps the old rows; a partial response
  /// (fewer than half the indexed rows, when the index has rows) keeps
  /// the old rows; a response over the 300 MB cap is refused before
  /// parsing; a write never deletes all rows. A type whose interval has
  /// not elapsed is skipped ('up-to-date') unless [force] (manual
  /// refresh). [onProgress] drives the "refreshing Trex details" popup;
  /// [abort] (the popup's Cancel) stops the sync between types — types
  /// already synced stay synced.
  Future<IptvSearchSyncResult> syncSearchIndex({
    bool force = false,
    void Function(IptvSearchSyncProgress)? onProgress,
    AbortController? abort,
  }) async {
    if (!_isXtream) return const IptvSearchSyncResult(rows: {}, skipped: {});
    return _runIndexWrite(() => _syncSearchIndex(force: force, onProgress: onProgress, abort: abort));
  }

  Future<IptvSearchSyncResult> _syncSearchIndex({
    required bool force,
    void Function(IptvSearchSyncProgress)? onProgress,
    AbortController? abort,
  }) async {
    final index = await _searchIndex();
    if (index == null) {
      return const IptvSearchSyncResult(rows: {}, skipped: {
        IptvSearchIndex.typeLive: 'failed',
        IptvSearchIndex.typeMovie: 'failed',
        IptvSearchIndex.typeSeries: 'failed',
      });
    }
    final rows = <String, int>{};
    final skipped = <String, String>{};
    final intervalHours = _catalogSyncIntervalHours();
    final dbPath = await IptvSearchIndex.dbFilePath();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    _refreshSearchIndexState(syncing: true);
    try {
      for (final type in IptvSearchIndex.types) {
        abort?.throwIfAborted();
        final lastSync = index.lastSync(connection.id)[type];
        final indexedCount = index.rowCounts(connection.id)[type] ?? 0;
        if (!force && intervalHours > 0 && lastSync != null && indexedCount > 0) {
          final ageHours = DateTime.now().difference(lastSync).inHours;
          if (ageHours < intervalHours) {
            skipped[type] = 'up-to-date';
            onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'up-to-date'));
            continue;
          }
        }
        if (!force && intervalHours == 0 && indexedCount > 0) {
          // Manual-only interval and the index already has rows: only
          // an explicit manual refresh (force) syncs.
          skipped[type] = 'up-to-date';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'up-to-date'));
          continue;
        }
        onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'fetching'));
        List<XtreamCategory> categories;
        int fetchedCount;
        String? catalogBody;
        // Hoisted out of the fetch try so the disk write + memoized
        // publish below can use the parsed rows after the guards pass.
        List<Object>? fetchedRows;
        try {
          categories = await _fetchCategoriesFor(type, abort);
          // The unfiltered getters store the raw body on the api (see
          // lastXxxStreamsBody) — read it synchronously right after the
          // await, before any other await, so a concurrent browse load
          // cannot swap it underneath this sync.
          final List<Object> fetched;
          switch (type) {
            case IptvSearchIndex.typeLive:
              fetched = await _xtreamApi.getLiveStreams(abortTrigger: abort?.trigger);
              catalogBody = _xtreamApi.lastLiveStreamsBody;
            case IptvSearchIndex.typeMovie:
              fetched = await _xtreamApi.getVodStreams(abortTrigger: abort?.trigger);
              catalogBody = _xtreamApi.lastVodStreamsBody;
            default:
              fetched = await _xtreamApi.getSeries(abortTrigger: abort?.trigger);
              catalogBody = _xtreamApi.lastSeriesBody;
          }
          fetchedRows = fetched;
          fetchedCount = fetched.length;
        } on XtreamCatalogTooLargeException {
          skipped[type] = 'oversize';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'oversize'));
          continue;
        } catch (e) {
          appLogger.w('IPTV: catalog sync fetch failed for $type', error: e);
          skipped[type] = 'failed';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'failed'));
          continue;
        }
        // Sync-time guards (the choke point): empty keeps the old rows;
        // partial (< half the indexed rows, when the index has rows)
        // keeps the old rows — a partial list must never overwrite a
        // good index (the P5a class).
        final body = catalogBody;
        if (fetchedCount == 0 || body == null || body.isEmpty) {
          skipped[type] = 'empty-response';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'empty-response'));
          continue;
        }
        if (indexedCount > 0 && fetchedCount < indexedCount ~/ 2) {
          skipped[type] = 'partial';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'partial'));
          continue;
        }
        onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'writing', rows: fetchedCount));
        try {
          final result = await compute(
            writeIndexTypeInBackground,
            IndexWriteParams(
              dbPath: dbPath,
              connectionId: connection.id,
              type: type,
              catalogBody: body,
              categoryBody: jsonEncode(categories.map((c) => c.toJson()).toList()),
              syncStampMs: nowMs,
            ),
          );
          if (result.skippedReason != null) {
            skipped[type] = result.skippedReason!;
            onProgress?.call(
              IptvSearchSyncProgress(type: type, phase: 'skipped', reason: result.skippedReason),
            );
            continue;
          }
          rows[type] = result.rowCount;
          // Build #23 (startup rule): the sync is the ONLY catalog
          // fetcher, so it also refreshes the disk catalog the browse
          // screens and the warm-ups read from (raw body + category
          // list), and publishes the fresh rows into the memoized
          // futures so the session sees them without a restart. A
          // guarded-out sync leaves both the disk file and the index
          // untouched. A disk-write failure never fails the sync — the
          // index is the primary store.
          try {
            await _catalogCache.write(connection.id, _diskDatasetFor(type), body);
            await _catalogCache.write(
              connection.id,
              _diskCategoryDatasetFor(type),
              jsonEncode(categories.map((c) => c.toJson()).toList()),
            );
            // fetchedRows is set by the fetch try above; every failure
            // path (throw, empty, partial, oversize) continues past here.
            _publishSyncedCatalog(type, fetchedRows);
          } catch (e) {
            appLogger.w('IPTV: catalog sync disk write failed for $type', error: e);
          }
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'done', rows: result.rowCount));
        } catch (e) {
          appLogger.w('IPTV: catalog sync write failed for $type', error: e);
          skipped[type] = 'failed';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'failed'));
        }
      }
      return IptvSearchSyncResult(rows: rows, skipped: skipped);
    } finally {
      _refreshSearchIndexState();
    }
  }

  /// Publish freshly synced rows into the memoized catalog futures
  /// (build #23): the warm-up may have populated them with the stale
  /// disk rows, and the sync is the newer truth — browse/search must
  /// see the refreshed catalog without a restart.
  void _publishSyncedCatalog(String type, List<Object> rows) {
    switch (type) {
      case IptvSearchIndex.typeLive:
        _liveStreamsFuture = Future.value(rows.cast<XtreamLiveStream>());
        _liveStreamsLoaded = true;
        _liveLoadSource = 'network';
      case IptvSearchIndex.typeMovie:
        _vodStreamsFuture = Future.value(rows.cast<XtreamVodStream>());
        _vodStreamsLoaded = true;
        _vodLoadSource = 'network';
      default:
        _seriesFuture = Future.value(rows.cast<XtreamSeries>());
        _seriesListLoaded = true;
        _seriesLoadSource = 'network';
    }
  }

  Future<List<XtreamCategory>> _fetchCategoriesFor(String type, AbortController? abort) {
    return switch (type) {
      IptvSearchIndex.typeLive => _xtreamApi.getLiveCategories(abortTrigger: abort?.trigger),
      IptvSearchIndex.typeMovie => _xtreamApi.getVodCategories(abortTrigger: abort?.trigger),
      _ => _xtreamApi.getSeriesCategories(abortTrigger: abort?.trigger),
    };
  }

  /// Make sure the search index is populated and fresh (build #23).
  /// Called at bind ([MultiServerManager.addIptvConnection]): seeds the
  /// index from the disk catalog when it is cold, then runs the network
  /// sync when the interval has elapsed. Fire-and-forget — binding must
  /// not wait for a catalog sync. A manual refresh calls
  /// [syncSearchIndex] with force: true instead.
  void ensureSearchIndexSynced() {
    if (!_isXtream) return;
    unawaited(
      _runIndexWrite(() async {
        await _seedSearchIndexFromDisk();
        await _syncSearchIndex(force: false, onProgress: null, abort: null);
      }),
    );
  }
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

  /// Build #21 — the search burst cap. ONE number for the whole search:
  /// the three sections (movies, series, live) plus any concurrent search
  /// on this client share one [_SearchRequestSemaphore] of this size, so
  /// the panel never sees more than this many search requests in flight
  /// at once. Before, each section ran 32 concurrent category calls, so
  /// a cold search put ~96 requests on a panel that allows 1 connection.
  ///
  /// Why 8: the sweep must still reach the last category ("|EN| TOP
  /// SERIES", 237th of 237) inside the 49s sweep deadline at realistic
  /// per-call latency — that is build #19's heal guarantee, and the
  /// P4-fast probe (1s per call, 232 categories to sweep) is the test
  /// of it. Cap 4 fails it: 232 / 4 x 1s = 58s > 49s, so the heal
  /// misses Game of Thrones on a slow panel. Cap 8 passes it: 232 / 8
  /// x 1s = 29s, with 20s of margin. 8 is the top of Matt's low-end
  /// range (4-8) and the smallest cap that keeps the heal working at
  /// 1s per call; the in-harness reach test proves it at 250ms and
  /// 500ms per call too. A slower panel (6s per call, the P4-slow
  /// stress case) cannot be swept inside the deadline at any cap Matt's
  /// range allows — the unfiltered load, which runs outside the cap, is
  /// the primary path then. 8 is still a 12x cut from the old ~96
  /// concurrent requests, and 4x down from the old per-section 32.
  /// (Build #17's 32 existed only to cover the list inside the deadline
  /// at 6s per call — a degraded panel — and that is exactly the volume
  /// that reads as abuse.)
  static const int _searchBurstCap = 8;

  /// The burst cap, for tests: assert the max in-flight sweep requests
  /// against this, not a literal, so a cap change stays honest.
  @visibleForTesting
  static int get searchBurstCap => _searchBurstCap;

  /// The search-wide burst semaphore (build #21): one per client, shared
  /// by the three sections of every search on this client — so a second
  /// keystroke's sweep shares the cap with the first instead of adding a
  /// second burst on top of it. A permit is released when its call lands
  /// (or aborts); a permit is never held past the section budget.
  final _SearchRequestSemaphore _searchBurst = _SearchRequestSemaphore(_searchBurstCap);

  /// Consecutive transient health-probe failures (build #21). A single
  /// timeout / 429 / 5xx / socket error must not flip the server offline
  /// — the panel is slow or throttling, not gone — so the offline verdict
  /// needs this many in a row. Probes are event-driven (resume, manual
  /// reconnect, connectivity change), not periodic, so 3 means three
  /// separate triggers agreed, not one slow probe under a burst.
  static const int _transientFailuresBeforeOffline = 3;

  int _consecutiveTransientHealthFailures = 0;

  /// The last health verdict this client published (build #21). A
  /// transient probe failure returns this instead of offline, so the app
  /// keeps the last-known state while the panel struggles.
  HealthStatus _lastHealthStatus = HealthStatus.online;

  /// Searches currently in flight on this client (build #21). A health
  /// probe that fires while one is running is deferred, not dropped (see
  /// [_deferredHealthProbe]).
  int _activeSearchCount = 0;

  /// The section AbortControllers of the searches currently in flight on
  /// this client (build #21, close-after-use). [cancelActiveSearches]
  /// aborts every controller in this set, which hard-cancels the
  /// sections' in-flight requests (the sockets close via
  /// AbortableRequest) so a search the user has walked away from — app
  /// backgrounded, connection torn down — stops talking to the panel.
  /// A controller is added when its search starts and removed when the
  /// search's sections all settle; aborting a controller that already
  /// settled is a no-op, so a stale entry is harmless but they are
  /// removed promptly to keep the set bounded.
  final Set<AbortController> _activeSearchAborts = {};

  /// A health probe arrived while a search was in flight (build #21).
  /// Cleared when the deferred probe fires, once, after the search ends.
  bool _deferredHealthProbe = false;

  /// Called once, coalesced, when a deferred health probe fires (build
  /// #21): the search has ended and the probe that arrived mid-search
  /// should run now. Set by [MultiServerManager] when it binds the
  /// client; null in tests and for clients the manager never bound. The
  /// manager re-probes this one connection and applies the verdict.
  void Function(IptvClient client)? onDeferredHealthProbe;

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
    // Idempotent: tests (and the manager's graceful close) can close
    // the same client twice (explicit close + tearDown) — disposing the
    // notifier twice throws, so the second close is a no-op.
    if (_closed) return;
    _closed = true;
    _api?.close();
    _http.close();
    // Build #23: close the search index connection (the file stays —
    // it is the synced catalog, re-opened on the next bind).
    _searchIndexInstance?.close();
    _searchIndexInstance = null;
    _searchIndexFuture = null;
    searchIndexStateNotifier.dispose();
  }

  /// Cancel every search currently in flight on this client (build #21,
  /// close-after-use — Matt: "should the connection have a close
  /// function so it stops talking after?"). Aborts each in-flight
  /// section's controller, which hard-cancels its requests (the sockets
  /// close via AbortableRequest) so no further panel traffic is
  /// generated for a search the user has walked away from. Called when
  /// the app backgrounds ([MultiServerManager.cancelActiveIptvSearches],
  /// wired in main.dart) and when a connection is torn down. Safe to
  /// call with no search in flight (no-op). The client stays usable
  /// afterwards — only the in-flight searches are cancelled, not the
  /// connection itself (use [close] to tear the connection down).
  /// NOTE: the background catalog crawl is NOT cancelled by this — it
  /// is a bounded batch walk (16 per batch) that populates the disk
  /// cache, and it only runs when the unfiltered load returns []; it
  /// finishes on its own and never re-runs for the same catalog.
  void cancelActiveSearches() {
    for (final abort in _activeSearchAborts.toList()) {
      abort.abort();
    }
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
    _seriesInfoFutures.clear();
    _xtreamChannelByKey.clear();
    _m3uChannelByKey.clear();
    unawaited(_catalogCache.clear(connection.id));
    // Build #23: the search index is derived from the catalog, so a
    // clear rebuilds it too — the next search falls back to the
    // disk/sweep paths until the next sync seeds it again. The index
    // file itself is NOT deleted (the rows are, per connection), so the
    // schema and the other connections' rows survive.
    unawaited(_clearSearchIndex());
    // A manual clear is the user's own action: the tabs must refresh
    // promptly, not at the pacer cooldown's trailing edge (build #14).
    notifyCatalogRefreshed(userInitiated: true);
  }

  /// Clear the disk catalog + search index rows for this connection
  /// (build #23): called by the manager when it replaces the client
  /// for a data-source change (new server URL / credentials), so the new
  /// client never serves the old source's data. Awaited before the
  /// warm-ups — the new client starts cold and the background sync
  /// fetches the new source. Unlike [clearCatalogCache] this deletes the
  /// index rows even when this client never opened the index (the rows
  /// belong to the connection id, shared across client instances).
  Future<void> clearCatalogForNewDataSource() async {
    await _catalogCache.clear(connection.id);
    final index = await _searchIndex();
    if (index != null) {
      await _runIndexWrite(() => index.deleteConnection(connection.id));
      _refreshSearchIndexState();
    }
  }

  Future<void> _clearSearchIndex() async {
    // Only when the index was already opened: opening it just to delete
    // rows that cannot exist yet would create the file for nothing.
    final index = _searchIndexInstance;
    if (index == null) return;
    await _runIndexWrite(() => index.deleteConnection(connection.id));
    _refreshSearchIndexState();
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

  /// Headers for direct-play stream opens from this panel (build #22):
  /// the same configured Xtream User-Agent the API client sends, so the
  /// stream carries one identity with the catalog calls instead of
  /// mpv/ffmpeg's default. Re-read per access (like [_xtreamUserAgent]),
  /// so a Settings change applies to the next open. Applies to Xtream and
  /// M3U alike — both serve streams from the provider.
  @override
  Map<String, String> get streamHeaders => {'User-Agent': _xtreamUserAgent()};

  /// Headers for artwork fetches from this panel (build #22): posters and
  /// channel logos carry the same configured Xtream User-Agent instead of
  /// 'Plezy'. Read by [MediaImageHelper.artworkHeadersFor].
  Map<String, String> get artworkHeaders => {'User-Agent': _xtreamUserAgent()};

  @override
  double get watchedThreshold => 0.9;

  @override
  bool get marksWatchedOnPlaybackStopped => false;

  @override
  LiveTvSupport get liveTv => _liveTv;

  @override
  Future<HealthStatus> checkHealth() async {
    // Build #21: a probe that fires while a search is in flight is
    // deferred, not dropped. The search is already exercising the panel,
    // and a concurrent probe just adds a request to a busy line. Return
    // the last-known verdict with no request; the probe runs once,
    // coalesced, when the search ends (see [_fireDeferredHealthProbe]).
    if (_activeSearchCount > 0) {
      _deferredHealthProbe = true;
      return _lastHealthStatus;
    }
    if (_isXtream) {
      try {
        final info = await _xtreamApi.getUserInfo();
        if (info == null) return _publishHealth(HealthStatus.authError);
        return _publishHealth(HealthStatus.online);
      } on MediaServerAuthException {
        return _publishHealth(HealthStatus.authError);
      } on MediaServerHttpException catch (e) {
        if (e.statusCode == 403) return _publishHealth(HealthStatus.accessDenied);
        // A cancelled probe says nothing about the server — and it is
        // not a failure, so it does not advance the transient streak.
        if (e.isCancellation) return _lastHealthStatus;
        // Build #21: timeouts, 429s and 5xx are transient — the panel is
        // slow or throttling, not gone. They need N in a row before the
        // server is published offline (see [_recordTransientHealthFailure]).
        if (e.isTransient || e.statusCode == 429 || (e.statusCode != null && e.statusCode! >= 500)) {
          return _recordTransientHealthFailure();
        }
        // Any other 4xx (400/404/405/410...) is definitive: the request
        // reached the panel and was refused for a reason a retry will not
        // fix. Publish offline immediately.
        return _publishHealth(HealthStatus.offline);
      } catch (e) {
        appLogger.d('IPTV health probe failed', error: e);
        // Not an HTTP verdict at all (defensive: getUserInfo only throws
        // the two typed exceptions above). A network-shaped failure is
        // transient; anything else publishes offline.
        if (MediaServerHttpException.from(e).isTransient) return _recordTransientHealthFailure();
        return _publishHealth(HealthStatus.offline);
      }
    }
    try {
      final response = await _http.head(Uri.parse(_m3u.playlistUrl)).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) return _publishHealth(HealthStatus.online);
      if (response.statusCode == 401) return _publishHealth(HealthStatus.authError);
      if (response.statusCode == 403) return _publishHealth(HealthStatus.accessDenied);
      if (response.statusCode == 429 || response.statusCode >= 500) return _recordTransientHealthFailure();
      return _publishHealth(HealthStatus.offline);
    } catch (e) {
      appLogger.d('IPTV health probe failed', error: e);
      if (MediaServerHttpException.from(e).isTransient) return _recordTransientHealthFailure();
      return _publishHealth(HealthStatus.offline);
    }
  }

  /// Publish a definitive health verdict: reset the transient streak and
  /// remember the verdict as the last-known state (build #21).
  HealthStatus _publishHealth(HealthStatus status) {
    _consecutiveTransientHealthFailures = 0;
    _lastHealthStatus = status;
    return status;
  }

  /// Record one transient health-probe failure (build #21): a timeout,
  /// 429, 5xx or socket error. Returns the last-known verdict until the
  /// streak reaches [_transientFailuresBeforeOffline], then publishes
  /// offline — the panel has failed three separate probes in a row, so
  /// it is down, not merely slow.
  HealthStatus _recordTransientHealthFailure() {
    _consecutiveTransientHealthFailures++;
    if (_consecutiveTransientHealthFailures >= _transientFailuresBeforeOffline) {
      return _publishHealth(HealthStatus.offline);
    }
    return _lastHealthStatus;
  }

  /// Fire the health probe deferred during a search (build #21), once.
  /// The manager re-probes this one connection; without a manager binding
  /// there is nothing to fire and the flag just clears.
  void _fireDeferredHealthProbe() {
    if (!_deferredHealthProbe) return;
    _deferredHealthProbe = false;
    onDeferredHealthProbe?.call(this);
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
      _liveLoadSource = 'disk';
      if (IptvCatalogDiskCache.isStale(disk.fetchedAt)) {
        _refreshCatalogInBackground<XtreamLiveStream>(
          dataset: IptvCatalogDiskCache.liveDataset,
          fetch: () async {
            final rows = await _xtreamApi.getLiveStreams();
            if (rows.isNotEmpty) _liveLoadSource = 'network';
            return rows;
          },
          toJson: (r) => r.toJson(),
          swap: (rows) => _liveStreamsFuture = Future.value(rows),
          rawBody: () => _xtreamApi.lastLiveStreamsBody,
        );
      }
      return disk.rows;
    }
    final rows = await _xtreamApi.getLiveStreams();
    _liveLoadSource = 'network';
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
  ///
  /// Build #18: the disk write happens ONLY when the load came from the
  /// unfiltered call. A crawl's rows are missing every hidden category,
  /// so persisting them bakes the filter into storage — the exact poison
  /// that made Trex series search return [] on the phone (the VOD loader
  /// has the same shape). Crawl rows are served in memory, never written.
  Future<List<XtreamVodStream>> _loadVodStreamsCached() async {
    final disk = await _readDiskCatalog<XtreamVodStream>(
      IptvCatalogDiskCache.vodDataset,
      XtreamApi.parseVodStreamsBody,
    );
    if (disk != null) {
      _vodLoadSource = 'disk';
      if (IptvCatalogDiskCache.isStale(disk.fetchedAt)) {
        // Build #19: the P5a guard needs the file's row count inside
        // the refresh closure (captured before the call so the null
        // promotion survives into the closure).
        final diskRowCount = disk.rows.length;
        _refreshCatalogInBackground<XtreamVodStream>(
          dataset: IptvCatalogDiskCache.vodDataset,
          fetch: () async {
            final loaded = await _loadVodStreams();
            // A crawl-shaped refresh must not overwrite the disk file:
            // return [] so the refresh skips, and the served rows stay
            // the disk rows (the source stays 'disk' with them).
            if (loaded.complete) {
              // Build #19: a PARTIAL unfiltered list must not overwrite
              // a larger good disk file — same poison as series (P5a):
              // the panel can answer the unfiltered call with a small
              // partial list while the file holds the full catalog, and
              // accepting it poisons the disk for the 24 h TTL even after
              // the panel recovers. Refuse the write when the new list
              // is under half the file's size; the stale file keeps
              // serving and the next warm-up retries the refresh.
              if (loaded.rows.length * 2 < diskRowCount) {
                return const <XtreamVodStream>[];
              }
              _vodLoadSource = 'network';
              return loaded.rows;
            }
            return const <XtreamVodStream>[];
          },
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
    final loaded = await _loadVodStreams();
    _vodLoadSource = loaded.complete ? 'network' : 'crawl';
    if (loaded.complete) {
      _writeCatalogRows(IptvCatalogDiskCache.vodDataset, loaded.rows, (r) => r.toJson(), _xtreamApi.lastVodStreamsBody);
    }
    return loaded.rows;
  }

  /// Unfiltered first (the fast path when the panel answers); when it
  /// returns [], fall back to a per-category fetch — the panel answers
  /// per-category calls even when the unfiltered call is empty.
  ///
  /// Returns whether the rows came from the unfiltered call ([complete])
  /// or the per-category crawl: crawl rows are missing every hidden
  /// category, so they must never be persisted as the catalog (build
  /// #18) — see [_loadVodStreamsCached].
  Future<({List<XtreamVodStream> rows, bool complete})> _loadVodStreams() async {
    final all = await _xtreamApi.getVodStreams();
    if (all.isNotEmpty) return (rows: all, complete: true);
    final categories = await _vodCategories().catchError((Object e) {
      appLogger.w('IPTV: VOD category list unavailable for fallback: $e');
      return const <XtreamCategory>[];
    });
    final wanted = categories.where((c) => !_isHiddenCategory(c.id, c.name)).toList(growable: false);
    if (wanted.isEmpty) return (rows: const <XtreamVodStream>[], complete: false);
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
    return (rows: out, complete: false);
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
  ///
  /// Build #18: the disk write happens ONLY when the load came from the
  /// unfiltered call. A crawl's rows are missing every hidden category,
  /// so persisting them bakes the filter into storage — the poison that
  /// made Trex series search return [] on the phone. Crawl rows are
  /// served in memory, never written.
  Future<List<XtreamSeries>> _loadSeriesCached() async {
    final disk = await _readDiskCatalog<XtreamSeries>(
      IptvCatalogDiskCache.seriesDataset,
      XtreamApi.parseSeriesBody,
    );
    if (disk != null) {
      _seriesLoadSource = 'disk';
      if (IptvCatalogDiskCache.isStale(disk.fetchedAt)) {
        // Build #19: the P5a guard needs the file's row count inside
        // the refresh closure (captured before the call so the null
        // promotion survives into the closure).
        final diskRowCount = disk.rows.length;
        _refreshCatalogInBackground<XtreamSeries>(
          dataset: IptvCatalogDiskCache.seriesDataset,
          fetch: () async {
            final loaded = await _loadSeries();
            // A crawl-shaped refresh must not overwrite the disk file:
            // return [] so the refresh skips, and the served rows stay
            // the disk rows (the source stays 'disk' with them).
            if (loaded.complete) {
              // Build #19 (P5a): a PARTIAL unfiltered list must not
              // overwrite a larger good disk file — the panel currently
              // answers get_series with 635 Netflix rows while the file
              // holds 46,527, and accepting the partial list poisons the
              // disk for the 24 h TTL even after the panel recovers.
              // Refuse the write when the new list is under half the
              // file's size (a genuine catalog shrink that large
              // overnight is implausible); the stale file keeps serving
              // and the next warm-up retries the refresh.
              if (loaded.rows.length * 2 < diskRowCount) {
                return const <XtreamSeries>[];
              }
              _seriesLoadSource = 'network';
              return loaded.rows;
            }
            return const <XtreamSeries>[];
          },
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
    final loaded = await _loadSeries();
    _seriesLoadSource = loaded.complete ? 'network' : 'crawl';
    if (loaded.complete) {
      _writeCatalogRows(IptvCatalogDiskCache.seriesDataset, loaded.rows, (r) => r.toJson(), _xtreamApi.lastSeriesBody);
    }
    return loaded.rows;
  }

  /// Same empty-unfiltered fallback as [_loadVodStreams], for series.
  ///
  /// Returns whether the rows came from the unfiltered call ([complete])
  /// or the per-category crawl: crawl rows are missing every hidden
  /// category, so they must never be persisted as the catalog (build
  /// #18) — see [_loadSeriesCached].
  Future<({List<XtreamSeries> rows, bool complete})> _loadSeries() async {
    final all = await _xtreamApi.getSeries();
    if (all.isNotEmpty) return (rows: all, complete: true);
    final categories = await _seriesCategories().catchError((Object e) {
      appLogger.w('IPTV: series category list unavailable for fallback: $e');
      return const <XtreamCategory>[];
    });
    final wanted = categories.where((c) => !_isHiddenCategory(c.id, c.name)).toList(growable: false);
    if (wanted.isEmpty) return (rows: const <XtreamSeries>[], complete: false);
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
    return (rows: out, complete: false);
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

  /// The live TV categories the user has NOT turned off (build #17): the
  /// guide category picker's entries. Filtered by the SAME
  /// [_isHiddenCategory] rule as the guide rows ([iptvChannels] drops
  /// hidden categories), so the picker and the guide can never drift
  /// apart — a hidden category never appears in the picker, and every
  /// picker entry has visible channels. M3U groups are (id, name) pairs
  /// with the group title as both.
  Future<List<({String id, String name})>> visibleLiveCategories() async {
    if (_isXtream) {
      final categories = await liveCategories();
      return categories
          .where((c) => !_isHiddenCategory(c.id, c.name))
          .map((c) => (id: c.id, name: c.name))
          .toList(growable: false);
    }
    final groups = await m3uGroups();
    return groups
        .where((g) => !_isHiddenGroup(g))
        .map((g) => (id: g, name: g))
        .toList(growable: false);
  }

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
    // Build #23: the warm-up also seeds the search index from the disk
    // catalog (fire-and-forget, once per client — the three warm-ups
    // share one seed through the index-write mutex). On the first run
    // after upgrading, the disk already holds the full lists, so the
    // index is warm within seconds with no network at all.
    unawaited(_maybeSeedSearchIndexFromDisk());
    // Build #23 (startup rule): disk only — the warm-up NEVER fetches
    // from the panel. The old path called _seriesList(), whose
    // stale-disk background refresh re-downloaded the whole catalog on
    // every start once the 24h TTL lapsed. The only catalog traffic is
    // the weekly sync (ensureSearchIndexSynced) and a manual refresh.
    unawaited(_warmSeriesCatalogFromDisk());
  }

  /// Disk-only catalog warm-up (build #23, startup rule): read the disk
  /// catalog into the memoized future so browse/search serve it
  /// immediately, and never fetch from the panel. If there is no disk
  /// file yet (fresh install), this is a no-op — the background sync
  /// populates the disk + index, and a browse/search load fetches as
  /// before (the cold fallback).
  Future<void> _warmSeriesCatalogFromDisk() async {
    if (_seriesListLoaded) return;
    final disk = await _readDiskCatalog<XtreamSeries>(
      IptvCatalogDiskCache.seriesDataset,
      XtreamApi.parseSeriesBody,
    );
    if (disk == null) return;
    _seriesFuture = Future.value(disk.rows);
    _seriesListLoaded = true;
    _seriesLoadSource = 'disk';
  }

  /// Same warm-up for the VOD catalog (build #13): the first Movies
  /// browse/search after app start otherwise races the 199k-row load.
  void warmUpVodCatalog() {
    if (!_isXtream || _vodStreamsLoaded) return;
    unawaited(_maybeSeedSearchIndexFromDisk());
    // Build #23 (startup rule): disk only — see [warmUpSeriesCatalog].
    unawaited(_warmVodCatalogFromDisk());
  }

  /// Disk-only VOD warm-up (build #23, startup rule) — see
  /// [_warmSeriesCatalogFromDisk].
  Future<void> _warmVodCatalogFromDisk() async {
    if (_vodStreamsLoaded) return;
    final disk = await _readDiskCatalog<XtreamVodStream>(
      IptvCatalogDiskCache.vodDataset,
      XtreamApi.parseVodStreamsBody,
    );
    if (disk == null) return;
    _vodStreamsFuture = Future.value(disk.rows);
    _vodStreamsLoaded = true;
    _vodLoadSource = 'disk';
  }

  /// Same warm-up for the live catalog (build #13): the first Live TV
  /// search after app start otherwise races the 55k-row load.
  void warmUpLiveCatalog() {
    if (!_isXtream || _liveStreamsLoaded) return;
    unawaited(_maybeSeedSearchIndexFromDisk());
    // Build #23 (startup rule): disk only — see [warmUpSeriesCatalog].
    unawaited(_warmLiveCatalogFromDisk());
  }

  /// Disk-only live warm-up (build #23, startup rule) — see
  /// [_warmSeriesCatalogFromDisk].
  Future<void> _warmLiveCatalogFromDisk() async {
    if (_liveStreamsLoaded) return;
    final disk = await _readDiskCatalog<XtreamLiveStream>(
      IptvCatalogDiskCache.liveDataset,
      XtreamApi.parseLiveStreamsBody,
    );
    if (disk == null) return;
    _liveStreamsFuture = Future.value(disk.rows);
    _liveStreamsLoaded = true;
    _liveLoadSource = 'disk';
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
    if (parts.length < 2) return const [];
    // A season id ('season:<seriesId>:<n>') returns that season's
    // episodes (build #17): the detail screen fetches the selected
    // season's episodes through this id, and fetchChildrenPage slices
    // them for the season pager.
    if (parts[0] == 'season') {
      final seriesId = int.tryParse(parts[1]);
      final seasonNum = parts.length >= 3 ? int.tryParse(parts[2]) : null;
      if (seriesId == null || seasonNum == null) return const [];
      final series = (await _seriesList()).where((s) => s.seriesId == seriesId).firstOrNull;
      if (series == null) return const [];
      final info = await _seriesInfo(seriesId);
      final seasonEpisodes = info.episodesBySeason[seasonNum];
      if (seasonEpisodes == null) return const [];
      final favorites = await _favoriteItems();
      final categoryNames = await _seriesCategoryNames();
      final seriesCategoryName = categoryNames[series.categoryId];
      // Sort a copy: the info object's lists are shared state (and may
      // be unmodifiable), so sorting them in place mutates the cache.
      final sorted = seasonEpisodes.toList()..sort((a, b) => a.episodeNum.compareTo(b.episodeNum));
      return sorted
          .map(
            (episode) => _episodeItem(
              series,
              episode,
              seasonNum,
              isFavorite: favorites.containsKey('episode:${series.seriesId}:${episode.id}'),
              seriesCategoryName: seriesCategoryName,
            ),
          )
          .toList(growable: false);
    }
    if (parts[0] != 'series') return const [];
    final seriesId = int.tryParse(parts[1]);
    if (seriesId == null) return const [];
    final series = (await _seriesList()).where((s) => s.seriesId == seriesId).firstOrNull;
    if (series == null) return const [];
    final info = await _seriesInfo(seriesId);
    final seasons = info.episodesBySeason.keys.toList()..sort();
    // One synthetic season item per season (build #17): the detail
    // screen — and the download / sync / title-copy callers — treat
    // fetchChildren(series) as seasons. The old flat episode list made
    // every episode render as a season tab (labelled with the episode's
    // panel title, e.g. "… - S01E01") and fetching that "season"'s
    // children return [] ("No episodes found").
    final categoryNames = await _seriesCategoryNames();
    final seriesCategoryName = categoryNames[series.categoryId];
    return seasons
        .map(
          (season) => _seasonItem(
            series,
            season,
            info.episodesBySeason[season]!.length,
            seriesCategoryName: seriesCategoryName,
          ),
        )
        .toList(growable: false);
  }

  /// One synthetic season item for an Xtream series (build #17 — the
  /// panel has no season items, only per-season episode lists, so the
  /// client synthesizes them). Server/library fields are copied from the
  /// series item so the detail screen's fallbacks treat the season like
  /// a Plex season.
  MediaItem _seasonItem(
    XtreamSeries series,
    int season,
    int episodeCount, {
    String? seriesCategoryName,
  }) {
    return MediaItem.xtream(
      id: 'season:${series.seriesId}:$season',
      kind: MediaKind.season,
      title: 'Season $season',
      parentId: 'series:${series.seriesId}',
      parentTitle: stripCategoryPrefix(series.name, seriesCategoryName),
      index: season,
      leafCount: episodeCount,
      thumbPath: series.cover,
      categoryId: series.categoryId,
      libraryId: _seriesLibraryId,
      libraryTitle: '$_name — Series',
      serverId: connection.id,
      serverName: _name,
    );
  }

  /// Memoized series-info fetch (build #17): `fetchChildren` needs the
  /// info for the season list AND for each season's episodes, and
  /// `fetchPlayableDescendants` walks both — without memoization one
  /// series detail would pay one get_series_info per season plus one
  /// for the list. A failed fetch is evicted so a retry re-fetches.
  /// Cleared with the catalog cache.
  final Map<int, Future<XtreamSeriesInfo>> _seriesInfoFutures = {};

  Future<XtreamSeriesInfo> _seriesInfo(int seriesId) {
    final cached = _seriesInfoFutures[seriesId];
    if (cached != null) return cached;
    final future = _xtreamApi.getSeriesInfo(seriesId).catchError((Object e) {
      _seriesInfoFutures.remove(seriesId);
      throw e;
    });
    _seriesInfoFutures[seriesId] = future;
    return future;
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
  Future<List<MediaItem>> fetchPlayableDescendants(String parentId) async {
    final children = await fetchChildren(parentId);
    if (children.isEmpty) return const [];
    // A series now returns season items (build #17); the leaves callers
    // (downloads, sync, deep links, the offline queue) need the
    // episodes, so expand each season into its episodes. A season id
    // already returns episodes and passes through unchanged.
    if (children.first.kind == MediaKind.season) {
      final episodes = <MediaItem>[];
      for (final season in children) {
        episodes.addAll(await fetchChildren(season.id));
      }
      return episodes;
    }
    return children;
  }

  @override
  Future<List<MediaItem>?> fetchClientSideEpisodeQueue(String seriesId) async {
    final episodes = await fetchPlayableDescendants(seriesId);
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
    // Build #21: track the in-flight search so a health probe that fires
    // mid-search can be deferred instead of adding a concurrent request
    // to a busy panel (see [checkHealth]). The deferred probe fires once,
    // coalesced, when the last concurrent search on this client ends.
    _activeSearchCount++;
    try {
      return await _searchItemsInner(
        needle,
        limit: limit,
        abort: abort,
        excludedLibraryIds: excludedLibraryIds,
      );
    } finally {
      _activeSearchCount--;
      if (_activeSearchCount == 0) _fireDeferredHealthProbe();
    }
  }

  Future<List<MediaItem>> _searchItemsInner(
    String needle, {
    required int limit,
    required AbortController? abort,
    required Set<String> excludedLibraryIds,
  }) async {
    final searchStarted = DateTime.now();
    if (_isXtream) {
      // Build #23 — scope inversion (global first): the three sections
      // always run, and the scope is a filter over the already-fetched
      // global result (the aggregation drops rows outside the scope, and
      // the hidden-library filter drops hidden ones). The client no
      // longer skips a section for a scoped search — when the local
      // index is warm that costs nothing (three FTS queries, zero panel
      // requests), and it means a wrong scope can never hide a row the
      // index has. The [include] flag still matters for the FALLBACK
      // paths: when the index is cold for a section, an excluded section
      // is skipped instead of sweeping the panel for rows the caller
      // will drop (build #21's request minimisation stands).
      final includeMovies = !excludedLibraryIds.contains(_moviesLibraryId);
      final includeSeries = !excludedLibraryIds.contains(_seriesLibraryId);
      // Live TV is not a real library, so it can never appear in
      // excludedLibraryIds itself — but the search screen's scope strip
      // excludes every OTHER library when a scope is active, so live
      // shows only for an unscoped search (build #13: "search in live
      // TV" was empty by construction before this — Xtream live channels
      // had no search leg at all, only M3U channels did).
      final includeLive = excludedLibraryIds.isEmpty;
      final moviesTrace = _SectionTrace();
      final seriesTrace = _SectionTrace();
      final liveTrace = _SectionTrace();
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
      // Build #21: one AbortController per section, plus the search-wide
      // burst semaphore. A new keystroke (the caller's abort) cancels all
      // three sections at once; a section's own budget timeout cancels
      // only that section — and cancelling means the sockets close, not
      // just the future being abandoned (see XtreamApi's AbortableRequest).
      // The three sections share one [_searchBurst], so the panel never
      // sees more than [_searchBurstCap] search requests in flight.
      final moviesAbort = AbortController();
      final seriesAbort = AbortController();
      final liveAbort = AbortController();
      // Build #21 (close-after-use): track the sections' controllers
      // so cancelActiveSearches() can abort an in-flight search (app
      // backgrounded, connection torn down).
      _activeSearchAborts.addAll([moviesAbort, seriesAbort, liveAbort]);
      if (abort != null) {
        unawaited(
          abort.trigger.then((_) {
            moviesAbort.abort();
            seriesAbort.abort();
            liveAbort.abort();
          }),
        );
      }
      try {
        final sections = await Future.wait([
          _searchMovies(
            needle,
            limit,
            moviesTrace,
            burst: _searchBurst,
            sectionAbort: moviesAbort,
            include: includeMovies,
          ).timeout(searchSectionBudget, onTimeout: () {
            // Hard-cancel the section's in-flight requests: the budget
            // expired, so the search already returned — those sockets
            // must stop, not keep downloading for a dead search.
            moviesAbort.abort();
            return moviesTrace.partialOut;
          }),
          _searchSeries(
            needle,
            limit,
            seriesTrace,
            burst: _searchBurst,
            sectionAbort: seriesAbort,
            include: includeSeries,
          ).timeout(searchSectionBudget, onTimeout: () {
            seriesAbort.abort();
            return seriesTrace.partialOut;
          }),
          _searchLive(
            needle,
            limit,
            liveTrace,
            burst: _searchBurst,
            sectionAbort: liveAbort,
            include: includeLive,
          ).timeout(searchSectionBudget, onTimeout: () {
            liveAbort.abort();
            return liveTrace.partialOut;
          }),
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
      } finally {
        _activeSearchAborts.remove(moviesAbort);
        _activeSearchAborts.remove(seriesAbort);
        _activeSearchAborts.remove(liveAbort);
      }
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
  /// A row that matches the query but sits in a hidden category is
  /// counted on [trace] (build #17) instead of being silently dropped —
  /// the search screen tells the user the filter hid it.
  void _appendMovieMatches(
    List<XtreamVodStream> rows,
    String needle,
    int limit,
    Map<String, IptvFavoriteItem> favorites,
    Map<String, String> categoryNames,
    List<MediaItem> out,
    Set<int> seen,
    _SectionTrace trace,
  ) {
    // One case-insensitive pattern for the whole scan (build #13): the
    // old `name.toLowerCase().contains(needle)` allocated a lowercased
    // copy of every row's name — 199k allocations per search, ~130ms
    // of UI-thread work. hasMatch allocates nothing per row.
    final match = RegExp(RegExp.escape(needle), caseSensitive: false);
    for (final stream in rows) {
      if (out.length >= limit) break;
      if (!seen.add(stream.streamId)) continue;
      if (!match.hasMatch(stream.name)) continue;
      if (_isHiddenCategory(stream.categoryId, categoryNames[stream.categoryId])) {
        trace.hiddenMatches++;
        continue;
      }
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
    _SectionTrace trace,
  ) {
    // One case-insensitive pattern for the whole scan — see
    // [_appendMovieMatches].
    final match = RegExp(RegExp.escape(needle), caseSensitive: false);
    for (final s in rows) {
      if (out.length >= limit) break;
      if (!seen.add(s.seriesId)) continue;
      if (!match.hasMatch(s.name)) continue;
      if (_isHiddenCategory(s.categoryId, categoryNames[s.categoryId])) {
        trace.hiddenMatches++;
        continue;
      }
      out.add(
        _seriesItem(
          s,
          isFavorite: favorites.containsKey('series:${s.seriesId}'),
          categoryName: categoryNames[s.categoryId],
        ),
      );
    }
  }

  /// Sweep per-category catalog rows with a SLIDING WINDOW (build #19),
  /// feeding each category's rows to [onRows] AS THEY LAND: up to
  /// [burst] permits run concurrently, and a finished call frees its
  /// permit immediately — the next category starts without waiting for
  /// the rest. The old batched Future.wait let one slow call hold a whole
  /// batch hostage: with 232 categories, a slow call in an early batch
  /// delayed every later batch behind it. With the window, a fast call
  /// frees its permit at once. (At a UNIFORM 6 s/call the window alone
  /// cannot beat the 8-batch x 6 s packing minimum — the sweep deadline
  /// moved 45 s -> 49 s for that, see [_sweepDeadline].)
  /// Stops at [deadline], when [shouldStop] says enough matches were
  /// found, or when [sectionAbort] fires; rows landing after the sweep
  /// stopped are dropped, never appended to a list that was already
  /// returned.
  ///
  /// Concurrency comes from [burst], the search-wide semaphore (build
  /// #21) — not a per-sweep batch size. The three sections share one
  /// semaphore of [_searchBurstCap] permits, so a search never puts more
  /// than that many category calls on the panel at once (before: 32 per
  /// section, ~96 in flight). A finished call frees its permit at once;
  /// an aborted call frees it too. The sweep still covers the whole
  /// 237-category list inside the deadline on a healthy panel (see
  /// [_searchBurstCap] for the reach math) — the old 32 existed only to
  /// cover it at 6s per call, a degraded panel.
  Future<void> _sweepCatalogCategories<T>(
    List<XtreamCategory> categories,
    Future<List<T>> Function(String categoryId) loadCategory,
    void Function(List<T> rows) onRows,
    bool Function() shouldStop,
    DateTime deadline, {
    required _SearchRequestSemaphore burst,
    required AbortController sectionAbort,
  }) async {
    var stopped = false;
    // In-flight calls. Each task removes itself on completion, so the
    // set's size is the live concurrency count.
    final active = <Future<void>>{};
    for (final category in categories) {
      if (stopped || shouldStop() || sectionAbort.isAborted) break;
      final timeLeft = deadline.difference(DateTime.now());
      if (timeLeft <= Duration.zero) break;
      // Take a permit from the search-wide cap before launching. The
      // acquire waits for a permit, the deadline, or the abort —
      // whichever comes first — so a stalled panel cannot wedge the loop.
      if (!await burst.acquireUntil(deadline, sectionAbort)) {
        stopped = true;
        break;
      }
      late final Future<void> task;
      try {
        task = loadCategory(category.id).then((rows) {
          burst.release();
          active.remove(task);
          if (!stopped && !shouldStop()) onRows(rows);
        }).catchError((Object e) {
          burst.release();
          active.remove(task);
          // Build #21: an aborted request is not a failed category — the
          // section's budget expired (or a new keystroke cancelled the
          // search), so stop the sweep instead of launching the next
          // category and generating more panel traffic.
          if (sectionAbort.isAborted || (e is MediaServerHttpException && e.isCancellation)) {
            stopped = true;
            return;
          }
          appLogger.w('IPTV: catalog sweep category ${category.id} unavailable: $e');
        });
      } catch (e) {
        // Defensive: an async loadCategory cannot throw synchronously,
        // but a leaked permit would starve the whole search.
        burst.release();
        rethrow;
      }
      active.add(task);
    }
    // Wait for the launched calls to land, bounded by the deadline, so
    // the caller gets every row that arrives in budget. But when the sweep
    // stopped EARLY — the deadline passed, or enough matches were found —
    // the in-flight calls' rows will be dropped by the stopped /
    // shouldStop guard in onRows, so hard-cancel them instead of letting
    // them run to their own HTTP budget for a dead search. (Without this
    // the sweep's own deadline ends the sweep just before the section
    // timeout fires, the section returns normally, the abort never fires,
    // and the orphaned calls keep downloading — the battery drain Matt
    // reported.) A sweep that visited every category keeps its in-flight
    // calls: the final wait below collects their rows.
    if (active.isNotEmpty && !sectionAbort.isAborted) {
      final stoppedEarly =
          shouldStop() || deadline.difference(DateTime.now()) <= Duration.zero;
      if (stoppedEarly) {
        sectionAbort.abort();
      }
    }
    if (active.isNotEmpty && !sectionAbort.isAborted) {
      final timeLeft = deadline.difference(DateTime.now());
      if (timeLeft > Duration.zero) {
        await Future.wait(active).timeout(timeLeft, onTimeout: () {
          stopped = true;
          return <void>[];
        });
      } else {
        stopped = true;
      }
    }
  }

  /// Build #18: sweep the categories a cached list does not represent.
  /// A disk file written from a per-category crawl (before the fix, or
  /// from a panel that answered [] to the unfiltered call) lacks every
  /// category hidden when it was written, so a warm search over it
  /// returns [] for shows in those categories even though they exist.
  /// When the warm filter found nothing, fetch the missing categories —
  /// the ones the user has NOT turned off and that no cached row belongs
  /// to — before answering []. A complete disk list sweeps nothing:
  /// [wanted] is empty and this returns immediately, so a genuine
  /// no-match costs no extra calls.
  Future<void> _sweepMissingCategories<T>({
    required Future<List<XtreamCategory>> Function() loadCategories,
    required Future<List<T>> Function(String categoryId) loadCategory,
    required void Function(List<T> rows) onRows,
    required Set<String?> represented,
    required bool Function() shouldStop,
    required DateTime deadline,
    required _SearchRequestSemaphore burst,
    required AbortController sectionAbort,
  }) async {
    final categories = await loadCategories().catchError((Object e) {
      appLogger.w('IPTV: category list unavailable for warm-path sweep: $e');
      return const <XtreamCategory>[];
    });
    final wanted = categories
        .where((c) => !_isHiddenCategory(c.id, c.name) && !represented.contains(c.id))
        .toList(growable: false);
    if (wanted.isEmpty) return;
    await _sweepCatalogCategories<T>(
      wanted,
      loadCategory,
      onRows,
      shouldStop,
      deadline,
      burst: burst,
      sectionAbort: sectionAbort,
    );
  }

  /// Repair a disk catalog after a healing search fetched rows the cached
  /// list lacked (build #19, P5b). Merges [sweptRows] into [cachedRows]
  /// (deduped by id), writes the merged list to disk, and swaps the
  /// in-memory memoized list so the next search does not heal again.
  /// AWAITED: the caller returns its results right after this, and the
  /// next search (or a disk-only read) must see the repaired file — a
  /// fire-and-forget write would race it. Skipped when nothing was swept
  /// or nothing new arrived, and when a clear landed mid-sweep
  /// (generation guard — the file is deleted instead of resurrecting
  /// cleared rows, mirroring [_writeDiskText]).
  ///
  /// Cost note: the merge re-encodes the whole catalog (build #13
  /// measured ~1.3 s for 199k VOD rows on the UI isolate), so this runs
  /// only on a healing search — rare, and it saves every later search
  /// from paying the sweep again.
  Future<void> _repairDiskCatalogAfterHeal<T>({
    required String dataset,
    required List<T> cachedRows,
    required List<T> sweptRows,
    required int Function(T row) idOf,
    required Map<String, dynamic> Function(T row) toJson,
    required void Function(List<T> merged) swapMemory,
  }) async {
    if (sweptRows.isEmpty) return;
    final generation = _catalogGeneration;
    final seen = <int>{for (final row in cachedRows) idOf(row)};
    final merged = List<T>.of(cachedRows);
    for (final row in sweptRows) {
      if (seen.add(idOf(row))) merged.add(row);
    }
    if (merged.length == cachedRows.length) return;
    await _catalogCache.write(connection.id, dataset, jsonEncode(merged.map(toJson).toList()));
    if (generation != _catalogGeneration) {
      await _catalogCache.delete(connection.id, dataset);
      return;
    }
    swapMemory(merged);
  }

  /// Deadline for a cold-catalog sweep, measured from the SECTION start
  /// (build #10): 98% of the section budget, so the sweep returns partial
  /// matches instead of being cut to [] by the outer timeout, with room
  /// left for the merge. Measured from the section start, not the sweep
  /// start — the old version computed it when the sweep began, so a slow
  /// category-names fetch before the sweep pushed the sweep past the
  /// outer 50s timeout and its partial matches were discarded (T3).
  ///
  /// Build #19: was 90% (45 s). At Trex scale the heal must sweep 232
  /// categories, and with a uniform 6 s per-category round trip the last
  /// batch (holding "|EN| TOP SERIES", last in the list) lands at ~48 s
  /// — past 45 s, so the heal missed it (P4-slow) even with the sliding
  /// window: 8 batches x 6 s is the integer-packing minimum at 32
  /// concurrent, and no scheduling inside the window can beat it. 98%
  /// (49 s) fits inside the 50 s section budget with room for the merge
  /// and the post-heal disk repair, and matches the 0.98 remaining-budget
  /// factor the cold path already uses. The threshold moves to ~6.1 s/call;
  /// beyond that the section budget itself is the binding constraint.
  DateTime _sweepDeadline(DateTime sectionStarted) =>
      sectionStarted.add(searchSectionBudget * 0.98);

  /// Search one section from the local index (build #23). Returns the
  /// section's matches when the index is warm for [type] — zero panel
  /// requests, regardless of [include] (global first; the aggregation
  /// filters by scope) — or null when the index is cold for the type,
  /// so the caller falls through to the disk/sweep paths. The
  /// category names come from the index alone (no panel round trip),
  /// and the rows are mapped back to Xtream models so the existing
  /// append builders (hidden-category filter, prefix strip, favourites)
  /// run unchanged.
  Future<List<MediaItem>?> _searchMoviesFromIndex(
    String needle,
    int limit,
    _SectionTrace trace,
    DateTime sectionStarted,
  ) async {
    final index = await _searchIndex();
    if (index == null) return null;
    final totalRows = index.rowCounts(connection.id)[IptvSearchIndex.typeMovie] ?? 0;
    if (totalRows == 0) return null;
    final favorites = await _favoriteItems();
    final categoryNames = index.categoryNames(connection.id, IptvSearchIndex.typeMovie);
    final rows = index
        .search(connection.id, IptvSearchIndex.typeMovie, needle)
        .map((r) => r.toVodStream())
        .toList(growable: false);
    final out = <MediaItem>[];
    trace.partialOut = out;
    _appendMovieMatches(rows, needle, limit, favorites, categoryNames, out, <int>{}, trace);
    trace.loadRows = totalRows;
    trace.loadSource = 'index';
    trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
    trace.loadMatches = out.length;
    trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
    return out;
  }

  /// Same as [_searchMoviesFromIndex], for series.
  Future<List<MediaItem>?> _searchSeriesFromIndex(
    String needle,
    int limit,
    _SectionTrace trace,
    DateTime sectionStarted,
  ) async {
    final index = await _searchIndex();
    if (index == null) return null;
    final totalRows = index.rowCounts(connection.id)[IptvSearchIndex.typeSeries] ?? 0;
    if (totalRows == 0) return null;
    final favorites = await _favoriteItems();
    final categoryNames = index.categoryNames(connection.id, IptvSearchIndex.typeSeries);
    final rows = index
        .search(connection.id, IptvSearchIndex.typeSeries, needle)
        .map((r) => r.toSeries())
        .toList(growable: false);
    final out = <MediaItem>[];
    trace.partialOut = out;
    _appendSeriesMatches(rows, needle, limit, favorites, categoryNames, out, <int>{}, trace);
    trace.loadRows = totalRows;
    trace.loadSource = 'index';
    trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
    trace.loadMatches = out.length;
    trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
    return out;
  }

  /// Same as [_searchMoviesFromIndex], for live channels. The hidden
  /// channels set is loaded first (a prefs read, local) so
  /// [_appendLiveMatches] skips hidden channels exactly as the warm
  /// path does.
  Future<List<MediaItem>?> _searchLiveFromIndex(
    String needle,
    int limit,
    _SectionTrace trace,
    DateTime sectionStarted,
  ) async {
    final index = await _searchIndex();
    if (index == null) return null;
    final totalRows = index.rowCounts(connection.id)[IptvSearchIndex.typeLive] ?? 0;
    if (totalRows == 0) return null;
    final categoryNames = index.categoryNames(connection.id, IptvSearchIndex.typeLive);
    await _liveTv.loadHiddenChannels();
    final rows = index
        .search(connection.id, IptvSearchIndex.typeLive, needle)
        .map((r) => r.toLiveStream())
        .toList(growable: false);
    final out = <MediaItem>[];
    trace.partialOut = out;
    _appendLiveMatches(rows, needle, limit, categoryNames, out, <int>{}, trace);
    trace.loadRows = totalRows;
    trace.loadSource = 'index';
    trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
    trace.loadMatches = out.length;
    trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
    return out;
  }

  Future<List<MediaItem>> _searchMovies(
    String needle,
    int limit,
    _SectionTrace trace, {
    required _SearchRequestSemaphore burst,
    required AbortController sectionAbort,
    required bool include,
  }) async {
    try {
      final sectionStarted = DateTime.now();
      // Build #23: the local index answers first — zero panel requests
      // when warm, regardless of scope. When it is cold, an excluded
      // section is skipped (no sweep for rows the caller drops) and an
      // included one falls through to the warm/cold disk/sweep paths.
      final indexOut = await _searchMoviesFromIndex(needle, limit, trace, sectionStarted);
      if (indexOut != null) return indexOut;
      if (!include) {
        trace.skipped = true;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return const [];
      }
      final favorites = await _favoriteItems();
      final categoryNames = await _vodCategoryNames();
      if (_vodStreamsLoaded) {
        // Warm catalog: filter the cached list (the old path).
        final rows = await _vodStreams();
        final out = <MediaItem>[];
        trace.partialOut = out;
        final seen = <int>{};
        _appendMovieMatches(rows, needle, limit, favorites, categoryNames, out, seen, trace);
        trace.loadRows = rows.length;
        trace.loadSource = _vodLoadSource;
        trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
        trace.loadMatches = out.length;
        if (out.isEmpty) {
          // Build #18: the disk list may be crawl-shaped (written before
          // the fix) — categories hidden when the file was written have
          // no rows in it. Sweep the categories it does not represent
          // before answering [].
          // Build #19: collect the swept rows so the heal can repair
          // the disk file (P5b) — the sweep fetches whole categories,
          // not just the matches.
          final healedRows = <XtreamVodStream>[];
          await _sweepMissingCategories<XtreamVodStream>(
            loadCategories: _vodCategories,
            loadCategory: (id) => _xtreamApi.getVodStreams(categoryId: id, abortTrigger: sectionAbort.trigger),
            onRows: (sweepRows) {
              healedRows.addAll(sweepRows);
              final before = out.length;
              _appendMovieMatches(sweepRows, needle, limit, favorites, categoryNames, out, seen, trace);
              trace.sweepMatches += out.length - before;
            },
            represented: {for (final r in rows) r.categoryId},
            shouldStop: () => out.length >= limit,
            deadline: _sweepDeadline(sectionStarted),
            burst: burst,
            sectionAbort: sectionAbort,
          );
          // Build #19 (P5b): the heal found rows the disk file lacked —
          // persist them so the next search does not heal again and a
          // disk-only read is not empty. Awaited before returning.
          await _repairDiskCatalogAfterHeal<XtreamVodStream>(
            dataset: IptvCatalogDiskCache.vodDataset,
            cachedRows: rows,
            sweptRows: healedRows,
            idOf: (row) => row.streamId,
            toJson: (row) => row.toJson(),
            swapMemory: (merged) {
              _vodStreamsFuture = Future.value(merged);
              _vodPartialRows.clear();
              _vodCrawledCategoryIds.clear();
            },
          );
        }
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
          trace.loadSource = _vodLoadSource;
          trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
          final before = out.length;
          _appendMovieMatches(rows, needle, limit, favorites, categoryNames, out, seen, trace);
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
        (id) => _xtreamApi.getVodStreams(categoryId: id, abortTrigger: sectionAbort.trigger),
        (rows) {
          final before = out.length;
          _appendMovieMatches(rows, needle, limit, favorites, categoryNames, out, seen, trace);
          trace.sweepMatches += out.length - before;
        },
        () => out.length >= limit || loadLanded,
        _sweepDeadline(sectionStarted),
        burst: burst,
        sectionAbort: sectionAbort,
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
          trace,
        );
        trace.partialMatches += out.length - partialBefore;
        if (out.isEmpty) {
          final remaining = sectionStarted.add(searchSectionBudget * 0.98).difference(DateTime.now());
          if (!remaining.isNegative) {
            final rows = await loadFuture.timeout(remaining, onTimeout: () => const <XtreamVodStream>[]);
            if (rows.isNotEmpty && !loadLanded) {
              loadLanded = true;
              trace.loadRows = rows.length;
              trace.loadSource = _vodLoadSource;
              trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
              final before = out.length;
              _appendMovieMatches(rows, needle, limit, favorites, categoryNames, out, seen, trace);
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
                trace,
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

  Future<List<MediaItem>> _searchSeries(
    String needle,
    int limit,
    _SectionTrace trace, {
    required _SearchRequestSemaphore burst,
    required AbortController sectionAbort,
    required bool include,
  }) async {
    try {
      final sectionStarted = DateTime.now();
      // Build #23: the local index answers first (see _searchMovies).
      final indexOut = await _searchSeriesFromIndex(needle, limit, trace, sectionStarted);
      if (indexOut != null) return indexOut;
      if (!include) {
        trace.skipped = true;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return const [];
      }
      final favorites = await _favoriteItems();
      final categoryNames = await _seriesCategoryNames();
      if (_seriesListLoaded) {
        // Warm catalog: filter the cached list (the old path).
        final rows = await _seriesList();
        final out = <MediaItem>[];
        trace.partialOut = out;
        final seen = <int>{};
        _appendSeriesMatches(rows, needle, limit, favorites, categoryNames, out, seen, trace);
        trace.loadRows = rows.length;
        trace.loadSource = _seriesLoadSource;
        trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
        trace.loadMatches = out.length;
        if (out.isEmpty) {
          // Build #18: the disk list may be crawl-shaped (written before
          // the fix, or from a panel that answered [] to the unfiltered
          // call) — categories hidden when the file was written have no
          // rows in it, so the show is unfindable from the cached list
          // alone. Sweep the categories it does not represent before
          // answering []. This is what heals Matt's phone even with the
          // poisoned file still on disk.
          // Build #19: collect the swept rows so the heal can repair
          // the disk file (P5b) — the sweep fetches whole categories,
          // not just the matches.
          final healedRows = <XtreamSeries>[];
          await _sweepMissingCategories<XtreamSeries>(
            loadCategories: _seriesCategories,
            loadCategory: (id) => _xtreamApi.getSeries(categoryId: id, abortTrigger: sectionAbort.trigger),
            onRows: (sweepRows) {
              healedRows.addAll(sweepRows);
              final before = out.length;
              _appendSeriesMatches(sweepRows, needle, limit, favorites, categoryNames, out, seen, trace);
              trace.sweepMatches += out.length - before;
            },
            represented: {for (final r in rows) r.categoryId},
            shouldStop: () => out.length >= limit,
            deadline: _sweepDeadline(sectionStarted),
            burst: burst,
            sectionAbort: sectionAbort,
          );
          // Build #19 (P5b): the heal found rows the disk file lacked —
          // persist them so the next search does not heal again and a
          // disk-only read is not empty. Awaited before returning.
          await _repairDiskCatalogAfterHeal<XtreamSeries>(
            dataset: IptvCatalogDiskCache.seriesDataset,
            cachedRows: rows,
            sweptRows: healedRows,
            idOf: (row) => row.seriesId,
            toJson: (row) => row.toJson(),
            swapMemory: (merged) {
              _seriesFuture = Future.value(merged);
              _seriesPartialRows.clear();
              _seriesCrawledCategoryIds.clear();
            },
          );
        }
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
          trace.loadSource = _seriesLoadSource;
          trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
          final before = out.length;
          _appendSeriesMatches(rows, needle, limit, favorites, categoryNames, out, seen, trace);
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
        (id) => _xtreamApi.getSeries(categoryId: id, abortTrigger: sectionAbort.trigger),
        (rows) {
          final before = out.length;
          _appendSeriesMatches(rows, needle, limit, favorites, categoryNames, out, seen, trace);
          trace.sweepMatches += out.length - before;
        },
        () => out.length >= limit || loadLanded,
        _sweepDeadline(sectionStarted),
        burst: burst,
        sectionAbort: sectionAbort,
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
          trace,
        );
        trace.partialMatches += out.length - partialBefore;
        if (out.isEmpty) {
          final remaining = sectionStarted.add(searchSectionBudget * 0.98).difference(DateTime.now());
          if (!remaining.isNegative) {
            final rows = await loadFuture.timeout(remaining, onTimeout: () => const <XtreamSeries>[]);
            if (rows.isNotEmpty && !loadLanded) {
              loadLanded = true;
              trace.loadRows = rows.length;
              trace.loadSource = _seriesLoadSource;
              trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
              final before = out.length;
              _appendSeriesMatches(rows, needle, limit, favorites, categoryNames, out, seen, trace);
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
                trace,
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
  Future<List<MediaItem>> _searchLive(
    String needle,
    int limit,
    _SectionTrace trace, {
    required _SearchRequestSemaphore burst,
    required AbortController sectionAbort,
    required bool include,
  }) async {
    try {
      final sectionStarted = DateTime.now();
      // Build #23: the local index answers first (see _searchMovies).
      final indexOut = await _searchLiveFromIndex(needle, limit, trace, sectionStarted);
      if (indexOut != null) return indexOut;
      if (!include) {
        trace.skipped = true;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return const [];
      }
      final categoryNames = await _liveCategoryNames();
      // Hidden channels (build #17, §9) never match in Live TV search:
      // load the set once, then [_appendLiveMatches] skips them in both
      // the warm and the cold path.
      await _liveTv.loadHiddenChannels();
      if (_liveStreamsLoaded) {
        // Warm catalog: filter the cached list.
        final rows = await _liveStreams();
        final out = <MediaItem>[];
        trace.partialOut = out;
        _appendLiveMatches(rows, needle, limit, categoryNames, out, <int>{}, trace);
        trace.loadRows = rows.length;
        trace.loadSource = _liveLoadSource;
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
          trace.loadSource = _liveLoadSource;
          trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
          final before = out.length;
          _appendLiveMatches(rows, needle, limit, categoryNames, out, seen, trace);
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
        (id) => _xtreamApi.getLiveStreams(categoryId: id, abortTrigger: sectionAbort.trigger),
        (rows) {
          final before = out.length;
          _appendLiveMatches(rows, needle, limit, categoryNames, out, seen, trace);
          trace.sweepMatches += out.length - before;
        },
        () => out.length >= limit || loadLanded,
        _sweepDeadline(sectionStarted),
        burst: burst,
        sectionAbort: sectionAbort,
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
            trace.loadSource = _liveLoadSource;
            trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
            final before = out.length;
            _appendLiveMatches(rows, needle, limit, categoryNames, out, seen, trace);
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
    _SectionTrace trace,
  ) {
    // One case-insensitive pattern for the whole scan — see
    // [_appendMovieMatches].
    final match = RegExp(RegExp.escape(needle), caseSensitive: false);
    for (final stream in rows) {
      if (out.length >= limit) break;
      if (!seen.add(stream.streamId)) continue;
      if (!match.hasMatch(stream.name)) continue;
      if (_isHiddenCategory(stream.categoryId, categoryNames[stream.categoryId])) {
        trace.hiddenMatches++;
        continue;
      }
      // A hidden channel (build #17, §9) never matches in Live TV search.
      if (_liveTv.isHiddenChannelKey('${stream.streamId}')) continue;
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
      // Hidden channels (build #17, §9) never match in Live TV search.
      await _liveTv.loadHiddenChannels();
      final out = <MediaItem>[];
      // One case-insensitive pattern for the whole scan — see
      // [_appendMovieMatches].
      final match = RegExp(RegExp.escape(needle), caseSensitive: false);
      for (final entry in entries) {
        if (out.length >= limit) break;
        // A hidden group (its own switch, or its category initial) hides
        // its entries from search too. Item names are never filtered.
        if (_isHiddenGroup(entry.groupTitle)) continue;
        if (_liveTv.isHiddenChannelKey(entry.tvgId ?? entry.url)) continue;
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
            // Guide category picker (build #17): the Xtream category id.
            categoryId: stream.categoryId,
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
          // Guide category picker (build #17): an M3U channel's
          // category is its group title.
          categoryId: entry.groupTitle,
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

/// A counting semaphore shared by the three search sections of one search
/// — and by concurrent searches on the same client (build #21). It is the
/// thing that enforces [IptvClient.searchBurstCap]: a category call takes
/// a permit before it is launched and returns it when it lands (or aborts),
/// so the panel never sees more than the cap in flight, however many
/// sections or keystrokes are running.
///
/// Grant rule (single isolate, first-wins): a permit is handed to exactly
/// one waiter. [release] completes the first waiter still queued — that
/// waiter owns the permit from that moment, without [_available] moving —
/// and skips waiters whose deadline or abort already won (their completer
/// is already completed, so completing it again is a no-op). A waiter that
/// times out or aborts removes itself from the queue and owns nothing.
/// [_available] only moves when a permit is taken with no waiter queued
/// ([acquireUntil] fast path) or returned with no waiter queued ([release]).
class _SearchRequestSemaphore {
  _SearchRequestSemaphore(int permits) : _available = permits;

  int _available;
  final Queue<Completer<bool>> _waiters = Queue<Completer<bool>>();

  /// Take a permit, waiting until one is free, [deadline], or [abort]
  /// fires. Returns true when a permit was granted, false when the wait
  /// ended without one — the caller must stop, not retry.
  Future<bool> acquireUntil(DateTime deadline, AbortController? abort) async {
    if (_available > 0) {
      _available--;
      return true;
    }
    if (abort?.isAborted ?? false) return false;
    final timeLeft = deadline.difference(DateTime.now());
    if (timeLeft <= Duration.zero) return false;
    final waiter = Completer<bool>();
    _waiters.add(waiter);
    final timer = Timer(timeLeft, () {
      if (!waiter.isCompleted) waiter.complete(false);
    });
    // Abort wakes the waiter the same way (the trigger future completes
    // on abort; the isCompleted guard makes a late abort a no-op when
    // the deadline already won).
    unawaited(
      abort?.trigger.then((_) {
        if (!waiter.isCompleted) waiter.complete(false);
      }),
    );
    bool granted;
    try {
      granted = await waiter.future;
    } finally {
      timer.cancel();
    }
    if (!granted) {
      // No permit: remove ourselves from the queue (a release() that
      // already picked us up removes us first, so this is a no-op then).
      _waiters.remove(waiter);
      return false;
    }
    return true;
  }

  /// Return a permit. Hands it straight to the first waiter still queued;
  /// parks it when nobody is waiting.
  void release() {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.complete(true);
        return;
      }
      // Already completed (deadline/abort won) — try the next waiter.
    }
    _available++;
  }
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

  /// Where the catalog rows came from (build #18): 'disk', 'network' or
  /// 'crawl'. '' when the load never landed. Rendered in the Last search
  /// row so a poisoned disk is visible on the phone.
  String loadSource = '';
  int loadMatches = 0;
  int sweepMatches = 0;
  int partialMatches = 0;

  /// Rows that matched the query but sat in a hidden category (build
  /// #17): counted, not returned, so the search screen can tell the user
  /// the filter hid them instead of showing a bare "No results".
  int hiddenMatches = 0;
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
    loadSource: loadSource,
    loadMatches: loadMatches,
    sweepMatches: sweepMatches,
    partialMatches: partialMatches,
    hiddenMatches: hiddenMatches,
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
    this.loadSource = '',
    required this.loadMatches,
    required this.sweepMatches,
    required this.partialMatches,
    required this.hiddenMatches,
    required this.ms,
    required this.skipped,
  });

  /// Rows the catalog load produced (-1 when it never landed during the
  /// search, 0 when it landed empty).
  final int loadRows;

  /// Milliseconds the load took to land (-1 when it never landed).
  final int loadMs;

  /// Where the catalog rows came from (build #18): 'disk', 'network' or
  /// 'crawl'. '' when the load never landed.
  final String loadSource;

  /// Matches that came from the full catalog load.
  final int loadMatches;

  /// Matches that came from the per-category sweep.
  final int sweepMatches;

  /// Matches that came from the crawl's published partial rows.
  final int partialMatches;

  /// Rows that matched the query but were removed by the hidden-category
  /// filter (build #17) — the search screen's "matches are in categories
  /// you turned off" message reads this.
  final int hiddenMatches;

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
