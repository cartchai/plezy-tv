// SERIES COVERAGE — v1.0.17.
//
// Matt's phone on v1.0.16+188: series covers 7/18 visible categories.
// Two candidate causes read identically on the dialog:
//   (a) the panel sends rows for only 7 of the 18 categories, or
//   (b) the parse-drop wipes the other 11 categories entirely.
// The discriminator is `droppedRows`: (a) drops ~0, (b) drops ~all of the
// 11 categories' rows. These tests drive `writeIndexTypeInBackground`
// (the exact function the sync uses) with both shapes. Moved in from the
// research probe (`probe_series_coverage_test.dart`); the failing-first
// run on base f06949d89 was 2/3 pass, 1/3 fail for the product reason
// (C-C2: covered 7, 700 rows, 1,100 dropped — the phone's exact 7/18).
// Zero panel requests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_search_index.dart';

const _connId = 'conn-coverage-1';

String _catBody(int count) => jsonEncode([
      for (var i = 1; i <= count; i++)
        {'category_id': 'cat$i', 'category_name': 'Category $i'},
    ]);

/// Rows across [categoryCount] categories, [perCategory] rows each.
/// When [backdropCats] is non-empty, rows in those categories carry
/// `backdrop_path: []` (the documented panel shape) and dropped in parse
/// before v1.0.17; all other rows omit the field and parse cleanly.
String _seriesBody({
  required int categoryCount,
  required int perCategory,
  Set<int> backdropCats = const {},
}) {
  final rows = <Map<String, dynamic>>[];
  var id = 1000;
  for (var c = 1; c <= categoryCount; c++) {
    for (var i = 0; i < perCategory; i++) {
      id++;
      final row = <String, dynamic>{
        'series_id': id,
        'name': 'Show $c-$i',
        'cover': 'http://example.com/cover.jpg',
        'category_id': 'cat$c',
      };
      if (backdropCats.contains(c)) row['backdrop_path'] = <dynamic>[];
      rows.add(row);
    }
  }
  return jsonEncode(rows);
}

void main() {
  late Directory tempDir;
  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('plezy_series_cov_');
  });
  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } on FileSystemException {
      // WAL checkpoint can hold the file briefly; best-effort cleanup.
    }
  });

  Future<IndexWriteResult> write(String catalogBody, {int categories = 18}) {
    return writeIndexTypeInBackground(
      IndexWriteParams(
        dbPath: '${tempDir.path}/index.db',
        connectionId: _connId,
        type: IptvSearchIndex.typeSeries,
        catalogBody: catalogBody,
        categoryBody: _catBody(categories),
        syncStampMs: 111,
      ),
    );
  }

  group('series coverage (v1.0.17)', () {
    test('C-C1 CONTROL: clean complete list covers all 18', () async {
      final result = await write(_seriesBody(categoryCount: 18, perCategory: 100));
      expect(result.coveredCategories, 18);
      expect(result.totalCategories, 18);
      expect(result.rowCount, 1800);
      expect(result.droppedRows, 0);
      expect(result.partial, isFalse);
      expect(result.skippedReason, isNull);
    });

    test('C-C2: backdrop arrays in 11 of 18 categories no longer wipe them', () async {
      // Phone shape: 18 visible categories, rows in 11 of them carry
      // backdrop_path arrays. Before v1.0.17 this landed covered 7, 700
      // rows, 1,100 dropped — the phone's exact 7/18. The tolerant parse
      // lands all 1,800 with 0 dropped.
      final result = await write(
        _seriesBody(
          categoryCount: 18,
          perCategory: 100,
          backdropCats: {8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18},
        ),
      );
      expect(result.coveredCategories, 18);
      expect(result.totalCategories, 18);
      expect(result.rowCount, 1800);
      expect(result.droppedRows, 0);
      expect(result.partial, isFalse);
    });

    test('C-C3 CONTROL: genuinely partial list also reads 7/18', () async {
      // Same covered count as C-C2-on-base, but dropped == 0: the
      // discriminator. A partial list is a panel-shape problem; a
      // dropped list is a parser problem.
      final result = await write(_seriesBody(categoryCount: 7, perCategory: 100));
      expect(result.coveredCategories, 7);
      expect(result.totalCategories, 18);
      expect(result.rowCount, 700);
      expect(result.droppedRows, 0);
      expect(result.partial, isTrue);
    });
  });
}
