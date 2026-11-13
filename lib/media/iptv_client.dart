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
import '../services/base_shared_preferences_service.dart';
import '../services/iptv/iptv_catalog_cache.dart';
import '../services/iptv/iptv_epg_sources.dart';
import '../services/iptv/iptv_playback_activity.dart';
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
import 'watch_progress.dart';
import '../services/iptv/iptv_item_favorites_repository.dart';
import '../services/iptv/iptv_refusal_log.dart';
import '../services/iptv/iptv_resume_repository.dart';
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

/// Thrown by [_IptvClient._waitForIdleUnlessAborted] when the background
/// playback check finds a stream playing (build v1.0.13, R4, D4). Unlike
/// the foreground wait, a background run never waits for idle — it bails
/// so WorkManager can retry.
class _BackgroundPlaybackActive implements Exception {
  const _BackgroundPlaybackActive();
}

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
    userAgentProvider: _userAgentProviderOverride ?? _xtreamUserAgent,
    // Build #27: every refused response and transport failure is handed
    // to the refusal log (Settings → IPTV → Connection refusals) with
    // its headers and body — the 403 the app used to discard is the
    // diagnostic. Record-only: the exception the caller sees is
    // unchanged, and no request is added.
    onRefusal: (entry) => IptvRefusalLog.instance.record(entry),
    connectionId: connection.id,
    connectionName: _name,
  );

  /// Override for the Xtream User-Agent provider (build v1.0.13, R4):
  /// the background isolate has no SettingsService, so the callback
  /// resolves the user's UA from SharedPreferences directly and hands
  /// it in here before the first request. Must be set before the lazy
  /// [_xtreamApi] builds; the override wins over [_xtreamUserAgent].
  String Function()? _userAgentProviderOverride;

  /// See [_userAgentProviderOverride].
  set userAgentProvider(String Function() provider) => _userAgentProviderOverride = provider;

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
  // [_readDiskCatalog] / [_refreshCatalogViaSyncIfDue].
  static const _catalogCache = IptvCatalogDiskCache();

  /// Generation guard for background refreshes: bumped by
  /// [clearCatalogCache], so a refresh started before a clear can never
  /// resurrect the cleared catalog (memory or disk).
  int _catalogGeneration = 0;

  /// Whether a FULL catalog load has completed with rows (build #9 Task 1).
  /// A future that is merely in flight — or that resolved empty — does not
  /// count: the Enter path reads the memoized list only when it is loaded,
  /// else the disk file (R2.3) — it never awaits a load that may take
  /// minutes on a 46k-row catalog.
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
  /// covered-category sets record what the crawl already fetched.
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
    if (libraryId == _liveLibraryId) return diagnostics.live.hiddenMatches;
    return 0;
  }

  /// The letter-group initials that hid the last search's matches, for
  /// one library (v1.1.0): the search screen's empty state names the
  /// hiding group instead of only counting. Empty when there was no
  /// search yet, when nothing was hidden, or when the library is not
  /// one of this connection's libraries.
  List<String> lastSearchHiddenGroupsForLibrary(String libraryId) {
    final diagnostics = _lastSearchDiagnostics;
    if (diagnostics == null) return const [];
    if (libraryId == _seriesLibraryId) return diagnostics.series.hiddenInitials;
    if (libraryId == _moviesLibraryId) return diagnostics.movies.hiddenInitials;
    if (libraryId == _liveLibraryId) return diagnostics.live.hiddenInitials;
    return const [];
  }

  // -- Local search index (build #23) -------------------------------------
  //
  // The whole catalog is synced once into a local SQLite FTS5 trigram
  // index ([IptvSearchIndex]), and search queries it instead of the
  // provider — zero panel requests during a search when the index is
  // warm. The index is derived/rebuildable cache data in its own file,
  // so it can never touch the main database; a broken index just reads
  // as cold and the search falls back to the disk/sync paths (R2.3).
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
        appLogger.w('IPTV: search index unavailable, search falls back to disk/sync: $e');
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
  /// type stays cold and the Enter-time sync fetches it (R2.3).
  ///
  /// Build v1.0.10 (M1): the seed stamps each type with its disk file's
  /// real fetchedAt, not now — the sync that follows reads the stamp to
  /// decide whether the type is due, so a stale disk must still sync
  /// instead of being stamped fresh and skipped for a week.
  Future<void> seedSearchIndexFromDisk() => _runIndexWrite(_seedSearchIndexFromDisk);

  Future<void> _maybeSeedSearchIndexFromDisk() => _runIndexWrite(_seedSearchIndexFromDisk);

  Future<void> _seedSearchIndexFromDisk() async {
    if (!_isXtream) return;
    final index = await _searchIndex();
    if (index == null) return;
    final dbPath = await IptvSearchIndex.dbFilePath();
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
              // Build v1.0.10 (M1): the disk file's real age, not now —
              // stamping now told the sync this type was just synced, so
              // a days-old disk was never refreshed for a week.
              syncStampMs: catalog.fetchedAt.millisecondsSinceEpoch,
              // v1.1.0 (Option B): the seed lands the FULL rows from
              // whatever the disk file holds — the hidden sets only
              // feed the isolate's hiddenSkipped diagnostic count.
              hiddenCategoryIds: _hiddenCategories.toList(),
              hiddenCategoryInitials: _hiddenCategoryInitials.toList(),
            ),
          );
          if (result.skippedReason != null) {
            appLogger.i(
              'IPTV: search index seed skipped $type (${result.skippedReason}) — the sync will fetch it',
            );
          } else if (result.partial) {
            // Series fix (v1.0.16): same cold-type rule as the sync —
            // the partial disk file lands, and the type stays due so the
            // sync completes it.
            appLogger.i(
              'IPTV: search index seed landed $type partial (${result.rowCount} rows, ${result.coveredCategories}/${result.totalCategories} categories) - the sync will complete it',
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

  /// SharedPreferences key holding the start time (epoch ms) of a catalog
  /// sync currently running in ANOTHER isolate (build v1.0.13, R4, D5).
  /// The UI isolate and the background job both write it for the duration
  /// of a sync and clear it when done, so the other side can yield
  /// instead of duplicating the 6 requests. Best-effort: a crash leaves
  /// a stale stamp, which ages out after [syncRunningStampStaleAfter].
  static const String syncRunningStampPrefsKey = 'iptv_catalog_sync_running_since_ms';

  /// A running stamp older than this is dead (the run crashed or was
  /// killed) and must not block syncs forever.
  static const Duration syncRunningStampStaleAfter = Duration(minutes: 30);

  /// True when another isolate started a catalog sync recently enough
  /// that this isolate should yield. Never throws — an unreadable prefs
  /// store reads as "nobody is syncing".
  static Future<bool> isSyncRunningElsewhere() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final stampMs = prefs.getInt(syncRunningStampPrefsKey);
      if (stampMs == null) return false;
      final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(stampMs));
      return age < syncRunningStampStaleAfter;
    } catch (e) {
      appLogger.w('IPTV: running stamp unreadable', error: e);
      return false;
    }
  }

  static Future<void> _writeSyncRunningStamp() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setInt(syncRunningStampPrefsKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      appLogger.w('IPTV: running stamp unwritable', error: e);
    }
  }

  static Future<void> _clearSyncRunningStamp() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.remove(syncRunningStampPrefsKey);
    } catch (e) {
      appLogger.w('IPTV: running stamp unclearable', error: e);
    }
  }

  /// The current catalog schema (v1.1.0): index + disk files hold the
  /// FULL catalog, filtered only at read time. A stored version below
  /// this means the files were written by the v1.0.16 lossy schema and
  /// the next sync re-fetches every type once to repair them.
  static const _currentCatalogSchemaVersion = 2;

  /// SharedPreferences key for the catalog schema version (v1.1.0,
  /// Option B): which schema the stored index + disk files were written
  /// under, per connection. Version 2 is the first schema whose index +
  /// disk hold the FULL catalog; version 1 (or absent) is the v1.0.16
  /// lossy schema, whose files were written visible-only and must be
  /// re-fetched once (the schema repair).
  String get _catalogSchemaPrefsKey => 'iptv_catalog_schema_v:${connection.id}';

  /// The catalog schema version the last completed sync stamped, or 0
  /// before any sync (no baseline — the repair runs on the first sync),
  /// or -1 when the version cannot be read at all. The -1 is not "old":
  /// in a raw background isolate the prefs channel is unavailable, so
  /// the read throws and the version is UNKNOWN — forcing a repair on
  /// inconclusive evidence would re-fetch the whole catalog on every
  /// background run and break the R4 due check (the probe pin). The
  /// repair fires only on positive evidence (a readable version < 2).
  /// Never throws.
  Future<int> _readCatalogSchemaVersion() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      return prefs.getInt(_catalogSchemaPrefsKey) ?? 0;
    } catch (e) {
      appLogger.w('IPTV: catalog schema version unreadable', error: e);
      return -1;
    }
  }

  /// Record the catalog schema version as synced (v1.1.0): called only
  /// after a sync loop completes cleanly, never on abort — an aborted
  /// run must not claim the repair is done. Never throws.
  Future<void> _writeCatalogSchemaVersion(int version) async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setInt(_catalogSchemaPrefsKey, version);
    } catch (e) {
      appLogger.w('IPTV: catalog schema version unwritable', error: e);
    }
  }

  /// The index's lastSync per type at the moment the memoized catalog was
  /// populated (build v1.0.13, R4, test 6). A background-isolate sync
  /// writes the index + disk while this client is warm; when the stamp
  /// advances past the recorded one the memo is stale and must be
  /// dropped. A type that never synced stamps the epoch, so the first
  /// real sync invalidates the memo.
  final Map<String, DateTime> _memoSyncStamp = {};

  /// True when [e] is a transport failure (the panel did not answer at
  /// all), as opposed to a refusal or a bad payload (build v1.0.13, R4,
  /// D9). Only transport failures are worth a background retry.
  static bool _isTransportError(Object e) =>
      e is MediaServerHttpException &&
      (e.type == MediaServerHttpErrorType.connectionError ||
          e.type == MediaServerHttpErrorType.connectionTimeout ||
          e.type == MediaServerHttpErrorType.receiveTimeout);

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
    // R2.4: a forced sync is a manual refresh (or the Enter path) — the
    // user asked explicitly, so a transport-closed fetch is retried once.
    // A background/interval sync (force: false) never retries.
    return _runIndexWrite(
      () => _syncSearchIndex(
        force: force,
        onProgress: onProgress,
        abort: abort,
        retryTransportErrors: force,
      ),
    );
  }

  /// Background-isolate entry point for the periodic catalog sync (build
  /// v1.0.13, R4). Same engine as [syncSearchIndex], but: the interval
  /// comes from the caller (a background isolate has no SettingsService),
  /// cold types are skipped (D8 — a type with no index rows has no user
  /// waiting on it, and the job must not pay for a first sync the user
  /// never asked for), the playback check reads the SharedPreferences
  /// mirror (D4 — the in-memory activity is a fresh idle instance in a
  /// background isolate), and a transport failure is reported per type
  /// (D9) so the caller can decide whether the run is worth retrying.
  /// Never retries a transport error (the WorkManager backoff is the
  /// retry). A playback bail returns the partial result with
  /// [IptvSearchSyncResult.playbackAborted] set.
  Future<IptvSearchSyncResult> syncSearchIndexForBackground({
    int? intervalHours,
    AbortController? abort,
    Future<bool> Function()? isPlaybackActive,
  }) {
    if (!_isXtream) return Future.value(const IptvSearchSyncResult(rows: {}, skipped: {}));
    return _runIndexWrite(
      () => _syncSearchIndex(
        force: false,
        abort: abort,
        retryTransportErrors: false,
        intervalHoursOverride: intervalHours,
        skipColdTypes: true,
        backgroundPlaybackCheck: isPlaybackActive,
      ),
    );
  }

  /// R2.4: retry a panel fetch ONCE on a transport error only — the
  /// panel closing the connection mid-download ("Connection closed while
  /// receiving data", the series failure in Matt's logs) is worth one
  /// re-ask after a short backoff. Never retries timeouts (the panel is
  /// not answering at all), 4xx, oversize, or empty responses — and only
  /// when [retry] is true (forced syncs: manual refresh, Enter). The
  /// backoff is abort-aware: a background cancel during the 2 s wait
  /// stops the sync instead of re-fetching into a dead run. A second
  /// failure throws, and the caller records the type 'failed' as usual.
  Future<T> _fetchWithTransportRetry<T>(
    Future<T> Function() fetch, {
    required bool retry,
    required AbortController abort,
  }) async {
    try {
      return await fetch();
    } on MediaServerHttpException catch (e) {
      if (!retry || e.type != MediaServerHttpErrorType.connectionError) rethrow;
      await Future.any([
        Future<void>.delayed(const Duration(seconds: 2)),
        abort.trigger,
      ]);
      abort.throwIfAborted();
      return await fetch();
    }
  }

  Future<IptvSearchSyncResult> _syncSearchIndex({
    required bool force,
    void Function(IptvSearchSyncProgress)? onProgress,
    AbortController? abort,
    bool retryTransportErrors = false,
    int? intervalHoursOverride,
    bool skipColdTypes = false,
    Future<bool> Function()? backgroundPlaybackCheck,
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
    final transportFailed = <String>{};
    // Series fix (v1.0.16): types that landed a partial list on a cold
    // index — searchable now, still due for refetch. Not a failure.
    final partialTypes = <String>{};
    // R4: panel requests attempted (categories + catalog per type that
    // reaches the fetch). Exact on the background path (no retries); a
    // forced sync's R2.4 retry re-fetches without incrementing.
    var attempts = 0;
    // R4: the background isolate has no SettingsService, so the caller
    // hands the interval in directly.
    final intervalHours = intervalHoursOverride ?? _catalogSyncIntervalHours();
    final dbPath = await IptvSearchIndex.dbFilePath();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // v1.1.0 (Option B): the stored catalog schema. Version 2 is the
    // first schema whose index + disk files hold the FULL catalog (the
    // v1.0.16 write-time skip wrote visible rows only, so a pre-1.1.0
    // index/disk is lossy: un-hiding a group could not bring back rows
    // that were never written). When the stored version is below 2 the
    // next sync re-fetches every type once — the repair — and the
    // version is stamped only on a clean run (same D1 rule as the old
    // hidden fingerprint: a failed/empty/oversize/partial-kept leg, or
    // a transport failure, leaves the version unstamped so the next
    // sync retries the repair). A hidden-set change no longer forces a
    // sync: filtering happens at read time now, so a toggle is instant
    // and offline and the stored catalog is unaffected.
    final storedSchemaVersion = await _readCatalogSchemaVersion();
    // -1 means unreadable (raw isolate): no repair without evidence.
    final schemaRepair =
        storedSchemaVersion >= 0 &&
        storedSchemaVersion < _currentCatalogSchemaVersion;
    // Build #28: every sync owns an AbortController, registered so
    // [cancelBackgroundWork] can stop it when the app backgrounds. A
    // caller-passed controller (the manual refresh popup's Cancel) is
    // registered too — backgrounding cancels it as well.
    abort ??= AbortController();
    _activeBackgroundAborts.add(abort);
    _refreshSearchIndexState(syncing: true);
    // R4 (D5): mark this sync as running so a concurrent run in another
    // isolate yields instead of duplicating the 6 requests. Cleared in
    // the finally below; a crash leaves a stamp that ages out in 30 min.
    await _writeSyncRunningStamp();
    try {
      for (final type in IptvSearchIndex.types) {
        abort.throwIfAborted();
        final lastSync = index.lastSync(connection.id)[type];
        final indexedCount = index.rowCounts(connection.id)[type] ?? 0;
        if (!force && !schemaRepair && intervalHours > 0 && lastSync != null && indexedCount > 0) {
          final ageHours = DateTime.now().difference(lastSync).inHours;
          if (ageHours < intervalHours) {
            skipped[type] = 'up-to-date';
            onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'up-to-date'));
            continue;
          }
        }
        if (!force && !schemaRepair && intervalHours == 0 && indexedCount > 0) {
          // Manual-only interval and the index already has rows: only
          // an explicit manual refresh (force) syncs.
          skipped[type] = 'up-to-date';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'up-to-date'));
          continue;
        }
        if (skipColdTypes && indexedCount == 0) {
          // Build v1.0.13 (R4, D8): the background job never pays for a
          // first sync — a type with no index rows has no user waiting
          // on it, and the foreground bind/manual refresh owns first
          // syncs. Skipping is not a failure: the type stays cold until
          // the user opens it.
          skipped[type] = 'cold';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'cold'));
          continue;
        }
        // Build #28: background work waits while a stream is playing.
        // A forced (manual) refresh is the user asking explicitly, so
        // it is not gated. Otherwise the sync pauses between types and
        // resumes when playback stops — it is not abandoned. The abort
        // races the wait, so a background cancel still stops a sync
        // that is parked on playback.
        if (!force) await _waitForIdleUnlessAborted(abort, backgroundPlaybackCheck: backgroundPlaybackCheck);
        onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'fetching'));
        List<XtreamCategory> categories;
        int fetchedCount;
        String? catalogBody;
        // Hoisted out of the fetch try so the disk write + memoized
        // publish below can use the parsed rows after the guards pass.
        List<Object>? fetchedRows;
        try {
          // R2.4: each fetch gets its own retry (categories and catalog
          // separately) — retrying the whole per-type block would cost
          // +2 requests instead of +1.
          attempts++;
          categories = await _fetchWithTransportRetry(
            () => _fetchCategoriesFor(type, abort),
            retry: retryTransportErrors,
            abort: abort,
          );
          // The unfiltered getters store the raw body on the api (see
          // lastXxxStreamsBody) — read it synchronously right after the
          // await, before any other await, so a concurrent browse load
          // cannot swap it underneath this sync.
          final List<Object> fetched;
          switch (type) {
            case IptvSearchIndex.typeLive:
              attempts++;
              fetched = await _fetchWithTransportRetry(
                () => _xtreamApi.getLiveStreams(abortTrigger: abort?.trigger),
                retry: retryTransportErrors,
                abort: abort,
              );
              catalogBody = _xtreamApi.lastLiveStreamsBody;
            case IptvSearchIndex.typeMovie:
              attempts++;
              fetched = await _fetchWithTransportRetry(
                () => _xtreamApi.getVodStreams(abortTrigger: abort?.trigger),
                retry: retryTransportErrors,
                abort: abort,
              );
              catalogBody = _xtreamApi.lastVodStreamsBody;
            default:
              attempts++;
              fetched = await _fetchWithTransportRetry(
                () => _xtreamApi.getSeries(abortTrigger: abort?.trigger),
                retry: retryTransportErrors,
                abort: abort,
              );
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
          if (_isTransportError(e)) transportFailed.add(type);
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
          // 'partial-kept' (v1.0.16 dialog fix): the old rows are kept
          // and searchable, so the dialog must not call it a failure.
          skipped[type] = 'partial-kept';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'partial-kept'));
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
              // v1.1.0 (Option B): the isolate lands the FULL rows;
              // the hidden sets only feed its hiddenSkipped count.
              hiddenCategoryIds: _hiddenCategories.toList(),
              hiddenCategoryInitials: _hiddenCategoryInitials.toList(),
            ),
          );
          if (result.skippedReason != null) {
            skipped[type] = result.skippedReason!;
            onProgress?.call(
              IptvSearchSyncProgress(type: type, phase: 'skipped', reason: result.skippedReason),
            );
            // Series fix (v1.0.16): the numbers that separate a
            // panel-truncated list (C1: dropped 0) from a parse-dropped
            // one (C3: dropped > 0) on the next failure.
            if (result.skippedReason == 'partial-kept') {
              appLogger.i(
                'IPTV: catalog sync skipped $type as partial-kept (covered ${result.coveredCategories}/${result.totalCategories} categories, ${result.droppedRows} rows dropped in parse, ${result.hiddenSkipped} in hidden categories)',
              );
            }
            continue;
          }
          rows[type] = result.rowCount;
          if (result.partial) {
            partialTypes.add(type);
            appLogger.i(
              'IPTV: catalog sync landed $type partial (${result.rowCount} rows, ${result.coveredCategories}/${result.totalCategories} categories, ${result.droppedRows} rows dropped in parse) - the type stays due for refetch, the disk catalog is untouched',
            );
          } else if (result.hiddenSkipped > 0) {
            appLogger.i(
              'IPTV: catalog sync landed $type (${result.rowCount} rows, ${result.hiddenSkipped} in hidden categories — filtered at read time)',
            );
          }
          // Build #23 (startup rule): the sync is the ONLY catalog
          // fetcher, so it also refreshes the disk catalog the browse
          // screens and the warm-ups read from (raw body + category
          // list), and publishes the fresh rows into the memoized
          // futures so the session sees them without a restart. A
          // guarded-out sync leaves both the disk file and the index
          // untouched. A disk-write failure never fails the sync — the
          // index is the primary store.
          //
          // Series fix (v1.0.16): a partial land is INDEX-ONLY — it
          // never overwrites the disk catalog and never publishes into
          // the memoized catalog (P5a: a 635-row partial list must not
          // clobber a 46,527-row good disk file). The disk file only
          // ever gets complete lists; the next sync (the type stays
          // due) refreshes it when the panel answers in full.
          if (!result.partial) {
            try {
              // v1.1.0 (Option B): the disk file holds the FULL catalog
              // (the raw body, verbatim) — the v1.0.16 filtered body is
              // gone. The cache size and the seed now reflect the whole
              // catalog; the read-time filter hides rows, never the
              // store.
              await _catalogCache.write(
                connection.id,
                _diskDatasetFor(type),
                body,
              );
              await _catalogCache.write(
                connection.id,
                _diskCategoryDatasetFor(type),
                jsonEncode(categories.map((c) => c.toJson()).toList()),
              );
              // fetchedRows is set by the fetch try above; every failure
              // path (throw, empty, partial, oversize) continues past here.
              // The memoized publish carries ALL fetched rows now — every
              // listing consumer filters hidden categories at read time
              // (browse, categories, guide, search), so a hidden row
              // never surfaces; a direct id resolve (favourite/resume)
              // still opens it, as before v1.0.16.
              _publishSyncedCatalog(type, fetchedRows, categories);
            } catch (e) {
              appLogger.w('IPTV: catalog sync disk write failed for $type', error: e);
            }
          }
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'done', rows: result.rowCount, partial: result.partial));
        } catch (e) {
          appLogger.w('IPTV: catalog sync write failed for $type', error: e);
          skipped[type] = 'failed';
          onProgress?.call(IptvSearchSyncProgress(type: type, phase: 'skipped', reason: 'failed'));
        }
      }
      // v1.1.0 (Option B, D1 rule carried over): stamp the catalog
      // schema version ONLY when the run actually completed. A type
      // skipped 'failed', 'empty-response', 'oversize' or
      // 'partial-kept' kept its old rows with a recent lastSync, so
      // stamping would make the next bind skip it as up-to-date and
      // the repair would never happen — the lossy rows would stay
      // until the weekly interval lapsed, with no indication why. The
      // partial-kept trigger is the one Matt's panel hits every day
      // (it persistently returns partial series lists); the transport
      // trigger is the one his flaky panel hits right now.
      // Deliberately NOT the hasFailure mirror: 'cold' does not block
      // (a cold type has no rows and no lastSync, so it stays due and
      // its first fetch lands the full rows), and 'partial-kept' DOES
      // block (see above). An aborted run never reaches here, so it
      // cannot claim the repair is done either.
      final repairApplied = !skipped.values.any(
        (reason) =>
            reason == 'failed' ||
            reason == 'empty-response' ||
            reason == 'oversize' ||
            reason == 'partial-kept',
      ) && transportFailed.isEmpty;
      if (repairApplied) {
        await _writeCatalogSchemaVersion(_currentCatalogSchemaVersion);
      } else {
        appLogger.w(
          'IPTV: catalog sync did not complete cleanly (skipped=$skipped transportFailed=$transportFailed) - the catalog schema version is not updated, so the next sync retries the repair',
        );
      }
      return IptvSearchSyncResult(rows: rows, skipped: skipped, transportFailedTypes: transportFailed, requests: attempts, partialTypes: partialTypes);
    } on _BackgroundPlaybackActive {
      // R4 (D4): playback started mid-run — bail with the partial
      // result; the caller maps it to a retry, and the types already
      // synced stay synced.
      return IptvSearchSyncResult(
        rows: rows,
        skipped: skipped,
        transportFailedTypes: transportFailed,
        playbackAborted: true,
        requests: attempts,
      );
    } finally {
      _activeBackgroundAborts.remove(abort);
      await _clearSyncRunningStamp();
      _refreshSearchIndexState();
    }
  }

  /// Wait until no stream is playing (build #28), or throw when [abort]
  /// fires first. Background panel work calls this before starting a
  /// fetch, so it never stacks on top of viewing traffic on a
  /// one-connection line. The wait is raced against the abort trigger:
  /// a sync parked on playback still stops when the app backgrounds.
  /// (The parked `waitForIdle` listener self-cleans at the next
  /// `markIdle` when the abort wins the race.)
  Future<void> _waitForIdleUnlessAborted(
    AbortController? abort, {
    Future<bool> Function()? backgroundPlaybackCheck,
  }) async {
    // R4 (D4): in a background isolate the in-memory activity is a fresh
    // (idle) instance, so the check reads the SharedPreferences mirror
    // instead — and the job never WAITS for idle, it bails so WorkManager
    // can retry. The foreground path keeps waiting (build #28).
    final backgroundCheck = backgroundPlaybackCheck;
    if (backgroundCheck != null) {
      if (await backgroundCheck()) throw const _BackgroundPlaybackActive();
      return;
    }
    final activity = IptvPlaybackActivity.instance;
    if (!activity.isPlaying) return;
    final trigger = abort?.trigger;
    if (trigger == null) {
      await activity.waitForIdle();
      return;
    }
    await Future.any([activity.waitForIdle(), trigger]);
    abort?.throwIfAborted();
  }

  /// Drop a memoized catalog when the index was written out-of-band after
  /// it was populated (build v1.0.13, R4): a background-isolate sync
  /// writes the DB + disk while this client is warm, and the memo would
  /// otherwise serve stale rows until restart. The stamp is the index's
  /// lastSync for the type; a newer stamp means the memo predates a sync.
  /// The check is one small SQLite query on an already-open index — no
  /// panel traffic. Never throws; on any failure the memo is kept.
  Future<void> _invalidateMemoIfIndexAdvanced(String type) async {
    if (_closed) return;
    final stamp = _memoSyncStamp[type];
    if (stamp == null) return;
    try {
      final index = await _searchIndex();
      if (index == null) return;
      final current = index.lastSync(connection.id)[type];
      if (current == null || !current.isAfter(stamp)) return;
      switch (type) {
        case IptvSearchIndex.typeLive:
          _liveStreamsFuture = null;
          _liveStreamsLoaded = false;
          _liveCategoriesFuture = null;
          _liveCategoryNamesFuture = null;
        case IptvSearchIndex.typeMovie:
          _vodStreamsFuture = null;
          _vodStreamsLoaded = false;
          _vodCategoriesFuture = null;
          _vodCategoryNamesFuture = null;
        default:
          _seriesFuture = null;
          _seriesListLoaded = false;
          _seriesCategoriesFuture = null;
          _seriesCategoryNamesFuture = null;
      }
      _memoSyncStamp.remove(type);
    } catch (e) {
      appLogger.w('IPTV: memo stamp check failed for $type', error: e);
    }
  }

  /// Record the index's lastSync for [type] as the memo's stamp, so a
  /// later background run is detectable. A type that never synced stamps
  /// the epoch, so the first real sync invalidates the memo.
  Future<void> _recordMemoStamp(String type) async {
    if (_closed) return;
    try {
      final index = await _searchIndex();
      _memoSyncStamp[type] =
          index?.lastSync(connection.id)[type] ?? DateTime.fromMillisecondsSinceEpoch(0);
    } catch (e) {
      appLogger.w('IPTV: memo stamp record failed for $type', error: e);
    }
  }

  /// Publish freshly synced rows into the memoized catalog futures
  /// (build #23): the warm-up may have populated them with the stale
  /// disk rows, and the sync is the newer truth — browse/search must
  /// see the refreshed catalog without a restart.
  ///
  /// Build v1.0.10 (M5): the synced categories are published too — the
  /// index is the single source for them (the sync just wrote this same
  /// list into the index's category table), so the memoized category
  /// futures copy from it and the derived id -> name maps are cleared
  /// to re-derive from the fresh lists. Before, a sync left the pre-
  /// sync category names in place until restart, so the hidden-category
  /// filter and the title-prefix strip used stale names. The library
  /// views are told the catalog changed (the old background refresh did
  /// this after its swap; the sync is the refresh now).
  void _publishSyncedCatalog(String type, List<Object> rows, List<XtreamCategory> categories) {
    switch (type) {
      case IptvSearchIndex.typeLive:
        _liveStreamsFuture = Future.value(rows.cast<XtreamLiveStream>());
        _liveStreamsLoaded = true;
        _liveLoadSource = 'network';
        _liveCategoriesFuture = Future.value(categories);
        _liveCategoryNamesFuture = null;
      case IptvSearchIndex.typeMovie:
        _vodStreamsFuture = Future.value(rows.cast<XtreamVodStream>());
        _vodStreamsLoaded = true;
        _vodLoadSource = 'network';
        _vodCategoriesFuture = Future.value(categories);
        _vodCategoryNamesFuture = null;
      default:
        _seriesFuture = Future.value(rows.cast<XtreamSeries>());
        _seriesListLoaded = true;
        _seriesLoadSource = 'network';
        _seriesCategoriesFuture = Future.value(categories);
        _seriesCategoryNamesFuture = null;
    }
    // The Live TV guide subscribes to the same notifier: it must only
    // reload for live rows / live categories. A VOD- or series-only
    // sync landing used to rebuild the whole 55k-channel guide and
    // re-fetch EPG for the visible channels (build #14, SA-4 partial),
    // so the event carries which catalog actually changed.
    notifyCatalogRefreshed(liveCatalogChanged: type == IptvSearchIndex.typeLive);
    // R4: the sync just stamped the index — record it as the memo's
    // stamp, so a LATER background run is detectable (the publish is
    // this type's memo population).
    final index = _searchIndexInstance;
    if (index != null) {
      _memoSyncStamp[type] =
          index.lastSync(connection.id)[type] ?? DateTime.fromMillisecondsSinceEpoch(0);
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
  ///
  /// Build v1.0.11 (R2.3): coalesced — a second caller while one run is
  /// in flight joins the SAME future instead of starting a second sync
  /// (the #29 tester nit: a racing double trigger cost 8 requests
  /// instead of 6; the index-write mutex alone still let the second run
  /// re-fetch a type the first run had just marked failed). Returns the
  /// in-flight run so a caller can await it (the Enter path kicks it
  /// off fire-and-forget and reads the disk meanwhile).
  Future<void>? _ensureSyncedInFlight;

  Future<void> ensureSearchIndexSynced({bool retryTransportErrors = false}) {
    if (!_isXtream) return Future.value();
    final existing = _ensureSyncedInFlight;
    if (existing != null) return existing;
    final future = _runIndexWrite(() async {
      // R4 (D5): another isolate is already syncing — yield instead of
      // duplicating the 6 requests. Best-effort (a stamp written after
      // this check still races), and the in-flight coalescing above
      // covers the same-isolate case. The stamp read runs CONCURRENTLY
      // with the seed: the read may pay a first-load cost on the prefs
      // cache, and awaiting it serially before the seed delayed the
      // sync's first fetch past a search's return (build18 D4). The
      // seed does not depend on the stamp, so the two overlap; the
      // yield decision still gates the fetch loop below.
      final stampElsewhereFuture = isSyncRunningElsewhere();
      await _seedSearchIndexFromDisk();
      if (await stampElsewhereFuture) return;
      await _syncSearchIndex(
        force: false,
        onProgress: null,
        abort: null,
        retryTransportErrors: retryTransportErrors,
      );
    });
    _ensureSyncedInFlight = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_ensureSyncedInFlight, future)) _ensureSyncedInFlight = null;
      }).catchError((Object _) {}),
    );
    return future;
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

  /// Build #25: max resume entries per connection (OpenTV's
  /// `observeRecent` default). Oldest-first eviction on insert, so the
  /// store stays ~6 KB.
  static const int _maxResumeEntries = 30;

  /// Build #25: the 5-second anti-clutter floor (OpenTV saves only when
  /// `pos > 5_000`; IPTVnator only lists an item after it "actually
  /// played for a couple of seconds"). A report below this never creates
  /// a row, so streams that fail right away don't clutter Continue
  /// Watching.
  static const int _resumeRecordFloorMs = 5000;

  // Resume positions for VOD movies / episodes (id -> snapshot),
  // persisted per connection. Same shape as the favourites store:
  // loaded lazily; the report methods update the cached map so browse /
  // search / detail all agree without re-reading prefs.
  IptvResumeRepository _resumeRepository =
      const SharedPreferencesIptvResumeRepository();
  Future<Map<String, IptvResumeItem>>? _resumeItemsFuture;

  /// Test-only override for the resume repository, so unit tests can
  /// share one store across client instances. Production code never sets
  /// this.
  @visibleForTesting
  set testResumeRepository(IptvResumeRepository repository) {
    _resumeRepository = repository;
    _resumeItemsFuture = null;
  }

  /// Prefs key for this connection's resume positions.
  String get _resumeKey => 'iptv_resume:${connection.id}';

  Future<Map<String, IptvResumeItem>> _resumeItems() =>
      _resumeItemsFuture ??= _resumeRepository.read(key: _resumeKey);

  /// Best-effort display snapshot (title / poster / library) for the
  /// item currently playing, stashed in [getPlaybackInitialization] —
  /// the one place the full item passes through the client at playback
  /// time. The report methods only receive an id, so without this the
  /// stored snapshot would have no title. Purely in-memory and bounded;
  /// a restart loses nothing the catalog re-resolution cannot refill.
  final Map<
    String,
    ({
      String? title,
      String? thumbPath,
      String? libraryId,
      String? parentId,
      String? parentTitle,
    })
  >
  _resumeSnapshots = {};

  /// Monotonic last-viewed clock: two stops in the same millisecond must
  /// still order deterministically (newest first), so the clock never
  /// goes backwards within this client.
  int _lastResumeTimestampMs = 0;

  /// Concurrent per-category fallback batch size (Task 8): the panel
  /// answers per-category calls even when the unfiltered call returns [].
  /// 16, not 8 (build #13): at 8 the sweep covered ~72 categories inside
  /// its 900ms deadline on a scaled Trex shape (150 visible categories,
  /// 100ms per call) and missed a match in category 120 — both the sweep
  /// and the crawl walk the list in order, so the batch size IS the
  /// reach. 16 doubles the reach without doubling the per-batch wait
  /// (one batch still costs one slow call, not sixteen), and at Matt's
  /// real scale (~270 series categories) it brings a full crawl inside
  /// ~9s at 500ms per call.
  static const int _catalogFallbackBatchSize = 16;

  /// Build #21 — the search burst cap. Retained after R2.3 deleted the
  /// sweep: the sections make no panel requests, so no search request
  /// acquires a permit today — the semaphore stays wired through
  /// [_searchItemsInner] so a future search path that needs the panel
  /// reuses this cap instead of inventing a new one. The sizing history
  /// below still applies to any per-category fetching. Before #21, each
  /// section ran 32 concurrent category calls, so a cold search put ~96
  /// requests on a panel that allows 1 connection.
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
  /// by the three sections of every search on this client. Retained after
  /// R2.3 deleted the sweep — the sections make no panel requests, so no
  /// search request acquires a permit today; the semaphore stays wired so
  /// a future search path that needs the panel reuses the cap. A permit
  /// is released when its call lands (or aborts); a permit is never held
  /// past the section budget.
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

  /// The line's connection limit (build #28), cached from the panel's
  /// `user_info.max_connections` the one time the client calls
  /// `getUserInfo()` — the health probe. Null until the probe has run
  /// (or the panel did not report it): unknown.
  int? _maxConnections;

  /// The connection limit the panel last reported, or null when unknown.
  int? get maxConnections => _maxConnections;

  /// True when this line allows one stream at a time — or when the
  /// limit is unknown (build #28). A one-connection line is the common
  /// Xtream shape, and the wait-for-release cost is bounded by the
  /// player stop completing (usually tens of milliseconds), so waiting
  /// when unsure is the safe default: opening the next stream before
  /// the old one is released stacks two streams on the only session
  /// and the panel answers 458.
  bool get isSingleConnection => _maxConnections == null || _maxConnections == 1;

  /// How long after a recorded 403 the health probe stays backed off
  /// (build #28) — the boards' "wait 5 min with everything closed"
  /// advice, as a duration. Test-overridable.
  @visibleForTesting
  static Duration refusalProbeBackoff = const Duration(minutes: 5);

  /// The refusal log this client consults before probing (build #28).
  /// Defaults to the app-wide singleton; tests inject a log backed by
  /// fake prefs.
  IptvRefusalLog _refusalLog = IptvRefusalLog.instance;

  @visibleForTesting
  set testRefusalLog(IptvRefusalLog log) => _refusalLog = log;

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

  /// AbortControllers for background panel work currently in flight on
  /// this client (build #28): the weekly index sync and the stale-disk
  /// catalog refreshes. [cancelBackgroundWork] triggers every controller
  /// in this set when the app backgrounds, so work nobody is watching
  /// stops talking to the panel. A controller is added when its job
  /// starts and removed when the job settles; aborting one that already
  /// settled is a no-op. The set never grows past the concurrent
  /// background jobs (6 catalog refreshes + 1 sync).
  final Set<AbortController> _activeBackgroundAborts = <AbortController>{};

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

  /// Public read of [_isHiddenCategory] (v1.0.16): the guide category
  /// submenu resolves the channel's category state through this, so the
  /// menu and the guide rows can never disagree about what is hidden.
  bool isCategoryHidden(String? categoryId, String? categoryName) => _isHiddenCategory(categoryId, categoryName);

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
    continueWatchingRemoval: true,
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

  /// Stop background panel work on this client (build #28): the weekly
  /// index sync, the stale-disk catalog refreshes, and the in-flight
  /// EPG fetches. Called when the app backgrounds
  /// ([MultiServerManager.cancelActiveIptvBackgroundWork], wired in
  /// main.dart next to [cancelActiveSearches]) and when a connection is
  /// torn down. Safe to call with nothing in flight (no-op). The client
  /// stays usable afterwards — only the in-flight background jobs are
  /// cancelled, not the connection itself (use [close] to tear the
  /// connection down). A sync parked on playback (see
  /// [_waitForIdleUnlessAborted]) stops too — its wait races the abort.
  void cancelBackgroundWork() {
    for (final abort in _activeBackgroundAborts.toList()) {
      abort.abort();
    }
    _liveTv.cancelBackgroundWork();
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
    // disk/sync paths until the next sync seeds it again. The index
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
  /// 'PlezTV'. Read by [MediaImageHelper.artworkHeadersFor].
  Map<String, String> get artworkHeaders => {'User-Agent': _xtreamUserAgent()};

  @override
  double get watchedThreshold => 0.9;

  /// Build #25 (trap T4): the stop report IS the watched-mark for IPTV
  /// — [reportPlaybackStopped] deletes a resume entry at/above the
  /// threshold — so the tracker must not also issue an explicit
  /// [markWatched] on every finished stop (it would call the local-only
  /// no-op path and claim the server acknowledged a mark that never
  /// happened). With this true, the tracker settles the watch from the
  /// stop report alone and only emits the local watched event.
  @override
  bool get marksWatchedOnPlaybackStopped => true;

  @override
  LiveTvSupport get liveTv => _liveTv;

  /// True when the refusal log holds a 403 for this connection recorded
  /// within [refusalProbeBackoff] (build #28). Only a 403 (access
  /// denied) backs off the probe — a 429 is rate-limiting, not a
  /// refusal, and the probe is how the app learns the panel recovered.
  /// A log that cannot be loaded says nothing, so the probe runs
  /// (fail-open: a broken log must not take the server offline). The
  /// check is best-effort by construction: a refusal recorded
  /// fire-and-forget a moment earlier may not have persisted yet, so
  /// one probe can slip through — one call, not a sweep.
  Future<bool> _hasRecentRefusal() async {
    try {
      await _refusalLog.ensureLoaded();
    } catch (_) {
      return false;
    }
    final cutoff = DateTime.now().subtract(refusalProbeBackoff);
    return _refusalLog.entriesNotifier.value.any(
      (e) => e.connectionId == connection.id && e.statusCode == 403 && e.timestamp.isAfter(cutoff),
    );
  }

  @override
  Future<HealthStatus> checkHealth() async {
    // Build #28: after a refusal, do not re-probe the panel on every
    // resume. A refused `player_api.php` call counts toward the panel's
    // flood limit, so a probe that lands on a panel that just refused
    // us feeds the very block it is trying to measure. While the
    // refusal log holds a 403 for this connection recorded within
    // [refusalProbeBackoff], return the last-known verdict with no
    // panel call. After the window, probe normally. A fresh sign-in
    // bypasses this (different path — the user explicitly asked).
    if (await _hasRecentRefusal()) {
      return _lastHealthStatus;
    }
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
        // Build #28: cache the line's connection limit from the one
        // `getUserInfo()` the client makes — the zap path and the
        // pre-tune gate read it (see [isSingleConnection]). A reply
        // without the field leaves the previous value alone.
        final maxConnections = int.tryParse('${info['max_connections']}');
        if (maxConnections != null) _maxConnections = maxConnections;
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

  /// Build v1.0.10 (M3, one freshness rule): the browse refresh IS the
  /// sync. After serving disk rows, fire [ensureSearchIndexSynced] when
  /// this type is due under the sync interval — the sync fetches the
  /// catalog + categories once, under the guards, and writes disk +
  /// index together, so one fetch feeds both stores and a partial panel
  /// answer can never clobber a good disk file through a side door.
  /// When the type is not due (or the interval is manual-only) nothing
  /// is fetched: the disk file's age follows the index's last sync, not
  /// a separate 24 h clock. The due check is coarse (the sync itself
  /// re-checks per type and skips what is up-to-date), and several
  /// browse loads firing at once serialize through the index-write
  /// mutex — the second run finds everything up-to-date and fetches
  /// nothing. The sync keeps build #28's gating (it waits for idle
  /// while a stream is playing and is cancellable on backgrounding),
  /// and the seed that runs first stamps the disk's real age (M1), so
  /// the due check here reads true ages.
  ///
  /// This replaces [_refreshCatalogInBackground] (deleted with it): the
  /// old side door bypassed the sync guards, never wrote the index, and
  /// had no partial guard for live at all (M4 — the sync's guard covers
  /// live too).
  void _refreshCatalogViaSyncIfDue(String type) {
    if (!_isXtream) return;
    unawaited(
      () async {
        final index = await _searchIndex();
        if (index == null) return;
        final intervalHours = _catalogSyncIntervalHours();
        if (intervalHours == 0) return; // Manual-only: no automatic refresh.
        final lastSync = index.lastSync(connection.id)[type];
        final rows = index.rowCounts(connection.id)[type] ?? 0;
        final due = lastSync == null ||
            rows == 0 ||
            DateTime.now().difference(lastSync).inHours >= intervalHours;
        if (due) unawaited(ensureSearchIndexSynced());
      }(),
    );
  }

  Future<List<XtreamLiveStream>> _liveStreams() async {
    await _invalidateMemoIfIndexAdvanced(IptvSearchIndex.typeLive);
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
    await _recordMemoStamp(IptvSearchIndex.typeLive);
    return result;
  }

  /// Disk first (build #11): a cached live list is served immediately;
  /// a due one is served and refreshed by the sync (build v1.0.10, one
  /// freshness rule — the sync interval, not a separate 24 h clock).
  /// No disk cache (first run, cleared, corrupt) falls back to the
  /// network fetch.
  Future<List<XtreamLiveStream>> _loadLiveStreamsCached() async {
    final disk = await _readDiskCatalog<XtreamLiveStream>(
      IptvCatalogDiskCache.liveDataset,
      XtreamApi.parseLiveStreamsBody,
    );
    if (disk != null) {
      _liveLoadSource = 'disk';
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeLive);
      return disk.rows;
    }
    final rows = await _xtreamApi.getLiveStreams();
    _liveLoadSource = 'network';
    // v1.1.0 (Option B): the disk file holds the FULL catalog — the
    // v1.0.16 write-time filter is gone. Live first-load has no
    // coverage guard (series fix left it as-is).
    _writeCatalogRows(
      IptvCatalogDiskCache.liveDataset,
      rows,
      (r) => r.toJson(),
      _xtreamApi.lastLiveStreamsBody,
    );
    return rows;
  }

  Future<List<XtreamVodStream>> _vodStreams() async {
    await _invalidateMemoIfIndexAdvanced(IptvSearchIndex.typeMovie);
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
    await _recordMemoStamp(IptvSearchIndex.typeMovie);
    return result;
  }

  /// Coverage guard for first-load disk writes (series fix, v1.0.16):
  /// an unfiltered list covering fewer than half the categories is a
  /// partial panel answer, not the catalog — serve it in memory, never
  /// persist it as the complete disk file (the P5a poison: a partial
  /// write bakes the filter into storage, and the seed then refuses the
  /// file forever). Mirrors the isolate write's 0.5 threshold. The
  /// [complete] flag alone cannot tell: a non-empty unfiltered answer
  /// can still be a partial one. Fail-closed: when the category list
  /// cannot be read, the rows are served but not persisted.
  Future<bool> _coversEnoughCategories(String type, Iterable<String> rowCategoryIds) async {
    List<XtreamCategory> categories;
    try {
      categories = await switch (type) {
        IptvSearchIndex.typeLive => _liveCategories(),
        IptvSearchIndex.typeMovie => _vodCategories(),
        _ => _seriesCategories(),
      };
    } catch (e) {
      appLogger.w('IPTV: category list unavailable for first-load guard ($type)', error: e);
      return false;
    }
    if (categories.isEmpty) return false;
    // v1.1.0 (Option B): the denominator counts ALL categories — a
    // fetch covering the whole catalog is complete even when most
    // categories are hidden, and hidden rows count toward the covered
    // set (they are in the disk file now, filtered at read time).
    final allIds = {for (final c in categories) c.id};
    final covered = rowCategoryIds.toSet().intersection(allIds);
    final ok = covered.length / allIds.length >= 0.5;
    if (!ok) {
      appLogger.i(
        'IPTV: partial unfiltered $type load not persisted (covered ${covered.length}/${allIds.length} categories)',
      );
    }
    return ok;
  }

  /// Disk first (build #11); the network load (with its per-category
  /// fallback) runs only on a miss, and the merged rows are written to
  /// disk — so a panel whose unfiltered call returns [] still gets a
  /// cached catalog from the fallback per-category crawl.
  ///
  /// Build #18: the disk write happens ONLY when the load came from the
  /// unfiltered call. A crawl has no single raw body, and persisting a
  /// merged partial could clobber a full disk file — the exact poison
  /// that made Trex series search return [] on the phone (the VOD loader
  /// has the same shape). Crawl rows are served in memory, never written.
  Future<List<XtreamVodStream>> _loadVodStreamsCached() async {
    final disk = await _readDiskCatalog<XtreamVodStream>(
      IptvCatalogDiskCache.vodDataset,
      XtreamApi.parseVodStreamsBody,
    );
    if (disk != null) {
      _vodLoadSource = 'disk';
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeMovie);
      return disk.rows;
    }
    final loaded = await _loadVodStreams();
    _vodLoadSource = loaded.complete ? 'network' : 'crawl';
    if (loaded.complete &&
        await _coversEnoughCategories(
          IptvSearchIndex.typeMovie,
          loaded.rows.map((r) => r.categoryId).whereType<String>(),
        )) {
      // v1.1.0 (Option B): the disk file holds the FULL catalog (the
      // guard above already counts all categories).
      _writeCatalogRows(
        IptvCatalogDiskCache.vodDataset,
        loaded.rows,
        (r) => r.toJson(),
        _xtreamApi.lastVodStreamsBody,
      );
    }
    return loaded.rows;
  }

  /// Unfiltered first (the fast path when the panel answers); when it
  /// returns [], fall back to a per-category fetch — the panel answers
  /// per-category calls even when the unfiltered call is empty.
  ///
  /// Returns whether the rows came from the unfiltered call ([complete])
  /// or the per-category crawl: crawl rows must never be persisted as
  /// the catalog (build #18) — see [_loadVodStreamsCached].
  Future<({List<XtreamVodStream> rows, bool complete})> _loadVodStreams() async {
    final all = await _xtreamApi.getVodStreams();
    if (all.isNotEmpty) return (rows: all, complete: true);
    final categories = await _vodCategories().catchError((Object e) {
      appLogger.w('IPTV: VOD category list unavailable for fallback: $e');
      return const <XtreamCategory>[];
    });
    // v1.1.0 (Option B): the crawl fetches ALL categories — hidden ones
    // too. Rows are still never persisted (build #18); the read-time
    // filter hides them, and the next full sync re-fetches in one call.
    final wanted = categories.toList(growable: false);
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
    await _invalidateMemoIfIndexAdvanced(IptvSearchIndex.typeSeries);
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
    await _recordMemoStamp(IptvSearchIndex.typeSeries);
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
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeSeries);
      return disk.rows;
    }
    final loaded = await _loadSeries();
    _seriesLoadSource = loaded.complete ? 'network' : 'crawl';
    if (loaded.complete &&
        await _coversEnoughCategories(
          IptvSearchIndex.typeSeries,
          loaded.rows.map((r) => r.categoryId).whereType<String>(),
        )) {
      // v1.1.0 (Option B): the disk file holds the FULL catalog (the
      // guard above already counts all categories).
      _writeCatalogRows(
        IptvCatalogDiskCache.seriesDataset,
        loaded.rows,
        (r) => r.toJson(),
        _xtreamApi.lastSeriesBody,
      );
    }
    return loaded.rows;
  }

  /// Same empty-unfiltered fallback as [_loadVodStreams], for series.
  ///
  /// Returns whether the rows came from the unfiltered call ([complete])
  /// or the per-category crawl: crawl rows must never be persisted as
  /// the catalog (build #18) — see [_loadSeriesCached].
  Future<({List<XtreamSeries> rows, bool complete})> _loadSeries() async {
    final all = await _xtreamApi.getSeries();
    if (all.isNotEmpty) return (rows: all, complete: true);
    final categories = await _seriesCategories().catchError((Object e) {
      appLogger.w('IPTV: series category list unavailable for fallback: $e');
      return const <XtreamCategory>[];
    });
    // v1.1.0 (Option B): the crawl fetches ALL categories — hidden ones
    // too. Rows are still never persisted (build #18); the read-time
    // filter hides them, and the next full sync re-fetches in one call.
    final wanted = categories.toList(growable: false);
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
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeLive);
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
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeMovie);
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
      _refreshCatalogViaSyncIfDue(IptvSearchIndex.typeSeries);
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

  // -- Disk-only reads for the Enter path (R2.3) ------------------------
  // The submit path must never fetch from the panel outside the one
  // coalesced sync — the plain loaders fall back to the network on a
  // disk miss, which would add requests outside the sync and break the
  // "exactly 6". These helpers read local data only and are never
  // memoized into the shared futures (a disk miss here must not poison
  // a later network-backed lookup with an empty map).

  /// Category names from the memoized future when it exists, else the
  /// disk categories file, else {} — never the panel.
  Future<Map<String, String>> _vodCategoryNamesFromDisk() async {
    final cached = _vodCategoryNamesFuture;
    if (cached != null) return cached;
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.vodCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    return disk == null ? const <String, String>{} : {for (final c in disk.rows) c.id: c.name};
  }

  /// Same as [_vodCategoryNamesFromDisk], for series.
  Future<Map<String, String>> _seriesCategoryNamesFromDisk() async {
    final cached = _seriesCategoryNamesFuture;
    if (cached != null) return cached;
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.seriesCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    return disk == null ? const <String, String>{} : {for (final c in disk.rows) c.id: c.name};
  }

  /// Same as [_vodCategoryNamesFromDisk], for live TV.
  Future<Map<String, String>> _liveCategoryNamesFromDisk() async {
    final cached = _liveCategoryNamesFuture;
    if (cached != null) return cached;
    final disk = await _readDiskCatalog<XtreamCategory>(
      IptvCatalogDiskCache.liveCategoriesDataset,
      (body) async => XtreamApi.parseCategoriesBody(body),
    );
    return disk == null ? const <String, String>{} : {for (final c in disk.rows) c.id: c.name};
  }

  /// Catalog rows for the Enter path: the memoized list when loaded,
  /// else the disk file, else the crawl's published partial rows —
  /// never a network fetch. The source labels the diagnostics
  /// ('disk' / 'crawl' / the memoized load's own source); 'syncing'
  /// means nothing local exists yet and the kicked-off sync is fetching
  /// it — the screen re-runs the search when that sync lands.
  Future<({List<XtreamVodStream> rows, String source})> _vodRowsForEnterSearch() async {
    if (_vodStreamsLoaded && _vodStreamsFuture != null) {
      return (rows: await _vodStreamsFuture!, source: _vodLoadSource);
    }
    final disk = await _readDiskCatalog<XtreamVodStream>(
      IptvCatalogDiskCache.vodDataset,
      XtreamApi.parseVodStreamsBody,
    );
    if (disk != null) return (rows: disk.rows, source: 'disk');
    if (_vodPartialRows.isNotEmpty) return (rows: List.of(_vodPartialRows), source: 'crawl');
    return (rows: const <XtreamVodStream>[], source: 'syncing');
  }

  /// Same as [_vodRowsForEnterSearch], for series.
  Future<({List<XtreamSeries> rows, String source})> _seriesRowsForEnterSearch() async {
    if (_seriesListLoaded && _seriesFuture != null) {
      return (rows: await _seriesFuture!, source: _seriesLoadSource);
    }
    final disk = await _readDiskCatalog<XtreamSeries>(
      IptvCatalogDiskCache.seriesDataset,
      XtreamApi.parseSeriesBody,
    );
    if (disk != null) return (rows: disk.rows, source: 'disk');
    if (_seriesPartialRows.isNotEmpty) return (rows: List.of(_seriesPartialRows), source: 'crawl');
    return (rows: const <XtreamSeries>[], source: 'syncing');
  }

  /// Same as [_vodRowsForEnterSearch], for live TV (no crawl source —
  /// the live loader never publishes partial rows).
  Future<({List<XtreamLiveStream> rows, String source})> _liveRowsForEnterSearch() async {
    if (_liveStreamsLoaded && _liveStreamsFuture != null) {
      return (rows: await _liveStreamsFuture!, source: _liveLoadSource);
    }
    final disk = await _readDiskCatalog<XtreamLiveStream>(
      IptvCatalogDiskCache.liveDataset,
      XtreamApi.parseLiveStreamsBody,
    );
    if (disk != null) return (rows: disk.rows, source: 'disk');
    return (rows: const <XtreamLiveStream>[], source: 'syncing');
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

  MediaItem _movieItem(
    XtreamVodStream stream, {
    bool isFavorite = false,
    String? categoryName,
    IptvResumeItem? resume,
  }) {
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
      // Build #25: the catalog carries no movie duration, so the stored
      // position AND duration both come from the player's report.
      durationMs: resume?.durationMs,
      viewOffsetMs: resume?.positionMs,
      lastViewedAt: resume?.updatedAtMs,
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
    IptvResumeItem? resume,
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
      // Build #25: the episode duration stays the catalog's (the store
      // agrees with it); only the position and last-viewed stamp come
      // from the resume entry.
      viewOffsetMs: resume?.positionMs,
      lastViewedAt: resume?.updatedAtMs,
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
    final resume = await _resumeItems();
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
            resume: resume['movie:${s.streamId}'],
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
    final resume = await _resumeItems();
    final categoryNames = await _vodCategoryNames();
    return streams
        .where((s) => !_isHiddenCategory(s.categoryId, categoryNames[s.categoryId]))
        .map(
          (s) => _movieItem(
            s,
            isFavorite: favorites.containsKey('movie:${s.streamId}'),
            categoryName: categoryNames[s.categoryId],
            resume: resume['movie:${s.streamId}'],
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
    _memoSyncStamp[IptvSearchIndex.typeSeries] = disk.fetchedAt;
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
    _memoSyncStamp[IptvSearchIndex.typeMovie] = disk.fetchedAt;
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
    _memoSyncStamp[IptvSearchIndex.typeLive] = disk.fetchedAt;
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
      final resume = await _resumeItems();
      return streams
          .where((s) => s.categoryId == categoryId)
          .map(
            (s) => _movieItem(
              s,
              isFavorite: favorites.containsKey('movie:${s.streamId}'),
              categoryName: categoryNames[s.categoryId],
              resume: resume['movie:${s.streamId}'],
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
        final movieResume = await _resumeItems();
        final vodCategoryNames = await _vodCategoryNames();
        return _movieItem(
          stream,
          isFavorite: movieFavorites.containsKey('movie:${stream.streamId}'),
          categoryName: vodCategoryNames[stream.categoryId],
          resume: movieResume['movie:${stream.streamId}'],
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
          final episodeResume = await _resumeItems();
          final episodeCategoryNames = await _seriesCategoryNames();
          return _episodeItem(
            series,
            episode,
            seasonEntry.key,
            isFavorite: episodeFavorites.containsKey('episode:${series.seriesId}:${episode.id}'),
            seriesCategoryName: episodeCategoryNames[series.categoryId],
            resume: episodeResume['episode:${series.seriesId}:${episode.id}'],
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
    MediaItem? onDeckEpisode;
    // Build #25 (25.5): a series opens on the episode you would
    // continue — the latest-resumed episode of that series, if any.
    // Best-effort: a stale id simply leaves the episode null.
    if (item != null && item.kind == MediaKind.show) {
      try {
        final resume = await _resumeItems();
        final episodes = resume.values
            .where((e) => e.kind == 'episode' && e.parentId == id)
            .toList()
          ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
        if (episodes.isNotEmpty) {
          onDeckEpisode = await fetchItem(episodes.first.id);
        }
      } catch (_) {
        // On-deck is a convenience, never a failure.
      }
    }
    return (item: item, onDeckEpisode: onDeckEpisode);
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
      final resume = await _resumeItems();
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
              resume: resume['episode:${series.seriesId}:${episode.id}'],
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
    bool onlineAllowed = false,
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
        onlineAllowed: onlineAllowed,
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
    required bool onlineAllowed,
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
      // is skipped instead of kicking off a sync for rows the caller
      // will drop (build #21's request minimisation stands, R2.3).
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
      // it returns [] for this search — the Enter path answers from disk
      // in milliseconds, so the budget is a safety net for a stalled
      // disk read, not the 49 s sweep it used to bound (R2.3).
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
            onlineAllowed: onlineAllowed,
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
            onlineAllowed: onlineAllowed,
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
            onlineAllowed: onlineAllowed,
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
    final m3uResults = await _searchM3uEntries(needle, limit, excludedLibraryIds, m3uLiveTrace);
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
    Map<String, IptvResumeItem> resume,
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
        final initial = categoryInitial(categoryNames[stream.categoryId]);
        if (initial != null) trace.hiddenInitials.add(initial);
        continue;
      }
      out.add(
        _movieItem(
          stream,
          isFavorite: favorites.containsKey('movie:${stream.streamId}'),
          categoryName: categoryNames[stream.categoryId],
          resume: resume['movie:${stream.streamId}'],
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
        final initial = categoryInitial(categoryNames[s.categoryId]);
        if (initial != null) trace.hiddenInitials.add(initial);
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


  /// Search one section from the local index (build #23). Returns the
  /// section's matches when the index is warm for [type] — zero panel
  /// requests, regardless of [include] (global first; the aggregation
  /// filters by scope) — or null when the index is cold for the type,
  /// so the caller falls through to the disk/sync paths (R2.3). The
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
    final resume = await _resumeItems();
    final categoryNames = index.categoryNames(connection.id, IptvSearchIndex.typeMovie);
    final rows = index
        .search(connection.id, IptvSearchIndex.typeMovie, needle, limit: limit * 2)
        .map((r) => r.toVodStream())
        .toList(growable: false);
    final out = <MediaItem>[];
    trace.partialOut = out;
    _appendMovieMatches(rows, needle, limit, favorites, resume, categoryNames, out, <int>{}, trace);
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
        .search(connection.id, IptvSearchIndex.typeSeries, needle, limit: limit * 2)
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
        .search(connection.id, IptvSearchIndex.typeLive, needle, limit: limit * 2)
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
    bool onlineAllowed = false,
  }) async {
    try {
      final sectionStarted = DateTime.now();
      // Build #23 — scope inversion (global first): the index answers
      // first — zero panel requests when warm — REGARDLESS of [include];
      // the aggregation filters by scope. The [include] flag only gates
      // the cold fallback below: an excluded section with a cold index
      // is skipped instead of kicking off a sync for rows the caller
      // will drop (build #21's request minimisation stands, R2.3). Do
      // NOT move the check above the index call — that overturns #23
      // (see the build23 scope-inversion test).
      final indexOut = await _searchMoviesFromIndex(needle, limit, trace, sectionStarted);
      if (indexOut != null) return indexOut;
      if (!include) {
        trace.skipped = true;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return const [];
      }
      // Build v1.0.11 (R2.0 + R2.3 — cold index, local data only):
      // the index is cold for this type, so answer from the local rows
      // the app already has — the warm in-memory catalog, else the disk
      // file, else the crawl's published partial rows, else [] with the
      // syncing state. Typing and submit alike: the SEARCH RULE forbids
      // panel requests while typing, and these rows cost none. Only a
      // submit kicks off ONE coalesced sync (6 requests, the only panel
      // traffic), and the screen re-runs this search when it lands. No
      // sweep, no unfiltered load, no per-category fetch — the old cold
      // path (load-vs-sweep race + heal + disk repair) is deleted with
      // the sweep; the sync owns fetching now.
      if (onlineAllowed) unawaited(ensureSearchIndexSynced(retryTransportErrors: true));
      trace.cold = true;
      final favorites = await _favoriteItems();
      final resume = await _resumeItems();
      final categoryNames = await _vodCategoryNamesFromDisk();
      final diskRows = await _vodRowsForEnterSearch();
      final out = <MediaItem>[];
      trace.partialOut = out;
      final seen = <int>{};
      _appendMovieMatches(diskRows.rows, needle, limit, favorites, resume, categoryNames, out, seen, trace);
      trace.loadRows = diskRows.rows.length;
      trace.loadSource = diskRows.source;
      trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
      trace.loadMatches = out.length;
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
    bool onlineAllowed = false,
  }) async {
    try {
      final sectionStarted = DateTime.now();
      // Build #23: the local index answers first (see _searchMovies —
      // global first regardless of [include]; the flag gates the cold
      // fallback only).
      final indexOut = await _searchSeriesFromIndex(needle, limit, trace, sectionStarted);
      if (indexOut != null) return indexOut;
      if (!include) {
        trace.skipped = true;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return const [];
      }
      // Build v1.0.11 (R2.0 + R2.3 — cold index, local data only):
      // same shape as movies — local rows only; only a submit kicks off
      // the coalesced sync.
      if (onlineAllowed) unawaited(ensureSearchIndexSynced(retryTransportErrors: true));
      trace.cold = true;
      final favorites = await _favoriteItems();
      final categoryNames = await _seriesCategoryNamesFromDisk();
      final diskRows = await _seriesRowsForEnterSearch();
      final out = <MediaItem>[];
      trace.partialOut = out;
      final seen = <int>{};
      _appendSeriesMatches(diskRows.rows, needle, limit, favorites, categoryNames, out, seen, trace);
      trace.loadRows = diskRows.rows.length;
      trace.loadSource = diskRows.source;
      trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
      trace.loadMatches = out.length;
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
    bool onlineAllowed = false,
  }) async {
    try {
      final sectionStarted = DateTime.now();
      // Build #23: the local index answers first (see _searchMovies —
      // global first regardless of [include]; the flag gates the cold
      // fallback only).
      final indexOut = await _searchLiveFromIndex(needle, limit, trace, sectionStarted);
      if (indexOut != null) return indexOut;
      if (!include) {
        trace.skipped = true;
        trace.ms = DateTime.now().difference(sectionStarted).inMilliseconds;
        return const [];
      }
      // Build v1.0.11 (R2.0 + R2.3 — cold index, local data only):
      // same shape as movies — local rows only (live has no crawl
      // source); only a submit kicks off the coalesced sync.
      if (onlineAllowed) unawaited(ensureSearchIndexSynced(retryTransportErrors: true));
      trace.cold = true;
      final categoryNames = await _liveCategoryNamesFromDisk();
      // Hidden channels (build #17, §9) never match in Live TV search:
      // load the set once, then [_appendLiveMatches] skips them.
      await _liveTv.loadHiddenChannels();
      final diskRows = await _liveRowsForEnterSearch();
      final out = <MediaItem>[];
      trace.partialOut = out;
      _appendLiveMatches(diskRows.rows, needle, limit, categoryNames, out, <int>{}, trace);
      trace.loadRows = diskRows.rows.length;
      trace.loadSource = diskRows.source;
      trace.loadMs = DateTime.now().difference(sectionStarted).inMilliseconds;
      trace.loadMatches = out.length;
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
        final initial = categoryInitial(categoryNames[stream.categoryId]);
        if (initial != null) trace.hiddenInitials.add(initial);
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
    _SectionTrace trace,
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
        if (!match.hasMatch(entry.name)) continue;
        // A hidden group (its own switch, or its category initial) hides
        // its entries from search too. Item names are never filtered.
        // A match in a hidden group is counted on the trace (v1.1.0),
        // like the Xtream append builders, so the search screen can
        // name the hiding group instead of showing a bare "No results".
        if (_isHiddenGroup(entry.groupTitle)) {
          trace.hiddenMatches++;
          final initial = categoryInitial(entry.groupTitle);
          if (initial != null) trace.hiddenInitials.add(initial);
          continue;
        }
        if (_liveTv.isHiddenChannelKey(entry.tvgId ?? entry.url)) continue;
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
    // Build #25: local-only resume. Rows come from the per-connection
    // resume store; each id is re-resolved against the catalog (fresh
    // titles/posters), falling back to the stored snapshot when the item
    // left the catalog. No panel requests beyond the catalog the app
    // already holds in memory / on disk.
    if (!_isXtream) return const [];
    final saved = await _resumeItems();
    if (saved.isEmpty) return const [];
    final entries = saved.values.toList()..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    final favorites = await _favoriteItems();
    final out = <MediaItem>[];
    for (final entry in entries) {
      if (entry.libraryId != null && excludedLibraryIds.contains(entry.libraryId)) continue;
      MediaItem? item;
      try {
        item = await fetchItem(entry.id);
      } catch (e) {
        // A catalog failure for one resume row must not kill the list —
        // the snapshot below is the fallback.
        appLogger.w('IPTV: resume ${entry.id} could not re-resolve: $e');
      }
      item ??= _resumeSnapshotItem(entry, isFavorite: favorites.containsKey(entry.id));
      if (item == null) continue;
      out.add(item);
      if (count != null && out.length >= count) break;
    }
    return out;
  }

  /// A resume entry whose item left the catalog, rendered from its
  /// stored snapshot (favorites pattern). Unknown kinds render nothing.
  MediaItem? _resumeSnapshotItem(IptvResumeItem entry, {required bool isFavorite}) {
    final kind = switch (entry.kind) {
      'movie' => MediaKind.movie,
      'episode' => MediaKind.episode,
      _ => null,
    };
    if (kind == null) return null;
    return MediaItem.xtream(
      id: entry.id,
      kind: kind,
      title: entry.title,
      thumbPath: entry.thumbPath,
      libraryId: entry.libraryId,
      libraryTitle: entry.kind == 'movie' ? '$_name — Movies' : '$_name — Series',
      parentId: entry.parentId,
      parentTitle: entry.parentTitle,
      durationMs: entry.durationMs,
      viewOffsetMs: entry.positionMs,
      lastViewedAt: entry.updatedAtMs,
      serverId: connection.id,
      serverName: _name,
      isFavorite: isFavorite,
    );
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

  // Watch state is local-only for IPTV (no server API). markWatched
  // clears the local resume entry so the item leaves Continue Watching
  // (the base-class postcondition — the detail screen's "mark watched"
  // action reaches here through WatchActions, and a no-op would leave
  // the item in the row while claiming it was marked); rate stays a
  // no-op; setFavorite persists (Task 1) so the heart sticks.
  @override
  Future<void> markWatched(MediaItem item) async {
    await _removeResumeEntry(item.id);
  }

  @override
  Future<void> markUnwatched(MediaItem item) async {}

  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {
    await _removeResumeEntry(item.id);
  }

  @override
  Future<void> rate(MediaItem item, double rating) async {}

  /// Deletes the stored resume position for [id], if any. Shared by
  /// [markWatched] and [removeFromContinueWatching]: both mean "this
  /// item is no longer resumable".
  Future<void> _removeResumeEntry(String id) async {
    final current = Map<String, IptvResumeItem>.of(await _resumeItems());
    if (current.remove(id) == null) return;
    await _resumeRepository.write(_resumeKey, current);
    _resumeItemsFuture = Future.value(current);
  }

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
  }) async {
    await _recordResumePosition(itemId: itemId, position: position, duration: duration, isStop: false);
  }

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
  }) async {
    await _recordResumePosition(itemId: itemId, position: position, duration: duration, isStop: false);
  }

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
  }) async {
    await _recordResumePosition(itemId: itemId, position: position, duration: duration, isStop: true);
  }

  /// Build #25: the single record path for the three report methods.
  /// Local writes only — never a panel request, never throws (trap T7:
  /// a prefs failure drops the write silently instead of queuing a
  /// position for a server that doesn't exist).
  ///
  /// Rules, in order: (1) only `movie:` / `episode:` ids (live never
  /// enters the store, trap T5); (2) position below the 5 s floor
  /// records nothing (anti-clutter, trap T2); (3) no usable duration
  /// records nothing (a row without duration can never render
  /// `hasActiveProgress`, trap T1); (4) a stop at/above
  /// [watchedThreshold] (0.9) deletes the entry instead of writing it
  /// (trap T3/T4 — the stop report IS the watched-mark); (5) otherwise
  /// upsert with the reported duration and now as `lastViewedAt`.
  Future<void> _recordResumePosition({
    required String itemId,
    required Duration position,
    required Duration? duration,
    required bool isStop,
  }) async {
    try {
      final kind = itemId.startsWith('movie:')
          ? 'movie'
          : itemId.startsWith('episode:')
              ? 'episode'
              : null;
      if (kind == null) return;
      if (position.inMilliseconds < _resumeRecordFloorMs) return;
      final durationMs = duration?.inMilliseconds ?? 0;
      if (durationMs <= 0) return;
      final current = Map<String, IptvResumeItem>.of(await _resumeItems());
      if (isStop &&
          isWatchedProgress(
            positionMs: position.inMilliseconds,
            durationMs: durationMs,
            threshold: watchedThreshold,
          )) {
        if (current.remove(itemId) != null) {
          await _resumeRepository.write(_resumeKey, current);
          _resumeItemsFuture = Future.value(current);
        }
        return;
      }
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final updatedAtMs = nowMs > _lastResumeTimestampMs ? nowMs : _lastResumeTimestampMs + 1;
      _lastResumeTimestampMs = updatedAtMs;
      final stash = _resumeSnapshots[itemId];
      final parts = itemId.split(':');
      current[itemId] = IptvResumeItem(
        id: itemId,
        kind: kind,
        title: stash?.title,
        thumbPath: stash?.thumbPath,
        libraryId: stash?.libraryId ?? (kind == 'movie' ? _moviesLibraryId : _seriesLibraryId),
        parentId: stash?.parentId ?? (kind == 'episode' && parts.length >= 2 ? 'series:${parts[1]}' : null),
        parentTitle: stash?.parentTitle,
        positionMs: position.inMilliseconds,
        durationMs: durationMs,
        updatedAtMs: updatedAtMs,
      );
      if (current.length > _maxResumeEntries) {
        final sorted = current.values.toList()..sort((a, b) => a.updatedAtMs.compareTo(b.updatedAtMs));
        for (final oldest in sorted.take(current.length - _maxResumeEntries)) {
          current.remove(oldest.id);
        }
      }
      await _resumeRepository.write(_resumeKey, current);
      _resumeItemsFuture = Future.value(current);
    } catch (_) {
      // A prefs failure drops the write silently — playback must never
      // crash or queue on a local store failure.
    }
  }

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
    // Build #25: stash the playing item's display snapshot so the
    // report methods (which only receive an id) can store a titled row.
    // Movies and episodes only — live items never enter the resume
    // store. Bounded and in-memory; a restart loses nothing the catalog
    // re-resolution cannot refill.
    if (item is XtreamMediaItem && (item.kind == MediaKind.movie || item.kind == MediaKind.episode)) {
      _resumeSnapshots[item.id] = (
        title: item.title,
        thumbPath: item.thumbPath,
        libraryId: item.libraryId,
        parentId: item.parentId,
        parentTitle: item.parentTitle,
      );
      if (_resumeSnapshots.length > 50) {
        _resumeSnapshots.remove(_resumeSnapshots.keys.first);
      }
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
      // The fingerprint check needs to know whether this load was fresh
      // (a memo miss) — a memo hit is not a new playlist.
      final wasFresh = _liveStreamsFuture == null;
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
      if (wasFresh) {
        await _maybeRefreshEpgForPlaylistChange(
          Object.hashAll(streams.map((s) => Object.hash(s.streamId, s.name, s.epgChannelId))),
        );
      }
      return channels;
    }
    final wasFresh = _m3uEntriesFuture == null;
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
    if (wasFresh) {
      await _maybeRefreshEpgForPlaylistChange(
        Object.hashAll(entries.map((e) => Object.hash(e.tvgId, e.url, e.name))),
      );
    }
    return channels;
  }

  /// Update-on-playlist-change (§3.3, PlezTV 1.2.0): after a FRESH live
  /// list load, compare the channel-list fingerprint against the stored
  /// one. A stored fingerprint that differs means the provider changed
  /// the playlist (added/removed/reordered channels) — refresh the EPG
  /// so the new channels get guide data. The first load stores the
  /// fingerprint without refreshing. The fingerprint is over the RAW
  /// rows, before the hidden-category filter — hiding a group never
  /// triggers a refresh. Skipped entirely when Settings isn't ready
  /// (background warm-ups) or the setting is off; the new fingerprint
  /// is always stored.
  Future<void> _maybeRefreshEpgForPlaylistChange(int fingerprint) async {
    final store = IptvEpgSourcesStore(connection.id);
    final stored = await store.loadChannelFingerprint();
    final settings = SettingsService.instanceOrNull;
    if (stored != null &&
        stored != fingerprint &&
        settings != null &&
        settings.read(SettingsService.iptvEpgUpdateOnPlaylistChange)) {
      await _liveTv.refreshEpgCache();
    }
    await store.saveChannelFingerprint(fingerprint);
  }

  /// Re-fetch the live channel list from the provider (PlezTV 1.2.0,
  /// §3.2 — Reload TV details): Xtream re-fetches get_live_streams and
  /// rewrites the disk catalog; M3U drops its playlist cache and
  /// re-downloads. Movies and series are untouched — this is not a full
  /// catalog sync. Returns the fresh channel list and tells the library
  /// views the catalog changed. The channel-list fingerprint is stored
  /// with the fresh rows, so the next fresh load does not re-trigger an
  /// update-on-playlist-change refresh for a change already handled.
  Future<List<LiveTvChannel>> refreshLiveChannelsFromNetwork() async {
    if (_isXtream) {
      _liveStreamsFuture = null;
      _liveCategoriesFuture = null;
      _liveCategoryNamesFuture = null;
      _xtreamChannelByKey.clear();
      final rows = await _xtreamApi.getLiveStreams();
      _writeCatalogRows(
        IptvCatalogDiskCache.liveDataset,
        rows,
        (r) => r.toJson(),
        _xtreamApi.lastLiveStreamsBody,
      );
      _liveStreamsFuture = Future.value(rows);
      _liveStreamsLoaded = true;
      await IptvEpgSourcesStore(
        connection.id,
      ).saveChannelFingerprint(
        Object.hashAll(rows.map((r) => Object.hash(r.streamId, r.name, r.epgChannelId))),
      );
    } else {
      _m3uEntriesFuture = null;
      await _catalogCache.delete(connection.id, IptvCatalogDiskCache.m3uDataset);
    }
    final channels = await iptvChannels();
    notifyCatalogRefreshed(userInitiated: true);
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

  /// The letter-group initials that hid those matches (v1.1.0): the
  /// search screen names the hiding group instead of only counting.
  final hiddenInitials = <String>{};
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

  /// The section's index was cold for this search (build v1.0.11, R2.0):
  /// the type had no indexed rows, so a typing search answered [] without
  /// touching the panel and a submit kicked off the sync instead. The
  /// search screen reads the same state from the index-state notifier;
  /// this is the diagnostics record of it.
  bool cold = false;

  IptvSearchSectionDiagnostics get diagnostics => IptvSearchSectionDiagnostics(
    loadRows: loadRows,
    loadMs: loadMs,
    loadSource: loadSource,
    loadMatches: loadMatches,
    sweepMatches: sweepMatches,
    partialMatches: partialMatches,
    hiddenMatches: hiddenMatches,
    hiddenInitials: hiddenInitials.toList()..sort(),
    ms: ms,
    skipped: skipped,
    cold: cold,
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
    this.hiddenInitials = const [],
    required this.ms,
    required this.skipped,
    this.cold = false,
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

  /// The letter-group initials that hid those matches (v1.1.0) — the
  /// search screen's "matches are in the EN group, which you turned
  /// off" message reads this. Empty when nothing was hidden by a group
  /// (hidden by per-category id only).
  final List<String> hiddenInitials;

  /// Wall time of the whole section, in milliseconds.
  final int ms;

  /// True when the section was excluded (scoped search).
  final bool skipped;

  /// True when the section's index was cold for this search (build
  /// v1.0.11, R2.0): the type had no indexed rows.
  final bool cold;

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
