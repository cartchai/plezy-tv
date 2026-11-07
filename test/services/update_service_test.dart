import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plezy/utils/media_server_http_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/update_service.dart';

import '../test_helpers/prefs.dart';

void main() {
  const lastCheckKey = 'update_last_check_time';

  setUp(resetSharedPreferencesForTest);
  PackageInfo.setMockInitialValues(
    appName: 'Plezy',
    packageName: 'com.plezy.test',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );

  test('malformed cooldown state fails open and removes the invalid value', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(lastCheckKey, 'not-an-instant');

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), isNull);
  });

  test('future cooldown state fails open and removes the invalid value', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(lastCheckKey, DateTime.now().add(const Duration(days: 30)).toIso8601String());

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), isNull);
  });

  test('recent valid cooldown state suppresses a duplicate check and remains stored', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final recent = DateTime.now().subtract(const Duration(minutes: 5)).toIso8601String();
    await prefs.setString(lastCheckKey, recent);

    expect(await UpdateService.shouldCheckForUpdates(), isFalse);
    expect(prefs.getString(lastCheckKey), recent);
  });

  test('old valid cooldown state permits a new check', () async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final old = DateTime.now().subtract(const Duration(days: 2)).toIso8601String();
    await prefs.setString(lastCheckKey, old);

    expect(await UpdateService.shouldCheckForUpdates(), isTrue);
    expect(prefs.getString(lastCheckKey), old);
  });

  final failedResponses = <String, Future<http.Response> Function()>{
    'timeout': () async => throw TimeoutException('request timed out'),
    'non-200 response': () async => http.Response('unavailable', 503),
    'parse failure': () async => http.Response('not-json', 200, headers: {'content-type': 'application/json'}),
  };

  for (final failure in failedResponses.entries) {
    test('a manual check reports a ${failure.key} as a failure, not as the latest version', () async {
      final client = MediaServerHttpClient(client: MockClient((_) => failure.value()));
      addTearDown(client.close);

      await expectLater(
        UpdateService.debugPerformUpdateCheck(respectCooldown: false, client: client, throwOnFailure: true),
        throwsA(anything),
      );
    });
  }

  test('a manual check that finds no newer release returns null', () async {
    final client = MediaServerHttpClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'tag_name': 'v1.0.0', 'html_url': 'https://example.com', 'published_at': '2026-01-01'}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(client.close);

    expect(
      await UpdateService.debugPerformUpdateCheck(respectCooldown: false, client: client, throwOnFailure: true),
      isNull,
    );
  });

  // Build #6: the fork's tags are "PlezTV vX.Y.Z", and releases may carry
  // no .apk asset (v2.25.1 shipped source-only). The mocked current version
  // for this file is 1.0.0 (see setUp above).
  MediaServerHttpClient releaseClient(Map<String, dynamic> release) {
    final client = MediaServerHttpClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(release),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(client.close);
    return client;
  }

  Future<Map<String, dynamic>?> checkRelease(Map<String, dynamic> release) {
    return UpdateService.debugPerformUpdateCheck(
      respectCooldown: false,
      client: releaseClient(release),
      throwOnFailure: true,
    );
  }

  test('a "PlezTV vX.Y.Z" tag parses and compares as newer', () async {
    final info = await checkRelease({
      'tag_name': 'PlezTV v1.0.1',
      'html_url': 'https://github.com/cartchai/plezy-tv/releases/tag/v1.0.1',
      'name': 'PlezTV v1.0.1',
      'body': '• Fixed the thing',
      'published_at': '2026-11-06T00:00:00Z',
      'assets': [],
    });

    expect(info, isNotNull);
    expect(info!['hasUpdate'], isTrue);
    expect(info['latestVersion'], '1.0.1');
    expect(info['currentVersion'], '1.0.0');
    expect(info['releaseNotes'], '• Fixed the thing');
  });

  test('a release carrying a dotted .apk asset exposes its download URL', () async {
    final info = await checkRelease({
      'tag_name': 'v1.0.1',
      'html_url': 'https://github.com/cartchai/plezy-tv/releases/tag/v1.0.1',
      'published_at': '2026-11-06T00:00:00Z',
      // GitHub rewrites spaces to dots in stored asset names.
      'assets': [
        {'name': 'PlezTV.v1.0.1.apk', 'browser_download_url': 'https://github.com/cartchai/plezy-tv/releases/download/v1.0.1/PlezTV.v1.0.1.apk'},
        {'name': 'Source code (zip)', 'browser_download_url': 'https://example.com/source.zip'},
      ],
    });

    expect(info, isNotNull);
    expect(info!['apkAssetName'], 'PlezTV.v1.0.1.apk');
    expect(info['apkAssetUrl'], 'https://github.com/cartchai/plezy-tv/releases/download/v1.0.1/PlezTV.v1.0.1.apk');
  });

  test('a release carrying a dotted .apk asset exposes its size for the in-app download check', () async {
    // Build #10: the in-app downloader verifies the finished file against
    // the release asset size, so the size must ride along with the URL.
    final info = await checkRelease({
      'tag_name': 'v1.0.1',
      'html_url': 'https://github.com/cartchai/plezy-tv/releases/tag/v1.0.1',
      'published_at': '2026-11-06T00:00:00Z',
      'assets': [
        {
          'name': 'PlezTV.v1.0.1.apk',
          'browser_download_url': 'https://github.com/cartchai/plezy-tv/releases/download/v1.0.1/PlezTV.v1.0.1.apk',
          'size': 361550680,
        },
      ],
    });

    expect(info, isNotNull);
    expect(info!['apkAssetSize'], 361550680);
  });

  test('a release with no .apk asset still reports the update, with no download URL', () async {
    final info = await checkRelease({
      'tag_name': 'v1.0.1',
      'html_url': 'https://github.com/cartchai/plezy-tv/releases/tag/v1.0.1',
      'published_at': '2026-11-06T00:00:00Z',
      'assets': [
        {'name': 'Source code (zip)', 'browser_download_url': 'https://example.com/source.zip'},
        {'name': 'Source code (tar.gz)', 'browser_download_url': 'https://example.com/source.tar.gz'},
      ],
    });

    expect(info, isNotNull);
    expect(info!['hasUpdate'], isTrue);
    expect(info['apkAssetUrl'], isNull);
    expect(info['apkAssetName'], isNull);
  });

  test('a tag with no version number in it is not an update and does not throw', () async {
    final info = await checkRelease({
      'tag_name': 'nightly-build',
      'html_url': 'https://example.com',
      'published_at': '2026-11-06T00:00:00Z',
      'assets': [],
    });

    expect(info, isNull);
  });

  test('missing published_at and html_url do not break the update result', () async {
    final info = await checkRelease({
      'tag_name': 'v1.0.1',
      'assets': [],
    });

    expect(info, isNotNull);
    expect(info!['hasUpdate'], isTrue);
    expect(info['releaseUrl'], UpdateService.releasesUrl);
    expect(info['publishedAt'], '');
  });

  for (final failure in failedResponses.entries) {
    test('startup ${failure.key} records cooldown before request and manual check bypasses it', () async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      final cooldownAtRequest = <String?>[];
      var requestCount = 0;
      final client = MediaServerHttpClient(
        client: MockClient((_) async {
          requestCount++;
          cooldownAtRequest.add(prefs.getString(lastCheckKey));
          return failure.value();
        }),
      );
      addTearDown(client.close);

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: true, client: client), isNull);
      expect(requestCount, 1);
      expect(cooldownAtRequest.single, isNotNull);
      final recordedCooldown = prefs.getString(lastCheckKey);
      expect(recordedCooldown, cooldownAtRequest.single);
      expect(DateTime.now().difference(DateTime.parse(recordedCooldown!)), lessThan(const Duration(minutes: 1)));

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: true, client: client), isNull);
      expect(requestCount, 1, reason: 'a simulated next launch must honor the failed attempt cooldown');

      expect(await UpdateService.debugPerformUpdateCheck(respectCooldown: false, client: client), isNull);
      expect(requestCount, 2, reason: 'an explicit manual check must bypass a recent startup cooldown');
      expect(
        prefs.getString(lastCheckKey),
        recordedCooldown,
        reason: 'manual checks must not rewrite startup cooldown',
      );
    });
  }
}
