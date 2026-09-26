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
///
/// Spaces go as `%20`. Dart's query encoding writes them as `+`, the form
/// convention, and several UPI apps show that literally: "Sahil+Mehra",
/// "Goa+trip". A real plus in a name is already `%2B`, so every `+` left in
/// the string was a space.
Uri upiPaymentUri({required String upiId, required String name, required int amount, String? note}) {
  final formEncoded = Uri(
    scheme: 'upi',
    host: 'pay',
    queryParameters: {
      'pa': upiId.trim(),
      'pn': name.trim(),
      // Two decimal places, as the UPI linking spec writes it. Several PSP
      // apps read a bare "1240" fine and a few refuse it as malformed.
      'am': '$amount.00',
      'cu': 'INR',
      if (note != null && note.trim().isNotEmpty) 'tn': note.trim(),
    },
  );
  return Uri.parse(formEncoded.toString().replaceAll('+', '%20'));
}

/// A UPI app Mull can hand a payment to directly.
///
/// `upi://pay` lets iOS choose, and iOS does not choose well: WhatsApp
/// registers the scheme too, and on plenty of phones it wins over the
/// PhonePe or Paytm the person actually pays with. Each app's own scheme
/// takes the same query and goes straight to that app.
class UpiApp {
  const UpiApp(this.key, this.label, this.prefix);

  /// Stored in the profile. Never change one once shipped.
  final String key;
  final String label;

  /// Everything before the `?`. The query is the standard UPI one.
  final String prefix;

  /// iOS's pick among whatever registered `upi:`. Last resort, and what the
  /// app did for everyone before.
  static const any = UpiApp('any', 'Any UPI app', 'upi://pay');

  /// Order is the order in the picker. Every scheme here must also be listed
  /// under LSApplicationQueriesSchemes in Info.plist, or iOS answers "not
  /// installed" whatever the truth.
  static const all = [
    UpiApp('gpay', 'Google Pay', 'tez://upi/pay'),
    UpiApp('phonepe', 'PhonePe', 'phonepe://pay'),
    UpiApp('paytm', 'Paytm', 'paytmmp://pay'),
    UpiApp('cred', 'CRED', 'credpay://upi/pay'),
    UpiApp('bhim', 'BHIM', 'bhim://upi/pay'),
    UpiApp('fampay', 'FamPay', 'fampay://upi/pay'),
  ];

  static UpiApp? byKey(String? key) =>
      key == any.key ? any : all.where((a) => a.key == key).firstOrNull;

  Uri uriFor(Uri payment) => Uri.parse('$prefix?${payment.query}');

  /// The app itself, nothing filled in. Null for [any], which is not an app.
  Uri? get home => key == any.key ? null : Uri.parse('${prefix.split('://').first}://');
}

/// The UPI apps on this phone, in picker order. Empty on the simulator.
Future<List<UpiApp>> installedUpiApps() async {
  final found = <UpiApp>[];
  for (final app in UpiApp.all) {
    try {
      if (await canLaunchUrl(Uri.parse('${app.prefix.split('://').first}://'))) found.add(app);
    } catch (_) {
      // Not listed in Info.plist, or no answer. Treated as not installed.
    }
  }
  return found;
}

/// Opens [app] (iOS's choice if null) with the payment filled in.
///
/// False means no app could take it — on a phone with none installed, or on the
/// simulator. The caller should fall back to showing the ID rather than
/// pretending the payment happened.
Future<bool> openUpiPayment({
  required String upiId,
  required String name,
  required int amount,
  String? note,
  UpiApp? app,
}) async {
  final payment = upiPaymentUri(upiId: upiId, name: name, amount: amount, note: note);
  final uri = app == null || app.key == UpiApp.any.key ? payment : app.uriFor(payment);
  try {
    if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return true;
  } catch (_) {
    // Fall through to letting iOS choose.
  }
  if (uri == payment) return false;
  try {
    return await launchUrl(payment, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

/// Opens [app] with nothing filled in, for paying by hand.
Future<bool> openUpiAppBlank(UpiApp app) async {
  final home = app.home;
  if (home == null) return false;
  try {
    return await launchUrl(home, mode: LaunchMode.externalApplication);
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
