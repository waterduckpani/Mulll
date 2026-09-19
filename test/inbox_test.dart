import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mull/core/inbox.dart';
import 'package:mull/data/models.dart';

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

  test('a shared screenshot runs through the screenshot parser', () async {
    mockInbox([
      {
        'kind': 'image',
        'lines': [
          line('zara.com', .04, .012),
          line('RIBBED KNIT CARDIGAN', .30, .030),
          line('₹3,590', .36, .034),
        ],
      },
    ]);

    final items = await Inbox.drain();
    expect(items, hasLength(1));
    final shot = items.single as SharedShot;
    // tidyTitle trims and truncates but never recases — Zara's shouty caps
    // survive into the sheet, where the user can edit them.
    expect(shot.read.name, 'RIBBED KNIT CARDIGAN');
    expect(shot.read.price, 3590);
    expect(shot.read.domain, 'zara.com');
  });

  test('an item settled in the share sheet arrives ready to add', () async {
    mockInbox([
      {
        'kind': 'resolved',
        'name': '  Ribbed knit cardigan ',
        'price': 3590,
        'itemKind': 'need',
        'url': 'https://www.zara.com/in/en/cardigan-p123.html',
      },
      {'kind': 'resolved', 'name': 'Filter coffee kit', 'price': 1850, 'itemKind': 'want'},
    ]);

    final items = await Inbox.drain();
    expect(items, hasLength(2));
    final first = items.first as SharedItem;
    expect(first.name, 'Ribbed knit cardigan', reason: 'the share sheet lets stray whitespace through');
    expect(first.price, 3590);
    expect(first.kind, ItemKind.need);
    expect(first.url, contains('zara.com'));
    expect((items.last as SharedItem).kind, ItemKind.want);
  });

  test('a half-finished resolved entry is dropped rather than added blind', () async {
    // These only exist because the user answered. A missing answer means the
    // extension should have queued the raw share instead, so trust nothing.
    mockInbox([
      {'kind': 'resolved', 'name': 'No price', 'itemKind': 'want'},
      {'kind': 'resolved', 'name': '  ', 'price': 900, 'itemKind': 'want'},
      {'kind': 'resolved', 'name': 'Free thing', 'price': 0, 'itemKind': 'want'},
    ]);
    expect(await Inbox.drain(), isEmpty);
  });

  test('an unknown kind defaults to a want rather than reserving budget', () async {
    mockInbox([
      {'kind': 'resolved', 'name': 'Mystery', 'price': 500},
    ]);
    expect((await Inbox.drain()).single, isA<SharedItem>());
    expect(((await Inbox.drain()).single as SharedItem).kind, ItemKind.want);
  });

  test('a UPI receipt is recognised as a payment, not a thing to buy', () async {
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

    final shot = (await Inbox.drain()).single as SharedShot;
    expect(shot.looksLikePayment, isTrue);
    expect(shot.receipt!.amount, 1240);
    expect(shot.receipt!.utr, '528401234567');
    expect(shot.receipt!.payeeUpiId, 'kabirv@ybl');
  });

  test('a product page is never mistaken for a payment', () async {
    mockInbox([
      {
        'kind': 'image',
        'lines': [
          line('zara.com', .04, .012),
          line('RIBBED KNIT CARDIGAN', .30, .030),
          line('₹3,590', .36, .034),
        ],
      },
    ]);

    final shot = (await Inbox.drain()).single as SharedShot;
    expect(shot.looksLikePayment, isFalse, reason: 'no reference and no payee');
    expect(shot.read.name, 'RIBBED KNIT CARDIGAN');
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

    final shot = (await Inbox.drain()).single as SharedShot;
    expect(shot.looksLikePayment, isFalse);
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

  test('shared text carrying a link becomes a link, not a name', () async {
    // Safari hands over "Product name https://…" as a single string.
    mockInbox([
      {'kind': 'text', 'text': 'Ribbed cardigan https://www.zara.com/in/en/cardigan-p123.html'},
    ]);

    final item = (await Inbox.drain()).single;
    expect(item, isA<SharedLink>());
    expect((item as SharedLink).url, contains('zara.com'));
  });

  test('shared text with no link stays a name', () async {
    mockInbox([
      {'kind': 'text', 'text': 'Ribbed knit cardigan'},
    ]);

    final item = (await Inbox.drain()).single;
    expect(item, isA<SharedText>());
    expect((item as SharedText).text, 'Ribbed knit cardigan');
  });

  test('blank and unknown entries are skipped without killing the drain', () async {
    mockInbox([
      {'kind': 'text', 'text': '   '},
      {'kind': 'something-new'},
      {'kind': 'link'}, // malformed: no url
      {'kind': 'link', 'url': 'https://allbirds.in/products/wool-runner'},
    ]);

    final items = await Inbox.drain();
    expect(items, hasLength(1));
    expect((items.single as SharedLink).url, contains('allbirds'));
  });

  test('order is preserved so shares arrive as they were made', () async {
    mockInbox([
      {'kind': 'link', 'url': 'https://example.com/one'},
      {'kind': 'link', 'url': 'https://example.com/two'},
      {'kind': 'link', 'url': 'https://example.com/three'},
    ]);

    final urls = (await Inbox.drain()).map((i) => (i as SharedLink).url).toList();
    expect(urls, [
      'https://example.com/one',
      'https://example.com/two',
      'https://example.com/three',
    ]);
  });

  test('a device without the extension installed drains to nothing', () async {
    // invokeMethod throws MissingPluginException when nothing answers.
    mockInbox(null);
    expect(await Inbox.drain(), isEmpty);
  });
}
