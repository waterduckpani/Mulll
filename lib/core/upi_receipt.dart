/// Reading a UPI payment receipt out of a screenshot.
///
/// The awkward part of splitting money was never the arithmetic — it is the
/// loop afterwards. "Did you send it?" "Yeah, ages ago." "I never got it."
/// A receipt has an amount, a reference number and a payee in it, so the claim
/// can carry its own evidence instead of being one person's word.
///
/// Every field is a guess off pixels, so nothing here settles anything on its
/// own: it fills in a claim that the person owed still has to confirm.
library;

import 'money.dart';
import 'ocr.dart';

class UpiReceipt {
  const UpiReceipt({this.amount, this.utr, this.payeeUpiId, this.payeeName, this.failed = false});

  final int? amount;

  /// The UPI reference — 12 digits, printed by every app as "UTR", "UPI
  /// transaction ID" or just a bare number under the amount.
  final String? utr;
  final String? payeeUpiId;
  final String? payeeName;

  /// The screenshot says the payment did not go through. Worth knowing: a
  /// failed payment shared as proof is a mistake, not a lie, and telling
  /// someone so beats silently recording a payment that never happened.
  final bool failed;

  bool get isEmpty => amount == null && utr == null;
}

class UpiReceiptReader {
  /// Money on a receipt is nearly always written with the symbol.
  static final _amount = RegExp(r'(?:₹|rs\.?|inr)\s*([\d][\d,]*(?:\.\d{1,2})?)', caseSensitive: false);

  /// A 12-digit UPI reference, with or without a label. Bounded on both sides
  /// so a phone number or an order id does not get mistaken for one.
  static final _labelledUtr = RegExp(
    r'(?:utr|rrn|upi\s*(?:transaction\s*)?(?:id|ref(?:erence)?)|transaction\s*id)\D{0,12}(\d{9,22})',
    caseSensitive: false,
  );
  static final _bareUtr = RegExp(r'(?<!\d)(\d{12})(?!\d)');

  static final _vpa = RegExp(r'\b([a-z0-9.\-_]{2,256}@[a-z]{2,64})\b', caseSensitive: false);

  static final _failed = RegExp(
    r'\b(failed|failure|unsuccessful|declined|cancelled|canceled|pending)\b',
    caseSensitive: false,
  );
  static final _succeeded = RegExp(
    r'\b(paid|success(?:ful)?|completed|sent|debited)\b',
    caseSensitive: false,
  );

  /// Lines that name the payer rather than the payee.
  static final _fromish = RegExp(r'\b(from|debited from|paid by|sender)\b', caseSensitive: false);

  static UpiReceipt parse(List<OcrLine> lines) {
    final failed = lines.any((l) => _failed.hasMatch(l.text)) && !lines.any((l) => _succeeded.hasMatch(l.text));

    return UpiReceipt(
      amount: _amount3(lines),
      utr: _utr(lines),
      payeeUpiId: _payee(lines),
      payeeName: _payeeName(lines),
      failed: failed,
    );
  }

  /// The biggest money-looking number. On a receipt the amount is the hero —
  /// every UPI app sets it several times larger than anything else.
  static int? _amount3(List<OcrLine> lines) {
    int? best;
    var bestHeight = 0.0;
    for (final line in lines) {
      for (final match in _amount.allMatches(line.text)) {
        final value = parseAmount(match.group(1)!);
        if (value == null) continue;
        if (best == null || line.h > bestHeight) {
          best = value;
          bestHeight = line.h;
        }
      }
    }
    return best;
  }

  static String? _utr(List<OcrLine> lines) {
    for (final line in lines) {
      final labelled = _labelledUtr.firstMatch(line.text);
      if (labelled != null) return labelled.group(1);
    }
    // Unlabelled: the reference is usually the only bare 12-digit run on the
    // screen, and it is never the amount because that carries a symbol.
    for (final line in lines) {
      if (_amount.hasMatch(line.text)) continue;
      final bare = _bareUtr.firstMatch(line.text);
      if (bare != null) return bare.group(1);
    }
    return null;
  }

  /// The VPA the money went to, skipping any line that is naming the payer.
  static String? _payee(List<OcrLine> lines) {
    String? fallback;
    for (final line in lines) {
      final match = _vpa.firstMatch(line.text);
      if (match == null) continue;
      final vpa = match.group(1)!.toLowerCase();
      if (_fromish.hasMatch(line.text)) {
        fallback ??= vpa;
        continue;
      }
      return vpa;
    }
    return fallback;
  }

  /// "To Sahil Mehta" / "Paid to Sahil Mehta".
  static final _toName = RegExp(r'^\s*(?:paid\s+to|to|payee)\s*[:\-]?\s*(.{2,60})$', caseSensitive: false);

  static String? _payeeName(List<OcrLine> lines) {
    for (final line in lines) {
      final match = _toName.firstMatch(line.text.trim());
      if (match == null) continue;
      final name = match.group(1)!.trim();
      // "To 9876543210@ybl" is the VPA, already captured; a name is letters.
      if (_vpa.hasMatch(name) || name.replaceAll(RegExp(r'[^A-Za-z]'), '').length < 2) continue;
      return name;
    }
    return null;
  }
}
