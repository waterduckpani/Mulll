import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mull/data/store.dart';
import 'package:mull/main.dart';

/// Walks the way in, screenshotting each step.
///
/// Run: flutter drive --driver=test_driver/integration_test.dart \
///        --target=integration_test/onboarding_test.dart
///
/// `flutter drive` passes no dart-defines, so this runs as a build with no
/// server behind it. That build skips the email and code steps, because there
/// is no account to make: what is left is the welcome, the two things Mull
/// needs to know about you, and the way in.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  Future<void> settle(WidgetTester t, [int ms = 900]) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> shot(WidgetTester t, String name) async {
    await settle(t, 500);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await t.pump();
    await binding.takeScreenshot(name);
  }

  Future<void> tapText(WidgetTester t, String text) async {
    await t.tap(find.text(text).hitTestable().last);
    await settle(t);
  }

  testWidgets('the way in', (t) async {
    final store = MullStore.memory();
    await t.pumpWidget(MullApp(store: store));
    await settle(t, 2200);

    if (find.text('Continue on this phone').evaluate().isNotEmpty) {
      await shot(t, 'onb-0-local-build');
      await tapText(t, 'Continue on this phone');
      await settle(t, 1600);
    }

    await shot(t, 'onb-1-welcome');

    await tapText(t, 'Get started');
    await settle(t, 900);
    await shot(t, 'onb-2-name');

    await t.enterText(find.byType(TextField).first, 'Bharat');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t);
    await shot(t, 'onb-3-name-filled');

    await tapText(t, 'Continue');
    await settle(t, 900);
    await shot(t, 'onb-4-upi');

    await t.enterText(find.byType(TextField).first, 'bharat@okhdfcbank');
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t);
    await shot(t, 'onb-5-upi-filled');

    await tapText(t, 'Continue');
    await settle(t, 1200);
    await shot(t, 'onb-6-ready');

    expect(store.profile.name, 'Bharat');
    expect(store.profile.upiId, 'bharat@okhdfcbank');
    expect(
      store.profile.onboarded,
      isFalse,
      reason: 'the flag is what the root watches, so flipping it here would '
          'replace this screen before anyone saw it',
    );

    await tapText(t, 'Take me in');
    await settle(t, 1800);
    expect(store.profile.onboarded, isTrue);
    await shot(t, 'onb-7-first-run');
  });
}
