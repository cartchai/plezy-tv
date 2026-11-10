// Widget tests for build #27 (refusal recorder, v1.0.8).
//
// Proves the Settings → IPTV → Connection refusals row exists and opens
// the log screen, that recorded refusals render newest-first with their
// headers and body on expand, and that Clear empties the log. No live
// panel: fakes only.
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
import 'package:plezy/screens/settings/iptv_refusals_screen.dart';
import 'package:plezy/screens/settings/iptv_settings_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_refusal_log.dart';
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
  password: 'hunter-9',
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
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'hunter-9');

  @override
  Future<Map<String, dynamic>?> getUserInfo() async => {'status': 'Active'};
}

IptvClient _trexClient() {
  final client = IptvClient.xtream(xtreamConnection: _trexConnection());
  client.testXtreamApi = _FakeXtreamApi();
  return client;
}

IptvRefusalEntry _entry({
  required String action,
  int? statusCode = 403,
  String failureKind = 'http',
  Map<String, String> headers = const {'cf-ray': 'abc123', 'server': 'cloudflare'},
  String bodySnippet = 'Just a moment...',
  DateTime? timestamp,
}) {
  return IptvRefusalEntry(
    timestamp: timestamp ?? DateTime.utc(2026, 11, 10, 5, 40, 12),
    connectionName: 'Trex',
    action: action,
    statusCode: statusCode,
    failureKind: failureKind,
    headers: headers,
    bodySnippet: bodySnippet,
    userAgent: 'VLC',
    network: 'wifi',
  );
}

Future<void> _pumpRefusalsScreen(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(theme: monoTheme(MonoPalette.dark), home: const IptvRefusalsScreen()),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpSettingsScreen(WidgetTester tester) async {
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

  // Tall viewport: the IPTV settings screen is long and its rows live in
  // lazily-built slivers, so a phone-sized viewport leaves the Xtream
  // section unbuilt until scrolled toward — and the 200px-step scroll
  // helpers stop with the last row still below the fold. A tall surface
  // builds the whole screen up front; scrolling mechanics are not what
  // this test is proving.
  tester.view.physicalSize = const Size(840, 12000);
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
    IptvRefusalLog.debugResetInstance();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    await StorageService.getInstance();
    epgTempDir = await Directory.systemTemp.createTemp('plezy_refusals_widget_');
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => epgTempDir;
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDisableDisk = false;
    IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
    if (await epgTempDir.exists()) await epgTempDir.delete(recursive: true);
  });

  group('Refusals screen', () {
    testWidgets('empty log shows the empty state', (tester) async {
      await _pumpRefusalsScreen(tester);
      expect(find.text(t.iptv.refusalsTitle), findsOneWidget);
      expect(find.text(t.iptv.refusalsEmpty), findsOneWidget);
      expect(find.text(t.iptv.refusalsDescription), findsOneWidget);
    });

    testWidgets('recorded refusals render newest-first', (tester) async {
      final log = IptvRefusalLog.instance;
      // runAsync: record() touches SharedPreferencesWithCache, whose
      // first load is real async — awaiting it in testWidgets' fake
      // async zone parks the test (repo precedent: CredentialVault in
      // the #20 widget test). Real async here, fake async for the pump.
      await tester.runAsync(
        () => log.record(
          _entry(action: 'player_api.php', timestamp: DateTime.utc(2026, 11, 10, 5, 40, 0)),
        ),
      );
      await tester.runAsync(
        () => log.record(
          _entry(
            action: 'player_api.php?action=get_live_categories',
            timestamp: DateTime.utc(2026, 11, 10, 5, 41, 0),
          ),
        ),
      );
      await _pumpRefusalsScreen(tester);

      final titles = tester.widgetList<ExpansionTile>(find.byType(ExpansionTile)).toList();
      expect(titles, hasLength(2));
      expect(
        (titles.first.title as Text).data,
        'HTTP 403 · player_api.php?action=get_live_categories',
      );
      expect((titles.last.title as Text).data, 'HTTP 403 · player_api.php');
    });

    testWidgets('expanding an entry shows headers and body', (tester) async {
      await tester.runAsync(() => IptvRefusalLog.instance.record(_entry(action: 'player_api.php')));
      await _pumpRefusalsScreen(tester);

      // Collapsed: the body is hidden.
      expect(find.text('Just a moment...'), findsNothing);
      await tester.tap(find.text('HTTP 403 · player_api.php'));
      await tester.pumpAndSettle();
      expect(find.textContaining('cf-ray: abc123'), findsOneWidget);
      expect(find.text('Just a moment...'), findsOneWidget);
      expect(find.textContaining('VLC'), findsOneWidget);
    });

    testWidgets('Clear empties the log and shows the empty state', (tester) async {
      await tester.runAsync(() => IptvRefusalLog.instance.record(_entry(action: 'player_api.php')));
      await _pumpRefusalsScreen(tester);
      expect(find.text('HTTP 403 · player_api.php'), findsOneWidget);

      await tester.tap(find.byTooltip(t.iptv.refusalsClear));
      // The Clear button's handler is async (persist + notifier run in
      // real async); let it drain before asserting the empty state.
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(find.text(t.iptv.refusalsEmpty), findsOneWidget);
      expect(find.text('HTTP 403 · player_api.php'), findsNothing);
    });

    testWidgets('Copy does not crash', (tester) async {
      await tester.runAsync(() => IptvRefusalLog.instance.record(_entry(action: 'player_api.php')));
      await _pumpRefusalsScreen(tester);
      await tester.tap(find.byTooltip(t.iptv.refusalsCopy));
      await tester.pumpAndSettle();
      expect(find.text('HTTP 403 · player_api.php'), findsOneWidget);
    });
  });

  group('Settings → IPTV refusals row', () {
    testWidgets('row exists with the empty subtitle and opens the log', (tester) async {
      await _pumpSettingsScreen(tester);

      expect(find.text(t.iptv.refusalsTitle), findsOneWidget);
      expect(find.text(t.iptv.refusalsEmpty), findsOneWidget);

      await tester.tap(find.text(t.iptv.refusalsTitle));
      await tester.pumpAndSettle();
      expect(find.text(t.iptv.refusalsDescription), findsOneWidget);
    });

    testWidgets('row subtitle shows the count after a refusal', (tester) async {
      await tester.runAsync(() => IptvRefusalLog.instance.record(_entry(action: 'player_api.php')));
      await _pumpSettingsScreen(tester);

      expect(find.text(t.iptv.refusalsTitle), findsOneWidget);
      expect(find.text(t.iptv.refusalsCount(n: 1)), findsOneWidget);
    });
  });
}
