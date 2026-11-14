/// M3U / M3U8 playlist parser. Pure text in, entries out — no network.
///
/// Handles `#EXTINF` lines (`tvg-id`, `tvg-logo`, `group-title`,
/// `catchup-source`, plus any other `key="value"` attributes) followed by
/// the stream URL on the next non-comment line. `#EXTM3U` headers, `#EXTGRP`
/// lines and other comments are skipped. An entry without a following URL
/// line is dropped.
class M3uEntry {
  final String name;
  final String url;
  final String? tvgId;
  final String? tvgLogo;
  final String? groupTitle;
  final String? catchupSource;

  const M3uEntry({
    required this.name,
    required this.url,
    this.tvgId,
    this.tvgLogo,
    this.groupTitle,
    this.catchupSource,
  });
}

final _attrPattern = RegExp(r'''([\w-]+)=(?:"([^"]*)"|([^\s,]+))''');

Map<String, String> _parseAttributes(String extinfLine) {
  final attrs = <String, String>{};
  for (final match in _attrPattern.allMatches(extinfLine)) {
    final key = match.group(1);
    final value = match.group(2) ?? match.group(3);
    if (key != null && value != null) attrs[key] = value;
  }
  return attrs;
}

List<M3uEntry> parseM3u(String text) {
  final entries = <M3uEntry>[];
  final lines = text.split('\n');
  Map<String, String>? pendingAttrs;
  String? pendingName;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#EXTINF')) {
      pendingAttrs = _parseAttributes(line);
      // Display name follows the last comma on the EXTINF line.
      final comma = line.lastIndexOf(',');
      pendingName = comma >= 0 && comma < line.length - 1 ? line.substring(comma + 1).trim() : '';
      continue;
    }

    if (line.startsWith('#')) continue; // #EXTM3U, #EXTGRP, other comments

    // A bare URL line: pairs with the preceding EXTINF, or stands alone.
    final pending = pendingName;
    final name = (pending != null && pending.isNotEmpty) ? pending : line.split('/').last;
    entries.add(
      M3uEntry(
        name: name,
        url: line,
        // 1.2.8 F1 (same rule as Xtream epg_channel_id): an empty
        // tvg-id="" is absent, not an id.
        tvgId: switch (pendingAttrs?['tvg-id']) { final s? when s.isNotEmpty => s, _ => null },
        tvgLogo: pendingAttrs?['tvg-logo'],
        groupTitle: pendingAttrs?['group-title'],
        catchupSource: pendingAttrs?['catchup-source'],
      ),
    );
    pendingAttrs = null;
    pendingName = null;
  }

  return entries;
}
