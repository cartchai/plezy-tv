import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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

  /// Parsed XMLTV files, keyed by EPG URL (M3U only).
  final Map<String, _CachedXmltvGuide> _xmltvCache = {};

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

  /// Whether the update-on-start refresh has run for this support instance
  /// (one instance per client per app launch).
  bool _startupRefreshDone = false;

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
  /// overlapping [from, to] is returned. A per-channel failure fails open
  /// (empty list — the guide renders hour placeholders for that channel)
  /// and never crashes the guide.
  Future<List<LiveTvProgram>> fetchEpgForChannel(
    String channelKey, {
    required DateTime from,
    required DateTime to,
  }) async {
    final settings = await _readEpgSettings();
    final now = DateTime.now();

    // Update-on-start forces one fresh fetch per channel on the first guide
    // open after launch, even inside the interval. The cache is in-memory,
    // so the first fetch after launch is fresh anyway; this matters when the
    // app was backgrounded and resumed with a warm cache. It also lifts a
    // "Clear guide", since the user asked for a refresh on start.
    final forceRefresh = settings.updateOnStart && !_startupRefreshDone;
    _startupRefreshDone = true;
    if (_epgCleared && !forceRefresh) return const <LiveTvProgram>[];
    if (forceRefresh) _epgCleared = false;

    final fetchFrom = now.subtract(Duration(days: settings.pastDays));
    final fetchTo = now.add(Duration(days: settings.daysToLoad));
    final ttl = settings.updateIntervalHours <= 0
        ? null // Manual only: the cache never expires on its own.
        : Duration(hours: settings.updateIntervalHours);

    final cached = _epgCache[channelKey];
    if (cached != null && cached.covers(from, to) && cached.isFresh(ttl) && !forceRefresh) {
      return _slice(cached.programs, from, to);
    }

    List<LiveTvProgram> programs;
    try {
      programs = _isXtream
          ? await _fetchXtreamEpg(channelKey, settings, fetchFrom, fetchTo)
          : await _fetchM3uEpg(channelKey, settings, fetchFrom, fetchTo);
    } catch (e) {
      appLogger.w('IPTV EPG fetch failed for channel $channelKey', error: e);
      return const [];
    }

    _epgCache[channelKey] = _CachedChannelEpg(
      programs: programs,
      fetchedAt: now,
      windowFrom: fetchFrom,
      windowTo: fetchTo,
    );
    _lastEpgUpdatedAt = now;
    _noteEpgUpdated(now);
    return _slice(programs, from, to);
  }

  /// Programs overlapping [from, to] (the guide's 6-hour window).
  static List<LiveTvProgram> _slice(List<LiveTvProgram> programs, DateTime from, DateTime to) {
    final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    return programs
        .where((p) => (p.endsAt ?? 0) > fromEpoch && (p.beginsAt ?? 0) < toEpoch)
        .toList(growable: false);
  }

  Future<List<LiveTvProgram>> _fetchXtreamEpg(
    String channelKey,
    _EpgSettings settings,
    DateTime from,
    DateTime to,
  ) async {
    // One channel's listings only — never the whole catalog. Limit 500
    // covers ~10 days of half-hour slots; anything past the limit simply
    // does not appear (placeholders fill the gap) instead of failing.
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
  ) async {
    final connection = _client.connection;
    if (connection is! M3uConnection) return const [];
    final epgUrl = connection.epgUrl;
    if (epgUrl == null || epgUrl.isEmpty) return const [];
    // The XMLTV `channel` attribute matches the entry's tvg-id, which is
    // also the M3U channel key when present.
    final tvgId = _client.tvgIdForChannelKey(channelKey);
    if (tvgId == null) return const [];
    final all = await _xmltvGuide(epgUrl);
    final fromEpoch = from.millisecondsSinceEpoch ~/ 1000;
    final toEpoch = to.millisecondsSinceEpoch ~/ 1000;
    final offsetSeconds = settings.timeOffsetMinutes * 60;
    final programs = <LiveTvProgram>[];
    for (final entry in all) {
      if (entry.channelId != tvgId) continue;
      final beginsAt = entry.startEpoch + offsetSeconds;
      final endsAt = entry.stopEpoch + offsetSeconds;
      if (endsAt <= beginsAt || endsAt <= fromEpoch || beginsAt >= toEpoch) continue;
      programs.add(
        LiveTvProgram(
          key: 'epg:m3u:$tvgId:$beginsAt',
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

  /// The provider's XMLTV file, parsed once per URL and cached with the
  /// same TTL as channel EPG (a re-fetch re-parses). Parsing runs in an
  /// isolate — provider files run to megabytes.
  Future<List<XmltvProgram>> _xmltvGuide(String epgUrl) async {
    final cached = _xmltvCache[epgUrl];
    if (cached != null && DateTime.now().difference(cached.fetchedAt) < const Duration(hours: 24)) {
      return cached.programs;
    }
    final response = await http.get(Uri.parse(epgUrl)).timeout(const Duration(seconds: 120));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('XMLTV fetch failed with HTTP ${response.statusCode}');
    }
    final programs = await compute(parseXmltv, response.body);
    _xmltvCache[epgUrl] = _CachedXmltvGuide(programs: programs, fetchedAt: DateTime.now());
    return programs;
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

  bool covers(DateTime from, DateTime to) => !windowFrom.isAfter(from) && !windowTo.isBefore(to);

  bool isFresh(Duration? ttl) => ttl == null || DateTime.now().difference(fetchedAt) < ttl;
}

/// One parsed XMLTV file, with its fetch time.
class _CachedXmltvGuide {
  final List<XmltvProgram> programs;
  final DateTime fetchedAt;

  const _CachedXmltvGuide({required this.programs, required this.fetchedAt});
}
