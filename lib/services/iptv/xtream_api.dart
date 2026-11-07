import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import '../../utils/json_utils.dart';

/// Minimal Xtream Codes API client (player_api.php / get.php / xmltv.php).
///
/// Xtream has no canonical spec; the shapes below are the ones this
/// provider (and the common Xtream UI panel) actually returns. Numbers
/// frequently arrive as strings, so every numeric field is read through
/// [flexibleInt]/[flexibleDouble].
///
/// Credentials travel in the query string (that is how player_api.php
/// authenticates). They are never logged: request URIs are never passed to
/// [appLogger] and no field of this class is persisted.
class XtreamApi {
  final String serverUrl;
  final String username;
  final String password;
  final http.Client _http;

  XtreamApi({
    required String serverUrl,
    required this.username,
    required this.password,
    http.Client? httpClient,
  }) : serverUrl = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl,
       _http = httpClient ?? http.Client();

  void close() => _http.close();

  /// Raw response body of the most recent UNFILTERED catalog call, per
  /// dataset (build #13). The client caches this body verbatim on disk —
  /// it is exactly what the panel sent, so the disk cache re-parses
  /// through the same parsers — instead of re-encoding the parsed rows
  /// back to JSON on the UI isolate (jsonEncode of 199k VOD rows froze
  /// the UI for ~1.3s on first launch; benchmark
  /// `iptv_build13_cache_benchmark_test.dart`). Null when the last call
  /// was per-category (a per-category body is never the full catalog),
  /// when the call failed, or when a test fake overrides the getter
  /// without setting it — the client falls back to the re-encode write
  /// then. Read synchronously right after the awaited call returns; no
  /// other call can interleave on this isolate in between.
  String? lastLiveStreamsBody;
  String? lastVodStreamsBody;
  String? lastSeriesBody;

  Uri _playerApiUri({String? action, Map<String, String>? extra}) {
    return Uri.parse('$serverUrl/player_api.php').replace(
      queryParameters: {
        'username': username,
        'password': password,
        'action': ?action,
        ...?extra,
      },
    );
  }

  /// Fetch a response body with status checks. Shared by [_getJson] and the
  /// big catalog calls, which hand the body to an isolate for parsing
  /// instead of decoding it here (see [_parseLiveStreams] etc.).
  Future<String> _fetchBody(Uri uri, {Duration timeout = const Duration(seconds: 30)}) async {
    http.Response response;
    try {
      response = await _http.get(uri).timeout(timeout);
    } catch (e) {
      throw MediaServerHttpException.from(e, uri: uri);
    }
    if (response.statusCode == 401) {
      throw MediaServerAuthException('Xtream authentication failed', statusCode: 401);
    }
    if (response.statusCode == 403) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream access denied',
        statusCode: 403,
        requestUri: uri,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream request failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        requestUri: uri,
      );
    }
    return response.body;
  }

  Future<dynamic> _getJson(Uri uri, {Duration timeout = const Duration(seconds: 30)}) async {
    final body = await _fetchBody(uri, timeout: timeout);
    try {
      return jsonDecode(body);
    } on FormatException catch (e) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream returned unparseable JSON: $e',
        statusCode: 200,
        requestUri: uri,
      );
    }
  }

  Future<String> _getText(Uri uri, {Duration timeout = const Duration(seconds: 30)}) async {
    http.Response response;
    try {
      response = await _http.get(uri).timeout(timeout);
    } catch (e) {
      throw MediaServerHttpException.from(e, uri: uri);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream request failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        requestUri: uri,
      );
    }
    return response.body;
  }

  static List<Map<String, dynamic>> _asObjectList(dynamic decoded) {
    if (decoded is List) return decoded.whereType<Map<String, dynamic>>().toList();
    return const [];
  }

  /// Auth probe: no action. Returns the raw `user_info` map, or null when
  /// the payload has none (login rejected).
  Future<Map<String, dynamic>?> getUserInfo() async {
    final decoded = await _getJson(_playerApiUri());
    if (decoded is Map<String, dynamic>) {
      final info = decoded['user_info'];
      if (info is Map<String, dynamic>) return info;
    }
    return null;
  }

  Future<List<XtreamCategory>> getLiveCategories() async {
    final decoded = await _getJson(_playerApiUri(action: 'get_live_categories'));
    return _asObjectList(decoded).map(XtreamCategory.fromJson).toList();
  }

  Future<List<XtreamCategory>> getVodCategories() async {
    final decoded = await _getJson(_playerApiUri(action: 'get_vod_categories'));
    return _asObjectList(decoded).map(XtreamCategory.fromJson).toList();
  }

  Future<List<XtreamCategory>> getSeriesCategories() async {
    final decoded = await _getJson(_playerApiUri(action: 'get_series_categories'));
    return _asObjectList(decoded).map(XtreamCategory.fromJson).toList();
  }

  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async {
    // The full live list is tens of thousands of rows; give it two minutes
    // on slow connections instead of the 30s default, and parse it off the
    // UI thread — decoding tens of thousands of rows on the main isolate
    // freezes the app for seconds.
    final body = await _fetchBody(
      _playerApiUri(action: 'get_live_streams', extra: categoryId == null ? null : {'category_id': categoryId}),
      timeout: const Duration(seconds: 120),
    );
    lastLiveStreamsBody = categoryId == null ? body : null;
    return compute(_parseLiveStreams, body);
  }

  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async {
    // The full VOD list is ~200k rows (tens of MB of JSON). Same treatment
    // as the live list: a long timeout and isolate parsing, so opening
    // Movies does not hang or time out on a slow connection.
    final body = await _fetchBody(
      _playerApiUri(action: 'get_vod_streams', extra: categoryId == null ? null : {'category_id': categoryId}),
      timeout: const Duration(seconds: 120),
    );
    lastVodStreamsBody = categoryId == null ? body : null;
    return compute(_parseVodStreams, body);
  }

  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    final body = await _fetchBody(
      _playerApiUri(action: 'get_series', extra: categoryId == null ? null : {'category_id': categoryId}),
      timeout: const Duration(seconds: 120),
    );
    lastSeriesBody = categoryId == null ? body : null;
    return compute(_parseSeries, body);
  }

  /// Full series detail: info + per-season episode lists.
  Future<XtreamSeriesInfo> getSeriesInfo(int seriesId) async {
    final decoded = await _getJson(_playerApiUri(action: 'get_series_info', extra: {'series_id': '$seriesId'}));
    if (decoded is! Map<String, dynamic>) {
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream get_series_info returned an unexpected payload',
      );
    }
    return XtreamSeriesInfo.fromJson(decoded);
  }

  /// Short EPG for one stream (up to [limit] listings). Titles and
  /// descriptions arrive Base64-encoded; they are decoded here, falling
  /// back to the raw string when decoding fails.
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout}) async {
    final decoded = await _getJson(
      _playerApiUri(action: 'get_short_epg', extra: {'stream_id': streamId, 'limit': '$limit'}),
      timeout: timeout ?? const Duration(seconds: 30),
    );
    if (decoded is! Map<String, dynamic>) return const [];
    final listings = decoded['epg_listings'];
    if (listings is! List) return const [];
    return listings.whereType<Map<String, dynamic>>().map(XtreamEpgProgram.fromJson).toList();
  }

  /// Simple data table (now/next + archive flags per stream). Returned raw;
  /// callers pick what they need.
  Future<Map<String, dynamic>?> getSimpleDataTable() async {
    final decoded = await _getJson(_playerApiUri(action: 'get_simple_data_table'));
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  /// Full XMLTV guide (large — callers fetch it only when the guide is
  /// actually being browsed). 120s: the file runs to megabytes and a slow
  /// connection legitimately takes a while to deliver it.
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120)}) =>
      _getText(Uri.parse('$serverUrl/xmltv.php?username=$username&password=$password'), timeout: timeout);

/// Parse helpers for the disk cache (build #11): a cached payload is the
/// same JSON the API returns, so it parses through the same isolate
/// parsers as the network path — one parse shape, no second model.
/// Categories are small (<1k rows), so they parse inline.
static Future<List<XtreamLiveStream>> parseLiveStreamsBody(String body) => compute(_parseLiveStreams, body);

static Future<List<XtreamVodStream>> parseVodStreamsBody(String body) => compute(_parseVodStreams, body);

static Future<List<XtreamSeries>> parseSeriesBody(String body) => compute(_parseSeries, body);

static List<XtreamCategory> parseCategoriesBody(String body) =>
    _asObjectList(_decodeCatalogJson(body)).map(XtreamCategory.fromJson).toList();
  /// M3U playlist export for this account.
  Future<String> getM3u({String type = 'm3u_plus', String output = 'ts'}) => _getText(
    Uri.parse('$serverUrl/get.php').replace(
      queryParameters: {'username': username, 'password': password, 'type': type, 'output': output},
    ),
  );

  // -- Stream URL builders (direct play, no transcode) ---------------------

  String liveStreamUrl(String streamId) => '$serverUrl/live/$username/$password/$streamId.m3u8';

  String movieStreamUrl(String streamId, String containerExtension) {
    final ext = containerExtension.isEmpty ? 'mp4' : containerExtension;
    return '$serverUrl/movie/$username/$password/$streamId.$ext';
  }

  String seriesStreamUrl(String episodeId, String containerExtension) {
    final ext = containerExtension.isEmpty ? 'mp4' : containerExtension;
    return '$serverUrl/series/$username/$password/$episodeId.$ext';
  }

  /// Catch-up URL. [durationMinutes] is the requested window length in
  /// minutes; [start] is the programme start, formatted
  /// `YYYY-MM-DD:HH-MM-SS` in UTC (the panel's convention).
  String timeshiftUrl({required String streamId, required int durationMinutes, required DateTime start}) {
    final utc = start.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${utc.year}-${two(utc.month)}-${two(utc.day)}:${two(utc.hour)}-${two(utc.minute)}-${two(utc.second)}';
    return '$serverUrl/timeshift/$username/$password/$durationMinutes/$stamp/$streamId.m3u8';
  }
}

/// Top-level catalog parsers for [compute]: the big Xtream lists are tens
/// of thousands of rows, and decoding + mapping them on the UI thread
/// freezes the app for seconds. These run on a background isolate; a
/// malformed body surfaces as the same [MediaServerHttpException] the
/// inline path used to throw, so callers see no difference.
dynamic _decodeCatalogJson(String body) {
  try {
    return jsonDecode(body);
  } on FormatException catch (e) {
    throw MediaServerHttpException(
      type: MediaServerHttpErrorType.unknown,
      message: 'Xtream returned unparseable JSON: $e',
    );
  }
}

/// One malformed row must not discard a whole catalog: the real provider's
/// 46k-row series list contains mistyped fields (e.g. a numeric `cover`),
/// and the old `.map(X.fromJson)` parse threw the entire list away — Movies
/// loaded while Series showed nothing. Each row parses independently now.
List<XtreamLiveStream> _parseLiveStreams(String body) =>
    parseFlexibleJsonList(_decodeCatalogJson(body), XtreamLiveStream.fromJson);

List<XtreamVodStream> _parseVodStreams(String body) =>
    parseFlexibleJsonList(_decodeCatalogJson(body), XtreamVodStream.fromJson);

List<XtreamSeries> _parseSeries(String body) =>
    parseFlexibleJsonList(_decodeCatalogJson(body), XtreamSeries.fromJson);

class XtreamCategory {
  final String id;
  final String name;
  final String? parentId;

  const XtreamCategory({required this.id, required this.name, this.parentId});

  factory XtreamCategory.fromJson(Map<String, dynamic> json) {
    return XtreamCategory(
      id: stringOrEmpty(json['category_id']),
      name: (json['category_name'] as String?) ?? '',
      parentId: json['parent_id']?.toString(),
    );
  }

  /// API-shaped map (build #11): the disk cache stores the same JSON the
  /// API returns, so a cached payload re-parses through [fromJson].
  Map<String, dynamic> toJson() => {'category_id': id, 'category_name': name, 'parent_id': parentId};
}

class XtreamLiveStream {
  final int streamId;
  final String name;
  final String? streamIcon;
  final String? epgChannelId;
  final String? categoryId;
  final bool tvArchive;
  final int tvArchiveDuration; // seconds the archive reaches back

  /// Xtream's `tv_archive_duration` is the catch-up window in DAYS
  /// (provider docs: "for how many days", example 7) — convert to seconds
  /// here so every downstream use (seek window, timeshift clamp) sees
  /// seconds. A value no panel would express in days (> 366) is already
  /// seconds and passes through unchanged.
  static int archiveDurationSeconds(int raw) => raw > 366 ? raw : raw * 24 * 3600;

  const XtreamLiveStream({
    required this.streamId,
    required this.name,
    this.streamIcon,
    this.epgChannelId,
    this.categoryId,
    this.tvArchive = false,
    this.tvArchiveDuration = 0,
  });

  factory XtreamLiveStream.fromJson(Map<String, dynamic> json) {
    return XtreamLiveStream(
      streamId: flexibleInt(json['stream_id']) ?? 0,
      name: (json['name'] as String?) ?? '',
      streamIcon: json['stream_icon'] as String?,
      epgChannelId: json['epg_channel_id'] as String?,
      categoryId: json['category_id']?.toString(),
      tvArchive: flexibleInt(json['tv_archive']) == 1,
      tvArchiveDuration: archiveDurationSeconds(flexibleInt(json['tv_archive_duration']) ?? 0),
    );
  }

  /// API-shaped map (build #11) — see [XtreamCategory.toJson].
  /// `tv_archive_duration` is stored in seconds (as held on this object):
  /// a seconds value above 366 passes through [fromJson] unchanged, so
  /// this round-trips (a 7-day archive is 604800s, not 7).
  Map<String, dynamic> toJson() => {
    'stream_id': streamId,
    'name': name,
    'stream_icon': streamIcon,
    'epg_channel_id': epgChannelId,
    'category_id': categoryId,
    'tv_archive': tvArchive ? 1 : 0,
    'tv_archive_duration': tvArchiveDuration,
  };
}

class XtreamVodStream {
  final int streamId;
  final String name;
  final String? streamIcon;
  final String? cover;
  final double? rating;
  final String? categoryId;
  final String containerExtension;
  final int? added;

  const XtreamVodStream({
    required this.streamId,
    required this.name,
    this.streamIcon,
    this.cover,
    this.rating,
    this.categoryId,
    this.containerExtension = 'mp4',
    this.added,
  });

  factory XtreamVodStream.fromJson(Map<String, dynamic> json) {
    return XtreamVodStream(
      streamId: flexibleInt(json['stream_id']) ?? 0,
      name: (json['name'] as String?) ?? '',
      streamIcon: json['stream_icon'] as String?,
      cover: json['cover'] as String?,
      rating: flexibleDouble(json['rating']),
      categoryId: json['category_id']?.toString(),
      containerExtension: (json['container_extension'] as String?) ?? 'mp4',
      added: flexibleInt(json['added']),
    );
  }

  /// API-shaped map (build #11) — see [XtreamCategory.toJson].
  Map<String, dynamic> toJson() => {
    'stream_id': streamId,
    'name': name,
    'stream_icon': streamIcon,
    'cover': cover,
    'rating': rating,
    'category_id': categoryId,
    'container_extension': containerExtension,
    'added': added,
  };
}

class XtreamSeries {
  final int seriesId;
  final String name;
  final String? cover;
  final String? plot;
  final String? cast;
  final String? director;
  final String? genre;
  final String? releaseDate;
  final double? rating;
  final String? categoryId;
  final String? backdropPath;
  final String? youtubeTrailer;
  final int? episodeRunTime;

  const XtreamSeries({
    required this.seriesId,
    required this.name,
    this.cover,
    this.plot,
    this.cast,
    this.director,
    this.genre,
    this.releaseDate,
    this.rating,
    this.categoryId,
    this.backdropPath,
    this.youtubeTrailer,
    this.episodeRunTime,
  });

  factory XtreamSeries.fromJson(Map<String, dynamic> json) {
    return XtreamSeries(
      seriesId: flexibleInt(json['series_id']) ?? 0,
      name: (json['name'] as String?) ?? '',
      cover: json['cover'] as String?,
      plot: json['plot'] as String?,
      cast: json['cast'] as String?,
      director: json['director'] as String?,
      genre: json['genre'] as String?,
      releaseDate: json['releaseDate'] as String?,
      rating: flexibleDouble(json['rating']),
      categoryId: json['category_id']?.toString(),
      backdropPath: json['backdrop_path'] as String?,
      youtubeTrailer: json['youtube_trailer'] as String?,
      episodeRunTime: flexibleInt(json['episode_run_time']),
    );
  }

  /// API-shaped map (build #11) — see [XtreamCategory.toJson].
  Map<String, dynamic> toJson() => {
    'series_id': seriesId,
    'name': name,
    'cover': cover,
    'plot': plot,
    'cast': cast,
    'director': director,
    'genre': genre,
    'releaseDate': releaseDate,
    'rating': rating,
    'category_id': categoryId,
    'backdrop_path': backdropPath,
    'youtube_trailer': youtubeTrailer,
    'episode_run_time': episodeRunTime,
  };
}

class XtreamEpisode {
  final int id;
  final int episodeNum;
  final String title;
  final String containerExtension;
  final int? durationSeconds;
  final String? plot;

  const XtreamEpisode({
    required this.id,
    required this.episodeNum,
    required this.title,
    this.containerExtension = 'mp4',
    this.durationSeconds,
    this.plot,
  });

  factory XtreamEpisode.fromJson(Map<String, dynamic> json) {
    final info = json['info'] is Map<String, dynamic> ? json['info'] as Map<String, dynamic> : null;
    return XtreamEpisode(
      id: flexibleInt(json['id']) ?? 0,
      episodeNum: flexibleInt(json['episode_num']) ?? 0,
      title: (json['title'] as String?) ?? '',
      containerExtension: (json['container_extension'] as String?) ?? 'mp4',
      durationSeconds: flexibleInt(info?['duration']),
      plot: info?['plot'] as String?,
    );
  }
}

class XtreamSeriesInfo {
  /// season number → episodes, in episode order.
  final Map<int, List<XtreamEpisode>> episodesBySeason;
  final Map<String, dynamic>? info;

  const XtreamSeriesInfo({required this.episodesBySeason, this.info});

  factory XtreamSeriesInfo.fromJson(Map<String, dynamic> json) {
    final episodes = <int, List<XtreamEpisode>>{};
    final raw = json['episodes'];
    if (raw is Map<String, dynamic>) {
      for (final entry in raw.entries) {
        final season = int.tryParse(entry.key);
        final list = entry.value;
        if (season == null || list is! List) continue;
        episodes[season] = list.whereType<Map<String, dynamic>>().map(XtreamEpisode.fromJson).toList();
      }
    }
    final info = json['info'] is Map<String, dynamic> ? json['info'] as Map<String, dynamic> : null;
    return XtreamSeriesInfo(episodesBySeason: episodes, info: info);
  }
}

String _decodeBase64Text(String? raw) {
  if (raw == null || raw.isEmpty) return '';
  try {
    return utf8.decode(base64Decode(raw));
  } catch (_) {
    return raw;
  }
}

class XtreamEpgProgram {
  final String id;
  final String title;
  final String description;
  final int startTimestamp; // epoch seconds
  final int stopTimestamp; // epoch seconds
  final String? channelId;

  const XtreamEpgProgram({
    required this.id,
    required this.title,
    required this.description,
    required this.startTimestamp,
    required this.stopTimestamp,
    this.channelId,
  });

  factory XtreamEpgProgram.fromJson(Map<String, dynamic> json) {
    return XtreamEpgProgram(
      id: stringOrEmpty(json['id']),
      title: _decodeBase64Text(json['title'] as String?),
      description: _decodeBase64Text(json['description'] as String?),
      startTimestamp: flexibleInt(json['start_timestamp']) ?? 0,
      stopTimestamp: flexibleInt(json['stop_timestamp']) ?? 0,
      channelId: json['channel_id']?.toString(),
    );
  }
}
