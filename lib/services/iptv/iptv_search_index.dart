import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../utils/app_logger.dart';
import '../../utils/iptv_initials.dart';
import '../../utils/json_utils.dart';
import '../../utils/search_relevance.dart';
import 'xtream_api.dart';

/// Whole-token quality markers stripped from titles at index time
/// (R2.2) — see [stripTitleDecorations].
const _qualityTokens = {'4k', 'fhd', 'hd', 'uhd', '2160p', '1080p', '720p', 'hevc', 'x265', 'x264'};

/// Strip the provider's title decorations before normalizing for the
/// index (R2.2) — the display `name` stays raw. A decorated title
/// ("EN - Game Of Thrones (2011)") normalizes to the same bare form as
/// the plain title ("Game of Thrones"), so BM25 + the caller scorer
/// stop ranking the real title 252nd of 252 behind shorter
/// near-matches. Strips, in order: a leading 2-letter language prefix
/// ("EN - "), a trailing " (YYYY)", and whole-token quality markers
/// (case-insensitive). If stripping leaves nothing, the original title
/// is kept. Case is preserved — [normalizeSearchText] lowercases after.
/// Note: the prefix regex also strips a genuine title starting like
/// "Go - …" — the real catalog's coverage beyond the `^[A-Za-z]{2} - `
/// + year + quality-token rules is UNVERIFIED; do not invent more
/// strip rules without data.
String stripTitleDecorations(String title) {
  var stripped = title.replaceFirst(RegExp(r'^[A-Za-z]{2} - '), '');
  stripped = stripped.replaceFirst(RegExp(r' \(\d{4}\)$'), '');
  final tokens = stripped.split(' ').where((t) => !_qualityTokens.contains(t.toLowerCase())).toList();
  final joined = tokens.join(' ');
  return joined.trim().isEmpty ? title : joined;
}

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

  /// Query cap for [search] (build v1.0.10): the FTS arm returns its
  /// best-ranked rows and the LIKE arm its first rows, both capped here
  /// in SQL — a short needle can never materialize the whole table, and
  /// the caller only ever keeps its per-section limit (100 by default).
  /// 200 = 2x that limit, headroom for the caller's RegExp + hidden-
  /// category filtering to remove rows without starving the result.
  /// (Build #23's 5000 was the same headroom idea without rank order;
  /// without ORDER BY rank the cap kept the first 100 *inserted* rows,
  /// which could cut the exact match — M2.)
  static const int ftsQueryLimit = 200;

  /// Rank window for [search] (build v1.0.10): the FTS arm re-runs
  /// ranked only when the match set fits in this many rows. Ranking
  /// means scoring every match (measured: ~420 ms for 200k matches),
  /// and past ~1000 near-identical rows the rank order is noise — the
  /// caller still scores the 200 it gets. The probe fetches one row
  /// past the window (1001) so the overflow case is detected without
  /// counting the whole set (a count of 200k matches costs ~260 ms;
  /// the probe stops after 1001 rows).
  static const int ftsRankWindow = 1000;

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

  /// Index schema version. v2 (R2.2): `name_norm` is the STRIPPED title
  /// ([stripTitleDecorations]), not the raw one.
  static const int _schemaVersion = 2;

  void _open() {
    _db.execute('PRAGMA journal_mode=WAL;');
    _db.execute('PRAGMA busy_timeout = 30000;');
    // One-time re-index on the v1 -> v2 upgrade: the old rows' norms are
    // the raw titles, so drop the four tables and rebuild from the disk
    // catalogs (local, 0 panel requests) — the seed path rebuilds it on
    // the next bind, and the sync refreshes it when due.
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version < _schemaVersion) {
      _db.execute('DROP TABLE IF EXISTS iptv_search_item;');
      _db.execute('DROP TABLE IF EXISTS iptv_search_fts;');
      _db.execute('DROP TABLE IF EXISTS iptv_search_category;');
      _db.execute('DROP TABLE IF EXISTS iptv_search_meta;');
      _db.execute('PRAGMA user_version = $_schemaVersion;');
    }
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

  /// Whether any row for [type] could match [needle] — a cheap `EXISTS`
  /// + LIKE gate over the same normalized tokens the FTS arm uses, so a
  /// no-match section answers in ~10 ms instead of paying a ~280 ms
  /// trigram posting-list walk over the whole table (R2.1: the 443 ms
  /// search was a no-match FTS walk, not the scorer). The gate must
  /// never change the result SET — it only skips work that cannot return
  /// rows. Returns true when the needle has no token >= 3 chars (the
  /// LIKE arm decides those), and fails open (true) if the query itself
  /// errors, so a broken gate degrades to the ungated search.
  bool hasMatch(String connectionId, String type, String needle) {
    if (_closed) return false;
    final tokens = normalizeSearchText(needle).split(' ').where((t) => t.length >= 3).toList();
    if (tokens.isEmpty) return true;
    final where = List.generate(tokens.length, (_) => 'name_norm LIKE ? ESCAPE ?').join(' AND ');
    final args = <Object?>[connectionId, type];
    for (final token in tokens) {
      args.add('%${_escapeLike(token)}%');
      args.add(r'\');
    }
    try {
      // The (connection_id, type) PK prefix narrows the scan to this
      // type's rows; the LIKEs then run over name_norm only.
      final result = _db.select(
        'SELECT EXISTS(SELECT 1 FROM iptv_search_item WHERE connection_id = ? AND type = ? AND $where)',
        args,
      );
      return (result.first.values.first as int) == 1;
    } catch (e) {
      appLogger.w('IPTV search index: hasMatch failed for $type', error: e);
      return true;
    }
  }

  /// Escape the LIKE wildcards in [value] (backslash first, so the
  /// escape itself is not ambiguous).
  static String _escapeLike(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
  /// same needle the warm path filters on). FTS arm when the needle has
  /// a token >= 3 chars (a superset of the caller's RegExp matches —
  /// normalization is monotone over substrings, so a row matching the
  /// full needle contains every normalized token); LIKE scan otherwise.
  /// Returns index rows in FTS rank order (or rowid order for the LIKE
  /// fallback); the caller applies its authoritative RegExp + hidden
  /// filters and the per-section limit. At most [limit] rows are
  /// returned (build v1.0.10: the cap lives in SQL, so a needle with
  /// thousands of matches materializes at most [limit] rows).
  ///
  /// Rank window (build v1.0.10): the FTS arm first probes up to
  /// [ftsRankWindow] + 1 rows in natural order. A set that fits in the
  /// window is re-run ranked (the sort is cheap there, and it is what
  /// keeps the exact match from being cut by the cap); a set that
  /// overflows the window returns its first [limit] probe rows
  /// unranked — ranking 200k near-identical rows costs ~420 ms and
  /// the order is noise among them, while the caller still scores the
  /// 200 it gets. See the M2 group note in
  /// iptv_build29_freshness_test for the BM25 length-bias limit of
  /// the rank guarantee.
  List<IptvSearchIndexRow> search(String connectionId, String type, String needle, {int limit = ftsQueryLimit}) {
    if (_closed) return const [];
    final needleNorm = normalizeSearchText(needle);
    final pattern = ftsPattern(needleNorm);
    try {
      if (pattern.isNotEmpty) {
        // No-match gate (R2.1): a section whose type holds no row for
        // the needle skips the FTS walk entirely. The gate uses the
        // same tokens as the FTS pattern, so it can never change the
        // result set — only skip work that returns nothing.
        if (!hasMatch(connectionId, type, needle)) return const [];
        // Starts-with arm (R2.2): exact-prefix matches first, so a
        // decorated title stripped to its bare form survives the cap
        // and reaches the caller scorer ahead of near-matches. One
        // LIKE over the type's rows (~0.1 ms); no ORDER BY — the scan
        // visits rows in (connection, type, stream_id) order and stops
        // after LIMIT 20, while ORDER BY rowid would force a sort of
        // every match first (200k rows for a common needle).
        final startsWith = _db
            .select(
              'SELECT connection_id, type, stream_id, category_id, name, name_norm, thumb, rating, container_ext, summary, epg_channel_id, has_archive, archive_duration '
              'FROM iptv_search_item '
              'WHERE connection_id = ? AND type = ? AND name_norm LIKE ? ESCAPE ? '
              'LIMIT 20',
              [connectionId, type, '${_escapeLike(needleNorm)}%', r'\'],
            )
            .map(IptvSearchIndexRow.fromDb)
            .toList(growable: false);
        // The conn/type filter is on the FTS table itself (see the class
        // doc): filtering after the join makes the planner scan the whole
        // index per query at Trex scale.
        const columns =
            'i.connection_id, i.type, i.stream_id, i.category_id, i.name, i.name_norm, '
            'i.thumb, i.rating, i.container_ext, i.summary, i.epg_channel_id, '
            'i.has_archive, i.archive_duration ';
        // Probe: natural order, one row past the rank window. A LIMIT
        // with no ORDER BY stops after that many rows — it never scans
        // the whole match set.
        final probe = _db.select(
          'SELECT $columns'
          'FROM iptv_search_fts '
          'JOIN iptv_search_item i ON i.rowid = iptv_search_fts.rowid '
          'WHERE iptv_search_fts MATCH ? AND iptv_search_fts.conn = ? AND iptv_search_fts.type = ? '
          'LIMIT ?',
          [pattern, connectionId, type, ftsRankWindow + 1],
        );
        final List<IptvSearchIndexRow> ftsRows;
        if (probe.length <= limit) {
          // The whole match set fits: return it; the caller re-scores.
          ftsRows = probe.map(IptvSearchIndexRow.fromDb).toList(growable: false);
        } else if (probe.length <= ftsRankWindow) {
          // Moderate set: re-run ranked — the sort is cheap here, and
          // rank order is what keeps the exact match in the cap.
          final rows = _db.select(
            'SELECT $columns'
            'FROM iptv_search_fts '
            'JOIN iptv_search_item i ON i.rowid = iptv_search_fts.rowid '
            'WHERE iptv_search_fts MATCH ? AND iptv_search_fts.conn = ? AND iptv_search_fts.type = ? '
            'ORDER BY iptv_search_fts.rank '
            'LIMIT ?',
            [pattern, connectionId, type, limit],
          );
          ftsRows = rows.map(IptvSearchIndexRow.fromDb).toList(growable: false);
        } else {
          // Huge set: return the first [limit] probe rows unranked.
          ftsRows = probe.take(limit).map(IptvSearchIndexRow.fromDb).toList(growable: false);
        }
        if (startsWith.isEmpty) return ftsRows;
        final seen = {for (final row in startsWith) row.streamId};
        final merged = [...startsWith, ...ftsRows.where((row) => !seen.contains(row.streamId))];
        return merged.take(limit).toList(growable: false);
      }
      // No trigram-matchable token (e.g. "of", "a&e"): LIKE scan of the
      // normalized name — still local-only. The LIKE is on the normalized
      // text (already lowercased), so SQLite's ASCII-only case folding
      // cannot miss a row the RegExp would catch. Bounded like the FTS
      // arm (build v1.0.10): without a LIMIT a 2-letter needle
      // materialized tens of thousands of rows across the 300k-row table.
      final like = '%${_escapeLike(needleNorm)}%';
      final rows = _db.select(
        'SELECT connection_id, type, stream_id, category_id, name, name_norm, thumb, '
        'rating, container_ext, summary, epg_channel_id, has_archive, '
        'archive_duration FROM iptv_search_item '
        'WHERE connection_id = ? AND type = ? AND name_norm LIKE ? ESCAPE ? '
        'ORDER BY rowid '
        'LIMIT ?',
        [connectionId, type, like, r'\', limit],
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

  /// Merge one type's rows into the index (series fix, v1.0.16): rows the
  /// incoming list contains are upserted (the old row for the same
  /// stream id is deleted and the new one inserted, so title/category
  /// updates land); rows it does NOT contain are KEPT, so a partial
  /// land's rows survive a later full sync and a full sync's rows
  /// survive a later partial one. Categories merge the same way.
  ///
  /// 1.2.4 (catalog memory): [deleteCategoryIds] removes rows in hidden
  /// categories in the same transaction — without it the merge would
  /// keep rows cached before their category was hidden, and the prune
  /// would never shrink the index. A refused warm partial still purges
  /// nothing (that path never reaches here).
  ///
  /// Meta semantics — the two numbers mean different things on purpose:
  /// * [IptvSearchIndexState.rowCounts] for the type is the VISIBLE rows
  ///   in the latest fetch (1.2.4: the index holds visible rows only —
  ///   hidden rows are pruned at write time), while the FTS table may
  ///   hold MORE rows merged in from earlier partial lands. The probe's
  ///   P1c pins this: after a partial land (5 rows) and a full sync
  ///   (46,527 rows) the meta reads 46,527 AND the partial rows are
  ///   searchable.
  /// * [IptvSearchIndexState.lastSync] is stamped ONLY by a complete
  ///   sync ([syncStampMs] != null). A partial land leaves it untouched
  ///   (0 on a fresh row, which reads back as null — `last_sync_ms` is
  ///   NOT NULL, so the meta write splits into two statements rather
  ///   than passing a null stamp) — lastSync == null (or rows == 0) is
  ///   what marks a type due for refetch, so the next bind/manual sync
  ///   retries it. A complete sync after a partial land stamps normally.
  ///   1.2.4: a complete land with every category hidden stamps 0 rows —
  ///   that is a deliberate empty land, not a cold type; the due checks
  ///   must not treat a stamped 0 as cold (see [IptvClient]).
  /// The cache-line count is the meta count, so a partial land shows
  /// its real row count (e.g. 5 series rows) instead of the misleading 0.
  void upsertType({
    required String connectionId,
    required String type,
    required List<IptvSearchIndexRow> rows,
    required Map<String, String> categories,
    required int? syncStampMs,
    List<String> deleteCategoryIds = const [],
  }) {
    if (_closed) return;
    _db.execute('BEGIN IMMEDIATE;');
    try {
      _upsertRowsLocked(connectionId, type, rows);
      _deleteRowsInCategoriesLocked(connectionId, type, deleteCategoryIds);
      _upsertCategoriesLocked(connectionId, type, categories);
      // A null stamp means "not synced": last_sync_ms is NOT NULL, so a
      // partial land stores 0 on a fresh row (which [lastSync] reads
      // back as null) and leaves the column untouched on conflict — it
      // must never clear a stamp a complete sync set.
      if (syncStampMs != null) {
        _db.execute(
          'INSERT INTO iptv_search_meta (connection_id, type, row_count, last_sync_ms) '
          'VALUES (?, ?, ?, ?) '
          'ON CONFLICT(connection_id, type) DO UPDATE SET row_count = excluded.row_count, last_sync_ms = excluded.last_sync_ms',
          [connectionId, type, rows.length, syncStampMs],
        );
      } else {
        _db.execute(
          'INSERT INTO iptv_search_meta (connection_id, type, row_count, last_sync_ms) '
          'VALUES (?, ?, ?, 0) '
          'ON CONFLICT(connection_id, type) DO UPDATE SET row_count = excluded.row_count',
          [connectionId, type, rows.length],
        );
      }
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

  /// Delete rows in [categoryIds] for one type (1.2.4 prune): the
  /// upsert-merge keeps rows the fetch did not return, so a category
  /// hidden after its rows landed would otherwise linger in search
  /// forever. FTS rows go by rowid join, same pattern as the type
  /// delete. Rows with a null category id are never matched — the
  /// filter can only hide a row by its category id or initial, so a
  /// null-category row is never hidden and must stay.
  void _deleteRowsInCategoriesLocked(
    String connectionId,
    String type,
    List<String> categoryIds,
  ) {
    if (categoryIds.isEmpty) return;
    final placeholders = List.filled(categoryIds.length, '?').join(',');
    _db.execute(
      'DELETE FROM iptv_search_fts WHERE rowid IN '
      '(SELECT rowid FROM iptv_search_item WHERE connection_id = ? AND type = ? AND category_id IN ($placeholders))',
      [connectionId, type, ...categoryIds],
    );
    _db.execute(
      'DELETE FROM iptv_search_item WHERE connection_id = ? AND type = ? AND category_id IN ($placeholders)',
      [connectionId, type, ...categoryIds],
    );
  }

  /// A single row by id (1.2.4, catalog memory): the id-resolution
  /// fallback for a favourite/resume whose row left the visible memos.
  /// The index still holds it until a sync prunes it; after a pruning
  /// sync it returns null and the caller falls back to the snapshot.
  IptvSearchIndexRow? resolveById(String connectionId, String type, int streamId) {
    if (_closed) return null;
    try {
      final found = _db.select(
        'SELECT * FROM iptv_search_item WHERE connection_id = ? AND type = ? AND stream_id = ? LIMIT 1',
        [connectionId, type, streamId],
      );
      if (found.isEmpty) return null;
      return IptvSearchIndexRow.fromDb(found.first);
    } catch (e) {
      appLogger.w('IPTV search index: resolve failed', error: e);
      return null;
    }
  }

  /// Rows in [type] that are visible under the CURRENT hidden sets
  /// (1.2.4): the partial guard's denominator. The stored row count is
  /// the visible land from the LAST sync — when the hidden set grew
  /// since, it counts rows that are hidden now, so comparing the fresh
  /// visible fetch against it would cry partial on a complete fetch
  /// (and the type would stay due and re-sync on every bind). Counting
  /// only currently-visible rows keeps the guard apples-to-apples: a
  /// fetch is partial when it returns fewer than half the rows the
  /// index holds for categories that are visible right now. A row with
  /// a null category id is never hidden, so it always counts.
  int visibleRowCount(
    String connectionId,
    String type,
    Set<String> hiddenIds,
    Set<String> hiddenInitials,
  ) {
    if (_closed) return 0;
    try {
      final names = categoryNames(connectionId, type);
      final hiddenCats = <String>{
        ...hiddenIds,
        for (final entry in names.entries)
          if (hiddenInitials.contains(categoryInitial(entry.value))) entry.key,
      };
      if (hiddenCats.isEmpty) {
        final found = _db.select(
          'SELECT COUNT(*) AS n FROM iptv_search_item WHERE connection_id = ? AND type = ?',
          [connectionId, type],
        );
        return (found.first['n'] as int?) ?? 0;
      }
      final placeholders = List.filled(hiddenCats.length, '?').join(',');
      final found = _db.select(
        'SELECT COUNT(*) AS n FROM iptv_search_item WHERE connection_id = ? AND type = ? '
        'AND (category_id IS NULL OR category_id NOT IN ($placeholders))',
        [connectionId, type, ...hiddenCats],
      );
      return (found.first['n'] as int?) ?? 0;
    } catch (e) {
      appLogger.w('IPTV search index: visible row count failed', error: e);
      return 0;
    }
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

  /// Delete-then-insert for exactly the incoming stream ids (upsert
  /// shape): the FTS row is addressed by the item rowid, so replacing
  /// the item row means its FTS row must go with it — the same join
  /// [_deleteTypeLocked] uses, scoped to the incoming ids. Rows the
  /// list does not contain are untouched. Chunked: one DELETE per 500
  /// ids — a single IN (...) with all ids exceeds SQLite's bound
  /// variable limit at Trex scale (46,527 series rows in one sync
  /// throws "too many SQL variables" and fails the whole write).
  void _upsertRowsLocked(String connectionId, String type, List<IptvSearchIndexRow> rows) {
    const batchSize = 500;
    for (var start = 0; start < rows.length; start += batchSize) {
      final end = (start + batchSize).clamp(0, rows.length);
      final batch = rows.sublist(start, end);
      final placeholders = List.filled(batch.length, '?').join(', ');
      _db.execute(
        'DELETE FROM iptv_search_fts WHERE rowid IN '
        '(SELECT rowid FROM iptv_search_item WHERE connection_id = ? AND type = ? AND stream_id IN ($placeholders))',
        [connectionId, type, ...batch.map((r) => r.streamId)],
      );
      _db.execute(
        'DELETE FROM iptv_search_item WHERE connection_id = ? AND type = ? AND stream_id IN ($placeholders)',
        [connectionId, type, ...batch.map((r) => r.streamId)],
      );
    }
    _insertRowsLocked(connectionId, type, rows);
  }

  void _upsertCategoriesLocked(String connectionId, String type, Map<String, String> categories) {
    final stmt = _db.prepare(
      'INSERT INTO iptv_search_category (connection_id, type, category_id, name) VALUES (?, ?, ?, ?) '
      'ON CONFLICT(connection_id, type, category_id) DO UPDATE SET name = excluded.name',
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
        nameNorm: normalizeSearchText(stripTitleDecorations(stream.name)),
        thumb: stream.streamIcon,
        epgChannelId: stream.epgChannelId,
        hasArchive: stream.tvArchive,
        archiveDuration: stream.tvArchiveDuration,
      );

  factory IptvSearchIndexRow.fromMovie(XtreamVodStream stream) => IptvSearchIndexRow(
        streamId: stream.streamId,
        categoryId: stream.categoryId,
        name: stream.name,
        nameNorm: normalizeSearchText(stripTitleDecorations(stream.name)),
        thumb: stream.cover ?? stream.streamIcon,
        rating: stream.rating,
        containerExt: stream.containerExtension,
      );

  factory IptvSearchIndexRow.fromSeries(XtreamSeries series) => IptvSearchIndexRow(
        streamId: series.seriesId,
        categoryId: series.categoryId,
        name: series.name,
        nameNorm: normalizeSearchText(stripTitleDecorations(series.name)),
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
      // The stored norm is the STRIPPED title (R2.2) — re-deriving it
      // from the raw name here would lose the strip. Fall back to the
      // derivation only when the column is absent (old SELECTs).
      nameNorm: (row['name_norm'] as String?) ?? normalizeSearchText(name),
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
    this.hiddenCategoryIds = const [],
    this.hiddenCategoryInitials = const [],
    this.catalogFilePath,
    this.categoryFilePath,
  });

  final String dbPath;
  final String connectionId;
  final String type;
  final String catalogBody;
  final String categoryBody;
  final int syncStampMs;

  /// Disk-file path variant (1.2.6, catalog memory, item 4): when set,
  /// the isolate reads the file itself instead of receiving the whole
  /// body across the port — the body copy that drove the bind peak is
  /// gone. The seed path sets these; the network sync keeps passing
  /// bodies, and [catalogBody]/[categoryBody] are then ignored (pass
  /// ''). Plain values only, so the params stay isolate-safe.
  final String? catalogFilePath;
  final String? categoryFilePath;

  /// Categories turned off by the user (1.2.4 prune — supersedes the
  /// v1.1.0 Option B "disk stays full" split, FORK §45): per-category
  /// ids and letter-group initials, exactly as stored on the
  /// connection. Rows from these categories are PRUNED at write time —
  /// skipped from the upsert and deleted from the index when a later
  /// sync finds them — so the index holds visible rows only, and
  /// [IndexWriteResult.hiddenSkipped] counts the rows pruned. Un-hiding
  /// a category needs a re-sync to bring its rows back; the categories
  /// screen says so with a Refresh action, so the un-hide never fails
  /// silently the way the v1.0.16 skip did.
  final List<String> hiddenCategoryIds;
  final List<String> hiddenCategoryInitials;
}

/// Result of a background-isolate index write.
class IndexWriteResult {
  const IndexWriteResult({
    required this.rowCount,
    required this.ms,
    this.skippedReason,
    this.partial = false,
    this.droppedRows = 0,
    this.coveredCategories = 0,
    this.totalCategories = 0,
    this.hiddenSkipped = 0,
  });

  final int rowCount;
  final int ms;

  /// Non-null when nothing was written: 'no-categories' (the category
  /// list was empty, so the hidden filter and prefix strip would have
  /// nothing to work from) or 'partial-kept' (the rows cover fewer than
  /// half the categories — a crawl-shaped / partial source, never a
  /// complete list — and the index already has rows for the type, so
  /// the old rows are kept). The caller keeps the old index rows in
  /// both cases. 'empty-response' when the catalog body parsed to zero
  /// rows.
  final String? skippedReason;

  /// True when rows WERE written but the fetched list was partial (it
  /// covered fewer than half the categories) — a cold-type land only
  /// (series fix, v1.0.16). The caller must NOT treat this as a failure:
  /// the type is searchable now, and it stays due for refetch (a partial
  /// land leaves last_sync_ms untouched — see [upsertType]).
  final bool partial;

  /// Rows the panel returned that failed to parse (dropped by
  /// [parseFlexibleJsonListCounted]) — the diagnostic that separates a
  /// panel-truncated list (C1: dropped == 0) from a parse-dropped one
  /// (C3: dropped > 0) on the next failure.
  final int droppedRows;

  /// Categories the fetched rows covered, out of the fetched category
  /// list — the guard's numbers, for the same diagnostic. These count
  /// ALL categories: hidden categories are included in both numbers —
  /// the guard runs on the fetched rows, before the visible-only filter.
  final int coveredCategories;
  final int totalCategories;

  /// Rows in hidden categories (1.2.4): counted AND pruned — skipped
  /// from the upsert and deleted from the index when a later sync finds
  /// them, so the index holds visible rows only. Reported separately
  /// from [droppedRows] so the C1-vs-C3 diagnosis is not polluted by
  /// rows the user asked to exclude.
  final int hiddenSkipped;
}

/// True when the category with [categoryId] and display [categoryName]
/// is hidden — by its own switch ([hiddenIds]) or because its category
/// initial is turned off ([hiddenInitials]). The same rule as
/// `IptvClient._isHiddenCategory`, shared so the background isolate
/// (which cannot call the client) resolves it identically. A category
/// with no initial is only hidden by its own switch.
bool isHiddenIptvCategory(String? categoryId, String? categoryName, Set<String> hiddenIds, Set<String> hiddenInitials) {
  if (categoryId != null && hiddenIds.contains(categoryId)) return true;
  final initial = categoryInitial(categoryName);
  return initial != null && hiddenInitials.contains(initial);
}

/// Background-isolate index write (build #23): parse one type's catalog
/// + category bodies and write that type's rows into the index file.
/// Top-level so [compute] can run it off the UI thread — a 200k-row
/// trigram build is seconds of synchronous SQLite work. Returns the
/// written row count. Throws on a corrupt body (the caller keeps the old
/// index rows — a failed sync never wipes good data).
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
    // Decode once: the typed rows feed the index, the decoded list
    // feeds the filtered body the caller writes to disk — one parse
    // serves both stores.
    // 1.2.6 (catalog memory, item 4): when the caller passed file
    // paths, the isolate reads the files itself — the main isolate
    // never held the bodies and `compute` copied only paths. The
    // network sync keeps passing bodies.
    final catalogBody = params.catalogFilePath != null
        ? await File(params.catalogFilePath!).readAsString()
        : params.catalogBody;
    final categoryBody = params.categoryFilePath != null
        ? await File(params.categoryFilePath!).readAsString()
        : params.categoryBody;
    final decoded = _decodeJson(catalogBody);
    final parsed = _rowsFromDecoded(params.type, decoded);
    final rows = parsed.rows;
    final categories = <String, String>{
      for (final c in parseFlexibleJsonList(_decodeJson(categoryBody), XtreamCategory.fromJson))
        c.id: c.name,
    };
    final hiddenIds = params.hiddenCategoryIds.toSet();
    final hiddenInitials = params.hiddenCategoryInitials.toSet();
    // 1.2.4 (catalog memory, Matt's prune decision — supersedes the
    // v1.1.0 Option B "disk stays full" split, FORK §45): the index
    // holds VISIBLE rows only. Hidden rows are skipped at write time,
    // and rows already in the index from before their category was
    // hidden are deleted after the upsert (the merge keeps rows the
    // fetch did not return, so a skip alone would leave them lingering
    // in search forever). The wire still downloads the full lists.
    // Un-hiding a category needs a re-sync to bring its rows back; the
    // categories screen shows a notice with a Refresh action when that
    // is the case, so the un-hide never fails silently the way the
    // v1.0.16 skip did. `rowCount` is the visible rows landed now.
    var hiddenSkipped = 0;
    final visibleRows = <IptvSearchIndexRow>[];
    for (final row in rows) {
      if (isHiddenIptvCategory(
        row.categoryId,
        row.categoryId == null ? null : categories[row.categoryId],
        hiddenIds,
        hiddenInitials,
      )) {
        hiddenSkipped++;
      } else {
        visibleRows.add(row);
      }
    }
    // Category ids hidden by id or by initial, for the post-upsert
    // delete of rows cached before their category was hidden.
    final hiddenCategoryIds = <String>{
      ...hiddenIds,
      for (final entry in categories.entries)
        if (hiddenInitials.contains(categoryInitial(entry.value))) entry.key,
    };
    // Categories the fetched rows cover, out of the whole category
    // list — the guard's denominator counts ALL categories now (the
    // v1.0.16 visible-only denominator is gone with the skip): hiding
    // most categories no longer changes what counts as complete.
    final covered = {for (final row in rows) row.categoryId}.intersection(categories.keys.toSet());
    int ms() => DateTime.now().difference(started).inMilliseconds;
    if (rows.isEmpty) {
      return IndexWriteResult(
        rowCount: 0,
        ms: ms(),
        skippedReason: 'empty-response',
        droppedRows: parsed.dropped,
      );
    }
    // Completeness guard (the seed's P5a): a crawl-shaped / partial
    // source covers only a subset of the categories — indexing it would
    // make search MISS rows the panel has, with no heal to cover the
    // gap (the index is the authority when warm). A complete list covers
    // (nearly) every category; a few legitimately empty categories are
    // fine at the 50% threshold.
    if (categories.isEmpty) {
      return IndexWriteResult(
        rowCount: 0,
        ms: ms(),
        skippedReason: 'no-categories',
        droppedRows: parsed.dropped,
      );
    }
    final isPartial = categories.isNotEmpty && covered.length / categories.length < 0.5;
    final index = IptvSearchIndex._(db, isMemory: false);
    if (isPartial) {
      // COLD-TYPE EXCEPTION (series fix, v1.0.16): when the index has 0
      // rows for the type, refusing the whole write makes the gap
      // permanent — every later sync fetches the same partial list and
      // refuses it again, so search stays empty forever (Matt's phone:
      // series index 0 rows while live/movies land on the same run).
      // Land what the panel returned instead, and leave last_sync_ms
      // untouched so the type stays due and the next sync refetches it.
      // A WARM index keeps refusing: a partial list must never shrink
      // good rows (P5a protection — the upsert below never deletes, but
      // the refuse keeps the warm path's all-or-nothing shape). The
      // refuse is 'partial-kept' (v1.0.16 dialog fix): the old rows are
      // kept and searchable, so the dialog must not call it a failure.
      final existing = _metaRowCount(db, params.connectionId, params.type);
      if (existing > 0) {
        return IndexWriteResult(
          rowCount: 0,
          ms: ms(),
          skippedReason: 'partial-kept',
          droppedRows: parsed.dropped,
          coveredCategories: covered.length,
          totalCategories: categories.length,
          hiddenSkipped: hiddenSkipped,
        );
      }
      index.upsertType(
        connectionId: params.connectionId,
        type: params.type,
        rows: visibleRows,
        categories: categories,
        syncStampMs: null, // Partial land: no stamp, stays due for refetch.
        deleteCategoryIds: hiddenCategoryIds.toList(),
      );
      return IndexWriteResult(
        rowCount: visibleRows.length,
        ms: ms(),
        partial: true,
        droppedRows: parsed.dropped,
        coveredCategories: covered.length,
        totalCategories: categories.length,
        hiddenSkipped: hiddenSkipped,
      );
    }
    // Complete list: upsert-merge (series fix, v1.0.16) — rows the fetch
    // did not return are KEPT, so a partial land's rows survive a later
    // full sync. See [upsertType] for the meta semantics. 1.2.4: the
    // merge keeps visible rows; rows in hidden categories are deleted
    // by the same write (see `deleteCategoryIds`), so a category hidden
    // after its rows landed does not linger in search. Un-hiding needs
    // a re-sync; the categories screen says so with a Refresh action.
    index.upsertType(
      connectionId: params.connectionId,
      type: params.type,
      rows: visibleRows,
      categories: categories,
      syncStampMs: params.syncStampMs,
      deleteCategoryIds: hiddenCategoryIds.toList(),
    );
    return IndexWriteResult(
      rowCount: visibleRows.length,
      ms: ms(),
      droppedRows: parsed.dropped,
      coveredCategories: covered.length,
      totalCategories: categories.length,
      hiddenSkipped: hiddenSkipped,
    );
  } finally {
    db.close();
  }
}

/// Meta row_count for one type (0 when never synced). Read inside the
/// isolate so the cold/warm decision sees the same rows the write will
/// touch — the main isolate's cached counts can lag a just-finished
/// background write.
int _metaRowCount(Database db, String connectionId, String type) {
  try {
    final found = db.select(
      'SELECT row_count FROM iptv_search_meta WHERE connection_id = ? AND type = ?',
      [connectionId, type],
    );
    if (found.isEmpty) return 0;
    return found.first['row_count'] as int;
  } catch (_) {
    // A meta read can only fail on a corrupt DB, in which case the write
    // below fails too and the caller keeps the old rows — treat as cold.
    return 0;
  }
}

({List<IptvSearchIndexRow> rows, int dropped}) _rowsFromDecoded(String type, dynamic decoded) {
  switch (type) {
    case IptvSearchIndex.typeLive:
      final parsed = parseFlexibleJsonListCounted(decoded, XtreamLiveStream.fromJson);
      return (
        rows: parsed.rows.map(IptvSearchIndexRow.fromLive).toList(growable: false),
        dropped: parsed.dropped,
      );
    case IptvSearchIndex.typeMovie:
      final parsed = parseFlexibleJsonListCounted(decoded, XtreamVodStream.fromJson);
      return (
        rows: parsed.rows.map(IptvSearchIndexRow.fromMovie).toList(growable: false),
        dropped: parsed.dropped,
      );
    default:
      final parsed = parseFlexibleJsonListCounted(decoded, XtreamSeries.fromJson);
      return (
        rows: parsed.rows.map(IptvSearchIndexRow.fromSeries).toList(growable: false),
        dropped: parsed.dropped,
      );
  }
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
  const IptvSearchSyncProgress({required this.type, required this.phase, this.rows = 0, this.reason, this.partial = false});

  /// 'live' | 'movie' | 'series'.
  final String type;

  /// 'fetching' | 'writing' | 'done' | 'skipped'.
  final String phase;
  final int rows;

  /// Skip reason when [phase] == 'skipped': 'up-to-date' | 'empty-response'
  /// | 'partial-kept' | 'oversize' | 'failed' | 'cold'. 'partial-kept'
  /// means the panel returned a partial list for a warm type and the old
  /// rows were kept — searchable, not a failure (v1.0.16 dialog fix).
  final String? reason;

  /// True when [phase] == 'done' but the landed list was partial (it
  /// covered fewer than half the categories) — a cold-type land that
  /// stays due for refetch (series fix, v1.0.16). The dialog shows the
  /// count with a partial marker instead of a plain count.
  final bool partial;
}

/// Outcome of one [IptvClient.syncSearchIndex] run, per type.
class IptvSearchSyncResult {
  const IptvSearchSyncResult({
    required this.rows,
    required this.skipped,
    this.transportFailedTypes = const {},
    this.playbackAborted = false,
    this.requests = 0,
    this.partialTypes = const {},
  });

  /// Rows written per type (0 when the type was skipped).
  final Map<String, int> rows;

  /// Skip reason per type that did not sync (see [IptvSearchSyncProgress.reason]).
  final Map<String, String> skipped;

  /// Types whose fetch failed on the TRANSPORT (connectionError /
  /// connectionTimeout / receiveTimeout). A 4xx, an oversize body, an
  /// empty response or a partial response is a 'failed'/'oversize'/
  /// 'empty-response'/'partial-kept' skip but NOT a transport failure — the
  /// distinction decides whether a background run is worth retrying
  /// (build v1.0.13, R4, D9): a transport failure retries, a refusal
  /// never does.
  final Set<String> transportFailedTypes;

  /// True when the run bailed because a stream started playing mid-run
  /// (build v1.0.13, R4, D4). The partial result stands; the caller maps
  /// this to a retry instead of a success.
  final bool playbackAborted;

  /// Panel requests this run attempted (build v1.0.13, R4): one per
  /// category-list fetch and one per catalog fetch that started. Exact
  /// for the background path (which never retries); a forced sync's
  /// transport retry (R2.4) re-fetches without incrementing, so it reads
  /// as a lower bound there. Only the background record consumes it.
  final int requests;

  /// Types that landed a partial list (cold-type land, series fix,
  /// v1.0.16): the rows are searchable now, but the type stays due and
  /// the next sync refetches it. Not a failure — the dialog shows the
  /// count with a partial marker, and the background record counts it
  /// as synced (a partial land still beats no rows at all).
  final Set<String> partialTypes;

  int get totalRows => rows.values.fold(0, (a, b) => a + b);

  /// True when any type failed to sync (v1.0.16 dialog fix): the manual
  /// refresh footer reads "Catalog sync failed" only on this. A skipped
  /// type is a failure EXCEPT 'up-to-date' (nothing to do) and
  /// 'partial-kept' (the panel returned a partial list for a warm type
  /// and the old rows were kept — searchable, not a failure). A type
  /// that landed a partial list is in [rows]/[partialTypes], never in
  /// [skipped], so it never reads as a failure either.
  bool get hasFailure => skipped.values.any((reason) => reason != 'up-to-date' && reason != 'partial-kept');
}
