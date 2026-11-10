// INDEPENDENT TESTER widget probe for build #20 (Trex 403 User-Agent fix).
//
// The builder did not write a widget test for the new Settings → IPTV →
// Xtream User-Agent group, so this one is the tester's own: it pumps the
// REAL IptvSettingsScreen and proves the group renders, the default
// subtitle is VLC, picking Custom reveals the custom text row, and a stored
// custom value shows in the subtitle. No live panel: fakes only.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/iptv_settings_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
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
      password: 'pass',
      createdAt: DateTime.utc(2026, 11, 6),
    );

class _FakeConnectionRegistry extends ConnectionRegistry {
  _FakeConnectionRegistry(super.db);

  @override
  Stream<List<Connection>> watchConnections() => Stream.value([_trexConnection()]);
}

/// Minimal fake API: answers the login probe the connections list runs, so
/// the screen never touches the network.
class _FakeXtreamApi extends XtreamApi {
  _FakeXtreamApi()
      : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pass');

  @override
  Future<Map<String, dynamic>?> getUserInfo() async => {'status': 'Active'};
}

IptvClient _trexClient() {
  final client = IptvClient.xtream(xtreamConnection: _trexConnection());
  client.testXtreamApi = _FakeXtreamApi();
  return client;
}

Future<void> _pumpScreen(WidgetTester tester) async {
  CredentialVault.resetKeyForTesting();
  await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(() async => db.close());
  final registry = _FakeConnectionRegistry(db);
  await registry.upsert(_trexConnection());

  final manager = MultiServerManager();
  manager.debugRegisterClientForTesting(_trexClient());
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
        child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const IptvSettingsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('en'));

  late Directory epgTempDir;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    await StorageService.getInstance();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_ua_widget_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  group('Tester probe #20 — Xtream User-Agent settings group', () {
    testWidgets('group renders with the VLC default subtitle', (tester) async {
      await _pumpScreen(tester);

      await tester.scrollUntilVisible(find.text(t.iptv.xtreamUserAgent), 200);
      expect(find.text(t.iptv.xtreamSection), findsOneWidget);
      expect(find.text(t.iptv.xtreamUserAgent), findsOneWidget);
      // The subtitle is the resolved UA that will be sent.
      expect(find.text('VLC'), findsOneWidget);
      // The custom text row is hidden until Custom is picked.
      expect(find.text(t.iptv.xtreamUserAgentCustomTitle), findsNothing);
    });

    testWidgets('picking Custom reveals the custom text row and stores the choice', (tester) async {
      await _pumpScreen(tester);

      await tester.scrollUntilVisible(find.text(t.iptv.xtreamUserAgent), 200);
      await tester.tap(find.text(t.iptv.xtreamUserAgent));
      await tester.pumpAndSettle();

      // The selection dialog offers all four choices. 'VLC' is also the
      // tile subtitle behind the dialog, so it is expected twice.
      expect(find.text(t.iptv.xtreamUserAgentVlc), findsWidgets);
      expect(find.text(t.iptv.xtreamUserAgentSmarters), findsOneWidget);
      expect(find.text(t.iptv.xtreamUserAgentBrowser), findsOneWidget);
      expect(find.text(t.iptv.xtreamUserAgentCustom), findsOneWidget);

      await tester.tap(find.text(t.iptv.xtreamUserAgentCustom));
      await tester.pumpAndSettle();

      final settings = SettingsService.instance;
      expect(settings.read(SettingsService.iptvXtreamUserAgent), 'custom');
      await tester.scrollUntilVisible(find.text(t.iptv.xtreamUserAgentCustomTitle), 200);
      expect(find.text(t.iptv.xtreamUserAgentCustomTitle), findsOneWidget);
      expect(find.text(t.iptv.xtreamUserAgentCustomHint), findsOneWidget);
      // Blank custom text: the subtitle shows the fallback.
      expect(find.text('Custom · VLC'), findsOneWidget);
    });

    testWidgets('a stored custom value shows in the subtitle', (tester) async {
      final settings = await SettingsService.getInstance();
      await settings.write(SettingsService.iptvXtreamUserAgent, 'custom');
      await settings.write(SettingsService.iptvXtreamUserAgentCustom, 'MyAgent/9');

      await _pumpScreen(tester);

      await tester.scrollUntilVisible(find.text(t.iptv.xtreamUserAgent), 200);
      // The value shows twice by design: the selection tile subtitle AND
      // the custom text row subtitle both show the stored custom text.
      expect(find.text('MyAgent/9'), findsWidgets);
      expect(find.text(t.iptv.xtreamUserAgentCustomTitle), findsOneWidget);
    });
  });
}
