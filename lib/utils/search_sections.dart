import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/search_hit.dart';

/// One section of grouped search results: one library's hits (or People).
class SearchResultSection {
  const SearchResultSection({required this.key, required this.label, required this.hits});

  /// Server-scoped library key, or 'people' for the people section.
  final String key;

  /// Header label: the library title (or the server/kind fallback the
  /// caller resolved).
  final String label;

  /// The section's hits, in ranked order.
  final List<SearchHit> hits;
}

/// Groups the ranked "All" search hits into sections by library (build #8
/// Task 2 — "add sections for search so I can easily skip through movies TV
/// or live or other libraries").
///
/// Sections are ordered Movies libraries, TV libraries, Live TV libraries,
/// then other libraries, with People last; sections of the same rank sort by
/// label so the order is stable across searches. Within a section the ranked
/// order is kept. A library's rank comes from its items' kinds (Live TV wins
/// over kind: an M3U channel is `MediaKind.unknown` in the `:live` library).
/// Items with no library fall back to a server+kind key so they still group
/// instead of each becoming their own section.
List<SearchResultSection> groupSearchResults(
  List<SearchHit> hits, {
  required String Function(MediaItem item) libraryLabel,
  String peopleLabel = 'People',
}) {
  final sections = <String, List<SearchHit>>{};
  final labels = <String, String>{};
  final ranks = <String, int>{};
  for (final hit in hits) {
    switch (hit) {
      case MediaSearchHit(:final item):
        final key = item.libraryGlobalKey ?? 'server:${item.serverId}:kind:${item.kind.id}';
        (sections[key] ??= []).add(hit);
        labels.putIfAbsent(key, () => libraryLabel(item));
        final rank = _rankForItem(item);
        final previous = ranks[key];
        if (previous == null || rank < previous) ranks[key] = rank;
      case PersonSearchHit():
        (sections['people'] ??= []).add(hit);
    }
  }
  final ordered = sections.entries.toList()
    ..sort((a, b) {
      final rank = _rankForKey(a.key, ranks).compareTo(_rankForKey(b.key, ranks));
      if (rank != 0) return rank;
      final labelA = a.key == 'people' ? peopleLabel : (labels[a.key] ?? a.key);
      final labelB = b.key == 'people' ? peopleLabel : (labels[b.key] ?? b.key);
      return labelA.compareTo(labelB);
    });
  return [
    for (final entry in ordered)
      SearchResultSection(
        key: entry.key,
        label: entry.key == 'people' ? peopleLabel : (labels[entry.key] ?? entry.key),
        hits: entry.value,
      ),
  ];
}

int _rankForKey(String key, Map<String, int> ranks) => key == 'people' ? 5 : (ranks[key] ?? 4);

int _rankForItem(MediaItem item) {
  // Live TV first: M3U channel items are kind unknown in the `:live` library.
  if (item.libraryId?.endsWith(':live') ?? false) return 2;
  return switch (item.kind) {
    MediaKind.movie => 0,
    MediaKind.show || MediaKind.season || MediaKind.episode => 1,
    MediaKind.artist || MediaKind.album || MediaKind.track => 3,
    _ => 4,
  };
}
