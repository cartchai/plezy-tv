// Name-initial detection for the IPTV initials filter (build #8 Task 4).
//
// The provider's content carries short capital-letter initials at the start
// of names — "EN - Title", "ES | Channel", "UK|Channel", "NF - Alice" —
// and Matt wants to turn whole sets of them off, like the category
// groupings. There is deliberately NO language mapping and NO allow-list:
// every initial-set is toggleable, including provider tags like "NF".
// An initial only counts when it KEEPS REPEATING across many items (see
// [iptvInitialRepeatThreshold]) — a one-off prefix is never offered.

/// An initial only counts as a filterable set when it appears on at least
/// this many items (names + category names). Keeps the filter list short:
/// real groupings (EN, ES, NF, UK, …) repeat hundreds of times on this
/// provider, while one-off prefixes never reach it.
const int iptvInitialRepeatThreshold = 5;

/// One detected initial set: the initial exactly as it appears in the
/// content, and how many items carry it.
class IptvInitial {
  const IptvInitial(this.initial, this.count);

  /// The initial exactly as it appears (e.g. "EN", "NF") — never mapped to
  /// a language, never normalized beyond the detection itself.
  final String initial;

  /// How many scanned names carried this initial.
  final int count;
}

/// The initial at the start of [name], or null when the name carries none.
///
/// An initial is 2–3 capital letters followed by a separator (`-`, `|`,
/// `:`, `/`, with optional spaces around it): "EN - Title" → "EN",
/// "UK|Channel" → "UK", "ES: Show" → "ES". A bare space is NOT a
/// separator — "IT Crowd" is a title, not an initial, and must never be
/// offered as one. A name that is only an initial ("NF") carries none:
/// the initial lives in the items that carry the prefix.
String? detectInitial(String? name) {
  if (name == null) return null;
  final match = _initialPattern.firstMatch(name);
  return match?.group(1);
}

/// The initial a name carries: the prefix before a separator, or the whole
/// name when it IS just an initial (a category named "NF" — the provider's
/// category names are the initials themselves). Null otherwise.
String? initialOf(String? name) {
  final prefixed = detectInitial(name);
  if (prefixed != null) return prefixed;
  if (name == null) return null;
  final bare = name.trim();
  return _bareInitialPattern.hasMatch(bare) ? bare : null;
}

final RegExp _initialPattern = RegExp(r'^([A-Z]{2,3})\s*[-|:/]\s*');
final RegExp _bareInitialPattern = RegExp(r'^[A-Z]{2,3}$');

/// Counts of each initial across [names] (item names and category names).
Map<String, int> countInitials(Iterable<String?> names) {
  final counts = <String, int>{};
  for (final name in names) {
    final initial = initialOf(name);
    if (initial == null) continue;
    counts[initial] = (counts[initial] ?? 0) + 1;
  }
  return counts;
}

/// The initials that repeat often enough to offer as toggles, most-common
/// first (ties by initial, so the order is stable).
List<IptvInitial> initialsMeetingThreshold(
  Map<String, int> counts, {
  int threshold = iptvInitialRepeatThreshold,
}) {
  final found = [
    for (final entry in counts.entries)
      if (entry.value >= threshold) IptvInitial(entry.key, entry.value),
  ];
  found.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.initial.compareTo(b.initial);
  });
  return found;
}
