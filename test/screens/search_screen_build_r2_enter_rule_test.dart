// R2.0 (SEARCH RULE) — widget level: typing on the phone search screen
// never talks to the panel; only Enter (submit) may go online.
//
// Fixture: a real [IptvClient] over a counting fake panel, with a COLD
// index and COLD disk (nothing synced yet) — so the whole Enter journey
// is observable: typing shows the cold hint, Enter shows "Catalog
// syncing…", the sync runs, and the results land after it.
//
// Failing-first at the R2.0 stage: the typing test passes, but the
// Enter test fails — the old cold path sweeps per-category (5 extra
// requests) and returns panel rows before the sync flags itself syncing,
// so the indicator never shows and the re-run never happens. R2.3 makes
// it pass.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/focusable_text_field.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/providers/hidden_libraries_provider.dart';
import 'package:plezy/providers/libraries_provider.dart';
import 'package:plezy/providers/multi_server_provider.dart';
import 'package:plezy/screens/search_screen.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/services/storage_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:provider/provider.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';
import '../test_helpers/r2_fake_xtream_api.dart';

void main() {
  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
    await StorageService.getInstance();
    TvDetectionService.debugSetAppleTVOverride(false);
  });

  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_build_r2_enter_widget_');
    IptvCatalogDiskCache.debugDirectoryProvider = () async => tempDir;
    IptvSearchIndex.debugDirectoryProvider = () async => tempDir;
  });

  tearDown(() async {
    IptvCatalogDiskCache.debugDirectoryProvider = null;
    IptvSearchIndex.debugDirectoryProvider = null;
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  // Yield to the real event loop (sqlite + isolate work) until [until]
  // holds or the budget (60 x 100 ms) expires. The search's disk-read
  // legs are real dart:io — they only complete on the real loop, so a
  // pump-only wait never lets them finish (same pattern as the
  // sync-dialog test).
  // Budget is 60, not 40: the hidden-category fingerprint prefs await(s)
  // in the sync path cost one extra real-async turn, so the rows land one
  // poll later (poll 39 vs 38) and the old 40-iteration budget sat within
  // 1 poll of the landing time. The extra 20 iterations are margin.
  Future<void> waitFor(WidgetTester tester, bool Function() until) async {
    for (var i = 0; i < 60 && !until(); i++) {
      await tester.runAsync(
        () async => await Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  // Pump the search screen over a real client with a cold index + cold
  // disk, and run one warmup search on the real loop so the client's
  // index is open before the screen's searches use the cached instance
  // (first open does real dart:io, which never completes in fake async).
  Future<R2FakeXtreamApi> pumpColdSearchScreen(WidgetTester tester) async {
    final api = R2FakeXtreamApi();
    final client = r2ClientWith(api);
    await tester.runAsync(() async {
      await client.searchItems('warmup-needle');
    });
    api.resetCounts();

    final manager = MultiServerManager();
    manager.debugRegisterClientForTesting(client);
    final provider = testMultiServerProvider(manager);
    final hidden = HiddenLibrariesProvider();
    final librariesProvider = LibrariesProvider();
    addTearDown(() {
      provider.dispose();
      hidden.dispose();
      librariesProvider.dispose();
      manager.dispose();
    });

    await tester.pumpWidget(
      TranslationProvider(
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<MultiServerProvider>.value(value: provider),
            ChangeNotifierProvider<HiddenLibrariesProvider>.value(value: hidden),
            ChangeNotifierProvider<LibrariesProvider>.value(value: librariesProvider),
          ],
          child: MaterialApp(theme: monoTheme(MonoPalette.dark), home: const SearchScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      // Dispose the search state (including its debounce, focus nodes,
      // and any hosted OSK route) before the next test.
      await tester.pumpWidget(const SizedBox.shrink());
      FocusManager.instance.primaryFocus?.unfocus();
    });
    return api;
  }

  Future<void> typeQuery(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(FocusableTextField), query);
    await tester.pump(const Duration(milliseconds: 600));
    // The debounce fires at 500 ms; the search itself lands a few real
    // yields later — wait for the no-results state before asserting.
    await waitFor(tester, () => find.text(t.messages.noResultsFound).evaluate().isNotEmpty);
    await tester.pump();
  }

  testWidgets('typing is local-only and names the cold catalog', (tester) async {
    final api = await pumpColdSearchScreen(tester);

    await typeQuery(tester, 'game of thrones');

    expect(api.totalRequests, 0, reason: 'typing must never talk to the panel');
    // Nothing is synced yet, so every type is cold — the empty state
    // names all of them and the Enter action.
    expect(
      find.text(t.iptv.catalogColdHint(types: 'Live TV, Movies, TV / Series')),
      findsOneWidget,
    );
  });

  testWidgets('Enter starts one sync, shows syncing, then finds the show', (tester) async {
    final api = await pumpColdSearchScreen(tester);

    await typeQuery(tester, 'game of thrones');
    expect(api.totalRequests, 0);

    // The typing search's rebuilds drop the field's focus — re-focus it
    // so the Enter action has an attached input connection to reach.
    await tester.showKeyboard(find.byType(FocusableTextField));
    await tester.testTextInput.receiveAction(TextInputAction.search);

    await waitFor(tester, () => find.text(t.iptv.catalogSyncing).evaluate().isNotEmpty);
    expect(find.text(t.iptv.catalogSyncing), findsOneWidget);

    // The sync lands, the screen re-runs the submitted search, and the
    // show appears — with no per-category sweep at any point.
    await waitFor(tester, () => find.text(r2GotName).evaluate().isNotEmpty);
    expect(find.text(r2GotName), findsOneWidget);
    expect(api.perCategoryRequests, 0, reason: 'no per-category sweep on submit');
    expect(api.totalRequests, 6, reason: 'one coalesced sync: 3 category lists + 3 catalogs');
  });
}
