import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/services/apk_installer.dart';
import 'package:plezy/services/apk_update_downloader.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/update_dialog.dart';

import '../test_helpers/io_fakes.dart';

/// Widget tests for the in-app update download dialog (build #10).
///
/// The dialog downloads the release APK itself on Android (fake HTTP
/// client via [ApkUpdateDownloader.debugClientOverride], fake path
/// provider for the cache dir, mocked installer channel) and falls back
/// to the browser "Download APK" button on other platforms. No real
/// network, no real install.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;
  const installerChannel = MethodChannel('com.matt.plezytv/apk_install');

  Map<String, dynamic> updateInfo({int? apkAssetSize}) => {
    'currentVersion': '2.25.5',
    'latestVersion': '2.25.6',
    'releaseUrl': 'https://github.com/cartchai/plezy-tv/releases/tag/v2.25.6',
    'releaseNotes': '• Fixed the thing',
    'apkAssetUrl': 'https://github.com/cartchai/plezy-tv/releases/download/v2.25.6/PlezTV.v2.25.6.apk',
    'apkAssetName': 'PlezTV.v2.25.6.apk',
    'apkAssetSize': apkAssetSize ?? 1000,
  };

  setUp(() async {
    LocaleSettings.setLocaleSync(AppLocale.en);
    tempDir = await Directory.systemTemp.createTemp('pleztv-update-dialog-test-');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tempDir);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    ApkInstaller.debugPlatformIsAndroid = true;
  });

  tearDown(() async {
    ApkUpdateDownloader.debugClientOverride = null;
    ApkInstaller.debugPlatformIsAndroid = null;
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      installerChannel,
      null,
    );
    PathProviderPlatform.instance = originalPathProvider;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  Future<void> pumpDialog(WidgetTester tester, Map<String, dynamic> info) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showUpdateAvailableDialog(
                    context,
                    info,
                    title: t.update.available,
                    dismissLabel: t.common.close,
                  ),
                  child: const Text('Check'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Check'));
    await tester.pumpAndSettle();
  }

  testWidgets('Android: Download fetches the APK in-app and Install opens the installer', (tester) async {
    ApkUpdateDownloader.debugClientOverride = _ChunkedFakeClient(
      chunks: [for (var i = 0; i < 10; i++) Uint8List.fromList(List.filled(100, i))],
      contentLength: 1000,
    );
    String? installedPath;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      installerChannel,
      (call) async {
        installedPath = (call.arguments as Map)['filePath'] as String?;
        return true;
      },
    );
    await pumpDialog(tester, updateInfo());

    expect(find.text(t.update.inAppDownloadHint), findsOneWidget);
    // The download writes a real file (dart:io), which only completes in
    // real async — run it in runAsync, then render the result.
    final downloadedFile = File('${tempDir.path}/temp/pleztv-update.apk');
    int? downloadedLength;
    await tester.runAsync(() async {
      await tester.tap(find.text(t.update.download));
      await Future<void>.delayed(const Duration(seconds: 1));
      if (await downloadedFile.exists()) downloadedLength = await downloadedFile.length();
    });
    await tester.pumpAndSettle();

    expect(find.text(t.update.downloadComplete), findsOneWidget);
    await tester.tap(find.text(t.update.install));
    await tester.pumpAndSettle();

    // The installer opened and the dialog closed behind it.
    expect(find.text(t.update.downloadComplete), findsNothing);
    expect(installedPath, isNotNull);
    expect(installedPath, endsWith('pleztv-update.apk'));
    expect(downloadedLength, 1000);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android: a truncated download shows the retry message', (tester) async {
    ApkUpdateDownloader.debugClientOverride = _ChunkedFakeClient(
      chunks: [Uint8List.fromList(List.filled(1000, 1))],
      contentLength: 1000,
    );
    await pumpDialog(tester, updateInfo(apkAssetSize: 999));

    await tester.runAsync(() async {
      await tester.tap(find.text(t.update.download));
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pumpAndSettle();

    expect(find.text(t.update.downloadSizeMismatch), findsOneWidget);
    expect(find.text(t.update.download), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('non-Android keeps the browser Download APK button', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await pumpDialog(tester, updateInfo());

    expect(find.text(t.update.installApkHint), findsOneWidget);
    expect(find.text(t.update.downloadApk), findsOneWidget);
    expect(find.text(t.update.download), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}

/// Fake HTTP client returning the given chunks as a streamed response.
/// No real network — the URL is never fetched.
class _ChunkedFakeClient extends http.BaseClient {
  _ChunkedFakeClient({required this.chunks, this.contentLength});

  final List<Uint8List> chunks;
  final int? contentLength;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(Stream.fromIterable(chunks), 200, contentLength: contentLength);
  }
}
