import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/m3u_parser.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

void main() {
  group('M3U parser', () {
    test('parses EXTINF attributes and pairs the following URL', () {
      const playlist = '''
#EXTM3U
#EXTINF:-1 tvg-id="BBC.One" tvg-logo="https://example.com/bbc.png" group-title="UK" catchup-source="https://example.com/catchup",BBC One
https://example.com/bbc.m3u8
#EXTINF:-1 tvg-id="CNN" group-title="US",CNN
https://example.com/cnn.ts
#EXTGRP:UK
''';
      final entries = parseM3u(playlist);
      expect(entries.length, 2);
      expect(entries[0].name, 'BBC One');
      expect(entries[0].tvgId, 'BBC.One');
      expect(entries[0].tvgLogo, 'https://example.com/bbc.png');
      expect(entries[0].groupTitle, 'UK');
      expect(entries[0].catchupSource, 'https://example.com/catchup');
      expect(entries[0].url, 'https://example.com/bbc.m3u8');
      expect(entries[1].name, 'CNN');
      expect(entries[1].tvgId, 'CNN');
      expect(entries[1].groupTitle, 'US');
    });

    test('bare URL without EXTINF falls back to the last path segment as name', () {
      final entries = parseM3u('https://example.com/only.ts\n');
      expect(entries.length, 1);
      expect(entries[0].name, 'only.ts');
      expect(entries[0].tvgId, isNull);
    });

    test('entry without a following URL is dropped', () {
      final entries = parseM3u('#EXTINF:-1 tvg-id="X",No URL\n');
      expect(entries, isEmpty);
    });
  });

  group('Xtream URL builders', () {
    final api = XtreamApi(serverUrl: 'https://panel.example.com:8080/', username: 'user', password: 'pass');

    test('server URL trailing slash is trimmed', () {
      expect(api.serverUrl, 'https://panel.example.com:8080');
    });

    test('live/movie/series URLs', () {
      expect(api.liveStreamUrl('123'), 'https://panel.example.com:8080/live/user/pass/123.m3u8');
      expect(api.movieStreamUrl('456', 'mkv'), 'https://panel.example.com:8080/movie/user/pass/456.mkv');
      expect(api.movieStreamUrl('456', ''), 'https://panel.example.com:8080/movie/user/pass/456.mp4');
      expect(api.seriesStreamUrl('789', 'mp4'), 'https://panel.example.com:8080/series/user/pass/789.mp4');
    });

    test('timeshift URL shape', () {
      final start = DateTime.utc(2026, 11, 5, 20, 30, 0);
      expect(
        api.timeshiftUrl(streamId: '123', durationMinutes: 60, start: start),
        'https://panel.example.com:8080/timeshift/user/pass/60/2026-11-05:20-30-00/123.m3u8',
      );
    });

    test('EPG program Base64 titles decode', () {
      final program = XtreamEpgProgram.fromJson({
        'id': '1',
        'title': 'TmV3cyBUb25pZ2h0',
        'description': 'RXZlbmluZyBuZXdz',
        'start_timestamp': 1762380000,
        'stop_timestamp': 1762383600,
        'channel_id': 'BBC.One',
      });
      expect(program.title, 'News Tonight');
      expect(program.description, 'Evening news');
    });
  });

  group('IptvClient libraries (no network)', () {
    test('M3U exposes only the Live TV library', () async {
      final connection = M3uConnection(
        id: 'conn-m3u-1',
        name: 'Trex M3U',
        playlistUrl: 'https://example.com/playlist.m3u',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      final libraries = await client.fetchLibraries();
      expect(libraries.length, 1);
      expect(libraries.single.id, 'iptv:conn-m3u-1:live');
      expect(libraries.single.title, 'Trex M3U — Live TV');
      expect(client.backend.id, 'm3u');
      expect(client.liveTv.dvr, isNull);
      client.close();
    });

    test('Xtream exposes Live TV + Movies + Series libraries', () async {
      final connection = XtreamConnection(
        id: 'conn-xt-1',
        name: 'Trex',
        serverUrl: 'https://panel.example.com:8080',
        username: 'user',
        password: 'pass',
        createdAt: DateTime.utc(2026, 11, 5),
      );
      final client = IptvClient.forConnection(connection);
      final libraries = await client.fetchLibraries();
      expect(libraries.map((l) => l.id), [
        'iptv:conn-xt-1:live',
        'iptv:conn-xt-1:movies',
        'iptv:conn-xt-1:series',
      ]);
      expect(client.backend.id, 'xtream');
      expect(client.capabilities.liveTv, isTrue);
      expect(client.capabilities.liveTvDvr, isFalse);
      expect(client.streamHeaders, isEmpty);
      expect(client.watchedThreshold, 0.9);
      client.close();
    });
  });
}
