import 'package:flutter_test/flutter_test.dart';
import 'package:mull/core/dates.dart';
import 'package:mull/core/money.dart';
import 'package:mull/core/split.dart';
import 'package:mull/core/upi.dart';
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

  group('dates', () {
    test('adding months keeps the day where the month is long enough', () {
      expect(addMonths(DateTime(2026, 1, 15), 1), DateTime(2026, 2, 15));
      // Rent set on the 31st is still rent in February — the day clamps rather
      // than rolling into March, which would walk the date forward every short
      // month until it fell off the calendar.
      expect(addMonths(DateTime(2026, 1, 31), 1), DateTime(2026, 2, 28));
      expect(addMonths(DateTime(2028, 1, 31), 1), DateTime(2028, 2, 29), reason: 'leap year');
      expect(addMonths(DateTime(2026, 12, 5), 1), DateTime(2027, 1, 5));
      expect(addMonths(DateTime(2026, 11, 30), 3), DateTime(2027, 2, 28));
      expect(addMonths(DateTime(2026, 3, 10), 12), DateTime(2027, 3, 10));
    });

    test('a clamped day does not stay clamped', () {
      // 31 Jan → 28 Feb is right, but stepping again from there must not give
      // 28 March: each occurrence is measured from the schedule's own date.
      var d = DateTime(2026, 1, 31);
      expect(addMonths(d, 1), DateTime(2026, 2, 28));
      expect(addMonths(d, 2), DateTime(2026, 3, 31));
    });

    test('relative days read the way people say them', () {
      final now = DateTime(2026, 9, 19, 14);
      expect(relativeDay(DateTime(2026, 9, 19), now), 'today');
      expect(relativeDay(DateTime(2026, 9, 20), now), 'tomorrow');
      expect(relativeDay(DateTime(2026, 9, 18), now), 'yesterday');
      expect(relativeDay(DateTime(2026, 9, 23), now), 'in 4 days');
      expect(relativeDay(DateTime(2026, 9, 12), now), '7 days ago');
      expect(relativeDay(DateTime(2026, 10, 30), now), 'on 30 Oct');
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
      s.completeOnboarding(name: 'Ananya');
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
      expect(s.netAcrossAll, 2000);
    });
  });

  group('sample data', () {
    test('reproduces the numbers on the mockup', () {
      // The cascade has to stop at the closure, or `..loadSample()` binds to
      // the DateTime inside it rather than to the store.
      final s = MullStore.memory()..clock = () => DateTime(2026, 9, 19, 10);
      s.loadSample();

      // "You owe, all in / ₹3,850"
      expect(s.netAcrossAll, -3850);
      expect(s.isAllSquare, isFalse);

      expect(s.namedGroups.map((g) => g.title), ['Flat', 'Goa trip', 'Sunday football']);
      expect(s.groupById(s.namedGroups[0].id)!.yourBalance, -6250, reason: 'Flat · you owe ₹6,250');
      expect(s.namedGroups[1].yourBalance, 2400, reason: 'Goa trip · you get back ₹2,400');
      expect(s.namedGroups[2].yourBalance, 0, reason: 'Sunday football · settled up');

      // One person ledger, square, so the PEOPLE section has something in it.
      expect(s.directLedgers.map((g) => g.title), ['Ritu Nair']);
      expect(s.directLedgers.single.yourBalance, 0);

      // "Sahil says they sent you ₹800" — a claim, so it moves nothing yet.
      expect(s.confirmationsForYou, hasLength(1));
      final (group, claim) = s.confirmationsForYou.single;
      expect(group.title, 'Goa trip');
      expect(claim.amount, 800);
      expect(claim.status, SettlementStatus.pending);

      // The two payments that clear the trip, exactly as the settle-up screen
      // has them: Sahil owes what he says he has already sent, and Kabir, who
      // is not on Mull, owes the rest.
      final owed = simplify(group.balances);
      expect(owed.every((t) => t.to == group.you!.id), isTrue);
      expect(owed.map((t) => t.amount).toList()..sort(), [800, 1600]);
      expect(owed.any((t) => t.from == claim.fromId && t.amount == claim.amount), isTrue);
      expect(
        group.members.where((m) => !m.isLinked && !m.isYou).map((m) => m.name),
        ['Kabir'],
        reason: 'one seat belongs to somebody who has never heard of Mull',
      );

      // The villa deposit was paid off in full, so the ledger stops asking
      // about it without hiding it.
      expect(
        group.expenses.where((e) => s.settledExpenses(group).contains(e.id)).map((e) => e.description),
        ['Deposit for the villa'],
      );

      // Every ledger balances to zero, or money has gone missing.
      for (final g in s.groups) {
        expect(g.balances.values.fold(0, (a, b) => a + b), 0, reason: g.title);
      }

      // The house help is due today; the maintenance is not yet.
      expect(s.dueRecurring.map((d) => d.$2.description), ['House help']);
      expect(s.upcomingRecurring.map((d) => d.$2.description), ['Flat maintenance']);
      expect(s.runAutoRecurring(), isEmpty, reason: 'nothing adds itself without being told to');
    });
  });

  group('recurring', () {
    ({MullStore store, Group group, Recurring rent}) flat({DateTime? clockAt}) {
      var now = clockAt ?? DateTime(2026, 9, 19, 10);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'Ananya');
      s.addGroup('Flat', ['Ritu']);
      final g = s.groups.single;
      final rent = s.addRecurring(
        g,
        description: 'Rent',
        amount: 75000,
        payerId: g.you!.id,
        shares: splitEqually(75000, g.members.map((m) => m.id).toList()),
        startsOn: DateTime(2026, 10, 1),
      );
      return (store: s, group: g, rent: rent);
    }

    test('nothing is due before its date', () {
      // The clock is 19 September and the rent starts on 1 October: close
      // enough to be worth seeing, not close enough to owe.
      final f = flat();
      expect(f.store.dueRecurring, isEmpty);
      expect(f.store.upcomingRecurring, hasLength(1));
      expect(f.group.expenses, isEmpty, reason: 'nothing is created until it is confirmed');
    });

    test('it shows up in the next fortnight, then comes due', () {
      var now = DateTime(2026, 9, 19);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'Ananya');
      s.addGroup('Flat', ['Ritu']);
      final g = s.groups.single;
      s.addRecurring(
        g,
        description: 'Rent',
        amount: 75000,
        payerId: g.you!.id,
        shares: splitEqually(75000, g.members.map((m) => m.id).toList()),
        startsOn: DateTime(2026, 9, 25),
      );
      expect(s.upcomingRecurring, hasLength(1));
      expect(s.dueRecurring, isEmpty);

      now = DateTime(2026, 9, 25, 9);
      expect(s.dueRecurring, hasLength(1));
      expect(s.upcomingRecurring, isEmpty);
    });

    test('adding a due one records the expense and moves the schedule on', () {
      var now = DateTime(2026, 10, 2);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'Ananya');
      s.addGroup('Flat', ['Ritu']);
      final g = s.groups.single;
      final rent = s.addRecurring(
        g,
        description: 'Rent',
        amount: 75000,
        payerId: g.you!.id,
        shares: splitEqually(75000, g.members.map((m) => m.id).toList()),
        startsOn: DateTime(2026, 10, 1),
      );

      final expense = s.addDue(g, rent);
      expect(expense.date, DateTime(2026, 10, 1), reason: 'dated when it was owed, not when it was confirmed');
      expect(expense.recurringId, rent.id);
      expect(expense.isRecurring, isTrue);
      expect(rent.nextDue, DateTime(2026, 11, 1));
      expect(rent.lastAddedOn, DateTime(2026, 10, 1));
      expect(s.dueRecurring, isEmpty);
      expect(g.yourBalance, 37500, reason: 'you paid 75,000 and your share is half');
    });

    test('a confirmed change becomes the new normal', () {
      // The landlord put the rent up. Confirming the higher number this month
      // must not leave next month asking for the old one.
      final f = flat(clockAt: DateTime(2026, 10, 2));
      final g = f.group;
      final newShares = splitEqually(80000, g.members.map((m) => m.id).toList());
      final expense = f.store.addDue(g, f.rent, amount: 80000, shares: newShares);
      expect(expense.amount, 80000);
      expect(f.rent.amount, 80000);
      expect(f.rent.shares, newShares);
    });

    test('skipping records nothing and still moves on', () {
      final f = flat(clockAt: DateTime(2026, 10, 2));
      f.store.skipDue(f.group, f.rent);
      expect(f.group.expenses, isEmpty);
      expect(f.rent.nextDue, DateTime(2026, 11, 1));
    });

    test('a phone that was off for months owes one period, not five', () {
      // Catching up silently is how a scheduler turns a holiday into a
      // five-figure surprise.
      var now = DateTime(2026, 10, 2);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'Ananya');
      s.addGroup('Flat', ['Ritu']);
      final g = s.groups.single;
      final rent = s.addRecurring(
        g,
        description: 'Rent',
        amount: 75000,
        payerId: g.you!.id,
        shares: splitEqually(75000, g.members.map((m) => m.id).toList()),
        startsOn: DateTime(2026, 10, 1),
      );

      now = DateTime(2027, 3, 4);
      expect(s.dueRecurring, hasLength(1), reason: 'due once, now');
      s.addDue(g, rent);
      expect(g.expenses, hasLength(1));
      expect(rent.nextDue, DateTime(2027, 4, 1));
      expect(s.dueRecurring, isEmpty);
    });

    test('a paused schedule is not due, and does not pile up while it is off', () {
      var now = DateTime(2026, 10, 2);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'Ananya');
      s.addGroup('Flat', ['Ritu']);
      final g = s.groups.single;
      final rent = s.addRecurring(
        g,
        description: 'Rent',
        amount: 75000,
        payerId: g.you!.id,
        shares: splitEqually(75000, g.members.map((m) => m.id).toList()),
        startsOn: DateTime(2026, 10, 1),
      );

      s.setRecurringPaused(g, rent, true);
      expect(s.dueRecurring, isEmpty);

      now = DateTime(2027, 1, 9);
      s.setRecurringPaused(g, rent, false);
      expect(rent.nextDue, DateTime(2027, 1, 9), reason: 'nothing is owed for the time it was off');
      expect(s.dueRecurring, hasLength(1));
    });

    test('a schedule stops at its end date', () {
      var now = DateTime(2026, 10, 2);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'Ananya');
      s.addGroup('Flat', ['Ritu']);
      final g = s.groups.single;
      final rent = s.addRecurring(
        g,
        description: 'Rent',
        amount: 75000,
        payerId: g.you!.id,
        shares: splitEqually(75000, g.members.map((m) => m.id).toList()),
        startsOn: DateTime(2026, 10, 1),
        endsOn: DateTime(2026, 11, 15),
      );

      s.addDue(g, rent);
      expect(rent.nextDue, DateTime(2026, 11, 1));
      expect(rent.hasEnded, isFalse);

      now = DateTime(2026, 11, 2);
      s.addDue(g, rent);
      expect(rent.nextDue, DateTime(2026, 12, 1));
      expect(rent.hasEnded, isTrue);
      expect(rent.isActive, isFalse);

      now = DateTime(2026, 12, 2);
      expect(s.dueRecurring, isEmpty, reason: 'the lease is over');
    });

    test('only autoAdd schedules add themselves, and they report what they did', () {
      var now = DateTime(2026, 10, 2);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'Ananya');
      s.addGroup('Flat', ['Ritu']);
      final g = s.groups.single;
      final ids = g.members.map((m) => m.id).toList();
      s.addRecurring(
        g,
        description: 'Rent',
        amount: 75000,
        payerId: g.you!.id,
        shares: splitEqually(75000, ids),
        startsOn: DateTime(2026, 10, 1),
      );
      s.addRecurring(
        g,
        description: 'Wifi',
        amount: 1200,
        payerId: g.you!.id,
        shares: splitEqually(1200, ids),
        startsOn: DateTime(2026, 10, 1),
        autoAdd: true,
      );

      final made = s.runAutoRecurring();
      expect(made, hasLength(1));
      expect(made.single.$2.description, 'Wifi');
      expect(g.expenses.map((e) => e.description), ['Wifi']);
      expect(s.dueRecurring, hasLength(1), reason: 'rent still waits to be confirmed');
      expect(s.runAutoRecurring(), isEmpty, reason: 'and it does not add it twice');
    });

    test('every frequency lands where it should', () {
      final from = DateTime(2026, 9, 19);
      expect(Frequency.weekly.next(from), DateTime(2026, 9, 26));
      expect(Frequency.fortnightly.next(from), DateTime(2026, 10, 3));
      expect(Frequency.monthly.next(from), DateTime(2026, 10, 19));
      expect(Frequency.quarterly.next(from), DateTime(2026, 12, 19));
      expect(Frequency.yearly.next(from), DateTime(2027, 9, 19));
    });

    test('stopping a schedule keeps the expenses it already made', () {
      final f = flat(clockAt: DateTime(2026, 10, 2));
      final expense = f.store.addDue(f.group, f.rent);
      f.store.removeRecurring(f.group, f.rent);
      expect(f.group.recurring, isEmpty);
      expect(f.group.expenses, hasLength(1), reason: 'that was real money');
      expect(expense.recurringId, isNull);
      expect(f.group.yourBalance, 37500, reason: 'and the balance does not move');
    });

    test('someone a schedule depends on cannot be removed', () {
      final f = flat();
      final ritu = f.group.members.firstWhere((m) => m.name == 'Ritu');
      expect(f.store.canRemoveMember(f.group, ritu), isFalse, reason: 'she is in the rent split');
    });
  });

  group('one-to-one ledgers', () {
    MullStore make() {
      final s = MullStore.memory()..clock = () => DateTime(2026, 9, 19);
      s.completeOnboarding(name: 'Ananya');
      return s;
    }

    test('a direct ledger is two seats and is titled after the person', () {
      final s = make();
      final d = s.directWith(name: 'Ritu Nair', upiId: 'ritu@okicici');
      expect(d.isDirect, isTrue);
      expect(d.members, hasLength(2));
      expect(d.title, 'Ritu Nair', reason: 'the person is the name, not "Me and Ritu"');
      expect(d.counterpart?.upiId, 'ritu@okicici');
      expect(s.directLedgers, [d]);
      expect(s.namedGroups, isEmpty);
    });

    test('asking twice for the same person returns the same ledger', () {
      final s = make();
      final first = s.directWith(name: 'Ritu', userId: 'u-ritu');
      final again = s.directWith(name: 'Ritu Nair', userId: 'u-ritu');
      expect(again.id, first.id, reason: 'matched on the account, not the spelling');
      expect(s.directWith(name: 'ritu').id, first.id, reason: 'and on the name when there is no account');
      expect(s.groups, hasLength(1));
    });

    test('it settles like any other ledger and counts in the total', () {
      final s = make();
      final d = s.directWith(name: 'Ritu');
      final me = d.you!.id;
      final ritu = d.counterpart!.id;
      s.addExpense(
        d,
        description: 'Cab',
        amount: 900,
        payerId: ritu,
        shares: splitEqually(900, [me, ritu]),
      );
      expect(d.yourBalance, -450);
      expect(s.netAcrossAll, -450);
      expect(s.totalYouOwe, 450);
      expect(s.totalOwedToYou, 0);
    });

    test('groups and people are listed apart', () {
      final s = make();
      s.addGroup('Goa', ['Sahil']);
      s.directWith(name: 'Ritu');
      expect(s.namedGroups.map((g) => g.title), ['Goa']);
      expect(s.directLedgers.map((g) => g.title), ['Ritu']);
    });
  });

  // --------------------------------------------------------------- netting
  //
  // The thing Mull got wrong for longest. Money between two people is one
  // fact, and the app used to report it once per ledger and then chase them
  // for the larger half.

  group('where you stand with a person', () {
    late MullStore store;
    late Group goa;
    late Group flat;

    setUp(() {
      store = MullStore.memory();
      store.completeOnboarding(name: 'Bharat');

      // Ananya paid for the villa: you owe her 2,000 here.
      // The same person in both, by address — which is what lets money be
      // written between her ledgers. Two seats that share only a name are a
      // guess; see 'a name alone is not enough to move money on' below.
      goa = store.addGroup('Goa', ['Ananya']);
      goa.members.firstWhere((m) => !m.isYou).email = 'ananya@example.com';
      final meA = goa.you!.id;
      final herA = goa.members.firstWhere((m) => !m.isYou).id;
      store.addExpense(
        goa,
        description: 'Villa',
        amount: 4000,
        payerId: herA,
        shares: splitEqually(4000, [meA, herA]),
      );

      // You paid the rent: she owes you 3,000 here.
      flat = store.addGroup('Flat', ['Ananya']);
      flat.members.firstWhere((m) => !m.isYou).email = 'ananya@example.com';
      final meB = flat.you!.id;
      final herB = flat.members.firstWhere((m) => !m.isYou).id;
      store.addExpense(
        flat,
        description: 'Rent',
        amount: 6000,
        payerId: meB,
        shares: splitEqually(6000, [meB, herB]),
      );
    });

    Standing ananya() => store.standings.single;

    test('two ledgers pointing opposite ways are one netted number', () {
      expect(goa.yourBalance, -2000);
      expect(flat.yourBalance, 3000);
      expect(
        ananya().amount,
        1000,
        reason: 'she owes 3,000 and is owed 2,000, which is one fact',
      );
      expect(ananya().groups, hasLength(2));
    });

    test('a nudge asks for the netted amount, never the gross one', () {
      // The bug this replaced sent "Hey Ananya, ₹3,000" while owing her 2,000.
      expect(store.nudgeMessage(ananya()), contains('₹1,000'));
      expect(store.nudgeMessage(ananya()), isNot(contains('₹3,000')));
    });

    test('the two halves of the headline agree with the names under them', () {
      expect(store.totalOwedToYou, 1000);
      expect(store.totalYouOwe, 0, reason: 'counting groups would say 2,000');
      expect(store.netAcrossAll, store.totalOwedToYou - store.totalYouOwe);
    });

    test('someone you owe has a row of their own', () {
      final dev = store.addGroup('Dinner', ['Dev']);
      final me = dev.you!.id;
      final him = dev.members.firstWhere((m) => !m.isYou).id;
      store.addExpense(
        dev,
        description: 'Dinner',
        amount: 800,
        payerId: him,
        shares: splitEqually(800, [me, him]),
      );
      expect(store.youOweThem.single.member.name, 'Dev');
      expect(store.youOweThem.single.magnitude, 400);
      expect(store.totalYouOwe, 400);
    });

    test('a pair balance is what you owe them, not what the group owes them', () {
      final trip = store.addGroup('Trip', ['Sahil', 'Kabir']);
      final me = trip.you!.id;
      final sahil = trip.members[1].id;
      final kabir = trip.members[2].id;
      // Sahil pays for everyone. You owe Sahil; Kabir owes Sahil.
      store.addExpense(
        trip,
        description: 'Hotel',
        amount: 3000,
        payerId: sahil,
        shares: splitEqually(3000, [me, sahil, kabir]),
      );
      expect(trip.balances[sahil], 2000, reason: 'the group owes Sahil 2,000');
      expect(
        trip.pairBalanceWithYou(sahil),
        -1000,
        reason: 'but you only owe him your own share',
      );
      expect(trip.pairBalanceWithYou(kabir), 0);
    });

    test('pair balances always add back up to the group balance', () {
      final trip = store.addGroup('Trip', ['Sahil', 'Kabir']);
      final me = trip.you!.id;
      store.addExpense(
        trip,
        description: 'Boat',
        amount: 1000,
        payerId: me,
        shares: splitByWeight(1000, {
          me: 1,
          trip.members[1].id: 2,
          trip.members[2].id: 3,
        }),
      );
      for (final g in store.groups) {
        final sum = g.members
            .where((m) => !m.isYou)
            .fold(0, (t, m) => t + g.pairBalanceWithYou(m.id));
        expect(sum, g.yourBalance);
      }
    });

    test('netting off cancels both ledgers and moves no money', () {
      expect(store.canNetOff(ananya()), isTrue);
      expect(store.netOffAmount(ananya()), 2000);

      final before = store.netAcrossAll;
      store.netOff(ananya());

      expect(goa.yourBalance, 0, reason: 'the smaller ledger closes outright');
      expect(flat.yourBalance, 1000, reason: 'and the rest is what is really left');
      expect(store.netAcrossAll, before, reason: 'no money moved');
      expect(store.standings.single.amount, 1000);
      expect(
        goa.settlements.every((s) => s.offset),
        isTrue,
        reason: 'an offset must never be recorded as a payment somebody made',
      );
    });

    test('a name alone is not enough to move money on', () {
      // Two seats both typed "Ananya" are shown as one person, which is right
      // more often than not. Writing confirmed offsets between them is not
      // something to do on a guess: if they are two people, it moves money
      // between strangers.
      for (final g in [goa, flat]) {
        g.members.firstWhere((m) => !m.isYou).email = null;
      }
      expect(ananya().byNameOnly, isTrue);
      expect(ananya().amount, 1000, reason: 'still shown netted');
      expect(store.canNetOff(ananya()), isFalse);
      expect(store.canSettleAcross(ananya()), isFalse);
      expect(store.netOff(ananya()), isEmpty);
      expect(store.settleAcross(ananya(), amount: 1000), isEmpty);
      expect(goa.settlements, isEmpty);
    });

    test('netting off is idempotent', () {
      store.netOff(ananya());
      final after = store.netAcrossAll;
      store.netOff(store.standings.single);
      expect(store.netAcrossAll, after);
      expect(store.canNetOff(store.standings.single), isFalse);
    });

    test('a part payment leaves the rest open', () {
      store.settleAcross(ananya(), amount: 400);
      expect(store.standings.single.amount, 600);
    });

    test('paying in full squares the person and every ledger', () {
      store.settleAcross(ananya(), amount: 1000);
      expect(store.standings.single.amount, 0);
      expect(store.netAcrossAll, 0);
      expect(goa.yourBalance, 0);
      expect(flat.yourBalance, 0);
    });

    test('you owe first, then you are owed, then square', () {
      final dev = store.addGroup('Dinner', ['Dev']);
      final me = dev.you!.id;
      final him = dev.members.firstWhere((m) => !m.isYou).id;
      store.addExpense(
        dev,
        description: 'Dinner',
        amount: 800,
        payerId: him,
        shares: splitEqually(800, [me, him]),
      );
      // Dev is 400 owed by you, Ananya is 1,000 owed to you. Sorting on size
      // alone put Ananya first and swapped them whenever either moved.
      expect(store.standings.first.member.name, 'Dev');
      expect(store.standings.first.youOwe, isTrue);
    });
  });

  group('taking things off the record', () {
    late MullStore store;
    late Group goa;

    setUp(() {
      store = MullStore.memory();
      store.completeOnboarding(name: 'Bharat');
      goa = store.addGroup('Goa', ['Ananya']);
      final me = goa.you!.id;
      final her = goa.members.firstWhere((m) => !m.isYou).id;
      store.addExpense(
        goa,
        description: 'Villa',
        amount: 4000,
        payerId: me,
        shares: splitEqually(4000, [me, her]),
      );
    });

    test('a deletion is remembered until the server has been told', () {
      // An upsert can only say "this row exists", so without a tombstone the
      // expense came back on the next pull with everyone's balance behind it.
      final expense = goa.expenses.single;
      store.removeExpense(goa, expense);
      expect(goa.tombstones, hasLength(1));
      expect(goa.tombstones.single.kind, TombstoneKind.expense);
      expect(goa.tombstones.single.id, expense.id);
    });

    test('undo takes the tombstone back off before it can travel', () {
      final expense = goa.expenses.single;
      store.removeExpense(goa, expense);
      store.restoreExpense(goa, expense);
      expect(goa.expenses, hasLength(1));
      expect(goa.tombstones, isEmpty);
    });

    test('the sync clearing a tombstone leaves the others alone', () {
      final expense = goa.expenses.single;
      store.removeExpense(goa, expense);
      final schedule = store.addRecurring(
        goa,
        description: 'Wifi',
        amount: 1000,
        payerId: goa.you!.id,
        shares: {goa.you!.id: 1000},
        startsOn: DateTime(2026, 10),
      );
      store.removeRecurring(goa, schedule);
      expect(goa.tombstones, hasLength(2));
      store.clearTombstones(goa, [goa.tombstones.first]);
      expect(goa.tombstones, hasLength(1));
    });

    test('leaving a group deletes your seat, not just the local copy', () {
      final empty = store.addGroup('Empty', ['Raj']);
      final you = empty.you!;
      // Someone has to be left running it, which is a separate rule and a
      // good one.
      store.setAdmin(empty, empty.members.firstWhere((m) => !m.isYou), true);
      expect(store.leaveGroup(empty), isTrue);
      expect(
        empty.tombstones.any((t) => t.kind == TombstoneKind.member && t.id == you.id),
        isTrue,
        reason: 'without this the next pull hands the group straight back',
      );
    });

    test('only the two people a payment is between can remove it', () {
      final trip = store.addGroup('Trip', ['Dev', 'Raj']);
      final between = Settlement(
        fromId: trip.members[1].id,
        toId: trip.members[2].id,
        amount: 500,
        status: SettlementStatus.confirmed,
      );
      trip.settlements.add(between);

      expect(store.canRemoveSettlement(trip, between), isFalse);
      expect(store.removeSettlement(trip, between), isFalse);
      expect(trip.settlements, contains(between));
      expect(store.whySettlementStays(trip, between), isNotNull);
    });

    test('a payment you are part of can be removed, and put back', () {
      final her = goa.members.firstWhere((m) => !m.isYou).id;
      final paid = store.settleUp(goa, fromId: her, toId: goa.you!.id, amount: 2000);
      expect(goa.yourBalance, 0);

      expect(store.removeSettlement(goa, paid), isTrue);
      expect(goa.yourBalance, 2000, reason: 'the debt is open again');
      store.restoreSettlement(goa, paid);
      expect(goa.yourBalance, 0);
      expect(goa.tombstones, isEmpty);
    });

    test('a dispute is not a dead end', () {
      final her = goa.members.firstWhere((m) => !m.isYou);
      final claim = Settlement(
        fromId: her.id,
        toId: goa.you!.id,
        amount: 2000,
        status: SettlementStatus.pending,
      );
      goa.settlements.add(claim);

      store.disputeSettlement(goa, claim);
      expect(claim.clearsDebt, isFalse);
      expect(
        store.openClaims.map((c) => c.$2),
        contains(claim),
        reason: 'a disagreement about money is the last thing to go quiet',
      );

      store.reopenSettlement(goa, claim);
      expect(claim.status, SettlementStatus.pending);
      store.confirmSettlement(goa, claim);
      expect(claim.clearsDebt, isTrue);
    });

    test('your own unanswered claims are findable', () {
      final her = goa.members.firstWhere((m) => !m.isYou);
      her.userId = 'someone';
      final flat = store.addGroup('Flat', <String>[]);
      store.addFriendAsMember(flat, userId: 'someone', name: 'Ananya');
      final me = flat.you!.id;
      final herSeat = flat.members.firstWhere((m) => !m.isYou).id;
      store.addExpense(
        flat,
        description: 'Rent',
        amount: 2000,
        payerId: herSeat,
        shares: splitEqually(2000, [me, herSeat]),
      );
      store.settleUp(flat, fromId: me, toId: herSeat, amount: 1000);
      expect(
        store.claimsAwaitingOthers,
        hasLength(1),
        reason: 'the payer had no way to see a claim nobody confirmed',
      );
    });
  });

  group('splitting by percentage', () {
    // splitByWeight normalises, which is right for shares ("Dev eats two
    // portions") and wrong for percentages: 30 and 30 quietly became half
    // each, and the line underneath said "Split by percentage" with a
    // straight face. Nobody typing 30 means 50.
    test('weights normalise, which is what shares are for', () {
      final out = splitByWeight(1000, {'a': 30, 'b': 30});
      expect(out.values.fold(0, (s, v) => s + v), 1000);
      expect(out['a'], 500);
    });

    test('so percentages have to be checked before they get there', () {
      int total(Map<String, num> w) =>
          w.values.fold<double>(0, (s, v) => s + v.toDouble()).round();
      expect(total({'a': 30, 'b': 30}), isNot(100));
      expect(total({'a': 50, 'b': 50}), 100);
      // Thirds, which nobody can type exactly and everybody types.
      expect(total({'a': 33.33, 'b': 33.33, 'c': 33.34}), 100);
    });
  });

  group('reminders', () {
    MullStore owed() {
      final s = MullStore.memory()..clock = () => DateTime(2026, 9, 19, 10);
      s.completeOnboarding(name: 'Ananya');
      s.updateProfile((p) => p.upiId = 'ananya@okhdfc');
      return s;
    }

    void youPaidFor(MullStore s, Group g, int amount) {
      s.addExpense(
        g,
        description: 'Dinner',
        amount: amount,
        payerId: g.you!.id,
        shares: splitEqually(amount, g.members.map((m) => m.id).toList()),
      );
    }

    test('one person owing across two ledgers is one row, netted', () {
      final s = owed();
      s.addGroup('Goa', ['Sahil']);
      s.addGroup('Flat', ['Sahil']);
      for (final g in s.groups) {
        youPaidFor(s, g, 1000);
      }
      final owing = s.owedToYou;
      expect(owing, hasLength(1), reason: 'chasing the same friend twice is how this feature gets uninstalled');
      expect(owing.single.amount, 1000, reason: '500 from each');
      expect(owing.single.groups, hasLength(2));
    });

    test('the message names the amount and how to pay', () {
      final s = owed();
      s.addGroup('Goa', ['Sahil']);
      youPaidFor(s, s.groups.single, 1000);
      final message = s.nudgeMessage(s.owedToYou.single);
      expect(message, contains('Sahil'));
      expect(message, contains('₹500'));
      expect(message, contains('Goa'));
      expect(message, contains('ananya@okhdfc'));
    });

    test('nobody is nudged more than twice in a day', () {
      var now = DateTime(2026, 9, 19, 10);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'Ananya');
      s.addGroup('Goa', ['Sahil']);
      youPaidFor(s, s.groups.single, 1000);

      expect(s.nudgesLeft(s.owedToYou.single), 2);
      s.markNudged(s.owedToYou.single);
      expect(s.nudgesLeft(s.owedToYou.single), 1, reason: 'one is a favour, two is fair');
      expect(s.canNudge(s.owedToYou.single), isTrue);

      now = DateTime(2026, 9, 19, 14);
      s.markNudged(s.owedToYou.single);
      expect(s.canNudge(s.owedToYou.single), isFalse, reason: 'the third is nagging');

      // A rolling window, not a calendar one: midnight is not a reset anybody
      // experiences, and two at 11pm plus two at 12:05am is four in ten
      // minutes.
      now = DateTime(2026, 9, 20, 9, 59);
      expect(s.canNudge(s.owedToYou.single), isFalse, reason: 'still inside 24 hours');

      // Each nudge ages out on its own, so the allowance comes back in the
      // order it was spent rather than all at once at some reset hour.
      now = DateTime(2026, 9, 20, 10, 1);
      expect(s.nudgesLeft(s.owedToYou.single), 1, reason: 'the 10am one has aged out');

      now = DateTime(2026, 9, 20, 14, 1);
      expect(s.nudgesLeft(s.owedToYou.single), 2, reason: 'and now the 2pm one has too');
    });

    test('the allowance is per person, not per group', () {
      var now = DateTime(2026, 9, 19, 10);
      final s = MullStore.memory()..clock = () => now;
      s.completeOnboarding(name: 'Ananya');
      s.addGroup('Goa', ['Sahil']);
      s.addGroup('Flat', ['Sahil']);
      for (final g in s.groups) {
        youPaidFor(s, g, 1000);
      }

      // Sahil owes across two ledgers but is one person. Spending the
      // allowance has to follow him, or three dinners together would mean six
      // reminders a day.
      final owing = s.owedToYou.single;
      expect(owing.groups, hasLength(2));
      s.markNudged(owing);
      now = DateTime(2026, 9, 19, 14);
      s.markNudged(s.owedToYou.single);
      expect(s.canNudge(s.owedToYou.single), isFalse);
    });

    test("a nudge the server refused does not stay offered", () {
      final s = MullStore.memory()..clock = () => DateTime(2026, 9, 19, 10);
      s.completeOnboarding(name: 'Ananya');
      s.addGroup('Goa', ['Sahil']);
      youPaidFor(s, s.groups.single, 1000);

      // The count that decides is the server's — a reminder sent from another
      // phone never touched this one's copy. When it says the allowance is
      // gone, the button has to agree rather than keep firing a call that will
      // keep being refused.
      s.spendNudges(s.owedToYou.single);
      expect(s.canNudge(s.owedToYou.single), isFalse);
      expect(s.nudgesLeft(s.owedToYou.single), 0);
    });

    test('people you owe are not on the list', () {
      final s = owed();
      final g = s.addGroup('Goa', ['Sahil']);
      final sahil = g.members.firstWhere((m) => m.name == 'Sahil');
      s.addExpense(
        g,
        description: 'Hotel',
        amount: 4000,
        payerId: sahil.id,
        shares: splitEqually(4000, g.members.map((m) => m.id).toList()),
      );
      expect(s.owedToYou, isEmpty);
    });
  });

  group('reading a file written by the wishlist-era app', () {
    test('groups carry over and repeatsMonthly becomes a schedule', () {
      final saved = {
        'version': 1,
        'profile': {'name': 'Ananya', 'monthlyBudget': 40000, 'resetDay': 1, 'theme': 'system', 'onboarded': true},
        'items': [
          {'id': 'i1', 'name': 'Jacket', 'price': 8000, 'kind': 'want', 'createdAt': '2026-09-01T00:00:00.000'},
        ],
        'lists': [],
        'spends': [],
        'budgetOverrides': {'2026-09': 30000},
        'groups': [
          {
            'id': 'g1',
            'name': 'Flat',
            'createdAt': '2026-08-01T00:00:00.000',
            'members': [
              {'id': 'm1', 'name': 'Ananya', 'isYou': true},
              {'id': 'm2', 'name': 'Ritu'},
            ],
            'expenses': [
              {
                'id': 'e1',
                'description': 'Rent',
                'amount': 60000,
                'payerId': 'm1',
                'shares': {'m1': 30000, 'm2': 30000},
                'method': 'equal',
                'repeatsMonthly': true,
                'date': '2026-09-01T00:00:00.000',
              },
              {
                'id': 'e2',
                'description': 'Chai',
                'amount': 100,
                'payerId': 'm2',
                'shares': {'m1': 50, 'm2': 50},
                'method': 'equal',
                'repeatsMonthly': false,
                'date': '2026-09-04T00:00:00.000',
              },
            ],
            'settlements': [],
          },
        ],
      };

      final s = MullStore.memory()..clock = () => DateTime(2026, 9, 19);
      s.debugRestore(saved);

      expect(s.profile.name, 'Ananya');
      expect(s.groups, hasLength(1));
      final g = s.groups.single;
      expect(g.expenses, hasLength(2), reason: 'the ledger is untouched');
      expect(g.yourBalance, 29950);

      // The flag said "this happens again" and nothing more. It becomes the
      // schedule it was always trying to be.
      expect(g.recurring, hasLength(1));
      final rent = g.recurring.single;
      expect(rent.description, 'Rent');
      expect(rent.amount, 60000);
      expect(rent.frequency, Frequency.monthly);
      expect(rent.nextDue, DateTime(2026, 10, 1));
      expect(g.expenses.firstWhere((e) => e.id == 'e1').recurringId, rent.id);
      expect(g.expenses.firstWhere((e) => e.id == 'e2').recurringId, isNull);

      // Wishlist, spends and lists are simply not read — there is nowhere for
      // them to go, and the groups are the part that was ever shared.
      expect(s.toJson().containsKey('items'), isFalse);
      expect(s.toJson()['version'], 2);
    });

    test('a file with no groups in it still opens', () {
      final s = MullStore.memory();
      s.debugRestore({'version': 1, 'profile': {'name': 'Ananya', 'onboarded': true}});
      expect(s.groups, isEmpty);
      expect(s.profile.name, 'Ananya');
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
        'am': '1240.00',
        'cu': 'INR',
        'tn': 'Goa trip',
      });
    });

    test('leaves the note out rather than sending an empty one', () {
      final uri = upiPaymentUri(upiId: 'a@b', name: 'A', amount: 10, note: '   ');
      expect(uri.queryParameters.containsKey('tn'), isFalse);
    });
  });

  group('who runs a group', () {
    MullStore signedIn() => MullStore.memory()..completeOnboarding(name: 'Ananya');

    test('whoever starts it runs it, and nobody else does', () {
      final s = signedIn();
      final g = s.addGroup('Flat', ['Sahil']);
      expect(g.you!.isAdmin, isTrue);
      expect(g.memberById(g.members[1].id)!.isAdmin, isFalse);
      expect(g.youAreAdmin, isTrue);
      expect(g.admins, hasLength(1));
    });

    test('a one-to-one ledger has no hierarchy in it', () {
      final s = signedIn();
      final g = s.directWith(name: 'Ritu', userId: newId());
      expect(g.members.every((m) => m.isAdmin), isTrue,
          reason: 'it belongs to both of you, so either can rename or delete it');
      expect(g.youAreAdmin, isTrue);
    });

    test('the last admin cannot step down', () {
      final s = signedIn();
      final g = s.addGroup('Flat', []);
      final sahil = s.addFriendAsMember(g, userId: newId(), name: 'Sahil')!;

      expect(s.setAdmin(g, g.you!, false), isFalse, reason: 'that group would be unrunnable');
      expect(g.you!.isAdmin, isTrue);

      expect(s.setAdmin(g, sahil, true), isTrue);
      expect(s.setAdmin(g, g.you!, false), isTrue, reason: 'there is someone else now');
      expect(g.youAreAdmin, isFalse);
    });

    test('a member cannot remove people, and an admin cannot remove history', () {
      final s = signedIn();
      final g = s.addGroup('Flat', ['Sahil', 'Dev']);
      final sahil = g.members.firstWhere((m) => m.name == 'Sahil');
      final dev = g.members.firstWhere((m) => m.name == 'Dev');

      expect(s.canRemoveMember(g, dev), isTrue);

      // Sahil paid for something, so the ledger depends on him. That refusal
      // is arithmetic, not authority, and outranks being an admin.
      s.addExpense(
        g,
        description: 'Rent',
        amount: 900,
        payerId: sahil.id,
        shares: splitEqually(900, g.members.map((m) => m.id).toList()),
      );
      expect(s.canRemoveMember(g, sahil), isFalse);
      expect(s.whyMemberStays(g, sahil), contains('owe a share'));

      // Dev was in that split too, so the arithmetic refusal now covers him
      // as well — it outranks authority either way. Test the other refusal
      // against someone the ledger has never touched.
      expect(s.whyMemberStays(g, dev), contains('owe a share'));
      final bhavya = s.addFriendAsMember(g, userId: newId(), name: 'Bhavya')!;
      expect(s.canRemoveMember(g, bhavya), isTrue);

      // Hand the group over and the authority goes with it.
      s
        ..setAdmin(g, bhavya, true)
        ..setAdmin(g, g.you!, false);
      expect(s.canRemoveMember(g, bhavya), isFalse);
      expect(s.whyMemberStays(g, bhavya), contains('Only an admin'));
    });

    test('leaving is yours to do, but not at the ledger\'s expense', () {
      final s = signedIn();
      final g = s.addGroup('Flat', []);
      final sahil = s.addFriendAsMember(g, userId: newId(), name: 'Sahil')!;

      // Sole admin of a group with someone else in it.
      expect(s.whyYouCannotLeave(g), contains('only admin'));

      s.setAdmin(g, sahil, true);
      expect(s.whyYouCannotLeave(g), isNull);

      s.addExpense(
        g,
        description: 'Wifi',
        amount: 800,
        payerId: g.you!.id,
        shares: splitEqually(800, [g.you!.id, sahil.id]),
      );
      expect(s.whyYouCannotLeave(g), contains('Settle up first'));
      expect(s.leaveGroup(g), isFalse);
      expect(s.groups, hasLength(1));
    });

    test('an icon is an admin\'s to set', () {
      final s = signedIn();
      final g = s.addGroup('Flat', []);
      s.setGroupIcon(g, 'home');
      expect(g.icon, 'home');

      final sahil = s.addFriendAsMember(g, userId: newId(), name: 'Sahil')!;
      s
        ..setAdmin(g, sahil, true)
        ..setAdmin(g, g.you!, false)
        ..setGroupIcon(g, 'plane');
      expect(g.icon, 'home', reason: 'the server refuses this too, so the app should not offer it');
    });

    test('roles and icons survive a round trip through the file', () {
      final s = signedIn();
      final g = s.addGroup('Flat', ['Kabir']);
      s.setGroupIcon(g, 'bolt');

      final reopened = MullStore.memory()..debugRestore(s.toJson());
      final back = reopened.groups.single;
      expect(back.icon, 'bolt');
      expect(back.you!.isAdmin, isTrue);
      expect(back.members.firstWhere((m) => m.name == 'Kabir').isAdmin, isFalse);
    });
  });

  group('who gets told', () {
    /// Collects what the app would have sent, instead of sending it.
    (MullStore, List<Notice>) listening() {
      final sent = <Notice>[];
      final s = MullStore.memory()
        ..completeOnboarding(name: 'Ananya')
        ..onNotice = sent.add;
      return (s, sent);
    }

    test('an expense reaches the split, not the group', () {
      final (s, sent) = listening();
      final g = s.addGroup('Flat', []);
      final sahil = s.addFriendAsMember(g, userId: 'u-sahil', name: 'Sahil')!;
      final dev = s.addFriendAsMember(g, userId: 'u-dev', name: 'Dev')!;
      s.addFriendAsMember(g, userId: 'u-bhavya', name: 'Bhavya');
      sent.clear();

      s.addExpense(
        g,
        description: 'Chai',
        amount: 60,
        payerId: sahil.id,
        shares: splitEqually(60, [sahil.id, dev.id]),
      );

      final notice = sent.single;
      expect(notice.kind, NoticeKind.expenseAdded);
      expect(notice.to, unorderedEquals(['u-sahil', 'u-dev']),
          reason: 'Bhavya is in the group and not in the split');
      expect(notice.title, 'Ananya added Chai',
          reason: 'Ananya typed it in; Sahil only paid');
      expect(notice.body, endsWith('Sahil paid'));
    });

    test('a seat with nobody behind it is not told anything', () {
      final (s, sent) = listening();
      final g = s.addGroup('Trip', ['Kabir']);
      sent.clear();
      final kabir = g.members.firstWhere((m) => m.name == 'Kabir');

      s.addExpense(
        g,
        description: 'Cab',
        amount: 400,
        payerId: g.you!.id,
        shares: splitEqually(400, [g.you!.id, kabir.id]),
      );
      expect(sent, isEmpty, reason: 'a placeholder has no inbox to reach');
    });

    test('settling reaches the other end of the payment and stops', () {
      final (s, sent) = listening();
      final g = s.addGroup('Flat', []);
      final sahil = s.addFriendAsMember(g, userId: 'u-sahil', name: 'Sahil')!;
      s.addFriendAsMember(g, userId: 'u-dev', name: 'Dev');
      sent.clear();

      s.settleUp(g, fromId: g.you!.id, toId: sahil.id, amount: 500);
      expect(sent.single.to, ['u-sahil']);
      expect(sent.single.kind, NoticeKind.settlementClaimed);

      // Confirming and disputing are the payee's calls, so the claim being
      // answered is one Sahil made on his phone and this one pulled down.
      final his = Settlement(fromId: sahil.id, toId: g.you!.id, amount: 500);
      g.settlements.add(his);

      sent.clear();
      s.confirmSettlement(g, his);
      expect(sent.single.to, ['u-sahil']);
      expect(sent.single.kind, NoticeKind.settlementConfirmed);

      sent.clear();
      s.disputeSettlement(g, his);
      expect(sent.single.kind, NoticeKind.settlementDisputed);
      expect(sent.single.to, ['u-sahil'],
          reason: 'a disputed payment is between the two of them');
    });

    test('a notice never says "You" to somebody else', () {
      final (s, sent) = listening();
      final g = s.addGroup('Flat', []);
      final sahil = s.addFriendAsMember(g, userId: 'u-sahil', name: 'Sahil')!;
      sent.clear();

      // Your own seat reads as "You" everywhere on screen, which is exactly
      // wrong in a sentence being delivered to someone else's phone.
      s.settleUp(g, fromId: g.you!.id, toId: sahil.id, amount: 500);
      expect(sent.single.title, startsWith('Ananya'));
      expect(sent.single.title, isNot(contains('You ')));
    });
  });
}
