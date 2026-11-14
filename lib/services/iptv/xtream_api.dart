import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../exceptions/media_server_exceptions.dart';
import '../../utils/app_logger.dart';
import '../../utils/iptv_initials.dart';
import '../../utils/json_utils.dart';
import 'iptv_refusal_log.dart';

/// The User-Agent values the Xtream panel sees (build #20).
///
/// Trex returns HTTP 403 to PlezTV's requests while TiviMate works with the
/// same account on the same phone: the app sent no User-Agent, so the panel
/// saw Dart's default `Dart/3.13 (dart:io)` — a distinctive, non-player
/// signature. Xtream panels enforce per-user allowed-UA lists and global
/// blocked-UA patterns as a first-class feature (USER_AGENT_BAN / EMPTY_UA),
/// and `VLC` is the most widely reported accepted value for 403s. The value
/// is a setting (Settings → IPTV → Xtream User-Agent), stored as a choice
/// key + custom text in SettingsService and resolved here so every caller
/// (client, sign-in probe, tests) agrees on the wire value.
class XtreamUserAgent {
  /// The default: the most widely reported accepted value for 403s.
  static const String vlc = 'VLC';

  /// Second most reported fallback.
  static const String smarters = 'IPTVSmartersPro';

  /// Full browser UA, the third documented fallback.
  static const String browser = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)';

  /// Stored choice keys for the Settings preference.
  static const String choiceVlc = 'vlc';
  static const String choiceSmarters = 'smarters';
  static const String choiceBrowser = 'browser';
  static const String choiceCustom = 'custom';

  static const String defaultChoice = choiceVlc;

  /// Resolve a stored choice + custom text to the UA string sent on the
  /// wire. Unknown choices and a blank custom value fall back to VLC —
  /// a request must never go out with no User-Agent again.
  static String resolve(String choice, String custom) => switch (choice) {
    choiceSmarters => smarters,
    choiceBrowser => browser,
    choiceCustom => custom.trim().isEmpty ? vlc : custom.trim(),
    _ => vlc,
  };
}

/// Thrown when an unfiltered catalog response exceeds the 300 MB cap
/// (build #23, [XtreamApi.maxCatalogResponseChars]). The sync reports
/// it as 'oversize' and keeps the old index rows — a bad sync never
/// wipes good data.
class XtreamCatalogTooLargeException implements Exception {
  const XtreamCatalogTooLargeException(this.chars);

  final int chars;

  @override
  String toString() => 'Xtream catalog response too large: $chars chars';
}
/// Which catalog rows are visible (1.2.4, catalog memory): the hidden
/// sets from the connection, plus the category-id -> initial map derived
/// from the category names. Plain values only, so it crosses into a
/// [compute] isolate like [IndexWriteParams]. The rule is the same one
/// the read-time filter applies — a row is hidden by its own category
/// id, or because its category's initial is turned off — so the
/// in-isolate filter and the read-time filter can never disagree about
/// a row. A category with no initial is absent from the map: a row in
/// one is hidden only by its own id switch.
class VisibleCatalogFilter {
  const VisibleCatalogFilter({
    required this.hiddenCategoryIds,
    required this.hiddenInitials,
    required this.initialByCategoryId,
  });

  /// Per-category ids turned off (usually empty — Matt hides initials).
  final List<String> hiddenCategoryIds;

  /// Category initials turned off (Matt hides 32).
  final List<String> hiddenInitials;

  /// categoryId -> initial, derived from the category names.
  final Map<String, String> initialByCategoryId;

  /// Build from the category list (sync path: the just-fetched list).
  factory VisibleCatalogFilter.fromCategories(
    List<XtreamCategory> categories, {
    required Set<String> hiddenCategoryIds,
    required Set<String> hiddenInitials,
  }) {
    final byId = <String, String>{};
    for (final category in categories) {
      final initial = categoryInitial(category.name);
      if (initial != null) byId[category.id] = initial;
    }
    return VisibleCatalogFilter(
      hiddenCategoryIds: hiddenCategoryIds.toList(),
      hiddenInitials: hiddenInitials.toList(),
      initialByCategoryId: byId,
    );
  }

  /// Build from an id -> name map (disk path: the cached category names).
  factory VisibleCatalogFilter.fromCategoryNames(
    Map<String, String> names, {
    required Set<String> hiddenCategoryIds,
    required Set<String> hiddenInitials,
  }) {
    final byId = <String, String>{};
    for (final entry in names.entries) {
      final initial = categoryInitial(entry.value);
      if (initial != null) byId[entry.key] = initial;
    }
    return VisibleCatalogFilter(
      hiddenCategoryIds: hiddenCategoryIds.toList(),
      hiddenInitials: hiddenInitials.toList(),
      initialByCategoryId: byId,
    );
  }

  bool isHidden(String? categoryId) {
    if (categoryId != null && hiddenCategoryIds.contains(categoryId)) return true;
    final initial = categoryId == null ? null : initialByCategoryId[categoryId];
    return initial != null && hiddenInitials.contains(initial);
  }

  /// True when nothing is hidden: the visible body IS the raw body, so a
  /// disk write must not pay the isolate round trip (sending a ~40MB
  /// body across the port blocks the main isolate ~300ms at Trex scale
  /// — the build #13 bench caught it). Write the raw body straight.
  bool get isNoOp => hiddenCategoryIds.isEmpty && hiddenInitials.isEmpty;
}


/// One XMLTV feed fetch: the response body as a byte stream plus the
/// conditional-fetch outcome (1.2.2 I9). [notModified] means the server
/// answered 304 to the validators sent — there is no body to download and
/// nothing to re-parse; the caller reuses the guide it already has.
/// [etag]/[lastModified] are the response's validators (from a 200 or a
/// 304), to send back as If-None-Match / If-Modified-Since on the next
/// refresh; both are null when the server sends none, and the next fetch
/// is then unconditional, exactly as before. Whether the panel honours
/// conditional fetch is UNPROVEN — a dynamically generated xmltv.php
/// likely sends no validators at all, in which case this is a no-op and
/// the feed downloads in full every time (the old behaviour).
typedef XmltvFeedFetch = ({
  Stream<List<int>> bytes,
  bool notModified,
  String? etag,
  String? lastModified,
});

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

  /// The default User-Agent sent on every request (build #20).
  static const String defaultUserAgent = XtreamUserAgent.vlc;

  /// Hostile-response cap (build #23, IPTVMac SyncService shape): an
  /// unfiltered catalog response larger than this is refused before
  /// parsing ([XtreamCatalogTooLargeException]), so a bad sync can't
  /// blow up storage. Counted in UTF-16 code units (≈ bytes for JSON,
  /// which is mostly ASCII).
  static const int maxCatalogResponseChars = 300000000;

  /// Fixed User-Agent for this client, when one is given.
  final String? _userAgent;

  /// Provider for the User-Agent, re-read on every request when given —
  /// the Settings-backed one in IptvClient reads the preference per
  /// request, so changing Settings → IPTV → Xtream User-Agent applies to
  /// the next request without rebuilding the client. Wins over [_userAgent].
  final String Function()? _userAgentProvider;

  /// The refusal recorder (build #27): called with a sanitized entry for
  /// every refused response and transport failure, before the throw.
  /// Null in tests and for callers that do not record.
  final Future<void> Function(IptvRefusalEntry entry)? _onRefusal;

  /// The connection this client serves, for the recorded entry ('' when
  /// the client is a pre-connection probe — the sign-in screen).
  final String _connectionId;
  final String _connectionName;

  XtreamApi({
    required String serverUrl,
    required this.username,
    required this.password,
    http.Client? httpClient,
    this._userAgent,
    this._userAgentProvider,
    this._onRefusal,
    this._connectionId = '',
    this._connectionName = '',
  }) : serverUrl = serverUrl.endsWith('/') ? serverUrl.substring(0, serverUrl.length - 1) : serverUrl,
       _http = httpClient ?? http.Client();

  /// The User-Agent for the next request: provider, then fixed value,
  /// then the VLC default. Never null, never empty.
  String get _effectiveUserAgent => _userAgentProvider?.call() ?? _userAgent ?? defaultUserAgent;

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
  ///
  /// Every request carries the configured User-Agent (build #20): the panel
  /// 403s the bare Dart default, so a request must never go out without one.
  Future<String> _fetchBody(
    Uri uri, {
    Duration timeout = const Duration(seconds: 30),
    Future<void>? abortTrigger,
  }) async {
    http.Response response;
    try {
      // Build #21: an AbortableRequest so a search section can hard-cancel
      // its in-flight requests when its budget expires (or a new keystroke
      // cancels the search) instead of abandoning the future and leaving
      // the socket running. Identical to what BaseClient.get does under
      // the hood (send + Response.fromStream); the single .timeout keeps
      // the old combined headers+body budget. A null trigger behaves
      // exactly like the old get() — every non-search caller passes none.
      final request = http.AbortableRequest('GET', uri, abortTrigger: abortTrigger);
      request.headers['User-Agent'] = _effectiveUserAgent;
      response = await (() async {
        final streamed = await _http.send(request);
        return http.Response.fromStream(streamed);
      })().timeout(timeout);
    } catch (e) {
      final mapped = MediaServerHttpException.from(e, uri: uri);
      // Build #27: a transport failure is a refusal too (timeout / socket
      // error) — but a cancellation is not: a search the user abandoned
      // says nothing about the panel and must never fill the log.
      if (!mapped.isCancellation) {
        await _recordRefusal(uri: uri, statusCode: null, failureKind: _failureKindFor(mapped.type));
      }
      throw mapped;
    }
    if (response.statusCode == 401) {
      await _recordRefusal(uri: uri, statusCode: 401, failureKind: 'http', response: response);
      throw MediaServerAuthException('Xtream authentication failed', statusCode: 401);
    }
    if (response.statusCode == 403) {
      await _recordRefusal(uri: uri, statusCode: 403, failureKind: 'http', response: response);
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream access denied',
        statusCode: 403,
        requestUri: uri,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _recordRefusal(uri: uri, statusCode: response.statusCode, failureKind: 'http', response: response);
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream request failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        requestUri: uri,
      );
    }
    return response.body;
  }

  /// Hand a refusal to the recorder (build #27), if one is attached.
  /// Record-only: the exception the caller sees is unchanged, and this
  /// never throws — a diagnostic must never break the error path it
  /// observes. The URL itself is never stored ([IptvRefusalEntry.actionForUri]
  /// derives the action without host or credentials) and the body/headers
  /// are sanitized with this client's own credentials as redaction values.
  Future<void> _recordRefusal({
    required Uri uri,
    required int? statusCode,
    required String failureKind,
    http.Response? response,
  }) async {
    final onRefusal = _onRefusal;
    if (onRefusal == null) return;
    try {
      await onRefusal(
        IptvRefusalEntry(
          timestamp: DateTime.now(),
          connectionId: _connectionId,
          connectionName: _connectionName,
          action: IptvRefusalEntry.actionForUri(uri),
          statusCode: statusCode,
          failureKind: failureKind,
          headers: response == null
              ? const {}
              : IptvRefusalEntry.sanitizeHeaders(response.headers, redactValues: [username, password]),
          bodySnippet: response == null
              ? ''
              : IptvRefusalEntry.sanitizeBody(response.body, redactValues: [username, password]),
          userAgent: _effectiveUserAgent,
        ),
      );
    } catch (_) {
      // Recording is best-effort; the refusal itself still throws.
    }
  }

  static String _failureKindFor(MediaServerHttpErrorType type) => switch (type) {
    MediaServerHttpErrorType.connectionTimeout || MediaServerHttpErrorType.receiveTimeout => 'timeout',
    MediaServerHttpErrorType.connectionError => 'connection',
    MediaServerHttpErrorType.cancelled => 'cancelled',
    MediaServerHttpErrorType.unknown => 'unknown',
  };

  Future<dynamic> _getJson(
    Uri uri, {
    Duration timeout = const Duration(seconds: 30),
    Future<void>? abortTrigger,
  }) async {
    final body = await _fetchBody(uri, timeout: timeout, abortTrigger: abortTrigger);
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

  /// Same User-Agent rule as [_fetchBody] (build #20): the EPG feed and the
  /// M3U export go through here, and the panel sees them too.
  /// [abortTrigger] (build #28) hard-cancels the request — the feed
  /// download stops when the app backgrounds instead of running to
  /// completion unobserved. A null trigger behaves exactly like the old
  /// get().
  Future<String> _getText(Uri uri, {Duration timeout = const Duration(seconds: 30), Future<void>? abortTrigger}) async {
    http.Response response;
    try {
      // Build #28: AbortableRequest, same shape as [_fetchBody] — see
      // its comment. The M3U export keeps passing no trigger.
      final request = http.AbortableRequest('GET', uri, abortTrigger: abortTrigger);
      request.headers['User-Agent'] = _effectiveUserAgent;
      response = await (() async {
        final streamed = await _http.send(request);
        return http.Response.fromStream(streamed);
      })().timeout(timeout);
    } catch (e) {
      final mapped = MediaServerHttpException.from(e, uri: uri);
      if (!mapped.isCancellation) {
        await _recordRefusal(uri: uri, statusCode: null, failureKind: _failureKindFor(mapped.type));
      }
      throw mapped;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _recordRefusal(uri: uri, statusCode: response.statusCode, failureKind: 'http', response: response);
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

  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async {
    final decoded = await _getJson(
      _playerApiUri(action: 'get_live_categories'),
      abortTrigger: abortTrigger,
    );
    return _asObjectList(decoded).map(XtreamCategory.fromJson).toList();
  }

  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async {
    final decoded = await _getJson(
      _playerApiUri(action: 'get_vod_categories'),
      abortTrigger: abortTrigger,
    );
    return _asObjectList(decoded).map(XtreamCategory.fromJson).toList();
  }

  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async {
    final decoded = await _getJson(
      _playerApiUri(action: 'get_series_categories'),
      abortTrigger: abortTrigger,
    );
    return _asObjectList(decoded).map(XtreamCategory.fromJson).toList();
  }

  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async {
    // The full live list is tens of thousands of rows; give it two minutes
    // on slow connections instead of the 30s default, and parse it off the
    // UI thread — decoding tens of thousands of rows on the main isolate
    // freezes the app for seconds.
    final body = await _fetchBody(
      _playerApiUri(action: 'get_live_streams', extra: categoryId == null ? null : {'category_id': categoryId}),
      timeout: const Duration(seconds: 120),
      abortTrigger: abortTrigger,
    );
    // Build #23: hostile-response cap (IPTVMac SyncService shape) — an
    // unfiltered catalog over 300 MB is refused BEFORE parsing, so a bad
    // sync can't blow up storage or the parse isolate. Per-category
    // bodies are small and uncapped. Counted in UTF-16 code units
    // (≈ bytes for JSON, which is mostly ASCII).
    if (categoryId == null && body.length > maxCatalogResponseChars) {
      throw XtreamCatalogTooLargeException(body.length);
    }
    lastLiveStreamsBody = categoryId == null ? body : null;
    return compute(_parseLiveStreams, body);
  }

  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async {
    // The full VOD list is ~200k rows (tens of MB of JSON). Same treatment
    // as the live list: a long timeout and isolate parsing, so opening
    // Movies does not hang or time out on a slow connection.
    final body = await _fetchBody(
      _playerApiUri(action: 'get_vod_streams', extra: categoryId == null ? null : {'category_id': categoryId}),
      timeout: const Duration(seconds: 120),
      abortTrigger: abortTrigger,
    );
    if (categoryId == null && body.length > maxCatalogResponseChars) {
      throw XtreamCatalogTooLargeException(body.length);
    }
    lastVodStreamsBody = categoryId == null ? body : null;
    return compute(_parseVodStreams, body);
  }

  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async {
    final body = await _fetchBody(
      _playerApiUri(action: 'get_series', extra: categoryId == null ? null : {'category_id': categoryId}),
      timeout: const Duration(seconds: 120),
      abortTrigger: abortTrigger,
    );
    if (categoryId == null && body.length > maxCatalogResponseChars) {
      throw XtreamCatalogTooLargeException(body.length);
    }
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
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    final decoded = await _getJson(
      _playerApiUri(action: 'get_short_epg', extra: {'stream_id': streamId, 'limit': '$limit'}),
      timeout: timeout ?? const Duration(seconds: 30),
      abortTrigger: abortTrigger,
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

  /// Full XMLTV guide as a byte stream (large — callers stream-parse it
  /// instead of materialising the whole body; build #26). [timeout] bounds
  /// reaching the server and each quiet gap between chunks, so a slow
  /// connection that keeps delivering still completes. The stream carries
  /// the same User-Agent and abort rules as [_getText]: [abortTrigger]
  /// hard-cancels the request at the socket. The bytes are the response
  /// body as the transport delivers it — gzip is already decoded by the
  /// underlying HttpClient (autoUncompress), verified by the loopback gzip
  /// test in iptv_build26_epg_streaming_test.dart.
  ///
  /// 1.2.2 I9 (conditional fetch): when [etag]/[lastModified] are given
  /// they are sent as If-None-Match / If-Modified-Since. A 304 answer
  /// comes back as `notModified: true` with an empty body stream — the
  /// caller reuses its guide instead of downloading and re-parsing.
  /// [etag]/[lastModified] in the result are the response's validators
  /// (from a 200 or a 304); null when the server sends none.
  Future<XmltvFeedFetch> getXmltvFeed({
    String? etag,
    String? lastModified,
    Duration timeout = const Duration(seconds: 120),
    Future<void>? abortTrigger,
  }) async {
    final uri = Uri.parse('$serverUrl/xmltv.php?username=$username&password=$password');
    http.StreamedResponse streamed;
    try {
      // Build #28: AbortableRequest, same shape as [_getText] — see its
      // comment. The send is awaited (headers) under the timeout; the
      // body then streams with a per-chunk-gap timeout instead of one
      // total budget, so a 150 MB feed on a slow connection is not cut
      // off for merely being slow.
      final request = http.AbortableRequest('GET', uri, abortTrigger: abortTrigger);
      request.headers['User-Agent'] = _effectiveUserAgent;
      if (etag != null) request.headers['If-None-Match'] = etag;
      if (lastModified != null) request.headers['If-Modified-Since'] = lastModified;
      streamed = await _http.send(request).timeout(timeout);
    } catch (e) {
      final mapped = MediaServerHttpException.from(e, uri: uri);
      if (!mapped.isCancellation) {
        await _recordRefusal(uri: uri, statusCode: null, failureKind: _failureKindFor(mapped.type));
      }
      throw mapped;
    }
    if (streamed.statusCode == 304) {
      // A 304 has no body by definition: the feed the caller already
      // holds is current. The response validators are the ones to send
      // next time (a server may rotate them on a 304).
      return (
        bytes: const Stream<List<int>>.empty(),
        notModified: true,
        etag: streamed.headers['etag'],
        lastModified: streamed.headers['last-modified'],
      );
    }
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      // Buffer only the (small) error body for the refusal record, as
      // [_getText] does — the success path never materialises the body.
      final response = await http.Response.fromStream(streamed);
      await _recordRefusal(uri: uri, statusCode: response.statusCode, failureKind: 'http', response: response);
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
      throw MediaServerHttpException(
        type: MediaServerHttpErrorType.unknown,
        message: 'Xtream request failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
        requestUri: uri,
      );
    }
    return (
      bytes: streamed.stream.timeout(timeout),
      notModified: false,
      etag: streamed.headers['etag'],
      lastModified: streamed.headers['last-modified'],
    );
  }

  /// Full XMLTV guide as a byte stream (large — callers stream-parse it
  /// instead of materialising the whole body; build #26). Implemented on
  /// top of [getXmltvFeed] so there is one network path. A first fetch
  /// has no validators, so this never 304s.
  Stream<List<int>> getXmltvStream({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async* {
    final fetch = await getXmltvFeed(timeout: timeout, abortTrigger: abortTrigger);
    yield* fetch.bytes.timeout(timeout);
  }

  /// Full XMLTV guide (large — callers fetch it only when the guide is
  /// actually being browsed). 120s: the file runs to megabytes and a slow
  /// connection legitimately takes a while to deliver it. Implemented on
  /// top of [getXmltvStream] so there is one network path; streaming
  /// callers use the stream directly and never materialise the body.
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    final bytes = await getXmltvStream(timeout: timeout, abortTrigger: abortTrigger)
        .fold<List<int>>(<int>[], (list, chunk) => list..addAll(chunk));
    return utf8.decode(bytes);
  }

/// Parse helpers for the disk cache (build #11): a cached payload is the
/// same JSON the API returns, so it parses through the same isolate
/// parsers as the network path — one parse shape, no second model.
/// Categories are small (<1k rows), so they parse inline.
static Future<List<XtreamLiveStream>> parseLiveStreamsBody(String body) => compute(_parseLiveStreams, body);

static Future<List<XtreamVodStream>> parseVodStreamsBody(String body) => compute(_parseVodStreams, body);

static Future<List<XtreamSeries>> parseSeriesBody(String body) => compute(_parseSeries, body);

/// Visible-only variants (1.2.4, catalog memory): the filter runs INSIDE
/// the isolate parse, so the memo holds visible rows only — the decoded
/// JSON is still fully materialised (unavoidable), but the typed row
/// list never holds a hidden row, and neither the parse peak nor the
/// steady state pays for the ~77% of rows in turned-off categories.
/// The disk file itself is pruned separately at write time; these
/// parsers are the defence for a stale full file (written before 1.2.4,
/// or by a path that writes the raw body).
static Future<List<XtreamLiveStream>> parseLiveStreamsBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_parseLiveStreamsVisible, _VisibleParseParams(body, filter));

static Future<List<XtreamVodStream>> parseVodStreamsBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_parseVodStreamsVisible, _VisibleParseParams(body, filter));

static Future<List<XtreamSeries>> parseSeriesBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_parseSeriesVisible, _VisibleParseParams(body, filter));

/// Visible-only parse from a DISK FILE (1.2.6, catalog memory, item 4):
/// the isolate reads the file itself, so the main isolate never holds
/// the tens-of-MB body and `compute` copies only the path + filter
/// across the port — the whole-body message copy that drove the bind
/// peak is gone. Same rows as [parseLiveStreamsBodyVisible] for the
/// same file content (the file IS the body the disk cache wrote).
static Future<List<XtreamLiveStream>> parseLiveStreamsFileVisible(String path, VisibleCatalogFilter filter) =>
    compute(_parseLiveStreamsFileVisible, _VisibleFileParseParams(path, filter));

static Future<List<XtreamVodStream>> parseVodStreamsFileVisible(String path, VisibleCatalogFilter filter) =>
    compute(_parseVodStreamsFileVisible, _VisibleFileParseParams(path, filter));

static Future<List<XtreamSeries>> parseSeriesFileVisible(String path, VisibleCatalogFilter filter) =>
    compute(_parseSeriesFileVisible, _VisibleFileParseParams(path, filter));

/// Visible-only re-encode (1.2.4, catalog memory): decode + filter +
/// re-encode the raw body in the isolate, so the disk write gets a
/// visible-only payload without a main-isolate `jsonEncode` freeze
/// (build #13: encoding 199k VOD rows on the UI isolate froze the app
/// ~1.3s). The disk file stays a plain API payload the isolate parsers
/// read unchanged — just pruned. Used by the sync disk write and the
/// first-load fallback writes.
static Future<String> encodeLiveStreamsBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_encodeLiveStreamsVisible, _VisibleParseParams(body, filter));

static Future<String> encodeVodStreamsBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_encodeVodStreamsVisible, _VisibleParseParams(body, filter));

static Future<String> encodeSeriesBodyVisible(String body, VisibleCatalogFilter filter) =>
    compute(_encodeSeriesVisible, _VisibleParseParams(body, filter));

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
  /// `YYYY-MM-DD:HH-MM` in UTC (the panel's convention).
  ///
  /// Build #16: the stamp used to carry seconds (`YYYY-MM-DD:HH-MM-SS`)
  /// and catch-up never played on the real panel — every documented
  /// source (UniPlayer catch-up spec, Dispatcharr's Xtream client, the
  /// Xtream API docs) agrees the start is `YYYY-MM-DD:HH-MM`, no seconds
  /// ("Strict `YYYY-MM-DD:HH-MM`"). A start the panel cannot parse
  /// resolves no archive segment, so mpv's open fails and the mini-player
  /// shows "Could not start the live channel".
  String timeshiftUrl({required String streamId, required int durationMinutes, required DateTime start}) {
    final utc = start.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${utc.year}-${two(utc.month)}-${two(utc.day)}:${two(utc.hour)}-${two(utc.minute)}';
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
/// The string reads coerce mistyped values (flexibleString) instead of
/// casting, so one bad field can't drop a row either: backdrop_path
/// arrives as an array, and a bare cast dropped ~95% of the series list.
List<XtreamLiveStream> _parseLiveStreams(String body) =>
    parseFlexibleJsonList(_decodeCatalogJson(body), XtreamLiveStream.fromJson);

List<XtreamVodStream> _parseVodStreams(String body) =>
    parseFlexibleJsonList(_decodeCatalogJson(body), XtreamVodStream.fromJson);

List<XtreamSeries> _parseSeries(String body) =>
    parseFlexibleJsonList(_decodeCatalogJson(body), XtreamSeries.fromJson);

/// Message for the visible-only parsers: the body plus the filter.
/// Plain values only, like [IndexWriteParams].
class _VisibleParseParams {
  final String body;
  final VisibleCatalogFilter filter;

  const _VisibleParseParams(this.body, this.filter);
}

/// Like [parseFlexibleJsonList] but the filter runs DURING the row loop:
/// a hidden row is parsed and dropped before it can join the list, so
/// the isolate never builds the full typed list — that is what shrinks
/// the parse peak, not just the steady state. Malformed rows are dropped
/// exactly as the unfiltered parse drops them.
///
/// 1.2.6 (catalog memory, item 4): hidden rows are skipped BEFORE they
/// are parsed at all — the category id comes straight off the raw map,
/// exactly as the typed row would carry it (`category_id?.toString()`,
/// no transformation in any of the three models), so the outcome is
/// identical and the ~77% of rows in hidden categories never become
/// typed objects. The post-parse check stays as a safety net.
List<T> _parseVisibleList<T>(
  Object? value,
  T Function(Map<String, dynamic> json) parse,
  String? Function(T row) categoryIdOf,
  VisibleCatalogFilter filter,
) {
  final result = <T>[];
  for (final json in flexibleMapList(value)) {
    try {
      if (filter.isHidden(json['category_id']?.toString())) continue;
      final row = parse(json);
      if (!filter.isHidden(categoryIdOf(row))) result.add(row);
    } catch (_) {
      // A malformed row does not invalidate its siblings.
    }
  }
  return result;
}

List<XtreamLiveStream> _parseLiveStreamsVisible(_VisibleParseParams params) => _parseVisibleList(
      _decodeCatalogJson(params.body),
      XtreamLiveStream.fromJson,
      (row) => row.categoryId,
      params.filter,
    );

List<XtreamVodStream> _parseVodStreamsVisible(_VisibleParseParams params) => _parseVisibleList(
      _decodeCatalogJson(params.body),
      XtreamVodStream.fromJson,
      (row) => row.categoryId,
      params.filter,
    );

List<XtreamSeries> _parseSeriesVisible(_VisibleParseParams params) => _parseVisibleList(
      _decodeCatalogJson(params.body),
      XtreamSeries.fromJson,
      (row) => row.categoryId,
      params.filter,
    );

/// Message for the file-based visible parsers: a path plus the filter.
/// Plain values only, like [_VisibleParseParams].
class _VisibleFileParseParams {
  final String path;
  final VisibleCatalogFilter filter;

  const _VisibleFileParseParams(this.path, this.filter);
}

/// File-based visible parsers (1.2.6, item 4): same rows as the
/// body-based ones — the isolate reads the file, then runs the identical
/// in-loop filter. A missing/corrupt file throws, and the caller treats
/// that as a cache miss exactly like a corrupt body.
Future<List<XtreamLiveStream>> _parseLiveStreamsFileVisible(_VisibleFileParseParams params) async {
  final body = await File(params.path).readAsString();
  return _parseVisibleList(
    _decodeCatalogJson(body),
    XtreamLiveStream.fromJson,
    (row) => row.categoryId,
    params.filter,
  );
}

Future<List<XtreamVodStream>> _parseVodStreamsFileVisible(_VisibleFileParseParams params) async {
  final body = await File(params.path).readAsString();
  return _parseVisibleList(
    _decodeCatalogJson(body),
    XtreamVodStream.fromJson,
    (row) => row.categoryId,
    params.filter,
  );
}

Future<List<XtreamSeries>> _parseSeriesFileVisible(_VisibleFileParseParams params) async {
  final body = await File(params.path).readAsString();
  return _parseVisibleList(
    _decodeCatalogJson(body),
    XtreamSeries.fromJson,
    (row) => row.categoryId,
    params.filter,
  );
}

String _encodeLiveStreamsVisible(_VisibleParseParams params) =>
    jsonEncode(_parseLiveStreamsVisible(params).map((row) => row.toJson()).toList());

String _encodeVodStreamsVisible(_VisibleParseParams params) =>
    jsonEncode(_parseVodStreamsVisible(params).map((row) => row.toJson()).toList());

String _encodeSeriesVisible(_VisibleParseParams params) =>
    jsonEncode(_parseSeriesVisible(params).map((row) => row.toJson()).toList());

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
      name: flexibleString(json['name']) ?? '',
      streamIcon: flexibleString(json['stream_icon']),
      epgChannelId: flexibleString(json['epg_channel_id']),
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
      name: flexibleString(json['name']) ?? '',
      streamIcon: flexibleString(json['stream_icon']),
      cover: flexibleString(json['cover']),
      rating: flexibleDouble(json['rating']),
      categoryId: json['category_id']?.toString(),
      containerExtension: flexibleString(json['container_extension']) ?? 'mp4',
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
      name: flexibleString(json['name']) ?? '',
      cover: flexibleString(json['cover']),
      plot: flexibleString(json['plot']),
      cast: flexibleString(json['cast']),
      director: flexibleString(json['director']),
      genre: flexibleString(json['genre']),
      releaseDate: flexibleString(json['releaseDate']),
      rating: flexibleDouble(json['rating']),
      categoryId: json['category_id']?.toString(),
      backdropPath: flexibleString(json['backdrop_path']),
      youtubeTrailer: flexibleString(json['youtube_trailer']),
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
