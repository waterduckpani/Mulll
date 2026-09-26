/// Which UPI app a payment opens.
///
/// Asked once, the first time it matters: someone with only PhonePe is never
/// asked anything, and someone with three apps picks one and is not asked
/// again. The choice lives on the profile screen after that.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/money.dart';
import '../core/upi.dart';
import '../data/store.dart';
import '../ui/page.dart';
import '../ui/sheet.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

/// The app to pay with, asking if it has to. Null if the picker was dismissed.
///
/// [ask] shows the picker even when a choice is saved — for the profile row.
Future<UpiApp?> chooseUpiApp(BuildContext context, {bool ask = false}) async {
  final store = context.readStore;
  final installed = await installedUpiApps();
  final saved = UpiApp.byKey(store.profile.payWith);
  if (!ask) {
    if (saved != null && (saved == UpiApp.any || installed.contains(saved))) return saved;
    // Nothing Mull knows by name. iOS may still have something for `upi:`.
    if (installed.isEmpty) return UpiApp.any;
    if (installed.length == 1) return installed.single;
  }
  if (!context.mounted) return null;
  final picked = await showMullSheet<UpiApp>(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(Gutter.text, 26, Gutter.text, 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pay with', style: MullType.screenTitle(sheet.c.ink)),
          const SizedBox(height: 8),
          Text(
            'Mull remembers this. Change it any time from your profile.',
            style: MullType.caption(sheet.c.ink3),
          ),
          const SizedBox(height: 16),
          CardRows(
            children: [
              for (final app in [...installed, UpiApp.any])
                SheetAction(
                  app.label,
                  detail: app == UpiApp.any
                      ? 'iPhone picks, sometimes WhatsApp'
                      : (app == saved ? 'current' : null),
                  onTap: () => Navigator.of(sheet).pop(app),
                ),
            ],
          ),
        ],
      ),
    ),
  );
  if (picked == null) return null;
  HapticFeedback.selectionClick();
  // Choosing again is also how someone asks for a filled-in payment back.
  store.updateProfile((p) => p
    ..payWith = picked.key
    ..payByHand = [...p.payByHand.where((k) => k != picked.key)]);
  return picked;
}

/// How a trip out to a UPI app ended, as far as Mull can tell — which is only
/// what the person says.
enum UpiOutcome {
  /// They say it went through.
  paid,

  /// It did not, or not yet.
  notPaid,

  /// No app would open at all.
  noApp,

  /// Backed out of choosing an app.
  cancelled,
}

/// Pays [name] over UPI, start to finish, and says how it went.
///
/// Opens the chosen app with the payment filled in, then asks. A UPI app can
/// refuse a filled-in payment — Paytm answers some links to a personal UPI ID
/// with "a technical error occurred" — so one of the answers is "it showed an
/// error". That copies the ID, opens the app blank for paying by hand, and
/// remembers the app so the next payment goes straight there.
Future<UpiOutcome> payOverUpi(
  BuildContext context, {
  required String upiId,
  required String name,
  required int amount,
  String? note,
}) async {
  final store = context.readStore;
  final app = await chooseUpiApp(context);
  if (app == null || !context.mounted) return UpiOutcome.cancelled;

  var byHand = store.profile.payByHand.contains(app.key);
  final opened = byHand
      ? await _payByHand(context, app, upiId: upiId, name: name, amount: amount)
      : await openUpiPayment(upiId: upiId, name: name, amount: amount, note: note, app: app);
  if (!opened) return UpiOutcome.noApp;
  if (!context.mounted) return UpiOutcome.cancelled;

  var answer = await _didItGoThrough(context, offerByHand: !byHand, app: app);
  if (answer == _Answer.error && context.mounted) {
    if (app != UpiApp.any) {
      store.updateProfile((p) => p.payByHand = {...p.payByHand, app.key}.toList());
    }
    byHand = true;
    if (!await _payByHand(context, app, upiId: upiId, name: name, amount: amount)) {
      return UpiOutcome.noApp;
    }
    if (!context.mounted) return UpiOutcome.cancelled;
    answer = await _didItGoThrough(context, offerByHand: false, app: app);
  }
  return answer == _Answer.paid ? UpiOutcome.paid : UpiOutcome.notPaid;
}

enum _Answer { paid, notYet, error }

/// Mull cannot see the UPI app, so the only honest thing is to ask.
Future<_Answer> _didItGoThrough(
  BuildContext context, {
  required bool offerByHand,
  required UpiApp app,
}) async {
  final answer = await showMullSheet<_Answer>(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(30, 28, 30, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Did it go through?', style: excon(28, tracking: -.02, color: sheet.c.ink)),
          const SizedBox(height: 10),
          Text(
            'Mull cannot see your UPI app, so it only records what you tell it.',
            style: ranade(13, height: 1.6, color: sheet.c.ink3),
          ),
          const SizedBox(height: 24),
          PillButton('Yes, I paid', onTap: () => Navigator.of(sheet).pop(_Answer.paid)),
          const SizedBox(height: 8),
          if (offerByHand) ...[
            SecondaryButton(
              app == UpiApp.any ? 'It showed an error' : '${app.label} showed an error',
              onTap: () => Navigator.of(sheet).pop(_Answer.error),
            ),
            const SizedBox(height: 8),
          ],
          SecondaryButton('Not yet', onTap: () => Navigator.of(sheet).pop(_Answer.notYet)),
        ],
      ),
    ),
  );
  return answer ?? _Answer.notYet;
}

/// Copies the UPI ID and opens [app] blank, after saying what to do there.
/// False if the app would not open.
Future<bool> _payByHand(
  BuildContext context,
  UpiApp app, {
  required String upiId,
  required String name,
  required int amount,
}) async {
  await Clipboard.setData(ClipboardData(text: upiId));
  if (!context.mounted) return false;
  final go = await showMullSheet<bool>(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(30, 28, 30, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pay ${inr(amount)} by hand', style: excon(28, tracking: -.02, color: sheet.c.ink)),
          const SizedBox(height: 10),
          Text(
            '${app == UpiApp.any ? 'Your UPI app' : app.label} would not take the '
            'payment filled in. ${name.split(' ').first}\'s UPI ID is copied: '
            'choose "Pay to UPI ID", paste it, and enter ${inr(amount)}.',
            style: ranade(13, height: 1.6, color: sheet.c.ink3),
          ),
          const SizedBox(height: 14),
          Text(upiId, style: ranade(15, color: sheet.c.ink)),
          const SizedBox(height: 24),
          PillButton(
            app == UpiApp.any ? 'Done' : 'Open ${app.label}',
            onTap: () => Navigator.of(sheet).pop(true),
          ),
        ],
      ),
    ),
  );
  if (go != true) return false;
  // "Any UPI app" has no app of its own to open. The ID is on the clipboard.
  if (app == UpiApp.any) return true;
  return openUpiAppBlank(app);
}
