import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Downloads a PlezTV release APK inside the app (build #10), so an Android
/// TV / Google TV — which has no browser download flow — can update without
/// leaving the app. Streams the file to disk in chunks (a release APK is
/// ~350 MB; it must never sit whole in memory), reports progress, and
/// verifies the finished file's size against the release asset size before
/// the caller offers Install. A partial file is always deleted, never left
/// behind for the installer to trip over.

/// Thrown when the download is cancelled via [ApkDownloadController.cancel].
class ApkDownloadCancelled implements Exception {
  const ApkDownloadCancelled();

  @override
  String toString() => 'ApkDownloadCancelled()';
}

/// Thrown when the download fails before completing (network error,
/// non-200 response). The partial file is deleted.
class ApkDownloadFailed implements Exception {
  const ApkDownloadFailed(this.message);

  final String message;

  @override
  String toString() => 'ApkDownloadFailed($message)';
}

/// Thrown when the finished file's size does not match the release asset
/// size — the download was truncated or the asset changed mid-download.
/// The partial file is deleted.
class ApkDownloadSizeMismatch implements Exception {
  const ApkDownloadSizeMismatch({required this.expected, required this.actual});

  final int expected;
  final int actual;

  @override
  String toString() => 'ApkDownloadSizeMismatch(expected $expected, got $actual)';
}

/// Cancels an in-flight APK download. The download stops after the current
/// chunk, the partial file is deleted, and [ApkDownloadCancelled] is thrown.
class ApkDownloadController {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// Human size for the download progress line: "12.3 MB", "845 KB", "512 B".
String formatDownloadBytes(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

class ApkUpdateDownloader {
  /// Test-only override for the download client, so widget tests can drive
  /// the update dialog with a fake HTTP client. Same pattern as
  /// [UpdateService.debugCheckForUpdatesOverride]. Never set in production
  /// code.
  @visibleForTesting
  static http.Client? debugClientOverride;

  /// Downloads the release APK at [url] to [destination], streaming it to
  /// disk. [expectedSizeBytes] is the release asset's size (from the GitHub
  /// API); when known, the finished file must match it exactly, or
  /// [ApkDownloadSizeMismatch] is thrown. When it is null, the response's
  /// content-length is the total, and with neither the total is -1
  /// (progress shows bytes only). [onProgress] fires after every chunk.
  /// [controller] cancels the download; [client] is the HTTP client to use
  /// (a fresh one is created when none is given).
  static Future<File> download({
    required Uri url,
    required int? expectedSizeBytes,
    required File destination,
    http.Client? client,
    ApkDownloadController? controller,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final ownedClient = client ?? debugClientOverride ?? http.Client();
    final closeClient = client == null && debugClientOverride == null;
    IOSink? sink;
    try {
      final response = await ownedClient.send(http.Request('GET', url));
      if (response.statusCode != 200) {
        throw ApkDownloadFailed('Download returned HTTP ${response.statusCode}');
      }
      // The release asset size is authoritative; the response length is the
      // fallback; -1 means the server sent neither (progress shows bytes).
      final total = expectedSizeBytes ?? response.contentLength ?? -1;
      var received = 0;
      sink = destination.openWrite();
      await for (final chunk in response.stream) {
        if (controller?.isCancelled == true) throw const ApkDownloadCancelled();
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (expectedSizeBytes != null) {
        final actual = await destination.length();
        if (actual != expectedSizeBytes) {
          throw ApkDownloadSizeMismatch(expected: expectedSizeBytes, actual: actual);
        }
      }
      return destination;
    } catch (e) {
      // A partial file must never survive a failed, cancelled or truncated
      // download — the installer would offer a broken APK.
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await destination.exists()) await destination.delete();
      } catch (_) {}
      if (e is ApkDownloadCancelled || e is ApkDownloadSizeMismatch || e is ApkDownloadFailed) rethrow;
      throw ApkDownloadFailed('$e');
    } finally {
      if (closeClient) ownedClient.close();
    }
  }
}
