import 'dart:async';
import 'dart:convert';

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

/// One programme from an XMLTV file, before mapping to [LiveTvProgram].
///
/// XMLTV is the guide format both M3U playlists (via their optional EPG
/// URL) and Xtream's `xmltv.php` speak: a `<programme>` carries
/// `start="YYYYMMDDHHMMSS ±HHMM"`, `stop`, and `channel="tvg-id"`, with
/// `<title>` and `<desc>` children.
/// Parsing runs in an isolate ([parseXmltv] is top-level) because provider
/// files run to megabytes.
class XmltvProgram {
  /// The `channel` attribute — matches an M3U entry's `tvg-id`.
  final String channelId;

  /// Epoch seconds (UTC).
  final int startEpoch;
  final int stopEpoch;
  final String title;
  final String description;

  const XmltvProgram({
    required this.channelId,
    required this.startEpoch,
    required this.stopEpoch,
    required this.title,
    required this.description,
  });
}

/// Stream-parse an XMLTV document from a byte stream, yielding one
/// [XmltvProgram] per `<programme>` element as it closes.
///
/// Build #26: the provider feed runs to ~150 MB at Trex scale, and the old
/// [parseXmltv] path held it ~4x at once (whole UTF-16 String, isolate
/// copy, DOM tree, result list — ~1.45 GB peak RSS on the production cold
/// start). This consumes chunked bytes through the `xml` package's chunked
/// event API (`Stream<String>.toXmlEvents`), so only the programme
/// currently being assembled is ever in memory. Callers must NOT `toList()`
/// the stream — accumulate only the retained list + indexes.
///
/// Same tolerance as [parseXmltv]: a malformed programme is skipped, never
/// fatal. Only a structurally unparseable document fails the whole parse
/// (unclosed element at EOF, mismatched tags, invalid XML, or a document
/// with no elements at all — an empty feed file reads as corrupt, exactly
/// like [parseXmltv] throwing on an empty body).
Stream<XmltvProgram> parseXmltvStream(Stream<List<int>> bytes) async* {
  // State for the programme currently being assembled.
  var inProgramme = false;
  var channelId = '';
  int? startEpoch;
  int? stopEpoch;
  final title = StringBuffer();
  final desc = StringBuffer();
  // The child element whose text is being accumulated ('title' / 'desc').
  String? currentChild;
  var sawElement = false;

  XmltvProgram? tryBuild() {
    if (channelId.isEmpty || startEpoch == null || stopEpoch == null || stopEpoch! <= startEpoch!) return null;
    return XmltvProgram(
      channelId: channelId,
      startEpoch: startEpoch!,
      stopEpoch: stopEpoch!,
      title: title.toString().trim(),
      description: desc.toString().trim(),
    );
  }

  void resetProgramme() {
    inProgramme = false;
    channelId = '';
    startEpoch = null;
    stopEpoch = null;
    title.clear();
    desc.clear();
    currentChild = null;
  }

  final events = bytes.transform(utf8.decoder).toXmlEvents(validateNesting: true);
  await for (final batch in events) {
    for (final event in batch) {
      if (event is XmlStartElementEvent) {
        sawElement = true;
        if (event.name == 'programme') {
          // A nested <programme> resets the outer one (malformed input);
          // the outer end event then finds empty state and yields nothing.
          resetProgramme();
          inProgramme = true;
          for (final attribute in event.attributes) {
            switch (attribute.name) {
              case 'channel':
                channelId = attribute.value.trim();
              case 'start':
                startEpoch = _parseXmltvTime(attribute.value);
              case 'stop':
                stopEpoch = _parseXmltvTime(attribute.value);
            }
          }
          // A self-closing <programme/> emits no end event (the event
          // parser yields a start event with isSelfClosing only).
          if (event.isSelfClosing) {
            final program = tryBuild();
            resetProgramme();
            if (program != null) yield program;
          }
        } else if (inProgramme && currentChild == null && (event.name == 'title' || event.name == 'desc')) {
          if (!event.isSelfClosing) currentChild = event.name;
        }
      } else if (event is XmlTextEvent) {
        if (currentChild == 'title') {
          title.write(event.value);
        } else if (currentChild == 'desc') {
          desc.write(event.value);
        }
      } else if (event is XmlCDATAEvent) {
        if (currentChild == 'title') {
          title.write(event.value);
        } else if (currentChild == 'desc') {
          desc.write(event.value);
        }
      } else if (event is XmlEndElementEvent) {
        if (event.name == 'programme' && inProgramme) {
          final program = tryBuild();
          resetProgramme();
          if (program != null) yield program;
        } else if (event.name == currentChild) {
          currentChild = null;
        }
      }
    }
  }
  if (!sawElement) {
    throw const FormatException('Empty XMLTV document');
  }
}

/// Parse an XMLTV document into programmes. Malformed entries are skipped,
/// never fatal: a provider file with one bad `<programme>` still yields the
/// rest. Throws only when the document itself does not parse.
List<XmltvProgram> parseXmltv(String body) {
  final document = XmlDocument.parse(body);
  final programs = <XmltvProgram>[];
  for (final element in document.findAllElements('programme')) {
    try {
      final channelId = element.getAttribute('channel')?.trim() ?? '';
      final start = _parseXmltvTime(element.getAttribute('start'));
      final stop = _parseXmltvTime(element.getAttribute('stop'));
      if (channelId.isEmpty || start == null || stop == null || stop <= start) continue;
      programs.add(
        XmltvProgram(
          channelId: channelId,
          startEpoch: start,
          stopEpoch: stop,
          title: element.getElement('title')?.innerText.trim() ?? '',
          description: element.getElement('desc')?.innerText.trim() ?? '',
        ),
      );
    } catch (_) {
      // One bad programme does not invalidate the file.
    }
  }
  return programs;
}

/// XMLTV time: `YYYYMMDDHHMMSS ±HHMM` (offset optional, defaults to UTC).
/// Returns epoch seconds, or null when the value does not parse.
int? _parseXmltvTime(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\s*([+-])(\d{2})(\d{2}))?$')
      .firstMatch(value.trim());
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  var epoch = DateTime.utc(year, month, day, hour, minute, second).millisecondsSinceEpoch ~/ 1000;
  final sign = match.group(7);
  if (sign != null) {
    final offsetMinutes = int.parse(match.group(8)!) * 60 + int.parse(match.group(9)!);
    epoch += sign == '+' ? -offsetMinutes * 60 : offsetMinutes * 60;
  }
  return epoch;
}
