import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mull/data/store.dart';
import 'package:mull/screens/home_screen.dart';
import 'package:mull/ui/tokens.dart';

/// The home screen actually drawing what the store works out.
///
/// The netting lives in `MullStore` and has its own tests; what these check is
/// that it reaches the screen, in both directions and in words. The old home
/// could only ever say what you were owed, so a person you owed had no row,
/// no amount and nowhere to tap.
void main() {
  Future<void> pumpHome(WidgetTester t, MullStore store) async {
    await t.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      StoreScope(
        store: store,
        child: ListenableBuilder(
          listenable: store,
          builder: (_, _) => MaterialApp(
            theme: buildTheme(MullColors.dark),
            home: const HomeScreen(),
          ),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 600));
  }

  MullStore withSample() => MullStore.memory()..loadSample();

  testWidgets('the sample data draws a people list with both directions', (t) async {
    final store = withSample();
    await pumpHome(t, store);

    // The list builds lazily, so the People section has to be scrolled to
    // before a finder can see it at all.
    await t.drag(find.byType(Scrollable).last, const Offset(0, -700));
    await t.pump(const Duration(milliseconds: 400));

    expect(find.text('PEOPLE'), findsOneWidget);
    // Every person Mull knows about has a row saying which way it points.
    expect(find.textContaining(RegExp('owes you|you owe|square')), findsWidgets);
  });

  testWidgets('somebody you owe is on the screen, with an amount', (t) async {
    final store = MullStore.memory();
    store.completeOnboarding(name: 'Bharat');
    final dinner = store.addGroup('Dinner', ['Dev']);
    final me = dinner.you!.id;
    final dev = dinner.members.firstWhere((m) => !m.isYou).id;
    store.addExpense(
      dinner,
      description: 'Dinner',
      amount: 900,
      payerId: dev,
      shares: {me: 450, dev: 450},
    );

    await pumpHome(t, store);
    expect(store.youOweThem.single.magnitude, 450);
    expect(find.text('you owe'), findsWidgets);
    expect(find.text('₹450'), findsWidgets);
  });

  testWidgets('both halves are named when money runs both ways', (t) async {
    final store = MullStore.memory();
    store.completeOnboarding(name: 'Bharat');

    final a = store.addGroup('Dinner', ['Dev']);
    store.addExpense(
      a,
      description: 'Dinner',
      amount: 900,
      payerId: a.members[1].id,
      shares: {a.you!.id: 450, a.members[1].id: 450},
    );
    final b = store.addGroup('Cab', ['Ritu']);
    store.addExpense(
      b,
      description: 'Cab',
      amount: 600,
      payerId: b.you!.id,
      shares: {b.you!.id: 300, b.members[1].id: 300},
    );

    await pumpHome(t, store);
    // "₹300 owed to you · ₹450 you owe" — the line the old headline could not
    // say, because it only ever had the net.
    expect(find.textContaining('owed to you'), findsWidgets);
    expect(find.textContaining('you owe'), findsWidgets);
  });

  testWidgets('a person square across two opposite ledgers says so once', (t) async {
    final store = MullStore.memory();
    store.completeOnboarding(name: 'Bharat');

    final a = store.addGroup('Goa', ['Ananya']);
    store.addExpense(
      a,
      description: 'Villa',
      amount: 1000,
      payerId: a.members[1].id,
      shares: {a.you!.id: 500, a.members[1].id: 500},
    );
    final b = store.addGroup('Flat', ['Ananya']);
    store.addExpense(
      b,
      description: 'Rent',
      amount: 1000,
      payerId: b.you!.id,
      shares: {b.you!.id: 500, b.members[1].id: 500},
    );

    await pumpHome(t, store);
    expect(store.standings.single.isSquare, isTrue);
    expect(find.text('square'), findsOneWidget);
    // And the headline does not claim a debt in either direction.
    expect(find.text('All square'), findsWidgets);
  });
}
