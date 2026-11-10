// BUILD #21 — composite offline verdict (failing-first).
//
// THE PHONE FAILURE (v1.0.3-2.25.0, 2026-11-09 ~23:12 EST): searching puts
// the app into OFFLINE mode and disconnects Trex. One aggravator is the
// composite verdict: the "refused is not offline" carve-out only applied
// when ALL visible servers were refused — with Plex unreachable on mobile
// data, Trex-refused + Plex-offline sent the whole app into the offline
// shell even though Trex was reachable and the refusal banner was the
// right UI.
//
// THE FIX: "no server online AND at least one refused" shows the refusal
// banner (OfflineModeReason.onlyRefusedServers), not the offline shell.
// Genuine no-network (no server refused anyone) still enters offline.
//
// This test FAILS on 652db5f90 (the mixed case collapses to offline) and
// PASSES on the fix. It uses only the pre-fix public API.

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/providers/offline_mode_provider.dart';
import 'package:plezy/services/multi_server_manager.dart';

import '../test_helpers/multi_server_fixtures.dart';
import '../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  group('Build #21 — composite offline verdict', () {
    test('Trex refused + Plex offline shows the refusal banner, not the offline shell', () async {
      final manager = MultiServerManager();
      final multi = testMultiServerProvider(manager);
      final p = OfflineModeProvider(manager, multiServerProvider: multi);
      await p.initialize();

      multi.setExpectedVisibleServerIds({'trex', 'plex-server'});
      multi.setVisibleServerIds({'trex', 'plex-server'});
      manager.updateServerStatus(ServerId('plex-server'), false);
      manager.debugMarkAccessDeniedForTesting(ServerId('trex'));
      await Future<void>.delayed(Duration.zero);

      expect(multi.refusedServerIds, ['trex']);
      expect(multi.hasConnectedServers, isFalse);
      expect(p.offlineReason, OfflineModeReason.onlyRefusedServers);
      expect(p.isOffline, isFalse);

      p.dispose();
      multi.dispose();
      manager.dispose();
    });

    test('genuine no-network (nothing refused) still enters offline', () async {
      final manager = MultiServerManager();
      final multi = testMultiServerProvider(manager);
      final p = OfflineModeProvider(manager, multiServerProvider: multi);
      await p.initialize();

      multi.setExpectedVisibleServerIds({'trex', 'plex-server'});
      multi.setVisibleServerIds({'trex', 'plex-server'});
      manager.updateServerStatus(ServerId('plex-server'), false);
      manager.updateServerStatus(ServerId('trex'), false);
      await Future<void>.delayed(Duration.zero);

      expect(multi.refusedServerIds, isEmpty);
      expect(p.offlineReason, OfflineModeReason.noServerConnection);
      expect(p.isOffline, isTrue);

      p.dispose();
      multi.dispose();
      manager.dispose();
    });

    test('Trex refused + Plex online stays online', () async {
      final manager = MultiServerManager();
      final multi = testMultiServerProvider(manager);
      final p = OfflineModeProvider(manager, multiServerProvider: multi);
      await p.initialize();

      multi.setExpectedVisibleServerIds({'trex', 'plex-server'});
      multi.setVisibleServerIds({'trex', 'plex-server'});
      manager.updateServerStatus(ServerId('plex-server'), true);
      manager.debugMarkAccessDeniedForTesting(ServerId('trex'));
      await Future<void>.delayed(Duration.zero);

      expect(p.offlineReason, OfflineModeReason.online);
      expect(p.isOffline, isFalse);

      p.dispose();
      multi.dispose();
      manager.dispose();
    });
  });
}
