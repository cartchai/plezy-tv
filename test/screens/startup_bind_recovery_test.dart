import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/main.dart';
import 'package:plezy/navigation/navigation_tabs.dart';
import 'package:plezy/screens/main_screen.dart';
import 'package:plezy/utils/media_server_timeouts.dart';

List<NavigationTabId> _ids(List<NavigationTab> tabs) => tabs.map((tab) => tab.id).toList();

void main() {
  group('startup bind recovery', () {
    test('enters offline mode only when initial bind failed with no online servers', () {
      expect(shouldEnterOfflineModeAfterStartupBind(bindingSucceeded: false, hasOnlineServers: false), isTrue);
      expect(shouldEnterOfflineModeAfterStartupBind(bindingSucceeded: true, hasOnlineServers: false), isFalse);
      expect(shouldEnterOfflineModeAfterStartupBind(bindingSucceeded: false, hasOnlineServers: true), isFalse);
    });

    test('the splash waits for the bind only up to the cap, with or without a network', () {
      fakeAsync((async) {
        bool? capped;
        bool? uncapped;
        bool? settledEarly;
        unawaited(awaitStartupBindSettle(Completer<bool>().future, hasNetwork: false).then((v) => capped = v));
        unawaited(awaitStartupBindSettle(Completer<bool>().future, hasNetwork: true).then((v) => uncapped = v));
        unawaited(awaitStartupBindSettle(Future.value(true), hasNetwork: false).then((v) => settledEarly = v));

        async.flushMicrotasks();
        expect(settledEarly, isTrue, reason: 'a loopback server that binds fast is not held back');

        async.elapse(MediaServerTimeouts.noNetworkStartupBind - const Duration(milliseconds: 1));
        expect(capped, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(capped, isFalse, reason: 'airplane mode reaches the offline shell after the cap');

        // R5: with a network the wait is capped at networkStartupBind (15 s).
        // Before R5 the splash waited for the real outcome with no cap at
        // all, so a hung Trex probe held the splash for its whole 30 s
        // fetch timeout. The old assertion here pinned the uncapped wait
        // ("with a network the splash waits for the real outcome") — it is
        // replaced, not deleted, by the capped assertion below.
        async.elapse(
          MediaServerTimeouts.networkStartupBind -
              MediaServerTimeouts.noNetworkStartupBind -
              const Duration(milliseconds: 1),
        );
        expect(uncapped, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(uncapped, isFalse, reason: 'with a network the splash stops waiting at the 15 s cap');
      });
    });

    test('a cap expiry with the bind still running proceeds to MainScreen', () {
      // R5 section 5.1 trap: a timeout is not a failed bind. The splash
      // wait returns false on a cap expiry, so the caller must check
      // isBinding before routing to the offline shell — otherwise a slow
      // Trex probe flashes splash, offline shell, MainScreen in turn.
      expect(
        shouldProceedToMainScreenAfterStartupBind(
          bindingSucceeded: false,
          hasOnlineServers: false,
          bindStillRunning: true,
          hasNetwork: true,
        ),
        isTrue,
      );
      expect(
        shouldProceedToMainScreenAfterStartupBind(
          bindingSucceeded: false,
          hasOnlineServers: false,
          bindStillRunning: false,
          hasNetwork: true,
        ),
        isFalse,
        reason: 'a genuinely settled failure with no online servers still goes offline',
      );
      expect(
        shouldProceedToMainScreenAfterStartupBind(
          bindingSucceeded: false,
          hasOnlineServers: false,
          bindStillRunning: true,
          hasNetwork: false,
        ),
        isFalse,
        reason: 'without a network the cap still reads as a failed bind',
      );
      expect(
        shouldProceedToMainScreenAfterStartupBind(
          bindingSucceeded: true,
          hasOnlineServers: false,
          bindStillRunning: false,
          hasNetwork: true,
        ),
        isTrue,
      );
      expect(
        shouldProceedToMainScreenAfterStartupBind(
          bindingSucceeded: false,
          hasOnlineServers: true,
          bindStillRunning: false,
          hasNetwork: true,
        ),
        isTrue,
      );
    });

    test('retries active profile bind when reconnect has no visible servers', () {
      expect(
        shouldRetryActiveProfileBindAfterReconnect(
          hasActiveProfile: true,
          hasVisibleConnectedServers: false,
          hasManagerOnlineServers: true,
          hasKnownOfflineServers: false,
        ),
        isTrue,
      );
      expect(
        shouldRetryActiveProfileBindAfterReconnect(
          hasActiveProfile: true,
          hasVisibleConnectedServers: false,
          hasManagerOnlineServers: false,
          hasKnownOfflineServers: false,
        ),
        isTrue,
      );
      expect(
        shouldRetryActiveProfileBindAfterReconnect(
          hasActiveProfile: true,
          hasVisibleConnectedServers: true,
          hasManagerOnlineServers: true,
          hasKnownOfflineServers: false,
        ),
        isFalse,
      );
      expect(
        shouldRetryActiveProfileBindAfterReconnect(
          hasActiveProfile: false,
          hasVisibleConnectedServers: false,
          hasManagerOnlineServers: true,
          hasKnownOfflineServers: false,
        ),
        isFalse,
      );
      expect(
        shouldRetryActiveProfileBindAfterReconnect(
          hasActiveProfile: true,
          hasVisibleConnectedServers: false,
          hasManagerOnlineServers: false,
          hasKnownOfflineServers: true,
        ),
        isFalse,
      );
    });

    test('explicit offline startup stays offline until a visible server connects', () {
      expect(
        shouldRenderMainScreenOffline(
          providerOffline: false,
          startupOfflineUntilConnected: true,
          hasVisibleConnectedServers: false,
        ),
        isTrue,
      );
      expect(
        shouldRenderMainScreenOffline(
          providerOffline: false,
          startupOfflineUntilConnected: true,
          hasVisibleConnectedServers: true,
        ),
        isFalse,
      );
      expect(
        shouldRenderMainScreenOffline(
          providerOffline: true,
          startupOfflineUntilConnected: false,
          hasVisibleConnectedServers: true,
        ),
        isTrue,
      );
    });
  });

  group('main screen bottom navigation tabs', () {
    test('mobile online hides Settings when another tab is active', () {
      final tabs = mainScreenBottomNavigationTabs(
        visibleTabs: allNavigationTabs,
        isMobile: true,
        isOffline: false,
        currentTab: NavigationTabId.discover,
      );

      expect(_ids(tabs), isNot(contains(NavigationTabId.settings)));
    });

    test('mobile offline includes Downloads and Settings', () {
      final offlineTabs = allNavigationTabs
          .where((tab) => tab.id == NavigationTabId.downloads || tab.id == NavigationTabId.settings)
          .toList();
      final tabs = mainScreenBottomNavigationTabs(
        visibleTabs: offlineTabs,
        isMobile: true,
        isOffline: true,
        currentTab: NavigationTabId.downloads,
      );

      expect(_ids(tabs), [NavigationTabId.downloads, NavigationTabId.settings]);
    });

    test('mobile online keeps Settings visible when it is selected', () {
      final tabs = mainScreenBottomNavigationTabs(
        visibleTabs: allNavigationTabs,
        isMobile: true,
        isOffline: false,
        currentTab: NavigationTabId.settings,
      );

      expect(_ids(tabs), contains(NavigationTabId.settings));
    });

    test('non-mobile returns all visible tabs unchanged', () {
      final tabs = mainScreenBottomNavigationTabs(
        visibleTabs: allNavigationTabs,
        isMobile: false,
        isOffline: false,
        currentTab: NavigationTabId.discover,
      );

      expect(tabs, same(allNavigationTabs));
    });
  });
}
