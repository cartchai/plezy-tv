import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/services/plex_api_cache.dart';
import 'package:plezy/services/plex_client.dart';

import '../test_helpers/backend_client_fixtures.dart';
import '../test_helpers/prefs.dart';

XtreamConnection _trexConnection({List<String> hiddenCategoryInitials = const []}) => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: 'pa' 'ss',
  hiddenCategoryInitials: hiddenCategoryInitials,
  createdAt: DateTime.utc(2026, 11, 6),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MultiServerManager manager;
  late PlexClient plex;
  late AppDatabase db;

  setUp(() {
    resetSharedPreferencesForTest();
    // The catalog disk cache reads real dart:io, which never completes in
    // the test zone — switch it off; its behaviour is covered by its own
    // unit tests.
    IptvCatalogDiskCache.debugDisableDisk = true;
    addTearDown(() => IptvCatalogDiskCache.debugDisableDisk = false);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    PlexApiCache.initialize(db);
    addTearDown(db.close);
    manager = MultiServerManager();
    plex = testPlexClient(serverId: ServerId('home-pc'), serverName: 'HOME PC');
    manager.debugRegisterClientForTesting(plex, online: true);
  });

  tearDown(() {
    manager.dispose();
  });

  test('a filter-only IPTV toggle reuses the IPTV client and never recreates Plex (build #15, P-1; build #17 reuse)', () async {
    // First bind: Trex joins the already-registered Plex client.
    await manager.addIptvConnection(_trexConnection());
    expect(manager.getClient(ServerId('home-pc')), same(plex));
    final firstTrex = manager.getClient(ServerId('trex'));
    expect(firstTrex, isNotNull);

    // The toggle: same connection, 161 initials now disabled. This is the
    // exact operation the settings screen used to run as a full profile
    // rebind — which recreated Plex and could leave its libraries not
    // loading (Matt, 2026-11-08: "something is not loading anymore").
    // Build #17 §2: a filter-only change reuses the client in place
    // (updateConnection + notifyCatalogRefreshed, no re-warm, no probe),
    // so the Trex client must be the SAME instance afterwards.
    await manager.addIptvConnection(_trexConnection(hiddenCategoryInitials: ['EN', 'AR', 'FR']));
    expect(manager.getClient(ServerId('home-pc')), same(plex), reason: 'Plex must never be recreated by an IPTV toggle');
    final secondTrex = manager.getClient(ServerId('trex'));
    expect(secondTrex, isNotNull);
    expect(secondTrex, same(firstTrex), reason: 'a filter-only toggle reuses the IPTV client (build #17)');
  });

  test('a toggle storm never recreates the Plex client', () async {
    await manager.addIptvConnection(_trexConnection());
    for (var i = 0; i < 5; i++) {
      await manager.addIptvConnection(_trexConnection(hiddenCategoryInitials: ['EN', 'AR', 'FR', 'DE', 'PL'].take(i + 1).toList()));
      expect(manager.getClient(ServerId('home-pc')), same(plex));
    }
    expect(manager.getClient(ServerId('trex')), isNotNull);
  });
}
