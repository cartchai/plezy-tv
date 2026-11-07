// Category-initial detection for the IPTV filter (build #8 Task 4,
// redesigned build #10).
//
// The provider's CATEGORIES carry short grouping prefixes at the start of
// their names — "|EN| UK SERIES", "24/7 ACTION & ADVENTURE VIP", "AR …" —
// and Matt wants to turn whole sets of them off, like the category
// groupings, so he can turn off entire regions. There is deliberately NO
// language mapping and NO allow-list: every initial-set is toggleable,
// including provider tags like "NF".
//
// Build #10 redesign: the initial comes from the CATEGORY name, not from
// item names. The build #8 name-based filter hid nearly every ITEM (Matt
// hid 161 of 171 initials, which emptied every series category and broke
// series search) while the categories themselves stayed listed — the wrong
// layer. Now toggling an initial hides every category carrying it, and
// everything in those categories; item names are never filtered.
//
// An initial only counts when it is shared by at least [iptvInitialRepeatThreshold]
// categories — a one-off prefix is never offered.

/// An initial only counts as a filterable set when it appears on at least
/// this many categories. Keeps the filter list short: real groupings (EN,
/// UK, 24/7, …) repeat across many categories on this provider, while
/// one-off prefixes never reach it.
const int iptvInitialRepeatThreshold = 5;

/// One detected initial set: the initial exactly as it appears in the
/// category names, and how many categories carry it.
class IptvInitial {
  const IptvInitial(this.initial, this.count);

  /// The initial exactly as it appears (e.g. "EN", "24/7") — never mapped
  /// to a language, never normalized beyond the detection itself.
  final String initial;

  /// How many categories carried this initial.
  final int count;
}

/// The initial a CATEGORY name carries, or null when it carries none.
///
/// The initial is the category's leading prefix token:
/// - "|EN| UK SERIES" → "EN" (the pipe-first form is stripped first);
/// - "EN - Movies", "AR | Channels", "ASIA: Shows" → "EN", "AR", "ASIA"
///   (2–4 capital letters followed by a separator `-`, `|`, `:`, `/`);
/// - a category that IS just an initial ("NF") → "NF";
/// - "24/7 ACTION & ADVENTURE VIP" → "24/7" (a short leading token
///   before the first space, when it is a tag rather than a word).
///
/// A bare space is NOT a separator — "UK Series" carries no initial, and
/// neither does a plain category name ("Action", "IT Crowd"). Those
/// categories are ungrouped: always shown, toggled individually via the
/// existing per-category switches.
String? categoryInitial(String? categoryName) {
  if (categoryName == null) return null;
  var s = categoryName.trim();
  if (s.isEmpty) return null;
  // Strip the pipe-first form: "|EN| UK SERIES" -> "EN| UK SERIES".
  s = s.replaceFirst(RegExp(r'^\|+\s*'), '');
  if (s.isEmpty) return null;
  // 2–4 capital letters + separator: "EN| ...", "AR - ...", "ASIA: ...".
  final prefixed = _categoryInitialPattern.firstMatch(s);
  if (prefixed != null) return prefixed.group(1);
  // A name that IS just an initial: a category called "NF".
  if (_bareInitialPattern.hasMatch(s)) return s;
  // Leading token before the first space, when it is a short tag rather
  // than a word: "24/7 ACTION ..." -> "24/7".
  final token = s.split(RegExp(r'\s+')).first;
  if (token.length <= 4 && RegExp(r'[0-9/]').hasMatch(token)) return token;
  return null;
}

final RegExp _categoryInitialPattern = RegExp(r'^([A-Z]{2,4})\s*[-|:/]');
final RegExp _bareInitialPattern = RegExp(r'^[A-Z]{2,4}$');

/// Counts of each initial across [categoryNames].
Map<String, int> countCategoryInitials(Iterable<String?> categoryNames) {
  final counts = <String, int>{};
  for (final name in categoryNames) {
    final initial = categoryInitial(name);
    if (initial == null) continue;
    counts[initial] = (counts[initial] ?? 0) + 1;
  }
  return counts;
}

/// The initials that repeat often enough to offer as toggles, most-common
/// first (ties by initial, so the order is stable). The checklist re-sorts
/// them alphabetically for display (build #10).
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
