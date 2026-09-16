import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mull/screens/wishlist/add_sheet.dart';
import 'package:mull/ui/tokens.dart';

void main() {
  const channel = MethodChannel('mull/screenshot');

  Map<String, Object?> line(String text, double y, double h) => {
    'text': text,
    'x': 0.0,
    'y': y,
    'w': .5,
    'h': h,
    'conf': 1.0,
  };

  /// Stands in for the picker + Vision, which only exist on a real device.
  void mockPicker(Object? payload) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'pick' ? payload : null,
    );
  }

  Future<void> pumpSheet(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(390, 844)); // a real phone, so overflows show up
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        theme: buildTheme(MullColors.light),
        home: const Scaffold(
          body: AddSheet(title: 'Add something', cta: 'Save it', askKind: true),
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 400)); // the sheet's autofocus timer
    await t.pumpAndSettle();
  }

  tearDown(() => mockPicker(null));

  testWidgets('offers the screenshot route', (t) async {
    mockPicker(null);
    await pumpSheet(t);
    expect(find.text('Scan a screenshot'), findsOneWidget);
  });

  testWidgets('a scanned screenshot fills in the name and the price', (t) async {
    mockPicker({
      'lines': [
        line('zara.com', .05, .014),
        line('SATIN EFFECT SHIRT', .61, .021),
        line('₹ 3,950', .655, .019),
        line('ADD TO BASKET', .90, .018),
      ],
    });
    await pumpSheet(t);

    await t.tap(find.text('Scan a screenshot'));
    await t.pumpAndSettle();

    expect(find.text('SATIN EFFECT SHIRT'), findsOneWidget);
    expect(find.text('₹3,950'), findsOneWidget);
    expect(find.text('Read from zara.com'), findsOneWidget);
    expect(find.text('Scan a screenshot'), findsNothing);
  });

  testWidgets('backing out of the picker leaves the sheet untouched', (t) async {
    mockPicker(null);
    await pumpSheet(t);

    await t.tap(find.text('Scan a screenshot'));
    await t.pumpAndSettle();

    expect(find.text('Scan a screenshot'), findsOneWidget);
    expect(find.text("What's it called?"), findsOneWidget);
  });
}
