import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/iptv_initials.dart';

void main() {
  group('categoryInitial (build #10 redesign: from the category name)', () {
    test('derives the initial from the category prefix', () {
      expect(categoryInitial('|EN| UK SERIES'), 'EN');
      expect(categoryInitial('|EN|UK MOVIES'), 'EN');
      expect(categoryInitial('EN - Movies'), 'EN');
      expect(categoryInitial('ES | Channels'), 'ES');
      expect(categoryInitial('UK|Channels'), 'UK');
      expect(categoryInitial('NF - Alice'), 'NF');
      expect(categoryInitial('IT: Shows'), 'IT');
      expect(categoryInitial('FR / Films'), 'FR');
      expect(categoryInitial('USA - News'), 'USA');
      expect(categoryInitial('ASIA: Shows'), 'ASIA');
      expect(categoryInitial('AR - Channels'), 'AR');
    });

    test('leading token before the first space, when it is a short tag', () {
      expect(categoryInitial('24/7 ACTION & ADVENTURE VIP'), '24/7');
      expect(categoryInitial('24/7'), '24/7');
    });

    test('a category that IS just an initial carries it', () {
      expect(categoryInitial('NF'), 'NF');
      expect(categoryInitial('ASIA'), 'ASIA');
    });

    test('a bare space is not a separator', () {
      // "UK Series" is a category name, not an initial — it must never be
      // offered, and neither is a plain category name.
      expect(categoryInitial('UK Series'), isNull);
      expect(categoryInitial('IT Crowd'), isNull);
      expect(categoryInitial('ABBA Gold'), isNull);
      expect(categoryInitial('Action'), isNull);
    });

    test('names without an initial return null', () {
      expect(categoryInitial('Alice'), isNull);
      expect(categoryInitial(''), isNull);
      expect(categoryInitial(null), isNull);
      expect(categoryInitial('eN - Title'), isNull);
      expect(categoryInitial('ENGLISH - Title'), isNull);
      expect(categoryInitial('   '), isNull);
      expect(categoryInitial('|'), isNull);
    });
  });

  group('initialsMeetingThreshold (build #8 Task 4)', () {
    test('only initials that keep repeating across categories are offered', () {
      final counts = countCategoryInitials([
        for (var i = 0; i < 6; i++) 'EN - Category $i',
        for (var i = 0; i < 5; i++) 'ES - Category $i',
        for (var i = 0; i < 4; i++) 'IT - Category $i',
        'NF - One Off',
        'Action',
      ]);
      final offered = initialsMeetingThreshold(counts);
      // EN (6) and ES (5) meet the threshold of 5; IT (4) and the NF
      // one-off (1) never appear as toggles.
      expect(offered.map((i) => (i.initial, i.count)), [('EN', 6), ('ES', 5)]);
    });

    test('every initial-set is toggleable, including provider tags like NF', () {
      final counts = countCategoryInitials([for (var i = 0; i < 7; i++) 'NF - Category $i']);
      final offered = initialsMeetingThreshold(counts);
      expect(offered.map((i) => i.initial), ['NF']);
    });

    test('counts are per category, not per item', () {
      // Six categories carry EN, however many items sit inside them.
      final counts = countCategoryInitials([
        '|EN| UK SERIES',
        '|EN| UK MOVIES',
        'EN - Drama',
        'EN - Comedy',
        'EN - News',
        'EN - Sports',
        'FR - Films',
      ]);
      expect(counts, {'EN': 6, 'FR': 1});
      expect(initialsMeetingThreshold(counts).map((i) => i.initial), ['EN']);
    });

    test('most-common first, ties by initial', () {
      final counts = countCategoryInitials([
        for (var i = 0; i < 5; i++) 'US - Category $i',
        for (var i = 0; i < 9; i++) 'EN - Category $i',
        for (var i = 0; i < 5; i++) 'ES - Category $i',
      ]);
      expect(
        initialsMeetingThreshold(counts).map((i) => i.initial),
        ['EN', 'ES', 'US'],
      );
    });
  });
}
