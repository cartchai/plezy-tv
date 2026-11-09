// TESTER-OWN — build #17 §3 denylist vs the parent's probe-B real panel
// names (2026-11-08): 194 live / 10 series / 40 VOD categories end in a
// bare content word. Verifies first-region-wins + denylist against those
// exact shapes. Not part of the build; tester verification only.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/iptv_initials.dart';

void main() {
  group('tester probe-B: real panel names', () {
    test('region wins over trailing content words (live)', () {
      expect(categoryInitial('UK| NEWS'), 'UK');
      expect(categoryInitial('UK| KIDS'), 'UK');
      expect(categoryInitial('UK| MUSIC'), 'UK');
      expect(categoryInitial('UK| MOVIES'), 'UK');
      expect(categoryInitial('UK| SPORTS'), 'UK');
      expect(categoryInitial('UK| DAZN PPV'), 'UK');
      expect(categoryInitial('UK| EPL PREMIER LEAGUE+ PPV'), 'UK');
      expect(categoryInitial('UK| UFC/BOXING PPV'), 'UK');
      expect(categoryInitial('UK| PAY PER VIEW PPV'), 'UK');
      expect(categoryInitial('UK| APPLE TV F1 PPV'), 'UK');
      expect(categoryInitial('UK| MAX PPV'), 'UK');
    });

    test('region wins over trailing content words (series/VOD)', () {
      expect(categoryInitial('|ES| HBO'), 'ES');
      expect(categoryInitial('|EXYU| HBO'), 'EXYU');
      expect(categoryInitial('|NL| DISNEY+ KIDS'), 'NL');
      expect(categoryInitial('|RU| RUSSIA KIDS'), 'RU');
      expect(categoryInitial('|EN| 4K MOVIES'), 'EN');
      expect(categoryInitial('|EN| CHRISTMAS MOVIES'), 'EN');
      expect(categoryInitial('|ES| SPORTS'), 'ES');
    });

    test('names with no region prefix carry no initial (always shown)', () {
      expect(categoryInitial('NETFLIX KIDS'), isNull);
      expect(categoryInitial('NETFLIX MOVIES'), isNull);
      expect(categoryInitial('WORLD LIVE SPORTS'), isNull);
      expect(categoryInitial('TOP IMDB/OSCAR MOVIES'), isNull);
      expect(categoryInitial('|MULTI| NETFLIX KIDS'), isNull);
    });

    test('a leading content word is skipped, the region still wins', () {
      expect(categoryInitial('LIVE TV | EN | NEWS'), 'EN');
      expect(categoryInitial('NEWS | EN'), 'EN');
      expect(categoryInitial('TV | EN'), 'EN');
    });

    test('denylisted words are never offered as toggles', () {
      final offered = initialsMeetingThreshold({
        'EN': 50,
        'NEWS': 40,
        'KIDS': 30,
        'PPV': 25,
        'HBO': 20,
        'LIVE': 15,
        'XXX': 10,
        'UK': 60,
      });
      final names = offered.map((i) => i.initial).toList();
      expect(names, containsAll(['EN', 'UK']));
      expect(names, isNot(contains('NEWS')));
      expect(names, isNot(contains('KIDS')));
      expect(names, isNot(contains('PPV')));
      expect(names, isNot(contains('HBO')));
      expect(names, isNot(contains('LIVE')));
      expect(names, isNot(contains('XXX')));
    });
  });
}
