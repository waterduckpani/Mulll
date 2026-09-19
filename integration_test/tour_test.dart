import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mull/data/store.dart';
import 'package:mull/main.dart';
import 'package:mull/ui/icons.dart';
import 'package:mull/ui/sheet.dart';

/// Walks every screen with the mockup data, screenshotting each one.
///
/// Run: flutter drive --driver=test_driver/integration_test.dart \
///        --target=integration_test/tour_test.dart
///
/// Note for anyone changing this file: a target that fails to compile makes
/// `flutter drive` silently run the *previous* build, so a green run after an
/// edit proves nothing until `flutter analyze` is clean too.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  Future<void> settle(WidgetTester t, [int ms = 900]) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Finder glyph(MullGlyph g) =>
      find.byWidgetPredicate((w) => w is MullIcon && w.glyph == g).hitTestable().last;

  Future<void> tapText(WidgetTester t, String text) async {
    await t.tap(find.text(text).hitTestable().last);
    await settle(t);
  }

  Future<void> shot(WidgetTester t, String name) async {
    await settle(t, 400);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await t.pump();
    await binding.takeScreenshot(name);
  }

  /// Backs out of every open sheet by tapping the scrim above them.
  Future<void> dismissSheet(WidgetTester t) async {
    for (var i = 0; i < 4 && SheetDepth.value.value > 0; i++) {
      await t.tapAt(const Offset(200, 24));
      await settle(t, 700);
    }
  }

  Future<void> back(WidgetTester t) async {
    await t.tap(glyph(MullGlyph.chevronLeft));
    await settle(t, 700);
  }

  testWidgets('tour', (t) async {
    final store = MullStore.memory()..loadSample();
    await t.pumpWidget(MullApp(store: store));
    await settle(t, 2500);

    // A build with no Supabase keys stops at the local-build notice first.
    // The tour runs through `flutter drive`, which passes no dart-defines.
    if (find.text('Continue on this phone').evaluate().isNotEmpty) {
      await tapText(t, 'Continue on this phone');
      await settle(t, 1500);
    }

    // ---- 4A, the groups home
    await shot(t, '01-home');

    // ---- the claim waiting on you
    await tapText(t, 'Check');
    await shot(t, '02-claim-check');
    await dismissSheet(t);

    // ---- a schedule whose turn has come
    await t.tap(find.text('Open it').hitTestable().first);
    await settle(t);
    await shot(t, '03-recurring-due');
    await dismissSheet(t);

    // ---- 4D, a group
    await tapText(t, 'Goa trip');
    await shot(t, '04-group-detail');

    // ---- 4E, settling up, and the sheet a row opens
    await tapText(t, 'Settle up');
    await shot(t, '05-settle-up');
    await tapText(t, 'Kabir pays you');
    await shot(t, '05b-settle-sheet');
    await dismissSheet(t);
    await back(t);

    // ---- 4F, the ledger, both tabs
    await tapText(t, 'Ledger');
    await shot(t, '06-ledger-expenses');
    await tapText(t, 'Settlements');
    await shot(t, '07-ledger-settlements');
    await back(t);

    // ---- adding an expense
    await tapText(t, 'Add an expense');
    await t.enterText(find.byType(TextField).at(0), 'Kayaking');
    await t.enterText(find.byType(TextField).at(1), '2600');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t);
    await shot(t, '08-add-expense');
    await tapText(t, 'Add it');
    await settle(t, 900);
    expect(
      store.groups.firstWhere((g) => g.name == 'Goa trip').expenses.map((e) => e.description),
      contains('Kayaking'),
    );
    await shot(t, '09-group-after-expense');
    await back(t);

    // ---- 4G, the flat, where the schedules live
    await tapText(t, 'Flat');
    await tapText(t, 'Recurring');
    await shot(t, '10-recurring');

    // ---- 4H, editing a standing cost
    await tapText(t, 'Flat maintenance');
    await shot(t, '11-recurring-editor');
    await dismissSheet(t);
    await back(t);
    await back(t);

    // ---- chasing the people who owe you
    //
    // A drag rather than ensureVisible: a ListView builds its children lazily,
    // so a row below the fold is not in the tree for a finder to find yet.
    await t.drag(find.byType(Scrollable).last, const Offset(0, -420));
    await settle(t, 800);
    await t.tap(find.text('Remind').hitTestable().last);
    await settle(t);
    await shot(t, '12-waiting-on');
    await dismissSheet(t);

    // ---- 4B and 4C, starting something new
    await tapText(t, 'Start a group');
    await settle(t, 800);
    await shot(t, '13-name-the-group');
    await t.enterText(find.byType(TextField).first, 'Ski trip');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t);
    await tapText(t, 'Next');
    await settle(t, 800);
    await shot(t, '14-whos-in');
    await back(t);
    await settle(t, 600);
    await t.tap(glyph(MullGlyph.close));
    await settle(t, 900);

    // ---- the group's own settings
    await tapText(t, 'Goa trip');
    await t.tap(find.bySemanticsLabel('Group settings').hitTestable().last);
    await settle(t);
    await shot(t, '14b-group-settings');
    await dismissSheet(t);
    await back(t);

    // ---- the profile
    await t.tap(find.bySemanticsLabel(RegExp('^Profile and settings')).hitTestable().last);
    await settle(t);
    await shot(t, '15-profile');
    await tapText(t, 'How Mull works');
    await shot(t, '15b-how-it-works');
    await dismissSheet(t);
    await t.tap(find.bySemanticsLabel(RegExp('^Profile and settings')).hitTestable().last);
    await settle(t);
    await tapText(t, 'Light');
    await shot(t, '16-profile-light');
    await tapText(t, 'Dark');
    await settle(t);
    await t.tap(glyph(MullGlyph.close));
    await settle(t, 900);

    // ---- and the screen an app with nothing in it shows
    store
      ..groups.clear()
      ..refresh();
    await settle(t, 1600);
    await shot(t, '17-empty-home');
  });
}
