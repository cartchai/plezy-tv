import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection/connection.dart';
import '../i18n/strings.g.dart';
import '../media/live_tv_support.dart';
import '../media/media_source_info.dart';
import '../models/livetv_capture_buffer.dart';
import '../models/livetv_channel.dart';
import '../models/livetv_program.dart';
import '../models/transcode_quality_preset.dart';
import '../services/favorite_channels_repository.dart';
import '../services/iptv/xmltv_parser.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import 'iptv_client.dart';

/// Which source served a channel's EPG (build #17, §10) — the split the
/// guide coverage diagnostic reports. `unknown` is for entries read from
/// disk files written before this build recorded the source.
enum IptvEpgSource { feedById, feedByName, shortEpg, none, unknown }

/// Guide coverage over the channels the guide has loaded EPG for (build
/// #17, §10): how many have programmes, split by the source that served
/// them, plus the tvg-id match rate over the same set — the numbers the
/// phone needs to prove the guide is fuller. `feedChannelIds` is the
/// distinct channel-id count of the last loaded XMLTV feed (0 when no
/// feed has loaded yet); it is context, not a denominator.
class IptvGuideCoverage {
  final int total;
  final int withPrograms;
  final int fromFeedById;
  final int fromFeedByName;
  final int fromShortEpg;
  final int none;
  final int unknown;
  final int feedChannelIds;

  const IptvGuideCoverage({
    required this.total,
    required this.withPrograms,
    required this.fromFeedById,
    required this.fromFeedByName,
    required this.fromShortEpg,
    required this.none,
    required this.unknown,
    required this.feedChannelIds,
  });

  const IptvGuideCoverage.empty()
    : total = 0,
      withPrograms = 0,
      fromFeedById = 0,
      fromFeedByName = 0,
      fromShortEpg = 0,
      none = 0,
      unknown = 0,
      feedChannelIds = 0;

  /// Share of loaded channels with programmes, 0–100 (0 when none loaded).
  int get percentWithPrograms => total == 0 ? 0 : (withPrograms * 100 / total).round();
}

/// Normalize a channel name for the EPG name-fallback match (build #17,
/// §10): strip a leading region/category tag ("US| ", "|EN| ",
/// "UK-NOWTV| "), lowercase, strip non-alphanumerics. "US| COMEDY
/// CENTRAL HD" and "Comedy Central HD" both normalize to
/// "comedycentralhd", so a feed whose channel ids are plain names matches
/// a playlist whose names carry region prefixes — and vice versa. No
/// fuzzy matching: the normalized strings must be exactly equal.
@visibleForTesting
String normalizeEpgChannelName(String name) {
  var s = name.trim();
  // Leading "|XX| " tag ("|EN| TOP SERIES").
  s = s.replaceFirst(RegExp(r'^\|[^|]*\|\s*'), '');
  // Leading "XX| " tag ("US| COMEDY CENTRAL HD", "UK-NOWTV| ...").
  s = s.replaceFirst(RegExp(r'^[^|\s][^|]{0,15}\|\s*'), '');
  return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

/// Live TV for IPTV connections (M3U + Xtream Codes).
///
/// Channels come from the provider's live list; playback is a direct stream
/// URL (no tune/transcode negotiation). Catch-up is available only on
/// Xtream channels with `tv_archive = 1`, via the `/timeshift/` endpoint —
/// the session synthesizes its [CaptureBuffer] from `tv_archive_duration`
/// and rebuilds the URL for a requested offset. There is no DVR surface.
class IptvLiveTvSupport implements LiveTvSupport {
  final IptvClient _client;
  final FavoriteChannelsRepository _favoritesRepository;

  IptvLiveTvSupport(this._client, [FavoriteChannelsRepository? favoritesRepository])
    : _favoritesRepository = favoritesRepository ?? const SharedPreferencesFavoriteChannelsRepository();

  String get _favoritesPrefsKey => 'iptv_fav_channels:${_client.connection.id}';

  /// Per-channel hide store (build #17, §9): `iptv_hidden_channels:<connectionId>`
  /// (SharedPreferences string list, same pattern as the favourites store
  /// above). A channel is identified by the SAME key derivation as
  /// favourites — the favorite source + channel key — so hide and favorite
  /// agree on identity. Per-connection, so hiding a Trex channel never
  /// hides a Plex one. The in-memory set is loaded lazily and kept in sync
  /// by [hideChannel]/[unhideChannel]; [isHiddenChannel] reads the
  /// in-memory set (empty until [loadHiddenChannels] has run — callers
  /// load first, then filter).
  String get _hiddenChannelsPrefsKey => 'iptv_hidden_channels:${_client.connection.id}';
  final Set<String> _hiddenChannelKeys = {};
  bool _hiddenChannelsLoaded = false;

  /// The favorite source string, factored out of [buildFavoriteChannelSource]
  /// so the hide key uses the identical derivation.
  String get _favoriteChannelSource => 'server://${_client.connection.id}/iptv';

  /// The stored hidden-channel key for [channel] — the same derivation as
  /// its favorite key.
  String hiddenKeyForChannel(LiveTvChannel channel) => favoriteChannelKey(_favoriteChannelSource, channel.key);

  /// The stored hidden keys (for the Settings → IPTV hidden-channels list).
  /// Empty until [loadHiddenChannels] has run.
  Set<String> get hiddenChannelKeys => Set.unmodifiable(_hiddenChannelKeys);

  /// Load the hidden set from disk (no-op when already loaded).
  Future<Set<String>> loadHiddenChannels() async {
    if (_hiddenChannelsLoaded) return Set.unmodifiable(_hiddenChannelKeys);
    final prefs = await SharedPreferences.getInstance();
    _hiddenChannelKeys
      ..clear()
      ..addAll(prefs.getStringList(_hiddenChannelsPrefsKey) ?? const []);
    _hiddenChannelsLoaded = true;
    return Set.unmodifiable(_hiddenChannelKeys);
  }

  bool isHiddenChannel(LiveTvChannel channel) => _hiddenChannelKeys.contains(hiddenKeyForChannel(channel));

  /// Sync check by channel key (the part after the source separator in a
  /// stored hidden key) — the search filter's funnel, which runs after the
  /// set has been loaded.
  bool isHiddenChannelKey(String channelKey) =>
      _hiddenChannelKeys.contains(favoriteChannelKey(_favoriteChannelSource, channelKey));

  Future<void> hideChannel(LiveTvChannel channel) async {
    await loadHiddenChannels();
    if (_hiddenChannelKeys.add(hiddenKeyForChannel(channel))) await _persistHiddenChannels();
  }

  Future<void> unhideChannel(LiveTvChannel channel) async {
    await loadHiddenChannels();
    if (_hiddenChannelKeys.remove(hiddenKeyForChannel(channel))) await _persistHiddenChannels();
  }

  /// Remove a hidden entry by its channel key (the Settings list holds
  /// stored keys, not channel objects — the key is the part after the
  /// source separator).
  Future<void> unhideChannelKey(String channelKey) async {
    await loadHiddenChannels();
    if (_hiddenChannelKeys.remove(favoriteChannelKey(_favoriteChannelSource, channelKey))) {
      await _persistHiddenChannels();
    }
  }

  Future<void> unhideAllChannels() async {
    await loadHiddenChannels();
    if (_hiddenChannelKeys.isEmpty) return;
    _hiddenChannelKeys.clear();
    await _persistHiddenChannels();
  }

  Future<void> _persistHiddenChannels() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenChannelsPrefsKey, _hiddenChannelKeys.toList(growable: false));
  }

  bool get _isXtream => _client.connection is XtreamConnection;

  /// Per-channel EPG, keyed by channel key. Entries cover the whole
  /// settings window ([now - pastDays, now + daysToLoad]) so scrolling the
  /// guide re-uses them until the update interval elapses.
  final Map<String, _CachedChannelEpg> _epgCache = {};

  /// Parsed XMLTV files, keyed by EPG URL (M3U) or by a sentinel for the
  /// Xtream login's `xmltv.php` feed (see [_xtreamXmltvGuide]).
  final Map<String, _CachedXmltvGuide> _xmltvCache = {};

  /// In-flight XMLTV fetches, keyed like [_xmltvCache]: the guide opens
  /// many channels at once, and they must share ONE `xmltv.php` download
  /// instead of each pulling the multi-megabyte file. The entry is removed
  /// when the fetch settles, so a later stale-cache call re-fetches.
  final Map<String, Future<_CachedXmltvGuide>> _xmltvGuideFutures = {};

  /// Failed XMLTV feed downloads, keyed like [_xmltvCache] (build #15,
  /// item 6): a failed feed is remembered briefly so a slow/failing feed
  /// is not re-downloaded channel by channel — rows show the existing
  /// tap-to-retry state instead until the window passes.
  final Map<String, DateTime> _xmltvFailedAt = {};

  /// Cap on concurrent per-channel `get_short_epg` calls (build #15,
  /// item 6): the guide opens many rows at once and each used to fire its
  /// own 60s call. Four in flight is enough for the first visible rows
  /// while the rest wait their turn instead of stacking timeouts.
  static const int _maxShortEpgConcurrency = 4;
  int _shortEpgInFlight = 0;
  final List<Completer<void>> _shortEpgWaiters = [];

  /// First-paint budget for one channel's `get_short_epg` (build #15,
  /// item 6): a channel whose short-EPG doesn't answer quickly falls back
  /// to the cached feed slice instead of holding its row for the full
  /// 60s. Test-overridable so the timeout path stays fast to prove.
  @visibleForTesting
  static Duration shortEpgFirstPaintTimeout = const Duration(seconds: 15);

  /// How long a failed XMLTV feed download is remembered (build #15,
  /// item 6). Test-overridable.
  @visibleForTesting
  static Duration xmltvNegativeCacheTtl = const Duration(minutes: 5);

  /// True after "Clear guide" until something refreshes the guide
  /// ([refreshEpgCache] or the one start-up refresh). While set, the guide
  /// shows "No information available" hour blocks instead of refetching —
  /// otherwise Clear would be undone by the guide's lazy fetch on its
  /// next row build.
  bool _epgCleared = false;

  /// Bumped by [clearEpgCache]; the guide watches it to reset per-channel
  /// loaded/failed state and re-fetch visible rows.
  int _epgVersion = 0;
  DateTime? _lastEpgUpdatedAt;
  DateTime? _lastEpgPrefWrite;

  /// Test-only override for the directory the persisted EPG cache lives
  /// in, so tests can use a temp dir instead of the app cache. Production
  /// code never sets this; reset it in tearDown when a test does.
  @visibleForTesting
  static Future<Directory> Function()? debugEpgCacheDirectoryProvider;

  /// Test-only: when true, the persisted EPG side is skipped entirely
  /// (mirrors `IptvCatalogDiskCache.debugDisableDisk` — real disk I/O hangs
  /// inside testWidgets' fake async zone). Production code never sets this.
  @visibleForTesting
  static bool debugDisablePersistedEpg = false;

  /// Whether the update-on-start refresh has run for this support instance
  /// (one instance per client per app launch), per channel. Build #6 used
  /// one bool for the whole support — harmless with an in-memory cache
  /// (every channel was cold at launch anyway), but with a persisted
  /// cache the first channel's refresh would have lifted the flag for
  /// every other channel, leaving their stale entries in place. One fresh
  /// fetch per channel on the first guide open is the setting's actual
  /// meaning.
  final Set<String> _startupRefreshedChannels = {};

  @override
  LiveTvDvrSupport? get dvr => null;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<List<LiveTvChannel>> fetchChannels({String? lineup}) => _client.iptvChannels();

  @override
  Future<List<LiveTvProgram>> fetchSchedule({DateTime? from, DateTime? to}) async {
    // Intentionally empty: the server-wide hook cannot name the channels the
    // guide is actually showing, and one call per channel across a 55k-row
    // catalog is not an option. The guide drives EPG lazily per visible
    // channel through [fetchEpgForChannel] instead, so only browsed channels
    // are ever fetched. See IPTV_EPG_NOTES.md.
    return const [];
  }

  /// EPG settings snapshot, read once per fetch from [SettingsService].
  static Future<_EpgSettings> _readEpgSettings() async {
    final settings = await SettingsService.getInstance();
    return _EpgSettings(
      daysToLoad: settings.read(SettingsService.iptvEpgDaysToLoad),
      updateIntervalHours: settings.read(SettingsService.iptvEpgUpdateIntervalHours),
      pastDays: settings.read(SettingsService.iptvEpgPastDays),
      updateOnStart: settings.read(SettingsService.iptvEpgUpdateOnStart),
      timeOffsetMinutes: settings.read(SettingsService.iptvEpgTimeOffsetMinutes),
    );
  }

  /// Fetch guide programs for ONE channel, for the requested window.
  ///
  /// The fetch covers the whole settings window ([now - pastDays, now +
  /// daysToLoad]) and the result is cached per channel, so scrolling the
  /// guide re-uses it until the update interval elapses. Only the slice
  /// overlapping [from, to] is returned.
  ///
  /// Build #8 Task 3: a fetch that FAILS (both sources failed) THROWS
  /// instead of returning [] — the old fail-open [] made the guide record
  /// a failed fetch as a successful empty one (loaded, placeholders, never
  /// retried), so Matt could not tell "failed" from "loaded but empty".
  /// Returning [] now means only one thing: the fetch succeeded and this
  /// channel genuinely has no programmes in the window. The guide catches
  /// the throw and marks the channel FAILED (visible retry state).
  Future<List<LiveTvProgram>> fetchEpgForChannel(
    String channelKey, {
    required DateTime from,
    required DateTime to,
  }) async {
    final settings = await _readEpgSettings();
    final now = DateTime.now();

    // Update-on-start forces one fresh fetch per channel on the first guide
    // open after launch, even inside the interval. It also lifts a
    // "Clear guide", since the user asked for a refresh on start.
    final forceRefresh = settings.updateOnStart && !_startupRefreshedChannels.contains(channelKey);
    if (forceRefresh) _startupRefreshedChannels.add(channelKey);
    if (_epgCleared && !forceRefresh) return const <LiveTvProgram>[];
    if (forceRefresh) _epgCleared = false;

    final fetchFrom = now.subtract(Duration(days: settings.pastDays));
    final fetchTo = now.add(Duration(days: settings.daysToLoad));
    final ttl = settings.updateIntervalHours <= 0
        ? null // Manual only: the cache never expires on its own.
        : Duration(hours: settings.updateIntervalHours);

    // In-memory first, then the persisted entry: a fresh persisted entry
    // covering the requested window is served without refetching — that is
    // the whole point of persisting it. A stale entry, or one that does
    // not cover the window, falls through to a refetch below.
    final cached = _epgCache[channelKey] ?? await _readPersistedEpg(channelKey);
    if (cached != null) _epgCache[channelKey] = cached;
    if (cached != null && cached.covers(from, to) && cached.isFresh(ttl) && !forceRefresh) {
      return _slice(cached.programs, from, to);
    }

    List<LiveTvProgram> programs;
    IptvEpgSource source;
    try {
      final fetched = _isXtream
          ? await _fetchXtreamEpg(channelKey, settings, fetchFrom, fetchTo, ttl)
          : await _fetchM3uEpg(channelKey, settings, fetchFrom, fetchTo, ttl);
      programs = fetched.programs;
      source = fetched.source;
    } catch (e) {
      // Build #8 Task 3: a failed fetch must surface (see the doc comment
      // above) — swallowing it as [] recorded failures as loaded-empty.
      // A failed fetch writes no cache entry, so a retry refetches.
      appLogger.w('IPTV EPG fetch failed for channel $channelKey', error: e);
      rethrow;
    }

    final entry = _CachedChannelEpg(programs: programs, fetchedAt: now, windowFrom: fetchFrom, windowTo: fetchTo, source: source);
    _epgCache[channelKey] = entry;
    // Best-effort and fire-and-forget: a failed write never breaks the
    // guide — the in-memory entry above still serves this launch — and
    // awaiting the disk write here would gate the guide on file I/O.
    // (The write still happens; it just doesn't hold the fetch open.)
    unawaited(_writePersistedEpg(channelKey, entry));
    _lastEpgUpdatedAt = now;
    _noteEpgUpdated(now);
    return _slice(programs, from, to);
  }

  /// Programmes from the EPG cache ONLY, for [channelKeys] — in-memory
  /// entries plus persisted per-channel files. Never a network fetch
  /// (build #15, item 2): the guide search sheet must not fire a
  /// `get_short_epg` per channel across the catalog. Channels with no
  /// cache entry contribute nothing here; they still match by channel
  /// name in the sheet. A stale entry is served as-is (the guide is the
  /// source of truth for freshness) as long as it covers the window.
  ///
  /// The persisted side is ONE directory listing, not one read per channel:
  /// only channels with a file are read, and only ones not already served
  /// from memory. A cache read failure never breaks search — programme
  /// results are best-effort.
  Future<Map<String, List<LiveTvProgram>>> cachedEpgForChannels(
    Set<String> channelKeys, {
    required DateTime from,
    required DateTime to,
  }) async {
    final out = <String, List<LiveTvProgram>>{};
    for (final key in channelKeys) {
      final entry = _epgCache[key];
      if (entry == null || !entry.covers(from, to)) continue;
      final slice = _slice(entry.programs, from, to);
      if (slice.isNotEmpty) out[key] = slice;
    }
    // Every requested channel already served from memory — the common case
    // after the guide warmed the cache — so no directory listing at all.
    if (out.length == channelKeys.length || debugDisablePersistedEpg) return out;
    try {
      final dir = await _epgCacheDir();
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final key = _channelKeyFromFileName(entity.path.split('/').last);
          if (key == null || !channelKeys.contains(key) || out.containsKey(key)) continue;
          final entry = await _readPersistedEpg(key);
          if (entry == null || !entry.covers(from, to)) continue;
          _epgCache[key] = entry;
          final slice = _slice(entry.programs, from, to);
          if (slice.isNotEmpty) out[key] = slice;
        }
      }
    } catch (_) {
      // Best-effort: in-memory results above still stand.
    }
    return out;
  }

  /// The channel key for a persisted EPG filename (`<base64url(key)>.json`
  /// — see [_fileSafe]); null when the name does not decode.
  static String? _channelKeyFromFileName(String name) {
    final base = name.endsWith('.json') ? name.substring(0, name.length - 5) : name;
    try {
      final padded = base + ('=' * ((4 - base.length % 4) % 4));
      return utf8.decode(base64Url.decode(padded));
    } catch (_) {
      return null;
    }
  }

  /// Test-only seam: seed the in-memory EPG cache for [channelKey] without
  /// touching disk or the network, so the search sheet's cache-only path
  /// can be driven directly. Production code never calls this.
  @visibleForTesting
  void debugSeedCachedEpg(
    String channelKey,
    List<LiveTvProgram> programs, {
    required DateTime from,
    required DateTime to,
  }) {
    _epgCache[channelKey] = _CachedChannelEpg(
      programs: programs,
      fetchedAt: DateTime.now(),
      windowFrom: from,
      windowTo: to,
    );
  }

  /// Persisted EPG cache: one JSON file per browsed channel, under the app
  /// cache directory (`iptv_epg/<connectionId>/<channelKey>.json`). A
  /// channel's whole settings window runs to hundreds of programs, so
  /// SharedPreferences would bloat; the cache directory is also the app's
  /// existing pattern for bulky per-item files (see ImageCacheService).
  /// Channel keys come from provider data, so the filename is
  /// base64url-encoded — never trusted raw.
  Future<Directory> _epgCacheDir() async {
    final base = await (debugEpgCacheDirectoryProvider ?? getApplicationCacheDirectory)();
    return Directory('${base.path}/iptv_epg/${_fileSafe(_client.connection.id)}');
  }

  static String _fileSafe(String value) => base64Url.encode(utf8.encode(value)).replaceAll('=', '');

  Future<File> _epgCacheFile(String channelKey) async {
    final dir = await _epgCacheDir();
    return File('${dir.path}/${_fileSafe(channelKey)}.json');
  }

  Future<_CachedChannelEpg?> _readPersistedEpg(String channelKey) async {
    try {
      final file = await _epgCacheFile(channelKey);
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return _CachedChannelEpg.fromJson(decoded);
    } catch (_) {
      // A corrupt or unreadable file reads as a miss — the channel
      // refetches and rewrites it.
      return null;
    }
  }

  Future<void> _writePersistedEpg(String channelKey, _CachedChannelEpg entry) async {
    try {
      final file = await _epgCacheFile(channelKey);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(entry.toJson()));
    } catch (e) {
      appLogger.w('IPTV EPG cache write failed for channel $channelKey', error: e);
    }
  }

  Future<void> _deletePersistedEpg() async {
    try {
      final dir = await _epgCacheDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      appLogger.w('IPTV EPG cache delete failed', error: e);
    }
  }

  /// Programs overlapping [from, to] (the guide's 6-hour window).
  static List<LiveTvProgram> _slice(List<LiveTvProgram> programs, DateTime from, DateTime to) {
    final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    return programs.where((p) => (p.endsAt ?? 0) > fromEpoch && (p.beginsAt ?? 0) < toEpoch).toList(growable: false);
  }

  /// Xtream EPG, TiviMate-style (build #8 Task 3): per-channel
  /// `get_short_epg` answers FIRST for the visible channel, while the
  /// login's big `xmltv.php` feed loads in the background (one shared fetch
  /// for the whole catalog, deduped by [_xtreamXmltvGuide]). The old order
  /// — xmltv first — made every visible row wait on a 55k-channel file
  /// (tens of MB, up to 120s) before showing anything. If get_short_epg has
  /// nothing for the channel, the feed (already in flight) is awaited and
  /// matched by tvg-id. A channel is never left blank by a missing or
  /// partial feed — and a fetch only THROWS when both sources fail: if
  /// either source answers (even empty), that answer stands, so a genuine
  /// empty is never misread as a failure.
  Future<({List<LiveTvProgram> programs, IptvEpgSource source})> _fetchXtreamEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl,
  ) async {
    // Start the big feed loading in the background now, so the fallback
    // below awaits the shared in-flight future instead of starting it.
    // Attach a no-op error listener NOW: the future is only awaited after
    // get_short_epg answers, and a rejection with no listener in the
    // meantime would surface as an unhandled async error — even though the
    // fetch handles it below. Awaiting the original future still sees the
    // rejection; this listener only marks it observed.
    final xmltvFuture = _fetchXtreamXmltvPrograms(channelKey, settings, from, to, ttl);
    unawaited(xmltvFuture.then<void>((_) {}).catchError((_) {}));
    List<LiveTvProgram>? shortEpg;
    try {
      shortEpg = await _fetchXtreamShortEpg(channelKey, settings, from, to);
    } catch (e) {
      appLogger.w('IPTV: get_short_epg failed for channel $channelKey; using xmltv.php', error: e);
    }
    if (shortEpg != null && shortEpg.isNotEmpty) {
      // The background feed still lands in the shared cache for later
      // fetches (its error is already observed above).
      return (programs: shortEpg, source: IptvEpgSource.shortEpg);
    }
    // get_short_epg had nothing (or failed): use the feed (already
    // loading). A feed that loads but has nothing for the channel returns
    // [] (genuine empty); a feed that fails only throws when get_short_epg
    // never answered — both sources failed.
    try {
      return await xmltvFuture;
    } catch (e) {
      if (shortEpg != null) {
        appLogger.w(
          'IPTV: xmltv.php fetch failed for channel $channelKey; get_short_epg already answered empty',
          error: e,
        );
        return (programs: const <LiveTvProgram>[], source: IptvEpgSource.none);
      }
      rethrow;
    }
  }

  /// Programmes for one channel out of the login's `xmltv.php` feed, plus
  /// which match served them (build #17, §10).
  /// The feed is fetched lazily (only when a channel's cached entry is
  /// stale or missing) and the parsed file is shared by every channel in
  /// the guide — never one fetch per channel. Matching is by the channel's
  /// tvg-id (`epg_channel_id`); some panels use the stream id as the XMLTV
  /// channel id, so that matches too. When neither hits, the channel's
  /// normalized name is tried against the feed's normalized channel ids —
  /// a feed whose ids are plain names matches a playlist whose names carry
  /// region prefixes. The source names what actually served programmes
  /// (after window filtering): a match whose programmes all fall outside
  /// the window still counts as `none` — the guide shows nothing for it.
  Future<({List<LiveTvProgram> programs, IptvEpgSource source})> _fetchXtreamXmltvPrograms(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl,
  ) async {
    final guide = await _xtreamXmltvGuide(ttl: ttl);
    _lastXmltvFeedChannelIds = guide.byChannel.length;
    final epgChannelId = _client.epgChannelIdForChannelKey(channelKey);
    final byId = <XmltvProgram>[];
    if (epgChannelId != null) byId.addAll(guide.byChannel[epgChannelId] ?? const []);
    if (epgChannelId != channelKey) byId.addAll(guide.byChannel[channelKey] ?? const []);
    var programs = _mapXmltvPrograms(byId, channelKey, settings, from, to, keyPrefix: 'xtream');
    if (programs.isNotEmpty) return (programs: programs, source: IptvEpgSource.feedById);
    final channelName = _client.channelNameForChannelKey(channelKey);
    if (channelName != null && channelName.isNotEmpty) {
      final byName = guide.byNormalizedName[normalizeEpgChannelName(channelName)] ?? const [];
      programs = _mapXmltvPrograms(byName, channelKey, settings, from, to, keyPrefix: 'xtream');
      if (programs.isNotEmpty) return (programs: programs, source: IptvEpgSource.feedByName);
    }
    return (programs: const <LiveTvProgram>[], source: IptvEpgSource.none);
  }

  /// One channel's `get_short_epg` listings — the fallback when the
  /// `xmltv.php` feed has nothing for the channel (or cannot be fetched).
  /// Limit 500 covers ~10 days of half-hour slots; anything past the limit
  /// simply does not appear (placeholders fill the gap) instead of failing.
  ///
  /// Build #15, item 6: at most [_maxShortEpgConcurrency] calls run at
  /// once, and a call that doesn't answer within
  /// [shortEpgFirstPaintTimeout] gives up fast — the caller falls back to
  /// the cached feed slice instead of holding the row for the full 60s.
  Future<List<LiveTvProgram>> _fetchXtreamShortEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
  ) async {
    await _acquireShortEpgSlot();
    try {
      final listings = await _client.xtreamApi
          .getShortEpg(channelKey, limit: 500, timeout: const Duration(seconds: 60))
          .timeout(
            shortEpgFirstPaintTimeout,
            onTimeout: () => throw TimeoutException('get_short_epg first-paint timeout for $channelKey'),
          );
      final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
      final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
      final offsetSeconds = settings.timeOffsetMinutes * 60;
      final programs = <LiveTvProgram>[];
      for (final listing in listings) {
        try {
          final beginsAt = listing.startTimestamp + offsetSeconds;
          final endsAt = listing.stopTimestamp + offsetSeconds;
          if (endsAt <= beginsAt || endsAt <= fromEpoch || beginsAt >= toEpoch) continue;
          programs.add(
            LiveTvProgram(
              // The API's own channel id is not trusted for matching: the
              // guide indexes programs by the channel key it asked for.
              key: 'epg:$channelKey:${listing.id}',
              title: listing.title.isEmpty ? t.liveTv.unknownProgram : listing.title,
              summary: listing.description.isEmpty ? null : listing.description,
              beginsAt: beginsAt,
              endsAt: endsAt,
              channelIdentifier: channelKey,
              serverId: _client.connection.id,
              serverName: _client.serverName,
            ),
          );
        } catch (_) {
          // One bad listing does not invalidate the channel's guide.
        }
      }
      programs.sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
      return programs;
    } finally {
      _releaseShortEpgSlot();
    }
  }

  /// Take one of the [_maxShortEpgConcurrency] `get_short_epg` slots,
  /// waiting for a free one when the storm is at the cap. The wait is
  /// bounded in practice: every holder gives up after
  /// [shortEpgFirstPaintTimeout], so a slot frees within that budget.
  Future<void> _acquireShortEpgSlot() async {
    while (_shortEpgInFlight >= _maxShortEpgConcurrency) {
      final waiter = Completer<void>();
      _shortEpgWaiters.add(waiter);
      await waiter.future;
    }
    _shortEpgInFlight++;
  }

  void _releaseShortEpgSlot() {
    _shortEpgInFlight--;
    if (_shortEpgWaiters.isNotEmpty) _shortEpgWaiters.removeAt(0).complete();
  }

  Future<({List<LiveTvProgram> programs, IptvEpgSource source})> _fetchM3uEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl,
  ) async {
    final connection = _client.connection;
    if (connection is! M3uConnection) return (programs: const <LiveTvProgram>[], source: IptvEpgSource.none);
    final epgUrl = connection.epgUrl;
    if (epgUrl == null || epgUrl.isEmpty) return (programs: const <LiveTvProgram>[], source: IptvEpgSource.none);
    // The XMLTV `channel` attribute matches the entry's tvg-id, which is
    // also the M3U channel key when present. When it misses, the entry's
    // normalized name is tried (build #17, §10) — same fallback as Xtream.
    final tvgId = _client.tvgIdForChannelKey(channelKey);
    if (tvgId == null) return (programs: const <LiveTvProgram>[], source: IptvEpgSource.none);
    final guide = await _xmltvGuide(epgUrl, ttl: ttl);
    _lastXmltvFeedChannelIds = guide.byChannel.length;
    var programs = _mapXmltvPrograms(guide.byChannel[tvgId] ?? const [], channelKey, settings, from, to, keyPrefix: 'm3u');
    if (programs.isNotEmpty) return (programs: programs, source: IptvEpgSource.feedById);
    final channelName = _client.channelNameForChannelKey(channelKey);
    if (channelName != null && channelName.isNotEmpty) {
      final byName = guide.byNormalizedName[normalizeEpgChannelName(channelName)] ?? const [];
      programs = _mapXmltvPrograms(byName, channelKey, settings, from, to, keyPrefix: 'm3u');
      if (programs.isNotEmpty) return (programs: programs, source: IptvEpgSource.feedByName);
    }
    return (programs: const <LiveTvProgram>[], source: IptvEpgSource.none);
  }

  /// Map parsed XMLTV programmes for one channel to guide programs,
  /// window-filtered and sorted. Shared by the M3U (user EPG URL) and
  /// Xtream (`xmltv.php`) paths.
  List<LiveTvProgram> _mapXmltvPrograms(
    List<XmltvProgram> entries,
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to, {
    required String keyPrefix,
  }) {
    final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    final offsetSeconds = settings.timeOffsetMinutes * 60;
    final programs = <LiveTvProgram>[];
    for (final entry in entries) {
      final beginsAt = entry.startEpoch + offsetSeconds;
      final endsAt = entry.stopEpoch + offsetSeconds;
      if (endsAt <= beginsAt || endsAt <= fromEpoch || beginsAt >= toEpoch) continue;
      programs.add(
        LiveTvProgram(
          key: 'epg:$keyPrefix:$channelKey:$beginsAt',
          title: entry.title.isEmpty ? t.liveTv.unknownProgram : entry.title,
          summary: entry.description.isEmpty ? null : entry.description,
          beginsAt: beginsAt,
          endsAt: endsAt,
          channelIdentifier: channelKey,
          serverId: _client.connection.id,
          serverName: _client.serverName,
        ),
      );
    }
    programs.sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
    return programs;
  }

  /// The provider's XMLTV file, parsed once per key and cached for [ttl]
  /// (null = manual only: fetched once, refreshed only by Update now /
  /// Clear). Parsing runs in an isolate — provider files run to megabytes.
  /// Concurrent channel fetches share one in-flight download per key.
  ///
  /// Build #15, item 6 — the feed is persisted, not just held in memory:
  /// a warm start parses the feed FILE instead of re-downloading it, a
  /// stale guide is served immediately while the refresh runs in the
  /// background (stale-while-revalidate), and a failed download is
  /// remembered briefly instead of retried channel by channel.
  Future<_CachedXmltvGuide> _xmltvGuideForKey(
    String cacheKey,
    Future<String> Function() fetchBody,
    Duration? ttl,
  ) async {
    bool fresh(_CachedXmltvGuide guide) => ttl == null || DateTime.now().difference(guide.fetchedAt) < ttl;

    final cached = _xmltvCache[cacheKey];
    if (cached != null && fresh(cached)) return cached;

    // A failed download is remembered briefly: don't start another 120s
    // download for a channel whose feed just failed — the caller falls
    // back to get_short_epg / tap-to-retry instead. A stale guide still
    // beats nothing.
    final failedAt = _xmltvFailedAt[cacheKey];
    if (failedAt != null) {
      if (DateTime.now().difference(failedAt) < xmltvNegativeCacheTtl) {
        if (cached != null) return cached;
        throw StateError('XMLTV feed for $cacheKey failed recently; retry shortly');
      }
      _xmltvFailedAt.remove(cacheKey);
    }

    final inFlight = _xmltvGuideFutures[cacheKey];
    if (inFlight != null) return inFlight;

    // Stale-while-revalidate: a stale in-memory guide still answers while
    // the refresh runs in the background — the guide never waits on a
    // download for programmes it already has.
    if (cached != null) {
      final future = _loadXmltvGuide(cacheKey, fetchBody);
      _xmltvGuideFutures[cacheKey] = future;
      unawaited(
        future.then<void>((_) {}).catchError((_) {}).whenComplete(() {
          _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
        }),
      );
      return cached;
    }

    // No in-memory guide: the persisted feed file is the warm start —
    // parse it now (no download) and refresh in the background when stale.
    final persisted = await _readPersistedXmltv(cacheKey);
    if (persisted != null) {
      _xmltvCache[cacheKey] = persisted;
      if (!fresh(persisted)) {
        final future = _loadXmltvGuide(cacheKey, fetchBody);
        _xmltvGuideFutures[cacheKey] = future;
        unawaited(
          future.then<void>((_) {}).catchError((_) {}).whenComplete(() {
            _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
          }),
        );
      }
      return persisted;
    }

    // Fully cold: one shared download, as before.
    final future = _loadXmltvGuide(cacheKey, fetchBody);
    _xmltvGuideFutures[cacheKey] = future;
    try {
      return await future;
    } finally {
      // The future is already awaited above; dropping it from the map just
      // lets the next stale-cache call start a fresh fetch. (removeWhere
      // returns void, so the discarded Future value trips no lint.)
      _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
    }
  }

  Future<_CachedXmltvGuide> _loadXmltvGuide(String cacheKey, Future<String> Function() fetchBody) async {
    String body;
    try {
      body = await fetchBody();
    } catch (e) {
      _xmltvFailedAt[cacheKey] = DateTime.now();
      rethrow;
    }
    final programs = await compute(parseXmltv, body);
    // Only a parseable feed is persisted — a corrupt body is never written
    // to disk, so a bad download can't poison every later cold start.
    unawaited(_writePersistedXmltv(cacheKey, body));
    final guide = _CachedXmltvGuide(programs: programs, fetchedAt: DateTime.now());
    _xmltvCache[cacheKey] = guide;
    _xmltvFailedAt.remove(cacheKey);
    return guide;
  }

  /// The persisted XMLTV feed file for [cacheKey]
  /// (`feed_<base64url(key)>.xml` next to the per-channel files). The raw
  /// body is stored, not the parsed guide — parsing runs in an isolate on
  /// read, same as on download.
  Future<File> _xmltvFeedFile(String cacheKey) async {
    final dir = await _epgCacheDir();
    return File('${dir.path}/feed_${_fileSafe(cacheKey)}.xml');
  }

  Future<void> _writePersistedXmltv(String cacheKey, String body) async {
    if (debugDisablePersistedEpg) return;
    try {
      final file = await _xmltvFeedFile(cacheKey);
      await file.parent.create(recursive: true);
      await file.writeAsString(body);
    } catch (e) {
      appLogger.w('IPTV EPG feed cache write failed for $cacheKey', error: e);
    }
  }

  /// Read + parse the persisted feed file, or null when there is none (or
  /// it is unreadable / unparseable — a corrupt file reads as a miss, and
  /// is deleted so it is not re-parsed on every cold start). The guide's
  /// fetch time is the file's last-modified time.
  Future<_CachedXmltvGuide?> _readPersistedXmltv(String cacheKey) async {
    if (debugDisablePersistedEpg) return null;
    File? file;
    try {
      file = await _xmltvFeedFile(cacheKey);
      if (!await file.exists()) return null;
      final body = await file.readAsString();
      final programs = await compute(parseXmltv, body);
      return _CachedXmltvGuide(programs: programs, fetchedAt: await file.lastModified());
    } catch (_) {
      try {
        await file?.delete();
      } catch (_) {
        // Best-effort: the file is gone or unreadable anyway.
      }
      return null;
    }
  }

  /// The M3U connection's user-supplied EPG URL, as a parsed guide.
  Future<_CachedXmltvGuide> _xmltvGuide(String epgUrl, {Duration? ttl}) {
    return _xmltvGuideForKey(epgUrl, () async {
      final response = await http.get(Uri.parse(epgUrl)).timeout(const Duration(seconds: 120));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('XMLTV fetch failed with HTTP ${response.statusCode}');
      }
      return response.body;
    }, ttl);
  }

  /// The Xtream login's `xmltv.php` feed, as a parsed guide. One guide per
  /// connection (the support is per-client), fetched lazily on the first
  /// channel that needs it and shared by the rest of the guide.
  Future<_CachedXmltvGuide> _xtreamXmltvGuide({Duration? ttl}) {
    return _xmltvGuideForKey('xtream:${_client.connection.id}', () => _client.xtreamApi.getXmltv(), ttl);
  }

  /// Bump on every cache clear so the guide can tell its per-channel state
  /// (loaded / failed) is stale and re-fetch visible rows.
  int get epgVersion => _epgVersion;

  /// Wall-clock time of the last successful EPG fetch on this client, or
  /// null before the first one. The settings screen reads the stored pref
  /// ([SettingsService.iptvEpgLastUpdated]) instead; this is for tests and
  /// diagnostics.
  DateTime? get lastEpgUpdatedAt => _lastEpgUpdatedAt;

  /// Distinct channel-id count of the last loaded XMLTV feed (build #17,
  /// §10) — context for the coverage diagnostic. 0 before any feed loads;
  /// reset by [clearEpgCache].
  int _lastXmltvFeedChannelIds = 0;

  /// Guide coverage over the channels this support has loaded EPG for
  /// (build #17, §10): the guide only fetches visible rows, so this set
  /// IS the visible guide. Computed from the per-channel cache entries
  /// (in-memory + persisted), so it survives a relaunch; entries read
  /// from disk files written before this build report `unknown`.
  IptvGuideCoverage guideCoverage() {
    var withPrograms = 0;
    var fromFeedById = 0;
    var fromFeedByName = 0;
    var fromShortEpg = 0;
    var none = 0;
    var unknown = 0;
    for (final entry in _epgCache.values) {
      if (entry.programs.isEmpty) {
        none++;
        continue;
      }
      withPrograms++;
      switch (entry.source) {
        case IptvEpgSource.feedById:
          fromFeedById++;
        case IptvEpgSource.feedByName:
          fromFeedByName++;
        case IptvEpgSource.shortEpg:
          fromShortEpg++;
        case IptvEpgSource.none:
          // A fetch that recorded `none` cannot have programmes; treat a
          // non-empty entry as unknown rather than dropping the row.
          unknown++;
        case IptvEpgSource.unknown:
          unknown++;
      }
    }
    return IptvGuideCoverage(
      total: _epgCache.length,
      withPrograms: withPrograms,
      fromFeedById: fromFeedById,
      fromFeedByName: fromFeedByName,
      fromShortEpg: fromShortEpg,
      none: none,
      unknown: unknown,
      feedChannelIds: _lastXmltvFeedChannelIds,
    );
  }

  /// Empty the EPG caches (Update now / Clear guide). The next guide visit
  /// re-fetches visible channels; the guide watches [epgVersion] to reset
  /// its own per-channel state.
  ///
  /// This is the "Clear guide" behaviour: [fetchEpgForChannel] stays empty
  /// until something refreshes ([refreshEpgCache] or the start-up refresh),
  /// so the guide shows "No guide data for this channel" blocks.
  Future<void> clearEpgCache() async {
    _epgCache.clear();
    _xmltvCache.clear();
    _lastXmltvFeedChannelIds = 0;
    // A clear is an explicit retry: forget a failed feed too, so the next
    // guide visit downloads instead of hitting the negative cache.
    _xmltvFailedAt.clear();
    // Best-effort and fire-and-forget: the in-memory caches are already
    // empty and the guide is cleared, so don't gate the settings action
    // (or the guide) on the disk delete — it completes in the background.
    unawaited(_deletePersistedEpg());
    _epgVersion++;
    _epgCleared = true;
    _lastEpgUpdatedAt = null;
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.iptvEpgLastUpdated, '');
  }

  /// Bust the EPG cache AND force a fresh fetch on the guide's next build
  /// ("Update now"). Unlike [clearEpgCache], the guide refetches instead
  /// of staying empty.
  Future<void> refreshEpgCache() async {
    await clearEpgCache();
    _epgCleared = false;
  }

  /// Record the last-update time for the settings screen, at most one
  /// SharedPreferences write per minute across all channel fetches.
  void _noteEpgUpdated(DateTime now) {
    if (_lastEpgPrefWrite != null && now.difference(_lastEpgPrefWrite!).inSeconds < 60) return;
    _lastEpgPrefWrite = now;
    final stamp = now.toIso8601String();
    SettingsService.getInstance().then((settings) {
      settings.write(SettingsService.iptvEpgLastUpdated, stamp);
    });
  }

  @override
  Future<LiveTvPlaybackSession?> startPlayback(
    String channelKey, {
    String? dvrKey,
    TranscodeQualityPreset quality = TranscodeQualityPreset.original,
  }) async {
    // Populate the channel lookup (cached after the first call).
    await _client.iptvChannels();
    late final String liveUrl;
    try {
      liveUrl = _client.liveUrlForChannelKey(channelKey);
    } on UnsupportedError {
      return null;
    }
    final archive = _client.archiveInfoForChannelKey(channelKey);
    return IptvLiveTvPlaybackSession(
      client: _client,
      channelKey: channelKey,
      liveUrl: liveUrl,
      archiveDurationSeconds: archive?.archiveDurationSeconds ?? 0,
    );
  }

  @override
  Future<String> buildFavoriteChannelSource({String? lineup}) async => _favoriteChannelSource;

  @override
  String get favoriteStoreKey => 'iptv:${_client.connection.id}';

  @override
  FavoriteChannelPersistenceMode get favoritePersistenceMode => FavoriteChannelPersistenceMode.serverSlice;

  @override
  Future<List<FavoriteChannel>> fetchFavoriteChannels({bool migrate = true, void Function()? checkCurrent}) {
    return _favoritesRepository.read(
      key: _favoritesPrefsKey,
      legacyKey: _favoritesPrefsKey,
      migrate: migrate,
      checkCurrent: checkCurrent,
    );
  }

  @override
  Future<void> setFavoriteChannels(List<FavoriteChannel> channels, {void Function()? checkCurrent}) {
    checkCurrent?.call();
    return _favoritesRepository.write(_favoritesPrefsKey, channels, checkCurrent: checkCurrent);
  }
}

/// One IPTV live session: a static direct-play URL, plus a rebuilt
/// `/timeshift/` URL when the channel offers catch-up and the player asks
/// for a negative offset. No server session is opened, so there is nothing
/// to heartbeat, release, or re-negotiate — [recover] returns this session
/// so the player simply re-opens the same URL.
class IptvLiveTvPlaybackSession implements LiveTvPlaybackSession {
  final IptvClient client;
  final String channelKey;
  final String liveUrl;
  final int archiveDurationSeconds;

  /// Epoch seconds when the session started — the capture-buffer origin.
  final double _startedAtEpoch;

  IptvLiveTvPlaybackSession({
    required this.client,
    required this.channelKey,
    required this.liveUrl,
    required this.archiveDurationSeconds,
  }) : _startedAtEpoch = DateTime.now().millisecondsSinceEpoch / 1000;

  bool get _hasArchive => archiveDurationSeconds > 0;

  @override
  LiveProgramInfo get program => LiveProgramInfo.none;

  @override
  LiveTvBackgroundPolicy get backgroundPolicy => LiveTvBackgroundPolicy.stopAndExit;

  @override
  CaptureBuffer? get captureBuffer {
    if (!_hasArchive) return null;
    // The window's end is "now", computed at read time — not frozen at
    // tune time (build #9 Task 3): the old `seekEndSeconds: 0` left the
    // bar's live edge minutes stale after minutes of viewing, because no
    // heartbeat ever refreshed it.
    final nowEpoch = DateTime.now().millisecondsSinceEpoch / 1000;
    return CaptureBuffer(
      startedAt: _startedAtEpoch,
      seekStartSeconds: -archiveDurationSeconds.toDouble(),
      seekEndSeconds: (nowEpoch - _startedAtEpoch).clamp(0, double.infinity),
    );
  }

  @override
  List<MediaSubtitleTrack> get subtitleTracks => const [];

  @override
  bool get canTimeShift => _hasArchive;

  @override
  Future<String?> streamUrlAt({int? offsetSeconds, MediaSubtitleTrack? subtitleTrack}) async {
    if (subtitleTrack != null) return null;
    if (offsetSeconds == null || offsetSeconds == 0) return liveUrl;
    if (offsetSeconds > 0 || !_hasArchive) return null;
    // offsetSeconds is seconds from the capture-buffer origin (session
    // start); negative = that far back into the archive.
    final startEpoch = (_startedAtEpoch + offsetSeconds).round();
    final start = DateTime.fromMillisecondsSinceEpoch(startEpoch * 1000, isUtc: true);
    final backMinutes = (-offsetSeconds / 60).ceil();
    final archiveMinutes = (archiveDurationSeconds / 60).ceil();
    final durationMinutes = backMinutes.clamp(1, archiveMinutes);
    return client.timeshiftUrlForChannelKey(channelKey, start, durationMinutes);
  }

  @override
  Future<LiveTimelineUpdate?> reportTimeline({
    required String state,
    required int positionMs,
    required int durationMs,
  }) async {
    // The player's 10s timeline heartbeat refreshes the seek window from
    // this report — returning null (the old behaviour) left the buffer
    // frozen at its tune-time snapshot and the live edge went stale
    // (build #9 Task 3). The update carries a freshly computed buffer so
    // the existing commit path refreshes `_live.captureBuffer` and
    // `atLiveEdge`, exactly as it does for Plex. No archive → no window.
    final buffer = captureBuffer;
    if (buffer == null) return null;
    return LiveTimelineUpdate(captureBuffer: buffer);
  }

  @override
  Future<void> discard() async {}

  @override
  Future<LiveTvPlaybackSession?> recover({required bool directStream, required bool directStreamAudio}) async => this;
}

/// EPG settings as the EPG layer reads them (see [SettingsService]).
class _EpgSettings {
  final int daysToLoad;
  final int updateIntervalHours;
  final int pastDays;
  final bool updateOnStart;
  final int timeOffsetMinutes;

  const _EpgSettings({
    required this.daysToLoad,
    required this.updateIntervalHours,
    required this.pastDays,
    required this.updateOnStart,
    required this.timeOffsetMinutes,
  });
}

/// One channel's fetched guide: the full settings-window program list plus
/// the window it was fetched for, so a later request can tell whether the
/// cached entry still covers it.
class _CachedChannelEpg {
  final List<LiveTvProgram> programs;
  final DateTime fetchedAt;
  final DateTime windowFrom;
  final DateTime windowTo;

  /// Which source served these programmes (build #17, §10) — the split
  /// the guide coverage diagnostic reports. Persisted, so a disk-served
  /// entry still knows its source; files written before this build lack
  /// the field and read back as [IptvEpgSource.unknown].
  final IptvEpgSource source;

  const _CachedChannelEpg({
    required this.programs,
    required this.fetchedAt,
    required this.windowFrom,
    required this.windowTo,
    this.source = IptvEpgSource.unknown,
  });

  Map<String, dynamic> toJson() => {
    'fetchedAt': fetchedAt.toIso8601String(),
    'windowFrom': windowFrom.toIso8601String(),
    'windowTo': windowTo.toIso8601String(),
    'source': source.name,
    'programs': programs.map((p) => p.toJson()).toList(),
  };

  factory _CachedChannelEpg.fromJson(Map<String, dynamic> json) {
    final fetchedAt = DateTime.tryParse(json['fetchedAt'] as String? ?? '');
    final windowFrom = DateTime.tryParse(json['windowFrom'] as String? ?? '');
    final windowTo = DateTime.tryParse(json['windowTo'] as String? ?? '');
    if (fetchedAt == null || windowFrom == null || windowTo == null) {
      throw const FormatException('Invalid cached EPG entry');
    }
    final source = IptvEpgSource.values.firstWhere(
      (s) => s.name == json['source'] as String?,
      orElse: () => IptvEpgSource.unknown,
    );
    final programs = <LiveTvProgram>[];
    final raw = json['programs'];
    if (raw is List) {
      for (final row in raw) {
        if (row is! Map<String, dynamic>) continue;
        try {
          programs.add(LiveTvProgram.fromJson(row));
        } catch (_) {
          // One bad program does not invalidate the channel's guide.
        }
      }
    }
    return _CachedChannelEpg(programs: programs, fetchedAt: fetchedAt, windowFrom: windowFrom, windowTo: windowTo, source: source);
  }

  bool covers(DateTime from, DateTime to) => !windowFrom.isAfter(from) && !windowTo.isBefore(to);

  bool isFresh(Duration? ttl) => ttl == null || DateTime.now().difference(fetchedAt) < ttl;
}

/// One parsed XMLTV file, with its fetch time and an index of programmes
/// by channel id (the `<programme channel="...">` attribute), so serving
/// one channel out of a whole-catalog file is a lookup, not a scan.
class _CachedXmltvGuide {
  final List<XmltvProgram> programs;
  final DateTime fetchedAt;

  _CachedXmltvGuide({required this.programs, required this.fetchedAt});

  late final Map<String, List<XmltvProgram>> byChannel = _index(programs);

  /// Programmes indexed by the channel id's normalized name (build #17,
  /// §10) — the name-fallback match. The feed's channel ids are often
  /// plain names ("Comedy Central HD") while the playlist's names carry
  /// region prefixes ("US| COMEDY CENTRAL HD"); normalizing both sides
  /// the same way makes them match when the exact tvg-id lookup misses.
  late final Map<String, List<XmltvProgram>> byNormalizedName = _indexByNormalizedName(programs);

  static Map<String, List<XmltvProgram>> _index(List<XmltvProgram> programs) {
    final map = <String, List<XmltvProgram>>{};
    for (final program in programs) {
      (map[program.channelId] ??= []).add(program);
    }
    return map;
  }

  static Map<String, List<XmltvProgram>> _indexByNormalizedName(List<XmltvProgram> programs) {
    final map = <String, List<XmltvProgram>>{};
    for (final program in programs) {
      final key = normalizeEpgChannelName(program.channelId);
      if (key.isEmpty) continue;
      (map[key] ??= []).add(program);
    }
    return map;
  }
}
