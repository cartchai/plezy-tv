import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/livetv_program.dart';
import 'package:plezy/utils/live_tv_scrub_block.dart';

LiveTvProgram _program({required int beginsAt, int? endsAt, String title = 'Show'}) => LiveTvProgram(
  key: title,
  title: title,
  beginsAt: beginsAt,
  endsAt: endsAt,
);

void main() {
  // Fixed "now": 2026-11-06 14:30:00 local. Hour block is 14:00–15:00.
  final now = DateTime(2026, 11, 6, 14, 30);
  final nowEpoch = now.millisecondsSinceEpoch ~/ 1000;
  final hourStart = DateTime(2026, 11, 6, 14).millisecondsSinceEpoch ~/ 1000;

  test('the programme covering now is the block', () {
    final block = liveScrubBlock([
      _program(beginsAt: nowEpoch - 1800, endsAt: nowEpoch + 1800),
    ], now);
    expect(block, (startEpoch: nowEpoch - 1800, endEpoch: nowEpoch + 1800));
  });

  test('a programme starting exactly at now is the block', () {
    final block = liveScrubBlock([
      _program(beginsAt: nowEpoch, endsAt: nowEpoch + 3600),
    ], now);
    expect(block, (startEpoch: nowEpoch, endEpoch: nowEpoch + 3600));
  });

  test('a programme that just ended is not the block', () {
    final block = liveScrubBlock([
      _program(beginsAt: nowEpoch - 3600, endsAt: nowEpoch),
    ], now);
    expect(block, (startEpoch: hourStart, endEpoch: hourStart + 3600));
  });

  test('no programme covering now falls back to the clock hour', () {
    final block = liveScrubBlock([
      _program(beginsAt: nowEpoch - 7200, endsAt: nowEpoch - 3600),
      _program(beginsAt: nowEpoch + 3600, endsAt: nowEpoch + 7200),
    ], now);
    expect(block, (startEpoch: hourStart, endEpoch: hourStart + 3600));
  });

  test('no EPG at all falls back to the clock hour', () {
    final block = liveScrubBlock(const [], now);
    expect(block, (startEpoch: hourStart, endEpoch: hourStart + 3600));
  });

  test('an open-ended programme falls back to the clock hour', () {
    final block = liveScrubBlock([
      _program(beginsAt: nowEpoch - 1800, endsAt: null),
    ], now);
    expect(block, (startEpoch: hourStart, endEpoch: hourStart + 3600));
  });

  test('the covering programme wins over its neighbours', () {
    final block = liveScrubBlock([
      _program(title: 'Before', beginsAt: nowEpoch - 7200, endsAt: nowEpoch - 3600),
      _program(title: 'Now', beginsAt: nowEpoch - 600, endsAt: nowEpoch + 3000),
      _program(title: 'After', beginsAt: nowEpoch + 3000, endsAt: nowEpoch + 6600),
    ], now);
    expect(block, (startEpoch: nowEpoch - 600, endEpoch: nowEpoch + 3000));
  });
}
