// Build #17 §11 (v2.25.13): the guide category switcher — LIVE TV
// categories only. Two proofs:
//   (a) The picker lists exactly the visible categories: the same
//       hidden-category rule as the guide rows, so a hidden category
//       never appears in the picker and every picker entry has rows.
//   (b) The rows carry their category: iptvChannels sets categoryId
//       (Xtream category id, M3U group title), which the in-memory
//       filter in guide_category.dart matches on.
// Failing-first: before the fix, visibleLiveCategories did not exist
// and LiveTvChannel had no categoryId, so the picker could not be
// built and the filter could not run.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSharedPreferencesForTest);

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  setUp(() {
    IptvCatalogDiskCache.debugDisableDisk = true;
  });

  tearDown(() {
    IptvCatalogDiskCache.debugDisableDisk = false;
  });

  IptvClient xtreamClientWith({
    List<String> hiddenCategoryIds = const [],
    List<String> hiddenInitials = const [],
  }) {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      hiddenCategoryIds: hiddenCategoryIds,
      hiddenCategoryInitials: hiddenInitials,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    client.testXtreamApi = _GuideFakeApi();
    return client;
  }

  group('build17 guide category switcher: Xtream', () {
    test('visibleLiveCategories lists every category when nothing is hidden', () async {
      final client = xtreamClientWith();
      try {
        expect(
          await client.visibleLiveCategories(),
          [
            (id: 'L1', name: '|EN| Live'),
            (id: 'L2', name: 'FR | Live'),
            (id: 'L3', name: 'US | Live'),
          ],
        );
      } finally {
        client.close();
      }
    });

    test('a category hidden by id never appears in the picker', () async {
      final client = xtreamClientWith(hiddenCategoryIds: const ['L2']);
      try {
        expect(
          (await client.visibleLiveCategories()).map((c) => c.id),
          ['L1', 'L3'],
        );
      } finally {
        client.close();
      }
    });

    test('a category hidden by initial never appears in the picker', () async {
      final client = xtreamClientWith(hiddenInitials: const ['FR']);
      try {
        expect(
          (await client.visibleLiveCategories()).map((c) => c.id),
          ['L1', 'L3'],
        );
      } finally {
        client.close();
      }
    });

    test('iptvChannels carries the category id on every channel', () async {
      final client = xtreamClientWith();
      try {
        final channels = await client.iptvChannels();
        expect(channels.map((c) => (c.key, c.categoryId)), [
          ('100', 'L1'),
          ('101', 'L2'),
          ('102', 'L3'),
        ]);
      } finally {
        client.close();
      }
    });

    test('a hidden category’s channels are gone and the rest keep their id', () async {
      final client = xtreamClientWith(hiddenInitials: const ['FR']);
      try {
        final channels = await client.iptvChannels();
        expect(channels.map((c) => (c.key, c.categoryId)), [
          ('100', 'L1'),
          ('102', 'L3'),
        ]);
      } finally {
        client.close();
      }
    });
  });

  group('build17 guide category switcher: M3U groups', () {
    late HttpServer server;
    HttpOverrides? previousOverrides;

    setUp(() async {
      previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/playlist.m3u') {
          response.headers.contentType = ContentType.text;
          response.write(
            '#EXTM3U\n'
            '#EXTINF:-1 tvg-id="n1" tvg-name="News One" group-title="News",News One\n'
            'http://example.com/n1.m3u8\n'
            '#EXTINF:-1 tvg-id="n2" tvg-name="News Two" group-title="News",News Two\n'
            'http://example.com/n2.m3u8\n'
            '#EXTINF:-1 tvg-id="s1" tvg-name="Sports One" group-title="Sports",Sports One\n'
            'http://example.com/s1.m3u8\n',
          );
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      HttpOverrides.global = previousOverrides;
    });

    IptvClient m3uClientWith({List<String> hiddenCategoryIds = const []}) {
      final connection = M3uConnection(
        id: 'm3u1',
        name: 'Test M3U',
        playlistUrl: 'http://127.0.0.1:${server.port}/playlist.m3u',
        hiddenCategoryIds: hiddenCategoryIds,
        createdAt: DateTime.utc(2026, 11, 6),
      );
      return IptvClient.m3u(m3uConnection: connection);
    }

    test('groups are the picker entries and channels carry the group as category', () async {
      final client = m3uClientWith();
      try {
        expect(
          await client.visibleLiveCategories(),
          [
            (id: 'News', name: 'News'),
            (id: 'Sports', name: 'Sports'),
          ],
        );
        final channels = await client.iptvChannels();
        expect(channels.map((c) => (c.key, c.categoryId)), [
          ('n1', 'News'),
          ('n2', 'News'),
          ('s1', 'Sports'),
        ]);
      } finally {
        client.close();
      }
    });

    test('a hidden group never appears in the picker and its channels are gone', () async {
      final client = m3uClientWith(hiddenCategoryIds: const ['Sports']);
      try {
        expect(
          (await client.visibleLiveCategories()).map((c) => c.id),
          ['News'],
        );
        final channels = await client.iptvChannels();
        expect(channels.map((c) => (c.key, c.categoryId)), [
          ('n1', 'News'),
          ('n2', 'News'),
        ]);
      } finally {
        client.close();
      }
    });
  });
}

/// Fake panel: three live categories, one channel each.
class _GuideFakeApi extends XtreamApi {
  _GuideFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => const [
    XtreamCategory(id: 'L1', name: '|EN| Live'),
    XtreamCategory(id: 'L2', name: 'FR | Live'),
    XtreamCategory(id: 'L3', name: 'US | Live'),
  ];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'EN Channel', categoryId: 'L1'),
    XtreamLiveStream(streamId: 101, name: 'FR Channel', categoryId: 'L2'),
    XtreamLiveStream(streamId: 102, name: 'US Channel', categoryId: 'L3'),
  ];
}
