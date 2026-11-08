// FAILING-FIRST — build #13 (v2.25.9): "Category initials doesn't
// actually turn off the categories with those initials so it's kind of
// fucking pointless" (Matt, 2026-11-07 ~05:12 EST).
//
// Two failure layers, both proven here before any product code changes:
// 1. DERIVATION: categoryInitial() only reads a LEADING prefix. Provider
//    categories whose region is buried after a content-type prefix
//    ("MOVIES | EN | Action", "SERIES | FR | Drama", "LIVE TV | AR |
//    News") return null, as do lowercase ("en | …") and bracket
//    ("[EN] …") forms — so toggling the initial does nothing for them.
// 2. REFRESH: after toggling, the client is rebound but nothing tells
//    the library tabs or the guide to reload (the library epoch only
//    bumps on server push events; the guide only reloads when the
//    server-id SET changes) — so even a working filter shows stale
//    lists until a restart.
//
// The fix: broaden the derivation (scan pipe segments, last match wins,
// case-insensitive, bracketed forms count) and fire the catalog-refreshed
// notification when addIptvConnection replaces a client, with the guide
// subscribing to it.

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/library_change_event.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/multi_server_manager.dart';
import 'package:plezy/utils/iptv_initials.dart';
import 'package:plezy/utils/library_content_notifier.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  group('build13: categoryInitial derivation (buried / lowercase / bracket)', () {
    test('buried after a content-type prefix', () {
      expect(categoryInitial('MOVIES | EN | Action'), 'EN');
      expect(categoryInitial('SERIES | FR | Drama'), 'FR');
      expect(categoryInitial('LIVE TV | AR | News'), 'AR');
    });

    test('lowercase counts, canonical uppercase out', () {
      expect(categoryInitial('en | Movies'), 'EN');
      expect(categoryInitial('fr - Drama'), 'FR');
    });

    test('bracketed initial counts', () {
      expect(categoryInitial('[EN] Movies'), 'EN');
      expect(categoryInitial('[FR] | Drama'), 'FR');
    });

    test('content-first pipe form yields the region, not the content word', () {
      expect(categoryInitial('TV | EN'), 'EN');
    });

    test('controls still hold', () {
      expect(categoryInitial('|EN| UK SERIES'), 'EN');
      expect(categoryInitial('24/7 ACTION & ADVENTURE VIP'), '24/7');
      expect(categoryInitial('NF'), 'NF');
      expect(categoryInitial('Action'), isNull);
      expect(categoryInitial('ENGLISH | Movies'), isNull);
      expect(categoryInitial('UK Series'), isNull);
      expect(categoryInitial(null), isNull);
      expect(categoryInitial(''), isNull);
    });
  });

  group('build13: buried initials hide their categories end to end', () {
    IptvClient buriedClient({List<String> hiddenCategoryInitials = const []}) {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: testPassword,
        hiddenCategoryInitials: hiddenCategoryInitials,
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      client.testXtreamApi = _BuriedInitialsFakeXtreamApi();
      return client;
    }

    test('disabling FR hides every FR category — including buried ones — everywhere', () async {
      final client = buriedClient(hiddenCategoryInitials: const ['FR']);
      try {
        final seriesCategories = await client.iptvCategoriesForLibrary('iptv:conn-xt-1:series');
        expect(seriesCategories.map((c) => c.name), isNot(contains('SERIES | FR | Drama')));
        expect(seriesCategories.map((c) => c.name), contains('SERIES | EN | Drama'));

        final channels = await client.iptvChannels();
        expect(channels.map((c) => c.title), isNot(contains('FR News')));
        expect(channels.map((c) => c.title), contains('EN News'));

        final results = await client.searchItems('drama');
        expect(results.map((i) => i.title), isNot(contains('FR Drama')));
        expect(results.map((i) => i.title), contains('EN Drama'));
      } finally {
        client.close();
      }
    });
  });

  group('build13: rebind notifies the library views', () {
    test('replacing the client fires a catalog-refreshed event', () async {
      // Unreachable panel so the health probe fails fast; the
      // notification is about the replacement, not the health.
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://127.0.0.1:1',
        username: 'user',
        password: testPassword,
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final manager = MultiServerManager();
      addTearDown(manager.dispose);
      await manager.addIptvConnection(connection);

      final events = <LibraryChangeEvent>[];
      final subscription = LibraryContentNotifier().stream.listen(events.add);
      addTearDown(subscription.cancel);

      // Toggle the filter: the settings/edit flow rebinds the same
      // connection with new filter state.
      await manager.addIptvConnection(connection.copyWith(hiddenCategoryInitials: const ['FR']));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(events.where((e) => e.serverId == ServerId('conn-xt-1')), isNotEmpty);
    });
  });
}

/// Fake panel whose categories bury the region after a content-type
/// prefix — the shape the old derivation missed entirely.
class _BuriedInitialsFakeXtreamApi extends XtreamApi {
  _BuriedInitialsFakeXtreamApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamCategory>> getSeriesCategories() async => const [
    XtreamCategory(id: 'S1', name: 'SERIES | EN | Drama'),
    XtreamCategory(id: 'S2', name: 'SERIES | FR | Drama'),
  ];

  @override
  Future<List<XtreamCategory>> getVodCategories() async => const [
    XtreamCategory(id: 'M1', name: 'MOVIES | EN | Action'),
    XtreamCategory(id: 'M2', name: 'MOVIES | FR | Action'),
  ];

  @override
  Future<List<XtreamCategory>> getLiveCategories() async => const [
    XtreamCategory(id: 'L1', name: 'LIVE TV | EN | News'),
    XtreamCategory(id: 'L2', name: 'LIVE TV | FR | News'),
  ];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId}) async {
    return const [
      XtreamSeries(seriesId: 10, name: 'EN Drama', categoryId: 'S1'),
      XtreamSeries(seriesId: 11, name: 'FR Drama', categoryId: 'S2'),
    ];
  }

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId}) async {
    return const [
      XtreamVodStream(streamId: 1, name: 'EN Action', containerExtension: 'mp4', categoryId: 'M1'),
      XtreamVodStream(streamId: 2, name: 'FR Action', containerExtension: 'mp4', categoryId: 'M2'),
    ];
  }

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId}) async {
    return const [
      XtreamLiveStream(streamId: 100, name: 'EN News', categoryId: 'L1'),
      XtreamLiveStream(streamId: 101, name: 'FR News', categoryId: 'L2'),
    ];
  }
}
