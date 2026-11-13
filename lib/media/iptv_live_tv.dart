import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../connection/connection.dart';
import '../exceptions/media_server_exceptions.dart';
import '../i18n/strings.g.dart';
import '../media/live_tv_support.dart';
import '../media/media_source_info.dart';
import '../models/livetv_capture_buffer.dart';
import '../models/livetv_channel.dart';
import '../models/livetv_program.dart';
import '../models/transcode_quality_preset.dart';
import '../services/favorite_channels_repository.dart';
import '../services/iptv/iptv_playback_activity.dart';
import '../services/iptv/xmltv_parser.dart';
import '../services/settings_service.dart';
import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart' show AbortController;
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

  /// AbortControllers for EPG fetches currently in flight on this
  /// support (build #28): the per-channel short-EPG calls and the
  /// whole-guide XMLTV download. [cancelBackgroundWork] triggers every
  /// controller in this set when the app backgrounds, and
  /// [cancelEpgFetchForChannel] triggers one channel's. A controller is
  /// added when its fetch starts and removed when the fetch settles;
  /// aborting one that already settled is a no-op.
  final Set<AbortController> _activeEpgAborts = <AbortController>{};

  /// The in-flight EPG fetch per channel key (build #28) — the
  /// scroll-away cancel: when a guide row leaves the viewport, the tab
  /// cancels that channel's fetch instead of letting it run to
  /// completion unobserved. The feed download is shared, so it is NOT
  /// in this map — only the per-channel short-EPG call is.
  final Map<String, AbortController> _epgAbortsByChannel = <String, AbortController>{};

  /// Stop every in-flight EPG fetch on this support (build #28): the
  /// per-channel short-EPG calls and the whole-guide XMLTV download.
  /// Called by [IptvClient.cancelBackgroundWork] when the app
  /// backgrounds. Safe to call with nothing in flight (no-op). A
  /// cancellation is not a failure — it is never recorded as a refusal
  /// and never poisons the feed's negative cache (see
  /// [_loadXmltvGuide]).
  void cancelBackgroundWork() {
    for (final abort in _activeEpgAborts.toList()) {
      abort.abort();
    }
  }

  /// Stop one channel's in-flight EPG fetch (build #28) — the
  /// scroll-away cancel. A no-op when that channel has no fetch in
  /// flight. The shared feed download is untouched: other visible rows
  /// may still need it. An M3U channel has no per-channel call (its
  /// only fetch is the shared feed), so this is a no-op for M3U — the
  /// feed is stopped only by [cancelBackgroundWork].
  void cancelEpgFetchForChannel(String channelKey) {
    _epgAbortsByChannel.remove(channelKey)?.abort();
  }

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

    // Build #26 (26.7): the fetch window is widened to cover the
    // REQUESTED window, not just [now - pastDays, now + daysToLoad] —
    // the day picker offers today + 7 days, but a picked day past the
    // 4-day settings window could never show data: the feed slice was
    // filtered to the settings window before the requested slice was
    // taken. The feed already holds the data; no extra download.
    var fetchFrom = now.subtract(Duration(days: settings.pastDays));
    var fetchTo = now.add(Duration(days: settings.daysToLoad));
    if (from.isBefore(fetchFrom)) fetchFrom = from;
    if (to.isAfter(fetchTo)) fetchTo = to;
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
    unawaited(_pruneStalePersistedEpg(ttl));
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

  /// Delete per-channel EPG files older than [ttl] (build #26, 26.6):
  /// the per-channel files were never pruned, so browsed channels
  /// accumulated forever. Best-effort and fire-and-forget — a failure
  /// never breaks the guide. Manual-only (null ttl) never prunes: the
  /// cache never expires, so neither do its files. The feed file
  /// (`feed_*.xml`) is governed by its own TTL logic and is never
  /// touched here.
  Future<void> _pruneStalePersistedEpg(Duration? ttl) async {
    if (ttl == null || debugDisablePersistedEpg) return;
    try {
      final dir = await _epgCacheDir();
      if (!await dir.exists()) return;
      final cutoff = DateTime.now().subtract(ttl);
      // Recursive: per-channel files live in a per-connection
      // subdirectory (iptv_epg/<conn>/<safe>.json) — a non-recursive
      // listing only sees the subdirectory itself, never the files.
      await for (final entity in dir.list(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        try {
          if ((await entity.lastModified()).isBefore(cutoff)) await entity.delete();
        } catch (_) {
          // One unreadable file does not stop the prune.
        }
      }
    } catch (_) {
      // Best-effort: the guide never depends on the prune.
    }
  }

  /// Programs overlapping [from, to] (the guide's 6-hour window).
  static List<LiveTvProgram> _slice(List<LiveTvProgram> programs, DateTime from, DateTime to) {
    final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    return programs.where((p) => (p.endsAt ?? 0) > fromEpoch && (p.beginsAt ?? 0) < toEpoch).toList(growable: false);
  }

  /// Xtream EPG, TiviMate-style (build #8 Task 3): per-channel
  /// `get_short_epg` answers FIRST for the visible channel. If it has
  /// nothing for the channel, the login's big `xmltv.php` feed is fetched
  /// (one shared fetch for the whole catalog, deduped by
  /// [_xtreamXmltvGuide]) and matched by tvg-id — build #26 (R3): the
  /// feed used to start loading in the background on EVERY channel fetch,
  /// even when short-EPG answered, which downloaded + parsed ~150 MB for
  /// nobody. The old order — xmltv first — made every visible row wait on
  /// a 55k-channel file (tens of MB, up to 120s) before showing anything.
  /// A channel is never left blank by a missing or partial feed — and a
  /// fetch only THROWS when both sources fail: if either source answers
  /// (even empty), that answer stands, so a genuine empty is never
  /// misread as a failure.
  Future<({List<LiveTvProgram> programs, IptvEpgSource source})> _fetchXtreamEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl,
  ) async {
    // Build #28: this channel's fetch owns an AbortController, so a row
    // that scrolls away (or the app backgrounding) stops it instead of
    // letting it run to completion unobserved. The shared feed download
    // is NOT aborted by it — other visible rows may still need it (see
    // [cancelEpgFetchForChannel]).
    final abort = AbortController();
    _epgAbortsByChannel[channelKey] = abort;
    _activeEpgAborts.add(abort);
    try {
      return await _fetchXtreamEpgWithAbort(channelKey, settings, from, to, ttl, abort);
    } finally {
      _activeEpgAborts.remove(abort);
      if (identical(_epgAbortsByChannel[channelKey], abort)) {
        _epgAbortsByChannel.remove(channelKey);
      }
    }
  }

  Future<({List<LiveTvProgram> programs, IptvEpgSource source})> _fetchXtreamEpgWithAbort(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl,
    AbortController abort,
  ) async {
    // Build #26 (R3): the feed is fetched LAZILY — only when
    // get_short_epg misses or fails for this channel. The old code
    // started the big feed download unconditionally, in the background,
    // on every channel fetch, even when short-EPG answered the row — a
    // ~150 MB download + a whole-document parse for nobody, on every
    // stale channel visit. Concurrent misses still share ONE download:
    // [_xmltvGuideForKey] dedups in-flight fetches per key.
    List<LiveTvProgram>? shortEpg;
    try {
      shortEpg = await _fetchXtreamShortEpg(channelKey, settings, from, to, abort.trigger);
    } catch (e) {
      // A cancellation is not a failure — the row scrolled away or the
      // app backgrounded. Do not fall through to the feed: the fetch is
      // over, and waiting on a download nobody watches is the waste
      // this cancel exists to stop.
      if (MediaServerHttpException.from(e).isCancellation) rethrow;
      appLogger.w('IPTV: get_short_epg failed for channel $channelKey; using xmltv.php', error: e);
    }
    if (shortEpg != null && shortEpg.isNotEmpty) {
      return (programs: shortEpg, source: IptvEpgSource.shortEpg);
    }
    // get_short_epg had nothing (or failed): use the feed, starting it
    // now. A feed that loads but has nothing for the channel returns
    // [] (genuine empty); a feed that fails only throws when get_short_epg
    // never answered — both sources failed.
    //
    // Build #28: a cancel that landed after get_short_epg answered is
    // honoured here, before waiting on the feed — the row scrolled away
    // or the app backgrounded, and the feed is a download nobody watches.
    abort.throwIfAborted();
    try {
      return await _fetchXtreamXmltvPrograms(channelKey, settings, from, to, ttl);
    } catch (e) {
      if (shortEpg != null) {
        // Build #28: a feed deferred while a stream is playing is not
        // a failure — it is the gate doing its job, and it retries when
        // playback stops. Logging it per row would spam the log while
        // the user watches with the guide open. A genuine feed failure
        // while playing is silent here for the same reason: the feed is
        // re-attempted when idle, and the panel error is already in the
        // refusal recorder.
        if (!IptvPlaybackActivity.instance.isPlaying) {
          appLogger.w(
            'IPTV: xmltv.php fetch failed for channel $channelKey; get_short_epg already answered empty',
            error: e,
          );
        }
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
    Future<void>? abortTrigger,
  ) async {
    await _acquireShortEpgSlot();
    // Build #26 (26.8): the first-paint timeout abandons the future but
    // must ALSO abort the underlying 60 s request — otherwise the socket
    // runs to its timeout unobserved. The abort is local to this call:
    // firing the channel's own controller here would trip the
    // throwIfAborted() in the caller and break the feed fallback.
    final firstPaintAbort = AbortController();
    final effectiveTrigger = abortTrigger == null
        ? firstPaintAbort.trigger
        : Future.any([abortTrigger, firstPaintAbort.trigger]);
    try {
      final listings = await _client.xtreamApi
          .getShortEpg(channelKey, limit: 500, timeout: const Duration(seconds: 60), abortTrigger: effectiveTrigger)
          .timeout(
            shortEpgFirstPaintTimeout,
            onTimeout: () {
              firstPaintAbort.abort();
              throw TimeoutException('get_short_epg first-paint timeout for $channelKey');
            },
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
  /// Start a shared feed download (build #28): the download owns an
  /// AbortController, registered in [_activeEpgAborts] so
  /// [cancelBackgroundWork] can stop it when the app backgrounds. The
  /// controller is removed when the download settles. The [fetchStream]
  /// receives the controller's trigger — the Xtream feed aborts at the
  /// socket (see [XtreamApi.getXmltvStream]); the M3U feed aborts at the
  /// socket too (see [_xmltvGuide]).
  Future<_CachedXmltvGuide> _startXmltvDownload(
    String cacheKey,
    Stream<List<int>> Function(Future<void>? abortTrigger) fetchStream,
  ) {
    final abort = AbortController();
    _activeEpgAborts.add(abort);
    final future = _loadXmltvGuide(cacheKey, () => fetchStream(abort.trigger));
    unawaited(
      future.then<void>((_) {}).catchError((_) {}).whenComplete(() => _activeEpgAborts.remove(abort)),
    );
    return future;
  }

  Future<_CachedXmltvGuide> _xmltvGuideForKey(
    String cacheKey,
    Stream<List<int>> Function(Future<void>? abortTrigger) fetchStream,
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
      // Build #28: while a stream is playing, do NOT start the refresh
      // download — the stale guide answers and the refresh waits until
      // playback stops. A new feed download on top of viewing traffic is
      // exactly the background work that gets a one-connection line
      // blocked.
      if (IptvPlaybackActivity.instance.isPlaying) return cached;
      final future = _startXmltvDownload(cacheKey, fetchStream);
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
        // Build #28: while a stream is playing, the persisted feed
        // answers and the refresh download waits — see the stale-cache
        // branch above.
        if (IptvPlaybackActivity.instance.isPlaying) return persisted;
        // Build #26: a concurrent caller may have started the refresh
        // while this one read the persisted file — share it instead of
        // starting a second download for the same key.
        if (_xmltvGuideFutures[cacheKey] != null) return persisted;
        final future = _startXmltvDownload(cacheKey, fetchStream);
        _xmltvGuideFutures[cacheKey] = future;
        unawaited(
          future.then<void>((_) {}).catchError((_) {}).whenComplete(() {
            _xmltvGuideFutures.removeWhere((key, value) => key == cacheKey && identical(value, future));
          }),
        );
      }
      return persisted;
    }

    // Fully cold: one shared download, as before — unless a stream is
    // playing (build #28): then there is no guide to serve and no
    // download starts. The caller falls back to get_short_epg (or an
    // empty guide) and the feed loads when playback stops.
    if (IptvPlaybackActivity.instance.isPlaying) {
      throw StateError('XMLTV feed for $cacheKey deferred while a stream is playing');
    }
    // Build #26: a concurrent caller may have started the download while
    // this one read the persisted file — share it instead of starting a
    // second one. Without this, N cold rows each download the feed and
    // tee to the same temp file (the old code had the same gap, hidden
    // because concurrent writeAsString calls to one path never errored).
    final inFlightAfterRead = _xmltvGuideFutures[cacheKey];
    if (inFlightAfterRead != null) return inFlightAfterRead;
    final future = _startXmltvDownload(cacheKey, fetchStream);
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

  /// Download + stream-parse the XMLTV feed for [cacheKey] (build #26).
  ///
  /// The response bytes are tee'd to a temp file while [parseXmltvStream]
  /// yields programmes — the whole feed is never held as a String, DOM,
  /// or isolate copy. The temp file is promoted to the persisted feed
  /// only when the parse completes successfully, preserving the old
  /// "only a parseable feed is persisted" invariant: a failed or
  /// cancelled download deletes the temp file and keeps the previously
  /// persisted feed (if any). A partial in-memory guide is never served
  /// as whole — on failure the partial list is discarded and the error
  /// is recorded exactly as a failed download was.
  Future<_CachedXmltvGuide> _loadXmltvGuide(String cacheKey, Stream<List<int>> Function() fetchStream) async {
    final programs = <XmltvProgram>[];
    // Tee the raw bytes to a temp file in the same directory, so the
    // promote is a same-filesystem rename. Skipped entirely when the
    // persisted side is disabled for tests. If the temp file cannot even
    // be located (the cache directory is unavailable), the download still
    // parses in memory and serves — persistence is best-effort, never a
    // reason to lose the guide (the pre-#26 path parsed in memory and
    // only the write could fail).
    File? tempFile;
    if (!debugDisablePersistedEpg) {
      try {
        tempFile = await _xmltvTempFeedFile(cacheKey);
      } catch (e) {
        appLogger.w('IPTV EPG feed cache unavailable for $cacheKey; parsing in memory', error: e);
      }
    }
    // Synchronous file I/O throughout (build #26): async dart:io never
    // completes inside testWidgets fake async (proven by probe: an
    // awaited File.exists() hangs, existsSync() works), and the fetch
    // path is awaited by widget tests — so an awaited create/write/
    // rename here would hang the guide in the harness. The parse loop
    // itself stays async (it awaits the byte stream, not the disk).
    // A tee that cannot be set up degrades to in-memory parsing, same as
    // the location fallback above — persistence never loses the guide.
    RandomAccessFile? raf;
    if (tempFile != null) {
      try {
        tempFile.parent.createSync(recursive: true);
        raf = tempFile.openSync(mode: FileMode.write);
      } catch (e) {
        appLogger.w('IPTV EPG feed cache unavailable for $cacheKey; parsing in memory', error: e);
        raf = null;
      }
    }
    try {
      final stream = fetchStream();
      await for (final program in parseXmltvStream(stream.map((chunk) {
        raf?.writeFromSync(chunk);
        return chunk;
      }))) {
        programs.add(program);
      }
      raf?.closeSync();
      raf = null;
    } catch (e) {
      // Build #28: a cancellation is not a failure — the app backgrounded
      // or the feed was stopped, not refused. It must not poison the
      // negative cache, or the next guide fetch would refuse to download
      // the feed for 120 s.
      try {
        raf?.closeSync();
      } catch (_) {
        // Best-effort: the file is gone or already closed.
      }
      try {
        if (tempFile != null && tempFile.existsSync()) tempFile.deleteSync();
      } catch (_) {
        // Best-effort: the temp file is gone or already deleted.
      }
      if (!MediaServerHttpException.from(e).isCancellation) {
        _xmltvFailedAt[cacheKey] = DateTime.now();
      }
      rethrow;
    }
    // Parse completed: the temp file holds exactly the bytes parsed, so
    // promote it to the persisted feed. A rename failure must not lose
    // the parsed guide — the in-memory guide still serves this launch,
    // and the next cold start re-downloads.
    if (tempFile != null) {
      try {
        final feedFile = await _xmltvFeedFile(cacheKey);
        if (feedFile.existsSync()) feedFile.deleteSync();
        tempFile.renameSync(feedFile.path);
      } catch (e) {
        appLogger.w('IPTV EPG feed cache write failed for $cacheKey', error: e);
      }
    }
    final guide = _CachedXmltvGuide(programs: programs, fetchedAt: DateTime.now());
    _xmltvCache[cacheKey] = guide;
    _xmltvFailedAt.remove(cacheKey);
    return guide;
  }

  /// Temp file the feed download is tee'd to while parsing (build #26):
  /// promoted to the persisted feed only on a successful parse. The
  /// `.tmp` suffix (not `.xml`) keeps it invisible to the feed-file
  /// helpers, which look for `*.xml`.
  Future<File> _xmltvTempFeedFile(String cacheKey) async {
    final dir = await _epgCacheDir();
    return File('${dir.path}/feed_${_fileSafe(cacheKey)}.tmp');
  }

  /// The persisted XMLTV feed file for [cacheKey]
  /// (`feed_<base64url(key)>.xml` next to the per-channel files). The raw
  /// bytes are stored, not the parsed guide — parsing streams from the
  /// file on read (build #26), same as on download.
  Future<File> _xmltvFeedFile(String cacheKey) async {
    final dir = await _epgCacheDir();
    return File('${dir.path}/feed_${_fileSafe(cacheKey)}.xml');
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
      if (!file.existsSync()) return null;
      // Build #26: stream-parse the file instead of reading the whole
      // body into a String and parsing it in an isolate — the cold-start
      // path held the whole feed ~4x at once (~1.45 GB peak RSS at Trex
      // scale). A corrupt file (including a truncated one) throws here
      // and is deleted below, exactly as before. Synchronous reads (see
      // _loadXmltvGuide): async dart:io never completes inside
      // testWidgets fake async, and this read is awaited on the fetch
      // path — the 64 KB sync chunks keep the streaming property (no
      // whole-file String) without touching the event loop.
      final programs = <XmltvProgram>[];
      await for (final program in parseXmltvStream(_readFileInChunks(file))) {
        programs.add(program);
      }
      return _CachedXmltvGuide(programs: programs, fetchedAt: file.lastModifiedSync());
    } catch (_) {
      try {
        if (file != null && file.existsSync()) file.deleteSync();
      } catch (_) {
        // Best-effort: the file is gone or unreadable anyway.
      }
      return null;
    }
  }

  /// A file as a byte stream read in 64 KB synchronous chunks (build
  /// #26): the streaming parser needs a [Stream], but async file reads
  /// never complete inside testWidgets fake async — sync reads do, and
  /// the generator only yields between chunks, so the whole file is
  /// never held in memory at once.
  static Stream<List<int>> _readFileInChunks(File file) async* {
    final raf = file.openSync();
    try {
      while (true) {
        final chunk = raf.readSync(65536);
        if (chunk.isEmpty) break;
        yield chunk;
      }
    } finally {
      raf.closeSync();
    }
  }

  /// The M3U connection's user-supplied EPG URL, as a parsed guide.
  Future<_CachedXmltvGuide> _xmltvGuide(String epgUrl, {Duration? ttl}) {
    return _xmltvGuideForKey(epgUrl, (abortTrigger) => _m3uFeedStream(epgUrl, abortTrigger), ttl);
  }

  /// The M3U feed as a byte stream (build #26): the old bare `http.get`
  /// buffered the whole body, and its abort only raced the get — the
  /// socket could finish in the background. An [AbortableRequest] aborts
  /// at the socket (as the Xtream feed does), and the short-lived client
  /// is closed when the stream ends, errors, or is cancelled, so an
  /// abandoned download never holds a socket open.
  Stream<List<int>> _m3uFeedStream(String epgUrl, Future<void>? abortTrigger) async* {
    final client = http.Client();
    try {
      final request = http.AbortableRequest('GET', Uri.parse(epgUrl), abortTrigger: abortTrigger);
      final streamed = await client.send(request).timeout(const Duration(seconds: 120));
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw StateError('XMLTV fetch failed with HTTP ${streamed.statusCode}');
      }
      yield* streamed.stream.timeout(const Duration(seconds: 120));
    } finally {
      client.close();
    }
  }

  /// The Xtream login's `xmltv.php` feed, as a parsed guide. One guide per
  /// connection (the support is per-client), fetched lazily on the first
  /// channel that needs it and shared by the rest of the guide.
  Future<_CachedXmltvGuide> _xtreamXmltvGuide({Duration? ttl}) {
    return _xmltvGuideForKey(
      'xtream:${_client.connection.id}',
      (abortTrigger) => _client.xtreamApi.getXmltvStream(abortTrigger: abortTrigger),
      ttl,
    );
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

  /// Build #28: on a one-connection line the next stream must wait for
  /// this one to be released (see [LiveTvPlaybackSession
  /// .requiresReleaseBeforeOpen]). The limit is the client's cached
  /// `max_connections` — unknown until the health probe runs, and
  /// unknown means wait.
  @override
  bool get requiresReleaseBeforeOpen => client.isSingleConnection;

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

  /// The live open carries the configured Xtream User-Agent alongside the
  /// language header (build #22): the panel sees the same identity on the
  /// stream as on the API calls. Delegates to the client so a Settings
  /// change applies to the next open; covers the live edge and the
  /// timeshift URL alike, since both open through this session.
  @override
  Map<String, String> get streamHeaders => {'Accept-Language': 'en', ...client.streamHeaders};

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
  // Stays a no-op (build #28): there is no panel disconnect/logout
  // endpoint — no peer sends one — so the session owns nothing releasable.
  // The release IS the awaited player stop (the release gate), not this.
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
