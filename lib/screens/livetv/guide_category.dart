import '../../models/livetv_channel.dart';

/// One entry in the guide's category picker (build #17): a visible live
/// TV category on one server. [label] is the display name — the bare
/// category name, prefixed with the source ("Trex — US") when the same
/// name exists on another visible source, so a category never shows
/// another source's channels. [serverId] + [categoryId] identify the
/// filter: a category id means nothing on another source.
typedef GuideCategoryEntry = ({String serverId, String categoryId, String label});

/// Apply the guide's source + live-TV-category filters to already-loaded
/// rows (build #17). Pure and in-memory: switching the source or the
/// category never re-fetches — it filters the rows the guide already
/// holds. A category is a (serverId, categoryId) pair, so picking a
/// category on one source never shows another source's channels.
/// Channels without a category (Plex/Jellyfin/Emby) never match a
/// selected category.
List<LiveTvChannel> filterGuideChannels({
  required List<LiveTvChannel> channels,
  String? sourceId,
  GuideCategoryEntry? category,
}) {
  var list = channels;
  if (sourceId != null) {
    list = list.where((c) => c.serverId == sourceId).toList(growable: false);
  }
  if (category != null) {
    list = list
        .where((c) => c.serverId == category.serverId && c.categoryId == category.categoryId)
        .toList(growable: false);
  }
  return list;
}
