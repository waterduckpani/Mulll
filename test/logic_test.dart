import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mull/core/cycle.dart';
import 'package:mull/core/link_reader.dart';
import 'package:mull/core/money.dart';
import 'package:mull/core/screenshot_reader.dart';
import 'package:mull/data/models.dart';
import 'package:mull/data/store.dart';

void main() {
  group('inr', () {
    test('uses Indian grouping', () {
      expect(inr(0), '₹0');
      expect(inr(650), '₹650');
      expect(inr(2400), '₹2,400');
      expect(inr(24600), '₹24,600');
      expect(inr(124600), '₹1,24,600');
      expect(inr(10000000), '₹1,00,00,000');
      expect(inr(-5300), '−₹5,300');
    });
  });

  group('parseAmount', () {
    test('accepts the formats promised in the UI', () {
      for (final s in ['28000', '28k', '28,000', '₹28k', '₹28,000', ' 28 K ', 'Rs. 28,000/-']) {
        expect(parseAmount(s), 28000, reason: s);
      }
      expect(parseAmount('1.2L'), 120000);
      expect(parseAmount('2 lakh'), 200000);
      expect(parseAmount('2.5k'), 2500);
    });

    test('rejects junk', () {
      for (final s in ['', 'abc', '0', '12kk', '-5']) {
        expect(parseAmount(s), isNull, reason: s);
      }
    });
  });

  group('Cycle', () {
    test('month starting on the 1st', () {
      final c = Cycle.of(DateTime(2026, 9, 19), 1);
      expect(c.start, DateTime(2026, 9, 1));
      expect(c.end, DateTime(2026, 10, 1));
      expect(c.daysLeft(DateTime(2026, 9, 19, 15)), 12);
      expect(c.label, 'September');
    });

    test('payday cycle straddles months and years', () {
      final c = Cycle.of(DateTime(2027, 1, 3), 25);
      expect(c.start, DateTime(2026, 12, 25));
      expect(c.end, DateTime(2027, 1, 25));
      expect(c.label, 'January');
    });
  });

  group('store', () {
    MullStore make() {
      final s = MullStore.memory()..clock = () => DateTime(2026, 9, 19, 10);
      s.completeOnboarding(name: 'Ananya', budget: 40000);
      return s;
    }

    test('sample data reproduces the mockup numbers', () {
      final s = make()..loadSample();
      expect(s.spent, 6200);
      expect(s.needsTotal, 9200);
      expect(s.free, 24600);
      final wants = s.reach(ItemKind.want);
      expect(wants.inReach.map((i) => i.name), ['Mechanical keyboard', 'Filter coffee kit', 'Linen shirt']);
      expect(wants.outOfReach.first.$1.name, 'Headphones');
      expect(wants.outOfReach.first.$2, 18150 + 24990 - 24600);
      expect(s.pendingInReach.single.name, 'Mechanical keyboard');
    });

    test('needs are reserved before wants', () {
      final s = make();
      s.addItem(name: 'Rent top-up', price: 30000, kind: ItemKind.need);
      final want = s.addItem(name: 'Shoes', price: 12000, kind: ItemKind.want);
      expect(s.free, 10000);
      expect(s.reach(ItemKind.want).outOfReach.single.$1.id, want.id);
      expect(want.outOfReachSince, isNotNull);
    });

    test('short stints below the line do not trigger an in-reach moment', () {
      final s = make();
      final want = s.addItem(name: 'Desk', price: 50000, kind: ItemKind.want);
      expect(want.outOfReachSince, isNotNull);
      s.setBudget(60000);
      expect(s.pendingInReach, isEmpty);
      expect(want.outOfReachSince, isNull);
    });

    test('a long wait crossing the line is celebrated once', () {
      var now = DateTime(2026, 9, 1);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'A', budget: 10000);
      final want = s.addItem(name: 'Keyboard', price: 12900, kind: ItemKind.want);
      now = DateTime(2026, 10, 2);
      s.setBudget(20000);
      expect(s.pendingInReach.single.id, want.id);
      s.keepWaiting(want);
      expect(s.pendingInReach, isEmpty);
    });

    test('buying moves money from wishlist to spent, and undo restores it', () {
      final s = make();
      final item = s.addItem(name: 'Charger', price: 2400, kind: ItemKind.need);
      final spend = s.buyItem(item);
      expect(s.items, isEmpty);
      expect(s.spent, 2400);
      s.removeSpend(spend);
      expect(s.items.single.name, 'Charger');
      expect(s.spent, 0);
    });

    test('needs are re-checked each new cycle', () {
      var now = DateTime(2026, 9, 10);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'A', budget: 10000);
      final need = s.addItem(name: 'Charger', price: 2400, kind: ItemKind.need);
      expect(s.needsToRecheck, [need]);
      s.confirmNeed(need);
      expect(s.needsToRecheck, isEmpty);
      now = DateTime(2026, 10, 2);
      expect(s.needsToRecheck, [need]);
    });

    test('budget override applies to one cycle only', () {
      var now = DateTime(2026, 9, 10);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'A', budget: 10000);
      s.setBudget(15000, justThisCycle: true);
      expect(s.budget, 15000);
      now = DateTime(2026, 10, 2);
      expect(s.budget, 10000);
    });

    test('JSON round trip', () {
      final s = make()..loadSample();
      final json = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
      expect(json['items'], hasLength(7));
      expect(Group.fromJson((json['groups'] as List).first as Map<String, dynamic>).declared, 18000);
      expect(NamedList.fromJson((json['lists'] as List).first as Map<String, dynamic>).reachBreak, 6);
    });
  });

  group('groups', () {
    test('declared, undeclared and initials', () {
      final g = Group(
        name: 'Goa flights',
        target: 24000,
        members: [
          Member(name: 'Ananya', isYou: true, amount: 6000, status: Pledge.settled),
          Member(name: 'Sahil Mehta', amount: 6000, status: Pledge.declared),
          Member(name: 'Divya'),
        ],
      );
      expect(g.declared, 12000);
      expect(g.undeclared, 12000);
      expect(g.yetToSay.single.name, 'Divya');
      expect(g.members[1].initials, 'SM');
      expect(g.members[2].initials, 'DI');
    });
  });

  group('LinkReader', () {
    test('tidies store titles', () {
      expect(
        LinkReader.tidyTitle('Anker 65W USB-C Charger, Nano II GaN : Amazon.in: Electronics'),
        'Anker 65W USB-C Charger',
      );
      expect(
        LinkReader.tidyTitle('Buy Keychron K2 Wireless Mechanical Keyboard Online at Best Price'),
        'Keychron K2 Wireless Mechanical Keyboard',
      );
      expect(LinkReader.tidyTitle('Linen Shirt | Nicobar'), 'Linen Shirt');
    });

    test('extracts urls from share text', () {
      expect(LinkReader.extractUrl('Check this out https://amzn.in/d/abc123 via app'), 'https://amzn.in/d/abc123');
      expect(LinkReader.domainOf('https://www.decathlon.in/p/123'), 'decathlon.in');
    });
  });

  group('ScreenshotReader', () {
    OcrLine at(String text, double y, double h) => OcrLine(text, y: y, h: h);

    test('reads a Zara product page — the kind we cannot scrape', () {
      final read = ScreenshotReader.parse([
        at('9:41', .012, .013),
        at('zara.com', .048, .014),
        at('ZARA', .09, .022),
        at('SATIN EFFECT SHIRT', .615, .021),
        at('₹ 3,950', .655, .019),
        at('MRP incl. of all taxes', .685, .011),
        at('ADD TO BASKET', .905, .018),
      ]);
      expect(read.name, 'SATIN EFFECT SHIRT');
      expect(read.price, 3950);
      expect(read.domain, 'zara.com');
      expect(read.isEmpty, isFalse);
    });

    test('takes the selling price over the struck-out MRP', () {
      final read = ScreenshotReader.parse([
        at('amazon.in', .04, .012),
        at('Anker 65W USB-C Charger, Nano III', .50, .020),
        at('4.5 out of 5 stars  1,203 ratings', .55, .012),
        at('₹2,999', .60, .026),
        at('M.R.P.: ₹4,999', .64, .014),
        at('Save ₹2,000 (40%)', .67, .013),
        at('FREE delivery Thursday, 18 September', .72, .013),
        at('Add to Cart', .82, .018),
      ]);
      expect(read.name, 'Anker 65W USB-C Charger');
      expect(read.price, 2999);
      expect(read.domain, 'amazon.in');
    });

    test('picks the lower price when both are set in the same size', () {
      for (final order in [
        ['₹ 2,290', '₹ 4,590'],
        ['₹ 4,590', '₹ 2,290'],
      ]) {
        final read = ScreenshotReader.parse([
          at('SILK BLEND DRESS', .50, .022),
          at(order[0], .56, .020),
          at(order[1], .56, .020),
        ]);
        expect(read.price, 2290, reason: order.join(' then '));
      }
    });

    test('is not fooled by ratings, discounts or the clock', () {
      final read = ScreenshotReader.parse([
        at('9:41', .012, .013),
        at('100%', .012, .013),
        at('4.3 ★ 2,145 ratings', .40, .030),
        at('40% off', .45, .030),
        at('Cotton Oversized Tee', .52, .020),
        at('₹1,299', .57, .022),
      ]);
      expect(read.price, 1299);
      expect(read.name, 'Cotton Oversized Tee');
    });

    test('reads a Massimo Dutti page: fibre percentages are names, not badges', () {
      // The real failure this came from: "%" was blanket junk, so the actual
      // name was discarded and "VIEW LOOK" won by being the only line left.
      final read = ScreenshotReader.parse([
        at('7:07', .012, .013),
        at('Massimo Dutti', .128, .020),
        at('VIEW LOOK', .742, .012),
        at('100% WOOL REGULAR FIT CHECK SHIRT', .770, .014),
        at('13,900.00INR', .803, .015),
        at('MRP incl. of all taxes', .833, .012),
        at('ADD TO BASKET', .884, .014),
        at('massimodutti.com', .962, .014),
      ]);
      expect(read.name, '100% WOOL REGULAR FIT CHECK SHIRT');
      expect(read.price, 13900);
      // Safari's address bar sits at the bottom by default since iOS 15.
      expect(read.domain, 'massimodutti.com');
    });

    test('ignores a domain in the middle of the page', () {
      // A footer link or a watermark is not the store you are shopping at.
      final read = ScreenshotReader.parse([
        at('LINEN SHIRT', .40, .022),
        at('₹2,490', .46, .020),
        at('also available at brandstore.com', .60, .012),
      ]);
      expect(read.domain, isNull);
    });

    test('reads a price with the currency trailing the number', () {
      final read = ScreenshotReader.parse([
        at('LINEN BLEND SHIRT', .50, .022),
        at('4,990.00INR', .56, .020),
      ]);
      expect(read.price, 4990);
    });

    test('a fibre percentage is never mistaken for the price', () {
      final read = ScreenshotReader.parse([
        at('100% COTTON SHIRT', .50, .030),
        at('₹1,499', .56, .020),
      ]);
      expect(read.price, 1499, reason: 'the 100 in "100% COTTON" is not a price');
      expect(read.name, '100% COTTON SHIRT');
    });

    test('admits when there is nothing to read', () {
      expect(ScreenshotReader.parse(const []).isEmpty, isTrue);
      expect(ScreenshotReader.parse([at('Wi-Fi', .3, .02)]).price, isNull);
    });
  });
}
