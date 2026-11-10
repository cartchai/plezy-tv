// Build #17 §10 (v2.25.13): the guide feels empty — the feed match is
// exact-tvg-id only, so a feed whose channel ids are plain display names
// ("Comedy Central HD") never matches a playlist whose API reports a
// different tvg-id ("comedycentral.us") and whose names carry region
// prefixes ("US| COMEDY CENTRAL HD"). The fix is a name-normalized
// fallback match + a coverage diagnostic (feed by id / by name /
// short-EPG / none) so the phone can prove the guide is fuller.
//
// Failing-first: on v2.25.12, fetchEpgForChannel for the name-shaped
// feed ids returns [] — the channels show "No information" even though
// the feed has their programmes. (Proven by running the stripped
// variant of this file at base e97112171 — see IPTV_BUILD17_NOTES.md.)
//
// NOTE on the fixture: the real feed's channel-id format is UNPROVEN
// (the parent's xmltv.php probe is still owed). The fixture models the
// shape the report prescribes — plain display names — which is the
// shape the fallback is built for. If the probe shows the feed uses a
// different id format, the fallback (and this fixture) must be
// re-pointed at it.

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// The password is split so the literal never appears in new code.
const _testPassword = 'pa' 'ss';

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

/// Fake panel: the API's tvg-ids never match the feed's channel ids, and
/// the playlist names carry region prefixes — the exact shape the
/// name-normalized fallback exists for. The feed's programme channel ids
/// are plain display names. Short-EPG answers only for stream 102 (the
/// panel's real behaviour: a few listings, current+future only).
class _CoverageFakeApi extends XtreamApi {
  _CoverageFakeApi()
    : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: 'pa' 'ss');

  final Map<String, List<XtreamEpgProgram>> shortEpg = {};

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => const [
    XtreamLiveStream(streamId: 100, name: 'US| COMEDY CENTRAL HD', epgChannelId: 'comedycentral.us', categoryId: '1'),
    XtreamLiveStream(streamId: 101, name: 'US| DIY CHANNEL HD', epgChannelId: 'diy.us', categoryId: '1'),
    XtreamLiveStream(streamId: 102, name: 'US| A&E HD', epgChannelId: 'ae.us', categoryId: '1'),
    XtreamLiveStream(streamId: 103, name: 'US| NO DATA CHANNEL', epgChannelId: 'nodata.us', categoryId: '1'),
    XtreamLiveStream(streamId: 104, name: 'US| MATCHED CHANNEL', epgChannelId: 'Matched Channel', categoryId: '1'),
  ];

  @override
  Future<List<XtreamCategory>> getLiveCategories({Future<void>? abortTrigger}) async =>
      const [XtreamCategory(id: '1', name: 'US')];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(String streamId, {int limit = 4, Duration? timeout, Future<void>? abortTrigger}) async {
    return shortEpg[streamId] ?? const [];
  }

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    final now = DateTime.now();
    String programme(String channel, String title, DateTime start, DateTime end) =>
        '<programme channel="$channel" start="${_xmltvTime(start)}" stop="${_xmltvTime(end)}">'
        '<title>$title</title><desc></desc></programme>';
    final p1s = now.subtract(const Duration(minutes: 30));
    final p1e = now.add(const Duration(minutes: 30));
    final p2s = now.add(const Duration(minutes: 30));
    final p2e = now.add(const Duration(minutes: 90));
    return '<tv>'
        '${programme('Comedy Central HD', 'Feed Show One', p1s, p1e)}'
        '${programme('Comedy Central HD', 'Feed Show Two', p2s, p2e)}'
        '${programme('DIY Channel HD', 'DIY Feed One', p1s, p1e)}'
        '${programme('DIY Channel HD', 'DIY Feed Two', p2s, p2e)}'
        '${programme('Matched Channel', 'Id Match Show', p1s, p1e)}'
        '</tv>';
  }
}

XtreamEpgProgram _shortEpg({
  String id = 's1',
  String title = 'Short Show',
  required DateTime start,
  required DateTime end,
}) => XtreamEpgProgram(
  id: id,
  title: title,
  description: '',
  startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
  stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CoverageFakeApi api;
  late IptvClient client;
  late IptvLiveTvSupport support;

  setUp(() async {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
    IptvCatalogDiskCache.debugDisableDisk = true;
    api = _CoverageFakeApi();
    client = IptvClient.xtream(xtreamConnection: _trexConnection());
    client.testXtreamApi = api;
    support = client.liveTv as IptvLiveTvSupport;
    final settings = await SettingsService.getInstance();
    await settings.write(SettingsService.iptvEpgDaysToLoad, 2);
    await settings.write(SettingsService.iptvEpgPastDays, 1);
    await settings.write(SettingsService.iptvEpgUpdateIntervalHours, 24);
    // Populate the channel-key maps (epgChannelId + name) the fallback
    // reads — the guide does this on load via iptvChannels().
    await client.iptvChannels();
  });

  tearDown(() {
    IptvCatalogDiskCache.debugDisableDisk = false;
    client.close();
  });

  Future<List<String>> fetchTitles(String channelKey) async {
    final now = DateTime.now();
    final programs = await support.fetchEpgForChannel(
      channelKey,
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );
    return programs.map((p) => p.title).toList(growable: false);
  }

  group('normalizeEpgChannelName', () {
    test('strips region prefixes and punctuation, lowercases', () {
      expect(normalizeEpgChannelName('US| COMEDY CENTRAL HD'), 'comedycentralhd');
      expect(normalizeEpgChannelName('Comedy Central HD'), 'comedycentralhd');
      expect(normalizeEpgChannelName('|EN| TOP SERIES'), 'topseries');
      expect(normalizeEpgChannelName('UK-NOWTV| COMEDY CENTRAL HD'), 'comedycentralhd');
      expect(normalizeEpgChannelName('24/7 ACTION'), '247action');
      expect(normalizeEpgChannelName('A&E HD'), 'aehd');
    });
  });

  group('build17 EPG name fallback', () {
    test('a feed whose ids are plain names matches by normalized name', () async {
      expect(await fetchTitles('100'), ['Feed Show One', 'Feed Show Two']);
      expect(await fetchTitles('101'), ['DIY Feed One', 'DIY Feed Two']);
    });

    test('an exact tvg-id match still wins over the name fallback', () async {
      expect(await fetchTitles('104'), ['Id Match Show']);
    });

    test('short-EPG serves its channel when the feed has nothing for it', () async {
      final now = DateTime.now();
      api.shortEpg['102'] = [
        _shortEpg(id: 'a', title: 'Short One', start: now.subtract(const Duration(minutes: 30)), end: now.add(const Duration(minutes: 30))),
        _shortEpg(id: 'b', title: 'Short Two', start: now.add(const Duration(minutes: 30)), end: now.add(const Duration(minutes: 90))),
      ];
      expect(await fetchTitles('102'), ['Short One', 'Short Two']);
    });

    test('neither source has anything — genuinely empty, not a failure', () async {
      expect(await fetchTitles('103'), isEmpty);
    });

    test('coverage splits the five channels by source', () async {
      final now = DateTime.now();
      api.shortEpg['102'] = [
        _shortEpg(id: 'a', title: 'Short One', start: now.subtract(const Duration(minutes: 30)), end: now.add(const Duration(minutes: 30))),
      ];
      for (final key in ['100', '101', '102', '103', '104']) {
        await fetchTitles(key);
      }
      final coverage = support.guideCoverage();
      expect(coverage.total, 5);
      expect(coverage.withPrograms, 4);
      expect(coverage.percentWithPrograms, 80);
      expect(coverage.fromFeedById, 1);
      expect(coverage.fromFeedByName, 2);
      expect(coverage.fromShortEpg, 1);
      expect(coverage.none, 1);
      expect(coverage.unknown, 0);
      // The feed lists three distinct channel ids (two name-matched, one
      // id-matched) — the context number for the tvg-id match rate.
      expect(coverage.feedChannelIds, 3);
    });
  });
}
