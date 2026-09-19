import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mull/core/inbox.dart';

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

  /// Stands in for the share extension plus Vision, which only exist on device.
  void mockInbox(Object? payload) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'drain' ? payload : null,
    );
  }

  setUp(() => TestWidgetsFlutterBinding.ensureInitialized());
  tearDown(() => mockInbox(null));

  test('an empty queue yields nothing', () async {
    mockInbox(<Object?>[]);
    expect(await Inbox.drain(), isEmpty);
  });

  test('a UPI receipt comes through with its amount, payee and reference', () async {
    mockInbox([
      {
        'kind': 'image',
        'lines': [
          line('Payment Successful', .14, .018),
          line('₹1,240', .23, .044),
          line('Paid to KABIR VERMA', .31, .015),
          line('kabirv@ybl', .35, .012),
          line('UTR: 528401234567', .55, .012),
        ],
      },
    ]);

    final shared = (await Inbox.drain()).single;
    expect(shared.isUsable, isTrue);
    expect(shared.receipt.amount, 1240);
    expect(shared.receipt.utr, '528401234567');
    expect(shared.receipt.payeeUpiId, 'kabirv@ybl');
    expect(shared.receipt.payeeName, 'KABIR VERMA');
  });

  test('a price tag is not a receipt', () async {
    // An amount on its own proves nothing — a photo of a menu has one of those.
    // A reference or a payee is what makes it a payment.
    mockInbox([
      {
        'kind': 'image',
        'lines': [
          line('RIBBED KNIT CARDIGAN', .30, .030),
          line('₹3,590', .36, .034),
        ],
      },
    ]);

    final shared = (await Inbox.drain()).single;
    expect(shared.isUsable, isFalse, reason: 'no reference and no payee');
  });

  test('a failed payment is not offered as a settlement', () async {
    mockInbox([
      {
        'kind': 'image',
        'lines': [
          line('Payment Failed', .14, .018),
          line('₹1,240', .23, .044),
          line('kabirv@ybl', .35, .012),
        ],
      },
    ]);

    expect((await Inbox.drain()).single.isUsable, isFalse);
  });

  test('a screenshot nothing could be read from is dropped, not offered', () async {
    // An empty sheet the user has to dismiss is worse than no prompt at all.
    mockInbox([
      {
        'kind': 'image',
        'lines': [line('9:41', .01, .012)],
      },
    ]);
    expect(await Inbox.drain(), isEmpty);
  });

  test('links and text are dropped now that Mull is only groups', () async {
    // The share extension can still queue these. There is nowhere for them to
    // go, and opening a sheet to say so would be worse than silence.
    mockInbox([
      {'kind': 'text', 'text': 'Ribbed knit cardigan'},
      {'kind': 'link', 'url': 'https://www.zara.com/in/en/cardigan-p123.html'},
      {'kind': 'resolved', 'name': 'Cardigan', 'price': 3590},
    ]);
    expect(await Inbox.drain(), isEmpty);
  });

  test('a malformed entry is skipped without killing the drain', () async {
    mockInbox([
      {'kind': 'something-new'},
      {'kind': 'image'}, // no lines at all
      {
        'kind': 'image',
        'lines': [
          line('₹900', .2, .04),
          line('UTR 528401234567', .5, .012),
        ],
      },
    ]);

    final items = await Inbox.drain();
    expect(items, hasLength(1));
    expect(items.single.receipt.amount, 900);
  });

  test('order is preserved so shares arrive as they were made', () async {
    Map<String, Object?> receipt(int amount, String utr) => {
      'kind': 'image',
      'lines': [line('₹$amount', .2, .04), line('UTR $utr', .5, .012)],
    };

    mockInbox([
      receipt(100, '111111111111'),
      receipt(200, '222222222222'),
      receipt(300, '333333333333'),
    ]);

    expect((await Inbox.drain()).map((i) => i.receipt.amount), [100, 200, 300]);
  });

  test('a device without the extension installed drains to nothing', () async {
    // invokeMethod throws MissingPluginException when nothing answers.
    mockInbox(null);
    expect(await Inbox.drain(), isEmpty);
  });
}
