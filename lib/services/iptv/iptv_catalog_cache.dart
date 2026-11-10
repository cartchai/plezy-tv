import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../utils/app_logger.dart';

/// On-disk cache for the IPTV provider catalogs (build #11).
///
/// The catalogs are huge (55k live channels, 199k movies, 46k series) and
/// every cold start re-fetched all of them — minutes on LTE before
/// anything showed. The raw API payloads are now stored per connection
/// under the app documents directory (NOT the cache dir — the OS may wipe
/// that) and parsed on demand with the same isolate parsers the network
/// path uses, so there is exactly one parse shape. Filtering (disabled
/// categories / category initials) is applied at read time on the parsed
/// rows, never baked into storage.
///
/// File layout: `<documents>/iptv_catalog/<connectionId>/<dataset>.json`
/// (connection ids come from our own registry, but are still base64url
/// encoded — never trusted raw as a path segment). A file's modification
/// time IS its fetched time, so no metadata envelope is needed — and a
/// corrupted file reads as a miss, so it can never poison every later
/// load. Images/posters are deliberately NOT cached here (Matt: images
/// don't have to be cached); this is catalog data only.
///
/// Every method is total — a failed read returns null, a failed write is
/// logged and swallowed — so the disk cache can never break a load: the
/// caller falls back to the network. Writes are fire-and-forget from the
/// caller's side for the same reason (awaiting a tens-of-MB write would
/// gate the browse on file I/O).
class IptvCatalogDiskCache {
  const IptvCatalogDiskCache();

  /// Test seam: when set, the cache root comes from here instead of the
  /// app documents directory. Same pattern as the EPG cache's
  /// `debugEpgCacheDirectoryProvider`. Always null in production; tests
  /// must clear it in tearDown.
  static Future<Directory> Function()? debugDirectoryProvider;

  /// Test-only escape hatch for widget tests: when true, the cache is
  /// inert — reads return null and writes/deletes/clears are no-ops.
  /// Widget tests run in `testWidgets`' fake async zone, where the real
  /// dart:io behind the disk cache never completes on a plain pump — the
  /// same reason the favourites repository has an in-memory stand-in in
  /// the widget tests (see `_InMemoryItemFavoritesRepository` in
  /// `test/screens/iptv/iptv_screens_test.dart`). The disk behaviour
  /// itself is covered by the unit tests in
  /// `test/services/iptv/iptv_catalog_cache_test.dart`, which run with
  /// real async. Never set this in production code.
  static bool debugDisableDisk = false;

  /// How long a cached catalog counts as fresh. A fresh cache is served
  /// with no network at all; a stale one is still served immediately,
  /// and a background refresh lands the new rows. Tests shrink it.
  /// Build v1.0.10 (M3, one freshness rule): this TTL now gates only
  /// the M3U playlist refresh — the Xtream catalogs follow the sync
  /// interval instead.
  @visibleForTesting
  static Duration catalogCacheTtl = const Duration(hours: 24);

  /// True when [fetchedAt] is older than [catalogCacheTtl].
  static bool isStale(DateTime fetchedAt) => DateTime.now().difference(fetchedAt) > catalogCacheTtl;

  static const String liveDataset = 'live';
  static const String vodDataset = 'vod';
  static const String seriesDataset = 'series';
  static const String liveCategoriesDataset = 'live_categories';
  static const String vodCategoriesDataset = 'vod_categories';
  static const String seriesCategoriesDataset = 'series_categories';
  static const String m3uDataset = 'm3u';

  Future<Directory> _connectionDir(String connectionId) async {
    final base = await (debugDirectoryProvider ?? getApplicationDocumentsDirectory)();
    return Directory('${base.path}/iptv_catalog/${_fileSafe(connectionId)}');
  }

  static String _fileSafe(String value) => base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  Future<File> _file(String connectionId, String dataset) async {
    final dir = await _connectionDir(connectionId);
    return File('${dir.path}/$dataset.json');
  }

  /// The stored body and when it was fetched (the file's modification
  /// time), or null when there is no file or it cannot be read. This is
  /// opaque storage — the caller validates the body by parsing it (a
  /// corrupt payload reads as a miss there, and the file is deleted).
  Future<({String body, DateTime fetchedAt})?> read(String connectionId, String dataset) async {
    if (debugDisableDisk) return null;
    try {
      final file = await _file(connectionId, dataset);
      if (!await file.exists()) return null;
      final fetchedAt = (await file.stat()).modified;
      return (body: await file.readAsString(), fetchedAt: fetchedAt);
    } catch (e) {
      appLogger.w('IPTV catalog cache read failed for $dataset', error: e);
      return null;
    }
  }

  /// Store [body] for [dataset]. Creates the directory as needed.
  /// Never throws — a failed write is logged and the caller carries on
  /// with the in-memory rows.
  Future<void> write(String connectionId, String dataset, String body) async {
    if (debugDisableDisk) return;
    try {
      final file = await _file(connectionId, dataset);
      // Concurrent writes for different datasets race this create
      // (build #13): two recursive creates for the same new directory
      // can throw PathNotFoundException on the loser. A create that
      // fails only because the directory now exists is not an error.
      try {
        await file.parent.create(recursive: true);
      } on FileSystemException catch (_) {
        if (!await file.parent.exists()) rethrow;
      }
      await file.writeAsString(body);
    } catch (e) {
      appLogger.w('IPTV catalog cache write failed for $dataset', error: e);
    }
  }

  /// Delete one dataset file. Never throws.
  Future<void> delete(String connectionId, String dataset) async {
    if (debugDisableDisk) return;
    try {
      final file = await _file(connectionId, dataset);
      if (await file.exists()) await file.delete();
    } catch (e) {
      appLogger.w('IPTV catalog cache delete failed for $dataset', error: e);
    }
  }

  /// Delete every cached dataset for [connectionId]. Never throws.
  Future<void> clear(String connectionId) async {
    if (debugDisableDisk) return;
    try {
      final dir = await _connectionDir(connectionId);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      appLogger.w('IPTV catalog cache clear failed', error: e);
    }
  }

  /// Total bytes stored for [connectionId] (0 when nothing is cached).
  /// Never throws.
  Future<int> sizeBytes(String connectionId) async {
    if (debugDisableDisk) return 0;
    try {
      final dir = await _connectionDir(connectionId);
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
