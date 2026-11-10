import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../utils/app_logger.dart';
import '../../utils/json_utils.dart';
import '../../utils/search_relevance.dart';
import 'xtream_api.dart';

/// Local search index for IPTV catalogs (build #23 — local-only search).
///
/// The whole catalog (live channels, VOD movies, series) is synced to a
/// SQLite file on the phone once, and search queries that file instead of
/// the provider — zero panel requests during a search when the index is
/// warm (Matt: "what if it runs a download of all the details to keep
/// into a file it can check once a week and that way search is faster").
/// This is the TiviMate / IPTVMac shape: a local indexed store, searched
/// locally; the panel is only touched by the periodic sync.
///
/// Index shape (IPTVMac FTS5 + IPTVnator trigram, so substring matching
/// keeps working):
/// * `iptv_search_item` — one row per catalog entry, with the display
///   fields search needs to build a [MediaItem] without touching the
///   300k-row catalog in memory. `name_norm` is [normalizeSearchText] of
///   the provider name, so the FTS arm and the 0–1000 scorer agree.
/// * `iptv_search_fts` — a standalone FTS5 table (`tokenize='trigram'`)
///   over `name_norm`, carrying the key columns (`conn`, `type`, `id`)
///   so the connection/type filter applies INSIDE the FTS scan — the
///   filter must be on the FTS table, not on the joined item table: a
///   slim FTS table (name only, filter after the join) makes the
///   planner scan the whole index per query (11–190 s at Trex scale in
///   the CLI probe), while the fat table answers a rare needle in ~1 ms.
///   Joined back to the item table on rowid for the display fields.
///   Trigram keeps substring/prefix matching (IPTVnator: substring >= 3
///   chars); tokens shorter than 3 characters have no trigrams, so a
///   query with no token >= 3 chars falls back to a LIKE scan of the
///   item table (still local-only, zero panel requests).
/// * `iptv_search_category` — category id -> name per connection/type, so
///   the hidden-category filter and the category-prefix strip work from
///   the index alone (no panel round trip for category names).
/// * `iptv_search_meta` — per (connection, type) row count + last sync
///   time. A type is "warm" when it has rows; staleness never makes it
///   cold — a stale index still answers, and the sync refreshes it in
///   the background.
///
/// The index is derived/rebuildable cache data, so it lives in its own
/// file (`<documents>/iptv_search_index/iptv_search_index.db`) — NOT in
/// the main Drift [AppDatabase]. A corrupt index can never touch the
/// user's real data, and no v26 migration / build_runner regen is needed.
/// One file serves all IPTV connections (`connection_id` column); M3U
/// has no VOD/series catalog and its playlist search is already
/// local-only, so M3U rows are never indexed.
///
/// Writes (sync + disk seed) run in a background isolate via [compute]
/// — building a 300k-row trigram index takes seconds of CPU, and the
/// `sqlite3` API is synchronous. Reads (search, meta, categories) are
/// short FTS/LIKE queries on the main isolate (milliseconds). The
/// database runs in WAL mode so a background write does not block a
/// search read.
///
/// Every method is total — a failed open/read returns cold/empty and the
/// caller falls back to the old disk/sweep search paths, so a broken
/// index can never break search.
class IptvSearchIndex {
  IptvSearchIndex._(this._db, {required this.isMemory});

  /// Catalog types, matching [IptvCatalogDiskCache]'s datasets.
  static const String typeLive = 'live';
  static const String typeMovie = 'movie';
  static const String typeSeries = 'series';
  static const List<String> types = [typeLive, typeMovie, typeSeries];

  /// Hostile-response cap (build #23, IPTVMac SyncService shape): a
  /// catalog response larger than this is refused before parsing, so a
  /// bad sync can't blow up storage. Counted in UTF-16 code units
  /// (≈ bytes for JSON, which is mostly ASCII). Defined on [XtreamApi]
  /// (the response lives there); forwarded here for the index/sync.
  static const int maxCatalogResponseChars = XtreamApi.maxCatalogResponseChars;

  /// Candidate cap for an FTS query: the trigram index returns its best
  /// matches first, and the per-section limit is 100 — 5000 candidates
  /// leaves room for the hidden-category filter to remove rows without
  /// starving the result.
  static const int ftsCandidateLimit = 5000;

  /// Test seam (same pattern as [IptvCatalogDiskCache]): when set, the
  /// index file lives under here instead of the app documents directory.
  /// Always null in production; tests must clear it in tearDown.
  static Future<Directory> Function()? debugDirectoryProvider;

  /// Test-only escape hatch for widget tests: when true, the index is
  /// inert — reads report cold and writes are no-ops. Widget tests run
  /// in `testWidgets`' fake async zone, where the real dart:io behind
  /// the index never completes on a plain pump. The index behaviour
  /// itself is covered by the unit tests in
  /// `test/services/iptv/iptv_build23_local_search_test.dart`, which run
  /// with real async. Never set this in production code.
  static bool debugDisableDisk = false;

  final Database _db;

  /// True when this instance is in-memory (unit tests) — [fileSizeBytes]
  /// reports 0 and there is no file to clean up.
  final bool isMemory;

  bool _closed = false;

  /// Open (or create) the on-disk index. Creates the schema on first
  /// open. WAL mode so a background-isolate write does not block a
  /// search read on this connection.
  static Future<IptvSearchIndex> open() async {
    if (debugDisableDisk) return IptvSearchIndex.memory();
    final path = await dbFilePath();
    await Directory(path).parent.create(recursive: true);
    final db = sqlite3.open(path);
    final index = IptvSearchIndex._(db, isMemory: false);
    index._open();
    return index;
  }

  /// Absolute path of the index DB file (for the background-isolate
  /// writer, which opens its own connection to the same file). Honors
  /// [debugDirectoryProvider].
  static Future<String> dbFilePath() async {
    final base = await (debugDirectoryProvider ?? getApplicationDocumentsDirectory)();
    return '${base.path}/iptv_search_index/iptv_search_index.db';
  }

  /// In-memory index (unit tests): same schema, no file.
  static IptvSearchIndex memory() {
    final index = IptvSearchIndex._(sqlite3.openInMemory(), isMemory: true);
    index._open();
    return index;
  }

  void _open() {
    _db.execute('PRAGMA journal_mode=WAL;');
    _db.execute('PRAGMA busy_timeout = 30000;');
    createSchema(_db);
  }

  /// Create the schema on [db] (idempotent). Shared by [_open] and the
  /// background-isolate writer so the two paths cannot drift.
  static void createSchema(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS iptv_search_meta (
        connection_id TEXT NOT NULL,
        type TEXT NOT NULL,
        row_count INTEGER NOT NULL DEFAULT 0,
        last_sync_ms INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (connection_id, type)
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS iptv_search_item (
        connection_id TEXT NOT NULL,
        type TEXT NOT NULL,
        stream_id INTEGER NOT NULL,
        category_id TEXT,
        name TEXT NOT NULL,
        name_norm TEXT NOT NULL,
        thumb TEXT,
        rating REAL,
        container_ext TEXT,
        summary TEXT,
        epg_channel_id TEXT,
        has_archive INTEGER NOT NULL DEFAULT 0,
        archive_duration INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (connection_id, type, stream_id)
      );
    ''');
    db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS iptv_search_fts USING fts5(
        name_norm, conn, type, id, tokenize='trigram'
      );
    ''');
    db.execute('''
      CREATE TABLE IF NOT EXISTS iptv_search_category (
        connection_id TEXT NOT NULL,
        type TEXT NOT NULL,
        category_id TEXT NOT NULL,
        name TEXT NOT NULL,
        PRIMARY KEY (connection_id, type, category_id)
      );
    ''');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.close();
  }

  // -- Sync state -----------------------------------------------------------

  /// Row counts per type for [connectionId] (0 when the type was never
  /// synced). A type is warm when its count is > 0.
  Map<String, int> rowCounts(String connectionId) {
    if (_closed) return const {};
    final out = <String, int>{for (final t in types) t: 0};
    try {
      final rows = _db.select(
        'SELECT type, row_count FROM iptv_search_meta WHERE connection_id = ?',
        [connectionId],
      );
      for (final row in rows) {
        out[row['type'] as String] = row['row_count'] as int;
      }
    } catch (e) {
      appLogger.w('IPTV search index: row counts unreadable', error: e);
    }
    return out;
  }

  /// True when [type] has indexed rows for [connectionId].
  bool isWarm(String connectionId, String type) => (rowCounts(connectionId)[type] ?? 0) > 0;

  /// Last sync time per type for [connectionId] (null when never synced).
  Map<String, DateTime?> lastSync(String connectionId) {
    if (_closed) return const {};
    final out = <String, DateTime?>{for (final t in types) t: null};
    try {
      final rows = _db.select(
        'SELECT type, last_sync_ms FROM iptv_search_meta WHERE connection_id = ?',
        [connectionId],
      );
      for (final row in rows) {
        final ms = row['last_sync_ms'] as int;
        if (ms > 0) out[row['type'] as String] = DateTime.fromMillisecondsSinceEpoch(ms);
      }
    } catch (e) {
      appLogger.w('IPTV search index: last sync unreadable', error: e);
    }
    return out;
  }

  /// Category id -> name for [type] (from the index alone — no panel
  /// round trip). Empty when the type was never synced.
  Map<String, String> categoryNames(String connectionId, String type) {
    if (_closed) return const {};
    try {
      final rows = _db.select(
        'SELECT category_id, name FROM iptv_search_category WHERE connection_id = ? AND type = ?',
        [connectionId, type],
      );
      return {for (final row in rows) row['category_id'] as String: row['name'] as String};
    } catch (e) {
      appLogger.w('IPTV search index: category names unreadable', error: e);
      return const {};
    }
  }

  /// On-disk size of the index (DB + WAL + shared-memory files), for the
  /// Settings → IPTV cache-size display. 0 for an in-memory index.
  /// Total bytes of the on-disk index files (DB + WAL + shm), without
  /// opening the database — 0 when there is no index file yet. Used by
  /// the Settings → IPTV cache-size row so the row never creates an
  /// empty index just to measure it.
  static Future<int> totalFileSizeBytes() async {
    try {
      final base = await (debugDirectoryProvider ?? getApplicationDocumentsDirectory)();
      final dir = Directory('${base.path}/iptv_search_index');
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (e) {
      return 0;
    }
  }

  Future<int> fileSizeBytes() async {
    if (isMemory || _closed) return 0;
    try {
      return await totalFileSizeBytes();
    } catch (e) {
      appLogger.w('IPTV search index: size unreadable', error: e);
      return 0;
    }
  }

  // -- Search ---------------------------------------------------------------

  /// Build the FTS5 MATCH pattern for a normalized needle. Only tokens
  /// of 3+ characters can match in a trigram index; shorter tokens are
  /// dropped here (the caller's RegExp still applies the full needle).
  /// Returns '' when no token is long enough — the caller falls back to
  /// [searchLike]. Quoted terms, so FTS5 syntax characters in a title
  /// (`A&E`, `C++`, quotes) never throw.
  @visibleForTesting
  static String ftsPattern(String needleNorm) {
    final tokens = needleNorm.split(' ').where((t) => t.length >= 3);
    if (tokens.isEmpty) return '';
    return tokens.map((t) => '"${t.replaceAll('"', '""')}"').join(' ');
  }

  /// Candidate rows for [needle] (already lowercased by the caller, the
  /// same needle the warm path filters on). FTS arm when the needle has
  /// a token >= 3 chars (a superset of the caller's RegExp matches —
  /// normalization is monotone over substrings, so a row matching the
  /// full needle contains every normalized token); LIKE scan otherwise.
  /// Returns index rows in FTS rank order (or rowid order for the LIKE
  /// fallback); the caller applies its authoritative RegExp + hidden
  /// filters and the per-section limit.
  List<IptvSearchIndexRow> search(String connectionId, String type, String needle) {
    if (_closed) return const [];
    final needleNorm = normalizeSearchText(needle);
    final pattern = ftsPattern(needleNorm);
    try {
      if (pattern.isNotEmpty) {
        // The conn/type filter is on the FTS table itself (see the class
        // doc): filtering after the join makes the planner scan the whole
        // index per query at Trex scale.
        final rows = _db.select(
          'SELECT i.connection_id, i.type, i.stream_id, i.category_id, i.name, '
          'i.thumb, i.rating, i.container_ext, i.summary, i.epg_channel_id, '
          'i.has_archive, i.archive_duration '
          'FROM iptv_search_fts '
          'JOIN iptv_search_item i ON i.rowid = iptv_search_fts.rowid '
          'WHERE iptv_search_fts MATCH ? AND iptv_search_fts.conn = ? AND iptv_search_fts.type = ? '
          'LIMIT ?',
          [pattern, connectionId, type, ftsCandidateLimit],
        );
        return rows.map(IptvSearchIndexRow.fromDb).toList(growable: false);
      }
      // No trigram-matchable token (e.g. "of", "a&e"): LIKE scan of the
      // normalized name — still local-only. The LIKE is on the normalized
      // text (already lowercased), so SQLite's ASCII-only case folding
      // cannot miss a row the RegExp would catch.
      final like = '%${needleNorm.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      final rows = _db.select(
        'SELECT connection_id, type, stream_id, category_id, name, thumb, '
        'rating, container_ext, summary, epg_channel_id, has_archive, '
        'archive_duration FROM iptv_search_item '
        'WHERE connection_id = ? AND type = ? AND name_norm LIKE ? ESCAPE ?',
        [connectionId, type, like, r'\'],
      );
      return rows.map(IptvSearchIndexRow.fromDb).toList(growable: false);
    } catch (e) {
      appLogger.w('IPTV search index: search failed for $type', error: e);
      return const [];
    }
  }

  // -- Writes (called from the background-isolate writer; see below) ------

  /// Atomically replace one type's rows for [connectionId] — the sync's
  /// choke point (OpenTV `replaceCatalogue` shape): the old rows are
  /// deleted and the new ones inserted in ONE transaction, and the meta
  /// row (count + sync time) is updated in the same transaction, so a
  /// failed or interrupted sync can never leave a half-written index.
  /// Categories are replaced with the rows (same transaction).
  /// Called on the main isolate only by unit tests; production writes go
  /// through [writeIndexTypeInBackground].
  void replaceType({
    required String connectionId,
    required String type,
    required List<IptvSearchIndexRow> rows,
    required Map<String, String> categories,
    required int syncStampMs,
  }) {
    if (_closed) return;
    _db.execute('BEGIN IMMEDIATE;');
    try {
      _deleteTypeLocked(connectionId, type);
      _insertRowsLocked(connectionId, type, rows);
      _insertCategoriesLocked(connectionId, type, categories);
      _db.execute(
        'INSERT INTO iptv_search_meta (connection_id, type, row_count, last_sync_ms) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(connection_id, type) DO UPDATE SET row_count = excluded.row_count, last_sync_ms = excluded.last_sync_ms',
        [connectionId, type, rows.length, syncStampMs],
      );
      _db.execute('COMMIT;');
    } catch (e) {
      try {
        _db.execute('ROLLBACK;');
      } catch (_) {}
      rethrow;
    }
  }

  void _deleteTypeLocked(String connectionId, String type) {
    // The FTS rows are addressed by the item rowids they index: delete
    // them by the same join the search uses, then the items.
    _db.execute(
      'DELETE FROM iptv_search_fts WHERE rowid IN '
      '(SELECT rowid FROM iptv_search_item WHERE connection_id = ? AND type = ?)',
      [connectionId, type],
    );
    _db.execute(
      'DELETE FROM iptv_search_item WHERE connection_id = ? AND type = ?',
      [connectionId, type],
    );
    _db.execute(
      'DELETE FROM iptv_search_category WHERE connection_id = ? AND type = ?',
      [connectionId, type],
    );
  }

  void _insertRowsLocked(String connectionId, String type, List<IptvSearchIndexRow> rows) {
    final itemStmt = _db.prepare(
      'INSERT INTO iptv_search_item (connection_id, type, stream_id, category_id, name, name_norm, thumb, rating, container_ext, summary, epg_channel_id, has_archive, archive_duration) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
    );
    // The FTS row carries the key columns (conn/type/id) so the search
    // filter applies inside the FTS scan (see the class doc).
    final ftsStmt = _db.prepare('INSERT INTO iptv_search_fts (rowid, name_norm, conn, type, id) VALUES (?, ?, ?, ?, ?)');
    try {
      for (final row in rows) {
        itemStmt.execute([
          connectionId,
          type,
          row.streamId,
          row.categoryId,
          row.name,
          row.nameNorm,
          row.thumb,
          row.rating,
          row.containerExt,
          row.summary,
          row.epgChannelId,
          row.hasArchive ? 1 : 0,
          row.archiveDuration,
        ]);
        ftsStmt.execute([_db.lastInsertRowId, row.nameNorm, connectionId, type, row.streamId]);
      }
    } finally {
      itemStmt.close();
      ftsStmt.close();
    }
  }

  void _insertCategoriesLocked(String connectionId, String type, Map<String, String> categories) {
    final stmt = _db.prepare(
      'INSERT INTO iptv_search_category (connection_id, type, category_id, name) VALUES (?, ?, ?, ?)',
    );
    try {
      for (final entry in categories.entries) {
        stmt.execute([connectionId, type, entry.key, entry.value]);
      }
    } finally {
      stmt.close();
    }
  }

  /// Delete every indexed row for [connectionId] (connection removed, or
  /// "Refresh playlists" — the index is derived from the catalog, so a
  /// clear rebuilds it on the next sync). Never throws.
  Future<void> deleteConnection(String connectionId) async {
    if (_closed) return;
    try {
      _db.execute('BEGIN IMMEDIATE;');
      try {
        for (final type in types) {
          _deleteTypeLocked(connectionId, type);
        }
        _db.execute('DELETE FROM iptv_search_meta WHERE connection_id = ?', [connectionId]);
        _db.execute('COMMIT;');
      } catch (e) {
        try {
          _db.execute('ROLLBACK;');
        } catch (_) {}
        rethrow;
      }
    } catch (e) {
      appLogger.w('IPTV search index: delete connection failed', error: e);
    }
  }
}

/// Snapshot of the search index for one connection — the search
/// screen's catalog-health line ("Trex catalog: 55,205 channels ·
/// updated 2 days ago") and the settings cache-size row read this.
/// A type is warm when it has rows; a stale index still answers, so
/// staleness never makes it cold.
class IptvSearchIndexState {
  const IptvSearchIndexState({
    required this.rowCounts,
    required this.lastSync,
    this.syncing = false,
    this.seeding = false,
  });

  const IptvSearchIndexState.empty()
      : rowCounts = const {},
        lastSync = const {},
        syncing = false,
        seeding = false;

  /// Indexed rows per type ('live' | 'movie' | 'series').
  final Map<String, int> rowCounts;

  /// Last sync time per type (null when never synced).
  final Map<String, DateTime?> lastSync;

  /// A network sync is running right now.
  final bool syncing;

  /// A disk seed is running right now.
  final bool seeding;

  int get totalRows => rowCounts.values.fold(0, (a, b) => a + b);
  bool get isWarm => totalRows > 0;
  bool get isEmpty => totalRows == 0;
  bool get isBusy => syncing || seeding;
}

/// One indexed catalog row — the display fields search needs, plus the
/// normalized name the FTS index matches on. Built from the Xtream
/// models at sync/seed time; mapped back to them at search time so the
/// existing `_movieItem` / `_seriesItem` / `_liveChannelItem` builders
/// (category-prefix strip, library ids, stream URLs) are reused
/// unchanged.
class IptvSearchIndexRow {
  const IptvSearchIndexRow({
    required this.streamId,
    required this.categoryId,
    required this.name,
    required this.nameNorm,
    this.thumb,
    this.rating,
    this.containerExt,
    this.summary,
    this.epgChannelId,
    this.hasArchive = false,
    this.archiveDuration = 0,
  });

  factory IptvSearchIndexRow.fromLive(XtreamLiveStream stream) => IptvSearchIndexRow(
        streamId: stream.streamId,
        categoryId: stream.categoryId,
        name: stream.name,
        nameNorm: normalizeSearchText(stream.name),
        thumb: stream.streamIcon,
        epgChannelId: stream.epgChannelId,
        hasArchive: stream.tvArchive,
        archiveDuration: stream.tvArchiveDuration,
      );

  factory IptvSearchIndexRow.fromMovie(XtreamVodStream stream) => IptvSearchIndexRow(
        streamId: stream.streamId,
        categoryId: stream.categoryId,
        name: stream.name,
        nameNorm: normalizeSearchText(stream.name),
        thumb: stream.cover ?? stream.streamIcon,
        rating: stream.rating,
        containerExt: stream.containerExtension,
      );

  factory IptvSearchIndexRow.fromSeries(XtreamSeries series) => IptvSearchIndexRow(
        streamId: series.seriesId,
        categoryId: series.categoryId,
        name: series.name,
        nameNorm: normalizeSearchText(series.name),
        thumb: series.cover,
        rating: series.rating,
        summary: series.plot,
      );

  factory IptvSearchIndexRow.fromDb(Row row) {
    final name = row['name'] as String;
    return IptvSearchIndexRow(
      streamId: row['stream_id'] as int,
      categoryId: row['category_id'] as String?,
      name: name,
      nameNorm: normalizeSearchText(name),
      thumb: row['thumb'] as String?,
      rating: (row['rating'] as num?)?.toDouble(),
      containerExt: row['container_ext'] as String?,
      summary: row['summary'] as String?,
      epgChannelId: row['epg_channel_id'] as String?,
      hasArchive: (row['has_archive'] as int) == 1,
      archiveDuration: row['archive_duration'] as int,
    );
  }

  final int streamId;
  final String? categoryId;

  /// Provider name as spelled (display title; the category-prefix strip
  /// runs on this at item-build time, same as the warm path).
  final String name;

  /// [normalizeSearchText] of [name] — what the FTS index matches on.
  final String nameNorm;
  final String? thumb;
  final double? rating;
  final String? containerExt;
  final String? summary;
  final String? epgChannelId;
  final bool hasArchive;
  final int archiveDuration;

  XtreamLiveStream toLiveStream() => XtreamLiveStream(
        streamId: streamId,
        name: name,
        streamIcon: thumb,
        epgChannelId: epgChannelId,
        categoryId: categoryId,
        tvArchive: hasArchive,
        tvArchiveDuration: archiveDuration,
      );

  XtreamVodStream toVodStream() => XtreamVodStream(
        streamId: streamId,
        name: name,
        cover: thumb,
        rating: rating,
        categoryId: categoryId,
        containerExtension: containerExt ?? 'mp4',
      );

  XtreamSeries toSeries() => XtreamSeries(
        seriesId: streamId,
        name: name,
        cover: thumb,
        plot: summary,
        rating: rating,
        categoryId: categoryId,
      );
}

/// Parameters for the background-isolate index write — plain values only
/// (isolate messages are copied, so the raw bodies are the cheapest
/// thing to pass; the isolate re-parses them with the same shape as
/// [XtreamApi]'s isolate parsers).
class IndexWriteParams {
  const IndexWriteParams({
    required this.dbPath,
    required this.connectionId,
    required this.type,
    required this.catalogBody,
    required this.categoryBody,
    required this.syncStampMs,
  });

  final String dbPath;
  final String connectionId;
  final String type;
  final String catalogBody;
  final String categoryBody;
  final int syncStampMs;
}

/// Result of a background-isolate index write.
class IndexWriteResult {
  const IndexWriteResult({required this.rowCount, required this.ms, this.skippedReason});

  final int rowCount;
  final int ms;

  /// Non-null when nothing was written: 'no-categories' (the category
  /// list was empty, so the hidden filter and prefix strip would have
  /// nothing to work from) or 'partial' (the rows cover fewer than half
  /// the categories — a crawl-shaped / partial source, never a complete
  /// list). The caller keeps the old index rows in both cases.
  final String? skippedReason;
}

/// Background-isolate index write (build #23): parse one type's catalog
/// + category bodies and atomically replace that type's rows in the
/// index file. Top-level so [compute] can run it off the UI thread —
/// a 200k-row trigram build is seconds of synchronous SQLite work.
/// Returns the written row count. Throws on a corrupt body (the caller
/// keeps the old index rows — a failed sync never wipes good data).
Future<IndexWriteResult> writeIndexTypeInBackground(IndexWriteParams params) async {
  final started = DateTime.now();
  final db = sqlite3.open(params.dbPath);
  try {
    db.execute('PRAGMA journal_mode=WAL;');
    db.execute('PRAGMA busy_timeout = 30000;');
    // Same schema as [IptvSearchIndex._open] (the isolate opens its own
    // connection; CREATE IF NOT EXISTS is a no-op when the main
    // isolate already created it).
    IptvSearchIndex.createSchema(db);
    final rows = _rowsFromBody(params.type, params.catalogBody);
    final categories = <String, String>{
      for (final c in parseFlexibleJsonList(_decodeJson(params.categoryBody), XtreamCategory.fromJson))
        c.id: c.name,
    };
    // Completeness guard (the seed's P5a): a crawl-shaped / partial
    // source covers only a subset of the categories — indexing it would
    // make search MISS rows the panel has, with no heal to cover the
    // gap (the index is the authority when warm). Refuse the write and
    // keep the old index (or stay cold, so the fallback sweep still
    // heals). A complete list covers (nearly) every category; a few
    // legitimately empty categories are fine at the 50% threshold.
    if (categories.isEmpty) {
      return IndexWriteResult(rowCount: 0, ms: DateTime.now().difference(started).inMilliseconds, skippedReason: 'no-categories');
    }
    final covered = {for (final row in rows) row.categoryId}.intersection(categories.keys.toSet());
    if (covered.length / categories.length < 0.5) {
      return IndexWriteResult(rowCount: 0, ms: DateTime.now().difference(started).inMilliseconds, skippedReason: 'partial');
    }
    // Reuse the main-isolate writer through a short-lived instance so
    // the transaction shape cannot drift between the two paths.
    final index = IptvSearchIndex._(db, isMemory: false);
    index.replaceType(
      connectionId: params.connectionId,
      type: params.type,
      rows: rows,
      categories: categories,
      syncStampMs: params.syncStampMs,
    );
    return IndexWriteResult(rowCount: rows.length, ms: DateTime.now().difference(started).inMilliseconds);
  } finally {
    db.close();
  }
}

List<IptvSearchIndexRow> _rowsFromBody(String type, String body) {
  final decoded = _decodeJson(body);
  return switch (type) {
    IptvSearchIndex.typeLive => parseFlexibleJsonList(decoded, XtreamLiveStream.fromJson)
        .map(IptvSearchIndexRow.fromLive)
        .toList(growable: false),
    IptvSearchIndex.typeMovie => parseFlexibleJsonList(decoded, XtreamVodStream.fromJson)
        .map(IptvSearchIndexRow.fromMovie)
        .toList(growable: false),
    _ => parseFlexibleJsonList(decoded, XtreamSeries.fromJson).map(IptvSearchIndexRow.fromSeries).toList(growable: false),
  };
}

dynamic _decodeJson(String body) {
  try {
    return jsonDecode(body);
  } on FormatException {
    return const <dynamic>[];
  }
}

/// Per-type progress of a catalog sync, for the "refreshing Trex details"
/// popup: which type is being fetched/written, and how many rows each
/// finished type landed (0 when it was skipped — see
/// [IptvSearchSyncResult.skipped]).
class IptvSearchSyncProgress {
  const IptvSearchSyncProgress({required this.type, required this.phase, this.rows = 0, this.reason});

  /// 'live' | 'movie' | 'series'.
  final String type;

  /// 'fetching' | 'writing' | 'done' | 'skipped'.
  final String phase;
  final int rows;

  /// Skip reason when [phase] == 'skipped': 'up-to-date' | 'empty-response'
  /// | 'partial' | 'oversize' | 'failed'.
  final String? reason;
}

/// Outcome of one [IptvClient.syncSearchIndex] run, per type.
class IptvSearchSyncResult {
  const IptvSearchSyncResult({required this.rows, required this.skipped});

  /// Rows written per type (0 when the type was skipped).
  final Map<String, int> rows;

  /// Skip reason per type that did not sync (see [IptvSearchSyncProgress.reason]).
  final Map<String, String> skipped;

  int get totalRows => rows.values.fold(0, (a, b) => a + b);
}
