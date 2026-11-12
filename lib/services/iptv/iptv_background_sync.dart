import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../../connection/connection.dart';
import '../../connection/connection_registry.dart';
import '../../database/app_database.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../media/iptv_client.dart';
import '../../services/base_shared_preferences_service.dart';
import '../../services/settings_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/media_server_http_client.dart';
import 'iptv_playback_activity.dart';
import 'xtream_api.dart';

/// Dependencies for [IptvBackgroundSync.runOnce], injectable so tests can
/// run the callback without a database, a vault, or a panel.
class IptvBackgroundSyncDeps {
  const IptvBackgroundSyncDeps({this.connectionLoader, this.clientFactory});

  /// Loads the Xtream connections to sync. Defaults to the production
  /// Drift load ([IptvBackgroundSync._loadXtreamConnections]).
  final Future<List<XtreamConnection>> Function()? connectionLoader;

  /// Builds the client for a connection. Receives the User-Agent the
  /// callback resolved from SharedPreferences (D2) — the factory hands
  /// it to the client via [IptvClient.userAgentProvider] before the
  /// first request. Defaults to [IptvClient.forConnection].
  final IptvClient Function(XtreamConnection connection, {required String userAgent})? clientFactory;
}

/// Periodic background catalog sync (build v1.0.13, R4).
///
/// The catalog (live channels, VOD movies, series) is synced into the
/// local search index on a WorkManager periodic task at the user's
/// sync-interval setting, so search stays local-only and the catalog
/// stays fresh without the user opening the app. The task runs at most
/// once per interval, makes 0 requests when up-to-date and 6 per due
/// Xtream connection per run, and never runs while a stream is playing
/// or while the UI isolate is already syncing.
///
/// The callback runs in a raw Dart background isolate: no
/// SettingsService, no MultiServerManager, no plugin registration of
/// its own — everything it needs is read from SharedPreferences
/// directly (D2) or rebuilt from the stored connection rows (D3).
/// The module never throws out of [runOnce]: a failure is a return
/// value (retry or not) plus a last-run record.
class IptvBackgroundSync {
  /// The task name the callback receives.
  static const String taskName = 'iptv-catalog-sync';

  /// The WorkManager unique name (one task for all IPTV connections).
  static const String uniqueName = 'plezy-iptv-catalog-sync';

  /// SharedPreferences slot holding the last run's record (JSON).
  static const String lastRunPrefsKey = 'iptv_last_background_sync';

  /// SharedPreferences slot holding the interval (hours) the task is
  /// currently registered with, so an interval change can re-register
  /// with `update` instead of `keep`.
  static const String registeredHoursPrefsKey = 'iptv_background_sync_registered_hours';

  /// The cross-isolate sync stamp lives on [IptvClient]; re-exported
  /// here so callers (and tests) have one place to find the R4 keys.
  static const String runningStampPrefsKey = IptvClient.syncRunningStampPrefsKey;

  /// The playback mirror lives on [IptvPlaybackActivity]; re-exported
  /// here for the same reason.
  static const String playbackMirrorPrefsKey = IptvPlaybackActivity.playbackMirrorPrefsKey;

  /// Test seam: the platform guard is `Platform.isAndroid ||
  /// Platform.isIOS` (WorkManager is a mobile-only plugin). Tests run
  /// on Linux and set this to force the supported path.
  @visibleForTesting
  static bool debugForceSupportedPlatform = false;

  /// Notifier bumped whenever a run writes a last-run record, so the
  /// Settings → IPTV tile can re-read it without reopening the screen.
  static final ValueNotifier<int> lastRunVersion = ValueNotifier(0);

  static bool get _supportedPlatform =>
      debugForceSupportedPlatform || Platform.isAndroid || Platform.isIOS;

  /// Flex window for a periodic task: the run lands at the END of the
  /// interval (a 15 min flex on a 6 h interval would let the OS run it
  /// early; a 1 h flex on a 24 h+ interval keeps the same shape).
  /// WorkManager requires flex < frequency and >= 5 min.
  static Duration flexForInterval(int hours) =>
      hours >= 24 ? const Duration(hours: 1) : const Duration(minutes: 15);

  /// Register the WorkManager platform once at startup. Safe to call on
  /// unsupported platforms (a no-op there). Never throws — a failed
  /// initialize must not break startup.
  static Future<void> initialize() async {
    if (!_supportedPlatform) return;
    try {
      await Workmanager().initialize(iptvSyncCallbackDispatcher);
    } catch (e) {
      appLogger.w('IPTV background sync: WorkManager initialize failed', error: e);
    }
  }

  /// (Re-)register the periodic task at the user's sync-interval setting
  /// (6/12/24/168 h; 0 = manual-only, no task). Safe to call on every
  /// startup and after an interval change: when the registered interval
  /// already matches, `keep` leaves the existing task (and its timing)
  /// alone; when it changed, `update` replaces the spec without
  /// cancelling, so the schedule is preserved. Constraints are
  /// network-connected ONLY — never Wi-Fi-only or unmetered, because
  /// the working Trex path is mobile data and the home WiFi is
  /// Trex-blocked. Never throws.
  static Future<void> ensureRegistered({int? intervalHoursOverride}) async {
    if (!_supportedPlatform) return;
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final hours = intervalHoursOverride ??
          prefs.getInt(SettingsService.iptvCatalogSyncIntervalHours.key) ??
          SettingsService.iptvCatalogSyncIntervalHours.defaultValue;
      final registered = prefs.getInt(registeredHoursPrefsKey);
      if (hours == 0) {
        await Workmanager().cancelByUniqueName(uniqueName);
        await prefs.setInt(registeredHoursPrefsKey, 0);
        return;
      }
      // First registration (no marker yet) uses keep: there is no old
      // spec to preserve. A changed interval needs update — keep would
      // preserve the old frequency.
      final policy = registered == null || registered == hours
          ? ExistingPeriodicWorkPolicy.keep
          : ExistingPeriodicWorkPolicy.update;
      await Workmanager().registerPeriodicTask(
        uniqueName,
        taskName,
        frequency: Duration(hours: hours),
        flexInterval: flexForInterval(hours),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: policy,
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 15),
      );
      await prefs.setInt(registeredHoursPrefsKey, hours);
    } catch (e) {
      appLogger.w('IPTV background sync: registration failed', error: e);
    }
  }

  /// Re-register after the user changes the sync interval in Settings →
  /// IPTV (wired to the interval tile's `onAfterWrite`).
  static Future<void> applyInterval(int hours) => ensureRegistered(intervalHoursOverride: hours);

  /// True when a stream is playing, read from the SharedPreferences
  /// mirror (D4). The in-memory [IptvPlaybackActivity] is a fresh idle
  /// instance in a background isolate, so the mirror is the only signal
  /// the callback can trust. Never throws — an unreadable prefs store
  /// reads as "not playing".
  static Future<bool> isPlaybackActive() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      return prefs.getBool(playbackMirrorPrefsKey) ?? false;
    } catch (e) {
      appLogger.w('IPTV background sync: playback mirror unreadable', error: e);
      return false;
    }
  }

  /// The last run's record, or null when no run has ever completed (or
  /// the record is unreadable). Shape:
  /// `{ranAtMs, connections: {id: {live|movie|series: outcome}},
  /// requests, retry, skipped}` where `skipped` is null or one of
  /// 'playing' | 'already-running' | 'load-failed'.
  static Future<Map<String, Object?>?> readLastRun() async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final raw = prefs.getString(lastRunPrefsKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      return decoded;
    } catch (e) {
      appLogger.w('IPTV background sync: last-run record unreadable', error: e);
      return null;
    }
  }

  static Future<void> _writeLastRun(Map<String, Object?> record) async {
    try {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString(lastRunPrefsKey, jsonEncode(record));
      lastRunVersion.value++;
    } catch (e) {
      appLogger.w('IPTV background sync: last-run record unwritable', error: e);
    }
  }

  /// The callback body: sync every Xtream connection's catalog into the
  /// local search index. Returns true when WorkManager should treat the
  /// run as done (no retry) and false when it should retry with the
  /// exponential backoff:
  ///
  /// - transport failure on any type → false (retry; the panel may
  ///   answer next time);
  /// - 403/refusal on any type → true (never retry a refusal, D9);
  /// - timeout / oversize / partial → true (the guards kept the old
  ///   data, and re-running immediately would fetch the same answer);
  /// - playing, or another isolate already syncing → false for playing
  ///   (retry later), true for already-running (the UI sync is doing
  ///   the same work);
  /// - aborted (the platform stopped the worker) → false;
  /// - no connections, or everything up-to-date → true.
  ///
  /// [deps] injects the connection loader + client factory for tests.
  /// [abort] is fired by the platform's `onTaskStopped` handler.
  static Future<bool> runOnce({IptvBackgroundSyncDeps? deps, AbortController? abort}) async {
    // D4: never fetch on top of a live stream on a one-connection line.
    if (await isPlaybackActive()) {
      await _writeLastRun({
        'ranAtMs': DateTime.now().millisecondsSinceEpoch,
        'connections': <String, Object?>{},
        'requests': 0,
        'retry': true,
        'skipped': 'playing',
      });
      return false;
    }
    // D5: the UI isolate is already syncing — yield; its run does the
    // same work, so this run is a success, not a retry.
    if (await IptvClient.isSyncRunningElsewhere()) {
      await _writeLastRun({
        'ranAtMs': DateTime.now().millisecondsSinceEpoch,
        'connections': <String, Object?>{},
        'requests': 0,
        'retry': false,
        'skipped': 'already-running',
      });
      return true;
    }
    // D2: no SettingsService in a background isolate — interval + UA
    // come straight from SharedPreferences.
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final intervalHours = prefs.getInt(SettingsService.iptvCatalogSyncIntervalHours.key) ??
        SettingsService.iptvCatalogSyncIntervalHours.defaultValue;
    final userAgent = XtreamUserAgent.resolve(
      prefs.getString(SettingsService.iptvXtreamUserAgent.key) ?? XtreamUserAgent.defaultChoice,
      prefs.getString(SettingsService.iptvXtreamUserAgentCustom.key) ?? '',
    );

    // D3: connections are encrypted in Drift behind the OS keystore.
    // A vault-unavailable load is a retry, never a crash, never a
    // plaintext fallback.
    late final List<XtreamConnection> connections;
    try {
      final loader = deps?.connectionLoader ?? _loadXtreamConnections;
      connections = await loader();
    } catch (e) {
      appLogger.w('IPTV background sync: connections unreadable', error: e);
      await _writeLastRun({
        'ranAtMs': DateTime.now().millisecondsSinceEpoch,
        'connections': <String, Object?>{},
        'requests': 0,
        'retry': true,
        'skipped': 'load-failed',
      });
      return false;
    }
    if (connections.isEmpty) {
      await _writeLastRun({
        'ranAtMs': DateTime.now().millisecondsSinceEpoch,
        'connections': <String, Object?>{},
        'requests': 0,
        'retry': false,
        'skipped': null,
      });
      return true;
    }

    final clientFactory = deps?.clientFactory ??
        ((XtreamConnection connection, {required String userAgent}) {
          final client = IptvClient.forConnection(connection);
          client.userAgentProvider = () => userAgent;
          return client;
        });
    final outcomes = <String, Map<String, String>>{};
    var requests = 0;
    var retry = false;
    for (final connection in connections) {
      if (abort?.isAborted == true) return false;
      final client = clientFactory(connection, userAgent: userAgent);
      try {
        // D4 (per-type): playback started after the run began — the
        // engine bails with playbackAborted set.
        final result = await client.syncSearchIndexForBackground(
          intervalHours: intervalHours,
          abort: abort,
          isPlaybackActive: isPlaybackActive,
        );
        if (abort?.isAborted == true) return false;
        if (result.playbackAborted) return false;
        outcomes[connection.id] = {
          ...result.rows.map((type, count) => MapEntry(type, 'synced')),
          ...result.skipped,
        };
        requests += result.requests;
        if (result.transportFailedTypes.isNotEmpty) retry = true;
      } on MediaServerHttpException catch (e) {
        // The sync itself only escapes on abort (cancelled) — anything
        // else is unexpected, so treat the connection as failed and
        // retry the run.
        if (e.type == MediaServerHttpErrorType.cancelled || abort?.isAborted == true) return false;
        outcomes[connection.id] = {
          for (final type in const ['live', 'movie', 'series']) type: 'failed',
        };
        retry = true;
      } catch (e) {
        appLogger.w('IPTV background sync: sync failed for ${connection.id}', error: e);
        outcomes[connection.id] = {
          for (final type in const ['live', 'movie', 'series']) type: 'failed',
        };
        retry = true;
      } finally {
        client.close();
      }
    }
    await _writeLastRun({
      'ranAtMs': DateTime.now().millisecondsSinceEpoch,
      'connections': outcomes,
      'requests': requests,
      'retry': retry,
      'skipped': null,
    });
    return !retry;
  }

  static Future<List<XtreamConnection>> _loadXtreamConnections() async {
    final bootstrap = await AppDatabase.open();
    final db = bootstrap.database;
    try {
      final connections = await ConnectionRegistry(db).list();
      return connections.whereType<XtreamConnection>().toList();
    } finally {
      await db.close();
    }
  }
}

/// The WorkManager callback dispatcher (the top-level function
/// WorkManager calls in the background isolate). Routes by task name;
/// anything that is not the catalog sync is a success (nothing to do).
/// The platform tears the isolate down after the handler returns, so
/// the in-flight sync is aborted first when the platform stops the
/// worker — the next scheduled run picks the remaining types up.
@pragma('vm:entry-point')
void iptvSyncCallbackDispatcher() {
  final abort = AbortController();
  Workmanager().executeTask(
    (taskName, inputData) async {
      if (taskName != IptvBackgroundSync.taskName) return true;
      return IptvBackgroundSync.runOnce(abort: abort);
    },
    onTaskStopped: (taskName, reason) async {
      abort.abort();
    },
  );
}
