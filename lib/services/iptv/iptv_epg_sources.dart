import 'dart:convert';

import 'package:plezy/exceptions/media_server_exceptions.dart';
import 'package:plezy/i18n/strings.g.dart';
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

  String get _validatorsKey => 'iptv_epg_feed_validators:$connectionId';

  /// Conditional-fetch validators (1.2.2 I9) per feed [cacheKey]: the
  /// ETag / Last-Modified the server sent with the feed, sent back as
  /// If-None-Match / If-Modified-Since on the next refresh. A 304 means
  /// the feed on disk is current — no download, no re-parse. Both null
  /// when the server sends no validators (a dynamically generated
  /// xmltv.php likely sends none) — the next fetch is then
  /// unconditional, exactly as before. Corrupt rows read as empty.
  Future<({String? etag, String? lastModified})> loadValidators(String cacheKey) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_validatorsKey);
    if (raw == null || raw.isEmpty) return (etag: null, lastModified: null);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return (etag: null, lastModified: null);
      final row = decoded[cacheKey];
      if (row is! Map<String, dynamic>) return (etag: null, lastModified: null);
      return (etag: row['etag'] as String?, lastModified: row['lastModified'] as String?);
    } catch (_) {
      return (etag: null, lastModified: null);
    }
  }

  /// Store the validators from the latest feed response, replacing
  /// whatever was stored for [cacheKey] — the validators describe the
  /// current representation. Saving both null removes the row (the
  /// server sent no validators). Best-effort callers never throw on a
  /// lost validator: the next refresh just downloads in full.
  Future<void> saveValidators(String cacheKey, String? etag, String? lastModified) async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic> all = {};
    try {
      final raw = prefs.getString(_validatorsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) all = Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // A corrupt table reads as empty; the save below replaces it.
    }
    if (etag == null && lastModified == null) {
      all.remove(cacheKey);
    } else {
      all[cacheKey] = {
        'etag': ?etag,
        'lastModified': ?lastModified,
      };
    }
    await prefs.setString(_validatorsKey, jsonEncode(all));
  }

  /// Forget every stored validator (Clear guide): a 304 against a
  /// deleted feed has no guide to reuse.
  Future<void> clearValidators() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_validatorsKey);
  }
}

/// Why a channel has no EPG (the "Channels without guide" grouping, and
/// the EPG details "why" line). A channel with no match says *why* —
/// never a bare empty row.
/// Why a channel has no EPG (the "Channels without guide" grouping, and
/// the EPG details "why" line). A channel with no match says *why* —
/// never a bare empty row.
enum IptvEpgNoGuideReason {
  noSource,
  noMatch,
  sourceFailed,
  notLoaded,

  /// The name names more than one feed channel (1.2.5 Fix 7): never a
  /// guess — the user Assigns one manually.
  ambiguous,

  /// The name names only a feed channel from another country (Fix 7).
  foreign,

  /// A feed id was identified (by id or by name) but it has no
  /// programmes in the window (Fix 7).
  matchedButNoPrograms,
}

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

  /// Which source served this channel's programmes (1.2.8 F8): the
  /// short-EPG lookup or a feed match (by id or by name). Null when
  /// nothing served it — the details sheet shows '—'.
  final IptvEpgSource? epgSource;

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
    this.epgSource,
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

  /// The feed's display names for this id (1.2.5 Fix 2): the human
  /// names the picker shows and searches. Empty when the feed lists
  /// no `<channel>` element for the id.
  final List<String> displayNames;

  const IptvEpgFeedChannel({
    required this.sourceId,
    required this.sourceName,
    required this.xmltvId,
    required this.programCount,
    this.displayNames = const [],
  });
}

/// One channel with no EPG, for the "Channels without guide" overview.
class IptvChannelWithoutGuide {
  final String channelKey;
  final String channelName;
  final IptvEpgNoGuideReason reason;

  /// The feed ids the name tier could not choose between (1.2.5 Fix 7):
  /// the candidates for an `ambiguous` or `foreign` row — or the
  /// identified-but-empty ids for a `matchedButNoPrograms` row — so the
  /// user can Assign one manually. Empty for every other reason.
  final List<String> candidates;

  const IptvChannelWithoutGuide({
    required this.channelKey,
    required this.channelName,
    required this.reason,
    this.candidates = const [],
  });
}

/// What "Reload TV details" found (the recovery action for D1-poisoned
/// entries): the channel list was re-fetched and the EPG refreshed, and
/// these counts say what came back. `withGuide` counts channels whose
/// guide the downloaded feeds can serve (by id, name, or manual
/// assignment) — channels whose guide comes only from the provider's
/// per-channel lookup are counted once browsed.
/// Per-tier match counts for one Reload (1.2.5 Fix 1): how the channels
/// that got a guide got it, and — for the ones that did not — why.
/// The dialog and the Logs export print these, so a feed that loads
/// but matches nothing says which tier failed instead of only counting.
class IptvEpgMatchTiers {
  final int manual;
  final int tvgId;
  final int name;
  final int nameLoose;
  final int ambiguous;
  final int foreign;
  final int noTvgId;
  final int tvgIdNotInFeed;
  final int matchedButNoProgrammes;

  /// 1.2.8 F2: the split of [matchedButNoProgrammes] — the feed
  /// declaring the id with zero programmes vs programmes that exist
  /// but all fall outside the Reload window. The two sum to
  /// [matchedButNoProgrammes].
  final int matchedButNoProgrammesDeclared;
  final int matchedButNoProgrammesOutsideWindow;
  final int none;

  const IptvEpgMatchTiers({
    this.manual = 0,
    this.tvgId = 0,
    this.name = 0,
    this.nameLoose = 0,
    this.ambiguous = 0,
    this.foreign = 0,
    this.noTvgId = 0,
    this.tvgIdNotInFeed = 0,
    this.matchedButNoProgrammes = 0,
    this.matchedButNoProgrammesDeclared = 0,
    this.matchedButNoProgrammesOutsideWindow = 0,
    this.none = 0,
  });

  const IptvEpgMatchTiers.empty()
      : manual = 0,
        tvgId = 0,
        name = 0,
        nameLoose = 0,
        ambiguous = 0,
        foreign = 0,
        noTvgId = 0,
        tvgIdNotInFeed = 0,
        matchedButNoProgrammes = 0,
        matchedButNoProgrammesDeclared = 0,
        matchedButNoProgrammesOutsideWindow = 0,
        none = 0;

  /// Channels that got a guide, by any tier.
  int get matched => manual + tvgId + name + nameLoose;

  /// Channels that got no guide, for any reason.
  int get unmatched => ambiguous + foreign + noTvgId + tvgIdNotInFeed + matchedButNoProgrammes + none;
}

/// One feed channel, for the Reload report's feed sample (1.2.5 Fix 1):
/// the raw feed id with the human names the feed lists for it, so the
/// user can see what the feed actually calls its channels.
class IptvEpgFeedSample {
  final String xmltvId;
  final List<String> displayNames;
  final int programCount;

  const IptvEpgFeedSample({
    required this.xmltvId,
    this.displayNames = const [],
    this.programCount = 0,
  });
}

/// One unmatched channel, for the Reload report's unmatched sample
/// (1.2.5 Fix 1): the playlist name plus the ids the matcher tried.
class IptvEpgUnmatchedSample {
  final String channelName;
  final String? epgChannelId;
  final String? tvgId;

  /// 1.2.8 F7: the blocked reason for this row ('ambiguous',
  /// 'foreign', 'no-tvg-id', 'tvg-id-not-in-feed',
  /// 'matched-but-no-programmes-declared',
  /// 'matched-but-no-programmes-outside-window', 'no-feed') — the
  /// dialog renders it next to the name.
  final String reason;

  const IptvEpgUnmatchedSample({
    required this.channelName,
    this.epgChannelId,
    this.tvgId,
    required this.reason,
  });
}

/// One feed candidate behind a foreign block (1.2.8 F9): the feed id
/// and the countries its id suffix / display-name tags name.
class IptvEpgForeignCandidate {
  final String xmltvId;
  final List<String> countries;

  const IptvEpgForeignCandidate({required this.xmltvId, this.countries = const []});
}

/// One foreign-blocked channel, for the Reload report's foreign
/// diagnostic (1.2.8 F9): the playlist name, the country the playlist
/// name claims, and the feed candidates the country gate refused.
class IptvEpgForeignSample {
  final String channelName;
  final String? playlistCountry;
  final List<IptvEpgForeignCandidate> candidates;

  const IptvEpgForeignSample({
    required this.channelName,
    this.playlistCountry,
    this.candidates = const [],
  });
}

class IptvReloadTvDetailsResult {
  final int channelsLoaded;
  final int withGuide;
  final int withoutGuide;
  final int feedChannelIds;

  /// Per-tier match counts + no-match reasons (1.2.5 Fix 1).
  final IptvEpgMatchTiers matchTiers;

  /// Up to 5 feed channels from the first loaded feed (1.2.5 Fix 1):
  /// what the feed actually calls its channels.
  final List<IptvEpgFeedSample> feedSamples;

  /// Up to 5 unmatched channels, in list order (1.2.5 Fix 1).
  final List<IptvEpgUnmatchedSample> sampleUnmatched;

  /// How many live channels carry a non-empty `epg_channel_id`
  /// (1.2.5 Fix 1): when this is 0, no tvg-id tier can ever match and
  /// the name tier is doing all the work. Null when the channel list
  /// was not re-fetched.
  final int? epgChannelIdCount;

  /// 1.2.8 F3: matches over ALL channels including hidden ones (the
  /// visible counts above are the filtered list). Null when the
  /// channel list was not re-fetched.
  final int? withGuideAllChannels;
  final int? channelsLoadedAll;

  /// 1.2.8 F2: the nearest retained programme start to now across
  /// the outside-window rows (null when no row is outside-window) —
  /// how far out the feed's schedule runs.
  final DateTime? nearestOutsideWindowProgramme;

  /// 1.2.8 F9: the first 5 foreign-blocked rows with their refused
  /// candidates, and the total count of refused candidates whose
  /// countries are all language-only codes (an "EN:"-tagged feed
  /// standing in for a US channel).
  final List<IptvEpgForeignSample> foreignSamples;
  final int foreignLanguageTaggedCandidateCount;

  /// Why the channel-list re-fetch failed, when it did (1.2.3 RC1).
  /// Null when the list loaded. The report dialog names this instead of
  /// showing nothing — a 403 is "the panel denied access", a timeout is
  /// "the panel is not answering".
  final IptvEpgFeedOutcomeKind? channelListFailureKind;

  /// URL-free short text for the list failure (see [epgFeedErrorReason]).
  final String? channelListFailureReason;

  /// One outcome per enabled source (1.2.3, Matt's follow-up): the
  /// report must name the FEED outcome, not just the channel counts —
  /// feed 403, feed timeout, feed loaded-but-matched-nothing, and feed
  /// loaded-with-matches are four different stories.
  final List<IptvEpgFeedOutcome> feedOutcomes;

  const IptvReloadTvDetailsResult({
    required this.channelsLoaded,
    required this.withGuide,
    required this.withoutGuide,
    required this.feedChannelIds,
    this.channelListFailureKind,
    this.channelListFailureReason,
    this.feedOutcomes = const [],
    this.matchTiers = const IptvEpgMatchTiers.empty(),
    this.feedSamples = const [],
    this.sampleUnmatched = const [],
    this.epgChannelIdCount,
    this.withGuideAllChannels,
    this.channelsLoadedAll,
    this.nearestOutsideWindowProgramme,
    this.foreignSamples = const [],
    this.foreignLanguageTaggedCandidateCount = 0,
  });
}

/// The result of "Update now" (1.2.3 RC2): the same per-source feed
/// outcomes as a Reload, without a channel-list re-fetch — Update now
/// never touches the catalog, so no match counts, only the feed's own
/// size (see [IptvEpgFeedOutcome.matchedChannels]).
class IptvEpgUpdateNowResult {
  final List<IptvEpgFeedOutcome> feedOutcomes;

  const IptvEpgUpdateNowResult({required this.feedOutcomes});
}

/// Which source served a channel's EPG (build #17, §10) — the split the
/// guide coverage diagnostic reports. `unknown` is for entries read from
/// disk files written before this build recorded the source.
/// (Moved here from iptv_live_tv.dart in 1.2.8: the EPG detail and the
/// Reload result in this file need the type without an import cycle.)
enum IptvEpgSource { feedById, feedByName, shortEpg, none, unknown }

/// How one EPG source's feed ended up during a Reload / Update-now
/// attempt (PlezTV 1.2.3) — so the report dialog can name the feed
/// outcome instead of leaving the user to guess whether the feed
/// failed or loaded-but-matched-nothing.
enum IptvEpgFeedOutcomeKind {
  /// The feed loaded and matched at least one of this connection's
  /// channels.
  loaded,

  /// The feed loaded but matched NONE of this connection's channels
  /// (M2 — the feed is fine, the ids/names do not line up).
  loadedNoMatch,

  /// The panel denied access (HTTP 403 — and 401, same family).
  denied,

  /// The panel did not answer (timeout / connection error).
  notAnswering,

  /// The feed load was deferred because something is playing (D1b) —
  /// it never downloaded, and will retry when playback stops.
  deferred,

  /// Any other failure (reason carries the detail).
  failed,
}

/// One source's outcome inside a Reload / Update-now report.
class IptvEpgFeedOutcome {
  /// The source id (`'provider'` or a user source id).
  final String sourceId;

  /// Display name shown in the report.
  final String sourceName;

  final IptvEpgFeedOutcomeKind kind;

  /// Distinct XMLTV channel ids in the loaded feed (0 when the feed
  /// never loaded).
  final int feedChannels;

  /// How many of this connection's channels the feed can serve. Null
  /// when the channel list was not available (Update now never
  /// re-fetches it) — the report then names the feed's own size
  /// instead of a match count.
  final int? matchedChannels;

  /// Short failure text for [IptvEpgFeedOutcomeKind.denied],
  /// [IptvEpgFeedOutcomeKind.notAnswering] and
  /// [IptvEpgFeedOutcomeKind.failed]. Never contains a URL — see
  /// [epgFeedErrorReason].
  final String? reason;

  /// Programmes parsed before the I8 window filter (1.2.5 Fix 1).
  /// Null when the feed never loaded.
  final int? feedProgramsParsed;

  /// Programmes retained after the window filter (1.2.5 Fix 1) — the
  /// guide's own size. Null when the feed never loaded.
  final int? feedProgramsRetained;

  /// Distinct `<channel>` ids in the feed (1.2.5 Fix 1). Null when the
  /// feed never loaded.
  final int? feedChannelsParsed;

  const IptvEpgFeedOutcome({
    required this.sourceId,
    required this.sourceName,
    required this.kind,
    this.feedChannels = 0,
    this.matchedChannels,
    this.reason,
    this.feedProgramsParsed,
    this.feedProgramsRetained,
    this.feedChannelsParsed,
  });
}

/// Classify an EPG feed/list failure for display (PlezTV 1.2.3): a 403
/// (or 401) means the panel denied access; a timeout or connection
/// error means the panel is not answering; anything else is a plain
/// failure.
IptvEpgFeedOutcomeKind classifyEpgFeedError(Object error) {
  if (error is MediaServerAuthException) {
    return (error.statusCode == 401 || error.statusCode == 403)
        ? IptvEpgFeedOutcomeKind.denied
        : IptvEpgFeedOutcomeKind.failed;
  }
  final mapped = MediaServerHttpException.from(error);
  if (mapped.statusCode == 403) return IptvEpgFeedOutcomeKind.denied;
  if (mapped.isTransient) return IptvEpgFeedOutcomeKind.notAnswering;
  // Some paths wrap the failure as a plain error whose text still
  // names the status (e.g. a fake, or a StateError carrying the panel
  // reply). The 5-minute "failed recently" StateError carries no
  // status code and falls through to `failed`, as it should.
  if (mapped.message.contains('403')) return IptvEpgFeedOutcomeKind.denied;
  return IptvEpgFeedOutcomeKind.failed;
}

/// One report line for a feed outcome (PlezTV 1.2.3): the user must be
/// able to tell from the dialog alone whether the feed failed or
/// loaded-but-matched-nothing. Shared by the Reload report and the
/// Update-now report. [channelsTotal] is the connection's channel
/// count (0 when the list was not available — the lines then name the
/// feed's own size instead of a match count).
String epgFeedOutcomeLine(IptvEpgFeedOutcome outcome, int channelsTotal) {
  return switch (outcome.kind) {
    IptvEpgFeedOutcomeKind.loaded when outcome.matchedChannels != null => t.iptv.epgFeedOutcomeLoaded(
      source: outcome.sourceName,
      matched: outcome.matchedChannels!,
      channels: channelsTotal,
    ),
    IptvEpgFeedOutcomeKind.loaded when outcome.feedChannels == 0 => t.iptv.epgFeedOutcomeLoadedEmpty(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.loaded => t.iptv.epgFeedOutcomeLoadedFeedOnly(source: outcome.sourceName, feedChannels: outcome.feedChannels),
    IptvEpgFeedOutcomeKind.loadedNoMatch when outcome.feedChannelsParsed == 0 =>
      t.iptv.epgFeedOutcomeLoadedNoChannels(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.loadedNoMatch when outcome.feedProgramsRetained == 0 && (outcome.feedProgramsParsed ?? 0) > 0 =>
      t.iptv.epgFeedOutcomeLoadedProgramsOutsideWindow(source: outcome.sourceName, parsed: outcome.feedProgramsParsed!),
    IptvEpgFeedOutcomeKind.loadedNoMatch when outcome.feedProgramsRetained == 0 =>
      t.iptv.epgFeedOutcomeLoadedNoPrograms(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.loadedNoMatch => t.iptv.epgFeedOutcomeLoadedNoMatch(source: outcome.sourceName, channels: channelsTotal),
    IptvEpgFeedOutcomeKind.denied => t.iptv.epgFeedOutcomeDenied(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.notAnswering => t.iptv.epgFeedOutcomeNotAnswering(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.deferred => t.iptv.epgFeedOutcomeDeferred(source: outcome.sourceName),
    IptvEpgFeedOutcomeKind.failed => t.iptv.epgFeedOutcomeFailed(source: outcome.sourceName, reason: outcome.reason ?? ''),
  };
}

/// A URL-free short reason for an EPG failure (PlezTV 1.2.3): the
/// exception's own message — never [Object.toString], because a
/// [MediaServerHttpException] appends the request host+path to its
/// toString, and the panel URL must never surface in the UI (or in a
/// persisted status).
String epgFeedErrorReason(Object error) {
  if (error is MediaServerException) return error.message;
  return error.toString();
}
