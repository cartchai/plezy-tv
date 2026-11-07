import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:plezy/utils/app_logger.dart';

/// Why the platform refused to open the installer. [code] is the channel
/// error code: `invalid_argument`, `file_not_found`, `bad_file` or `failed`.
class ApkInstallException implements Exception {
  const ApkInstallException(this.code, [this.message]);

  final String code;
  final String? message;

  @override
  String toString() => 'ApkInstallException($code${message == null ? '' : ': $message'})';
}

/// Opens the Android system install prompt for a downloaded APK (build
/// #10), over the `com.matt.plezytv/apk_install` channel. The native side
/// shares the file through the app's FileProvider
/// (`com.matt.plezytv.fileprovider`) and fires an ACTION_VIEW intent with
/// `application/vnd.android.package-archive`. Only Android can install an
/// APK this way — on every other platform (and on a build whose native side
/// never registered the channel) this returns false instead of throwing.
class ApkInstaller {
  static const MethodChannel _channel = MethodChannel('com.matt.plezytv/apk_install');

  /// Test-only override for the Android platform check: unit tests run on
  /// the host platform, so they set this true to drive the channel.
  /// Same pattern as AppIconService's test seam. Never set in production.
  @visibleForTesting
  static bool? debugPlatformIsAndroid;

  /// Opens the system installer for the APK at [file]. Returns true when
  /// the installer opened, false when the device has no app to handle the
  /// install intent or the platform cannot install APKs. Throws
  /// [ApkInstallException] when the platform refuses (missing file, bad
  /// path, …). The install itself is the system's job from here on: on
  /// first use Android asks the user to allow "Install unknown apps" for
  /// PlezTV, then installs over the current build — the fixed debug
  /// keystore keeps the signature, so the over-the-top update works.
  static Future<bool> installApk(File file) async {
    final isAndroid = debugPlatformIsAndroid ?? Platform.isAndroid;
    if (!isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('installApk', {'filePath': file.path}) ?? false;
    } on PlatformException catch (e) {
      throw ApkInstallException(e.code, e.message);
    } on MissingPluginException {
      appLogger.w('APK installer channel is missing on this build');
      return false;
    }
  }
}
