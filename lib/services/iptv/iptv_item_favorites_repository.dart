import 'dart:convert';

import '../base_shared_preferences_service.dart';

/// One favourited IPTV movie / series / episode, stored as a snapshot so
/// the favourites list renders without fetching the provider's whole
/// catalog (199k movies). The client re-resolves the id against the
/// catalog when it can, so titles and posters stay fresh; the snapshot is
/// the fallback when the item left the catalog.
class IptvFavoriteItem {
  final String id;

  /// 'movie' | 'show' | 'episode'.
  final String kind;
  final String? title;
  final String? thumbPath;
  final String? libraryId;
  final String? parentId;
  final String? parentTitle;

  const IptvFavoriteItem({
    required this.id,
    required this.kind,
    this.title,
    this.thumbPath,
    this.libraryId,
    this.parentId,
    this.parentTitle,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    if (title != null) 'title': title,
    if (thumbPath != null) 'thumbPath': thumbPath,
    if (libraryId != null) 'libraryId': libraryId,
    if (parentId != null) 'parentId': parentId,
    if (parentTitle != null) 'parentTitle': parentTitle,
  };

  factory IptvFavoriteItem.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final kind = json['kind'];
    if (id is! String || id.isEmpty || kind is! String || kind.isEmpty) {
      throw const FormatException('Invalid favorite item');
    }
    return IptvFavoriteItem(
      id: id,
      kind: kind,
      title: json['title'] as String?,
      thumbPath: json['thumbPath'] as String?,
      libraryId: json['libraryId'] as String?,
      parentId: json['parentId'] as String?,
      parentTitle: json['parentTitle'] as String?,
    );
  }
}

/// Persistence boundary for per-connection favourited IPTV movies, series
/// and episodes. Same shape as the favourite-channels repository: the repo
/// owns the serialisation; the call site owns the key naming
/// (`iptv_fav_items:<connectionId>`).
abstract class IptvItemFavoritesRepository {
  /// Reads the favourited items for [key]. A missing, empty or corrupt
  /// value reads as empty — a bad favourites file never crashes the app.
  /// One malformed row is skipped, not fatal.
  Future<Map<String, IptvFavoriteItem>> read({required String key});

  /// Replaces the favourited items under [key].
  Future<void> write(String key, Map<String, IptvFavoriteItem> items);
}

/// Production implementation. Holds no state; reads and writes go through
/// the app-wide [BaseSharedPreferencesService.sharedCache] so favourites
/// are covered by logout wipe, export and store salvage like every other
/// pref.
class SharedPreferencesIptvItemFavoritesRepository implements IptvItemFavoritesRepository {
  const SharedPreferencesIptvItemFavoritesRepository();

  @override
  Future<Map<String, IptvFavoriteItem>> read({required String key}) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final raw = readTolerantString(prefs, key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, IptvFavoriteItem>{};
      for (final entry in decoded.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        try {
          out[entry.key] = IptvFavoriteItem.fromJson(entry.value);
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
  Future<void> write(String key, Map<String, IptvFavoriteItem> items) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(key, jsonEncode(items.map((k, v) => MapEntry(k, v.toJson()))));
  }
}
