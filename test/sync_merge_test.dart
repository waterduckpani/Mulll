import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mull/core/split.dart';
import 'package:mull/data/models.dart';
import 'package:mull/data/store.dart';

/// What the server would hand back for [g]: the same rows, and none of the
/// phone's own bookkeeping.
Group serverCopy(Group g, {void Function(Group)? edit}) {
  final json = jsonDecode(jsonEncode(g.toJson())) as Map<String, dynamic>
    ..remove('tombstones')
    ..remove('acked');
  final copy = Group.fromJson(json)..syncedAt = DateTime.now();
  edit?.call(copy);
  return copy;
}

/// A push that landed: the server now has every row as it stands.
void pushed(MullStore store, Group g) {
  store.ackRows(g, g.printed);
  store.markGroupSynced(g);
}

void main() {
  late MullStore store;
  late Group flat;
  late String me;
  late String dev;

  setUp(() {
    store = MullStore.memory();
    store.completeOnboarding(name: 'Bharat');
    flat = store.addGroup('Flat', ['Dev']);
    me = flat.you!.id;
    dev = flat.members.firstWhere((m) => !m.isYou).id;
    store.addExpense(
      flat,
      description: 'Rent',
      amount: 24000,
      payerId: me,
      shares: splitEqually(24000, [me, dev]),
    );
    pushed(store, flat);
  });

  Group current() => store.groupById(flat.id)!;

  group('a pull around unsent work', () {
    test('an edit whose push failed survives the next pull', () {
      // The push never landed, so the server still has 24,000.
      final server = serverCopy(current());
      current().expenses.single.amount = 26000;

      store.replaceGroups([server]);

      expect(current().expenses.single.amount, 26000,
          reason: 'this used to be erased from the phone that made it');
    });

    test('a row nobody here touched takes the server version', () {
      final server = serverCopy(current(), edit: (g) => g.expenses.single.description = 'Rent, October');

      store.replaceGroups([server]);

      expect(current().expenses.single.description, 'Rent, October');
    });

    test('something added here and not yet sent is kept', () {
      final server = serverCopy(current());
      store.addExpense(current(), description: 'Wifi', amount: 1000, payerId: me, shares: {me: 500, dev: 500});

      store.replaceGroups([server]);

      expect(current().expenses.map((e) => e.description), containsAll(['Rent', 'Wifi']));
    });

    test('something deleted here does not come back before the delete is sent', () {
      final server = serverCopy(current());
      store.removeExpense(current(), current().expenses.single);

      store.replaceGroups([server]);

      expect(current().expenses, isEmpty);
      expect(current().tombstones, hasLength(1), reason: 'still owed to the server');
    });

    test('something deleted elsewhere goes', () {
      final server = serverCopy(current(), edit: (g) => g.expenses.clear());

      store.replaceGroups([server]);

      expect(current().expenses, isEmpty);
    });

    test('after a pull, the server is what counts as sent', () {
      final server = serverCopy(current(), edit: (g) => g.expenses.single.amount = 25000);
      store.replaceGroups([server]);

      expect(current().hasPendingChanges, isFalse);
      current().expenses.single.amount = 25500;
      expect(current().hasPendingChanges, isTrue);
    });

    test('a group deleted here stays gone until the server has the delete', () {
      final server = serverCopy(current());
      store.deleteGroup(current());
      expect(store.pendingGroupDeletes, contains(flat.id));

      store.replaceGroups([server]);

      expect(store.groupById(flat.id), isNull);
    });

    test('a group synced by an older Mull takes the server once', () {
      final server = serverCopy(current(), edit: (g) => g.expenses.single.amount = 25000);
      current().acked.clear();
      current().expenses.single.amount = 99999;

      store.replaceGroups([server]);

      expect(current().expenses.single.amount, 25000);
      expect(current().acked, isNotEmpty);
    });
  });

  group('undo after the delete already landed', () {
    test('a restored expense is sent again, so the server un-deletes it', () {
      final rent = current().expenses.single;
      store.removeExpense(current(), rent);
      store.restoreExpense(current(), rent);

      expect(current().acked.containsKey('e:${rent.id}'), isFalse,
          reason: 'unsent is what makes the push say deleted_at: null');
    });

    test('a restored group is sent again', () {
      final g = current();
      store.deleteGroup(g);
      store.restoreGroup(g);

      expect(store.pendingGroupDeletes, isEmpty);
      expect(g.acked.containsKey('g'), isFalse);
    });
  });

  group('a schedule coming due on two phones', () {
    test('both phones write the same expense', () {
      final rent = store.addRecurring(
        current(),
        description: 'Maid',
        amount: 3000,
        payerId: me,
        shares: {me: 1500, dev: 1500},
        startsOn: DateTime(2026, 9, 1),
      );
      final other = MullStore.memory()..debugRestore(jsonDecode(jsonEncode(store.toJson())) as Map<String, dynamic>);

      final here = store.addDue(current(), rent);
      final there = other.addDue(other.groupById(flat.id)!, other.groupById(flat.id)!.recurringById(rent.id)!);

      expect(there.id, here.id, reason: 'one row on the server, not two');
    });

    test('a phone that already has the occurrence does not add it twice', () {
      final rent = store.addRecurring(
        current(),
        description: 'Maid',
        amount: 3000,
        payerId: me,
        shares: {me: 1500, dev: 1500},
        startsOn: DateTime(2026, 9, 1),
      );
      final first = store.addDue(current(), rent);
      rent.nextDue = DateTime(2026, 9, 1); // a stale copy that never advanced
      final again = store.addDue(current(), rent);

      expect(again.id, first.id);
      expect(current().expenses.where((e) => e.recurringId == rent.id), hasLength(1));
    });
  });

  group('a pull that only fetched what changed', () {
    late Group goa;

    setUp(() {
      goa = store.addGroup('Goa', ['Dev']);
      pushed(store, goa);
    });

    test('a group the server still lists but did not send is kept as it is', () {
      final flatServer = serverCopy(current(), edit: (g) => g.expenses.single.description = 'Rent, October');

      // Only the flat changed; Goa is listed and not fetched.
      store.replaceGroups([flatServer], present: [flat.id, goa.id]);

      expect(store.groupById(goa.id), isNotNull, reason: 'unchanged is not deleted');
      expect(current().expenses.single.description, 'Rent, October');
    });

    test('an unsent edit in a group that was not fetched is left alone', () {
      store.addExpense(goa, description: 'Scooter', amount: 800, payerId: goa.you!.id, shares: {goa.you!.id: 800});

      store.replaceGroups(const [], present: [flat.id, goa.id]);

      expect(store.groupById(goa.id)!.expenses.map((e) => e.description), ['Scooter']);
    });

    test('a group the server no longer lists goes, as with a full pull', () {
      store.replaceGroups(const [], present: [flat.id]);

      expect(store.groupById(goa.id), isNull);
      expect(store.groupById(flat.id), isNotNull);
    });

    test('a group made here and never sent survives not being listed', () {
      final fresh = store.addGroup('New', ['Dev']);

      store.replaceGroups(const [], present: [flat.id, goa.id]);

      expect(store.groupById(fresh.id), isNotNull);
    });

    test('the listed order is kept, with unsent groups after it', () {
      final fresh = store.addGroup('New', ['Dev']);

      store.replaceGroups(const [], present: [goa.id, flat.id]);

      expect(store.groups.map((g) => g.id), [goa.id, flat.id, fresh.id]);
    });

    test('a group deleted here is not brought back by being listed', () {
      store.deleteGroup(goa);

      store.replaceGroups(const [], present: [flat.id, goa.id]);

      expect(store.groupById(goa.id), isNull);
    });

    test('the revision it was fetched at is kept, and survives a restart', () {
      final server = serverCopy(current())..serverRev = 7;

      store.replaceGroups([server], present: [flat.id, goa.id]);

      expect(current().serverRev, 7);
      final reloaded = Group.fromJson(jsonDecode(jsonEncode(current().toJson())) as Map<String, dynamic>);
      expect(reloaded.serverRev, 7);
    });
  });

  test('only an admin can delete a group', () {
    final g = current();
    g.you!.role = MemberRole.member;
    expect(store.deleteGroup(g), isFalse);
    expect(store.groupById(g.id), isNotNull);
  });

  test('stableId is a real uuid and depends only on its seed', () {
    final id = stableId('abc|2026-9-1');
    expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
    expect(stableId('abc|2026-9-1'), id);
    expect(stableId('abc|2026-10-1'), isNot(id));
  });

  test('signing out forgets the account, including what never synced', () async {
    store.updateProfile((p) => p.upiId = 'bharat@okhdfcbank');
    store.addGroup('Never pushed', ['Raj']);
    await store.forgetAccount();

    expect(store.groups, isEmpty);
    expect(store.profile.name, isEmpty, reason: 'the next person would inherit it');
    expect(store.profile.upiId, isNull, reason: 'and be paid at it');
  });

  test('an expense added late in the day is not ordered before a payment that morning', () {
    final g = current();
    // The rent was settled at 10am; the chai was added at 3pm the same day.
    // After a pull an expense's date has no time in it, only a day.
    final morning = DateTime(2026, 9, 20, 10);
    g.expenses.clear();
    store.addExpense(g, description: 'Rent', amount: 2000, payerId: me, shares: {me: 1000, dev: 1000},
        date: DateTime(2026, 9, 19));
    g.settlements.add(Settlement(fromId: dev, toId: me, amount: 1000, status: SettlementStatus.confirmed,
        date: morning, confirmedAt: morning));
    final chai = Expense(description: 'Chai', amount: 100, payerId: me, shares: {me: 50, dev: 50},
        date: DateTime(2026, 9, 20), createdAt: DateTime(2026, 9, 20, 15));
    g.expenses.add(chai);

    final rent = g.expenses.firstWhere((e) => e.description == 'Rent');
    final settled = store.settledExpenses(g);
    expect(settled, contains(rent.id),
        reason: 'the morning payment cleared the rent; ordering the chai first hid that');
    expect(settled, isNot(contains(chai.id)), reason: 'the chai came after and is still owed');
  });
}
