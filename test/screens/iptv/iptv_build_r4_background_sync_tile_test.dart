// R4.3 — the background sync tile in Settings → IPTV
// (v1.0.13-2.25.0+185), NEW-API tests.
//
// These tests reference the R4 tile (`t.iptv.backgroundSync*`) and the
// last-run record, so this file FAILS TO LOAD on base bc6b9d3af — that
// is the failing-first evidence for the tile; the pre-fix-API
// failing-first tests live in iptv_build_r4_background_sync_test.dart.
//
// The tile shows the last background run (when it ran + what happened)
// and, when the OS is deferring background work, the diagnostics
// verdict that explains the deferral — so a run that never lands
// explains itself instead of looking broken.

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/iptv_settings_screen.dart';
import 'package:plezy/services/background_work_diagnostics_service.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/iptv/iptv_background_sync.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

XtreamConnection _trexConnection() => XtreamConnection(
      id: 'trex',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: 'pa' 'ss',
      createdAt: DateTime.utc(2026, 11, 6),
    );

/// Registry with a fake live stream: the real Drift `watchConnections()`
/// stream schedules a zero-duration close timer when its StreamBuilder
/// unmounts, which the test framework flags as a pending timer. The
/// screen under test only needs the connection list, so the stream is a
/// fixed value while `list()` / `upsert()` still hit the real
/// in-memory DB.
class _FakeConnectionRegistry extends ConnectionRegistry {
  _FakeConnectionRegistry(super.db);

  @override
  Stream<List<Connection>> watchConnections() => Stream.value([_trexConnection()]);
}

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    await StorageService.getInstance();
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() {
    IptvCatalogDiskCache.debugDisableDisk = false;
  });

  Future<void> pumpSettings(
    WidgetTester tester, {
    BackgroundWorkDiagnosticsService? diagnostics,
  }) async {
    CredentialVault.resetKeyForTesting();
    await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final registry = _FakeConnectionRegistry(db);
    await registry.upsert(_trexConnection());
    final manager = MultiServerManager();
    final provider = testMultiServerProvider(manager);
    addTearDown(() {
      provider.dispose();
      manager.dispose();
    });
    tester.view.physicalSize = const Size(840, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
          Provider<ConnectionRegistry>.value(value: registry),
        ],
        child: InputModeTracker(
          child: MaterialApp(
            theme: monoTheme(MonoPalette.dark),
            home: IptvSettingsScreen(backgroundWorkDiagnosticsService: diagnostics),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(t.iptv.backgroundSync), 200);
    // The tile is below the fold, so it is only built (and only starts
    // its async last-run read) during the scroll. Give that read a real
    // async gap, then pump twice: the first pump lets the read finish
    // and setState, the second renders the rebuilt tile. A single pump
    // leaves the tile showing '' (not yet loaded) at assertion time.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump();
  }

  Future<void> seedLastRun(WidgetTester tester, Map<String, Object?> record) async {
    // A SharedPreferencesWithCache write never completes inside
    // testWidgets' fake async zone (it awaits the platform write, which
    // needs the real event loop) — do it in real async. Reads are fine
    // in fake async; only the write deadlocks.
    await tester.runAsync(() async {
      final prefs = await BaseSharedPreferencesService.sharedCache();
      await prefs.setString(IptvBackgroundSync.lastRunPrefsKey, jsonEncode(record));
    });
  }

  Map<String, Object?> runRecord({
    required Map<String, String> outcomes,
    int hoursAgo = 2,
    int requests = 6,
    bool retry = false,
    String? skipped,
  }) =>
      {
        'ranAtMs': DateTime.now().subtract(Duration(hours: hoursAgo)).millisecondsSinceEpoch,
        'connections': {'conn-xt-1': outcomes},
        'requests': requests,
        'retry': retry,
        'skipped': skipped,
      };

  group('R4.3 — the background sync tile', () {
    testWidgets('shows Never run when no background sync has ever run', (tester) async {
      await pumpSettings(tester);
      expect(find.text(t.iptv.backgroundSync), findsOneWidget);
      expect(find.text(t.iptv.backgroundSyncNever), findsOneWidget);
      expect(find.textContaining('Last run'), findsNothing);
    });

    testWidgets('shows the last run and its outcome after a clean run', (tester) async {
      await seedLastRun(tester, runRecord(outcomes: {
        'live': 'synced',
        'movie': 'synced',
        'series': 'synced',
      }));
      await pumpSettings(tester);
      expect(find.text(t.iptv.backgroundSync), findsOneWidget);
      expect(find.textContaining('Last run'), findsOneWidget);
      expect(find.textContaining(t.iptv.backgroundSyncAllSynced), findsOneWidget);
      expect(find.text(t.iptv.backgroundSyncNever), findsNothing);
    });

    testWidgets('shows the partial summary when a type failed', (tester) async {
      await seedLastRun(tester, runRecord(
        outcomes: {'live': 'synced', 'movie': 'synced', 'series': 'failed'},
        retry: true,
      ));
      await pumpSettings(tester);
      expect(find.textContaining(t.iptv.backgroundSyncPartial(synced: 2, failed: 1)), findsOneWidget);
      expect(find.textContaining(t.iptv.backgroundSyncAllSynced), findsNothing);
    });

    testWidgets('shows why a run was skipped while a stream was playing', (tester) async {
      // The callback returns before loading connections when a stream
      // is playing, so the record has no per-connection outcomes —
      // only the skip reason.
      await seedLastRun(tester, {
        'ranAtMs': DateTime.now().subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
        'connections': <String, Object?>{},
        'requests': 0,
        'retry': true,
        'skipped': 'playing',
      });
      await pumpSettings(tester);
      expect(find.textContaining(t.iptv.backgroundSyncSkippedPlaying), findsOneWidget);
    });

    testWidgets('shows the diagnostics verdict when the OS defers background work', (tester) async {
      const channel = MethodChannel('com.plezy/device.settings-background-test-r4');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => switch (call.method) {
          'getBackgroundWorkSignals' => {
              'verdict': 'blocked',
              'reasons': ['background_restricted'],
            },
          'openBackgroundSettings' => true,
          _ => null,
        },
      );
      final diagnostics = BackgroundWorkDiagnosticsService.forTesting(channel: channel);
      await diagnostics.refresh();
      addTearDown(() async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        diagnostics.dispose();
      });
      await pumpSettings(tester, diagnostics: diagnostics);
      expect(find.text(t.downloads.backgroundWarning.statusBlocked), findsOneWidget);
    });
  });
}
