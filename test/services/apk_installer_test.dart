import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/apk_installer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.matt.plezytv/apk_install');

  setUp(() {
    ApkInstaller.debugPlatformIsAndroid = true;
  });

  tearDown(() {
    ApkInstaller.debugPlatformIsAndroid = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  void mockChannel(Future<dynamic> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, handler);
  }

  test('installApk calls the channel with the file path and returns true', () async {
    String? receivedMethod;
    Map<Object?, Object?>? receivedArgs;
    mockChannel((call) async {
      receivedMethod = call.method;
      receivedArgs = Map.of(call.arguments as Map);
      return true;
    });
    final file = File('/cache/pleztv-update.apk');
    expect(await ApkInstaller.installApk(file), isTrue);
    expect(receivedMethod, 'installApk');
    expect(receivedArgs, {'filePath': '/cache/pleztv-update.apk'});
  });

  test('returns false when the platform reports no handler', () async {
    mockChannel((_) async => false);
    expect(await ApkInstaller.installApk(File('/cache/pleztv-update.apk')), isFalse);
  });

  test('returns false on non-Android without touching the channel', () async {
    ApkInstaller.debugPlatformIsAndroid = false;
    var called = false;
    mockChannel((_) async {
      called = true;
      return true;
    });
    expect(await ApkInstaller.installApk(File('/cache/pleztv-update.apk')), isFalse);
    expect(called, isFalse);
  });

  test('PlatformException becomes ApkInstallException with the native code', () async {
    mockChannel((_) async => throw PlatformException(code: 'file_not_found', message: 'no such file'));
    await expectLater(
      ApkInstaller.installApk(File('/cache/pleztv-update.apk')),
      throwsA(
        isA<ApkInstallException>()
            .having((e) => e.code, 'code', 'file_not_found')
            .having((e) => e.message, 'message', 'no such file'),
      ),
    );
  });

  test('a missing channel returns false instead of throwing', () async {
    mockChannel((_) async => throw MissingPluginException());
    expect(await ApkInstaller.installApk(File('/cache/pleztv-update.apk')), isFalse);
  });
}
