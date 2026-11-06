import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

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
    try {
      programs = _isXtream
          ? await _fetchXtreamEpg(channelKey, settings, fetchFrom, fetchTo, ttl)
          : await _fetchM3uEpg(channelKey, settings, fetchFrom, fetchTo, ttl);
    } catch (e) {
      // Build #8 Task 3: a failed fetch must surface (see the doc comment
      // above) — swallowing it as [] recorded failures as loaded-empty.
      // A failed fetch writes no cache entry, so a retry refetches.
      appLogger.w('IPTV EPG fetch failed for channel $channelKey', error: e);
      rethrow;
    }

    final entry = _CachedChannelEpg(
      programs: programs,
      fetchedAt: now,
      windowFrom: fetchFrom,
      windowTo: fetchTo,
    );
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
    return programs
        .where((p) => (p.endsAt ?? 0) > fromEpoch && (p.beginsAt ?? 0) < toEpoch)
        .toList(growable: false);
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
  Future<List<LiveTvProgram>> _fetchXtreamEpg(
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
      return shortEpg;
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
        return const [];
      }
      rethrow;
    }
  }

  /// Programmes for one channel out of the login's `xmltv.php` feed.
  /// The feed is fetched lazily (only when a channel's cached entry is
  /// stale or missing) and the parsed file is shared by every channel in
  /// the guide — never one fetch per channel. Matching is by the channel's
  /// tvg-id (`epg_channel_id`); some panels use the stream id as the XMLTV
  /// channel id, so that matches too.
  Future<List<LiveTvProgram>> _fetchXtreamXmltvPrograms(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl,
  ) async {
    final guide = await _xtreamXmltvGuide(ttl: ttl);
    final epgChannelId = _client.epgChannelIdForChannelKey(channelKey);
    final entries = <XmltvProgram>[];
    if (epgChannelId != null) entries.addAll(guide.byChannel[epgChannelId] ?? const []);
    if (epgChannelId != channelKey) entries.addAll(guide.byChannel[channelKey] ?? const []);
    return _mapXmltvPrograms(entries, channelKey, settings, from, to, keyPrefix: 'xtream');
  }

  /// One channel's `get_short_epg` listings — the fallback when the
  /// `xmltv.php` feed has nothing for the channel (or cannot be fetched).
  /// Limit 500 covers ~10 days of half-hour slots; anything past the limit
  /// simply does not appear (placeholders fill the gap) instead of failing.
  Future<List<LiveTvProgram>> _fetchXtreamShortEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
  ) async {
    final listings = await _client.xtreamApi.getShortEpg(
      channelKey,
      limit: 500,
      timeout: const Duration(seconds: 60),
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
  }

  Future<List<LiveTvProgram>> _fetchM3uEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
    Duration? ttl,
  ) async {
    final connection = _client.connection;
    if (connection is! M3uConnection) return const [];
    final epgUrl = connection.epgUrl;
    if (epgUrl == null || epgUrl.isEmpty) return const [];
    // The XMLTV `channel` attribute matches the entry's tvg-id, which is
    // also the M3U channel key when present.
    final tvgId = _client.tvgIdForChannelKey(channelKey);
    if (tvgId == null) return const [];
    final guide = await _xmltvGuide(epgUrl, ttl: ttl);
    return _mapXmltvPrograms(guide.byChannel[tvgId] ?? const [], channelKey, settings, from, to, keyPrefix: 'm3u');
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
  Future<_CachedXmltvGuide> _xmltvGuideForKey(
    String cacheKey,
    Future<String> Function() fetchBody,
    Duration? ttl,
  ) async {
    final cached = _xmltvCache[cacheKey];
    if (cached != null && (ttl == null || DateTime.now().difference(cached.fetchedAt) < ttl)) {
      return cached;
    }
    final inFlight = _xmltvGuideFutures[cacheKey];
    if (inFlight != null) return inFlight;
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
    final body = await fetchBody();
    final programs = await compute(parseXmltv, body);
    final guide = _CachedXmltvGuide(programs: programs, fetchedAt: DateTime.now());
    _xmltvCache[cacheKey] = guide;
    return guide;
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
  Future<String> buildFavoriteChannelSource({String? lineup}) async =>
      'server://${_client.connection.id}/iptv';

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
    return CaptureBuffer(
      startedAt: _startedAtEpoch,
      seekStartSeconds: -archiveDurationSeconds.toDouble(),
      seekEndSeconds: 0,
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
  }) async => null;

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

  const _CachedChannelEpg({
    required this.programs,
    required this.fetchedAt,
    required this.windowFrom,
    required this.windowTo,
  });

  Map<String, dynamic> toJson() => {
    'fetchedAt': fetchedAt.toIso8601String(),
    'windowFrom': windowFrom.toIso8601String(),
    'windowTo': windowTo.toIso8601String(),
    'programs': programs.map((p) => p.toJson()).toList(),
  };

  factory _CachedChannelEpg.fromJson(Map<String, dynamic> json) {
    final fetchedAt = DateTime.tryParse(json['fetchedAt'] as String? ?? '');
    final windowFrom = DateTime.tryParse(json['windowFrom'] as String? ?? '');
    final windowTo = DateTime.tryParse(json['windowTo'] as String? ?? '');
    if (fetchedAt == null || windowFrom == null || windowTo == null) {
      throw const FormatException('Invalid cached EPG entry');
    }
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
    );
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

  static Map<String, List<XmltvProgram>> _index(List<XmltvProgram> programs) {
    final map = <String, List<XmltvProgram>>{};
    for (final program in programs) {
      (map[program.channelId] ??= []).add(program);
    }
    return map;
  }
}
