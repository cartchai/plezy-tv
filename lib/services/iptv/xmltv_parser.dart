import 'package:xml/xml.dart';

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
