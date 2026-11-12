// DIALOG WART — PlezTV v1.0.16 (tester NO SHIP on ef634b923).
//
// After the first partial land, a second manual refresh fetching the
// same partial list refuses it as warm-partial — and the dialog mapped
// ANY skipped reason != 'up-to-date' to failed, so the footer read
// "Catalog sync failed" while the series row read "partial", even
// though search works for the landed rows. For Matt this is the steady
// state (his panel persistently returns a partial list).
//
// The fix: the warm-partial refuse carries the distinct reason
// 'partial-kept' (the old rows are kept, the type stays searchable),
// and the dialog treats it as non-failed like 'up-to-date'.
//
// Failing-first: D1 + D2 FAIL on ef634b923 for the product reason (the
// second sync reports 'partial'; the footer reads "Catalog sync
// failed"). Both use only pre-existing public API, so they compile on
// base. The `hasFailure` predicate itself is pinned in
// iptv_build_series_fix_test.dart (F6 — new API).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/connection/connection_registry.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/settings/iptv_settings_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/multi_server_fixtures.dart';
import '../../test_helpers/prefs.dart';

const testPassword = 'pa' 'ss';
const _connId = 'conn-xt-1';

List<XtreamCategory> _cats(String prefix, int count) =>
    [for (var i = 1; i <= count; i++) XtreamCategory(id: '$prefix$i', name: 'Category $i')];

/// The Nov 9 degraded shape: 635 Netflix-only series rows in a single
/// category of 237; live + movies complete.
List<XtreamSeries> _partialSeriesRows() => [
      const XtreamSeries(seriesId: 7001, name: 'NF - Alice', categoryId: 'cat1'),
      for (var i = 0; i < 634; i++) XtreamSeries(seriesId: 80000 + i, name: 'Netflix Filler $i', categoryId: 'cat1'),
    ];

class _DegradedPanel extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final action = request.url.queryParameters['action'];
    final body = _bodyFor(action);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }

  String _bodyFor(String? action) {
    switch (action) {
      case null:
        return jsonEncode({
          'user_info': {'status': 'Active', 'exp_date': '1790000000'},
        });
      case 'get_live_categories':
        return jsonEncode(const [
          XtreamCategory(id: 'live1', name: 'Live 1'),
          XtreamCategory(id: 'live2', name: 'Live 2'),
          XtreamCategory(id: 'live3', name: 'Live 3'),
        ].map((c) => c.toJson()).toList());
      case 'get_vod_categories':
        return jsonEncode(const [
          XtreamCategory(id: 'mov1', name: 'Movies 1'),
          XtreamCategory(id: 'mov2', name: 'Movies 2'),
          XtreamCategory(id: 'mov3', name: 'Movies 3'),
        ].map((c) => c.toJson()).toList());
      case 'get_series_categories':
        return jsonEncode(_cats('cat', 237).map((c) => c.toJson()).toList());
      case 'get_live_streams':
        return jsonEncode(const [
          XtreamLiveStream(streamId: 1, name: 'Live One', categoryId: 'live1'),
          XtreamLiveStream(streamId: 2, name: 'Live Two', categoryId: 'live2'),
          XtreamLiveStream(streamId: 3, name: 'Live Three', categoryId: 'live3'),
        ].map((r) => r.toJson()).toList());
      case 'get_vod_streams':
        return jsonEncode(const [
          XtreamVodStream(streamId: 11, name: 'Movie One', categoryId: 'mov1'),
          XtreamVodStream(streamId: 12, name: 'Movie Two', categoryId: 'mov2'),
          XtreamVodStream(streamId: 13, name: 'Movie Three', categoryId: 'mov3'),
        ].map((r) => r.toJson()).toList());
      case 'get_series':
        return jsonEncode(_partialSeriesRows().map((r) => r.toJson()).toList());
      case 'get_series_info':
        return jsonEncode({
          'info': {'name': 'Show'},
          'episodes': <String, dynamic>{},
        });
      default:
        return '[]';
    }
  }
}

XtreamConnection _trexConnection() => XtreamConnection(
      id: _connId,
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      createdAt: DateTime.utc(2026, 11, 5),
    );

IptvClient _clientWith(_DegradedPanel panel) {
  final client = IptvClient.forConnection(_trexConnection());
  client.testXtreamApi = XtreamApi(
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: testPassword,
    httpClient: panel,
  );
  addTearDown(client.close);
  return client;
}

/// Registry with a fixed connection list (same shape as the R4 tile
/// test): the screen only needs the connection list, so the stream is
/// a fixed value while `list()` / `upsert()` hit the real in-memory DB.
class _FakeConnectionRegistry extends ConnectionRegistry {
  _FakeConnectionRegistry(super.db);

  @override
  Stream<List<Connection>> watchConnections() => Stream.value([_trexConnection()]);
}

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  late Directory tempDir;
  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    await StorageService.getInstance();
    tempDir = await Directory.systemTemp.createTemp('plezy_dialog_partial_kept_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
    // NOTE: do NOT set `debugDisableDisk` here — that flag makes
    // `_searchIndex()` return null, so no sync can land anything and
    // every type reports `failed`. The index lives on real SQLite in
    // the temp dir (same as the series-fix probe).
  });
  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!await tempDir.exists()) break;
      try {
        await tempDir.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 2) rethrow;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  });

  group('dialog partial-kept v1.0.16', () {
    test('D1: second forced sync refuses warm-partial as partial-kept', () async {
      final client = _clientWith(_DegradedPanel());

      final first = await client.syncSearchIndex(force: true);
      expect(first.partialTypes, contains(IptvSearchIndex.typeSeries));
      expect(first.skipped, isEmpty);
      expect((await client.searchItems('alice')).map((m) => m.title), contains('NF - Alice'));

      final second = await client.syncSearchIndex(force: true);
      // ignore: avoid_print
      print('D1: second skipped=${second.skipped} partial=${second.partialTypes}');
      expect(second.skipped[IptvSearchIndex.typeSeries], 'partial-kept',
          reason: 'a warm-partial refuse keeps the landed rows — it is not a failure');
      expect(second.partialTypes, isEmpty);
      // Search still works for the landed rows.
      expect((await client.searchItems('alice')).map((m) => m.title), contains('NF - Alice'));
    });

    testWidgets('D2: the refresh dialog says Done, not Failed, on the second refresh', (tester) async {
      final client = _clientWith(_DegradedPanel());
      // First sync lands the partial list; the dialog will run the
      // second one (the warm-partial refuse). A sync writes the index
      // in a background isolate (`compute`), whose result never arrives
      // inside testWidgets' fake async zone — run it in real async.
      await tester.runAsync(() => client.syncSearchIndex(force: true));
      // `searchItems` races its three sections against a timeout, so it
      // needs real async too — a bare await hangs in fake async.
      final found = await tester.runAsync(() => client.searchItems('alice'));
      expect((found ?? <MediaItem>[]).map((m) => m.title), contains('NF - Alice'));

      CredentialVault.resetKeyForTesting();
      await tester.runAsync(() => CredentialVault.protect('opaque-vault-warmup'));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final registry = _FakeConnectionRegistry(db);
      await registry.upsert(_trexConnection());
      final manager = MultiServerManager()..debugRegisterClientForTesting(client);
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
              home: const IptvSettingsScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // `scrollUntilVisible` can leave the tile's centre just below the
      // fold (its centre sat 100 px past the viewport edge), and the tap
      // then misses the tile entirely — the dialog never opens and the
      // poll below waits for a footer that never comes. `ensureVisible`
      // scrolls the tile fully into view before tapping.
      await tester.ensureVisible(find.text(t.iptv.catalogSyncNow));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.iptv.catalogSyncNow));
      await tester.pump();

      // The dialog runs the sync; poll (real async) until the footer
      // lands, then assert it reads Done. Bounded by ITERATION count,
      // not by `DateTime.now()`: the fake-async clock never advances
      // inside testWidgets, so a wall-clock deadline would never arrive
      // and the loop would spin forever if the dialog never landed.
      var landed = false;
      for (var i = 0; i < 100 && !landed; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await tester.pump();
        landed = find.text(t.iptv.catalogSyncDone).evaluate().isNotEmpty ||
            find.text(t.iptv.catalogSyncFailed).evaluate().isNotEmpty;
      }
      expect(landed, isTrue, reason: 'the dialog never reached a footer');
      expect(find.text(t.iptv.catalogSyncTitle), findsOneWidget);
      expect(find.text(t.iptv.catalogSyncDone), findsOneWidget,
          reason: 'a kept partial list is not a failed sync');
      expect(find.text(t.iptv.catalogSyncFailed), findsNothing);
    });
  });
}
