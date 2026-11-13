import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Third-party EPG sources + per-channel manual EPG assignment (PlezTV
/// 1.2.0, EPG area build 2 — TiviMate-anchored, §3.1/§3.2 of
/// RESEARCH_EPG_AREA.md).
///
/// The provider feed is implicit and never stored: Xtream = the login's
/// `xmltv.php` feed, M3U = the playlist's declared `url-tvg` / `x-tvg-url`
/// (`M3uConnection.epgUrl`) when present. Everything a user adds lives in
/// SharedPreferences under per-connection keys (same pattern as the hidden
/// channels store), so it survives refreshes and catalog syncs — a removed
/// source stays removed; the provider never silently re-enables it
/// (IPTVnator rule).
///
/// The mapping store is the escape hatch for channels no automatic match
/// can reach (the beIN case: feed id "beIN Sports 1" vs tvg-id
/// "beIN.Sports.1" vs name "beIN SPORTS 1 HD"): a manual assignment is
/// consulted before the byId/byName chain and survives refreshes/syncs.

/// One EPG source for a connection.
class IptvEpgSourceConfig {
  /// `'provider'` for the built-in feed, `'user_<uuid>'` for an added one.
  final String id;

  /// `'provider'` or `'xmltv'` (an added XMLTV URL).
  final String kind;

  /// The XMLTV URL for an added source; null for the provider feed.
  final String? url;

  /// Display name. Defaults to the URL host when the user adds a source
  /// without naming it.
  final String name;

  /// A disabled source is never fetched and never matches.
  final bool enabled;

  /// Display-only time shift for this source, in minutes. Null means
  /// "fall back to the global EPG time offset" (TiviMate model: per-source
  /// shift fixes a wrong-timezone feed without re-importing).
  final int? timeShiftMinutes;

  static const String providerId = 'provider';
  static const String kindProvider = 'provider';
  static const String kindXmltv = 'xmltv';

  const IptvEpgSourceConfig({
    required this.id,
    required this.kind,
    this.url,
    required this.name,
    this.enabled = true,
    this.timeShiftMinutes,
  });

  bool get isProvider => id == providerId;

  /// A fresh id for a user-added source.
  static String newUserId() => 'user_${const Uuid().v4()}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    if (url != null) 'url': url,
    'name': name,
    'enabled': enabled,
    if (timeShiftMinutes != null) 'timeShiftMinutes': timeShiftMinutes,
  };

  factory IptvEpgSourceConfig.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'] as String? ?? '';
    final id = rawId.isEmpty ? providerId : rawId;
    final kind = json['kind'] as String? ?? (id == providerId ? kindProvider : kindXmltv);
    return IptvEpgSourceConfig(
      id: id,
      kind: kind,
      url: json['url'] as String?,
      name: json['name'] as String? ?? id,
      enabled: json['enabled'] as bool? ?? true,
      timeShiftMinutes: json['timeShiftMinutes'] as int?,
    );
  }

  IptvEpgSourceConfig copyWith({
    String? name,
    bool? enabled,
    int? timeShiftMinutes,
    bool clearTimeShift = false,
  }) {
    return IptvEpgSourceConfig(
      id: id,
      kind: kind,
      url: url,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      timeShiftMinutes: clearTimeShift ? null : (timeShiftMinutes ?? this.timeShiftMinutes),
    );
  }
}

/// Display state of one source's status chip (IPTVnator model — the
/// visibility TiviMate lacks).
enum IptvEpgSourceState { upToDate, needsRefresh, failed, disabled }

/// What a source did last, persisted so the settings screen shows it
/// after a restart. Facts only — the display [state] is computed from
/// them (a failure after the last success is "failed"; a success older
/// than the update interval is "needs refresh").
class IptvEpgSourceStatus {
  final DateTime? lastSuccess;
  final DateTime? lastFailure;
  final String? lastFailureReason;
  final int programs;
  final int channels;
  final int sizeBytes;
  final int? durationMs;

  const IptvEpgSourceStatus({
    this.lastSuccess,
    this.lastFailure,
    this.lastFailureReason,
    this.programs = 0,
    this.channels = 0,
    this.sizeBytes = 0,
    this.durationMs,
  });

  static const empty = IptvEpgSourceStatus();

  IptvEpgSourceState state({required bool enabled, Duration? ttl}) {
    if (!enabled) return IptvEpgSourceState.disabled;
    if (lastFailure != null && (lastSuccess == null || lastFailure!.isAfter(lastSuccess!))) {
      return IptvEpgSourceState.failed;
    }
    if (lastSuccess == null) return IptvEpgSourceState.needsRefresh;
    if (ttl != null && DateTime.now().difference(lastSuccess!) >= ttl) {
      return IptvEpgSourceState.needsRefresh;
    }
    return IptvEpgSourceState.upToDate;
  }

  Map<String, dynamic> toJson() => {
    if (lastSuccess != null) 'lastSuccess': lastSuccess!.toIso8601String(),
    if (lastFailure != null) 'lastFailure': lastFailure!.toIso8601String(),
    if (lastFailureReason != null) 'lastFailureReason': lastFailureReason,
    'programs': programs,
    'channels': channels,
    'sizeBytes': sizeBytes,
    if (durationMs != null) 'durationMs': durationMs,
  };

  factory IptvEpgSourceStatus.fromJson(Map<String, dynamic> json) {
    return IptvEpgSourceStatus(
      lastSuccess: DateTime.tryParse(json['lastSuccess'] as String? ?? ''),
      lastFailure: DateTime.tryParse(json['lastFailure'] as String? ?? ''),
      lastFailureReason: json['lastFailureReason'] as String?,
      programs: json['programs'] as int? ?? 0,
      channels: json['channels'] as int? ?? 0,
      sizeBytes: json['sizeBytes'] as int? ?? 0,
      durationMs: json['durationMs'] as int?,
    );
  }

  IptvEpgSourceStatus copyWith({
    DateTime? lastSuccess,
    DateTime? lastFailure,
    String? lastFailureReason,
    bool clearFailure = false,
    int? programs,
    int? channels,
    int? sizeBytes,
    int? durationMs,
  }) {
    return IptvEpgSourceStatus(
      lastSuccess: lastSuccess ?? this.lastSuccess,
      lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
      lastFailureReason: clearFailure ? null : (lastFailureReason ?? this.lastFailureReason),
      programs: programs ?? this.programs,
      channels: channels ?? this.channels,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      durationMs: durationMs ?? this.durationMs,
    );
  }
}

/// One manual EPG assignment: this channel always uses this XMLTV channel
/// id from this source.
class IptvEpgMapping {
  final String xmltvId;
  final String sourceId;

  const IptvEpgMapping({required this.xmltvId, required this.sourceId});

  Map<String, dynamic> toJson() => {'xmltvId': xmltvId, 'sourceId': sourceId};

  factory IptvEpgMapping.fromJson(Map<String, dynamic> json) {
    return IptvEpgMapping(
      xmltvId: json['xmltvId'] as String? ?? '',
      sourceId: json['sourceId'] as String? ?? IptvEpgSourceConfig.providerId,
    );
  }
}

/// Per-connection store for EPG sources, the precedence toggle, manual
/// mappings, per-source status, and the channel-list fingerprint the
/// update-on-playlist-change check compares against. All keys are
/// per-connection (`iptv_epg_*:<connectionId>`), so one connection's
/// sources never leak into another's. Every method is best-effort on
/// corrupt data: a bad row reads as missing, never as a crash.
class IptvEpgSourcesStore {
  final String connectionId;

  IptvEpgSourcesStore(this.connectionId);

  String get _sourcesKey => 'iptv_epg_sources:$connectionId';
  String get _precedenceKey => 'iptv_epg_added_sources_first:$connectionId';
  String get _mappingKey => 'iptv_epg_mapping:$connectionId';
  String get _statusKey => 'iptv_epg_source_status:$connectionId';
  String get _fingerprintKey => 'iptv_epg_channel_fingerprint:$connectionId';

  Future<List<IptvEpgSourceConfig>> loadUserSources() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sourcesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final out = <IptvEpgSourceConfig>[];
      for (final row in decoded) {
        if (row is! Map<String, dynamic>) continue;
        try {
          final source = IptvEpgSourceConfig.fromJson(row);
          // The provider feed is implicit — a stored row claiming to be
          // it is stale data, not a second provider.
          if (source.isProvider) continue;
          out.add(source);
        } catch (_) {
          // One bad row does not drop the rest.
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveUserSources(List<IptvEpgSourceConfig> sources) async {
    final prefs = await SharedPreferences.getInstance();
    final userOnly = sources.where((s) => !s.isProvider).toList(growable: false);
    await prefs.setString(_sourcesKey, jsonEncode(userOnly.map((s) => s.toJson()).toList()));
  }

  /// "Added sources take precedence over the provider guide" (IPTVnator
  /// toggle). Default off — the provider feed first, added sources fill
  /// gaps (TiviMate Premium model).
  Future<bool> loadAddedSourcesFirst() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_precedenceKey) ?? false;
  }

  Future<void> saveAddedSourcesFirst(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_precedenceKey, value);
  }

  Future<Map<String, IptvEpgMapping>> loadMappings() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_mappingKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, IptvEpgMapping>{};
      for (final entry in decoded.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        try {
          final mapping = IptvEpgMapping.fromJson(entry.value as Map<String, dynamic>);
          if (mapping.xmltvId.isEmpty) continue;
          out[entry.key] = mapping;
        } catch (_) {
          // One bad row does not drop the rest.
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveMapping(String channelKey, IptvEpgMapping mapping) async {
    final mappings = await loadMappings();
    mappings[channelKey] = mapping;
    await _writeMappings(mappings);
  }

  /// Restores auto-matching for [channelKey].
  Future<void> clearMapping(String channelKey) async {
    final mappings = await loadMappings();
    if (mappings.remove(channelKey) == null) return;
    await _writeMappings(mappings);
  }

  /// Replace the whole mapping table (deleting a source clears every
  /// mapping that pointed at it — a deleted source must not keep
  /// matching channels).
  Future<void> saveMappings(Map<String, IptvEpgMapping> mappings) => _writeMappings(mappings);

  Future<void> _writeMappings(Map<String, IptvEpgMapping> mappings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _mappingKey,
      jsonEncode(mappings.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  Future<Map<String, IptvEpgSourceStatus>> loadStatuses() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_statusKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return {};
      final out = <String, IptvEpgSourceStatus>{};
      for (final entry in decoded.entries) {
        if (entry.value is! Map<String, dynamic>) continue;
        try {
          out[entry.key] = IptvEpgSourceStatus.fromJson(entry.value as Map<String, dynamic>);
        } catch (_) {
          // One bad row does not drop the rest.
        }
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  Future<void> saveStatus(String sourceId, IptvEpgSourceStatus status) async {
    final statuses = await loadStatuses();
    statuses[sourceId] = status;
    await _writeStatuses(statuses);
  }

  /// Replace the whole status table (deleting a source drops its status
  /// row with it).
  Future<void> saveStatuses(Map<String, IptvEpgSourceStatus> statuses) => _writeStatuses(statuses);

  Future<void> _writeStatuses(Map<String, IptvEpgSourceStatus> statuses) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _statusKey,
      jsonEncode(statuses.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  /// The channel-list fingerprint the update-on-playlist-change check
  /// compares against (see `IptvClient.iptvChannels`). Null before the
  /// first list load — the first load stores it without refreshing.
  Future<int?> loadChannelFingerprint() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_fingerprintKey);
  }

  Future<void> saveChannelFingerprint(int fingerprint) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_fingerprintKey, fingerprint);
  }
}

/// Why a channel has no EPG (the "Channels without guide" grouping, and
/// the EPG details "why" line). A channel with no match says *why* —
/// never a bare empty row.
enum IptvEpgNoGuideReason { noSource, noMatch, sourceFailed, notLoaded }

/// One channel's EPG assignment state, for the guide long-press "EPG
/// details" view: which source serves it, which XMLTV id matched, how it
/// matched, and — when it has nothing — why.
class IptvChannelEpgDetail {
  final String channelKey;
  final String? channelName;

  /// The source that served the programmes (or the source a manual
  /// assignment points at). Null when no source serves the channel.
  final String? sourceId;
  final String? sourceName;

  /// The XMLTV channel id that matched (or was assigned).
  final String? matchedXmltvId;

  /// How it matched: `'tvg-id'`, `'name'`, or `'manual'`. Null when
  /// nothing matched.
  final String? matchMethod;

  /// Programmes in the requested window.
  final int programCount;

  /// When the channel's cached entry was fetched (null when never
  /// fetched), and when it expires (null for manual-only / never).
  final DateTime? lastFetch;
  final DateTime? nextFetch;

  /// Why the channel has no guide. Null when it has programmes.
  final IptvEpgNoGuideReason? noGuideReason;

  const IptvChannelEpgDetail({
    required this.channelKey,
    this.channelName,
    this.sourceId,
    this.sourceName,
    this.matchedXmltvId,
    this.matchMethod,
    this.programCount = 0,
    this.lastFetch,
    this.nextFetch,
    this.noGuideReason,
  });

  bool get hasGuide => programCount > 0;
}

/// One XMLTV channel id from one loaded feed, for the Assign EPG picker
/// (search is local, over these already-downloaded indexes).
class IptvEpgFeedChannel {
  final String sourceId;
  final String sourceName;
  final String xmltvId;
  final int programCount;

  const IptvEpgFeedChannel({
    required this.sourceId,
    required this.sourceName,
    required this.xmltvId,
    required this.programCount,
  });
}

/// One channel with no EPG, for the "Channels without guide" overview.
class IptvChannelWithoutGuide {
  final String channelKey;
  final String channelName;
  final IptvEpgNoGuideReason reason;

  const IptvChannelWithoutGuide({
    required this.channelKey,
    required this.channelName,
    required this.reason,
  });
}

/// What "Reload TV details" found (the recovery action for D1-poisoned
/// entries): the channel list was re-fetched and the EPG refreshed, and
/// these counts say what came back. `withGuide` counts channels whose
/// guide the downloaded feeds can serve (by id, name, or manual
/// assignment) — channels whose guide comes only from the provider's
/// per-channel lookup are counted once browsed.
class IptvReloadTvDetailsResult {
  final int channelsLoaded;
  final int withGuide;
  final int withoutGuide;
  final int feedChannelIds;

  const IptvReloadTvDetailsResult({
    required this.channelsLoaded,
    required this.withGuide,
    required this.withoutGuide,
    required this.feedChannelIds,
  });
}
