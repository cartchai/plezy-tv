import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../base_shared_preferences_service.dart';
import '../connectivity_probe.dart';
import '../../utils/log_redaction_manager.dart';

/// One recorded panel refusal (build #27).
///
/// The app used to discard the body and headers of every refused Xtream
/// response, so a 403 could not be told apart from a Cloudflare block, a
/// flood-protection block, or a panel error. This entry is what the panel
/// actually said, captured at the moment of refusal.
///
/// Safety: an entry NEVER carries credentials. The request URL is never
/// stored — only an [action] derived from it (see [actionForUri]) — and
/// the body and headers pass through [sanitizeBody]/[sanitizeHeaders],
/// which truncate, redact sensitive fields and strip known credential
/// values. A test ([iptv_build27_refusal_log_test.dart]) asserts a
/// stored entry built from a credential-carrying URL contains no
/// credential anywhere.
class IptvRefusalEntry {
  IptvRefusalEntry({
    required this.timestamp,
    this.connectionId = '',
    this.connectionName = '',
    required this.action,
    this.statusCode,
    required this.failureKind,
    Map<String, String> headers = const {},
    String bodySnippet = '',
    this.userAgent = '',
    this.network = 'unknown',
  }) : headers = sanitizeHeaders(headers),
       bodySnippet = sanitizeBody(bodySnippet);

  /// When the refusal happened (UTC).
  final DateTime timestamp;

  /// The connection it happened on ('' when there is none yet — the
  /// sign-in probe runs before a connection exists).
  final String connectionId;

  /// The user-given connection name ('' when unknown). Safe to show: it
  /// is a name Matt typed, not a credential.
  final String connectionName;

  /// What was being done, without host or credentials — e.g.
  /// `player_api.php?action=get_live_categories`, `xmltv.php`,
  /// `live:123`, `stream: Game Of Thrones`. See [actionForUri].
  final String action;

  /// The HTTP status when the panel answered (403/429/401/500...), or
  /// null for a transport failure (timeout / socket error).
  final int? statusCode;

  /// How it failed: 'http' (a status), 'timeout', 'connection' or
  /// 'unknown'. Cancellations are never recorded — a search the user
  /// abandoned is not a refusal.
  final String failureKind;

  /// The response headers, with sensitive values redacted
  /// (set-cookie / authorization and friends become '[REDACTED]').
  final Map<String, String> headers;

  /// The first [IptvRefusalLog.maxBodyChars] of the response body,
  /// redacted. The Cloudflare "Just a moment..." page and the panel's
  /// JSON error both fit — the discriminator between a WAF block and a
  /// panel block lives here.
  final String bodySnippet;

  /// The User-Agent the request sent.
  final String userAgent;

  /// The network when refused: 'wifi' | 'mobile' | 'ethernet' | 'none' |
  /// 'unknown'. A refusal that only happens on one network is a
  /// different story from one that happens on both.
  final String network;

  IptvRefusalEntry copyWith({String? network}) => IptvRefusalEntry(
    timestamp: timestamp,
    connectionId: connectionId,
    connectionName: connectionName,
    action: action,
    statusCode: statusCode,
    failureKind: failureKind,
    headers: headers,
    bodySnippet: bodySnippet,
    userAgent: userAgent,
    network: network ?? this.network,
  );

  Map<String, dynamic> toJson() => {
    'v': 1,
    'ts': timestamp.millisecondsSinceEpoch,
    'connectionId': connectionId,
    'connectionName': connectionName,
    'action': action,
    'status': statusCode,
    'kind': failureKind,
    'headers': headers,
    'body': bodySnippet,
    'ua': userAgent,
    'network': network,
  };

  factory IptvRefusalEntry.fromJson(Map<String, dynamic> json) {
    final headers = <String, String>{};
    final rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value?.toString() ?? '';
      }
    }
    return IptvRefusalEntry(
      timestamp: DateTime.fromMillisecondsSinceEpoch((json['ts'] as num?)?.toInt() ?? 0, isUtc: true),
      connectionId: (json['connectionId'] as String?) ?? '',
      connectionName: (json['connectionName'] as String?) ?? '',
      action: (json['action'] as String?) ?? 'request',
      statusCode: (json['status'] as num?)?.toInt(),
      failureKind: (json['kind'] as String?) ?? 'unknown',
      headers: headers,
      bodySnippet: (json['body'] as String?) ?? '',
      userAgent: (json['ua'] as String?) ?? '',
      network: (json['network'] as String?) ?? 'unknown',
    );
  }

  /// Plain-text form for Copy: one block per entry, newest first when
  /// joined. Safe to send to a maintainer — it contains nothing the
  /// entry itself does not already hold (no URL, no credentials).
  String toShareText() {
    final lines = <String>[
      '[${_formatTimestamp(timestamp)}] ${_statusLabel()} · $action',
      if (connectionName.isNotEmpty) 'Connection: $connectionName',
      'Network: $network',
      if (userAgent.isNotEmpty) 'User-Agent: $userAgent',
      if (headers.isNotEmpty) ...[
        'Headers:',
        for (final entry in headers.entries) '  ${entry.key}: ${entry.value}',
      ],
      if (bodySnippet.isNotEmpty) ...['Body:', bodySnippet],
    ];
    return lines.join('\n');
  }

  String _statusLabel() => statusCode == null ? failureKind : 'HTTP $statusCode';

  static String _formatTimestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// Derive a safe action label from a request URI. The host is dropped
  /// (the panel address is not stored) and credentials are dropped by
  /// construction: only the path shape and the `action` query value are
  /// ever emitted — never `username`/`password` and never the
  /// user/password path segments of a stream URL.
  static String actionForUri(Uri uri) {
    final path = uri.path;
    if (path.endsWith('player_api.php')) {
      final action = uri.queryParameters['action'];
      return action == null || action.isEmpty ? 'player_api.php' : 'player_api.php?action=$action';
    }
    if (path.endsWith('xmltv.php')) return 'xmltv.php';
    if (path.endsWith('get.php')) return 'get.php';
    final segments = uri.pathSegments;
    if (segments.isEmpty) return 'request';
    const kinds = {'live', 'movie', 'series', 'timeshift'};
    if (kinds.contains(segments.first)) {
      final last = segments.last;
      final id = last.contains('.') ? last.substring(0, last.lastIndexOf('.')) : last;
      return id.isEmpty ? segments.first : '${segments.first}:$id';
    }
    return 'request';
  }

  /// Truncate a response body to the stored cap and redact it. [redactValues]
  /// are literal credential values the caller knows (XtreamApi passes its
  /// username and password): they are replaced verbatim before the
  /// pattern-based redaction, so a body echoing the request URL cannot
  /// leak them. [LogRedactionManager.redact] then strips sensitive
  /// `password=`-style fields, tokens and URL user-info.
  static String sanitizeBody(String body, {List<String> redactValues = const []}) {
    var out = body.length <= IptvRefusalLog.maxBodyChars
        ? body
        : body.substring(0, IptvRefusalLog.maxBodyChars);
    for (final value in redactValues) {
      if (value.isEmpty) continue;
      out = out.replaceAll(value, '[REDACTED]');
    }
    return LogRedactionManager.redact(out);
  }

  /// Redact response headers. Values of credential-carrying headers
  /// (cookies, authorization, API keys) are replaced wholesale; other
  /// values pass through the literal redaction plus the pattern-based
  /// one, so a `location` header echoing a credential URL is stripped.
  static Map<String, String> sanitizeHeaders(
    Map<String, String> headers, {
    List<String> redactValues = const [],
  }) {
    const sensitive = {
      'cookie',
      'set-cookie',
      'authorization',
      'proxy-authorization',
      'x-api-key',
      'x-auth-token',
      'x-plex-token',
      'x-emby-token',
    };
    final out = <String, String>{};
    for (final entry in headers.entries) {
      if (sensitive.contains(entry.key.toLowerCase())) {
        out[entry.key] = '[REDACTED]';
        continue;
      }
      var value = entry.value;
      for (final redact in redactValues) {
        if (redact.isEmpty) continue;
        value = value.replaceAll(redact, '[REDACTED]');
      }
      out[entry.key] = LogRedactionManager.redact(value);
    }
    return Map.unmodifiable(out);
  }
}

/// The persisted refusal log (build #27): the last [maxEntries] refusals,
/// newest first, in one SharedPreferences string so they survive an app
/// restart — a refusal at 20:47 has to still be there when Matt opens
/// Settings later. Writes are serialised (concurrent refused requests
/// cannot clobber each other) and recording never throws: a diagnostic
/// must never break the error path it observes.
///
/// Storage is the app-wide shared cache ([BaseSharedPreferencesService]),
/// the same store the favourites use — covered by logout wipe and store
/// salvage like every other pref.
class IptvRefusalLog {
  IptvRefusalLog({
    Future<SharedPreferencesWithCache> Function()? prefsProvider,
    Future<String> Function()? networkTypeProvider,
  }) : _prefsProvider = prefsProvider ?? BaseSharedPreferencesService.sharedCache,
       _networkTypeProvider = networkTypeProvider ?? _defaultNetworkType;

  /// How many refusals are kept; the oldest drops off past this.
  static const int maxEntries = 50;

  /// How much of a response body is kept per entry (chars).
  static const int maxBodyChars = 2048;

  /// The SharedPreferences slot holding the JSON list.
  static const String prefsKey = 'iptv_refusal_log';

  static IptvRefusalLog? _instance;

  /// The app-wide log. The UI and the recorders share it.
  static IptvRefusalLog get instance => _instance ??= IptvRefusalLog();

  @visibleForTesting
  static void debugResetInstance() => _instance = null;

  final Future<SharedPreferencesWithCache> Function() _prefsProvider;
  final Future<String> Function() _networkTypeProvider;

  /// The entries, newest first. The Settings screen listens to this.
  final ValueNotifier<List<IptvRefusalEntry>> entriesNotifier = ValueNotifier(const []);

  Future<void>? _loadFuture;
  Future<void> _queue = Future.value();

  /// Load the persisted entries into [entriesNotifier] (once). The
  /// screen calls this on open; [record]/[clear] load implicitly.
  Future<void> ensureLoaded() => _loadFuture ??= _loadFromPrefs();

  /// Read the persisted entries fresh (a new instance after a restart
  /// reads the same log).
  Future<List<IptvRefusalEntry>> loadEntries() async {
    final prefs = await _prefsProvider();
    return _decode(readTolerantString(prefs, prefsKey));
  }

  /// Append [entry] (newest first), dropping the oldest past
  /// [maxEntries]. The network type is resolved here when the entry
  /// does not carry one — callers that already know it pass it in.
  /// Never throws.
  Future<void> record(IptvRefusalEntry entry) {
    return _enqueue(() async {
      await ensureLoaded();
      final network = entry.network == 'unknown' ? await _networkTypeProvider() : entry.network;
      final withNetwork = network == entry.network ? entry : entry.copyWith(network: network);
      final next = [withNetwork, ...entriesNotifier.value];
      if (next.length > maxEntries) next.removeRange(maxEntries, next.length);
      await _persist(next);
      entriesNotifier.value = List.unmodifiable(next);
    });
  }

  /// Drop every recorded refusal (persisted and in-memory).
  Future<void> clear() {
    return _enqueue(() async {
      await ensureLoaded();
      await _persist(const []);
      entriesNotifier.value = const [];
    });
  }

  Future<void> _loadFromPrefs() async {
    entriesNotifier.value = List.unmodifiable(await loadEntries());
  }

  Future<void> _persist(List<IptvRefusalEntry> entries) async {
    final prefs = await _prefsProvider();
    await prefs.setString(prefsKey, jsonEncode(entries.map((e) => e.toJson()).toList()));
  }

  static List<IptvRefusalEntry> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final entries = <IptvRefusalEntry>[];
      for (final item in decoded.whereType<Map<String, dynamic>>()) {
        try {
          entries.add(IptvRefusalEntry.fromJson(item));
        } catch (_) {
          // One corrupt entry must not discard the whole log.
        }
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }

  /// Serialise write tasks so concurrent refused requests cannot
  /// read-modify-write over each other. A failed task does not break
  /// the queue for the next one; the failure still reaches the
  /// awaiting caller (the recorders catch it — recording never breaks
  /// the error path).
  Future<void> _enqueue(Future<void> Function() task) {
    final run = _queue.then((_) => task());
    _queue = run.catchError((_) {});
    return run;
  }

  /// The network when a refusal happened, from the platform probe
  /// (500 ms cap — recording must not stall the error path). Unknown
  /// when the platform cannot answer.
  static Future<String> _defaultNetworkType() async {
    final results = await ConnectivityProbe.check(timeout: const Duration(milliseconds: 500));
    if (results.contains(ConnectivityResult.none)) return 'none';
    if (results.contains(ConnectivityResult.wifi)) return 'wifi';
    if (results.contains(ConnectivityResult.mobile)) return 'mobile';
    if (results.contains(ConnectivityResult.ethernet)) return 'ethernet';
    return 'unknown';
  }
}
