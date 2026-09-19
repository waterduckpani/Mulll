/// Paying people back, the way it actually happens in India.
///
/// Mull never touches the money. It hands the UPI app a filled-in payment and
/// gets out of the way — which is the whole trick, because the alternative is
/// screenshotting a balance and retyping the amount into GPay.
library;

import 'package:url_launcher/url_launcher.dart';

/// `nobody@bank` — deliberately loose. Banks and PSPs invent new handles
/// constantly, and rejecting a valid one is worse than accepting a typo the
/// UPI app will reject anyway.
final _upiId = RegExp(r'^[a-zA-Z0-9.\-_]{2,256}@[a-zA-Z]{2,64}$');

bool isUpiId(String value) => _upiId.hasMatch(value.trim());

/// A payment, pre-filled. `am` is rupees; `tn` is the note the payee sees.
Uri upiPaymentUri({required String upiId, required String name, required int amount, String? note}) {
  return Uri(
    scheme: 'upi',
    host: 'pay',
    queryParameters: {
      'pa': upiId.trim(),
      'pn': name.trim(),
      'am': amount.toString(),
      'cu': 'INR',
      if (note != null && note.trim().isNotEmpty) 'tn': note.trim(),
    },
  );
}

/// Opens GPay, PhonePe, Paytm or whichever UPI app is installed.
///
/// False means no app could take it — on a phone with none installed, or on the
/// simulator. The caller should fall back to showing the ID rather than
/// pretending the payment happened.
Future<bool> openUpiPayment({
  required String upiId,
  required String name,
  required int amount,
  String? note,
}) async {
  final uri = upiPaymentUri(upiId: upiId, name: name, amount: amount, note: note);
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Hands [text] to WhatsApp with the message already written.
///
/// Group logistics in India live in WhatsApp, so a summary that cannot be
/// pasted there is a summary nobody sees.
///
/// With a [phone] it opens that person's chat directly, which is what turns a
/// reminder from "compose a message" into "press send". Without one it opens
/// the contact picker, so a nudge still works for someone whose number Mull
/// has never been told.
Future<bool> shareOnWhatsApp(String text, {String? phone}) async {
  final number = phone?.replaceAll(RegExp(r'[^0-9]'), '');
  final uri = Uri.https('wa.me', '/${number ?? ''}', {'text': text});
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
