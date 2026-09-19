import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/split.dart';
import '../../core/upi.dart';
import '../../core/upi_receipt.dart';
import '../../data/models.dart';
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

  void _save() {
    final store = context.readStore;
    final existing = widget.existing;
    final note = _note.text.trim();

    if (existing != null) {
      existing
        ..description = _description.text.trim()
        ..amount = _amount.amount!
        ..payerId = _split.payerId
        ..shares = _split.shares
        ..method = _split.method
        ..note = note.isEmpty ? null : note
        ..date = _date;
      store.updateExpense(widget.group, existing);
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
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 24),
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
                ),
                const SizedBox(height: 18),
                _RowButton(
                  label: 'When',
                  value: daysBetween(_date, store.now()) == 0
                      ? 'Today'
                      : shortDateWithYear(_date, store.now()),
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
            Expanded(child: Text(label, style: ranade(15, color: c.ink2))),
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
      for (final f in Frequency.values)
        NameChip(f.label, selected: f == value, onTap: () => onChanged(f)),
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

class _SettleSheet extends StatelessWidget {
  const _SettleSheet({required this.group, required this.transfer});

  final Group group;
  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final from = group.memberById(transfer.from);
    final to = group.memberById(transfer.to);
    if (from == null || to == null) return const SizedBox.shrink();

    final youPay = from.isYou;
    final owedToYou = to.isYou;
    final payee = to;

    void record() {
      store.settleUp(group, fromId: from.id, toId: to.id, amount: transfer.amount);
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop();
      Toast.show(context, '${inr(transfer.amount)} settled');
    }

    Future<void> payOverUpi() async {
      final upi = payee.upiId;
      if (upi == null) return;
      final opened = await openUpiPayment(
        upiId: upi,
        name: payee.name,
        amount: transfer.amount,
        note: group.title,
      );
      if (!context.mounted) return;
      if (!opened) {
        Toast.show(context, 'No UPI app could open that');
        return;
      }
      // We cannot know whether the payment went through — only the user can say.
      // Marking it paid automatically would quietly falsify the ledger.
      if (context.mounted) Navigator.of(context).pop();
      if (context.mounted) await _confirmPaid(context, group, transfer);
    }

    /// Chases them inside Mull, not in a chat app. Twice a day, counted on the
    /// server — the cap is the feature here as much as the reminder is.
    Future<void> remind() async {
      Navigator.of(context).pop();
      final userId = from.userId;

      if (userId == null) {
        // No account behind that seat, so there is no inbox to reach. WhatsApp
        // is the honest fallback rather than a button that does nothing.
        final message = [
          'Hey ${store.shortName(from)}, ${inr(transfer.amount)} for ${group.title} '
              'when you get a chance.',
          if (store.profile.upiId != null) 'My UPI is ${store.profile.upiId}.',
        ].join(' ');
        final sent = await shareOnWhatsApp(message, phone: from.phone);
        if (!context.mounted) return;
        Toast.show(
          context,
          sent ? '${store.shortName(from)} is not on Mull — sent on WhatsApp' : "Couldn't open WhatsApp",
        );
        return;
      }

      final outcome = await NoticesService.remind(
        toUserId: userId,
        groupId: group.id,
        title: '${store.profile.name.trim().split(' ').first} is waiting on ${inr(transfer.amount)}',
        body: group.title,
        amount: transfer.amount,
      );
      if (!context.mounted) return;
      Toast.show(context, switch (outcome) {
        ReminderOutcome.sent => 'Nudged ${store.shortName(from)}',
        ReminderOutcome.outOfTurns => "That's both of today's nudges. Try again tomorrow.",
        ReminderOutcome.failed => "Couldn't send that. Check your connection.",
      });
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(youPay ? 'You owe' : '${store.shortName(from)} owes ${store.shortName(to)}'),
          const SizedBox(height: 10),
          Text(inr(transfer.amount), style: excon(44, tracking: -.03, color: c.ink)),
          const SizedBox(height: 8),
          Text(
            switch (null) {
              _ when youPay => 'To ${to.name}${payee.upiId == null ? '' : ' · ${payee.upiId}'}',
              // Money coming to you is the case the old copy got wrong: it is
              // not "between them", it is between them and you.
              _ when owedToYou && !from.isLinked =>
                '${store.shortName(from)} is not on Mull. Settle in person, then '
                    'mark it here.',
              _ when owedToYou =>
                'They pay you straight over UPI. Mark it here once it lands, or '
                    'wait for them to say they have sent it.',
              _ => 'Mull just keeps the record. The money moves between them.',
            },
            style: ranade(13, height: 1.5, color: c.ink3),
          ),
          const SizedBox(height: 22),
          if (youPay && payee.upiId != null) ...[
            PillButton('Pay ${inr(transfer.amount)} over UPI', onTap: payOverUpi),
            const SizedBox(height: 8),
            SecondaryButton('Already paid, just record it', onTap: record),
          ] else ...[
            PillButton('Mark as settled', onTap: record),
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

/// A receipt you shared into Mull, matched against what you owe.
///
/// This is the loop that makes "I already sent it" mean something: the claim
/// arrives carrying the amount and the UPI reference off the payment itself,
/// so the person owed is confirming evidence rather than taking your word.
Future<void> showReceiptSettle(
  BuildContext context,
  Group group,
  Transfer transfer,
  UpiReceipt receipt,
) {
  final store = context.readStore;
  final payee = group.memberById(transfer.to);

  return showMullSheet(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('Looks like you paid'),
          const SizedBox(height: 10),
          Text(inr(receipt.amount!), style: excon(44, tracking: -.03, color: sheet.c.ink)),
          const SizedBox(height: 8),
          Text(
            [
              if (payee != null) 'To ${payee.name} · ${group.title}',
              if (receipt.utr != null) 'UPI ref ${receipt.utr}',
            ].join('\n'),
            style: ranade(13, height: 1.55, color: sheet.c.ink3),
          ),
          const SizedBox(height: 22),
          PillButton(
            'Record it',
            onTap: () {
              store.settleUp(
                group,
                fromId: transfer.from,
                toId: transfer.to,
                amount: receipt.amount!,
                utr: receipt.utr,
              );
              HapticFeedback.mediumImpact();
              Navigator.of(sheet).pop();
              Toast.show(context, '${inr(receipt.amount!)} recorded');
            },
          ),
          const SizedBox(height: 8),
          SecondaryButton('Not this one', onTap: () => Navigator.of(sheet).pop()),
        ],
      ),
    ),
  );
}

/// After sending someone to their UPI app, the only honest thing is to ask.
Future<void> _confirmPaid(BuildContext context, Group group, Transfer transfer) {
  final store = context.readStore;
  return showMullSheet(
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
          PillButton(
            'Yes, mark it settled',
            onTap: () {
              store.settleUp(group, fromId: transfer.from, toId: transfer.to, amount: transfer.amount);
              HapticFeedback.mediumImpact();
              Navigator.of(sheet).pop();
            },
          ),
          const SizedBox(height: 8),
          SecondaryButton('Not yet', onTap: () => Navigator.of(sheet).pop()),
        ],
      ),
    ),
  );
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

/// Puts the group's state into WhatsApp as plain text.
Future<void> shareGroupSummary(BuildContext context, Group group) async {
  final store = context.readStore;
  final sent = await shareOnWhatsApp(store.groupSummary(group));
  if (!context.mounted) return;
  if (!sent) Toast.show(context, "Couldn't open WhatsApp");
}

// ------------------------------------------------------------------- member

/// Edit one person: their name, the number a reminder goes to, and the UPI ID
/// that makes settling one tap.
Future<void> showMemberSheet(BuildContext context, Group group, Member member) => showMullSheet(
  context,
  height: 720,
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
  late final _phone = TextEditingController(text: widget.member.phone ?? '');

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
    _phone.dispose();
    super.dispose();
  }

  void _save() {
    final store = context.readStore;
    final name = _name.text.trim();
    if (name.isNotEmpty) widget.member.name = name;
    final email = _email.text.trim().toLowerCase();
    widget.member.email = email.isEmpty ? null : email;
    store.setPhone(widget.member, _phone.text);
    store.setUpiId(widget.member, _upi.text);
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final typed = _upi.text.trim();
    final looksRight = typed.isEmpty || isUpiId(typed);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(widget.member.isYou ? 'You' : widget.member.name),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigField(controller: _name, hint: 'Name'),
                if (!widget.member.isYou) ...[
                  const SizedBox(height: 26),
                  BigField(
                    controller: _email,
                    size: 20,
                    hint: 'their@email.com',
                    keyboardType: TextInputType.emailAddress,
                    help: Text(
                      widget.member.isLinked
                          ? 'They are on Mull and see this group.'
                          : 'Invite them here and this seat becomes theirs the moment they '
                                'sign up, with everything they already owe or are owed.',
                      style: ranade(12, height: 1.5, color: c.ink3),
                    ),
                  ),
                  const SizedBox(height: 26),
                  BigField(
                    controller: _phone,
                    size: 20,
                    hint: '+91 98765 43210',
                    keyboardType: TextInputType.phone,
                    help: Text(
                      'Where a reminder goes. With a number, chasing them is one '
                      'tap into their WhatsApp; without one you have to find them '
                      'yourself.',
                      style: ranade(12, height: 1.5, color: c.ink3),
                    ),
                  ),
                ],
                const SizedBox(height: 26),
                // A seat with an account behind it takes its VPA from that
                // account, so there is nothing here to edit — and editing it
                // would be the old mistake: a payment address entered by the
                // person doing the paying.
                if (widget.member.isLinked && !widget.member.isYou)
                  CardRows(
                    children: [
                      SizedBox(
                        height: 58,
                        child: Row(
                          children: [
                            Expanded(child: Text('Their UPI ID', style: ranade(15.5, color: c.ink))),
                            Text(widget.member.upiId ?? 'Not set', style: excon(15, color: c.ink2)),
                          ],
                        ),
                      ),
                    ],
                  )
                else
                  BigField(
                    controller: _upi,
                    size: 20,
                    hint: 'name@bank',
                    help: Text(
                      looksRight
                          ? (widget.member.isYou
                                ? 'Goes into the summaries you send, so people can pay you back.'
                                : 'Settling up opens GPay or PhonePe with the amount already filled in.')
                          : "That doesn't look like a UPI ID. They usually read name@bank.",
                      style: ranade(12, height: 1.5, color: c.ink3),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
          child: PillButton('Save', onTap: looksRight ? _save : null),
        ),
      ],
    );
  }
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
              group.isSettled
                  ? 'Every expense goes with it.'
                  : 'Every expense goes with it, and this one is not settled up yet.',
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
              SecondaryButton(
                group.isDirect ? 'Delete this ledger' : 'Delete group',
                onTap: admin ? _delete : null,
              ),
              if (!admin) ...[
                const SizedBox(height: 10),
                Text(
                  'Only an admin can delete a group. You can leave it from People.',
                  textAlign: TextAlign.center,
                  style: MullType.caption(c.ink3, size: 11.5),
                ),
              ],
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
