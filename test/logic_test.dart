import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mull/core/cycle.dart';
import 'package:mull/core/link_reader.dart';
import 'package:mull/core/money.dart';
import 'package:mull/core/screenshot_reader.dart';
import 'package:mull/core/split.dart';
import 'package:mull/core/upi.dart';
import 'package:mull/core/upi_receipt.dart';
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
      expect(s.room, 33800);
      expect(s.leftForWants, 24600);
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
      expect(s.leftForWants, 10000);
      expect(s.reach(ItemKind.want).outOfReach.single.$1.id, want.id);
      expect(want.outOfReachSince, isNotNull);
    });

    test('adding to the wishlist never moves the ruler', () {
      final s = make();
      expect(s.room, 40000);
      s.addItem(name: 'Desk', price: 37800, kind: ItemKind.want);
      s.addItem(name: 'Headphones', price: 24990, kind: ItemKind.want);
      // Wanting things costs nothing — only buying does.
      expect(s.room, 40000);
      expect(s.spent, 0);
    });

    test('needs cannot reserve money that is not there', () {
      final s = make();
      s.addItem(name: 'Laptop', price: 60000, kind: ItemKind.need);
      expect(s.leftForWants, -20000, reason: 'the shortfall is real and worth saying out loud');
      expect(s.needsReserved, 40000, reason: 'but only the budget can actually be set aside');
      expect(s.reach(ItemKind.want).pool, -20000);
    });

    test('time to reach counts the queue ahead, not just the price', () {
      final s = make();
      s.addItem(name: 'Charger', price: 10000, kind: ItemKind.need);
      // 30,000 a month for wants once the need is set aside.
      final first = s.addItem(name: 'Keyboard', price: 12900, kind: ItemKind.want);
      final second = s.addItem(name: 'Desk', price: 37800, kind: ItemKind.want);
      expect(s.monthlyWantRoom, 30000);
      expect(s.monthsToReach(first), 1);
      // 12,900 + 37,800 = 50,700 → two months at 30,000.
      expect(s.monthsToReach(second), 2);
      expect(s.reachDate(second), DateTime(2026, 11, 1));
    });

    test('no month estimate when needs already outgrow the budget', () {
      final s = make();
      s.addItem(name: 'Laptop', price: 60000, kind: ItemKind.need);
      final want = s.addItem(name: 'Desk', price: 37800, kind: ItemKind.want);
      expect(s.monthsToReach(want), isNull);
      expect(s.reachDate(want), isNull);
    });

    test('buying within the line pushes nothing else out', () {
      // Two wants being in reach together already means the budget covers
      // both, so buying one can never cost the other its place. Spending what
      // you planned to spend is not an event.
      final s = make();
      final desk = s.addItem(name: 'Desk', price: 30000, kind: ItemKind.want);
      final kit = s.addItem(name: 'Coffee kit', price: 9000, kind: ItemKind.want);
      expect(s.reach(ItemKind.want).inReach.map((i) => i.name), ['Desk', 'Coffee kit']);
      expect(s.overBudgetBy(desk), 0);
      s.buyItem(desk);
      expect(s.reach(ItemKind.want).inReach.single.id, kit.id);
    });

    test('buying past the line is the only thing worth a warning', () {
      final s = make();
      final desk = s.addItem(name: 'Desk', price: 52000, kind: ItemKind.want);
      expect(s.overBudgetBy(desk), 12000);
      s.logSpend('Groceries', 5000);
      expect(s.overBudgetBy(desk), 17000, reason: 'the line moves as the month is spent');
    });

    test('buying a need leaves the wants pool exactly where it was', () {
      final s = make();
      final need = s.addItem(name: 'Charger', price: 10000, kind: ItemKind.need);
      s.addItem(name: 'Desk', price: 30000, kind: ItemKind.want);
      final before = s.leftForWants;
      s.buyItem(need);
      expect(s.leftForWants, before, reason: 'realising a reservation changes no one else’s place');
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
      expect(Group.fromJson((json['groups'] as List).first as Map<String, dynamic>).total, 47400);
      expect(NamedList.fromJson((json['lists'] as List).first as Map<String, dynamic>).reachBreak, 6);
    });
  });

  group('splitting', () {
    test('an even split still adds up to the bill', () {
      expect(splitEqually(100, ['a', 'b', 'c']), {'a': 34, 'b': 33, 'c': 33});
      expect(splitEqually(900, ['a', 'b', 'c']), {'a': 300, 'b': 300, 'c': 300});
      expect(splitEqually(1, ['a', 'b']), {'a': 1, 'b': 0});
      expect(splitEqually(500, []), isEmpty);
      for (final n in [1, 2, 3, 4, 5, 6, 7, 11, 13]) {
        final ids = [for (var i = 0; i < n; i++) 'p$i'];
        final split = splitEqually(9999, ids);
        expect(split.values.fold(0, (s, v) => s + v), 9999, reason: 'across $n people');
      }
    });

    test('shares and percentages give the odd rupee to whoever was rounded down hardest', () {
      // 100 across 1:1:1 is the classic case — someone has to get the extra.
      final byShares = splitByWeight(100, {'a': 1, 'b': 1, 'c': 1});
      expect(byShares.values.fold(0, (s, v) => s + v), 100);
      expect(byShares.values.toList()..sort(), [33, 33, 34]);

      // Dev eats two portions.
      expect(splitByWeight(1200, {'a': 1, 'b': 2, 'c': 1}), {'a': 300, 'b': 600, 'c': 300});
      expect(splitByWeight(1000, {'a': 30, 'b': 70}), {'a': 300, 'b': 700});
      // Weightless input is still a split, not a crash.
      expect(splitByWeight(90, {'a': 0, 'b': 0}), {'a': 45, 'b': 45});
    });

    test('simplify clears the group in at most one payment per person', () {
      // Three people, one paid for everything.
      final transfers = simplify({'you': 200, 'b': -100, 'c': -100});
      expect(transfers, hasLength(2));
      expect(transfers.every((t) => t.to == 'you'), isTrue);
      expect(transfers.fold(0, (s, t) => s + t.amount), 200);
    });

    test('simplify nets a chain into a single payment', () {
      // A owes B, B owes C the same — so A should just pay C, and B drops out.
      final transfers = simplify({'a': -500, 'b': 0, 'c': 500});
      expect(transfers, hasLength(1));
      expect(transfers.single.from, 'a');
      expect(transfers.single.to, 'c');
      expect(transfers.single.amount, 500);
    });

    test('nothing to simplify when everyone is square', () {
      expect(simplify({'a': 0, 'b': 0}), isEmpty);
      expect(simplify(const {}), isEmpty);
    });
  });

  group('group ledger', () {
    Group make3() => Group(
      name: 'Goa',
      members: [Member(id: 'you', name: 'Ananya', isYou: true), Member(id: 'b', name: 'Sahil'), Member(id: 'c', name: 'Divya')],
    );

    test('paying for the group puts you in credit', () {
      final g = make3();
      g.expenses.add(
        Expense(
          description: 'Flights',
          amount: 3000,
          payerId: 'you',
          shares: splitEqually(3000, ['you', 'b', 'c']),
        ),
      );
      expect(g.balances, {'you': 2000, 'b': -1000, 'c': -1000});
      expect(g.yourBalance, 2000);
      expect(g.isSettled, isFalse);
    });

    test('balances always sum to zero, whoever paid and however it split', () {
      final g = make3();
      g.expenses.addAll([
        Expense(description: 'A', amount: 1000, payerId: 'you', shares: splitEqually(1000, ['you', 'b', 'c'])),
        Expense(description: 'B', amount: 777, payerId: 'b', shares: splitEqually(777, ['you', 'b'])),
        Expense(description: 'C', amount: 250, payerId: 'c', shares: splitByWeight(250, {'you': 1, 'c': 3})),
      ]);
      g.settlements.add(Settlement(fromId: 'c', toId: 'you', amount: 120));
      expect(g.balances.values.fold(0, (s, v) => s + v), 0);
    });

    test('an expense you had no share of still leaves you owing nothing for it', () {
      final g = make3();
      // Divya skipped dinner.
      g.expenses.add(
        Expense(description: 'Dinner', amount: 900, payerId: 'you', shares: splitEqually(900, ['you', 'b'])),
      );
      expect(g.balances['c'], 0);
      expect(g.balances['b'], -450);
      expect(g.balances['you'], 450);
    });

    test('settling up moves people back towards square', () {
      final g = make3();
      g.expenses.add(
        Expense(description: 'Flights', amount: 3000, payerId: 'you', shares: splitEqually(3000, ['you', 'b', 'c'])),
      );
      Settlement paid(String from) =>
          Settlement(fromId: from, toId: 'you', amount: 1000, status: SettlementStatus.confirmed);
      g.settlements.add(paid('b'));
      expect(g.balances['b'], 0);
      expect(g.yourBalance, 1000);
      g.settlements.add(paid('c'));
      expect(g.isSettled, isTrue);
      expect(simplify(g.balances), isEmpty);
    });

    test('an unconfirmed claim does not clear the debt', () {
      final g = make3();
      g.expenses.add(
        Expense(description: 'Flights', amount: 3000, payerId: 'you', shares: splitEqually(3000, ['you', 'b', 'c'])),
      );
      final claim = Settlement(fromId: 'b', toId: 'you', amount: 1000);
      g.settlements.add(claim);
      // He says he sent it. Until you say it landed, he still owes it.
      expect(g.balances['b'], -1000);
      expect(g.awaitingYourConfirmation.single.id, claim.id);

      claim.status = SettlementStatus.confirmed;
      expect(g.balances['b'], 0);
      expect(g.awaitingYourConfirmation, isEmpty);
    });

    test('a disputed claim leaves the debt standing and stays on the record', () {
      final g = make3();
      g.expenses.add(
        Expense(description: 'Flights', amount: 3000, payerId: 'you', shares: splitEqually(3000, ['you', 'b', 'c'])),
      );
      g.settlements.add(Settlement(fromId: 'b', toId: 'you', amount: 1000, status: SettlementStatus.disputed));
      expect(g.balances['b'], -1000);
      expect(g.settlements, hasLength(1), reason: 'the disagreement stays visible');
      expect(g.awaitingYourConfirmation, isEmpty, reason: 'already answered');
    });

    test('someone removed from the group keeps their place in old expenses', () {
      final g = make3();
      g.expenses.add(
        Expense(description: 'Cab', amount: 600, payerId: 'c', shares: splitEqually(600, ['you', 'b', 'c'])),
      );
      g.members.removeWhere((m) => m.id == 'c');
      // Their balance is still real — dropping it would lose ₹400 of history.
      expect(g.balances['c'], 400);
      expect(g.balances.values.fold(0, (s, v) => s + v), 0);
    });

    test('initials', () {
      expect(Member(name: 'Sahil Mehta').initials, 'SM');
      expect(Member(name: 'Divya').initials, 'DI');
    });
  });

  group('store groups', () {
    MullStore withGroup() {
      final s = MullStore.memory()..clock = () => DateTime(2026, 9, 19, 10);
      s.completeOnboarding(name: 'Ananya', budget: 40000);
      s.addGroup('Goa', ['Sahil', 'Divya']);
      return s;
    }

    test('a new group puts you in it and carries your UPI ID over', () {
      final s = MullStore.memory();
      s.updateProfile((p) => p.upiId = 'ananya@okhdfc');
      final g = s.addGroup('Flat', ['Dev']);
      expect(g.members, hasLength(2));
      expect(g.you?.isYou, isTrue);
      expect(g.you?.upiId, 'ananya@okhdfc');
    });

    test('people the ledger depends on cannot be removed', () {
      final s = withGroup();
      final g = s.groups.single;
      final sahil = g.members.firstWhere((m) => m.name == 'Sahil');
      final divya = g.members.firstWhere((m) => m.name == 'Divya');

      expect(s.canRemoveMember(g, divya), isTrue, reason: 'nothing references her yet');
      s.addExpense(
        g,
        description: 'Cab',
        amount: 600,
        payerId: sahil.id,
        shares: splitEqually(600, [g.you!.id, sahil.id]),
      );
      expect(s.removeMember(g, sahil), isFalse, reason: 'he paid for it');
      expect(s.removeMember(g, g.you!), isFalse, reason: 'you are always in your own group');
      expect(s.removeMember(g, divya), isTrue);
      expect(g.members, hasLength(2));
    });

    test('your UPI ID follows you from the group back to your profile', () {
      final s = withGroup();
      final g = s.groups.single;
      s.setUpiId(g.you!, ' ananya@okhdfc ');
      expect(g.you!.upiId, 'ananya@okhdfc', reason: 'trimmed');
      expect(s.profile.upiId, 'ananya@okhdfc');
      s.setUpiId(g.you!, '');
      expect(g.you!.upiId, isNull);
    });

    test('the WhatsApp summary says who pays whom, and how to pay you', () {
      final s = withGroup();
      final g = s.groups.single;
      s.setUpiId(g.you!, 'ananya@okhdfc');
      s.addExpense(
        g,
        description: 'Flights',
        amount: 3000,
        payerId: g.you!.id,
        shares: splitEqually(3000, g.members.map((m) => m.id).toList()),
      );

      final summary = s.groupSummary(g);
      expect(summary, contains('Goa'));
      expect(summary, contains('Sahil → You: ₹1,000'));
      expect(summary, contains('Pay me at ananya@okhdfc'));
      expect(summary, contains('Total spent: ₹3,000'));
    });

    test('a settled group says so instead of listing payments', () {
      final s = withGroup();
      expect(s.groupSummary(s.groups.single), contains('All settled up'));
    });

    test('recording money you received settles it outright', () {
      final s = withGroup();
      final g = s.groups.single;
      final sahil = g.members.firstWhere((m) => m.name == 'Sahil')..userId = 'u-sahil';
      final settlement = s.settleUp(g, fromId: sahil.id, toId: g.you!.id, amount: 500);
      // You are the one owed, so you saying it arrived is the confirmation.
      expect(settlement.status, SettlementStatus.confirmed);
    });

    test('recording money you sent waits on the other person', () {
      final s = withGroup();
      final g = s.groups.single;
      final sahil = g.members.firstWhere((m) => m.name == 'Sahil')..userId = 'u-sahil';
      final settlement = s.settleUp(g, fromId: g.you!.id, toId: sahil.id, amount: 500, utr: '4471');
      expect(settlement.status, SettlementStatus.pending);
      expect(settlement.utr, '4471');
      expect(g.balances[g.you!.id], 0, reason: 'a claim moves nothing yet');

      s.confirmSettlement(g, settlement);
      expect(settlement.status, SettlementStatus.confirmed);
      expect(settlement.confirmedAt, isNotNull);
    });

    test('paying a seat nobody has claimed settles immediately', () {
      // A placeholder cannot confirm anything, so waiting on one would leave
      // the debt hanging with no way to ever clear it.
      final s = withGroup();
      final g = s.groups.single;
      final divya = g.members.firstWhere((m) => m.name == 'Divya');
      expect(divya.isLinked, isFalse);
      expect(s.settleUp(g, fromId: g.you!.id, toId: divya.id, amount: 500).status, SettlementStatus.confirmed);
    });

    test('confirmations across every group land in one place', () {
      final s = withGroup();
      final g = s.groups.single;
      final sahil = g.members.firstWhere((m) => m.name == 'Sahil')..userId = 'u-sahil';
      s.settleUp(g, fromId: sahil.id, toId: g.you!.id, amount: 100);
      expect(s.confirmationsForYou, isEmpty, reason: 'you recorded it, so it is already confirmed');

      g.settlements.add(Settlement(fromId: sahil.id, toId: g.you!.id, amount: 200));
      expect(s.confirmationsForYou, hasLength(1));
      expect(s.confirmationsForYou.single.$2.amount, 200);
    });

    test('a repeating expense is offered once its month comes round', () {
      var now = DateTime(2026, 9, 19);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'Ananya', budget: 40000);
      s.addGroup('Flat', ['Ritu']);
      final g = s.groups.single;
      final rent = s.addExpense(
        g,
        description: 'Rent',
        amount: 75000,
        payerId: g.you!.id,
        shares: splitEqually(75000, g.members.map((m) => m.id).toList()),
        repeatsMonthly: true,
        date: DateTime(2026, 9, 1),
      );
      expect(s.dueRepeats(g), isEmpty, reason: 'on 19 September, next month has not come round yet');

      now = DateTime(2026, 10, 3);
      expect(s.dueRepeats(g), [rent]);

      final next = s.repeatExpense(g, rent);
      expect(next.date, DateTime(2026, 10, 1));
      expect(next.amount, 75000);
      expect(next.repeatsMonthly, isTrue);
      expect(s.dueRepeats(g), isEmpty, reason: 'already carried forward');
    });

    test('activity is newest first, expenses and settlements together', () {
      final s = withGroup();
      final g = s.groups.single;
      s.addExpense(
        g,
        description: 'Old',
        amount: 300,
        payerId: g.you!.id,
        shares: splitEqually(300, [g.you!.id]),
        date: DateTime(2026, 9, 1),
      );
      s.settleUp(g, fromId: g.members[1].id, toId: g.you!.id, amount: 100);
      final activity = s.activity(g);
      expect(activity.first, isA<Settlement>());
      expect(activity.last, isA<Expense>());
    });

    test('your position across every group at once', () {
      final s = withGroup();
      final g = s.groups.single;
      s.addExpense(
        g,
        description: 'Flights',
        amount: 3000,
        payerId: g.you!.id,
        shares: splitEqually(3000, g.members.map((m) => m.id).toList()),
      );
      expect(s.groupsNet, 2000);
    });
  });

  group('UPI receipts', () {
    OcrLine at(String text, double y, double h) => OcrLine(text, y: y, h: h);

    test('reads a Google Pay receipt', () {
      final r = UpiReceiptReader.parse([
        at('9:41', .012, .013),
        at('Completed', .18, .014),
        at('₹2,000', .26, .040),
        at('Paid to Sahil Mehta', .33, .016),
        at('sahil@okaxis', .37, .013),
        at('UPI transaction ID  447126558301', .62, .012),
      ]);
      expect(r.amount, 2000);
      expect(r.utr, '447126558301');
      expect(r.payeeUpiId, 'sahil@okaxis');
      expect(r.payeeName, 'Sahil Mehta');
      expect(r.failed, isFalse);
    });

    test('reads a PhonePe receipt, ignoring the account the money left', () {
      final r = UpiReceiptReader.parse([
        at('Payment Successful', .14, .018),
        at('₹1,240', .23, .044),
        at('Paid to KABIR VERMA', .31, .015),
        at('kabirv@ybl', .35, .012),
        at('Debited from  ananya@okhdfc', .48, .012),
        at('UTR: 528401234567', .55, .012),
      ]);
      expect(r.amount, 1240);
      expect(r.utr, '528401234567');
      expect(r.payeeUpiId, 'kabirv@ybl', reason: 'not the account it was debited from');
      expect(r.failed, isFalse);
    });

    test('picks the amount over other numbers by how big it is set', () {
      final r = UpiReceiptReader.parse([
        at('₹500', .24, .042), // the hero
        at('Balance ₹12,480', .70, .011),
        at('To ramesh@paytm', .34, .013),
        at('UPI Ref No 528401234567', .60, .012),
      ]);
      expect(r.amount, 500);
    });

    test('finds a bare reference when nothing labels it', () {
      final r = UpiReceiptReader.parse([
        at('₹300', .25, .040),
        at('to@okicici', .33, .013),
        at('447126558301', .61, .011),
      ]);
      expect(r.utr, '447126558301');
    });

    test('a phone number is not a reference', () {
      final r = UpiReceiptReader.parse([
        at('₹300', .25, .040),
        at('9876543210', .40, .012),
      ]);
      expect(r.utr, isNull);
    });

    test('says so when the payment did not go through', () {
      final r = UpiReceiptReader.parse([
        at('Payment Failed', .14, .018),
        at('₹1,240', .23, .044),
        at('kabirv@ybl', .35, .012),
      ]);
      expect(r.failed, isTrue);
    });

    test('admits when a screenshot is not a receipt at all', () {
      expect(UpiReceiptReader.parse(const []).isEmpty, isTrue);
      expect(UpiReceiptReader.parse([at('SATIN EFFECT SHIRT', .5, .02)]).isEmpty, isTrue);
    });
  });

  group('matching a receipt to a debt', () {
    MullStore owing() {
      final s = MullStore.memory()..clock = () => DateTime(2026, 9, 19);
      s.completeOnboarding(name: 'Ananya', budget: 40000);
      s.addGroup('Goa', ['Sahil']);
      final g = s.groups.single;
      final sahil = g.members.firstWhere((m) => m.name == 'Sahil')..upiId = 'sahil@okaxis';
      // Sahil paid for something, so you owe him 1,000.
      s.addExpense(
        g,
        description: 'Airbnb',
        amount: 2000,
        payerId: sahil.id,
        shares: splitEqually(2000, g.members.map((m) => m.id).toList()),
      );
      return s;
    }

    test('matches on the payee and the amount', () {
      final s = owing();
      final match = s.matchReceipt(const UpiReceipt(amount: 1000, payeeUpiId: 'sahil@okaxis', utr: '4471'));
      expect(match, isNotNull);
      expect(match!.$1.name, 'Goa');
      expect(match.$2.amount, 1000);
    });

    test('a failed payment matches nothing', () {
      final s = owing();
      expect(
        s.matchReceipt(const UpiReceipt(amount: 1000, payeeUpiId: 'sahil@okaxis', failed: true)),
        isNull,
      );
    });

    test('will not guess when nothing lines up', () {
      final s = owing();
      expect(s.matchReceipt(const UpiReceipt(amount: 7777, payeeUpiId: 'nobody@okaxis')), isNull);
      expect(s.matchReceipt(const UpiReceipt()), isNull);
    });

    test('ignores debts you are not the one paying', () {
      final s = owing();
      final g = s.groups.single;
      // Now you have paid for more, so Sahil owes you instead.
      s.addExpense(
        g,
        description: 'Flights',
        amount: 8000,
        payerId: g.you!.id,
        shares: splitEqually(8000, g.members.map((m) => m.id).toList()),
      );
      expect(g.yourBalance, greaterThan(0));
      expect(s.matchReceipt(const UpiReceipt(amount: 3000, payeeUpiId: 'sahil@okaxis')), isNull);
    });
  });

  group('UPI', () {
    test('accepts the handles Indian banks actually issue', () {
      for (final id in ['ananya@okhdfc', 'sahil.mehta@okaxis', 'kabir-v@ybl', '9876543210@paytm']) {
        expect(isUpiId(id), isTrue, reason: id);
      }
      for (final id in ['', 'ananya', 'ananya@', '@okhdfc', 'a b@okhdfc']) {
        expect(isUpiId(id), isFalse, reason: id);
      }
    });

    test('builds a payment the UPI app can open with nothing left to type', () {
      final uri = upiPaymentUri(upiId: 'sahil@okaxis', name: 'Sahil Mehta', amount: 1240, note: 'Goa trip');
      expect(uri.scheme, 'upi');
      expect(uri.host, 'pay');
      expect(uri.queryParameters, {
        'pa': 'sahil@okaxis',
        'pn': 'Sahil Mehta',
        'am': '1240',
        'cu': 'INR',
        'tn': 'Goa trip',
      });
    });

    test('leaves the note out rather than sending an empty one', () {
      final uri = upiPaymentUri(upiId: 'a@b', name: 'A', amount: 10, note: '   ');
      expect(uri.queryParameters.containsKey('tn'), isFalse);
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
