import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mull/screens/friends_sheet.dart';
import 'package:mull/ui/tokens.dart';

void main() {
  testWidgets('a report needs a reason before it can be sent, and blocks by default', (t) async {
    t.view.physicalSize = const Size(1179, 2556);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);

    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(MullColors.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showReportSheet(context, name: 'Kabir', userId: 'u1'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();

    expect(find.text('REPORT KABIR'), findsOneWidget);
    expect(t.takeException(), isNull, reason: 'no overflow on a 6.1" phone');

    bool sendEnabled() {
      final pill = find.ancestor(of: find.text('Send report'), matching: find.byWidgetPredicate((w) => w is GestureDetector || w is InkWell));
      return pill.evaluate().any((e) {
        final w = e.widget;
        return (w is GestureDetector && w.onTap != null) || (w is InkWell && w.onTap != null);
      });
    }

    expect(sendEnabled(), isFalse);
    await t.tap(find.text('Spam or a scam'));
    await t.pump();
    expect(find.byIcon(Icons.check), findsOneWidget);
    expect(sendEnabled(), isTrue);

    final toggle = t.widget<Switch>(find.byType(Switch));
    expect(toggle.value, isTrue);
  });
}
