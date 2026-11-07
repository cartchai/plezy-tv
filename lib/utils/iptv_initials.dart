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
/// The initial is found by scanning the category's pipe-separated
/// segments (build #13): the region is often buried after a content-type
/// prefix — "MOVIES | EN | Action", "SERIES | FR | Drama", "LIVE TV |
/// AR | News" — so only reading a leading prefix missed it entirely.
/// The LAST matching segment wins, so "TV | EN" yields EN, not TV.
/// Matching is case-insensitive ("en | …" counts) and bracketed
/// segments ("[EN] …") count; the result is canonical uppercase.
///
/// Per segment, in order:
/// - a bracketed initial: "[EN] …" → "EN";
/// - a segment that IS an initial: "EN", "NF" → itself;
/// - a leading 2–4 letter token + separator: "EN - Movies", "AR |
///   Channels", "ASIA: Shows" → "EN", "AR", "ASIA" (a bare space is NOT
///   a separator — "UK Series" carries no initial);
/// - a short tag token before the first space: "24/7 ACTION …" → "24/7".
///
/// A plain category name ("Action", "IT Crowd") carries no initial.
/// Those categories are ungrouped: always shown, toggled individually
/// via the existing per-category switches.
/// The initial a category belongs to. The derivation is a pure function
/// of the name, so results are memoized (build #13): the search and
/// browse filter 199k rows through this function, and re-running the
/// splits + regexes per row froze the UI for ~600ms. The cache is
/// bounded by the number of distinct category names (833 on Matt's
/// provider) and never invalidated — the derivation depends on no
/// mutable state.
final Map<String, String?> _categoryInitialCache = {};

String? categoryInitial(String? categoryName) {
  if (categoryName == null) return null;
  if (_categoryInitialCache.containsKey(categoryName)) return _categoryInitialCache[categoryName];
  final derived = _deriveCategoryInitial(categoryName);
  _categoryInitialCache[categoryName] = derived;
  return derived;
}

String? _deriveCategoryInitial(String? categoryName) {
  if (categoryName == null) return null;
  final s = categoryName.trim();
  if (s.isEmpty) return null;
  String? found;
  for (final rawSegment in s.split('|')) {
    final segment = rawSegment.trim();
    if (segment.isEmpty) continue;
    // Bracketed initial: "[EN] Movies" or a "[FR]" segment.
    final bracketed = _bracketedInitialPattern.firstMatch(segment);
    if (bracketed != null && _isCodeCase(bracketed.group(1)!)) {
      found = bracketed.group(1)!.toUpperCase();
      continue;
    }
    // A segment that IS just an initial: "EN", "NF", "en". Title Case
    // words ("News", "Kids") are content, not codes — they must not
    // override an earlier region ("LIVE TV | AR | News" is AR).
    final bare = _bareInitialPattern.firstMatch(segment);
    if (bare != null && _isCodeCase(bare.group(1)!)) {
      found = bare.group(1)!.toUpperCase();
      continue;
    }
    // 2–4 letters + separator: "EN - Movies", "AR | Channels",
    // "ASIA: Shows". Case-insensitive; canonical uppercase out. Same
    // code-case rule: a Title Case prefix ("En - …") is a word.
    final prefixed = _categoryInitialPattern.firstMatch(segment);
    if (prefixed != null && _isCodeCase(prefixed.group(1)!)) {
      found = prefixed.group(1)!.toUpperCase();
      continue;
    }
    // Leading token before the first space, when it is a short tag
    // rather than a word: "24/7 ACTION ..." -> "24/7".
    final token = segment.split(RegExp(r'\s+')).first;
    if (token.length <= 4 && RegExp(r'[0-9/]').hasMatch(token)) {
      found = token.toUpperCase();
    }
  }
  return found;
}

/// True when [token] looks like a code, not a word: all capitals ("EN",
/// "FR") or all lowercase ("en", "fr"). Title Case ("News", "En") is a
/// word and never an initial.
bool _isCodeCase(String token) => token == token.toUpperCase() || token == token.toLowerCase();

final RegExp _bracketedInitialPattern = RegExp(r'^\[([A-Za-z]{2,4})\]');
final RegExp _categoryInitialPattern = RegExp(r'^([A-Za-z]{2,4})\s*[-:/]', caseSensitive: false);
final RegExp _bareInitialPattern = RegExp(r'^([A-Za-z]{2,4})$');

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
