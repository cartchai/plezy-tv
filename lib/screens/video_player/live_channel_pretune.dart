// ignore_for_file: prefer_initializing_formals
// The constructor's parameters keep public names because the pretuner is
// constructed from another library (the player screen), which cannot pass
// private named parameters — so initializing formals cannot be used here.
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:plezy/media/live_tv_support.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/mpv/models.dart';

/// One neighbour channel, tuned in the background while the current channel
/// plays: its session is started and its stream URL resolved, so a zap to it
/// skips the session-start round trip. The playlist probe (IPTV only) records
/// whether the manifest answered, so a zap to a dead neighbour can fail fast
/// instead of opening mpv and waiting out the live open deadline.
///
/// Pre-tune is NOT a second stream: it fetches the playlist (a few KB of
/// manifest) and holds the session ready. No media flows until the viewer
/// zaps — Matt's line allows exactly one simultaneous stream.
class PretunedChannel {
  PretunedChannel({
    required this.channelKey,
    required this.session,
    required this.streamUrl,
    required this.readyAt,
    this.probeStatus,
  });

  final String channelKey;
  final LiveTvPlaybackSession session;
  final String streamUrl;
  final DateTime readyAt;

  /// The playlist status when probed, null when the channel was not probed
  /// (non-IPTV) or the probe itself could not run (timeout, DNS).
  final int? probeStatus;

  /// The neighbour's playlist already refused with a fatal status: zapping
  /// to it would only open mpv onto a dead stream.
  bool get isDead => probeStatus != null && fatalPlaybackHttpStatuses.contains(probeStatus!);
}

/// GETs an IPTV playlist (a few KB of manifest, no media) to learn whether
/// the neighbour is alive before the viewer zaps to it. Returns the status,
/// or null when the probe itself could not run — inconclusive, never a
/// verdict: the zap still opens normally rather than trusting an absent
/// answer.
Future<int?> probeIptvPlaylist(String url, Map<String, String> headers) async {
  final client = http.Client();
  try {
    final response = await client.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 5));
    return response.statusCode;
  } catch (_) {
    return null;
  } finally {
    client.close();
  }
}

/// Background pre-tuner for the channels adjacent to the one playing.
///
/// The operations are injected so tests can fake the session negotiation:
/// [startSession] starts a channel's playback session, [resolveUrl] resolves
/// its live-edge stream URL, [discardSession] retires a held session.
/// [shouldProbe] decides per session whether the playlist probe runs — only
/// IPTV sessions serve a static manifest worth probing; a Plex/Jellyfin
/// session negotiates a transcode, and GETting its URL would pull transcode
/// output (a second stream). [probePlaylist] runs the probe when one is due.
class LiveChannelPretuner {
  LiveChannelPretuner({
    required Future<LiveTvPlaybackSession?> Function(LiveTvChannel channel) startSession,
    required Future<String?> Function(LiveTvPlaybackSession session) resolveUrl,
    required void Function(LiveTvPlaybackSession session) discardSession,
    Future<int?> Function(String url, Map<String, String> headers)? probePlaylist,
    bool Function(LiveTvPlaybackSession session)? shouldProbe,
    this.entryTtl = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : _startSession = startSession,
       _resolveUrl = resolveUrl,
       _discardSession = discardSession,
       _probePlaylist = probePlaylist,
       _shouldProbe = shouldProbe,
       _now = now ?? DateTime.now;

  final Duration entryTtl;

  final Future<LiveTvPlaybackSession?> Function(LiveTvChannel channel) _startSession;
  final Future<String?> Function(LiveTvPlaybackSession session) _resolveUrl;
  final void Function(LiveTvPlaybackSession session) _discardSession;
  final Future<int?> Function(String url, Map<String, String> headers)? _probePlaylist;
  final bool Function(LiveTvPlaybackSession session)? _shouldProbe;
  final DateTime Function() _now;

  final Map<String, PretunedChannel> _entries = {};
  final Set<String> _inFlight = {};
  var _wantedKeys = <String>{};
  var _disposed = false;

  /// Starts background tunes for the neighbours of [currentIndex] and drops
  /// entries that are no longer neighbours or have expired. Fire-and-forget:
  /// a tune that completes after the viewer moved on is discarded, never
  /// stored, so a stale entry can never be zapped to.
  void refresh(List<LiveTvChannel> channels, int currentIndex) {
    final wanted = <String>{};
    for (final delta in [-1, 1]) {
      final index = currentIndex + delta;
      if (index >= 0 && index < channels.length) wanted.add(channels[index].key);
    }
    _wantedKeys = wanted;
    for (final key in _entries.keys.toList()) {
      final entry = _entries[key]!;
      if (!wanted.contains(key) || _isExpired(entry)) {
        _entries.remove(key);
        _discard(entry.session);
      }
    }
    for (final channel in channels) {
      if (!wanted.contains(channel.key)) continue;
      if (_entries.containsKey(channel.key) || _inFlight.contains(channel.key)) continue;
      _inFlight.add(channel.key);
      unawaited(_pretune(channel));
    }
  }

  /// Takes the entry for [channelKey] if it is live — removing it, so a
  /// consumed entry cannot be zapped to twice. Returns null when there is no
  /// entry, or the entry expired (the zap falls back to a cold start).
  PretunedChannel? take(String channelKey) {
    final entry = _entries.remove(channelKey);
    if (entry == null) return null;
    if (_isExpired(entry)) {
      _discard(entry.session);
      return null;
    }
    return entry;
  }

  /// Discards every held session. In-flight tunes that complete afterwards
  /// discard their session instead of storing it.
  void dispose() {
    _disposed = true;
    for (final entry in _entries.values) {
      _discard(entry.session);
    }
    _entries.clear();
    _wantedKeys = const {};
  }

  bool _isExpired(PretunedChannel entry) => _now().difference(entry.readyAt) >= entryTtl;

  void _discard(LiveTvPlaybackSession session) {
    try {
      _discardSession(session);
    } catch (_) {
      // Best-effort: a failed discard must never break a zap.
    }
  }

  Future<void> _pretune(LiveTvChannel channel) async {
    LiveTvPlaybackSession? session;
    try {
      session = await _startSession(channel);
      if (session == null || _disposed) return;
      final url = await _resolveUrl(session);
      if (url == null || _disposed) return;
      int? probeStatus;
      if (_shouldProbe?.call(session) == true && _probePlaylist != null) {
        try {
          probeStatus = await _probePlaylist(url, session.streamHeaders);
        } catch (_) {
          // Inconclusive (timeout, DNS): the entry is still usable — the
          // zap opens normally rather than trusting an absent verdict.
          probeStatus = null;
        }
      }
      if (_disposed || !_wantedKeys.contains(channel.key)) return;
      _entries[channel.key] = PretunedChannel(
        channelKey: channel.key,
        session: session,
        streamUrl: url,
        readyAt: _now(),
        probeStatus: probeStatus,
      );
      session = null;
    } catch (_) {
      // A failed pre-tune is best-effort: the zap falls back to the cold
      // path, so the failure is swallowed here rather than surfaced.
    } finally {
      _inFlight.remove(channel.key);
      if (session != null) _discard(session);
    }
  }
}
