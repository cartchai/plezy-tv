import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:plezy/services/apk_update_downloader.dart';

void main() {
  group('ApkUpdateDownloader (build #10)', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pleztv-update-test-');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    File destination() => File('${tempDir.path}/pleztv-update.apk');

    Uri apkUrl() => Uri.parse(
      'https://github.com/cartchai/plezy-tv/releases/download/v2.25.6/PlezTV.v2.25.6.apk',
    );

    test('downloads in chunks, reports progress in order, verifies size', () async {
      final chunks = [for (var i = 0; i < 10; i++) Uint8List.fromList(List.filled(100, i))];
      const total = 1000;
      final progress = <(int, int)>[];
      final file = await ApkUpdateDownloader.download(
        url: apkUrl(),
        expectedSizeBytes: total,
        destination: destination(),
        client: _ChunkedFakeClient(chunks: chunks, contentLength: total),
        onProgress: (received, totalBytes) => progress.add((received, totalBytes)),
      );
      expect(await file.length(), total);
      expect(progress.map((p) => p.$1), [100, 200, 300, 400, 500, 600, 700, 800, 900, 1000]);
      expect(progress.map((p) => p.$2), everyElement(total));
      final content = await file.readAsBytes();
      expect(content.sublist(0, 100), everyElement(0));
      expect(content.sublist(900), everyElement(9));
    });

    test('size mismatch throws and deletes the partial file', () async {
      final chunks = [Uint8List.fromList(List.filled(1000, 1))];
      final file = destination();
      await expectLater(
        ApkUpdateDownloader.download(
          url: apkUrl(),
          expectedSizeBytes: 999,
          destination: file,
          client: _ChunkedFakeClient(chunks: chunks, contentLength: 1000),
        ),
        throwsA(
          isA<ApkDownloadSizeMismatch>()
              .having((e) => e.expected, 'expected', 999)
              .having((e) => e.actual, 'actual', 1000),
        ),
      );
      expect(await file.exists(), isFalse);
    });

    test('HTTP error throws and deletes the partial file', () async {
      final file = destination();
      await expectLater(
        ApkUpdateDownloader.download(
          url: apkUrl(),
          expectedSizeBytes: 1000,
          destination: file,
          client: _ChunkedFakeClient(chunks: const [], statusCode: 404),
        ),
        throwsA(isA<ApkDownloadFailed>()),
      );
      expect(await file.exists(), isFalse);
    });

    test('cancel mid-download throws and deletes the partial file', () async {
      final chunks = [for (var i = 0; i < 10; i++) Uint8List.fromList(List.filled(100, i))];
      final controller = ApkDownloadController();
      final file = destination();
      await expectLater(
        ApkUpdateDownloader.download(
          url: apkUrl(),
          expectedSizeBytes: 1000,
          destination: file,
          client: _DelayedChunkedFakeClient(chunks: chunks, contentLength: 1000),
          controller: controller,
          onProgress: (_, _) => controller.cancel(),
        ),
        throwsA(isA<ApkDownloadCancelled>()),
      );
      expect(await file.exists(), isFalse);
    });

    test('unknown total reports -1 and still completes', () async {
      final chunks = [Uint8List.fromList(List.filled(250, 7))];
      final progress = <(int, int)>[];
      final file = await ApkUpdateDownloader.download(
        url: apkUrl(),
        expectedSizeBytes: null,
        destination: destination(),
        client: _ChunkedFakeClient(chunks: chunks, contentLength: null),
        onProgress: (received, totalBytes) => progress.add((received, totalBytes)),
      );
      expect(await file.length(), 250);
      expect(progress, [(250, -1)]);
    });
  });

  group('formatDownloadBytes', () {
    test('formats bytes, kilobytes and megabytes', () {
      expect(formatDownloadBytes(512), '512 B');
      expect(formatDownloadBytes(1023), '1023 B');
      expect(formatDownloadBytes(1024), '1 KB');
      expect(formatDownloadBytes(845 * 1024), '845 KB');
      expect(formatDownloadBytes(12 * 1024 * 1024 + 300 * 1024), '12.3 MB');
    });
  });
}

/// Fake HTTP client returning the given chunks as a streamed response.
/// No real network — the URL is never fetched.
class _ChunkedFakeClient extends http.BaseClient {
  _ChunkedFakeClient({required this.chunks, this.statusCode = 200, this.contentLength});

  final List<Uint8List> chunks;
  final int statusCode;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.fromIterable(chunks),
      statusCode,
      contentLength: contentLength,
    );
  }
}

/// Same as [_ChunkedFakeClient] but with a delay between chunks, so a
/// cancel issued from the first progress callback lands mid-download
/// instead of after it.
class _DelayedChunkedFakeClient extends http.BaseClient {
  _DelayedChunkedFakeClient({required this.chunks, this.contentLength});

  final List<Uint8List> chunks;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    Stream<List<int>> stream() async* {
      for (final chunk in chunks) {
        await Future.delayed(const Duration(milliseconds: 20));
        yield chunk;
      }
    }

    return http.StreamedResponse(stream(), 200, contentLength: contentLength);
  }
}
