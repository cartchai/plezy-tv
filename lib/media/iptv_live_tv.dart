import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

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
import '../services/iptv/iptv_epg_sources.dart';
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

/// The XMLTV feed download was deferred by the playback gate (build #28,
/// 1.1.2 D1b): no feed exists yet and a stream is playing. This is NOT a
/// failure and NOT a genuine empty — the fetch returns empty without
/// caching, so the channel reloads when playback stops. It extends
/// [StateError] with the same message the gate has always thrown, so
/// existing message-based handling still matches.
class _EpgFeedDeferred extends StateError {
  _EpgFeedDeferred(String cacheKey) : super('XMLTV feed for $cacheKey deferred while a stream is playing');
}

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

  /// Channels with programmes per configured source id (PlezTV 1.2.0) —
  /// the per-source breakdown of the coverage diagnostic (§3.4). Only
  /// entries that recorded a source id are counted.
  final Map<String, int> bySourceId;

  const IptvGuideCoverage({
    required this.total,
    required this.withPrograms,
    required this.fromFeedById,
    required this.fromFeedByName,
    required this.fromShortEpg,
    required this.none,
    required this.unknown,
    required this.feedChannelIds,
    this.bySourceId = const {},
  });

  const IptvGuideCoverage.empty()
    : total = 0,
      withPrograms = 0,
      fromFeedById = 0,
      fromFeedByName = 0,
      fromShortEpg = 0,
      none = 0,
      unknown = 0,
      feedChannelIds = 0,
      bySourceId = const {};

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
    : _favoritesRepository = favoritesRepository ?? const SharedPreferencesFavoriteChannelsRepository() {
    // D1b (1.1.2): the playback-gate deferral used to claim "it retries
    // when playback stops" while nothing listened for playback stopping
    // (isPlayingNotifier had zero listeners). This listener is the
    // missing half: when playback stops and any channel was deferred,
    // the guide version bumps so visible rows re-fetch instead of
    // showing hour blocks until the next window change.
    IptvPlaybackActivity.instance.isPlayingNotifier.addListener(_onPlaybackActivityChanged);
  }

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
  /// Xtream login's `xmltv.php` feed (see [_fetchFeedPrograms]).
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

  /// `get_short_epg` page size: the panel returns at most this many
  /// listings per call, with no total/count — so exactly this many
  /// means the answer may be truncated (1.2.1 D4) and the feed tail
  /// must fill the days the limit cut off.
  static const int _shortEpgLimit = 500;

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
  DateTime? _lastEpgAttemptPrefWrite;

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

  /// Channels whose feed was deferred by the playback gate (1.1.2 D1b):
  /// the fetch returned empty without caching. Cleared when playback
  /// stops (the listener bumps the guide version) and by
  /// [clearEpgCache].
  final Set<String> _deferredEpgChannels = {};

  /// The quiet-hour boundary this support instance already refreshed for
  /// (§3.3) — a refresh is once per boundary, not once per guide open.
  DateTime? _quietHourRefreshedFor;

  /// D1b: when playback stops, channels deferred by the gate must
  /// reload. The guide watches [epgVersion] and re-fetches visible rows
  /// when it changes — bumping it here is what makes the deferred rows
  /// heal without a window change or an Update now.
  void _onPlaybackActivityChanged() {
    if (IptvPlaybackActivity.instance.isPlaying) return;
    if (_deferredEpgChannels.isEmpty) return;
    _deferredEpgChannels.clear();
    _epgVersion++;
  }

  /// Record a playback-gate deferral for [channelKey] (1.1.2 D1b).
  void _recordFeedDeferral(String channelKey) {
    _deferredEpgChannels.add(channelKey);
  }

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
  ///
  /// 1.1.2 D1a: "both sources failed" counts a feed that FAILS as
  /// failed — a feed that loads but has nothing for the channel is the
  /// only "answering empty". A playback-gate deferral (D1b) is neither:
  /// it returns [] without caching, and reloads when playback stops.
  /// [force] bypasses the feed's 5-minute negative cache (D8) — an
  /// explicit retry is not a storm. Only an explicit force bypasses it:
  /// a plain re-fetch after a failure still respects the negative cache
  /// (see iptv_epg_cache_test: a failed feed must not be re-downloaded
  /// per channel).
  /// (1.2.1 D7) A cached entry stamped from a feed generation that has
  /// since refreshed is stale even though its own clock is fresh — it
  /// refetches from the new feed, and a failed refetch still serves the
  /// old entry (stale-while-revalidate).
  Future<List<LiveTvProgram>> fetchEpgForChannel(
    String channelKey, {
    required DateTime from,
    required DateTime to,
    bool force = false,
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
    // D7: an entry stamped from a feed generation that has since been
    // superseded is stale even though its own clock is fresh — fall
    // through to a refetch, which re-maps from the new feed. The old
    // entry is kept so a failed refetch can still serve it (below).
    final servable = cached != null && cached.covers(from, to) && cached.isFresh(ttl) && !forceRefresh;
    final generationStale = servable && _isFeedGenerationStale(cached);
    if (servable && !generationStale) {
      return _slice(cached.programs, from, to);
    }

    // D9: an attempt happened even when the fetch fails or returns
    // empty — record it before the fetch, so "Last attempt" certifies
    // activity while "Last updated" certifies data (stamped below,
    // only when programmes were stored).
    _noteEpgAttempt(now);
    List<LiveTvProgram> programs;
    IptvEpgSource source;
    String? fetchedSourceId;
    String? fetchedMatchedXmltvId;
    String? fetchedMatchMethod;
    Map<String, DateTime> fetchedFeedGenerations;
    try {
      final fetched = _isXtream
          ? await _fetchXtreamEpg(channelKey, settings, fetchFrom, fetchTo, ttl, force: force)
          : await _fetchM3uEpg(channelKey, settings, fetchFrom, fetchTo, ttl, force: force);
      programs = fetched.programs;
      source = fetched.source;
      fetchedSourceId = fetched.sourceId;
      fetchedMatchedXmltvId = fetched.matchedXmltvId;
      fetchedMatchMethod = fetched.matchMethod;
      fetchedFeedGenerations = fetched.feedGenerations;
      if (fetched.feedDeferred) {
        // D1b: the feed was deferred by the playback gate — not a
        // failure and not a genuine empty. Return [] WITHOUT caching,
        // so the next fetch after playback stops downloads the feed.
        // The deferral is recorded (see _recordFeedDeferral) so the
        // idle listener bumps the guide version and the row re-fetches.
        return const <LiveTvProgram>[];
      }
      // A successful (non-deferred) fetch resolves the channel: it is
      // no longer a deferred one.
      _deferredEpgChannels.remove(channelKey);
    } catch (e) {
      if (generationStale) {
        // D7: the refetch after a feed refresh failed — serve the old
        // entry instead of a retry row (stale-while-revalidate: the
        // previous guide data beats nothing, and the refresh failure
        // does not invalidate it). The next fetch retries the refresh.
        appLogger.w('IPTV EPG refetch failed for channel $channelKey after a feed refresh; serving the previous entry', error: e);
        return _slice(cached.programs, from, to);
      }
      // Build #8 Task 3: a failed fetch must surface (see the doc comment
      // above) — swallowing it as [] recorded failures as loaded-empty.
      // A failed fetch writes no cache entry, so a retry refetches.
      appLogger.w('IPTV EPG fetch failed for channel $channelKey', error: e);
      rethrow;
    }

    final entry = _CachedChannelEpg(programs: programs, fetchedAt: now, windowFrom: fetchFrom, windowTo: fetchTo, source: source, sourceId: fetchedSourceId, matchedXmltvId: fetchedMatchedXmltvId, matchMethod: fetchedMatchMethod, feedGenerations: fetchedFeedGenerations);
    _epgCache[channelKey] = entry;
    // Best-effort and fire-and-forget: a failed write never breaks the
    // guide — the in-memory entry above still serves this launch — and
    // awaiting the disk write here would gate the guide on file I/O.
    // (The write still happens; it just doesn't hold the fetch open.)
    unawaited(_writePersistedEpg(channelKey, entry));
    unawaited(_pruneStalePersistedEpg(ttl));
    // D9: "Last updated" certifies DATA, not activity — stamp it only
    // when at least one programme was stored. An empty fetch (a genuine
    // empty, or a channel with no guide) leaves it alone.
    if (programs.isNotEmpty) {
      _lastEpgUpdatedAt = now;
      _noteEpgUpdated(now);
    }
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

  /// D7: true when [entry] was mapped from a feed generation that has
  /// since been superseded — either the in-memory guide for one of its
  /// feeds is newer than the stamped generation, or a refresh is in
  /// flight for one of its feeds right now (the refetch awaits it, so
  /// the new data is not missed while the download runs). Entries from
  /// short-EPG alone (empty generations) are never stale this way, and
  /// an entry whose feed is not loaded in memory cannot be judged — it
  /// serves (a cold guide has no newer generation to compare).
  bool _isFeedGenerationStale(_CachedChannelEpg entry) {
    for (final stamp in entry.feedGenerations.entries) {
      final current = _xmltvCache[stamp.key];
      if (current != null && current.fetchedAt.isAfter(stamp.value)) return true;
      if (_xmltvGuideFutures.containsKey(stamp.key)) return true;
    }
    return false;
  }

  /// Xtream EPG, TiviMate-style (build #8 Task 3): per-channel
  /// `get_short_epg` answers FIRST for the visible channel. If it has
  /// nothing for the channel, the login's big `xmltv.php` feed is fetched
  /// (one shared fetch for the whole catalog, deduped by
  /// [_fetchFeedPrograms]) and matched by tvg-id — build #26 (R3): the
  /// feed used to start loading in the background on EVERY channel fetch,
  /// even when short-EPG answered, which downloaded + parsed ~150 MB for
  /// nobody. The old order — xmltv first — made every visible row wait on
  /// a 55k-channel file (tens of MB, up to 120s) before showing anything.
  /// A channel is never left blank by a missing or partial feed — and a
  /// fetch only THROWS when both sources fail: if either source answers
  /// (even empty), that answer stands, so a genuine empty is never
  /// misread as a failure. 1.1.2 D1a: a feed that FAILS does not count
  /// as "answering" — only a feed that LOADS but has nothing for the
  /// channel answers empty. A playback-gate deferral is neither a
  /// failure nor an answer (see [_fetchXtreamEpgWithAbort]).
  /// (1.2.1 D4) A non-empty short-EPG answer at exactly the limit is
  /// treated as possibly truncated: the feed tail fills the days the
  /// limit cut off (see [_mergeFeedTail]).
  Future<({List<LiveTvProgram> programs, IptvEpgSource source, bool feedDeferred, String? sourceId, String? matchedXmltvId, String? matchMethod, Map<String, DateTime> feedGenerations})> _fetchXtreamEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl, {
    bool force = false,
  }) async {
    // Build #28: this channel's fetch owns an AbortController, so a row
    // that scrolls away (or the app backgrounding) stops it instead of
    // letting it run to completion unobserved. The shared feed download
    // is NOT aborted by it — other visible rows may still need it (see
    // [cancelEpgFetchForChannel]).
    final abort = AbortController();
    _epgAbortsByChannel[channelKey] = abort;
    _activeEpgAborts.add(abort);
    try {
      return await _fetchXtreamEpgWithAbort(channelKey, settings, from, to, ttl, abort, force: force);
    } finally {
      _activeEpgAborts.remove(abort);
      if (identical(_epgAbortsByChannel[channelKey], abort)) {
        _epgAbortsByChannel.remove(channelKey);
      }
    }
  }

  Future<({List<LiveTvProgram> programs, IptvEpgSource source, bool feedDeferred, String? sourceId, String? matchedXmltvId, String? matchMethod, Map<String, DateTime> feedGenerations})> _fetchXtreamEpgWithAbort(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl,
    AbortController abort, {
    bool force = false,
  }) async {
    // Build #26 (R3): the feed is fetched LAZILY — only when
    // get_short_epg misses or fails for this channel. The old code
    // started the big feed download unconditionally, in the background,
    // on every channel fetch, even when short-EPG answered the row — a
    // ~150 MB download + a whole-document parse for nobody, on every
    // stale channel visit. Concurrent misses still share ONE download:
    // [_xmltvGuideForKey] dedups in-flight fetches per key.
    List<LiveTvProgram>? shortEpg;
    bool shortEpgAtLimit = false;
    try {
      final fetched = await _fetchXtreamShortEpg(channelKey, settings, from, to, abort.trigger);
      shortEpg = fetched.programs;
      shortEpgAtLimit = fetched.atLimit;
    } catch (e) {
      // A cancellation is not a failure — the row scrolled away or the
      // app backgrounded. Do not fall through to the feed: the fetch is
      // over, and waiting on a download nobody watches is the waste
      // this cancel exists to stop.
      if (MediaServerHttpException.from(e).isCancellation) rethrow;
      appLogger.w('IPTV: get_short_epg failed for channel $channelKey; using xmltv.php', error: e);
    }
    if (shortEpg != null && shortEpg.isNotEmpty) {
      if (shortEpgAtLimit) {
        // D4: the panel answered exactly the limit, so the tail days
        // may be cut off — merge the feed's programmes for the part of
        // the window past the last short-EPG programme. A cancel that
        // landed while short-EPG answered is honoured before the merge
        // (same as the feed fallback below).
        abort.throwIfAborted();
        final merged = await _mergeFeedTail(channelKey, settings, shortEpg, from, to, ttl, force: force);
        return (programs: merged.programs, source: IptvEpgSource.shortEpg, feedDeferred: false, sourceId: null, matchedXmltvId: null, matchMethod: null, feedGenerations: merged.feedGenerations);
      }
      return (programs: shortEpg, source: IptvEpgSource.shortEpg, feedDeferred: false, sourceId: null, matchedXmltvId: null, matchMethod: null, feedGenerations: const <String, DateTime>{});
    }
    // get_short_epg had nothing (or failed): use the feed, starting it
    // now. A feed that loads but has nothing for the channel returns
    // [] (genuine empty); a feed that FAILS throws (1.1.2 D1a) — a
    // failed feed is not a source answering empty, even when
    // get_short_epg already answered empty.
    //
    // Build #28: a cancel that landed after get_short_epg answered is
    // honoured here, before waiting on the feed — the row scrolled away
    // or the app backgrounded, and the feed is a download nobody watches.
    abort.throwIfAborted();
    try {
      final feed = await _fetchFeedPrograms(channelKey, settings, from, to, ttl, force: force);
      if (feed.feedDeferred) {
        // D1b (now inside the multi-source fetch): every source deferred
        // by the playback gate — not a failure and not a genuine empty.
        // Return empty without caching; the deferral is already recorded
        // by _fetchFeedPrograms, so the idle listener bumps the guide
        // version and the channel reloads when playback stops.
        return (
          programs: const <LiveTvProgram>[],
          source: IptvEpgSource.none,
          feedDeferred: true,
          sourceId: null,
          matchedXmltvId: null,
          matchMethod: null,
          feedGenerations: const <String, DateTime>{},
        );
      }
      return (
        programs: feed.programs,
        source: feed.source,
        feedDeferred: false,
        sourceId: feed.sourceId,
        matchedXmltvId: feed.matchedXmltvId,
        matchMethod: feed.matchMethod,
        feedGenerations: feed.feedGenerations,
      );
    } catch (e) {
      // A cancellation is not a failure (build #28): the app
      // backgrounded mid-download. The gate test pins the old
      // behaviour here — a cancelled feed yields an empty guide, not
      // a throw — so keep returning [] for cancellations; only a
      // genuine feed FAILURE takes the D1a rethrow below.
      if (MediaServerHttpException.from(e).isCancellation) {
        return (
          programs: const <LiveTvProgram>[],
          source: IptvEpgSource.none,
          feedDeferred: false,
          sourceId: null,
          matchedXmltvId: null,
          matchMethod: null,
          feedGenerations: const <String, DateTime>{},
        );
      }
      if (shortEpg != null) {
        // D1a: get_short_epg ANSWERED (empty) and the feed FAILED. A
        // feed that fails is not a source "answering empty" — the
        // build #8 invariant ("a fetch only throws when both sources
        // fail") is met: one source answered empty, the other failed,
        // so the fetch must surface as a failure (guide retry state),
        // not as loaded-empty hour blocks. The old code returned []
        // here and the caller cached it for the whole interval — the
        // phone symptom (every channel hour blocks, no retry state).
        if (!IptvPlaybackActivity.instance.isPlaying) {
          appLogger.w(
            'IPTV: xmltv.php fetch failed for channel $channelKey; get_short_epg already answered empty',
            error: e,
          );
        }
        rethrow;
      }
      rethrow;
    }
  }

  /// D4: short-EPG answered exactly the limit, so the tail days may be
  /// cut off — merge the feed's programmes for the window past the last
  /// short-EPG programme. The feed is consulted only for the uncovered
  /// part ([lastShortEnd, to]); a feed programme starting before the
  /// frontier is dropped, so the same show never renders twice (short
  /// and feed keys differ). A feed that fails or defers loses only the
  /// tail — the short-EPG programmes are real and still served. A
  /// cancellation is not a failure: it rethrows, like the feed fallback.
  Future<({List<LiveTvProgram> programs, Map<String, DateTime> feedGenerations})> _mergeFeedTail(
    String channelKey,
    _EpgSettings settings,
    List<LiveTvProgram> shortEpg,
    DateTime from,
    DateTime to,
    Duration? ttl, {
    bool force = false,
  }) async {
    final lastShortEnd = shortEpg.map((p) => p.endsAt ?? 0).reduce((a, b) => a > b ? a : b);
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    if (lastShortEnd >= toEpoch) return (programs: shortEpg, feedGenerations: const <String, DateTime>{});
    final tailFrom = DateTime.fromMillisecondsSinceEpoch(lastShortEnd * 1000);
    try {
      final feed = await _fetchFeedPrograms(channelKey, settings, tailFrom, to, ttl, force: force);
      if (feed.feedDeferred || feed.programs.isEmpty) {
        return (programs: shortEpg, feedGenerations: feed.feedGenerations);
      }
      final tail = feed.programs.where((p) => (p.beginsAt ?? 0) >= lastShortEnd).toList(growable: false);
      if (tail.isEmpty) return (programs: shortEpg, feedGenerations: feed.feedGenerations);
      final merged = [...shortEpg, ...tail];
      merged.sort((a, b) => (a.beginsAt ?? 0).compareTo(b.beginsAt ?? 0));
      return (programs: merged, feedGenerations: feed.feedGenerations);
    } catch (e) {
      if (MediaServerHttpException.from(e).isCancellation) rethrow;
      return (programs: shortEpg, feedGenerations: const <String, DateTime>{});
    }
  }

  /// Programmes for one channel out of the connection's XMLTV feeds —
  /// the provider feed plus any enabled third-party sources, in priority
  /// order (PlezTV 1.2.0, §3.1). Per source: a manual assignment is
  /// tried first, then the channel's tvg-id, then its normalized name.
  /// The first source with data wins (TiviMate Premium model); the
  /// "added sources take precedence" toggle puts the added sources
  /// first. A source that fails is recorded in its status and skipped —
  /// a failed source never blocks the next one. A feed that loads but
  /// has nothing for the channel is a genuine empty; a feed that FAILS
  /// (and no source loaded) throws, like the single-feed path did
  /// (1.1.2 D1a). A playback-gate deferral on every source is neither:
  /// it returns [feedDeferred] and nothing is cached (D1b).
  Future<({List<LiveTvProgram> programs, IptvEpgSource source, bool feedDeferred, String? sourceId, String? matchedXmltvId, String? matchMethod, Map<String, DateTime> feedGenerations})> _fetchFeedPrograms(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl, {
    bool force = false,
  }) async {
    final attempts = await _epgSourceAttempts();
    if (attempts.isEmpty) {
      return (
        programs: const <LiveTvProgram>[],
        source: IptvEpgSource.none,
        feedDeferred: false,
        sourceId: null,
        matchedXmltvId: null,
        matchMethod: null,
        feedGenerations: const <String, DateTime>{},
      );
    }
    final mappings = await _epgStore.loadMappings();
    final mapping = mappings[channelKey];
    final epgChannelId = _client.epgChannelIdForChannelKey(channelKey);
    final tvgId = _client.tvgIdForChannelKey(channelKey);
    final channelName = _client.channelNameForChannelKey(channelKey);
    var sawDeferred = false;
    var anyLoaded = false;
    Object? lastError;
    StackTrace? lastStackTrace;
    // D7: the feed generations consulted for this channel (cache key ->
    // that guide's fetch time), so the per-channel entry can be stamped
    // with the generation it was mapped from.
    final generations = <String, DateTime>{};
    for (final attempt in attempts) {
      _CachedXmltvGuide guide;
      try {
        final started = DateTime.now();
        final (loaded, loadedFresh) = await _loadSourceGuide(attempt.cacheKey, attempt.fetchStream, ttl, force: force);
        guide = loaded;
        anyLoaded = true;
        if (loadedFresh) {
          await _recordSourceSuccess(attempt.config, attempt.cacheKey, guide, started);
        }
      } on _EpgFeedDeferred {
        sawDeferred = true;
        continue;
      } catch (e, st) {
        // A cancellation is not a failure (build #28): the row scrolled
        // away or the app backgrounded — the fetch is over, not a reason
        // to try the next source's download.
        if (MediaServerHttpException.from(e).isCancellation) rethrow;
        lastError = e;
        lastStackTrace = st;
        await _recordSourceFailure(attempt.config, e);
        continue;
      }
      generations[attempt.cacheKey] = guide.fetchedAt;
      if (guide.byChannel.length > _lastXmltvFeedChannelIds) {
        _lastXmltvFeedChannelIds = guide.byChannel.length;
      }
      final match = _matchInGuide(
        guide,
        channelKey,
        mapping,
        attempt.config.id,
        epgChannelId,
        tvgId,
        channelName,
        settings,
        from,
        to,
        keyPrefix: attempt.keyPrefix,
        offsetMinutes: attempt.config.timeShiftMinutes,
      );
      if (match == null) continue;
      return (
        programs: match.programs,
        source: match.matchMethod == 'name' ? IptvEpgSource.feedByName : IptvEpgSource.feedById,
        feedDeferred: false,
        sourceId: attempt.config.id,
        matchedXmltvId: match.matchedXmltvId,
        matchMethod: match.matchMethod,
        feedGenerations: generations,
      );
    }
    if (!anyLoaded) {
      if (sawDeferred) {
        // Every source deferred — the caller returns an uncached empty
        // (D1b), and the deferral is recorded so the idle listener bumps
        // the guide version and the row re-fetches when playback stops.
        _recordFeedDeferral(channelKey);
        return (
          programs: const <LiveTvProgram>[],
          source: IptvEpgSource.none,
          feedDeferred: true,
          sourceId: null,
          matchedXmltvId: null,
          matchMethod: null,
          feedGenerations: const <String, DateTime>{},
        );
      }
      if (lastError != null) Error.throwWithStackTrace(lastError, lastStackTrace ?? StackTrace.empty);
    }
    return (
      programs: const <LiveTvProgram>[],
      source: IptvEpgSource.none,
      feedDeferred: false,
      sourceId: null,
      matchedXmltvId: null,
      matchMethod: null,
      feedGenerations: generations,
    );
  }

  /// The match chain for one loaded guide (shared by the fetch path, the
  /// local details probe, and the without-guide computation): a manual
  /// assignment for this source first, then the tvg-id, then the
  /// normalized name. Null when nothing in this guide serves the channel
  /// in the window.
  ({List<LiveTvProgram> programs, String matchedXmltvId, String matchMethod})? _matchInGuide(
    _CachedXmltvGuide guide,
    String channelKey,
    IptvEpgMapping? mapping,
    String? sourceId,
    String? epgChannelId,
    String? tvgId,
    String? channelName,
    _EpgSettings settings,
    DateTime from,
    DateTime to, {
    required String keyPrefix,
    int? offsetMinutes,
  }) {
    if (mapping != null && mapping.sourceId == sourceId) {
      final mapped = _mapXmltvPrograms(
        guide.byChannel[mapping.xmltvId] ?? const [],
        channelKey,
        settings,
        from,
        to,
        keyPrefix: keyPrefix,
        offsetMinutes: offsetMinutes,
      );
      if (mapped.isNotEmpty) {
        return (programs: mapped, matchedXmltvId: mapping.xmltvId, matchMethod: 'manual');
      }
    }
    // The tvg-id candidates, in the old order: Xtream tries its
    // `epg_channel_id` then the stream id (the key); M3U tries its
    // tvg-id, which IS the key when present. One list covers both.
    final candidates = <String>{?epgChannelId, ?tvgId, channelKey}.toList(growable: false);
    for (final id in candidates) {
      final programs = _mapXmltvPrograms(
        guide.byChannel[id] ?? const [],
        channelKey,
        settings,
        from,
        to,
        keyPrefix: keyPrefix,
        offsetMinutes: offsetMinutes,
      );
      if (programs.isNotEmpty) {
        return (programs: programs, matchedXmltvId: id, matchMethod: 'tvg-id');
      }
    }
    if (channelName != null && channelName.isNotEmpty) {
      final byName = guide.byNormalizedName[normalizeEpgChannelName(channelName)] ?? const [];
      final programs = _mapXmltvPrograms(
        byName,
        channelKey,
        settings,
        from,
        to,
        keyPrefix: keyPrefix,
        offsetMinutes: offsetMinutes,
      );
      if (programs.isNotEmpty) {
        return (programs: programs, matchedXmltvId: byName.first.channelId, matchMethod: 'name');
      }
    }
    return null;
  }

  /// One feed fetch per enabled source, in priority order (PlezTV 1.2.0,
  /// §3.1): the provider feed plus every enabled user-added source.
  /// [keyPrefix] names the source in programme keys (`xtream` for the
  /// provider feed, `m3u` for a playlist guide, `user` for added ones)
  /// so a programme served by an added source never collides with the
  /// provider's key for the same channel+start.
  Future<List<_EpgSourceAttempt>> _epgSourceAttempts() async {
    final userSources = await _epgStore.loadUserSources();
    final enabled = userSources.where((s) => s.enabled).toList(growable: false);
    final provider = _providerSourceAttempt();
    final added = enabled
        .map(
          (s) => _EpgSourceAttempt(
            config: s,
            cacheKey: 'user:${s.id}',
            keyPrefix: 'user',
            fetchStream: (abortTrigger) => _m3uFeedStream(s.url!, abortTrigger),
          ),
        )
        .toList(growable: false);
    final addedFirst = await _epgStore.loadAddedSourcesFirst();
    if (addedFirst) return [...added, ?provider];
    return [?provider, ...added];
  }

  /// The provider feed's fetch (Xtream: the login's `xmltv.php`; M3U:
  /// the playlist's declared EPG URL). Null when the connection has no
  /// provider feed (an M3U playlist without a declared URL).
  _EpgSourceAttempt? _providerSourceAttempt() {
    if (_isXtream) {
      return _EpgSourceAttempt(
        config: _providerConfig(),
        cacheKey: 'xtream:${_client.connection.id}',
        keyPrefix: 'xtream',
        fetchStream: (abortTrigger) => _client.xtreamApi.getXmltvStream(abortTrigger: abortTrigger),
      );
    }
    final connection = _client.connection;
    if (connection is M3uConnection && connection.epgUrl != null && connection.epgUrl!.isNotEmpty) {
      final url = connection.epgUrl!;
      return _EpgSourceAttempt(
        config: _providerConfig(),
        cacheKey: url,
        keyPrefix: 'm3u',
        fetchStream: (abortTrigger) => _m3uFeedStream(url, abortTrigger),
      );
    }
    return null;
  }

  IptvEpgSourceConfig _providerConfig() => const IptvEpgSourceConfig(
    id: IptvEpgSourceConfig.providerId,
    kind: IptvEpgSourceConfig.kindProvider,
    name: 'Provider guide',
  );

  /// Load one source's guide, saying whether it loaded fresh (a download
  /// or a persisted-file parse — the status-worthy event) or was served
  /// from the fresh in-memory cache. The stale-while-revalidate path
  /// returns the stale guide while the refresh runs in the background,
  /// so a serve is not a fresh load.
  Future<(_CachedXmltvGuide guide, bool loadedFresh)> _loadSourceGuide(
    String cacheKey,
    Stream<List<int>> Function(Future<void>? abortTrigger) fetchStream,
    Duration? ttl, {
    bool force = false,
  }) async {
    final before = _xmltvCache[cacheKey]?.fetchedAt;
    final guide = await _xmltvGuideForKey(cacheKey, fetchStream, ttl, force: force);
    return (guide, before == null || guide.fetchedAt != before);
  }

  /// Record a fresh source load in the per-source status (§3.1): last
  /// success, programmes + channels stored, feed size, fetch duration.
  /// A success clears a previous failure — the chip goes green again.
  Future<void> _recordSourceSuccess(
    IptvEpgSourceConfig config,
    String cacheKey,
    _CachedXmltvGuide guide,
    DateTime started,
  ) async {
    final size = await _xmltvFeedFileSize(cacheKey);
    final statuses = await _epgStore.loadStatuses();
    final status = statuses[config.id] ?? IptvEpgSourceStatus.empty;
    await _epgStore.saveStatus(
      config.id,
      status.copyWith(
        lastSuccess: DateTime.now(),
        clearFailure: true,
        programs: guide.programs.length,
        channels: guide.byChannel.length,
        sizeBytes: size,
        durationMs: DateTime.now().difference(started).inMilliseconds,
      ),
    );
  }

  /// Record a failed source load in the per-source status (§3.1): last
  /// failure + reason. The previous success (if any) stays, so the chip
  /// can say "failed since ...".
  Future<void> _recordSourceFailure(IptvEpgSourceConfig config, Object error) async {
    final statuses = await _epgStore.loadStatuses();
    final status = statuses[config.id] ?? IptvEpgSourceStatus.empty;
    await _epgStore.saveStatus(
      config.id,
      status.copyWith(lastFailure: DateTime.now(), lastFailureReason: error.toString()),
    );
  }

  /// The persisted feed file's size in bytes (0 when the feed is not
  /// persisted — tests disable the persisted side, and a memory-only
  /// guide has no file). Best-effort, never throws.
  Future<int> _xmltvFeedFileSize(String cacheKey) async {
    if (debugDisablePersistedEpg) return 0;
    try {
      final file = await _xmltvFeedFile(cacheKey);
      if (!file.existsSync()) return 0;
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
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
  /// Returns the mapped programmes plus whether the panel answered
  /// exactly [_shortEpgLimit] listings — with no total/count, that is
  /// the only truncation signal (1.2.1 D4): the answer may be cut off
  /// and the feed tail must fill the missing days.
  Future<({List<LiveTvProgram> programs, bool atLimit})> _fetchXtreamShortEpg(
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
          .getShortEpg(channelKey, limit: _shortEpgLimit, timeout: const Duration(seconds: 60), abortTrigger: effectiveTrigger)
          .timeout(
            shortEpgFirstPaintTimeout,
            onTimeout: () {
              firstPaintAbort.abort();
              throw TimeoutException('get_short_epg first-paint timeout for $channelKey');
            },
          );
      final atLimit = listings.length == _shortEpgLimit;
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
      return (programs: programs, atLimit: atLimit);
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

  /// Programmes for one channel out of the playlist's XMLTV guide —
  /// the provider feed plus any enabled third-party sources, in
  /// priority order (PlezTV 1.2.0, §3.1). A channel with no tvg-id
  /// still tries the name fallback (1.2.1 D2): the Xtream path tries
  /// byId then byName, and the M3U path does the same — an id-less
  /// playlist entry matches the feed by its name.
  Future<({List<LiveTvProgram> programs, IptvEpgSource source, bool feedDeferred, String? sourceId, String? matchedXmltvId, String? matchMethod, Map<String, DateTime> feedGenerations})> _fetchM3uEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl, {
    bool force = false,
  }) async {
    final connection = _client.connection;
    if (connection is! M3uConnection) {
      return (
        programs: const <LiveTvProgram>[],
        source: IptvEpgSource.none,
        feedDeferred: false,
        sourceId: null,
        matchedXmltvId: null,
        matchMethod: null,
        feedGenerations: const <String, DateTime>{},
      );
    }
    final attempts = await _epgSourceAttempts();
    if (attempts.isEmpty) {
      return (
        programs: const <LiveTvProgram>[],
        source: IptvEpgSource.none,
        feedDeferred: false,
        sourceId: null,
        matchedXmltvId: null,
        matchMethod: null,
        feedGenerations: const <String, DateTime>{},
      );
    }
    return _fetchFeedPrograms(channelKey, settings, from, to, ttl, force: force);
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
    int? offsetMinutes,
  }) {
    final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    final offsetSeconds = (offsetMinutes ?? settings.timeOffsetMinutes) * 60;
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
    Duration? ttl, {
    bool force = false,
  }) async {
    bool fresh(_CachedXmltvGuide guide) => ttl == null || DateTime.now().difference(guide.fetchedAt) < ttl;

    final cached = _xmltvCache[cacheKey];
    if (cached != null && fresh(cached)) return cached;

    // A failed download is remembered briefly: don't start another 120s
    // download for a channel whose feed just failed — the caller falls
    // back to get_short_epg / tap-to-retry instead. A stale guide still
    // beats nothing.
    // D8: an explicit retry (force) bypasses the remembered failure —
    // it is not a storm, so it attempts the download again instead of
    // failing fast for 5 minutes. A forced retry also forgets the
    // failure, so a later automatic fetch is not blocked by a failure
    // the retry already superseded.
    final failedAt = _xmltvFailedAt[cacheKey];
    if (failedAt != null) {
      if (force) {
        _xmltvFailedAt.remove(cacheKey);
      } else if (DateTime.now().difference(failedAt) < xmltvNegativeCacheTtl) {
        if (cached != null) return cached;
        throw StateError('XMLTV feed for $cacheKey failed recently; retry shortly');
      } else {
        _xmltvFailedAt.remove(cacheKey);
      }
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
      // D1b: a deferral is not a failure — the caller converts it to
      // an uncached empty instead of a cached loaded-empty.
      throw _EpgFeedDeferred(cacheKey);
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

  /// Bump on every cache clear so the guide can tell its per-channel state
  /// (loaded / failed) is stale and re-fetch visible rows.
  int get epgVersion => _epgVersion;

  /// Wall-clock time of the last EPG fetch that stored at least one
  /// programme on this client (1.1.2 D9), or null before the first one.
  /// The settings screen reads the stored pref
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
    final bySourceId = <String, int>{};
    for (final entry in _epgCache.values) {
      if (entry.programs.isEmpty) {
        none++;
        continue;
      }
      withPrograms++;
      if (entry.sourceId != null) {
        bySourceId[entry.sourceId!] = (bySourceId[entry.sourceId!] ?? 0) + 1;
      }
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
      bySourceId: bySourceId,
    );
  }

  /// Per-connection EPG sources store (§3.1/§3.2): user-added sources,
  /// the precedence toggle, manual mappings, per-source status, and the
  /// channel-list fingerprint. SharedPreferences-backed, keyed by
  /// connection id.
  IptvEpgSourcesStore get _epgStore => IptvEpgSourcesStore(_client.connection.id);

  /// The connection's sources in stored order: the provider feed first
  /// (when one exists — Xtream always, M3U only with a declared EPG
  /// URL), then added sources in the order the user arranged them. The
  /// provider cannot be removed, disabled, or moved.
  Future<List<IptvEpgSourceConfig>> epgSources() async {
    final user = await _epgStore.loadUserSources();
    final provider = _providerSourceAttempt();
    return [if (provider != null) _providerConfig(), ...user];
  }

  /// Add a third-party EPG source (§3.1): validate the URL first (fetch
  /// the first bytes and confirm it parses as XMLTV — user-initiated, so
  /// the SEARCH/STARTUP rules don't apply), then store it. Returns the
  /// stored config. Throws [StateError] with the reason when validation
  /// fails. The same URL may be added twice (different names — the
  /// reorder test does exactly that); each entry is its own source.
  Future<IptvEpgSourceConfig> addEpgSource(String url, {String? name, int? timeShiftMinutes}) async {
    final trimmed = url.trim();
    await validateEpgSourceUrl(trimmed);
    final uri = Uri.parse(trimmed);
    // A growable copy: the store returns an unmodifiable list.
    final sources = (await _epgStore.loadUserSources()).toList();
    final config = IptvEpgSourceConfig(
      id: IptvEpgSourceConfig.newUserId(),
      kind: IptvEpgSourceConfig.kindXmltv,
      url: trimmed,
      name: (name ?? '').trim().isEmpty ? uri.host : name!.trim(),
      timeShiftMinutes: timeShiftMinutes,
    );
    sources.add(config);
    await _epgStore.saveUserSources(sources);
    return config;
  }

  /// Change an added source (enable/disable, rename, time shift). The
  /// provider guide cannot be changed.
  Future<void> updateEpgSource(IptvEpgSourceConfig source) async {
    if (source.isProvider) throw ArgumentError('The provider guide cannot be changed');
    final sources = (await _epgStore.loadUserSources()).toList();
    final index = sources.indexWhere((s) => s.id == source.id);
    if (index < 0) throw ArgumentError('Unknown EPG source ${source.id}');
    sources[index] = source;
    await _epgStore.saveUserSources(sources);
  }

  /// Remove an added source. The provider guide cannot be removed. A
  /// removed source stays removed (IPTVnator rule), and its mappings go
  /// with it — a deleted source must not keep matching channels.
  Future<void> deleteEpgSource(String sourceId) async {
    if (sourceId == IptvEpgSourceConfig.providerId) {
      throw ArgumentError('The provider guide cannot be removed');
    }
    final sources = (await _epgStore.loadUserSources()).toList();
    sources.removeWhere((s) => s.id == sourceId);
    await _epgStore.saveUserSources(sources);
    final mappings = await _epgStore.loadMappings();
    mappings.removeWhere((_, mapping) => mapping.sourceId == sourceId);
    await _epgStore.saveMappings(mappings);
    final statuses = await _epgStore.loadStatuses();
    statuses.remove(sourceId);
    await _epgStore.saveStatuses(statuses);
  }

  /// Move an added source up ([delta] -1) or down (+1) in the priority
  /// order. No-op at the ends and for unknown ids. The provider feed
  /// never moves — the precedence toggle is what flips it below the
  /// added sources.
  Future<void> moveEpgSource(String sourceId, int delta) async {
    final sources = (await _epgStore.loadUserSources()).toList();
    final index = sources.indexWhere((s) => s.id == sourceId);
    if (index < 0) return;
    final target = (index + delta).clamp(0, sources.length - 1);
    if (target == index) return;
    final source = sources.removeAt(index);
    sources.insert(target, source);
    await _epgStore.saveUserSources(sources);
  }

  /// "Added sources take precedence over the provider guide" (IPTVnator
  /// toggle, §3.1). Default off — the provider feed first, added sources
  /// fill gaps (TiviMate Premium model).
  Future<bool> addedSourcesTakePrecedence() => _epgStore.loadAddedSourcesFirst();

  Future<void> setAddedSourcesTakePrecedence(bool value) => _epgStore.saveAddedSourcesFirst(value);

  /// Per-source status (§3.1): every known source has an entry (missing
  /// = never fetched). The UI reads the display state from each status
  /// with the update interval as the freshness bar.
  Future<Map<String, IptvEpgSourceStatus>> epgSourceStatuses() async {
    final stored = await _epgStore.loadStatuses();
    final sources = await epgSources();
    final out = <String, IptvEpgSourceStatus>{};
    for (final source in sources) {
      out[source.id] = stored[source.id] ?? IptvEpgSourceStatus.empty;
    }
    return out;
  }

  /// Validate an EPG source URL before adding it (§3.1): it must be an
  /// http(s) URL that answers 200 with bytes that parse as XMLTV. Only
  /// the first 256 KB are read — a multi-megabyte feed is never
  /// downloaded for validation. Throws [StateError] with the reason.
  Future<void> validateEpgSourceUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
      throw StateError('Not a valid http(s) URL');
    }
    final client = http.Client();
    try {
      final response = await client.send(http.Request('GET', uri)).timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('EPG source returned HTTP ${response.statusCode}');
      }
      const cap = 256 * 1024;
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(const Duration(seconds: 15))) {
        bytes.addAll(chunk);
        if (bytes.length >= cap) break;
      }
      _checkXmltvPrefix(bytes);
    } on StateError {
      rethrow;
    } catch (e) {
      throw StateError('Could not fetch the EPG source: $e');
    } finally {
      client.close();
    }
  }

  /// Confirm the first bytes of a would-be source parse as XMLTV. A
  /// complete small file must parse with a `<tv>` root; a truncated
  /// prefix (the file is bigger than the validation cap) is accepted
  /// when the cut is the only problem — the bytes so far parsed as XML
  /// up to the cut.
  static void _checkXmltvPrefix(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!text.contains('<tv')) throw StateError('Not an XMLTV file (no <tv> element)');
    try {
      final doc = XmlDocument.parse(text);
      if (doc.rootElement.name.local != 'tv') {
        throw StateError('Not an XMLTV file (root is not <tv>)');
      }
    } on XmlParserException catch (e) {
      final message = e.message.toLowerCase();
      if (!message.contains('end of input') && !message.contains('unexpected end')) rethrow;
      // The prefix parsed as XML up to the cut: accept.
    }
  }

  /// Assign an EPG to a channel by hand (§3.2, TiviMate's Assign EPG):
  /// this channel always uses this XMLTV channel id from this source.
  /// The mapping is consulted before the byId/byName chain and survives
  /// refreshes and catalog syncs. Throws [ArgumentError] for an empty id
  /// or an unknown source.
  Future<void> assignEpg(String channelKey, {required String xmltvId, required String sourceId}) async {
    if (xmltvId.trim().isEmpty) throw ArgumentError('An XMLTV channel id is required');
    final sources = await epgSources();
    if (sources.every((s) => s.id != sourceId)) throw ArgumentError('Unknown EPG source $sourceId');
    await _epgStore.saveMapping(channelKey, IptvEpgMapping(xmltvId: xmltvId.trim(), sourceId: sourceId));
  }

  /// Clear a manual assignment: the channel goes back to auto-matching.
  Future<void> clearEpgAssignment(String channelKey) => _epgStore.clearMapping(channelKey);

  /// The manual assignment for [channelKey], if one exists.
  Future<IptvEpgMapping?> epgAssignmentFor(String channelKey) async {
    final mappings = await _epgStore.loadMappings();
    return mappings[channelKey];
  }

  /// One channel's EPG assignment state (§3.2, the "see my assigned EPG"
  /// view): which source serves it, which XMLTV id matched, how it
  /// matched, programmes in the requested window, when it was fetched
  /// and when it expires — or, when it has nothing, why. A cached entry
  /// with programmes answers from the cache; otherwise the loaded feeds
  /// are probed locally (no network) — the channel may have guide that
  /// simply hasn't been fetched yet.
  Future<IptvChannelEpgDetail> channelEpgDetail(String channelKey, {DateTime? from, DateTime? to}) async {
    final settings = await _readEpgSettings();
    // Default window: the settings window, like the guide itself — callers
    // that already have a window (tests) pass it explicitly.
    final now = DateTime.now();
    from ??= now.subtract(Duration(days: settings.pastDays));
    to ??= now.add(Duration(days: settings.daysToLoad));
    final ttl = settings.updateIntervalHours <= 0 ? null : Duration(hours: settings.updateIntervalHours);
    final cached = _epgCache[channelKey] ?? await _readPersistedEpg(channelKey);
    if (cached != null) _epgCache[channelKey] = cached;
    if (cached != null && cached.programs.isNotEmpty) {
      final slice = _slice(cached.programs, from, to);
      return IptvChannelEpgDetail(
        channelKey: channelKey,
        channelName: _client.channelNameForChannelKey(channelKey),
        sourceId: cached.sourceId,
        sourceName: await _sourceName(cached.sourceId),
        matchedXmltvId: cached.matchedXmltvId,
        matchMethod: cached.matchMethod,
        programCount: slice.length,
        lastFetch: cached.fetchedAt,
        nextFetch: ttl == null ? null : cached.fetchedAt.add(ttl),
      );
    }
    final probe = await _probeLocalMatch(channelKey, settings, from, to);
    if (probe != null) return probe;
    return IptvChannelEpgDetail(
      channelKey: channelKey,
      channelName: _client.channelNameForChannelKey(channelKey),
      programCount: 0,
      lastFetch: cached?.fetchedAt,
      noGuideReason: await _noGuideReason(ttl),
    );
  }

  /// The local match probe for [channelEpgDetail]: the match chain
  /// against the feeds already loaded in memory (no network). Null when
  /// no loaded feed serves the channel in the window.
  Future<IptvChannelEpgDetail?> _probeLocalMatch(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
  ) async {
    final attempts = await _epgSourceAttempts();
    final mappings = await _epgStore.loadMappings();
    final mapping = mappings[channelKey];
    final epgChannelId = _client.epgChannelIdForChannelKey(channelKey);
    final tvgId = _client.tvgIdForChannelKey(channelKey);
    final channelName = _client.channelNameForChannelKey(channelKey);
    for (final attempt in attempts) {
      final guide = _xmltvCache[attempt.cacheKey];
      if (guide == null) continue;
      final match = _matchInGuide(
        guide,
        channelKey,
        mapping,
        attempt.config.id,
        epgChannelId,
        tvgId,
        channelName,
        settings,
        from,
        to,
        keyPrefix: attempt.keyPrefix,
        offsetMinutes: attempt.config.timeShiftMinutes,
      );
      if (match == null) continue;
      return IptvChannelEpgDetail(
        channelKey: channelKey,
        channelName: channelName,
        sourceId: attempt.config.id,
        sourceName: attempt.config.name,
        matchedXmltvId: match.matchedXmltvId,
        matchMethod: match.matchMethod,
        programCount: match.programs.length,
      );
    }
    return null;
  }

  /// The no-guide reason for a channel, derived from the feeds' state
  /// (shared by the details view and the without-guide overview): no
  /// enabled sources at all, nothing loaded (failed vs never tried), or
  /// feeds loaded but nothing matched.
  Future<IptvEpgNoGuideReason> _noGuideReason(Duration? ttl) async {
    final attempts = await _epgSourceAttempts();
    if (attempts.isEmpty) return IptvEpgNoGuideReason.noSource;
    final statuses = await _epgStore.loadStatuses();
    final loadedKeys = attempts
        .where((a) => _xmltvCache.containsKey(a.cacheKey))
        .map((a) => a.cacheKey)
        .toSet();
    return _reasonFor(attempts: attempts, loadedCacheKeys: loadedKeys, statuses: statuses, ttl: ttl);
  }

  IptvEpgNoGuideReason _reasonFor({
    required List<_EpgSourceAttempt> attempts,
    required Set<String> loadedCacheKeys,
    required Map<String, IptvEpgSourceStatus> statuses,
    required Duration? ttl,
  }) {
    if (attempts.isEmpty) return IptvEpgNoGuideReason.noSource;
    if (loadedCacheKeys.isEmpty) {
      final anyFailed = attempts.any((attempt) {
        final status = statuses[attempt.config.id];
        return status != null && status.state(enabled: attempt.config.enabled, ttl: ttl) == IptvEpgSourceState.failed;
      });
      return anyFailed ? IptvEpgNoGuideReason.sourceFailed : IptvEpgNoGuideReason.notLoaded;
    }
    return IptvEpgNoGuideReason.noMatch;
  }

  /// The display name for a source id ('Provider guide' for the
  /// provider feed, the stored name for an added one, the id itself
  /// when the source is gone — a deleted source's stale references
  /// still read).
  Future<String?> _sourceName(String? sourceId) async {
    if (sourceId == null) return null;
    if (sourceId == IptvEpgSourceConfig.providerId) return 'Provider guide';
    final sources = await _epgStore.loadUserSources();
    for (final source in sources) {
      if (source.id == sourceId) return source.name;
    }
    return sourceId;
  }

  /// Every XMLTV channel id in every enabled source's feed, for the
  /// Assign EPG picker (§3.2). The feeds load lazily on first need
  /// (user-initiated — opening Assign), exactly like the guide's lazy
  /// feed; a source that defers (playback gate) or fails contributes
  /// nothing. Search over the result is local, in the picker.
  Future<List<IptvEpgFeedChannel>> epgFeedChannels({bool forceRefresh = false}) async {
    final settings = await _readEpgSettings();
    final ttl = settings.updateIntervalHours <= 0 ? null : Duration(hours: settings.updateIntervalHours);
    final attempts = await _epgSourceAttempts();
    final loaded = await _loadEnabledFeeds(attempts, ttl, force: forceRefresh);
    final out = <IptvEpgFeedChannel>[];
    for (final entry in loaded) {
      for (final channel in entry.guide.byChannel.entries) {
        out.add(
          IptvEpgFeedChannel(
            sourceId: entry.attempt.config.id,
            sourceName: entry.attempt.config.name,
            xmltvId: channel.key,
            programCount: channel.value.length,
          ),
        );
      }
    }
    out.sort((a, b) => a.xmltvId.toLowerCase().compareTo(b.xmltvId.toLowerCase()));
    return out;
  }

  /// Every channel with no EPG (§3.2, the "see my assigned EPGs per
  /// channel" overview), grouped by reason by the caller. A channel
  /// counts as having guide when its per-channel cache holds programmes
  /// or any loaded feed matches it — the feeds load lazily on first
  /// need (user-initiated — opening the overview). Channels whose guide
  /// comes only from the provider's per-channel lookup are not listed
  /// until browsed; the overview says so.
  Future<List<IptvChannelWithoutGuide>> channelsWithoutGuide() async {
    final settings = await _readEpgSettings();
    final ttl = settings.updateIntervalHours <= 0 ? null : Duration(hours: settings.updateIntervalHours);
    final channels = await _client.iptvChannels();
    final attempts = await _epgSourceAttempts();
    final loaded = await _loadEnabledFeeds(attempts, ttl);
    final mappings = await _epgStore.loadMappings();
    final statuses = await _epgStore.loadStatuses();
    final reason = _reasonFor(
      attempts: attempts,
      loadedCacheKeys: loaded.map((e) => e.attempt.cacheKey).toSet(),
      statuses: statuses,
      ttl: ttl,
    );
    final now = DateTime.now();
    final from = now.subtract(Duration(days: settings.pastDays));
    final to = now.add(Duration(days: settings.daysToLoad));
    // Persisted per-channel entries, from one directory listing (not
    // one stat per channel — the catalog runs to tens of thousands).
    final persistedKeys = await _persistedEpgChannelKeys();
    final out = <IptvChannelWithoutGuide>[];
    for (final channel in channels) {
      final cached =
          _epgCache[channel.key] ??
          (persistedKeys.contains(channel.key) ? await _readPersistedEpg(channel.key) : null);
      if (cached != null) _epgCache[channel.key] = cached;
      if (cached != null && cached.programs.isNotEmpty) continue;
      if (_channelHasFeedMatch(channel.key, loaded, mappings, settings, from, to)) continue;
      out.add(
        IptvChannelWithoutGuide(channelKey: channel.key, channelName: channel.title ?? channel.key, reason: reason),
      );
    }
    return out;
  }

  /// True when any loaded feed serves [channelKey] in the window (by
  /// assignment, tvg-id, or name). Local only — no network.
  bool _channelHasFeedMatch(
    String channelKey,
    List<({ _EpgSourceAttempt attempt, _CachedXmltvGuide guide })> loaded,
    Map<String, IptvEpgMapping> mappings,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
  ) {
    final mapping = mappings[channelKey];
    final epgChannelId = _client.epgChannelIdForChannelKey(channelKey);
    final tvgId = _client.tvgIdForChannelKey(channelKey);
    final channelName = _client.channelNameForChannelKey(channelKey);
    for (final entry in loaded) {
      final match = _matchInGuide(
        entry.guide,
        channelKey,
        mapping,
        entry.attempt.config.id,
        epgChannelId,
        tvgId,
        channelName,
        settings,
        from,
        to,
        keyPrefix: entry.attempt.keyPrefix,
        offsetMinutes: entry.attempt.config.timeShiftMinutes,
      );
      if (match != null) return true;
    }
    return false;
  }

  /// The enabled sources' guides, loaded lazily (user-initiated callers
  /// only — Assign, Channels without guide, Reload TV details). A source
  /// that defers (playback gate) or fails contributes nothing; a fresh
  /// load records the source's status, a failure records its reason.
  Future<List<({ _EpgSourceAttempt attempt, _CachedXmltvGuide guide })>> _loadEnabledFeeds(
    List<_EpgSourceAttempt> attempts,
    Duration? ttl, {
    bool force = false,
  }) async {
    final loaded = <({ _EpgSourceAttempt attempt, _CachedXmltvGuide guide })>[];
    for (final attempt in attempts) {
      try {
        final started = DateTime.now();
        final (guide, loadedFresh) = await _loadSourceGuide(attempt.cacheKey, attempt.fetchStream, ttl, force: force);
        if (loadedFresh) {
          await _recordSourceSuccess(attempt.config, attempt.cacheKey, guide, started);
        }
        loaded.add((attempt: attempt, guide: guide));
      } on _EpgFeedDeferred {
        continue;
      } catch (e) {
        // A cancellation aborts the whole bulk load (the app
        // backgrounded); a failed source is recorded and skipped.
        if (MediaServerHttpException.from(e).isCancellation) rethrow;
        await _recordSourceFailure(attempt.config, e);
        continue;
      }
    }
    return loaded;
  }

  /// Channel keys with a persisted per-channel EPG file, from one
  /// directory listing. Best-effort — a failure reads as "none
  /// persisted", and the overview still works from memory + feeds.
  /// Skipped entirely when the persisted side is disabled for tests.
  Future<Set<String>> _persistedEpgChannelKeys() async {
    final out = <String>{};
    if (debugDisablePersistedEpg) return out;
    try {
      final dir = await _epgCacheDir();
      if (!await dir.exists()) return out;
      await for (final entity in dir.list()) {
        if (entity is! File || !entity.path.endsWith('.json')) continue;
        final key = _channelKeyFromFileName(entity.path.split('/').last);
        if (key != null) out.add(key);
      }
    } catch (_) {
      // Best-effort: the overview still works from memory + feeds.
    }
    return out;
  }

  /// Reload TV details (§3.2, Matt's original wording): re-fetch the
  /// channel list from the provider (not a full catalog sync — movies
  /// and series are untouched) and refresh the EPG for this connection,
  /// then report counts. The recovery action for D1-poisoned entries:
  /// it busts the per-channel cache the way Update now does.
  Future<IptvReloadTvDetailsResult> reloadTvDetails() async {
    final channels = await _client.refreshLiveChannelsFromNetwork();
    await refreshEpgCache();
    final settings = await _readEpgSettings();
    final ttl = settings.updateIntervalHours <= 0 ? null : Duration(hours: settings.updateIntervalHours);
    final attempts = await _epgSourceAttempts();
    final loaded = await _loadEnabledFeeds(attempts, ttl);
    final mappings = await _epgStore.loadMappings();
    final now = DateTime.now();
    final from = now.subtract(Duration(days: settings.pastDays));
    final to = now.add(Duration(days: settings.daysToLoad));
    var withGuide = 0;
    for (final channel in channels) {
      if (_channelHasFeedMatch(channel.key, loaded, mappings, settings, from, to)) withGuide++;
    }
    final feedChannelIds = loaded.expand((e) => e.guide.byChannel.keys).toSet().length;
    return IptvReloadTvDetailsResult(
      channelsLoaded: channels.length,
      withGuide: withGuide,
      withoutGuide: channels.length - withGuide,
      feedChannelIds: feedChannelIds,
    );
  }

  /// Refresh the guide when the quiet hour passed since the last data
  /// landed (§3.3, TiviMate's ~04:00 update time). An in-app interval
  /// check on guide open — never a background-job promise. Returns true
  /// when a refresh was triggered.
  Future<bool> maybeRefreshForQuietHour() async {
    final settings = await SettingsService.getInstance();
    final updateTime = settings.read(SettingsService.iptvEpgUpdateTimeMinutes);
    if (updateTime < 0) return false;
    final intervalHours = settings.read(SettingsService.iptvEpgUpdateIntervalHours);
    if (intervalHours <= 0) return false; // Manual only: never auto-refresh.
    final now = DateTime.now();
    var boundary = DateTime(now.year, now.month, now.day, updateTime ~/ 60, updateTime % 60);
    if (now.isBefore(boundary)) boundary = boundary.subtract(const Duration(days: 1));
    if (_quietHourRefreshedFor == boundary) return false;
    // Last data landed: this support's in-memory stamp, else the stored
    // pref (a relaunch clears the memory but not the pref).
    final stored = settings.read(SettingsService.iptvEpgLastUpdated);
    final lastData = _lastEpgUpdatedAt ?? DateTime.tryParse(stored);
    if (lastData != null && !lastData.isBefore(boundary)) return false;
    _quietHourRefreshedFor = boundary;
    await refreshEpgCache();
    return true;
  }

  /// Empty the EPG caches (Update now / Clear guide). The next guide visit
  /// re-fetches visible channels; the guide watches [epgVersion] to reset
  /// its own per-channel state.
  ///
  /// This is the "Clear guide" behaviour: [fetchEpgForChannel] stays empty
  /// until something refreshes ([refreshEpgCache] or the start-up refresh),
  /// so the guide shows "No information available" hour blocks.
  Future<void> clearEpgCache() async {
    _epgCache.clear();
    _xmltvCache.clear();
    _lastXmltvFeedChannelIds = 0;
    // A clear is an explicit retry: forget a failed feed too, so the next
    // guide visit downloads instead of hitting the negative cache.
    _xmltvFailedAt.clear();
    // A clear is a fresh start: forget playback-gate deferrals (D1b)
    // too — the guide re-fetches visible rows from scratch.
    _deferredEpgChannels.clear();
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

  /// Record the last EPG fetch ATTEMPT for the settings screen (1.1.2
  /// D9): an attempt happened even when the fetch failed or returned
  /// empty, so this stamp — unlike "Last updated" — certifies activity,
  /// not data. Throttled to one write per minute, like
  /// [_noteEpgUpdated]. Written before the fetch runs (see
  /// [fetchEpgForChannel]).
  void _noteEpgAttempt(DateTime now) {
    if (_lastEpgAttemptPrefWrite != null && now.difference(_lastEpgAttemptPrefWrite!).inSeconds < 60) return;
    _lastEpgAttemptPrefWrite = now;
    final stamp = now.toIso8601String();
    SettingsService.getInstance().then((settings) {
      settings.write(SettingsService.iptvEpgLastAttempt, stamp);
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

  /// Which configured source served these programmes (PlezTV 1.2.0):
  /// the provider feed (`'provider'`) or a user-added source id. Null
  /// for entries written before this build. Drives the EPG details view
  /// ("assigned source") and the per-source coverage breakdown.
  final String? sourceId;

  /// The XMLTV channel id that matched (or was manually assigned), and
  /// how it matched (`'tvg-id'`, `'name'`, `'manual'`). Null when nothing
  /// matched — the details view reads these, not a fresh fetch.
  final String? matchedXmltvId;
  final String? matchMethod;

  /// Feed generations this entry was mapped from (1.2.1 D7): the XMLTV
  /// cache key -> that guide's fetch time, for every feed consulted
  /// while fetching the channel. Empty when the entry came from
  /// short-EPG alone (or was written before this build). When a feed
  /// refreshes, entries stamped from the older generation are stale
  /// and must refetch instead of serving for the whole interval.
  final Map<String, DateTime> feedGenerations;

  const _CachedChannelEpg({
    required this.programs,
    required this.fetchedAt,
    required this.windowFrom,
    required this.windowTo,
    this.source = IptvEpgSource.unknown,
    this.sourceId,
    this.matchedXmltvId,
    this.matchMethod,
    this.feedGenerations = const {},
  });

  Map<String, dynamic> toJson() => {
    'fetchedAt': fetchedAt.toIso8601String(),
    'windowFrom': windowFrom.toIso8601String(),
    'windowTo': windowTo.toIso8601String(),
    'source': source.name,
    if (sourceId != null) 'sourceId': sourceId,
    if (matchedXmltvId != null) 'matchedXmltvId': matchedXmltvId,
    if (matchMethod != null) 'matchMethod': matchMethod,
    if (feedGenerations.isNotEmpty) 'feedGenerations': feedGenerations.map((k, v) => MapEntry(k, v.toIso8601String())),
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
    return _CachedChannelEpg(
      programs: programs,
      fetchedAt: fetchedAt,
      windowFrom: windowFrom,
      windowTo: windowTo,
      source: source,
      sourceId: json['sourceId'] as String?,
      matchedXmltvId: json['matchedXmltvId'] as String?,
      matchMethod: json['matchMethod'] as String?,
      feedGenerations: _feedGenerationsFromJson(json['feedGenerations']),
    );
  }

  static Map<String, DateTime> _feedGenerationsFromJson(Object? raw) {
    final out = <String, DateTime>{};
    if (raw is Map<String, dynamic>) {
      for (final entry in raw.entries) {
        final at = DateTime.tryParse(entry.value as String? ?? '');
        if (at != null) out[entry.key] = at;
      }
    }
    return out;
  }

  bool covers(DateTime from, DateTime to) => !windowFrom.isAfter(from) && !windowTo.isBefore(to);

  bool isFresh(Duration? ttl) => ttl == null || DateTime.now().difference(fetchedAt) < ttl;
}

/// One parsed XMLTV file, with its fetch time and an index of programmes
/// by channel id (the `<programme channel="...">` attribute), so serving
/// one channel out of a whole-catalog file is a lookup, not a scan.
/// One source's fetch, in priority order (PlezTV 1.2.0, §3.1): the
/// provider feed or an added source. [cacheKey] is the guide's key in
/// [_xmltvCache] (`xtream:<id>` for the provider feed, the EPG URL for
/// a playlist guide, `user:<id>` for an added source); [keyPrefix]
/// names the source in programme keys.
class _EpgSourceAttempt {
  final IptvEpgSourceConfig config;
  final String cacheKey;
  final String keyPrefix;
  final Stream<List<int>> Function(Future<void>? abortTrigger) fetchStream;

  const _EpgSourceAttempt({
    required this.config,
    required this.cacheKey,
    required this.keyPrefix,
    required this.fetchStream,
  });
}

class _CachedXmltvGuide {
  final List<XmltvProgram> programs;
  final DateTime fetchedAt;

  /// Dedupe by (channel, start) at import (1.2.1 D3, tvheadend model):
  /// a provider that re-publishes a programme must not render it
  /// twice. First-wins — the guide indexes programmes by the same key
  /// the mapper builds (`epg:<source>:<channel>:<beginsAt>`), so an
  /// exact duplicate would collide in the guide.
  _CachedXmltvGuide({required List<XmltvProgram> programs, required this.fetchedAt})
      : programs = _dedupePrograms(programs);

  static List<XmltvProgram> _dedupePrograms(List<XmltvProgram> programs) {
    final seen = <String>{};
    final kept = <XmltvProgram>[];
    for (final program in programs) {
      if (seen.add('${program.channelId}\n${program.startEpoch}')) {
        kept.add(program);
      }
    }
    return kept;
  }

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
