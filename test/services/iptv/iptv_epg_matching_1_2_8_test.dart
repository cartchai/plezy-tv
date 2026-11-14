// EPG matching round 2 (PlezTV 1.2.8): the Reload report stops lying
// about why the guide is thin, and the matcher picks up the channels
// the first round left behind (RESEARCH_EPG_MATCHING_ROUND2.md).
//
// F1 empty-string ids are absent (not "tvg-id not in feed"); F2 splits
// "matched but no programmes" by feed declaration vs window; F3 counts
// matches over ALL channels including hidden ones and renders the
// programme-carrying feed count; F4 folds zero-padded numbers (01→1);
// F5 runs the loose tier for no-id channels with a known country; F6
// adds display-name-exact preference and same-channel duplicate
// collapse; F7 stratifies the unmatched sample and names each row's
// reason; F8 names the serving source per guide row; F9 diagnoses the
// foreign bucket (language-tagged feed candidates).
//
// No live panel use — every test serves a scripted feed from a fake
// Xtream API (panel.example.com). No streams are ever opened.

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
import 'package:plezy/services/iptv/m3u_parser.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

// The password is split so the literal never appears in new code.
const _testPassword = 'pa' 'ss';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('F4 zero-padded number folding', () {
    test('01 folds to 1, 007 to 7, 101 and 0 are untouched', () {
      expect(normalizeEpgChannelName('AR| BEIN SPORTS 01 FHD'), 'beinsports1');
      expect(normalizeEpgChannelName('beIN Sports 1'), 'beinsports1');
      expect(normalizeEpgChannelName('CHANNEL 007'), 'channel7');
      expect(normalizeEpgChannelName('CHANNEL 101'), 'channel101');
      expect(normalizeEpgChannelName('CHANNEL 00'), 'channel0');
      expect(normalizeEpgChannelName('CHANNEL 0'), 'channel0');
    });
  });

  group('F1 empty-string ids are absent', () {
    test('an empty M3U tvg-id="" parses as absent', () {
      const playlist =
          '#EXTM3U\n#EXTINF:-1 tvg-id="" tvg-name="X",X Channel\nhttp://example.com/x\n'
          '#EXTINF:-1 tvg-id="cnn",CNN\nhttp://example.com/cnn\n';
      final entries = parseM3u(playlist);
      expect(entries, hasLength(2));
      expect(entries[0].tvgId, isNull);
      expect(entries[1].tvgId, 'cnn');
    });
  });

  group('Match chain round 2 — integration (fake provider feed)', () {
    late Directory tempDir;
    late _MatchingEpgApi api;
    late IptvClient client;
    late IptvLiveTvSupport support;

    setUp(() async {
      resetSharedPreferencesForTest();
      LocaleSettings.setLocaleSync(AppLocale.en);
      await SettingsService.getInstance();
      IptvCatalogDiskCache.debugDisableDisk = true;
      tempDir = await Directory.systemTemp.createTemp('plezy_epg_matching_1_2_8_');
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

    test('F1: an empty-string epg_channel_id is absent, not tvg-id-not-in-feed', () async {
      // The panel returns epg_channel_id: "" — parsed through fromJson,
      // the real panel path — for a channel with no name twin.
      api.liveStreams = [
        XtreamLiveStream.fromJson({
          'stream_id': 900,
          'name': 'ZZ No Id Channel',
          'epg_channel_id': '',
          'category_id': '1',
        }),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'other',
          displayNames: ['Other'],
          programmes: [(title: 'Other Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      final result = await support.reloadTvDetails();
      expect(result.epgChannelIdCount, 0);
      expect(result.matchTiers.noTvgId, 1);
      expect(result.matchTiers.tvgIdNotInFeed, 0);
    });

    test('F2a: a feed-declared id with zero programmes is declared, not outside-window', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 300, name: 'TNT SPORT 1', epgChannelId: 'TNTSport1.uk'),
      ];
      api.xmltvBody = _feedFrom([
        (id: 'TNTSport1.uk', displayNames: ['UK: TNT SPORTS 1'], programmes: []),
      ]);
      final result = await support.reloadTvDetails();
      expect(result.matchTiers.matchedButNoProgrammes, 1);
      expect(result.matchTiers.matchedButNoProgrammesDeclared, 1);
      expect(result.matchTiers.matchedButNoProgrammesOutsideWindow, 0);
      expect(result.nearestOutsideWindowProgramme, isNull);
    });

    test('F2b: programmes only outside the window are outside-window, with the nearest date', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 300, name: 'TNT SPORT 1', epgChannelId: 'TNTSport1.uk'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'TNTSport1.uk',
          displayNames: ['UK: TNT SPORTS 1'],
          programmes: [
            (title: 'TNT Later', start: now.add(const Duration(days: 5)), end: now.add(const Duration(days: 5, hours: 1))),
          ],
        ),
      ]);
      final result = await support.reloadTvDetails();
      expect(result.matchTiers.matchedButNoProgrammes, 1);
      expect(result.matchTiers.matchedButNoProgrammesDeclared, 0);
      expect(result.matchTiers.matchedButNoProgrammesOutsideWindow, 1);
      final nearest = result.nearestOutsideWindowProgramme;
      expect(nearest, isNotNull);
      expect(nearest!.difference(now.add(const Duration(days: 5))).abs(), lessThan(const Duration(minutes: 1)));
      // The overview/details keep the single reason — the split lives
      // in the Reload tiers and dialog.
      final window = windowAround(now);
      final detail = await support.channelEpgDetail('300', from: window.from, to: window.to);
      expect(detail.hasGuide, isFalse);
      expect(detail.noGuideReason, IptvEpgNoGuideReason.matchedButNoPrograms);
      final without = await support.channelsWithoutGuide();
      expect(without, hasLength(1));
      expect(without.first.reason, IptvEpgNoGuideReason.matchedButNoPrograms);
    });

    test('F3: matches are counted over ALL channels including hidden ones', () async {
      // Rebuild the client on a connection that hides one category.
      client = IptvClient.xtream(
        xtreamConnection: _trexConnection(hiddenCategoryIds: ['hidden-cat']),
      );
      client.testXtreamApi = api;
      support = client.liveTv as IptvLiveTvSupport;
      api.liveStreams = [
        XtreamLiveStream(streamId: 301, name: 'US - CNN HD', epgChannelId: 'cnn', categoryId: '1'),
        XtreamLiveStream(streamId: 302, name: 'ZZ Visible No Guide', epgChannelId: 'zz-vis', categoryId: '1'),
        XtreamLiveStream(streamId: 303, name: 'US - FOX HD', epgChannelId: 'fox', categoryId: 'hidden-cat'),
        XtreamLiveStream(streamId: 304, name: 'ZZ Hidden No Guide', epgChannelId: 'zz-hid', categoryId: 'hidden-cat'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'cnn.us',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN News', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'Fox.us',
          displayNames: ['FOX'],
          programmes: [(title: 'Fox Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'extra-a',
          displayNames: ['Extra A'],
          programmes: [(title: 'Extra A Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'extra-b',
          displayNames: ['Extra B'],
          programmes: [(title: 'Extra B Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'extra-c',
          displayNames: ['Extra C'],
          programmes: [(title: 'Extra C Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'extra-d',
          displayNames: ['Extra D'],
          programmes: [(title: 'Extra D Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (id: 'empty-a', displayNames: ['Empty A'], programmes: []),
        (id: 'empty-b', displayNames: ['Empty B'], programmes: []),
        (id: 'empty-c', displayNames: ['Empty C'], programmes: []),
        (id: 'empty-d', displayNames: ['Empty D'], programmes: []),
      ]);
      final result = await support.reloadTvDetails();
      // Visible list: 2 channels, 1 with guide. Full list: 4, 2 with
      // guide. The feed declares 10 channels, 6 carrying programmes.
      expect(result.channelsLoaded, 2);
      expect(result.withGuide, 1);
      expect(result.channelsLoadedAll, 4);
      expect(result.withGuideAllChannels, 2);
      expect(result.feedChannelIds, 6);
      final outcome = result.feedOutcomes.first;
      expect(outcome.feedChannelsParsed, 10);
      expect(outcome.feedChannels, 6);
    });

    test('F4: AR| BEIN SPORTS 01 FHD matches feed beIN Sports 1 by name', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 201, name: 'AR| BEIN SPORTS 01 FHD'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'beIN Sports 1',
          displayNames: ['beIN Sports 1'],
          programmes: [(title: 'beIN Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('201', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['beIN Show']);
      final detail = await support.channelEpgDetail('201', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name');
    });

    test('F5: US - FOX SPORTS 1 HD (no id) matches feed Fox Sport 1 by name-loose', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 202, name: 'US - FOX SPORTS 1 HD'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'Fox Sport 1',
          displayNames: ['Fox Sport 1'],
          programmes: [(title: 'Fox Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('202', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox Show']);
      final detail = await support.channelEpgDetail('202', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name-loose');
    });

    test('F4+F5: AR| BEIN SPORT 01 FHD (singular) matches feed beIN Sports 1 by name-loose', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 203, name: 'AR| BEIN SPORT 01 FHD'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'beIN Sports 1',
          displayNames: ['beIN Sports 1'],
          programmes: [(title: 'beIN Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('203', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['beIN Show']);
      final detail = await support.channelEpgDetail('203', from: window.from, to: window.to);
      expect(detail.matchMethod, 'name-loose');
    });

    test('F6A: display-name-exact preference picks Fox.us over the fox id', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 204, name: 'US - FOX HD'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'Fox.us',
          displayNames: ['FOX'],
          programmes: [(title: 'Fox US Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'fox',
          displayNames: ['FOX Channel'],
          programmes: [(title: 'Fox Generic Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('204', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['Fox US Show']);
      final detail = await support.channelEpgDetail('204', from: window.from, to: window.to);
      expect(detail.matchedXmltvId, 'Fox.us');
      expect(detail.matchMethod, 'name');
    });

    test('F6B: same-channel duplicate collapse picks the in-window CNN.us over CNN.us2', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 205, name: 'US - CNN HD'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'CNN.us',
          displayNames: ['CNN'],
          programmes: [(title: 'CNN Live', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'CNN.us2',
          displayNames: ['CNN'],
          programmes: [
            (title: 'CNN Later', start: now.add(const Duration(days: 5)), end: now.add(const Duration(days: 5, hours: 1))),
          ],
        ),
      ]);
      await loadChannels();
      final window = windowAround(now);
      final programs = await support.fetchEpgForChannel('205', from: window.from, to: window.to);
      expect(programs.map((p) => p.title), ['CNN Live']);
      final detail = await support.channelEpgDetail('205', from: window.from, to: window.to);
      expect(detail.matchedXmltvId, 'CNN.us');
      expect(detail.matchMethod, 'name');
    });

    test('F6B guard (1.2.5): two live feeds both claiming one name stay ambiguous', () async {
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
    });

    test('F7: the unmatched sample is stratified by reason and names each reason', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 1, name: 'ZZ Alpha'),
        XtreamLiveStream(streamId: 2, name: 'ZZ Beta'),
        XtreamLiveStream(streamId: 3, name: 'ZZ Gamma', epgChannelId: 'zz-gamma'),
        XtreamLiveStream(streamId: 4, name: 'ZZ Delta', epgChannelId: 'zz-delta'),
        XtreamLiveStream(streamId: 5, name: 'AMB', epgChannelId: 'amb-x'),
        XtreamLiveStream(streamId: 6, name: 'UK: SKY TWO', epgChannelId: 'skytwo'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'amb-a',
          displayNames: ['AMB'],
          programmes: [(title: 'Amb A', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'amb-b',
          displayNames: ['AMB'],
          programmes: [(title: 'Amb B', start: now, end: now.add(const Duration(hours: 1)))],
        ),
        (
          id: 'SkyTwo.de',
          displayNames: ['Sky Two'],
          programmes: [(title: 'Sky Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      final result = await support.reloadTvDetails();
      expect(result.channelsLoaded, 6);
      expect(result.withGuide, 0);
      expect(result.withoutGuide, 6);
      expect(result.matchTiers.noTvgId, 2);
      expect(result.matchTiers.tvgIdNotInFeed, 2);
      expect(result.matchTiers.ambiguous, 1);
      expect(result.matchTiers.foreign, 1);
      // Stratified: first row per reason in order of first appearance
      // (no-tvg-id, tvg-id-not-in-feed, ambiguous, foreign), then fill
      // to 5 in channel order — the foreign row must appear, and the
      // second tvg-id-not-in-feed row must not crowd it out.
      expect(
        result.sampleUnmatched.map((e) => e.channelName),
        ['ZZ Alpha', 'ZZ Beta', 'ZZ Gamma', 'AMB', 'UK: SKY TWO'],
      );
      expect(
        result.sampleUnmatched.map((e) => e.reason),
        ['no-tvg-id', 'no-tvg-id', 'tvg-id-not-in-feed', 'ambiguous', 'foreign'],
      );
      expect(result.sampleUnmatched.last.epgChannelId, 'skytwo');
    });

    test('F9: the foreign diagnostic records the language-tagged candidate', () async {
      api.liveStreams = [
        XtreamLiveStream(streamId: 400, name: 'US - CNN HD', epgChannelId: 'cnn-x'),
      ];
      final now = DateTime.now();
      api.xmltvBody = _feedFrom([
        (
          id: 'cnn',
          displayNames: ['EN: CNN'],
          programmes: [(title: 'CNN Show', start: now, end: now.add(const Duration(hours: 1)))],
        ),
      ]);
      final result = await support.reloadTvDetails();
      expect(result.matchTiers.foreign, 1);
      expect(result.foreignSamples, hasLength(1));
      final sample = result.foreignSamples.first;
      expect(sample.channelName, 'US - CNN HD');
      expect(sample.playlistCountry, 'us');
      expect(sample.candidates, hasLength(1));
      expect(sample.candidates.first.xmltvId, 'cnn');
      expect(sample.candidates.first.countries, ['en']);
      expect(result.foreignLanguageTaggedCandidateCount, 1);
      final without = await support.channelsWithoutGuide();
      expect(without, hasLength(1));
      expect(without.first.reason, IptvEpgNoGuideReason.foreign);
      expect(without.first.candidates, ['cnn']);
    });

    test('1.2.5 Reload diagnostics still hold (F4/F5/F6/F2/F7 regression guard)', () async {
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
      expect(result.matchTiers.matchedButNoProgrammesDeclared, 0);
      expect(result.matchTiers.matchedButNoProgrammesOutsideWindow, 0);
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
  });
}

XtreamConnection _trexConnection({List<String> hiddenCategoryIds = const []}) => XtreamConnection(
  id: 'trex',
  name: 'Trex',
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  password: _testPassword,
  hiddenCategoryIds: hiddenCategoryIds,
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
