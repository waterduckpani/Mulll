import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mull/data/store.dart';
import 'package:mull/main.dart';
import 'package:mull/ui/icons.dart';

/// Walks every screen from the design with the mockup data, screenshotting each.
/// Run: flutter drive --driver=test_driver/integration_test.dart --target=integration_test/tour_test.dart
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  Future<void> settle(WidgetTester t, [int ms = 900]) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Finder glyph(MullGlyph g) => find.byWidgetPredicate((w) => w is MullIcon && w.glyph == g).hitTestable().last;

  Future<void> tapText(WidgetTester t, String text) async {
    await t.tap(find.text(text).hitTestable().last);
    await settle(t);
  }

  Future<void> shot(WidgetTester t, String name) async {
    await settle(t, 300);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await t.pump();
    await binding.takeScreenshot(name);
  }

  testWidgets('tour', (t) async {
    final store = MullStore.memory()..loadSample();
    await t.pumpWidget(MullApp(store: store));
    await settle(t, 2500);
    await shot(t, '08-in-reach');

    await tapText(t, 'Keep waiting');
    expect(store.pendingInReach, isEmpty);
    await shot(t, '02-wishlist');

    await tapText(t, 'Needs');
    await shot(t, '02b-wishlist-needs');

    await tapText(t, 'Wants');
    await shot(t, '01-budget-home');

    await tapText(t, 'Add to wishlist');
    await t.enterText(find.byType(TextField).at(0), 'Office chair');
    await t.enterText(find.byType(TextField).at(1), '28k');
    await tapText(t, 'Need');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t);
    await shot(t, '07-quick-add');

    await tapText(t, 'Save it');
    await settle(t, 1200);
    await shot(t, '03-need-check');
    await tapText(t, "Yes, it's a need");
    expect(store.needs.map((i) => i.name), contains('Office chair'));
    await settle(t, 1500);
    await shot(t, '01b-home-after-add');

    await tapText(t, 'Adjust budget');
    await shot(t, '09-adjust-budget');
    await t.tap(find.text('Save budget'));
    await settle(t);

    await t.tap(find.textContaining('Resets').hitTestable());
    await settle(t);
    await shot(t, '10-this-month');
    await t.tap(glyph(MullGlyph.chevronLeft));
    await settle(t);

    await tapText(t, 'Groups');
    await shot(t, '04-groups');
    await tapText(t, 'Goa trip');
    await shot(t, '05-group-detail');
    await tapText(t, 'Add an expense');
    await t.enterText(find.byType(TextField).at(0), 'Scooter rental');
    await t.enterText(find.byType(TextField).at(1), '2400');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t);
    await shot(t, '11-add-expense');
    await tapText(t, 'Add it');
    await settle(t, 800);
    expect(store.groups.first.expenses.map((e) => e.description), contains('Scooter rental'));
    await shot(t, '05b-group-after-expense');

    await shot(t, '15-confirm-claim');

    // A pending claim sits above "Who pays whom", so scroll to reach the rows.
    await t.ensureVisible(find.textContaining('→').first);
    await settle(t);

    // The row that says who pays whom, straight into the settle-up sheet.
    await t.tap(find.textContaining('→').hitTestable().first);
    await settle(t);
    await shot(t, '14-settle-up');
    await t.tapAt(const Offset(200, 80)); // dismiss by tapping the scrim
    await settle(t);

    await tapText(t, 'Lists');
    await shot(t, '12-lists');
    await tapText(t, 'Goa trip');
    await shot(t, '06-named-list');
    await t.tapAt(
      t.getCenter(find.text('Swim shorts').hitTestable()) -
          Offset(t.getSize(find.text('Swim shorts')).width / 2 + 22, 0),
    );
    await settle(t);
    expect(store.lists.first.doneCount, 5);
    await shot(t, '06b-named-list-ticked');

    await t.tap(find.bySemanticsLabel(RegExp('^Profile and settings')).hitTestable().last);
    await settle(t);
    await shot(t, '13-profile');
    await tapText(t, 'Dark');
    await shot(t, '13b-profile-dark');
    await t.tap(glyph(MullGlyph.close));
    await settle(t);
    await shot(t, '06c-named-list-dark');

    await tapText(t, 'Wishlist');
    await t.tap(find.text('Wishlist').hitTestable().last); // pop to root
    await settle(t);
    await shot(t, '01c-home-dark');
    await tapText(t, 'Wants');
    await shot(t, '02c-wishlist-dark');
  });
}
