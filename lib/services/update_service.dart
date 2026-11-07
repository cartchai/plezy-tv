import 'package:flutter/foundation.dart';
import 'package:auto_updater/auto_updater.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'base_shared_preferences_service.dart';

/// Service to check for new versions on GitHub
/// Only enabled when ENABLE_UPDATE_CHECK build flag is set
///
/// Upstream Plezy delegates to Sparkle/WinSparkle on desktop; the PlezTV
/// fork does NOT (no fork appcast exists — see the notes below), so every
/// platform uses the GitHub API check + browser link dialog.
///
/// PlezTV fork notes (build #6):
/// - The check points at the FORK repo (cartchai/plezy-tv), not upstream
///   edde746/plezy — an update must never offer an upstream Plezy build.
/// - The native desktop updater is disabled for the fork: there is no fork
///   appcast yet, and the upstream feed would offer upstream builds. Until a
///   fork appcast exists, every platform uses the GitHub API + browser flow.
/// - On Android the flow is: check -> dialog with version + changelog ->
///   "Download APK" opens the release's .apk asset in the browser -> the
///   user opens the download and the system installer puts it over the
///   current install. All current builds are debug-signed with the same
///   debug key, so the over-the-top update keeps its signature. Switching
///   to release signing later WILL break this path (signature mismatch) and
///   must be handled then, not now.
class UpdateService {
  static const String _githubRepo = 'cartchai/plezy-tv';

  /// Public releases page, linked from the Settings Updates section.
  static const String releasesUrl = 'https://github.com/cartchai/plezy-tv/releases';

  /// Upstream appcast — deliberately NOT used by the fork (see class doc).
  static const String _feedUrl = 'https://cdn.jsdelivr.net/gh/edde746/plezy@appcast/appcast.xml';

  static const String _keySkippedVersion = 'update_skipped_version';
  static const String _keyLastCheckTime = 'update_last_check_time';

  // Check cooldown: 6 hours
  static const Duration _checkCooldown = Duration(hours: 6);

  static bool _nativeUpdaterInitialized = false;

  /// Check if update checking is enabled via build flag
  static bool get isUpdateCheckEnabled {
    return const bool.fromEnvironment('ENABLE_UPDATE_CHECK', defaultValue: false);
  }

  /// Whether any in-app update path applies to this install.
  /// False inside a packaged (MSIX/Store) install: the Store owns updates and
  /// the package directory is read-only, so neither WinSparkle nor the GitHub
  /// fallback dialog has anything it can do. Gates the settings entry too, so
  /// no dead affordance ships.
  static bool get isUpdateCheckAvailable => isUpdateCheckEnabled && !PlatformDetector.isPackagedInstall();

  /// Whether the native auto_updater (Sparkle/WinSparkle) should be used.
  /// Fork: always false — there is no PlezTV appcast, and the upstream feed
  /// would offer upstream Plezy builds to a PlezTV install. Every platform
  /// uses the GitHub API + browser flow until a fork appcast exists.
  static bool get useNativeUpdater => false;

  /// Initialize the native auto_updater (Sparkle/WinSparkle).
  /// Call once at startup if [useNativeUpdater] is true.
  static Future<void> initNativeUpdater() async {
    if (_nativeUpdaterInitialized) return;

    try {
      await autoUpdater.setFeedURL(_feedUrl);
      _nativeUpdaterInitialized = true;
    } catch (error, stackTrace) {
      appLogger.e('Failed to initialize native auto updater', error: error, stackTrace: stackTrace);
    }
  }

  /// Trigger a background update check via Sparkle/WinSparkle.
  /// Only shows UI if an update is found.
  static Future<void> checkForUpdatesNative({bool inBackground = true}) async {
    if (!_nativeUpdaterInitialized) {
      await initNativeUpdater();
      if (!_nativeUpdaterInitialized) return;
    }
    try {
      await autoUpdater.checkForUpdates(inBackground: inBackground);
    } catch (error, stackTrace) {
      appLogger.e('Native update check failed', error: error, stackTrace: stackTrace);
    }
  }

  static Future<void> skipVersion(String version) async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_keySkippedVersion, version);
  }

  static Future<String?> getSkippedVersion() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    return prefs.getString(_keySkippedVersion);
  }

  /// Check if cooldown period has passed since last check
  static Future<bool> shouldCheckForUpdates() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final lastCheckString = prefs.getString(_keyLastCheckTime);
    if (lastCheckString == null) return true;

    final now = DateTime.now();
    final lastCheck = DateTime.tryParse(lastCheckString);
    if (lastCheck == null || lastCheck.isAfter(now)) {
      await prefs.remove(_keyLastCheckTime);
      return true;
    }

    return now.difference(lastCheck) >= _checkCooldown;
  }

  static Future<void> _updateLastCheckTime() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_keyLastCheckTime, DateTime.now().toIso8601String());
  }

  /// Internal method that performs the actual update check
  /// [respectCooldown] - if true, checks cooldown and records the attempt before the request
  /// [throwOnFailure] - if true, a failed check (network, non-200, bad payload)
  /// is rethrown instead of reading as "no update"
  static Future<Map<String, dynamic>?> _performUpdateCheck({
    required bool respectCooldown,
    MediaServerHttpClient? client,
    bool forceEnabled = false,
    bool throwOnFailure = false,
  }) async {
    if (!forceEnabled && !isUpdateCheckAvailable) {
      return null;
    }

    // Check cooldown if requested
    if (respectCooldown && !await shouldCheckForUpdates()) {
      return null;
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      if (respectCooldown) {
        await _updateLastCheckTime();
      }

      final response = await (client ?? httpClient).get(
        'https://api.github.com/repos/$_githubRepo/releases/latest',
        headers: {'Accept': 'application/vnd.github+json'},
      );

      if (response.statusCode != 200) {
        throw StateError('Release check returned HTTP ${response.statusCode}');
      }
      final data = response.data;
      final rawTag = data['tag_name'] as String?;

      // Tags may be "v2.25.2", "2.25.2" or "PlezTV v2.25.2" — take the
      // first numeric x.y[.z] run. A tag with no version in it is not an
      // update, not a crash.
      final cleanVersion = rawTag == null ? null : _extractVersion(rawTag);
      if (cleanVersion == null) {
        appLogger.w('Release check: tag "$rawTag" carries no version number');
        return null;
      }

      final hasUpdate = _isNewerVersion(cleanVersion, currentVersion);

      if (hasUpdate) {
        // Check if this version was skipped
        final skippedVersion = await getSkippedVersion();
        if (skippedVersion == cleanVersion) {
          return null;
        }

        return {
          'hasUpdate': true,
          'currentVersion': currentVersion,
          'latestVersion': cleanVersion,
          'releaseUrl': data['html_url'] as String? ?? releasesUrl,
          'releaseName': data['name'] as String? ?? 'Version $cleanVersion',
          'releaseNotes': data['body'] as String? ?? '',
          'publishedAt': data['published_at'] as String? ?? '',
          // The .apk asset is how Android installs over the top. GitHub
          // stores a spaced asset name with dots (PlezTV.v2.25.2.apk), so
          // match on the .apk suffix, never an exact filename. A release
          // with no .apk asset (e.g. v2.25.1 shipped source-only) still
          // reports the update — the dialog says plainly there is no APK
          // attached yet instead of offering a dead download.
          ..._apkAsset(data['assets']),
        };
      }
    } catch (error, stackTrace) {
      appLogger.e('Failed to check for updates', error: error, stackTrace: stackTrace);
      if (throwOnFailure) rethrow;
    }

    return null;
  }

  @visibleForTesting
  static Future<Map<String, dynamic>?> debugPerformUpdateCheck({
    required bool respectCooldown,
    required MediaServerHttpClient client,
    bool throwOnFailure = false,
  }) {
    return _performUpdateCheck(
      respectCooldown: respectCooldown,
      client: client,
      forceEnabled: true,
      throwOnFailure: throwOnFailure,
    );
  }

  /// Test-only override for the manual check, so widget tests can drive the
  /// up-to-date and update-available paths without the network. Same pattern
  /// as [debugPerformUpdateCheck] below and the *ForTesting seams elsewhere
  /// in the codebase. Never set in production code.
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function()? debugCheckForUpdatesOverride;

  /// Check for updates on GitHub (manual check, ignores cooldown)
  /// Returns a map with update info, or null when there is no update (or the
  /// release is skipped). Throws when the check itself fails, so the caller
  /// can say so instead of reporting the latest version.
  static Future<Map<String, dynamic>?> checkForUpdates() {
    final override = debugCheckForUpdatesOverride;
    if (override != null) return override();
    return _performUpdateCheck(respectCooldown: false, throwOnFailure: true);
  }

  /// First numeric `x.y` or `x.y.z` run inside a release tag, or null when
  /// the tag carries no version ("v2.25.2", "2.25.2", "PlezTV v2.25.2" all
  /// yield "2.25.2"; "nightly-build" yields null).
  static String? _extractVersion(String tag) {
    final match = RegExp(r'\d+\.\d+(?:\.\d+)?').firstMatch(tag);
    return match?.group(0);
  }

  /// The release's .apk asset, matched on the `.apk` suffix only (GitHub
  /// rewrites spaces to dots in stored asset names). Returns
  /// `{'apkAssetUrl': ..., 'apkAssetName': ..., 'apkAssetSize': ...}` or the
  /// same keys with null values when the release carries no .apk asset.
  /// The size (bytes, from the GitHub API) is what the in-app downloader
  /// verifies the finished file against before offering Install (build
  /// #10) — a truncated download must never reach the installer.
  static Map<String, Object?> _apkAsset(Object? assets) {
    String? url;
    String? name;
    int? size;
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map) continue;
        final assetName = asset['name'] as String?;
        if (assetName == null || !assetName.toLowerCase().endsWith('.apk')) continue;
        url = asset['browser_download_url'] as String?;
        name = assetName;
        size = asset['size'] as int?;
        break;
      }
    }
    return {'apkAssetUrl': url, 'apkAssetName': name, 'apkAssetSize': size};
  }

  /// Check for updates on startup (respects cooldown and skipped versions)
  /// Returns update info if available, null otherwise
  static Future<Map<String, dynamic>?> checkForUpdatesOnStartup() {
    return _performUpdateCheck(respectCooldown: true);
  }

  /// Parse version string into list of integers
  /// Handles versions like "1.2.3+4" by taking only the numeric parts
  static List<int> _parseVersionParts(String version) {
    return version.split('.').map((p) {
      final numPart = p.split('+').first.split('-').first;
      return int.tryParse(numPart) ?? 0;
    }).toList();
  }

  /// Compare two version strings
  /// Returns true if newVersion is newer than currentVersion
  static bool _isNewerVersion(String newVersion, String currentVersion) {
    try {
      final newParts = _parseVersionParts(newVersion);
      final currentParts = _parseVersionParts(currentVersion);

      // Compare each part
      final maxLength = newParts.length > currentParts.length ? newParts.length : currentParts.length;

      for (int i = 0; i < maxLength; i++) {
        final newPart = i < newParts.length ? newParts[i] : 0;
        final currentPart = i < currentParts.length ? currentParts[i] : 0;

        if (newPart > currentPart) return true;
        if (newPart < currentPart) return false;
      }

      return false;
    } catch (error, stackTrace) {
      appLogger.e('Error comparing versions', error: error, stackTrace: stackTrace);
      return false;
    }
  }
}
