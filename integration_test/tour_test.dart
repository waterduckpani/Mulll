import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mull/data/store.dart';
import 'package:mull/main.dart';
import 'package:mull/ui/icons.dart';
import 'package:mull/ui/sheet.dart';

/// Walks every screen with the mockup data, screenshotting each in both themes.
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

  /// Backs out of every open sheet by tapping the scrim above them.
  ///
  /// Above them, not at 80pt: the tall sheets reach to within ~70pt of the top,
  /// so the old tap landed on the sheet itself and quietly did nothing.
  Future<void> dismissSheet(WidgetTester t) async {
    for (var i = 0; i < 4 && SheetDepth.value.value > 0; i++) {
      await t.tapAt(const Offset(200, 24));
      await settle(t, 700);
    }
  }

  testWidgets('tour', (t) async {
    final store = MullStore.memory()..loadSample();
    await t.pumpWidget(MullApp(store: store));
    await settle(t, 2500);

    // A build with no Supabase keys stops at the local-build notice first.
    // The tour runs through `flutter drive`, which passes no dart-defines.
    if (find.text('Continue on this phone').evaluate().isNotEmpty) {
      await tapText(t, 'Continue on this phone');
      await settle(t, 1200);
    }

    // ---- home, exactly as the mockup has it
    await shot(t, '01-home');

    // ---- the claim waiting on you
    await tapText(t, 'Check');
    await shot(t, '02-claim-check');
    await dismissSheet(t);

    // ---- rent, due again
    await t.tap(find.textContaining('Rent is due').hitTestable().last);
    await settle(t);
    await shot(t, '03-recurring-due');
    await dismissSheet(t);

    // ---- a group
    await tapText(t, 'Goa trip');
    await shot(t, '04-group-detail');

    await tapText(t, 'Add an expense');
    await t.enterText(find.byType(TextField).at(0), 'Scooter rental');
    await t.enterText(find.byType(TextField).at(1), '2400');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t);
    await shot(t, '05-add-expense');
    await tapText(t, 'Add it');
    await settle(t, 800);
    expect(
      store.groups.firstWhere((g) => g.name == 'Goa trip').expenses.map((e) => e.description),
      contains('Scooter rental'),
    );
    await shot(t, '06-group-after-expense');

    // ---- settling up, from the row that says who pays whom
    await t.ensureVisible(find.textContaining('→').first);
    await settle(t);
    await t.tap(find.textContaining('→').hitTestable().first);
    await settle(t);
    await shot(t, '07-settle-up');
    await dismissSheet(t);

    await t.tap(glyph(MullGlyph.chevronLeft));
    await settle(t);

    // ---- the flat, where the schedules live
    await tapText(t, 'Flat');
    await shot(t, '08-group-with-schedules');
    await t.ensureVisible(find.text('Manage'));
    await settle(t);
    await tapText(t, 'Manage');
    await shot(t, '09-recurring-list');
    await tapText(t, 'Wifi');
    await shot(t, '10-recurring-editor');
    await dismissSheet(t);
    await dismissSheet(t);
    await t.tap(glyph(MullGlyph.chevronLeft));
    await settle(t);

    // ---- chasing the people who owe you
    await t.ensureVisible(find.text('Remind'));
    await settle(t);
    await t.tap(find.text('Remind').hitTestable().last);
    await settle(t);
    await shot(t, '11-waiting-on');
    await dismissSheet(t);

    // ---- starting something new
    await tapText(t, 'Start a group');
    await shot(t, '12-start-a-group');
    await tapText(t, 'One person');
    await shot(t, '13-split-with-someone');
    await dismissSheet(t);

    // ---- the same walk again, in the dark
    await t.tap(find.bySemanticsLabel(RegExp('^Profile and settings')).hitTestable().last);
    await settle(t);
    await shot(t, '14-profile');
    await tapText(t, 'Dark');
    await shot(t, '15-profile-dark');
    await t.tap(glyph(MullGlyph.close));
    await settle(t);
    await shot(t, '01d-home-dark');

    await tapText(t, 'Goa trip');
    await shot(t, '04d-group-detail-dark');
    await tapText(t, 'Add an expense');
    await settle(t);
    await shot(t, '05d-add-expense-dark');
    await dismissSheet(t);
    await t.tap(glyph(MullGlyph.chevronLeft));
    await settle(t);

    await tapText(t, 'Flat');
    await t.ensureVisible(find.text('Manage'));
    await settle(t);
    await tapText(t, 'Manage');
    await shot(t, '09d-recurring-list-dark');
  });
}
