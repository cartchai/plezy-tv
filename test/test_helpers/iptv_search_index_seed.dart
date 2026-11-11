// Test-only helper: seed the local search index from a fake panel's
// fixture rows.
//
// R2.3 removed the panel-load fallback from search: a search answers
// from the local index (warm) or the local disk rows — never from the
// panel. Tests written before R2 that assert "search finds the fixture
// rows" therefore need the catalog already synced; this helper is that
// sync, in miniature: it reads the fake's unfiltered catalogs + category
// lists and writes them into the index with a fresh stamp, so the
// client's search finds them with zero panel requests.
//
// Each type is seeded independently and fail-open: a type whose fetch
// throws stays cold (exactly like a failed sync leg), so fail-open tests
// (one leg failing, the others answering) keep working.
//
// Callers must point the index at a temp dir first
// (`IptvSearchIndex.debugDirectoryProvider = () async => tempDir;` in
// setUp, cleared in tearDown) and call this in the test setup, before
// the search under test. If a test counts panel requests, call
// `resetCounts()` (or the fake's equivalent) after seeding — the seed
// reads are setup reads, not search reads.
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

/// Seed [connectionId]'s index rows for all three types from [api]'s
/// unfiltered catalogs. Fail-open per type; the index instance is closed
/// before returning (the client opens its own instance when it searches).
/// [types] selects which types to seed ('live' | 'movie' | 'series') —
/// a test whose fake never answers one type (a slow/cold fixture) seeds
/// only the others instead of hanging on it.
Future<void> seedIptvSearchIndexFromFakePanel(
  XtreamApi api,
  String connectionId, {
  Set<String> types = const {'live', 'movie', 'series'},
}) async {
  final index = await IptvSearchIndex.open();
  try {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    if (types.contains(IptvSearchIndex.typeLive)) {
      try {
        final categories = await api.getLiveCategories();
        final rows = await api.getLiveStreams();
        index.replaceType(
          connectionId: connectionId,
          type: IptvSearchIndex.typeLive,
          rows: rows.map(IptvSearchIndexRow.fromLive).toList(),
          categories: {for (final c in categories) c.id: c.name},
          syncStampMs: stamp,
        );
      } catch (_) {
        // Fail-open: the type stays cold, like a failed sync leg.
      }
    }
    if (types.contains(IptvSearchIndex.typeMovie)) {
      try {
        final categories = await api.getVodCategories();
        final rows = await api.getVodStreams();
        index.replaceType(
          connectionId: connectionId,
          type: IptvSearchIndex.typeMovie,
          rows: rows.map(IptvSearchIndexRow.fromMovie).toList(),
          categories: {for (final c in categories) c.id: c.name},
          syncStampMs: stamp,
        );
      } catch (_) {
        // Fail-open: the type stays cold, like a failed sync leg.
      }
    }
    if (types.contains(IptvSearchIndex.typeSeries)) {
      try {
        final categories = await api.getSeriesCategories();
        final rows = await api.getSeries();
        index.replaceType(
          connectionId: connectionId,
          type: IptvSearchIndex.typeSeries,
          rows: rows.map(IptvSearchIndexRow.fromSeries).toList(),
          categories: {for (final c in categories) c.id: c.name},
          syncStampMs: stamp,
        );
      } catch (_) {
        // Fail-open: the type stays cold, like a failed sync leg.
      }
    }
  } finally {
    index.close();
  }
}
