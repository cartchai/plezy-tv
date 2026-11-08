// Build #17 §11 (v2.25.13): the guide category switcher filters the
// already-loaded rows in memory — source first, then the selected live
// TV category. A category is a (serverId, categoryId) pair: a category
// id means nothing on another source, and a channel without a category
// (Plex/Jellyfin/Emby) never matches a selected category. No network
// call happens on switch — this pure function is the whole filter, so
// these tests are the proof.

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/livetv_channel.dart';
import 'package:plezy/screens/livetv/guide_category.dart';

void main() {
  LiveTvChannel channel(String key, {String? serverId, String? categoryId}) =>
      LiveTvChannel(key: key, title: key, serverId: serverId, categoryId: categoryId);

  final channels = [
    channel('trex-us-1', serverId: 'trex', categoryId: 'L1'),
    channel('trex-us-2', serverId: 'trex', categoryId: 'L1'),
    channel('trex-fr-1', serverId: 'trex', categoryId: 'L2'),
    channel('trex-us-other', serverId: 'trex2', categoryId: 'L1'),
    channel('plex-1', serverId: 'plex'),
  ];

  group('filterGuideChannels', () {
    test('no source, no category — everything passes through', () {
      expect(filterGuideChannels(channels: channels), hasLength(5));
    });

    test('source only — only that server’s channels', () {
      final out = filterGuideChannels(channels: channels, sourceId: 'trex');
      expect(out.map((c) => c.key), ['trex-us-1', 'trex-us-2', 'trex-fr-1']);
    });

    test('category only — only that server’s channels in that category', () {
      final out = filterGuideChannels(
        channels: channels,
        category: (serverId: 'trex', categoryId: 'L1', label: 'US'),
      );
      expect(out.map((c) => c.key), ['trex-us-1', 'trex-us-2']);
    });

    test('the same category id on another source never matches', () {
      final out = filterGuideChannels(
        channels: channels,
        category: (serverId: 'trex2', categoryId: 'L1', label: 'US'),
      );
      expect(out.map((c) => c.key), ['trex-us-other']);
    });

    test('a Plex channel (no category) never matches a selected category', () {
      final out = filterGuideChannels(
        channels: channels,
        category: (serverId: 'plex', categoryId: 'L1', label: 'US'),
      );
      expect(out, isEmpty);
    });

    test('source + category compose — favorites-style narrowing', () {
      final out = filterGuideChannels(
        channels: channels,
        sourceId: 'trex',
        category: (serverId: 'trex', categoryId: 'L2', label: 'FR'),
      );
      expect(out.map((c) => c.key), ['trex-fr-1']);
    });

    test('source + a category from another source is empty, not wrong', () {
      final out = filterGuideChannels(
        channels: channels,
        sourceId: 'trex',
        category: (serverId: 'trex2', categoryId: 'L1', label: 'US'),
      );
      expect(out, isEmpty);
    });
  });
}
