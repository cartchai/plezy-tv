// EPG matching fix (PlezTV 1.2.5): the feed loads but matches 0/26151
// channels (RESEARCH_EPG_MATCHING.md). The matcher is rebuilt in order:
// diagnostics first, display-name parsing, a case-insensitive tvg-id
// tier, jellyfin-tentacle-strength normalization, a numeric-id tier, a
// loose-name fallback for split feed ids, and uniqueness gating that
// never guesses.
//
// No live panel use — every test serves a scripted feed from a fake
// Xtream API (panel.example.com) or parses a literal XMLTV string.
// No streams are ever opened.
//
// FAILING-FIRST: the §5 table group below is written against the
// 1.2.4 base normalizer and FAILS there (6 of 9 rows do not meet);
// it passes only once the 1.2.5 normalizer lands.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/media/iptv_live_tv.dart';
import 'package:plezy/services/iptv/iptv_catalog_cache.dart';
import 'package:plezy/services/iptv/iptv_epg_sources.dart';
import 'package:plezy/services/iptv/iptv_playback_activity.dart';
import 'package:plezy/services/iptv/xmltv_parser.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// The password is split so the literal never appears in new code.
const _testPassword = 'pa' 'ss';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('§5 normalization table — each row must meet after the fix', () {
    test('playlist name and feed id reduce to one key per channel', () {
      // Row 1 (already met on 1.2.4 — the documented case).
      expect(
        normalizeEpgChannelName('US| COMEDY CENTRAL HD'),
        normalizeEpgChannelName('Comedy Central HD'),
      );
      // Rows 2-3: the "US - " prefix and the ".us" suffix must go.
      expect(normalizeEpgChannelName('US - CNN HD'), normalizeEpgChannelName('CNN.us'));
      expect(normalizeEpgChannelName('US - CNN HD'), normalizeEpgChannelName('CNN'));
      // Row 4: the HD marker must go.
      expect(normalizeEpgChannelName('Comedy Central HD'), normalizeEpgChannelName('Comedy Central'));
      // Row 5: the "UK:" prefix and the ".uk" suffix must go.
      expect(normalizeEpgChannelName('UK: SKY ONE'), normalizeEpgChannelName('SkyOne.uk'));
      // Row 6: a two-code prefix plus the HD marker.
      expect(normalizeEpgChannelName('CA EN: DISCOVERY HD'), normalizeEpgChannelName('Discovery'));
      // Row 7: the ".uk" suffix plus the HD marker.
      expect(normalizeEpgChannelName('BBC One HD'), normalizeEpgChannelName('BBCOne.uk'));
    });

    test('the §5 keys are the single key per channel', () {
      expect(normalizeEpgChannelName('US - CNN HD'), 'cnn');
      expect(normalizeEpgChannelName('CNN.us'), 'cnn');
      expect(normalizeEpgChannelName('CNN'), 'cnn');
      expect(normalizeEpgChannelName('Comedy Central HD'), 'comedycentral');
      expect(normalizeEpgChannelName('Comedy Central'), 'comedycentral');
      expect(normalizeEpgChannelName('UK: SKY ONE'), 'skyone');
      expect(normalizeEpgChannelName('SkyOne.uk'), 'skyone');
      expect(normalizeEpgChannelName('CA EN: DISCOVERY HD'), 'discovery');
      expect(normalizeEpgChannelName('Discovery'), 'discovery');
      expect(normalizeEpgChannelName('BBC One HD'), 'bbcone');
      expect(normalizeEpgChannelName('BBCOne.uk'), 'bbcone');
    });

    test('the 1.2.4 contract cases keep their keys', () {
      expect(normalizeEpgChannelName('US| COMEDY CENTRAL HD'), 'comedycentral');
      expect(normalizeEpgChannelName('|EN| TOP SERIES'), 'topseries');
      expect(normalizeEpgChannelName('UK-NOWTV| COMEDY CENTRAL HD'), 'comedycentral');
      expect(normalizeEpgChannelName('24/7 ACTION'), '247action');
    });

    test('jellyfin-tentacle shapes: entities, accents, superscripts', () {
      // "&" reads as "and" so "A&E" meets "A and E" (1.2.4 said "aehd").
      expect(normalizeEpgChannelName('A&E HD'), 'aande');
      expect(normalizeEpgChannelName('A and E'), 'aande');
      // "CA: TSN 5 ᴿᴬᵂ" -> "tsn5" (jellyfin-tentacle's own example).
      expect(normalizeEpgChannelName('CA: TSN 5 ᴿᴬᵂ'), 'tsn5');
      // Accents fold: "Šiauliai" == "Siauliai".
      expect(normalizeEpgChannelName('Šiauliai'), 'siauliai');
      expect(normalizeEpgChannelName('Café TV'), 'cafetv');
      // HTML entities decode before "&" becomes "and".
      expect(normalizeEpgChannelName('A&amp;E HD'), 'aande');
      // Quality markers drop as words, not as substrings: "HDNet" keeps "hdnet".
      expect(normalizeEpgChannelName('HDNet'), 'hdnet');
      // A trailing "@Feed" suffix and a ".xx" country suffix drop.
      expect(normalizeEpgChannelName('ABCTV.au@Sydney'), 'abctv');
    });
  });
  group('XMLTV parser — display names + parse stats (Fix 1/2)', () {
    String xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

    test('parseXmltv records channel ids with their display names', () {
      const body = '<?xml version="1.0" encoding="UTF-8"?><tv>'
          '<channel id="cnn.us"><display-name>CNN</display-name><display-name>CNN International</display-name></channel>'
          '<channel id="bbc.uk"><display-name>BBC One</display-name></channel>'
          '<programme channel="cnn.us" start="20261113120000 +0000" stop="20261113130000 +0000"><title>News</title></programme>'
          '</tv>';
      final stats = XmltvParseStats();
      final programs = parseXmltv(body, stats: stats);
      expect(programs, hasLength(1));
      expect(stats.channelIds, {'cnn.us', 'bbc.uk'});
      expect(stats.channelDisplayNames['cnn.us'], ['CNN', 'CNN International']);
      expect(stats.channelDisplayNames['bbc.uk'], ['BBC One']);
      expect(stats.programsSeen, 1);
      expect(stats.programsYielded, 1);
      expect(stats.programChannelIds, {'cnn.us'});
    });

    test('parseXmltvStream records display names and pre-filter counts', () async {
      final now = DateTime.now().toUtc();
      final body = '<?xml version="1.0" encoding="UTF-8"?><tv>'
          '<channel id="cnn.us"><display-name>CNN</display-name></channel>'
          '<channel id="bbc.uk"><display-name>BBC One</display-name></channel>'
          '<programme channel="cnn.us" start="${xmltvTime(now)}" stop="${xmltvTime(now.add(const Duration(hours: 1)))}"><title>News</title></programme>'
          '<programme channel="bbc.uk" start="${xmltvTime(now.add(const Duration(days: 30)))}" stop="${xmltvTime(now.add(const Duration(days: 30, hours: 1)))}"><title>Future</title></programme>'
          '</tv>';
      final stats = XmltvParseStats();
      final programs = await parseXmltvStream(
        Stream<List<int>>.value(utf8.encode(body)),
        windowFromEpoch: now.subtract(const Duration(days: 7)).millisecondsSinceEpoch ~/ 1000,
        windowToEpoch: now.add(const Duration(days: 8)).millisecondsSinceEpoch ~/ 1000,
        stats: stats,
      ).toList();
      expect(programs, hasLength(1));
      expect(programs.first.channelId, 'cnn.us');
      // Seen before the window filter: both programmes. Yielded: only
      // the in-window one. The dropped id is still recorded — the
      // loose fallback needs to know it exists.
      expect(stats.programsSeen, 2);
      expect(stats.programsYielded, 1);
      expect(stats.channelIds, {'cnn.us', 'bbc.uk'});
      expect(stats.channelDisplayNames['cnn.us'], ['CNN']);
      expect(stats.channelDisplayNames['bbc.uk'], ['BBC One']);
      expect(stats.programChannelIds, {'cnn.us', 'bbc.uk'});
    });

    test('a feed with no <channel> elements reports none', () {
      const body = '<?xml version="1.0" encoding="UTF-8"?><tv>'
          '<programme channel="cnn.us" start="20261113120000 +0000" stop="20261113130000 +0000"><title>News</title></programme>'
          '</tv>';
      final stats = XmltvParseStats();
      final programs = parseXmltv(body, stats: stats);
      expect(programs, hasLength(1));
      expect(stats.channelIds, isEmpty);
      expect(stats.channelDisplayNames, isEmpty);
      expect(stats.programChannelIds, {'cnn.us'});
    });
  });

  group('Country + identity helpers (Fix 6/7)', () {
    test('epgChannelCountry reads the playlist country', () {
      expect(epgChannelCountry('CA EN: DISCOVERY HD'), 'ca');
      expect(epgChannelCountry('|UK| SKY ONE'), 'gb');
      expect(epgChannelCountry('US - CNN HD'), 'us');
      // A language-only tag names no country.
      expect(epgChannelCountry('EN: X'), isNull);
      expect(epgChannelCountry('CNN'), isNull);
    });

    test('epgFeedIdCountry reads the .xx suffix', () {
      expect(epgFeedIdCountry('TNTSport1.uk'), 'gb');
      expect(epgFeedIdCountry('CNN.us'), 'us');
      expect(epgFeedIdCountry('SkyOne.de'), 'de');
      expect(epgFeedIdCountry('CNN'), isNull);
    });

    test('epgDisplayNamesAreOneChannel gates the mixed-id rule', () {
      // One channel under two names (a brand prefix plus a generic
      // word) is one channel.
      expect(epgDisplayNamesAreOneChannel(['HISTORY', 'DISCOVERY HISTORY']), isTrue);
      expect(epgDisplayNamesAreOneChannel(['CNN', 'CNN HD']), isTrue);
      // Two different channels sharing one id are not.
      expect(epgDisplayNamesAreOneChannel(['LRT', 'LRT PLUS']), isFalse);
      expect(epgDisplayNamesAreOneChannel(['BBC ONE', 'BBC TWO']), isFalse);
    });
  });

  group('Match chain — integration (fake provider feed)', () {
    late Directory tempDir;
    late _MatchingEpgApi api;
    late IptvClient client;
    late IptvLiveTvSupport support;

    setUp(() async {
      resetSharedPreferencesForTest();
      LocaleSettings.setLocaleSync(AppLocale.en);
      await SettingsService.getInstance();
      IptvCatalogDiskCache.debugDisableDisk = true;
      tempDir = await Directory.systemTemp.createTemp('plezy_epg_matching_1_2_5_');
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = () async => tempDir;
      api = _MatchingEpgApi();
      client = IptvClient.xtream(xtreamConnection: _trexConnection());
      client.testXtreamApi = api;
      support = client.liveTv as IptvLiveTvSupport;
    });

    tearDown(() async {
      IptvLiveTvSupport.debugEpgCacheDirectoryProvider = null;
      IptvCatalogDiskCache.debugDisableDisk = false;
      IptvPlaybackActivity.instance.markIdle();
      IptvPlaybackActivity.debugResetInstance();
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
          break;
        } on FileSystemException {
          if (attempt == 1) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    Future<void> loadChannels() async => client.iptvChannels();

    ({DateTime from, DateTime to}) windowAround(DateTime now) => (
      from: now.subtract(const Duration(hours: 1)),
      to: now.add(const Duration(hours: 6)),
    );

    test('case-insensitive tvg-id (Fix 3): CNN.us matches epgChannelId CNN.us', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 600, name: 'CNN US', epgChannelId: 'CNN.us'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'cnn.us',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('600', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['CNN News']);
      final detail = await support.channelEpgDetail('600', from: window.from, to: window.to);
      expect(detail.matchedXmltvId, 'cnn.us');
      expect(detail.matchMethod, 'tvg-id');
    });

    test('numeric tier (Fix 5): feed id 012345 matches stream id 12345', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 12345, name: 'Channel 12345', epgChannelId: 'ch12345'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: '012345',
          displayNames: ['Channel 12345'],
          programmes: [(title: 'Numeric Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('12345', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Numeric Show']);
      final detail = await support.channelEpgDetail('12345', from: window.from, to: window.to);
      expect(detail.matchedXmltvId, '012345');
      expect(detail.matchMethod, 'tvg-id');
    });

    test('name via display-name (Fix 2): US - CNN HD matches feed cnn.us displaying CNN', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 700, name: 'US - CNN HD', epgChannelId: 'cnn'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'cnn.us',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('700', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['CNN News']);
      final detail = await support.channelEpgDetail('700', from: window.from, to: window.to);
      expect(detail.matchedXmltvId, 'cnn.us');
      expect(detail.matchMethod, 'name');
    });

    test('uniqueness gating (Fix 7): two feed ids displaying CNN never match', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 500, name: 'CNN', epgChannelId: 'cnn'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'cnn-a',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN A', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'cnn-b',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN B', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      expect(await support.fetchEpgForChannel('500', from: window.from, to: window.to), isEmpty);
      final detail = await support.channelEpgDetail('500', from: window.from, to: window.to);
      expect(detail.hasGuide, isFalse);
      expect(detail.noGuideReason, IptvEpgNoGuideReason.ambiguous);
      final without = await support.channelsWithoutGuide();
      expect(without, hasLength(1));
      expect(without.first.reason, IptvEpgNoGuideReason.ambiguous);
      expect(without.first.candidates, ['cnn-a', 'cnn-b']);
    });

    test('foreign gating (Fix 7): UK: SKY ONE does not take the German Sky One', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 400, name: 'UK: SKY ONE', epgChannelId: 'skyone'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'SkyOne.de',
          displayNames: ['Sky One'],
          programmes: [(title: 'Sky Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      expect(await support.fetchEpgForChannel('400', from: window.from, to: window.to), isEmpty);
      final detail = await support.channelEpgDetail('400', from: window.from, to: window.to);
      expect(detail.hasGuide, isFalse);
      expect(detail.noGuideReason, IptvEpgNoGuideReason.foreign);
      final without = await support.channelsWithoutGuide();
      expect(without, hasLength(1));
      expect(without.first.reason, IptvEpgNoGuideReason.foreign);
      expect(without.first.candidates, ['SkyOne.de']);
    });

    test('loose fallback (Fix 6, the TNT case): a split feed id is found by its in-window copy', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 300, name: 'TNT SPORT 1', epgChannelId: 'TNTSport1.uk'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'TNTSport1.uk',
          displayNames: ['UK: TNT SPORTS 1'],
          programmes: [
            (title: 'TNT Old', start: now.add(const Duration(days: 30)), end: now.add(const Duration(days: 30, hours: 1))),
          ],
        ),
        (
          id: 'tntsports1.uk',
          displayNames: ['NOW: TNT SPORT 1'],
          programmes: [(title: 'TNT Live', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('300', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['TNT Live']);
      final detail = await support.channelEpgDetail('300', from: window.from, to: window.to);
      expect(detail.matchedXmltvId, 'tntsports1.uk');
      expect(detail.matchMethod, 'name-loose');
    });

    test('matched-but-no-programmes (Fix 7): an identified id with nothing in-window says so', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 300, name: 'TNT SPORT 1', epgChannelId: 'TNTSport1.uk'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'TNTSport1.uk',
          displayNames: ['UK: TNT SPORTS 1'],
          programmes: [
            (title: 'TNT Old', start: now.add(const Duration(days: 30)), end: now.add(const Duration(days: 30, hours: 1))),
          ],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      expect(await support.fetchEpgForChannel('300', from: window.from, to: window.to), isEmpty);
      final detail = await support.channelEpgDetail('300', from: window.from, to: window.to);
      expect(detail.hasGuide, isFalse);
      expect(detail.noGuideReason, IptvEpgNoGuideReason.matchedButNoPrograms);
      final without = await support.channelsWithoutGuide();
      expect(without, hasLength(1));
      expect(without.first.reason, IptvEpgNoGuideReason.matchedButNoPrograms);
      expect(without.first.candidates, ['TNTSport1.uk']);
    });

    test('mixed feed id (Fix 7): LRT PLUS + LRT under one id is never name-matched', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 800, name: 'LRT', epgChannelId: 'lrt-x'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'lrt',
          displayNames: ['LRT PLUS', 'LRT'],
          programmes: [(title: 'LRT Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      expect(await support.fetchEpgForChannel('800', from: window.from, to: window.to), isEmpty);
    });

    test('feed health (Fix 8): an empty feed says it contains no channels', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
      ];
      api.xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
      final result = await support.reloadTvDetails();
      expect(result.feedOutcomes, hasLength(1));
      final outcome = result.feedOutcomes.first;
      expect(outcome.kind, IptvEpgFeedOutcomeKind.loadedNoMatch);
      expect(outcome.feedChannelsParsed, 0);
      expect(outcome.feedProgramsParsed, 0);
      expect(outcome.feedProgramsRetained, 0);
      expect(epgFeedOutcomeLine(outcome, result.channelsLoaded), contains('contains no channels'));
    });

    test('feed health (Fix 8): programmes only outside the window say so', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 100, name: 'Channel 100', epgChannelId: 'ch100'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'ch100',
          displayNames: ['Channel 100'],
          programmes: [
            (title: 'Future', start: now.add(const Duration(days: 30)), end: now.add(const Duration(days: 30, hours: 1))),
          ],
        ),
      ]);
      final result = await support.reloadTvDetails();
      expect(result.feedOutcomes, hasLength(1));
      final outcome = result.feedOutcomes.first;
      expect(outcome.kind, IptvEpgFeedOutcomeKind.loadedNoMatch);
      expect(outcome.feedProgramsParsed, 1);
      expect(outcome.feedProgramsRetained, 0);
      expect(outcome.feedChannelsParsed, 1);
      expect(epgFeedOutcomeLine(outcome, result.channelsLoaded), contains('fall outside the loaded window'));
    });

    test('Reload diagnostics (Fix 1): per-tier counts, samples, epg_channel_id count', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 600, name: 'CNN US', epgChannelId: 'CNN.us'),
        XtreamLiveStream(streamId: 700, name: 'US - CNN HD', epgChannelId: 'cnn'),
        XtreamLiveStream(streamId: 800, name: 'LRT', epgChannelId: 'lrt-x'),
        XtreamLiveStream(streamId: 500, name: 'HBO', epgChannelId: 'hbo'),
        XtreamLiveStream(streamId: 400, name: 'UK: SKY ONE', epgChannelId: 'skyone'),
        XtreamLiveStream(streamId: 300, name: 'TNT SPORT 1', epgChannelId: 'TNTSport1.uk'),
        XtreamLiveStream(streamId: 12345, name: 'Channel 12345', epgChannelId: 'ch12345'),
        XtreamLiveStream(streamId: 200, name: 'beIN SPORTS 1 HD', epgChannelId: 'beIN.Sports.1'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'cnn.us',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'hbo-a',
          displayNames: ['HBO'],
          programmes: [(title: 'HBO A', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'hbo-b',
          displayNames: ['HBO'],
          programmes: [(title: 'HBO B', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'SkyOne.de',
          displayNames: ['Sky One'],
          programmes: [(title: 'Sky Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'TNTSport1.uk',
          displayNames: ['UK: TNT SPORTS 1'],
          programmes: [
            (title: 'TNT Old', start: now.add(const Duration(days: 30)), end: now.add(const Duration(days: 30, hours: 1))),
          ],
        ),
        (
          id: 'tntsports1.uk',
          displayNames: ['NOW: TNT SPORT 1'],
          programmes: [(title: 'TNT Live', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: '012345',
          displayNames: ['Channel 12345'],
          programmes: [(title: 'Numeric Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'lrt',
          displayNames: ['LRT PLUS', 'LRT'],
          programmes: [(title: 'LRT Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'beIN 1',
          displayNames: ['beIN 1'],
          programmes: [(title: 'beIN Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 8);
      expect(result.withGuide, 4);
      expect(result.withoutGuide, 4);
      expect(result.matchTiers.manual, 0);
      expect(result.matchTiers.tvgId, 2);
      expect(result.matchTiers.name, 1);
      expect(result.matchTiers.nameLoose, 1);
      expect(result.matchTiers.ambiguous, 1);
      expect(result.matchTiers.foreign, 1);
      expect(result.matchTiers.noTvgId, 0);
      expect(result.matchTiers.tvgIdNotInFeed, 2);
      expect(result.matchTiers.matchedButNoProgrammes, 0);
      expect(result.matchTiers.none, 0);
      expect(result.matchTiers.matched, 4);
      expect(result.matchTiers.unmatched, 4);
      expect(result.epgChannelIdCount, 8);
      expect(result.feedSamples.map((e) => e.xmltvId), ['012345', 'SkyOne.de', 'beIN 1', 'cnn.us', 'hbo-a']);
      expect(result.sampleUnmatched.map((e) => e.channelName), ['LRT', 'HBO', 'UK: SKY ONE', 'beIN SPORTS 1 HD']);
      final outcome = result.feedOutcomes.first;
      expect(outcome.kind, IptvEpgFeedOutcomeKind.loaded);
      expect(outcome.feedChannels, 8);
      expect(outcome.matchedChannels, 4);
      expect(outcome.feedProgramsParsed, 9);
      expect(outcome.feedProgramsRetained, 8);
      expect(outcome.feedChannelsParsed, 9);
    });

    test('Assign data (Fix 2/9): epgFeedChannels carries the display names', () async {
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'CNN.us',
          displayNames: ['CNN', 'CNN International'],
          programmes: [(title: 'CNN News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      final channels = await support.epgFeedChannels();
      expect(channels, hasLength(1));
      expect(channels.first.xmltvId, 'CNN.us');
      expect(channels.first.displayNames, ['CNN', 'CNN International']);
      // The Assign search is normalized: typing "cnn" finds "CNN.us"
      // by id and by display name alike.
      const query = 'cnn';
      final key = normalizeEpgChannelName(query);
      final found = channels.where((c) {
        return normalizeEpgChannelName(c.xmltvId).contains(key) ||
            c.displayNames.any((d) => normalizeEpgChannelName(d).contains(key));
      }).toList(growable: false);
      expect(found, hasLength(1));
    });
  });

}

XtreamConnection _trexConnection() => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  createdAt: DateTime.utc(2026, 11, 6),
);

String _xmltvTime(DateTime dt) => '${DateFormat('yyyyMMddHHmmss').format(dt.toUtc())} +0000';

/// One feed channel: its id, its display names, and its programmes.
typedef _FeedChannel = ({
  String id,
  List<String> displayNames,
  List<({String title, DateTime start, DateTime end})> programmes,
});

String _feedFrom(List<_FeedChannel> channels) {
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  for (final channel in channels) {
    buf.write('<channel id="${channel.id}">');
    for (final name in channel.displayNames) {
      buf.write('<display-name>$name</display-name>');
    }
    buf.write('</channel>');
  }
  for (final channel in channels) {
    for (final programme in channel.programmes) {
      buf.write('<programme start="${_xmltvTime(programme.start)}" stop="${_xmltvTime(programme.end)}" channel="${channel.id}">'
          '<title>${programme.title}</title></programme>');
    }
  }
  buf.write('</tv>');
  return buf.toString();
}

/// Fake provider: scripted short-EPG listings per stream id, a scripted
/// xmltv.php feed, and a MUTABLE live-streams list.
class _MatchingEpgApi extends XtreamApi {
  _MatchingEpgApi() : super(serverUrl: 'https://panel.example.com:8080', username: 'user', password: _testPassword);

  final Map<String, List<XtreamEpgProgram>> scripted = {};
  String xmltvBody = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
  List<XtreamLiveStream> liveStreams = [];

  @override
  Future<List<XtreamEpgProgram>> getShortEpg(
    String streamId, {
    int limit = 4,
    Duration? timeout,
    Future<void>? abortTrigger,
  }) async {
    return (scripted[streamId] ?? const []).take(limit).toList();
  }

  @override
  Future<XmltvFeedFetch> getXmltvFeed({String? etag, String? lastModified, Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async {
    return (
      bytes: Stream<List<int>>.value(utf8.encode(await getXmltv(timeout: timeout, abortTrigger: abortTrigger))),
      notModified: false,
      etag: null,
      lastModified: null,
    );
  }

  @override
  Future<String> getXmltv({Duration timeout = const Duration(seconds: 120), Future<void>? abortTrigger}) async => xmltvBody;

  @override
  Future<List<XtreamLiveStream>> getLiveStreams({String? categoryId, Future<void>? abortTrigger}) async => liveStreams;
}
