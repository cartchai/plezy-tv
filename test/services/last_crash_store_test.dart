// Unit tests — build #14 (v2.25.10): the on-device crash readout.
//
// The v2.25.9 startup crash was never reproduced in the harness, so the
// crash itself, from the phone, is the evidence. LastCrashCatcher persists
// the last fatal Dart error + stack to disk; Settings shows it on the next
// launch. These tests prove the store round-trips, redacts credentials out
// of the message, and that the catcher records through both handlers while
// still calling the previous handler — and that the known-benign RenderFlex
// overflow diagnostic does NOT overwrite the record.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show FlutterError, FlutterErrorDetails;
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/last_crash_store.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_last_crash_test_');
    LastCrashStore.debugDirectoryOverride = tempDir;
  });

  tearDown(() async {
    LastCrashStore.debugDirectoryOverride = null;
    LastCrashStore.resetForTesting();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('record then read round-trips the error, stack, source and time', () async {
    final stack = StackTrace.current;
    final when = DateTime.utc(2026, 11, 7, 18, 7, 30);
    LastCrashStore.record(
      StateError('boom on startup'),
      stackTrace: stack,
      source: 'uncaught',
      timestamp: when,
    );

    final record = await LastCrashStore.read();
    expect(record, isNotNull);
    expect(record!.errorType, 'StateError');
    expect(record.message, contains('boom on startup'));
    expect(record.stackTrace, stack.toString());
    expect(record.source, 'uncaught');
    expect(record.timestamp, when);
    expect(record.headline, '[uncaught] StateError: Bad state: boom on startup');
  });

  test('a second record overwrites the first', () async {
    LastCrashStore.record(StateError('first'), source: 'framework');
    LastCrashStore.record(ArgumentError('second'), source: 'uncaught');

    final record = await LastCrashStore.read();
    expect(record, isNotNull);
    expect(record!.errorType, 'ArgumentError');
    expect(record.source, 'uncaught');
  });

  test('clear removes the record', () async {
    LastCrashStore.record(StateError('boom'));
    expect(await LastCrashStore.read(), isNotNull);

    await LastCrashStore.clear();
    expect(await LastCrashStore.read(), isNull);
  });

  test('a corrupt file reads as no record', () async {
    final file = File('${tempDir.path}/${LastCrashStore.fileName}');
    await file.writeAsString('this is not json{{{');

    expect(await LastCrashStore.read(), isNull);
  });

  test('credentials are redacted out of the persisted message', () async {
    LastCrashStore.record(
      Exception(
        'request failed: https://panel.example.com:8080/player_api.php?username=user&password=hunter2',
      ),
      source: 'uncaught',
    );

    final file = File('${tempDir.path}/${LastCrashStore.fileName}');
    expect(file.existsSync(), isTrue);
    final persisted = await file.readAsString();
    expect(persisted, isNot(contains('hunter2')));
    expect(jsonDecode(persisted)['message'], isNot(contains('hunter2')));
  });

  group('LastCrashCatcher', () {
    late void Function(FlutterErrorDetails)? savedFlutterErrorHandler;
    late bool Function(Object, StackTrace)? savedDispatcherHandler;
    var flutterErrorCalls = 0;
    var dispatcherCalls = 0;

    setUp(() {
      savedFlutterErrorHandler = FlutterError.onError;
      savedDispatcherHandler = PlatformDispatcher.instance.onError;
      // Stub the previous handlers so the test framework never sees the
      // fired errors as test failures.
      FlutterError.onError = (_) => flutterErrorCalls++;
      PlatformDispatcher.instance.onError = (_, _) {
        dispatcherCalls++;
        return false;
      };
      LastCrashCatcher.install();
    });

    tearDown(() {
      FlutterError.onError = savedFlutterErrorHandler;
      PlatformDispatcher.instance.onError = savedDispatcherHandler;
      LastCrashCatcher.resetForTesting();
      flutterErrorCalls = 0;
      dispatcherCalls = 0;
    });

    test('FlutterError.onError records the error and still calls the previous handler', () async {
      FlutterError.onError!(
        FlutterErrorDetails(exception: StateError('framework boom'), stack: StackTrace.current),
      );

      final record = await LastCrashStore.read();
      expect(record, isNotNull);
      expect(record!.source, 'framework');
      expect(record.message, contains('framework boom'));
      expect(flutterErrorCalls, 1);
    });

    test('PlatformDispatcher.onError records the error and still calls the previous handler', () async {
      final handled = PlatformDispatcher.instance.onError!(StateError('uncaught boom'), StackTrace.current);

      final record = await LastCrashStore.read();
      expect(record, isNotNull);
      expect(record!.source, 'uncaught');
      expect(record.message, contains('uncaught boom'));
      expect(dispatcherCalls, 1);
      expect(handled, isFalse);
    });

    test('a RenderFlex overflow does NOT overwrite the recorded crash', () async {
      LastCrashStore.record(StateError('the real crash'), source: 'uncaught');

      FlutterError.onError!(
        FlutterErrorDetails(
          exception: FlutterError('A RenderFlex overflowed by 40 pixels on the right.'),
          stack: StackTrace.current,
        ),
      );

      final record = await LastCrashStore.read();
      expect(record, isNotNull);
      expect(record!.message, contains('the real crash'));
      // The previous handler still ran — only the recording was skipped.
      expect(flutterErrorCalls, 1);
    });
  });

  group('abnormal-exit flag (build #14, D-6)', () {
    test('first launch is not abnormal, a second launch without a clean exit is', () async {
      expect(await LastCrashStore.markLaunched(), isFalse);
      expect(LastCrashStore.abnormalExitDetected, isFalse);

      // No clean exit in between: the next launch finds 'running'.
      expect(await LastCrashStore.markLaunched(), isTrue);
      expect(LastCrashStore.abnormalExitDetected, isTrue);
    });

    test('a clean exit between launches clears the flag', () async {
      expect(await LastCrashStore.markLaunched(), isFalse);
      LastCrashStore.markCleanExit();

      expect(await LastCrashStore.markLaunched(), isFalse);
      expect(LastCrashStore.abnormalExitDetected, isFalse);
    });

    test('resetForTesting clears the flag', () async {
      await LastCrashStore.markLaunched();
      await LastCrashStore.markLaunched();
      expect(LastCrashStore.abnormalExitDetected, isTrue);

      LastCrashStore.resetForTesting();
      expect(LastCrashStore.abnormalExitDetected, isFalse);
    });
  });
}
