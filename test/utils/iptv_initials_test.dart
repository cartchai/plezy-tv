import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/iptv_initials.dart';

void main() {
  group('detectInitial (build #8 Task 4)', () {
    test('detects the prefix before a separator', () {
      expect(detectInitial('EN - Title'), 'EN');
      expect(detectInitial('ES | Channel'), 'ES');
      expect(detectInitial('UK|Channel'), 'UK');
      expect(detectInitial('NF - Alice'), 'NF');
      expect(detectInitial('IT: Show'), 'IT');
      expect(detectInitial('FR / Film'), 'FR');
      expect(detectInitial('USA - News'), 'USA');
    });

    test('a bare space is not a separator', () {
      // "IT Crowd" is a title, not an initial — it must never be offered.
      expect(detectInitial('IT Crowd'), isNull);
      expect(detectInitial('ABBA Gold'), isNull);
      expect(detectInitial('The Last of Us'), isNull);
    });

    test('names without an initial return null', () {
      expect(detectInitial('Alice'), isNull);
      expect(detectInitial('NF'), isNull);
      expect(detectInitial(''), isNull);
      expect(detectInitial(null), isNull);
      expect(detectInitial('eN - Title'), isNull);
      expect(detectInitial('ENGLISH - Title'), isNull);
    });

    test('initialOf also reads a name that IS just an initial', () {
      // A category named "NF" is the NF grouping — no separator needed.
      expect(initialOf('NF'), 'NF');
      expect(initialOf('EN - Title'), 'EN');
      expect(initialOf('Action'), isNull);
      expect(initialOf('IT Crowd'), isNull);
    });
  });

  group('initialsMeetingThreshold (build #8 Task 4)', () {
    test('only initials that keep repeating are offered', () {
      final counts = countInitials([
        for (var i = 0; i < 6; i++) 'EN - Movie $i',
        for (var i = 0; i < 5; i++) 'ES - Show $i',
        for (var i = 0; i < 4; i++) 'IT - Film $i',
        'NF - One Off',
        'Alice',
      ]);
      final offered = initialsMeetingThreshold(counts);
      // EN (6) and ES (5) meet the threshold of 5; IT (4) and the NF
      // one-off (1) never appear as toggles.
      expect(offered.map((i) => (i.initial, i.count)), [('EN', 6), ('ES', 5)]);
    });

    test('every initial-set is toggleable, including provider tags like NF', () {
      final counts = countInitials([for (var i = 0; i < 7; i++) 'NF - Show $i']);
      final offered = initialsMeetingThreshold(counts);
      expect(offered.map((i) => i.initial), ['NF']);
    });

    test('most-common first, ties by initial', () {
      final counts = countInitials([
        for (var i = 0; i < 5; i++) 'US - Item $i',
        for (var i = 0; i < 9; i++) 'EN - Item $i',
        for (var i = 0; i < 5; i++) 'ES - Item $i',
      ]);
      expect(
        initialsMeetingThreshold(counts).map((i) => i.initial),
        ['EN', 'ES', 'US'],
      );
    });
  });
}
