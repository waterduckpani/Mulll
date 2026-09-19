/// Things shared into Mull from other apps.
///
/// One thing, now: a UPI receipt. You pay Sahil back in GPay, share the
/// confirmation screen into Mull, and the claim arrives carrying the amount and
/// the reference off the payment itself — so the person owed is confirming
/// evidence rather than taking your word for it.
///
/// The reading happens here rather than in the share extension, so the parser
/// with the test suite behind it is the one that decides.
library;

import 'package:flutter/services.dart';

import 'ocr.dart';
import 'upi_receipt.dart';

/// A screenshot that read as a payment.
class SharedReceipt {
  const SharedReceipt(this.receipt);

  final UpiReceipt receipt;

  /// Enough of a payment to be worth checking against what you owe.
  ///
  /// An amount alone is not enough — a photo of a price tag has one of those.
  /// A reference or a payee is what makes it a receipt.
  bool get isUsable =>
      !receipt.failed && receipt.amount != null && (receipt.utr != null || receipt.payeeUpiId != null);
}

class Inbox {
  static const _channel = MethodChannel('mull/screenshot');

  /// Everything shared since the app was last open, oldest first.
  ///
  /// Reading is destructive — the native side deletes each entry as it hands it
  /// over, so a share is never offered twice.
  static Future<List<SharedReceipt>> drain() async {
    final List<Object?>? raw;
    try {
      raw = await _channel.invokeMethod<List<Object?>>('drain');
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      // No share extension on this build or this device. Not an error.
      return const [];
    }
    if (raw == null) return const [];

    final items = <SharedReceipt>[];
    for (final entry in raw) {
      final item = _parse((entry as Map).cast<Object?, Object?>());
      if (item != null) items.add(item);
    }
    return items;
  }

  /// Anything that is not an image is dropped without ceremony. A shared link
  /// or a line of text has nowhere to go now that Mull is only groups, and
  /// opening a sheet to say so would be worse than silence.
  static SharedReceipt? _parse(Map<Object?, Object?> map) {
    if (map['kind'] != 'image') return null;
    final lines = [
      for (final line in (map['lines'] as List? ?? const []))
        OcrLine.fromMap((line as Map).cast<Object?, Object?>()),
    ];
    if (lines.isEmpty) return null;
    final receipt = UpiReceiptReader.parse(lines);
    if (receipt.isEmpty) return null;
    return SharedReceipt(receipt);
  }
}
