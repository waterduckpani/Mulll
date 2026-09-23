import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mull/core/split.dart';
import 'package:mull/data/models.dart';
import 'package:mull/data/remote/groups_sync.dart';
import 'package:mull/data/store.dart';
import 'package:mull/main.dart';
import 'package:mull/screens/home_screen.dart';
import 'package:mull/ui/tokens.dart';

void main() {
  group('saving', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('mull_save'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('saves that overlap still leave a whole file, with the newest state', () async {
      final file = File('${dir.path}/mull.json');
      final store = MullStore.atFile(file)..completeOnboarding(name: 'Bharat');
      final flat = store.addGroup('Flat', ['Dev']);
      final me = flat.you!.id;
      final dev = flat.members.firstWhere((m) => !m.isYou).id;

      // The debounced save and a backgrounding save, many times over and
      // never awaited in between — the overlap that used to tear the file.
      final writes = <Future<void>>[];
      for (var i = 1; i <= 40; i++) {
        store.addExpense(flat, description: 'Chai $i', amount: 20, payerId: me, shares: splitEqually(20, [me, dev]));
        writes
          ..add(store.flush())
          ..add(store.flush());
      }
      await Future.wait(writes);

      final saved = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final expenses = ((saved['groups'] as List).single as Map)['expenses'] as List;
      expect(expenses, hasLength(40));
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('a failed save does not stop the next one', () async {
      final missing = File('${dir.path}/gone/mull.json');
      final store = MullStore.atFile(missing)..completeOnboarding(name: 'Bharat');
      await expectLater(store.flush(), throwsA(isA<FileSystemException>()));
      Directory('${dir.path}/gone').createSync();
      await store.flush();
      expect(missing.existsSync(), isTrue);
    });
  });

  group('stale shares', () {
    test('one clause per row: its shares stay, anyone else\'s go', () {
      final filters = GroupsSync.staleShareFilters('expense_id', {
        'e1': {'a': 50, 'b': 50},
        'e2': {'c': 100},
      });
      expect(filters, ['and(expense_id.eq.e1,member_id.not.in.(a,b)),and(expense_id.eq.e2,member_id.not.in.(c))']);
    });

    test('a row with no shares loses all of them, as the per-row delete did', () {
      expect(GroupsSync.staleShareFilters('recurring_id', {'r1': {}}), ['recurring_id.eq.r1']);
    });

    test('nothing to send is nothing to delete', () {
      expect(GroupsSync.staleShareFilters('expense_id', {}), isEmpty);
    });

    test('many rows split into several short filters, none lost', () {
      final byParent = {
        for (var i = 0; i < 60; i++)
          'expense-$i-0000-0000-0000-000000000000': {
            for (var m = 0; m < 8; m++) 'member-$m-0000-0000-0000-000000000000': 10,
          },
      };
      final filters = GroupsSync.staleShareFilters('expense_id', byParent);
      expect(filters.length, greaterThan(1));
      for (final f in filters) {
        expect(f.length, lessThanOrEqualTo(4000));
      }
      final clauses = filters.join(',').split('),and(').length;
      expect(clauses, 60);
    });

    test('one clause longer than the limit still goes, on its own', () {
      final runs = GroupsSync.chunked(['x' * 5000, 'y'], maxLength: 4000).toList();
      expect(runs, [['x' * 5000], ['y']]);
    });
  });

  group('what the store does less of', () {
    late MullStore store;
    late Group flat;
    late String me;
    late String dev;
    var told = 0;

    setUp(() {
      store = MullStore.memory()..completeOnboarding(name: 'Bharat');
      flat = store.addGroup('Flat', ['Dev']);
      me = flat.you!.id;
      dev = flat.members.firstWhere((m) => !m.isYou).id;
      store.addExpense(flat, description: 'Rent', amount: 24000, payerId: me, shares: splitEqually(24000, [me, dev]));
      store.ackRows(flat, flat.printed);
      store.markGroupSynced(flat);
      told = 0;
      store.addListener(() => told++);
    });

    // The definition hasPendingChanges replaced, kept here to hold it to.
    bool pendingTheOldWay(Group g) =>
        !g.hasReachedServer || g.tombstones.isNotEmpty || g.printed.entries.any((e) => g.isDirty(e.key, e.value));

    test('"anything unsent" still means exactly what it did', () {
      expect(flat.hasPendingChanges, pendingTheOldWay(flat));
      expect(flat.hasPendingChanges, isFalse);

      final checks = <void Function()>[
        () => flat.name = 'The flat',
        () => flat.icon = 'home',
        () => flat.members.last.name = 'Dev Rao',
        () => flat.expenses.single.amount = 26000,
        () => flat.expenses.single.shares = {me: 13000, dev: 13000},
        () => store.addExpense(flat, description: 'Wifi', amount: 1000, payerId: me, shares: {me: 500, dev: 500}),
        () => store.settleUp(flat, fromId: dev, toId: me, amount: 100),
        () => store.addRecurring(flat, description: 'Maid', amount: 3000, payerId: me,
            shares: {me: 1500, dev: 1500}, startsOn: DateTime(2026, 10, 1)),
        () => store.removeExpense(flat, flat.expenses.first),
      ];
      for (final change in checks) {
        change();
        expect(flat.hasPendingChanges, pendingTheOldWay(flat));
        expect(flat.hasPendingChanges, isTrue);
        store.ackRows(flat, flat.printed);
        store.clearTombstones(flat, [...flat.tombstones]);
        expect(flat.hasPendingChanges, pendingTheOldWay(flat));
        expect(flat.hasPendingChanges, isFalse);
      }
    });

    test('a pull with nothing new tells the screen but changes nothing', () {
      final before = [...store.groups];
      store.replaceGroups(const [], present: [flat.id]);
      expect(told, 1);
      expect(store.groups.length, before.length);
      for (var i = 0; i < before.length; i++) {
        expect(identical(store.groups[i], before[i]), isTrue);
      }
    });

    test('a pull that drops a group still drops it', () {
      store.replaceGroups(const [], present: const []);
      expect(store.groups, isEmpty);
    });

    test('acknowledging rows saves without a rebuild; the end of the push rebuilds', () {
      store.ackRows(flat, {'e:x': 'y'});
      store.clearTombstones(flat, [const Tombstone(id: 'x', kind: TombstoneKind.expense)]);
      expect(told, 0);
      store.markGroupSynced(flat);
      expect(told, 1);
      store.announceSync();
      expect(told, 2);
    });

    test('a group deleted here is queued for the server only if it is really gone', () {
      store.queueGroupDelete(flat.id);
      expect(store.pendingGroupDeletes, isEmpty, reason: 'still on this phone');
      store.queueGroupDelete('some-other-group');
      expect(store.pendingGroupDeletes, {'some-other-group'});
    });

    test('groups keep the order they always had', () {
      // Owe, owed, square; then by size; then newest first.
      final owe = store.addGroup('Owe', ['A']);
      store.addExpense(owe, description: 'x', amount: 100, payerId: owe.members.last.id,
          shares: {owe.you!.id: 50, owe.members.last.id: 50});
      final oweMore = store.addGroup('Owe more', ['B']);
      store.addExpense(oweMore, description: 'x', amount: 1000, payerId: oweMore.members.last.id,
          shares: {oweMore.you!.id: 500, oweMore.members.last.id: 500});
      store.addGroup('Square', ['C']);
      final names = store.namedGroups.map((g) => g.name).toList();
      expect(names, ['Owe more', 'Owe', 'Flat', 'Square']);

      int rank(Group g) => switch (g.yourBalance) { < 0 => 0, > 0 => 1, _ => 2 };
      final reference = [...store.groups]..sort((a, b) {
        final d = rank(a).compareTo(rank(b));
        if (d != 0) return d;
        final s = b.yourBalance.abs().compareTo(a.yourBalance.abs());
        return s != 0 ? s : b.createdAt.compareTo(a.createdAt);
      });
      expect(names, reference.map((g) => g.name).toList());
    });

    test('the totals worked out from standings in hand match the store\'s own', () {
      final sample = MullStore.memory()..loadSample();
      final people = sample.standings;
      expect(MullStore.youOweIn(people), sample.totalYouOwe);
      expect(MullStore.owedToYouIn(people), sample.totalOwedToYou);
    });
  });

  group('the screens still say it', () {
    testWidgets('the footer counts the people you are not square with', (t) async {
      await t.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final store = MullStore.memory()..loadSample();
      final unsquare = store.standings.where((s) => !s.isSquare).length;
      await t.pumpWidget(StoreScope(
        store: store,
        child: MaterialApp(theme: buildTheme(MullColors.dark), home: const HomeScreen()),
      ));
      await t.pump(const Duration(milliseconds: 600));
      final footer = find.textContaining('to square up with');
      await t.scrollUntilVisible(footer, 300, scrollable: find.byType(Scrollable).last);
      await t.pump(const Duration(milliseconds: 400));
      expect(t.widget<Text>(footer).data, '$unsquare people to square up with');
    });

    testWidgets('the app follows the theme setting, and only rebuilds for it', (t) async {
      final store = MullStore.memory()..completeOnboarding(name: 'Bharat');
      await t.pumpWidget(MullApp(store: store));
      await t.pump();
      MaterialApp app() => t.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app().themeMode, ThemeMode.dark);
      final first = app();

      store.addGroup('Flat', ['Dev']);
      await t.pump();
      expect(identical(app(), first), isTrue, reason: 'a ledger edit is not a theme change');

      store.updateProfile((p) => p.theme = ThemeMode.light);
      await t.pump();
      expect(app().themeMode, ThemeMode.light);
      expect(app().theme, same(first.theme), reason: 'built once');
      await t.pump(const Duration(seconds: 1));
    });
  });
}
