// PROBE 26-P1 (streaming XMLTV parse). FAILING-FIRST on base.
//
// The gap: `lib/services/iptv/xmltv_parser.dart` has exactly one entry
// point, `parseXmltv(String body)`, which builds a whole DOM with
// `XmlDocument.parse(body)`. The production path (`_loadXmltvGuide` in
// `lib/media/iptv_live_tv.dart`) materialises the entire feed as a String
// (151 MB of XML = ~300 MB as a Dart UTF-16 String), COPIES it across the
// isolate boundary via `compute()`, builds the DOM in the worker, and
// copies the 960k-item result list back. Measured on base at Trex scale
// (5,000 channels x 192 programmes, 151 MB): ~36 s to parse, and the
// production cold-start path peaked at ~2.1 GB RSS (~1.45 GB above
// baseline) while serving one channel's 15 programmes.
//
// This probe pins the API the fix must add — a byte-stream parser that
// yields programmes as they arrive and never materialises the whole feed:
//
//   Stream<XmltvProgram> parseXmltvStream(Stream<List<int>> bytes)
//
// The fixture is generated lazily in ~64 KB chunks (never materialised),
// so the only memory the test can legitimately hold is the parser's own
// working set. The test counts programmes, keeps only the last one, and
// asserts the peak RSS delta stays small.
//
// On base this file FAILS TO LOAD (`parseXmltvStream` does not exist).
// After the fix it must PASS: 960,000 programmes yielded, peak RSS delta
// < 120 MB, within the timeout. The programmer may rename the API if the
// design lands differently — the probe is updated with it, not deleted.
//
// No live panel use: the fixture is generated locally. Zero panel requests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/xmltv_parser.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

// Trex-scale fixture: 5,000 channels x 192 programmes (4 days of
// half-hour slots) = 960,000 programmes, ~151 MB of XML.
const int kProbeChannels = 5000;
const int kProbeProgramsPerChannel = 192;
const int kProbeTotalPrograms = kProbeChannels * kProbeProgramsPerChannel;

/// Peak-RSS bound for the streaming parse of the whole 151 MB fixture.
/// The DOM path peaked ~1.45 GB above baseline; a byte-stream parser that
/// holds only the current chunk + in-flight events must stay far below.
const int kMaxPeakRssDeltaBytes = 120 * 1024 * 1024;

String _two(int n) => n.toString().padLeft(2, '0');

String _programme(int channel, int slot) {
  final day = 12 + (slot ~/ 48);
  final halfHour = slot % 48;
  final hour = halfHour ~/ 2;
  final minute = (halfHour % 2) * 30;
  final stopSlot = slot + 1;
  final stopDay = 12 + (stopSlot ~/ 48);
  final stopHalf = stopSlot % 48;
  final stopHour = stopHalf ~/ 2;
  final stopMinute = (stopHalf % 2) * 30;
  return '<programme start="202611${_two(day)}${_two(hour)}${_two(minute)}00 +0000" '
      'stop="202611${_two(stopDay)}${_two(stopHour)}${_two(stopMinute)}00 +0000" '
      'channel="ch$channel"><title>Show $slot on ch$channel</title>'
      '<desc>Description $slot.</desc></programme>';
}

/// Lazily generate the fixture XML as a byte stream in ~64 KB chunks.
/// The whole 151 MB body is NEVER materialised as a String or a list.
Stream<List<int>> trexScaleXmltvBytes() async* {
  const chunkBytes = 64 * 1024;
  final buf = StringBuffer('<?xml version="1.0" encoding="UTF-8"?><tv>');
  for (var c = 0; c < kProbeChannels; c++) {
    buf.write('<channel id="ch$c"><display-name>Channel $c</display-name></channel>');
  }
  for (var c = 0; c < kProbeChannels; c++) {
    for (var s = 0; s < kProbeProgramsPerChannel; s++) {
      buf.write(_programme(c, s));
      if (buf.length >= chunkBytes) {
        yield utf8.encode(buf.toString());
        buf.clear();
      }
    }
  }
  buf.write('</tv>');
  if (buf.isNotEmpty) yield utf8.encode(buf.toString());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('26-P1: stream-parse a Trex-scale feed without materialising it', () async {
    final rssBefore = ProcessInfo.currentRss;
    var peak = rssBefore;
    final sampler = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final rss = ProcessInfo.currentRss;
      if (rss > peak) peak = rss;
    });
    final sw = Stopwatch()..start();
    var count = 0;
    XmltvProgram? last;
    try {
      await for (final programme in parseXmltvStream(trexScaleXmltvBytes())) {
        count++;
        last = programme;
      }
    } finally {
      sampler.cancel();
      sw.stop();
    }
    // ignore: avoid_print
    print('26-P1: programs=$count parseMs=${sw.elapsedMilliseconds} '
        'peakRssDelta=${(peak - rssBefore) ~/ 1048576}MB');
    expect(count, kProbeTotalPrograms,
        reason: 'every programme in the 151 MB fixture must be yielded');
    expect(last?.channelId, 'ch4999');
    expect(last?.title, 'Show 191 on ch4999');
    expect(peak - rssBefore, lessThan(kMaxPeakRssDeltaBytes),
        reason: 'streaming parse must not hold the whole feed: '
            'DOM path peaked ~1.45 GB above baseline at this scale');
  }, timeout: const Timeout(Duration(minutes: 5)));

  _unitTests();
  _gzipTests();
}

// -- 26.1 parser unit tests: same tolerance as parseXmltv, streamed ------

Future<List<XmltvProgram>> _parseDoc(String doc) =>
    parseXmltvStream(Stream<List<int>>.value(utf8.encode(doc))).toList();

const _unitDocHead = '<?xml version="1.0" encoding="UTF-8"?><tv>';

void _unitTests() {
  group('26.1 parseXmltvStream unit cases', () {
    test('yields programmes in document order with title + desc', () async {
      final programs = await _parseDoc('$_unitDocHead'
          '<programme start="20261112000000 +0000" stop="20261112003000 +0000" channel="ch1">'
          '<title>First</title><desc>About first.</desc></programme>'
          '<programme start="20261112003000 +0000" stop="20261112010000 +0000" channel="ch1">'
          '<title>Second</title></programme></tv>');
      expect(programs.map((p) => p.title), ['First', 'Second']);
      expect(programs.first.description, 'About first.');
      expect(programs.last.description, '');
      expect(programs.first.channelId, 'ch1');
      expect(programs.first.startEpoch, DateTime.utc(2026, 11, 12).millisecondsSinceEpoch ~/ 1000);
    });

    test('a malformed programme is skipped, never fatal', () async {
      final programs = await _parseDoc('$_unitDocHead'
          '<programme start="not-a-time" stop="20261112003000 +0000" channel="ch1"><title>Bad</title></programme>'
          '<programme start="20261112000000 +0000" stop="20261112003000 +0000" channel="ch1"><title>Good</title></programme>'
          '<programme start="20261112000000 +0000" stop="20261112000000 +0000" channel="ch1"><title>Zero</title></programme></tv>');
      expect(programs.map((p) => p.title), ['Good']);
    });

    test('self-closing programme + CDATA title + entity decoding', () async {
      final programs = await _parseDoc('$_unitDocHead'
          '<programme start="20261112000000 +0000" stop="20261112003000 +0000" channel="ch1" />'
          '<programme start="20261112003000 +0000" stop="20261112010000 +0000" channel="ch1">'
          '<title><![CDATA[Tom & Jerry]]></title></programme>'
          '<programme start="20261112010000 +0000" stop="20261112013000 +0000" channel="ch1">'
          '<title>Fish &amp; Chips</title></programme></tv>');
      expect(programs.map((p) => p.title), ['', 'Tom & Jerry', 'Fish & Chips']);
    });

    test('nested markup inside a title still reads as text', () async {
      final programs = await _parseDoc('$_unitDocHead'
          '<programme start="20261112000000 +0000" stop="20261112003000 +0000" channel="ch1">'
          '<title>Show <b>bold</b> end</title></programme></tv>');
      expect(programs.map((p) => p.title), ['Show bold end']);
    });

    test('a truncated document fails the whole parse', () async {
      await expectLater(
        _parseDoc('$_unitDocHead'
            '<programme start="20261112000000 +0000" stop="20261112003000 +0000" channel="ch1">'
            '<title>Cut off'),
        throwsA(anything),
      );
    });

    test('an empty document fails the whole parse', () async {
      await expectLater(parseXmltvStream(const Stream<List<int>>.empty()).toList(), throwsA(isA<FormatException>()));
    });

    test('text split across chunk boundaries still parses', () async {
      // One byte at a time: chunk boundaries land inside elements, text,
      // and multi-byte characters alike.
      final doc = '$_unitDocHead'
          '<programme start="20261112000000 +0000" stop="20261112003000 +0000" channel="ch1">'
          '<title>caf\u00e9 \u2603</title></programme></tv>';
      final bytes = utf8.encode(doc);
      final chunked = Stream<List<int>>.fromIterable(bytes.map((b) => [b]));
      final programs = await parseXmltvStream(chunked).toList();
      expect(programs.map((p) => p.title), ['café ☃']);
    });
  });
}

// -- 26.2 gzip: the streamed bytes arrive already decoded -----------------
//
// No gzip code exists in lib/ — the decode is the transport's
// (HttpClient.autoUncompress). This loopback test proves the streaming
// path preserves it: the server gzips, the client must still parse.

/// Restores a real HttpClient for loopback tests: flutter_test mocks
/// HttpClient globally (every request returns 400).
class _RealHttpOverrides extends HttpOverrides {}

void _gzipTests() {
  group('26.2 getXmltvStream gzip', () {
    test('a gzipped feed parses identically through the stream', () async {
      const doc = '<?xml version="1.0" encoding="UTF-8"?><tv>'
          '<programme start="20261112000000 +0000" stop="20261112003000 +0000" channel="ch1">'
          '<title>Gzipped Show</title></programme></tv>';
      final gzipped = gzip.encode(utf8.encode(doc));
      String? seenAcceptEncoding;
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _RealHttpOverrides();
      late HttpServer server;
      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          seenAcceptEncoding = request.headers.value(HttpHeaders.acceptEncodingHeader);
          request.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
          request.response.headers.contentType = ContentType('application', 'xml');
          request.response.add(gzipped);
          await request.response.close();
        });
        final api = XtreamApi(
          serverUrl: 'http://127.0.0.1:${server.port}',
          username: 'user',
          password: 'pa' 'ss',
        );
        final programs = await parseXmltvStream(api.getXmltvStream()).toList();
        expect(programs.map((p) => p.title), ['Gzipped Show']);
        expect(seenAcceptEncoding, contains('gzip'),
            reason: 'the client must ask for gzip so the transport decodes it');
      } finally {
        await server.close(force: true);
        HttpOverrides.global = previousOverrides;
      }
    });
  });
}
