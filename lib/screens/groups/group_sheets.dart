import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/split.dart';
import '../../core/upi.dart';
import '../upi_picker.dart';
import '../../data/models.dart';
import '../../data/remote/auth_service.dart';
import '../../data/remote/friends_service.dart';
import '../../data/remote/notices_service.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'icon_picker.dart';
import 'recurring_sheets.dart';
import 'split_editor.dart';

/// The group creation flow lives in `create_group_flow.dart` now: naming a
/// thing and deciding who is in it are two questions, and a sheet that asks
/// both at once is a form.

// ------------------------------------------------------------- add an expense

Future<void> showAddExpense(BuildContext context, Group group, {Expense? existing}) => showMullSheet(
  context,
  // This sheet grows with the group — every member is another row in the
  // split. Ask for most of the screen so a normal-sized group is visible
  // without scrolling; the sheet clamps itself to what the phone has.
  height: 880,
  builder: (_) => _ExpenseSheet(group: group, existing: existing),
);

/// Keeps whatever has focus above the keyboard.
///
/// The sheet asks for 880 points and a small phone with the keyboard up has
/// nothing like that, so the split rows sat underneath it: you could tap a
/// person's amount field and not see what you were typing. The scroll view
/// needs the inset as padding, which is all this is.
double _keyboardInset(BuildContext context) => MediaQuery.viewInsetsOf(context).bottom;

class _ExpenseSheet extends StatefulWidget {
  const _ExpenseSheet({required this.group, this.existing});

  final Group group;
  final Expense? existing;

  @override
  State<_ExpenseSheet> createState() => _ExpenseSheetState();
}

class _ExpenseSheetState extends State<_ExpenseSheet> {
  late final _description = TextEditingController(text: widget.existing?.description ?? '');
  late final _amount = AmountController(widget.existing?.amount);
  late final _note = TextEditingController(text: widget.existing?.note ?? '');
  final _amountFocus = FocusNode();

  late final SplitModel _split;
  late DateTime _date;

  /// Offered only when adding: turning an expense that already exists into a
  /// schedule would leave the two silently out of step.
  bool _repeats = false;
  Frequency _frequency = Frequency.monthly;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _date = existing?.date ?? context.readStore.now();
    _split = SplitModel(
      group: widget.group,
      payerId: existing?.payerId,
      method: existing?.method ?? SplitMethod.equal,
      shares: existing?.shares,
      amount: existing?.amount ?? 0,
    )..addListener(_onSplitChanged);

    _description.addListener(() => setState(() {}));
    _amount.addListener(() {
      _split.amount = _amount.amount ?? 0;
      setState(() {});
    });
    _amountFocus.addListener(() {
      if (!_amountFocus.hasFocus) _amount.tidy();
      setState(() {});
    });
  }

  void _onSplitChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    _note.dispose();
    _amountFocus.dispose();
    _split
      ..removeListener(_onSplitChanged)
      ..dispose();
    super.dispose();
  }

  bool get _valid => _description.text.trim().isNotEmpty && _amount.amount != null && _split.isValid;

  /// The rupee figure, when what was typed had paise in it.
  int? get _rounded {
    final typed = double.tryParse(_amount.text.replaceAll(RegExp(r'[^0-9.]'), ''));
    final amount = _amount.amount;
    if (typed == null || amount == null) return null;
    return typed == typed.roundToDouble() ? null : amount;
  }

  void _save() {
    final store = context.readStore;
    final existing = widget.existing;
    final note = _note.text.trim();

    if (existing != null) {
      // Kept so the notice can say what actually moved: "₹500 → ₹5,000" is the
      // sentence the other people in the split need, not "something changed".
      final before = Expense(
        id: existing.id,
        description: existing.description,
        amount: existing.amount,
        payerId: existing.payerId,
        shares: Map.of(existing.shares),
        method: existing.method,
        date: existing.date,
      );
      existing
        ..description = _description.text.trim()
        ..amount = _amount.amount!
        ..payerId = _split.payerId
        ..shares = _split.shares
        ..method = _split.method
        ..note = note.isEmpty ? null : note
        ..date = _date;
      store.updateExpense(widget.group, existing, before: before);
    } else {
      store.addExpense(
        widget.group,
        description: _description.text.trim(),
        amount: _amount.amount!,
        payerId: _split.payerId,
        shares: _split.shares,
        method: _split.method,
        note: note,
        date: _date,
      );
      if (_repeats) {
        store.addRecurring(
          widget.group,
          description: _description.text.trim(),
          amount: _amount.amount!,
          payerId: _split.payerId,
          shares: _split.shares,
          method: _split.method,
          frequency: _frequency,
          startsOn: _frequency.next(_date),
        );
      }
    }
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
  }

  Future<void> _pickDate() async {
    final store = context.readStore;
    final picked = await showMullDatePicker(
      context,
      initial: _date,
      first: DateTime(store.now().year - 3),
      last: dayOf(store.now()).add(const Duration(days: 365)),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(widget.existing == null ? 'Add an expense' : 'Edit expense'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(30, 12, 30, 24 + _keyboardInset(context)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigField(
                  controller: _description,
                  autofocus: widget.existing == null,
                  hint: 'What was it?',
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _amountFocus.requestFocus(),
                ),
                const SizedBox(height: 22),
                BigField(
                  controller: _amount,
                  focusNode: _amountFocus,
                  numeric: true,
                  hint: '₹0',
                  trailing: Text('total bill', style: ranade(11.5, color: c.ink3)),
                  // Mull keeps whole rupees on purpose — nobody settles 33.33
                  // over UPI — but rounding somebody's 499.50 up without a
                  // word is the app changing a number they typed.
                  help: _rounded == null ? null : Text('Rounded to ${inr(_rounded!)}. Mull keeps whole rupees.'),
                ),
                const SizedBox(height: 18),
                _RowButton(
                  label: 'When',
                  value: daysBetween(_date, store.now()) == 0 ? 'Today' : shortDateWithYear(_date, store.now()),
                  onTap: _pickDate,
                ),
                const SizedBox(height: 26),
                SplitFields(model: _split),
                const SizedBox(height: 22),
                BigField(
                  controller: _note,
                  size: 16,
                  hint: 'Note (optional)',
                  capitalization: TextCapitalization.sentences,
                ),
                if (widget.existing == null) ...[
                  const SizedBox(height: 24),
                  CheckRow(
                    on: _repeats,
                    label: 'This happens again',
                    onTap: () => setState(() => _repeats = !_repeats),
                    help:
                        'Rent, wifi, the maid. Mull puts it on a schedule and asks '
                        'when it comes round. It never adds one behind your back '
                        'unless you tell it to.',
                  ),
                  if (_repeats) ...[
                    const SizedBox(height: 16),
                    _FrequencyPicker(
                      value: _frequency,
                      onChanged: (f) => setState(() => _frequency = f),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Next one ${relativeDay(_frequency.next(_date), store.now())}.',
                      style: ranade(11.5, color: c.ink3),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, keyboardUp ? 4 : 30),
          child: PillButton(widget.existing == null ? 'Add it' : 'Save', onTap: _valid ? _save : null),
        ),
      ],
    );
  }
}

/// A label with a tappable value on the right — "When · Today".
class _RowButton extends StatelessWidget {
  const _RowButton({required this.label, required this.value, required this.onTap});

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .99,
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: ranade(15, color: c.ink2)),
            ),
            Text(value, style: excon(16, color: c.ink)),
            const SizedBox(width: 8),
            MullIcon(MullGlyph.chevronRight, size: 15, color: c.ink3, strokeWidth: 1.7),
          ],
        ),
      ),
    );
  }
}

class _FrequencyPicker extends StatelessWidget {
  const _FrequencyPicker({required this.value, required this.onChanged});

  final Frequency value;
  final ValueChanged<Frequency> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final f in Frequency.values) NameChip(f.label, selected: f == value, onTap: () => onChanged(f)),
    ],
  );
}

// ---------------------------------------------------------------- settle up

/// Records [transfer] as paid, offering UPI first.
Future<void> showSettleUp(BuildContext context, Group group, Transfer transfer) => showMullSheet(
  context,
  fitContent: true,
  builder: (_) => _SettleSheet(group: group, transfer: transfer),
);

class _SettleSheet extends StatefulWidget {
  const _SettleSheet({required this.group, required this.transfer});

  final Group group;
  final Transfer transfer;

  @override
  State<_SettleSheet> createState() => _SettleSheetState();
}

class _SettleSheetState extends State<_SettleSheet> {
  late final AmountController _amount = AmountController(widget.transfer.amount)..addListener(() => setState(() {}));

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  int get _max => widget.transfer.amount;
  int? get _value => _amount.amount;
  bool get _valid => _value != null && _value! > 0 && _value! <= _max;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final group = widget.group;
    final transfer = widget.transfer;
    final from = group.memberById(transfer.from);
    final to = group.memberById(transfer.to);
    if (from == null || to == null) return const SizedBox.shrink();

    final youPay = from.isYou;
    final owedToYou = to.isYou;
    // Somebody else's debt is theirs to settle. This sheet used to offer
    // "Mark as settled" on it to anybody in the group. Two people who are both
    // not on Mull are the exception: nobody else could ever write it down.
    final forThem = !youPay && !owedToYou;
    if (forThem && (from.isLinked || to.isLinked)) return const SizedBox.shrink();
    final payee = to;
    final part = _valid && _value! < _max;

    void record() {
      store.settleUp(group, fromId: from.id, toId: to.id, amount: _value!);
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop();
      Toast.show(
        context,
        part ? '${inr(_value!)} recorded · ${inr(_max - _value!)} left' : '${inr(_value!)} settled',
      );
    }

    Future<void> payWithUpi() async {
      final upi = payee.upiId;
      if (upi == null) return;
      final outcome = await payOverUpi(
        context,
        upiId: upi,
        name: payee.name,
        amount: _value!,
        note: group.title,
      );
      if (!context.mounted) return;
      switch (outcome) {
        case UpiOutcome.paid:
          record();
        case UpiOutcome.noApp:
          Toast.show(
            context,
            'No UPI app could open that',
            action: 'Copy ID',
            onAction: () => Clipboard.setData(ClipboardData(text: upi)),
          );
        case UpiOutcome.notPaid || UpiOutcome.cancelled:
          break;
      }
    }

    /// Chases them inside Mull, not in a chat app. Twice a day, counted on the
    /// server — the cap is the feature here as much as the reminder is.
    Future<void> remind() async {
      Navigator.of(context).pop();
      await remindMember(context, group, from, transfer.amount);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(switch (null) {
            _ when youPay => 'You owe ${store.shortName(to)}',
            _ when forThem => '${store.shortName(from)} owes ${store.shortName(to)}',
            _ => '${store.shortName(from)} owes you',
          }),
          const SizedBox(height: 12),
          // An editable amount, because "I will send you 500 of the 1,800 now"
          // is the most ordinary sentence in splitting money and Mull had no
          // way to write it down. Prefilled with the whole debt, which is what
          // most people are here to clear.
          BigField(
            controller: _amount,
            numeric: true,
            hint: '₹0',
            size: 40,
            trailing: _value != _max
                ? Pressable(
                    onTap: () {
                      _amount.text = _max.toString();
                      setState(() {});
                    },
                    child: Text('All of it', style: ranade(12.5, color: c.ink2)),
                  )
                : Text('of ${inr(_max)}', style: ranade(11.5, color: c.ink3)),
          ),
          const SizedBox(height: 12),
          Text(
            switch (null) {
              _ when _value == null => 'How much is actually changing hands.',
              _ when _value! > _max => 'That is more than the ${inr(_max)} outstanding here.',
              _ when part => '${inr(_max - _value!)} would still be open.',
              _ when youPay => 'To ${to.name}${payee.upiId == null ? '' : ' · ${payee.upiId}'}',
              // Money coming to you is the case the old copy got wrong: it is
              // not "between them", it is between them and you.
              _ when owedToYou && !from.isLinked =>
                '${store.shortName(from)} is not on Mull. Settle in person, then '
                    'mark it here.',
              _ when forThem =>
                'Neither of them is on Mull. Mark it once they tell you it is done.',
              _ =>
                'They pay you straight over UPI. Mark it here once it lands, or '
                    'wait for them to say they have sent it.',
            },
            style: ranade(13, height: 1.5, color: c.ink3),
          ),
          const SizedBox(height: 22),
          if (youPay && payee.upiId != null) ...[
            PillButton(
              _valid ? 'Pay ${inr(_value!)} over UPI' : 'Pay over UPI',
              onTap: _valid ? payWithUpi : null,
            ),
            const SizedBox(height: 8),
            SecondaryButton('Already paid, just record it', onTap: _valid ? record : null),
          ] else ...[
            PillButton('Mark as settled', onTap: _valid ? record : null),
            if (youPay) ...[
              const SizedBox(height: 8),
              SecondaryButton(
                'Add their UPI ID',
                onTap: () {
                  Navigator.of(context).pop();
                  showMemberSheet(context, group, payee);
                },
              ),
            ],
            // Chasing is the other half of settling up, and it is the half
            // Mull can actually help with when the money is coming to you.
            if (owedToYou) ...[
              const SizedBox(height: 8),
              SecondaryButton('Remind ${store.shortName(from)}', onTap: remind),
            ],
          ],
        ],
      ),
    );
  }
}

/// "Sahil says he sent you ₹2,400" — the Check button on the home screen.
///
/// Only the person owed can say the money arrived, so this is the one place a
/// balance actually moves on somebody's say-so, and it is the right somebody.
Future<void> showClaimCheck(BuildContext context, Group group, Settlement settlement) {
  final store = context.readStore;
  final from = group.memberById(settlement.fromId);

  return showMullSheet(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow('${from == null ? 'Someone' : store.shortName(from)} says they paid you'),
          const SizedBox(height: 10),
          Text(inr(settlement.amount), style: excon(44, tracking: -.03, color: sheet.c.ink)),
          const SizedBox(height: 10),
          Text(
            [
              group.title,
              if (settlement.utr != null) 'UPI ref ${settlement.utr}',
              'claimed ${daysAgo(settlement.date, store.now())}',
            ].join(' · '),
            style: ranade(12.5, height: 1.55, color: sheet.c.ink3),
          ),
          const SizedBox(height: 14),
          Text(
            'Check your bank or UPI app. Until you say it arrived, they still owe it.',
            style: ranade(12.5, height: 1.6, color: sheet.c.ink3),
          ),
          const SizedBox(height: 22),
          PillButton(
            'It arrived',
            onTap: () {
              store.confirmSettlement(group, settlement);
              HapticFeedback.mediumImpact();
              Navigator.of(sheet).pop();
              Toast.show(context, '${inr(settlement.amount)} settled');
            },
          ),
          const SizedBox(height: 8),
          SecondaryButton(
            "It hasn't",
            onTap: () {
              store.disputeSettlement(group, settlement);
              Navigator.of(sheet).pop();
              Toast.show(context, 'Marked as not received');
            },
          ),
        ],
      ),
    ),
  );
}

/// A claim you said never arrived, when it has.
///
/// Disputing used to be a one-way door. The claim stopped being pending, so
/// every list that could have acted on it dropped it, and the only way back
/// was deleting the evidence. A transfer held up for two days and then found
/// is an ordinary thing, and it should cost nobody their record of it.
Future<void> showDisputedSettlement(
  BuildContext context,
  Group group,
  Settlement settlement,
) {
  final store = context.readStore;
  final from = group.memberById(settlement.fromId);
  final name = from == null ? 'They' : store.shortName(from);

  return showMullSheet(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('You said this never arrived'),
          const SizedBox(height: 10),
          Text(inr(settlement.amount), style: excon(44, tracking: -.03, color: sheet.c.ink)),
          const SizedBox(height: 10),
          Text(
            [
              '$name · ${group.title}',
              if (settlement.utr != null) 'UPI ref ${settlement.utr}',
              'claimed ${daysAgo(settlement.date, store.now())}',
            ].join(' · '),
            style: ranade(12.5, height: 1.55, color: sheet.c.ink3),
          ),
          const SizedBox(height: 14),
          Text(
            'The debt is still standing. If the money has turned up since, say '
            'so and it clears.',
            style: ranade(12.5, height: 1.6, color: sheet.c.ink3),
          ),
          const SizedBox(height: 22),
          PillButton(
            'It arrived after all',
            onTap: () {
              store.confirmSettlement(group, settlement);
              HapticFeedback.mediumImpact();
              Navigator.of(sheet).pop();
              Toast.show(context, '${inr(settlement.amount)} settled');
            },
          ),
          const SizedBox(height: 8),
          SecondaryButton(
            'Still nothing · ask again',
            onTap: () {
              store.reopenSettlement(group, settlement);
              Navigator.of(sheet).pop();
              Toast.show(context, 'Back to waiting on $name');
            },
          ),
        ],
      ),
    ),
  );
}

/// A claim you made, from your side of it.
///
/// Says plainly where it has got to and gives you the two things you can
/// actually do: chase them, or take it back. Neither was reachable before —
/// an unconfirmed claim simply sat there, and a disputed one had nowhere at
/// all to go.
Future<void> showOwnClaim(BuildContext context, Group group, Settlement settlement) {
  final store = context.readStore;
  final to = group.memberById(settlement.toId);
  final disputed = settlement.status == SettlementStatus.disputed;
  final name = to == null ? 'They' : store.shortName(to);
  final standing = to == null ? null : store.standingWith(to);
  final canNudge = standing == null || store.nudgesLeft(standing) > 0;

  return showMullSheet(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(disputed ? '$name says it never arrived' : 'Waiting on $name'),
          const SizedBox(height: 10),
          Text(inr(settlement.amount), style: excon(44, tracking: -.03, color: sheet.c.ink)),
          const SizedBox(height: 10),
          Text(
            [
              group.title,
              if (settlement.utr != null) 'UPI ref ${settlement.utr}',
              'claimed ${daysAgo(settlement.date, store.now())}',
            ].join(' · '),
            style: ranade(12.5, height: 1.55, color: sheet.c.ink3),
          ),
          const SizedBox(height: 14),
          Text(
            disputed
                ? 'They have looked and not found it. Until this is sorted out '
                      'the debt is still standing, so it is worth checking the '
                      'reference against your bank.'
                : 'The debt stands until they say the money landed. If it has '
                      'been a while, a nudge is the polite version of asking.',
            style: ranade(12.5, height: 1.6, color: sheet.c.ink3),
          ),
          const SizedBox(height: 22),
          if (to != null && canNudge)
            PillButton(
              'Ask $name to confirm',
              onTap: () {
                Navigator.of(sheet).pop();
                remindMember(context, group, to, settlement.amount, claim: settlement);
              },
            )
          else if (to != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                "You've nudged $name twice today. You can again tomorrow.",
                textAlign: TextAlign.center,
                style: MullType.caption(sheet.c.ink3),
              ),
            ),
          const SizedBox(height: 8),
          SecondaryButton(
            'Take this claim back',
            onTap: () {
              Navigator.of(sheet).pop();
              confirmRemoveSettlement(context, group, settlement);
            },
          ),
        ],
      ),
    ),
  );
}

/// Taking a payment off the record, with the consequence said out loud.
///
/// It used to be an unannounced long-press that deleted instantly, available
/// to anybody in the group including people the payment had nothing to do
/// with. Removing a confirmed one puts a debt back between two people, which
/// is not something to do by accident on the way past.
Future<void> confirmRemoveSettlement(
  BuildContext context,
  Group group,
  Settlement settlement,
) {
  final store = context.readStore;
  final refusal = store.whySettlementStays(group, settlement);
  if (refusal != null) {
    Toast.show(context, refusal);
    return Future.value();
  }

  final from = group.memberById(settlement.fromId);
  final to = group.memberById(settlement.toId);
  String name(Member? m) => m == null ? 'someone' : store.shortName(m);

  return showMullSheet(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(30, 28, 30, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            settlement.offset ? 'Undo this netting off?' : 'Remove this payment?',
            style: excon(28, tracking: -.02, color: sheet.c.ink),
          ),
          const SizedBox(height: 12),
          Text(
            switch (null) {
              _ when settlement.offset =>
                'This cancelled ${inr(settlement.amount)} against another '
                    'ledger. Removing it puts both sides of that back.',
              _ when settlement.clearsDebt =>
                '${inr(settlement.amount)} from ${name(from)} to ${name(to)} is '
                    'recorded as paid. Taking it off means that debt is open '
                    'again, for both of you.',
              _ =>
                'This claim has not been confirmed, so no balance moves. It '
                    'simply stops being on the record.',
            },
            style: ranade(13.5, height: 1.6, color: sheet.c.ink3),
          ),
          const SizedBox(height: 26),
          PillButton(
            'Remove it',
            onTap: () {
              Navigator.of(sheet).pop();
              if (!store.removeSettlement(group, settlement)) return;
              HapticFeedback.mediumImpact();
              Toast.show(
                context,
                'Payment removed',
                action: 'Undo',
                onAction: () => store.restoreSettlement(group, settlement),
              );
            },
          ),
          const SizedBox(height: 8),
          SecondaryButton('Keep it', onTap: () => Navigator.of(sheet).pop()),
        ],
      ),
    ),
  );
}

/// Chases one person about one debt, in the group it belongs to — or, with a
/// [claim], asks them to confirm money you say you sent.
///
/// Counted against the same two-a-day allowance as a nudge from the person
/// sheet. It used to count nothing locally, so the button stayed live and every
/// tap after the second went to the server just to be refused.
Future<void> remindMember(
  BuildContext context,
  Group group,
  Member member,
  int amount, {
  Settlement? claim,
}) async {
  final store = context.readStore;
  final userId = member.userId;
  final standing = store.standingWith(member);
  final name = store.shortName(member);

  if (standing != null && store.nudgesLeft(standing) == 0) {
    Toast.show(context, "You've nudged $name twice today. You can again tomorrow.");
    return;
  }

  if (userId == null) {
    // No account behind that seat, so there is no inbox to reach. WhatsApp is
    // the honest fallback rather than a button that does nothing.
    final message = [
      'Hey $name, ${inr(amount)} for ${group.title} when you get a chance.',
      if (store.profile.upiId != null) 'My UPI is ${store.profile.upiId}.',
    ].join(' ');
    final sent = await shareOnWhatsApp(message, phone: member.phone);
    if (!context.mounted) return;
    if (sent && standing != null) store.markNudged(standing);
    Toast.show(context, sent ? '$name is not on Mull — sent on WhatsApp' : "Couldn't open WhatsApp");
    return;
  }

  final me = store.profile.name.trim().split(' ').first;
  final outcome = await NoticesService.remind(
    toUserId: userId,
    groupId: group.id,
    // A confirmation nudge is not a debt reminder. Worded as one, it told the
    // person you had just paid that they owed you the same amount.
    title: claim != null
        ? '$me is waiting for you to confirm ${inr(amount)}'
        : '$me is waiting on ${inr(amount)}',
    body: claim != null ? 'Check it landed, then confirm it in ${group.title}' : group.title,
    amount: amount,
  );
  if (!context.mounted) return;
  switch (outcome) {
    case ReminderOutcome.sent:
      if (standing != null) store.markNudged(standing);
      Toast.show(context, 'Nudged $name');
    case ReminderOutcome.outOfTurns:
      if (standing != null) store.spendNudges(standing);
      Toast.show(context, "That's both of today's nudges. Try again tomorrow.");
    case ReminderOutcome.failed:
      Toast.show(context, "Couldn't send that. Check your connection.");
  }
}

/// Puts the group's state into WhatsApp as plain text.
Future<void> shareGroupSummary(BuildContext context, Group group) async {
  final store = context.readStore;
  final sent = await shareOnWhatsApp(store.groupSummary(group));
  if (!context.mounted) return;
  if (!sent) Toast.show(context, "Couldn't open WhatsApp");
}

// ------------------------------------------------------------------- member

/// One person in a group.
///
/// Someone on Mull is read-only here: their name and UPI ID come from their
/// own account, and the only person who should ever type a payment address is
/// the one being paid. A seat nobody has claimed yet can be named, given an
/// address to invite, and given a UPI ID. An admin also gets the group's
/// decisions about this person — make them an admin, take them out — on the
/// same tap rather than behind a long-press nobody found.
Future<void> showMemberSheet(BuildContext context, Group group, Member member) => showMullSheet(
  context,
  height: member.isLinked && !member.isYou ? 560 : 640,
  builder: (_) => _MemberSheet(group: group, member: member),
);

class _MemberSheet extends StatefulWidget {
  const _MemberSheet({required this.group, required this.member});

  final Group group;
  final Member member;

  @override
  State<_MemberSheet> createState() => _MemberSheetState();
}

class _MemberSheetState extends State<_MemberSheet> {
  late final _name = TextEditingController(text: widget.member.name);
  late final _upi = TextEditingController(text: widget.member.upiId ?? '');
  late final _email = TextEditingController(text: widget.member.email ?? '');

  Member get member => widget.member;
  Group get group => widget.group;

  /// Nothing to type: their details are their account's.
  bool get _readOnly => member.isLinked && !member.isYou;

  @override
  void initState() {
    super.initState();
    _upi.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _upi.dispose();
    _email.dispose();
    super.dispose();
  }

  void _save() {
    final store = context.readStore;
    final name = _name.text.trim();
    if (member.isYou) {
      // Your seat's name is your account's name — the pull takes it from the
      // profile, so changing only the seat snapped back twenty seconds later.
      if (name.isNotEmpty && name != store.profile.name) {
        store.updateProfile((p) => p.name = name);
        unawaited(AuthService.saveProfile(name: name));
      }
    } else if (name.isNotEmpty) {
      member.name = name;
    }
    if (!member.isYou) {
      final email = _email.text.trim().toLowerCase();
      final before = member.email;
      member.email = email.isEmpty ? null : email;
      // A seat is claimed by its address only into a group where the person
      // has accepted somebody as a friend. Asking them is what makes the
      // address mean anything, and it is them saying yes — not you typing it —
      // that puts this group's balances on their phone.
      if (email.isNotEmpty && email != before) {
        unawaited(FriendsService.request(email));
      }
    }
    store.setUpiId(member, _upi.text);
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
  }

  /// Runs [action] once this sheet is gone, so a toast lands on the screen
  /// behind rather than on a sheet that is closing.
  void _then(VoidCallback action) {
    Navigator.of(context).pop();
    Future.delayed(const Duration(milliseconds: 160), action);
  }

  Widget? _adminActions(BuildContext context) {
    final store = context.readStore;
    if (!group.youAreAdmin || group.isDirect || member.isYou) return null;
    final outer = Navigator.of(context).context;
    final lastAdmin = member.isAdmin && group.admins.length < 2;
    final why = store.whyMemberStays(group, member);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CardRows(
          children: [
            if (member.isLinked)
              SheetAction(
                member.isAdmin ? 'Remove as admin' : 'Make an admin',
                detail: lastAdmin ? 'last admin' : (member.isAdmin ? null : 'can add people'),
                onTap: () => _then(() {
                  final wasAdmin = member.isAdmin;
                  if (store.setAdmin(group, member, !wasAdmin)) {
                    HapticFeedback.mediumImpact();
                    Toast.show(
                      outer,
                      wasAdmin
                          ? '${store.shortName(member)} is no longer an admin'
                          : '${store.shortName(member)} can run this group now',
                    );
                  } else {
                    Toast.show(outer, 'A group needs at least one admin');
                  }
                }),
              ),
            SheetAction(
              'Remove from group',
              destructive: true,
              detail: why == null ? null : 'not possible',
              onTap: () => _then(() {
                if (store.removeMember(group, member)) {
                  HapticFeedback.mediumImpact();
                  Toast.show(outer, 'Removed ${store.shortName(member)}');
                } else if (why != null) {
                  Toast.show(outer, why);
                }
              }),
            ),
          ],
        ),
        if (why != null) ...[
          const SizedBox(height: 12),
          Text(why, style: MullType.caption(context.c.ink3)),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final typed = _upi.text.trim();
    final looksRight = typed.isEmpty || isUpiId(typed);
    final admin = _adminActions(context);

    final Widget body;
    if (_readOnly) {
      final upi = member.upiId;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            member.isAdmin && !group.isDirect ? 'On Mull · admin of this group' : 'On Mull',
            style: MullType.caption(c.ink3),
          ),
          const SizedBox(height: 18),
          // Label above value, not beside it: a UPI ID is long, and squeezed
          // into the right half of a row it was cut off at the "@" — the
          // part that says which bank.
          Pressable(
            onTap: upi == null
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: upi));
                    HapticFeedback.selectionClick();
                    Toast.show(context, 'UPI ID copied');
                  },
            scale: .99,
            child: Container(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 18),
              decoration: BoxDecoration(color: c.quiet, borderRadius: BorderRadius.circular(22)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Their UPI ID', style: ranade(12.5, color: c.ink3)),
                  const SizedBox(height: 6),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(upi ?? 'Not added yet', style: excon(18, color: upi == null ? c.ink3 : c.ink)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            upi == null
                ? 'They add it from their own profile. Mull never asks you for someone else\'s.'
                : 'From their own account, so it is the one they get paid at. Tap to copy.',
            style: MullType.caption(c.ink3),
          ),
          if (admin != null) ...[const SizedBox(height: 26), admin],
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BigField(controller: _name, hint: 'Name'),
          if (!member.isYou) ...[
            const SizedBox(height: 26),
            BigField(
              controller: _email,
              size: 20,
              hint: 'their@email.com',
              keyboardType: TextInputType.emailAddress,
              help: Text(
                'Optional. They get a friend request, and once they accept, this '
                'seat becomes theirs with everything already in it.',
                style: ranade(12, height: 1.5, color: c.ink3),
              ),
            ),
          ],
          const SizedBox(height: 26),
          BigField(
            controller: _upi,
            size: 20,
            hint: 'name@bank',
            help: Text(
              looksRight
                  ? (member.isYou
                        ? 'Goes into the summaries you send, so people can pay you back.'
                        : 'Only until they join. Then it comes from their own account.')
                  : "That doesn't look like a UPI ID. They usually read name@bank.",
              style: ranade(12, height: 1.5, color: c.ink3),
            ),
          ),
          if (admin != null) ...[const SizedBox(height: 26), admin],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(member.isYou ? 'You' : member.name),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 16),
            child: body,
          ),
        ),
        if (!_readOnly)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
            child: PillButton('Save', onTap: looksRight ? _save : null),
          ),
      ],
    );
  }
}

// -------------------------------------------------------------------- leave

/// Asks, then leaves. True once you are out, on the server as well.
///
/// When something stands in the way, it says what, rather than showing a
/// greyed-out button and leaving you to guess.
Future<bool> confirmLeaveGroup(BuildContext context, Group group) async {
  final store = context.readStore;
  final why = store.whyYouCannotLeave(group);
  final open = store.openOnLeaving(group);
  final confirmed = await showMullSheet<bool>(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(30, 30, 30, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            why == null ? 'Leave ${group.title}?' : 'Not just yet',
            style: excon(28, tracking: -.02, color: sheet.c.ink),
          ),
          const SizedBox(height: 10),
          Text(
            why ??
                'It disappears from your phone. Everyone else keeps the group, '
                    'and the expenses you were part of stay in it under your name.',
            style: ranade(14, height: 1.6, color: sheet.c.ink3),
          ),
          // Leaving is allowed with money open, and it clears none of it. Said
          // plainly, with the names, before and not after.
          if (why == null && open.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              [
                for (final (other, amount) in open)
                  amount > 0
                      ? '${store.shortName(other)} still owes you ${inr(amount)}'
                      : 'You still owe ${store.shortName(other)} ${inr(-amount)}',
              ].join('\n'),
              style: ranade(14, height: 1.6, color: sheet.c.ink),
            ),
            const SizedBox(height: 10),
            Text(
              'Leaving does not clear this. It stays in the group, they are told '
              'you left, and it is between you to settle.',
              style: ranade(13, height: 1.6, color: sheet.c.ink3),
            ),
          ],
          const SizedBox(height: 24),
          if (why == null) ...[
            PillButton(
              open.isEmpty ? 'Leave it' : 'Leave anyway',
              onTap: () => Navigator.of(sheet).pop(true),
            ),
            const SizedBox(height: 8),
            SecondaryButton('Stay', onTap: () => Navigator.of(sheet).pop(false)),
          ] else
            PillButton('OK', onTap: () => Navigator.of(sheet).pop(false)),
        ],
      ),
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  final left = await store.leaveGroupEverywhere(group);
  if (!context.mounted) return left;
  if (left) {
    HapticFeedback.mediumImpact();
    Toast.show(context, 'You left ${group.title}');
  } else {
    Toast.show(context, "Couldn't reach Mull. Try again in a moment.");
  }
  return left;
}

// ----------------------------------------------------------------- settings

/// A plain label with a value and a chevron, for a row that leaves the sheet.
class _SettingsRow extends StatelessWidget {
  const _SettingsRow({required this.label, required this.value, required this.onTap});

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .985,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 18, 18),
        decoration: surfaceOf(c, Lift.flat, radius: BorderRadius.circular(22)),
        child: Row(
          children: [
            Expanded(child: Text(label, style: MullType.cardTitle(c.ink, size: 16))),
            Text(value, style: MullType.caption(c.ink3)),
            const SizedBox(width: 10),
            MullIcon(MullGlyph.chevronRight, size: 14, color: c.ink3, strokeWidth: 1.8),
          ],
        ),
      ),
    );
  }
}

/// Resolves to 'deleted' when the group was removed, 'people' when the caller
/// should open the members screen, or 'add-recurring' when it should open the
/// schedule editor — each once this sheet is out of the way.
Future<String?> showGroupSettings(BuildContext context, Group group) =>
    showMullSheet<String>(context, height: 700, builder: (_) => _GroupSettingsSheet(group: group));

class _GroupSettingsSheet extends StatefulWidget {
  const _GroupSettingsSheet({required this.group});

  final Group group;

  @override
  State<_GroupSettingsSheet> createState() => _GroupSettingsSheetState();
}

class _GroupSettingsSheetState extends State<_GroupSettingsSheet> {
  late final _name = TextEditingController(text: widget.group.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _apply() {
    if (_name.text.trim().isNotEmpty) widget.group.name = _name.text.trim();
    context.readStore.updateGroup(widget.group);
  }

  Future<void> _delete() async {
    final store = context.readStore;
    final nav = Navigator.of(context);
    final group = widget.group;
    final confirmed = await showMullSheet<bool>(
      context,
      fitContent: true,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(30, 30, 30, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Delete ${group.title}?', style: excon(28, tracking: -.02, color: sheet.c.ink)),
            const SizedBox(height: 10),
            Text(
              [
                'Every expense goes with it.',
                // The part the old copy left out, and the part that matters:
                // this is not "remove it from my phone". A group deleted here
                // disappears for everyone in it, including the history they
                // were relying on.
                if (group.members.length > 1) 'It goes for everyone in it, not just you.',
                if (!group.isSettled) 'This one is not settled up yet.',
              ].join(' '),
              style: ranade(14, height: 1.6, color: sheet.c.ink3),
            ),
            const SizedBox(height: 24),
            PillButton('Delete it', onTap: () => Navigator.of(sheet).pop(true)),
            const SizedBox(height: 8),
            SecondaryButton('Keep it', onTap: () => Navigator.of(sheet).pop(false)),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    store.deleteGroup(group);
    nav.pop('deleted');
    if (mounted) {
      Toast.show(context, 'Deleted ${group.title}', action: 'Undo', onAction: () => store.restoreGroup(group));
    }
  }

  Future<void> _leave() async {
    final nav = Navigator.of(context);
    // The group screen behind treats this the same as a delete: the group is
    // gone from this phone either way.
    if (await confirmLeaveGroup(context, widget.group)) nav.pop('deleted');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final group = widget.group;
    final admin = group.youAreAdmin;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(group.isDirect ? 'This ledger' : 'Group'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!group.isDirect) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 16),
                        child: IconWell(
                          iconKey: group.icon,
                          size: 44,
                          glyphSize: 21,
                          onTap: admin
                              ? () async {
                                  await pickGroupIcon(context, group);
                                  if (mounted) setState(() {});
                                }
                              : null,
                        ),
                      ),
                      Expanded(
                        child: BigField(
                          controller: _name,
                          hint: 'Name',
                          // Typing into a field that silently refuses to save
                          // is worse than not offering it, and the server
                          // refuses a rename from anyone who is not an admin.
                          onChanged: admin ? (_) => _apply() : null,
                          help: admin
                              ? null
                              : Text(
                                  'Only an admin can rename this group or change its icon.',
                                  style: ranade(12, height: 1.5, color: c.ink3),
                                ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                ],
                // People have a screen of their own now. This used to be the
                // only place membership lived, which meant a row of chips was
                // carrying roles, balances and removal all at once.
                _SettingsRow(
                  label: group.isDirect ? 'The two of you' : 'People',
                  value: [
                    '${group.members.length}',
                    if (!group.isDirect && admin) 'you run it',
                  ].join(' · '),
                  onTap: () => Navigator.of(context).pop('people'),
                ),
                const SizedBox(height: 26),
                Eyebrow('Repeating · ${group.recurring.length}', size: 10.5, tracking: .18),
                const SizedBox(height: 12),
                // Not a second list of schedules. Recurring is a screen off the
                // group now, and two ways to see the same thing in two shapes
                // is how an app starts disagreeing with itself.
                Text(
                  group.recurring.isEmpty
                      ? 'Rent, wifi, the house help. Set one up from Recurring on '
                            'the group screen and Mull asks when it comes round.'
                      : 'Open Recurring on the group screen to change what they '
                            'cost, who pays and when they land.',
                  style: MullType.caption(c.ink3),
                ),
                const SizedBox(height: 12),
                SecondaryButton(
                  'Add a recurring cost',
                  // Handed back to the group screen rather than opened here:
                  // this sheet's context is gone the moment it pops, and the
                  // editor has to outlive it.
                  onTap: () => Navigator.of(context).pop('add-recurring'),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // An admin deletes; everyone else leaves. A delete button that
              // is greyed out for most people is a door with no handle.
              if (admin)
                SecondaryButton(
                  group.isDirect ? 'Delete this ledger' : 'Delete group',
                  onTap: _delete,
                )
              else
                SecondaryButton('Leave group', onTap: _leave),
            ],
          ),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------- expense actions

/// Long-press on an expense: edit it, look at the schedule behind it, or take
/// it back out of the ledger.
Future<void> showExpenseActions(BuildContext context, Group group, Expense expense) {
  final store = context.readStore;
  return showMullSheet(
    context,
    fitContent: true,
    builder: (sheet) {
      void run(VoidCallback action) {
        Navigator.of(sheet).pop();
        Future.delayed(const Duration(milliseconds: 160), action);
      }

      final schedule = expense.recurringId == null ? null : group.recurringById(expense.recurringId!);

      return Padding(
        padding: const EdgeInsets.fromLTRB(30, 26, 30, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text(
                    expense.description,
                    style: MullType.screenTitle(sheet.c.ink),
                    maxLines: 2,
                  ),
                ),
                const SizedBox(width: 12),
                Text(inr(expense.amount), style: MullType.cardAmount(sheet.c.ink)),
              ],
            ),
            const SizedBox(height: 16),
            CardRows(
              children: [
                SheetAction('Edit', onTap: () => run(() => showAddExpense(context, group, existing: expense))),
                if (schedule != null)
                  SheetAction(
                    'The schedule behind it',
                    detail: schedule.frequency.shortLabel,
                    onTap: () => run(() => showRecurringEditor(context, group, existing: schedule)),
                  )
                else
                  SheetAction(
                    'Make it repeat',
                    onTap: () => run(() => showRecurringEditor(context, group)),
                  ),
                SheetAction(
                  'Delete',
                  destructive: true,
                  onTap: () => run(() {
                    store.removeExpense(group, expense);
                    Toast.show(
                      context,
                      'Deleted ${expense.description}',
                      action: 'Undo',
                      onAction: () => store.restoreExpense(group, expense),
                    );
                  }),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
