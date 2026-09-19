import 'package:flutter/services.dart';

import '../data/models.dart';
import 'link_reader.dart';
import 'screenshot_reader.dart';
import 'upi_receipt.dart';

/// Something the user shared into Mull from another app.
sealed class InboxItem {
  const InboxItem();
}

/// Already sorted out in the share sheet — name, price and kind all settled.
///
/// Nothing to ask, so nothing is asked: these are added straight to the
/// wishlist. Approving twenty items one sheet at a time is the thing the share
/// sheet exists to avoid.
final class SharedItem extends InboxItem {
  const SharedItem({required this.name, required this.price, required this.kind, this.url});

  final String name;
  final int price;
  final ItemKind kind;
  final String? url;
}

/// A screenshot, already recognised on the native side.
///
/// Read two ways, because pixels do not say what they are. The same image
/// might be a product page worth putting on the wishlist, or a UPI receipt
/// worth settling a debt with — so both readings are carried and whoever has
/// the ledger to hand decides which one it is.
final class SharedShot extends InboxItem {
  const SharedShot(this.read, {this.receipt});

  final ScreenshotRead read;
  final UpiReceipt? receipt;

  /// Enough of a payment to be worth checking against what you owe.
  bool get looksLikePayment =>
      receipt != null &&
      !receipt!.failed &&
      receipt!.amount != null &&
      (receipt!.utr != null || receipt!.payeeUpiId != null);
}

/// A product URL — [LinkReader] may still be able to fetch the real title.
final class SharedLink extends InboxItem {
  const SharedLink(this.url);

  final String url;
}

/// Shared text that had no URL in it. Usually a product name someone copied.
final class SharedText extends InboxItem {
  const SharedText(this.text);

  final String text;
}

/// The queue the share extension writes to.
///
/// Two kinds of entry arrive. A [SharedItem] was settled in the share sheet and
/// needs nothing from us. Everything else is a raw share the user did not stop
/// to triage, and is still read here by the same [ScreenshotReader] and
/// [LinkReader] the in-app add flow uses — so the parser with the test suite
/// stays the one that decides, and the extension's Swift guess only ever
/// prefills a field the user was looking at.
class Inbox {
  static const _channel = MethodChannel('mull/screenshot');

  /// Everything shared since the app was last open, oldest first. Reading is
  /// destructive — the native side deletes each entry as it hands it over, so
  /// a share is never offered twice.
  static Future<List<InboxItem>> drain() async {
    final List<Object?>? raw;
    try {
      raw = await _channel.invokeMethod<List<Object?>>('drain');
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
    if (raw == null) return const [];

    final items = <InboxItem>[];
    for (final entry in raw) {
      final map = (entry as Map).cast<Object?, Object?>();
      final item = _parse(map);
      if (item != null) items.add(item);
    }
    return items;
  }

  static InboxItem? _parse(Map<Object?, Object?> map) {
    switch (map['kind'] as String?) {
      case 'resolved':
        final name = (map['name'] as String?)?.trim();
        final price = (map['price'] as num?)?.toInt();
        if (name == null || name.isEmpty || price == null || price <= 0) return null;
        return SharedItem(
          name: name,
          price: price,
          kind: map['itemKind'] == 'need' ? ItemKind.need : ItemKind.want,
          url: map['url'] as String?,
        );

      case 'image':
        final lines = [
          for (final line in (map['lines'] as List? ?? const []))
            OcrLine.fromMap((line as Map).cast<Object?, Object?>()),
        ];
        final read = ScreenshotReader.parse(lines, thumb: map['thumb'] as Uint8List?);
        final receipt = UpiReceiptReader.parse(lines);
        // A screenshot of a page we could read nothing from is worse than
        // nothing — it opens an empty sheet the user has to dismiss. A receipt
        // counts as something even when there is no product name in sight.
        if (read.isEmpty && receipt.isEmpty) return null;
        return SharedShot(read, receipt: receipt.isEmpty ? null : receipt);

      case 'link':
        final url = map['url'] as String?;
        return url == null ? null : SharedLink(url);

      case 'text':
        final text = (map['text'] as String?)?.trim();
        if (text == null || text.isEmpty) return null;
        // Share sheets often hand over "Product name https://…" as one string.
        final url = LinkReader.extractUrl(text);
        return url != null ? SharedLink(url) : SharedText(text);

      default:
        return null;
    }
  }
}
