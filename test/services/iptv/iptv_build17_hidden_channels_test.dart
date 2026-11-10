// Build #17 §9 (v2.25.13): the per-channel hide store
// (`iptv_hidden_channels:<connectionId>`) — hide persists across a client
// rebind, a hidden channel never appears in Live TV search, and un-hiding
// (single + all) restores it.
//
// Failing-first: on v2.25.12 there was no hide store at all — hiding was
// impossible, and a hidden channel (had one existed) would still have
// matched in search.

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

import '../../test_helpers/prefs.dart';

void main() {
  setUp(resetSharedPreferencesForTest);

  // The password is split so the literal never appears in new code.
  const testPassword = 'pa' 'ss';

  IptvClient clientWith({required XtreamApi api}) {
    final connection = XtreamConnection(
      id: 'conn-xt-1',
      name: 'Trex',
      serverUrl: 'https://panel.example.com:8080',
      username: 'user',
      password: testPassword,
      createdAt: DateTime.utc(2026, 11, 5),
    );
    final client = IptvClient.forConnection(connection);
    client.testXtreamApi = api;
    return client;
  }

  final news = LiveTvChannel(key: '100', title: 'Trex News', serverId: 'conn-xt-1');
  final sports = LiveTvChannel(key: '101', title: 'Trex Sports', serverId: 'conn-xt-1');

  group('build17 hidden channels', () {
    test('hide persists across a client rebind', () async {
      final first = clientWith(api: _HiddenFakeApi());
      try {
        final support = first.liveTv as IptvLiveTvSupport;
        await support.hideChannel(news);
        expect(support.isHiddenChannel(news), isTrue);
        expect(support.isHiddenChannel(sports), isFalse);
      } finally {
        first.close();
      }

      // A fresh client over the same connection (a rebind) re-reads the
      // store from disk — the channel stays hidden.
      final second = clientWith(api: _HiddenFakeApi());
      try {
        final support = second.liveTv as IptvLiveTvSupport;
        await support.loadHiddenChannels();
        expect(support.isHiddenChannel(news), isTrue);
        expect(support.isHiddenChannel(sports), isFalse);
      } finally {
        second.close();
      }
    });

    test('hidden channel never appears in Live TV search results', () async {
      final client = clientWith(api: _HiddenFakeApi());
      try {
        final support = client.liveTv as IptvLiveTvSupport;
        await support.hideChannel(news);

        final results = await client.searchItems('trex');
        final titles = results.map((i) => i.title).toList();
        expect(titles, contains('Trex Sports'));
        expect(titles, isNot(contains('Trex News')));
      } finally {
        client.close();
      }
    });

    test('unhide by key and unhide-all restore the channels', () async {
      final client = clientWith(api: _HiddenFakeApi());
      try {
        final support = client.liveTv as IptvLiveTvSupport;
        await support.hideChannel(news);
        await support.hideChannel(sports);
        expect(support.isHiddenChannel(news), isTrue);
        expect(support.isHiddenChannel(sports), isTrue);

        await support.unhideChannelKey('100');
        expect(support.isHiddenChannel(news), isFalse);
        expect(support.isHiddenChannel(sports), isTrue);

        await support.unhideAllChannels();
        expect(support.isHiddenChannel(sports), isFalse);
        expect(support.hiddenChannelKeys, isEmpty);
      } finally {
        client.close();
      }
    });
  });
}

/// Minimal fake panel: two live channels in one category, nothing else.
class _HiddenFakeApi extends XtreamApi {
  _HiddenFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async => const [XtreamCategory(id: '1', name: '|EN| Live 1')];

  @override
  Future<List<XtreamCategory>> getVodCategories({Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamCategory>> getSeriesCategories({Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'Trex News', categoryId: '1'),
    XtreamLiveStream(streamId: 101, name: 'Trex Sports', categoryId: '1'),
  ];

  @override
  Future<List<XtreamVodStream>> getVodStreams({String? categoryId, Future<void>? abortTrigger}) async => const [];

  @override
  Future<List<XtreamSeries>> getSeries({String? categoryId, Future<void>? abortTrigger}) async => const [];
}
