import 'dart:convert';

import '../base_shared_preferences_service.dart';

/// One IPTV movie / episode with a resume position, stored as a snapshot
/// so Continue Watching renders without fetching the provider's whole
/// catalog (199k movies). The client re-resolves the id against the
/// catalog when it can, so titles and posters stay fresh; the snapshot is
/// the fallback when the item left the catalog.
class IptvResumeItem {
  final String id;

  /// 'movie' | 'episode'. Series are never resume entries (a show is not
  /// playable); live channels never enter the store either.
  final String kind;
  final String? title;
  final String? thumbPath;
  final String? libraryId;
  final String? parentId;
  final String? parentTitle;

  /// Playback position in milliseconds, from the player's report.
  final int positionMs;

  /// Total duration in milliseconds, from the player's report. VOD
  /// catalog rows carry no duration, so the report is the only source
  /// for movies; without it the row can never render hasActiveProgress.
  final int durationMs;

  /// Last viewed at, milliseconds since epoch. Sort key for Continue
  /// Watching (newest first) and the eviction order.
  final int updatedAtMs;

  const IptvResumeItem({
    required this.id,
    required this.kind,
    this.title,
    this.thumbPath,
    this.libraryId,
    this.parentId,
    this.parentTitle,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAtMs,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    if (title != null) 'title': title,
    if (thumbPath != null) 'thumbPath': thumbPath,
    if (libraryId != null) 'libraryId': libraryId,
    if (parentId != null) 'parentId': parentId,
    if (parentTitle != null) 'parentTitle': parentTitle,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'updatedAtMs': updatedAtMs,
  };

  factory IptvResumeItem.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final kind = json['kind'];
    final positionMs = (json['positionMs'] as num?)?.toInt();
    final durationMs = (json['durationMs'] as num?)?.toInt();
    final updatedAtMs = (json['updatedAtMs'] as num?)?.toInt();
    if (id is! String || id.isEmpty) {
      throw const FormatException('Invalid resume item: missing id');
    }
    if (kind != 'movie' && kind != 'episode') {
      throw const FormatException('Invalid resume item: bad kind');
    }
    if (positionMs == null || positionMs < 0) {
      throw const FormatException('Invalid resume item: bad positionMs');
    }
    if (durationMs == null || durationMs <= 0) {
      throw const FormatException('Invalid resume item: bad durationMs');
    }
    if (updatedAtMs == null || updatedAtMs < 0) {
      throw const FormatException('Invalid resume item: bad updatedAtMs');
    }
    return IptvResumeItem(
      id: id,
      kind: kind,
      title: json['title'] as String?,
      thumbPath: json['thumbPath'] as String?,
      libraryId: json['libraryId'] as String?,
      parentId: json['parentId'] as String?,
      parentTitle: json['parentTitle'] as String?,
      positionMs: positionMs,
      durationMs: durationMs,
      updatedAtMs: updatedAtMs,
    );
  }
}

/// Persistence boundary for per-connection IPTV resume positions. Same
/// shape as the favourite-items repository: the repo owns the
/// serialisation; the call site owns the key naming
/// (`iptv_resume:<connectionId>`).
abstract class IptvResumeRepository {
  /// Reads the resume positions for [key]. A missing, empty or corrupt
  /// value reads as empty — a bad resume file never crashes the app.
  /// One malformed row is skipped, not fatal.
  Future<Map<String, IptvResumeItem>> read({required String key});

  /// Replaces the resume positions under [key].
  Future<void> write(String key, Map<String, IptvResumeItem> items);
}

/// Production implementation. Holds no state; reads and writes go through
/// the app-wide [BaseSharedPreferencesService.sharedCache] so resume
/// positions are covered by logout wipe, export and store salvage like
/// every other pref.
class SharedPreferencesIptvResumeRepository implements IptvResumeRepository {
  const SharedPreferencesIptvResumeRepository();

  @override
  Future<Map<String, IptvResumeItem>> read({required String key}) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final raw = readTolerantString(prefs, key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, IptvResumeItem>{};
      for (final entry in decoded.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        try {
          out[entry.key] = IptvResumeItem.fromJson(entry.value);
        } catch (_) {
          // One bad row does not invalidate the list.
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> write(String key, Map<String, IptvResumeItem> items) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(key, jsonEncode(items.map((k, v) => MapEntry(k, v.toJson()))));
  }
}
