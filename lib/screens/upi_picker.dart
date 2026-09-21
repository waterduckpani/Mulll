/// Which UPI app a payment opens.
///
/// Asked once, the first time it matters: someone with only PhonePe is never
/// asked anything, and someone with three apps picks one and is not asked
/// again. The choice lives on the profile screen after that.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  store.updateProfile((p) => p.payWith = picked.key);
  return picked;
}

/// Opens the chosen UPI app with the payment filled in. Null if the person
/// backed out of choosing; false if no app would take it.
Future<bool?> payOverUpi(
  BuildContext context, {
  required String upiId,
  required String name,
  required int amount,
  String? note,
}) async {
  final app = await chooseUpiApp(context);
  if (app == null) return null;
  return openUpiPayment(upiId: upiId, name: name, amount: amount, note: note, app: app);
}
