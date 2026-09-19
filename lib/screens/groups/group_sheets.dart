import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../core/split.dart';
import '../../core/upi.dart';
import '../../core/upi_receipt.dart';
import '../friends_sheet.dart';
import '../../data/models.dart';
import '../../data/remote/friends_service.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';

class NameChip extends StatelessWidget {
  const NameChip(this.label, {super.key, this.selected = false, this.onTap, this.onRemove, this.detail});

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .95,
      child: AnimatedContainer(
        duration: motion(context, const Duration(milliseconds: 200)),
        height: 40,
        padding: EdgeInsets.only(left: 16, right: onRemove == null ? 16 : 4),
        decoration: BoxDecoration(
          color: selected ? c.pill : c.pill.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? c.pill : c.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: ranade(14, color: selected ? c.pillInk : c.ink2)),
            if (detail != null) ...[
              const SizedBox(width: 8),
              Text(detail!, style: excon(13, color: selected ? c.pillInk : c.ink3)),
            ],
            if (onRemove != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRemove,
                child: SizedBox(
                  width: 34,
                  height: 40,
                  child: Center(child: MullIcon(MullGlyph.close, size: 13, color: c.ink3, strokeWidth: 2)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Inline "add a name" input that turns entries into chips.
class _PeopleInput extends StatefulWidget {
  const _PeopleInput({required this.onAdd});

  final ValueChanged<String> onAdd;

  @override
  State<_PeopleInput> createState() => _PeopleInputState();
}

class _PeopleInputState extends State<_PeopleInput> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final names = _ctrl.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
    for (final n in names) {
      widget.onAdd(n);
    }
    _ctrl.clear();
    _focus.requestFocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              style: ranade(16, color: c.ink),
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              keyboardAppearance: c.isDark ? Brightness.dark : Brightness.light,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration.collapsed(
                hintText: 'Add a name',
                hintStyle: ranade(16, color: c.ink3.withValues(alpha: .6)),
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: _ctrl.text.trim().isEmpty ? .3 : 1,
            duration: const Duration(milliseconds: 150),
            child: CircleButton(
              filled: false,
              semanticLabel: 'Add person',
              onTap: _ctrl.text.trim().isEmpty ? null : _submit,
              child: MullIcon(MullGlyph.plus, size: 18, color: c.ink, strokeWidth: 1.8),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- start a group

Future<void> showStartGroup(BuildContext context, {void Function(Group)? onCreated}) async {
  final group = await showMullSheet<Group>(context, height: 620, builder: (_) => const _StartGroupSheet());
  if (group != null) onCreated?.call(group);
}

class _StartGroupSheet extends StatefulWidget {
  const _StartGroupSheet();

  @override
  State<_StartGroupSheet> createState() => _StartGroupSheetState();
}

class _StartGroupSheetState extends State<_StartGroupSheet> {
  final _name = TextEditingController();
  final _people = <String>[];

  /// Friends picked before the group exists. Held as [Friend] rather than
  /// seated straight away because the group has no id yet — they become members
  /// in one go when it is created.
  final _friends = <Friend>[];

  Future<void> _pickFriends() async {
    final picked = await showFriendPicker(
      context,
      alreadyIn: {
        for (final f in _friends)
          if (f.userId != null) f.userId!,
      },
    );
    if (picked == null || !mounted) return;
    setState(() => _friends.addAll(picked));
  }

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _create() {
    final group = context.readStore.addGroup(
      _name.text,
      _people,
      friends: [
        for (final f in _friends)
          Member(name: f.label, userId: f.userId, email: f.email, upiId: f.upiId),
      ],
    );
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(group);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Start a group'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 16, 30, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigField(
                  controller: _name,
                  autofocus: true,
                  hint: 'Goa trip',
                  textInputAction: TextInputAction.next,
                  help: const Text('A trip, the flat, a night out — anywhere costs get shared.'),
                ),
                const SizedBox(height: 28),
                const Eyebrow("Who's in"),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    const NameChip('You', selected: true),
                    for (final (i, f) in _friends.indexed)
                      NameChip(
                        f.label,
                        // The dot marks a seat that carries its own UPI ID,
                        // which is the difference that matters at settle-up.
                        detail: f.upiId == null ? null : '·',
                        onRemove: () => setState(() => _friends.removeAt(i)),
                      ),
                    for (final (i, p) in _people.indexed)
                      NameChip(p, onRemove: () => setState(() => _people.removeAt(i))),
                  ],
                ),
                const SizedBox(height: 16),
                GhostButton('Add from friends', onTap: _pickFriends),
                const SizedBox(height: 16),
                _PeopleInput(onAdd: (n) => setState(() => _people.add(n))),
                const SizedBox(height: 12),
                Text(
                  'A friend brings their own name and UPI ID. A typed name is a '
                  'placeholder — fine for someone not on Mull, but you will have to '
                  'settle up with them by hand.',
                  style: ranade(12, height: 1.6, color: c.ink3),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(26, 8, 26, keyboardUp ? 4 : 30),
          child: Column(
            children: [
              PillButton('Start it', onTap: _name.text.trim().isEmpty ? null : _create),
              if (!keyboardUp)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('No money moves through Mull.', style: ranade(11.5, color: c.ink3)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------- add an expense

Future<void> showAddExpense(BuildContext context, Group group, {Expense? existing}) => showMullSheet(
  context,
  // This sheet grows with the group — every member is another row in the
  // split. Ask for most of the screen so a normal-sized group is visible
  // without scrolling; the sheet clamps itself to what the phone has.
  height: 860,
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
  final _amountFocus = FocusNode();

  late String _payerId;
  late SplitMethod _method;
  late bool _repeats;

  /// Who the bill is divided between — the whole group unless someone sat out.
  late Set<String> _included;

  /// Raw per-person input for the methods that need one: rupees for [exact],
  /// a count for [shares], a percentage for [percent].
  final _weights = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    final group = widget.group;
    final existing = widget.existing;
    _payerId = existing?.payerId ?? group.you?.id ?? group.members.first.id;
    _method = existing?.method ?? SplitMethod.equal;
    _repeats = existing?.repeatsMonthly ?? false;
    _included = existing != null ? existing.shares.keys.toSet() : group.members.map((m) => m.id).toSet();

    for (final m in group.members) {
      final share = existing?.shares[m.id];
      _weights[m.id] = TextEditingController(
        text: switch (_method) {
          SplitMethod.exact => share?.toString() ?? '',
          SplitMethod.shares => share == null ? '' : '1',
          _ => '',
        },
      )..addListener(() => setState(() {}));
    }

    _description.addListener(() => setState(() {}));
    _amount.addListener(() => setState(() {}));
    _amountFocus.addListener(() {
      if (!_amountFocus.hasFocus) _amount.tidy();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    _amountFocus.dispose();
    for (final c in _weights.values) {
      c.dispose();
    }
    super.dispose();
  }

  double? _weightOf(String id) {
    final text = _weights[id]!.text.trim();
    if (text.isEmpty) return null;
    return double.tryParse(text);
  }

  /// The split as it currently stands, or an empty map if it does not resolve.
  Map<String, int> get _shares {
    final amount = _amount.amount;
    if (amount == null || amount <= 0) return const {};

    switch (_method) {
      case SplitMethod.equal:
        final ids = widget.group.members.map((m) => m.id).where(_included.contains).toList();
        return ids.isEmpty ? const {} : splitEqually(amount, ids);

      case SplitMethod.exact:
        final out = <String, int>{};
        for (final m in widget.group.members) {
          final value = _weightOf(m.id);
          if (value != null && value > 0) out[m.id] = value.round();
        }
        // Exact means exact: a split that does not add up to the bill is not a
        // split, so it stays invalid until the numbers agree.
        return out.values.fold(0, (s, v) => s + v) == amount ? out : const {};

      case SplitMethod.shares:
      case SplitMethod.percent:
        final weights = <String, num>{};
        for (final m in widget.group.members) {
          final value = _weightOf(m.id);
          if (value != null && value > 0) weights[m.id] = value;
        }
        return weights.isEmpty ? const {} : splitByWeight(amount, weights);
    }
  }

  bool get _valid => _description.text.trim().isNotEmpty && _amount.amount != null && _shares.isNotEmpty;

  void _save() {
    final store = context.readStore;
    final existing = widget.existing;
    if (existing != null) {
      existing
        ..description = _description.text.trim()
        ..amount = _amount.amount!
        ..payerId = _payerId
        ..shares = _shares
        ..method = _method
        ..repeatsMonthly = _repeats;
      store.updateExpense(widget.group, existing);
    } else {
      store.addExpense(
        widget.group,
        description: _description.text.trim(),
        amount: _amount.amount!,
        payerId: _payerId,
        shares: _shares,
        method: _method,
        repeatsMonthly: _repeats,
      );
    }
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
  }

  /// The line under the split that says whether it currently works.
  String _splitStatus() {
    final amount = _amount.amount;
    if (amount == null) return 'Put the amount in first.';
    final shares = _shares;
    if (shares.isNotEmpty) {
      return switch (_method) {
        SplitMethod.equal => '${inr(amount ~/ _included.length)} each, give or take a rupee.',
        SplitMethod.exact => 'Adds up to ${inr(amount)}.',
        SplitMethod.shares => 'Split by shares.',
        SplitMethod.percent => 'Split by percentage.',
      };
    }
    if (_method == SplitMethod.exact) {
      var assigned = 0;
      for (final m in widget.group.members) {
        final v = _weightOf(m.id);
        if (v != null && v > 0) assigned += v.round();
      }
      final left = amount - assigned;
      return left > 0 ? '${inr(left)} still to assign.' : '${inr(-left)} over the total.';
    }
    return 'Give at least one person a number.';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final group = widget.group;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final shares = _shares;

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
                const SizedBox(height: 26),
                const Eyebrow('Who paid'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in group.members)
                      NameChip(
                        store.shortName(m),
                        selected: m.id == _payerId,
                        onTap: () => setState(() => _payerId = m.id),
                      ),
                  ],
                ),
                const SizedBox(height: 26),
                const Eyebrow('Split'),
                const SizedBox(height: 12),
                Segmented(
                  labels: const ['Equally', 'Exact', 'Shares', '%'],
                  index: _method.index,
                  onChanged: (i) => setState(() => _method = SplitMethod.values[i]),
                ),
                const SizedBox(height: 16),
                for (final m in group.members)
                  _SplitRow(
                    key: ValueKey(m.id),
                    name: store.displayName(m),
                    method: _method,
                    included: _included.contains(m.id),
                    controller: _weights[m.id]!,
                    share: shares[m.id],
                    onToggle: () => setState(() {
                      if (!_included.remove(m.id)) _included.add(m.id);
                    }),
                  ),
                const SizedBox(height: 14),
                Text(_splitStatus(), style: ranade(12, color: c.ink3)),
                const SizedBox(height: 18),
                Pressable(
                  onTap: () => setState(() => _repeats = !_repeats),
                  scale: .99,
                  child: Row(
                    children: [
                      AnimatedContainer(
                        duration: motion(context, const Duration(milliseconds: 180)),
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: _repeats ? c.pill : c.pill.withValues(alpha: 0),
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(color: _repeats ? c.pill : c.line),
                        ),
                        child: _repeats
                            ? Center(
                                child: MullIcon(
                                  MullGlyph.check,
                                  size: 13,
                                  color: c.pillInk,
                                  strokeWidth: 2.2,
                                ),
                              )
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Happens every month',
                          style: ranade(15, color: _repeats ? c.ink : c.ink2),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_repeats) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Rent, wifi, the maid. Mull offers next month when it comes '
                    'round rather than adding it behind your back.',
                    style: ranade(11.5, height: 1.6, color: c.ink3),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(26, 8, 26, keyboardUp ? 4 : 30),
          child: PillButton(widget.existing == null ? 'Add it' : 'Save', onTap: _valid ? _save : null),
        ),
      ],
    );
  }
}

/// One person's line in the split editor.
class _SplitRow extends StatelessWidget {
  const _SplitRow({
    super.key,
    required this.name,
    required this.method,
    required this.included,
    required this.controller,
    required this.share,
    required this.onToggle,
  });

  final String name;
  final SplitMethod method;
  final bool included;
  final TextEditingController controller;
  final int? share;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final equal = method == SplitMethod.equal;
    final on = !equal || included;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Pressable(
        onTap: equal ? onToggle : null,
        scale: equal ? .99 : 1,
        haptic: equal,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              if (equal)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: AnimatedContainer(
                    duration: motion(context, const Duration(milliseconds: 180)),
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: included ? c.pill : c.pill.withValues(alpha: 0),
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: included ? c.pill : c.line),
                    ),
                    child: included
                        ? Center(
                            child: MullIcon(MullGlyph.check, size: 13, color: c.pillInk, strokeWidth: 2.2),
                          )
                        : null,
                  ),
                ),
              Expanded(
                child: Text(
                  name,
                  style: ranade(15.5, color: on ? c.ink : c.ink3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!equal)
                SizedBox(
                  width: 82,
                  child: TextField(
                    controller: controller,
                    textAlign: TextAlign.right,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: excon(17, color: c.ink),
                    keyboardAppearance: c.isDark ? Brightness.dark : Brightness.light,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: method == SplitMethod.percent
                          ? '0%'
                          : (method == SplitMethod.shares ? '0' : '₹0'),
                      hintStyle: excon(17, color: c.ink3.withValues(alpha: .6)),
                      border: UnderlineInputBorder(borderSide: BorderSide(color: c.line)),
                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.line)),
                      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: c.ink2)),
                      contentPadding: const EdgeInsets.only(bottom: 6),
                    ),
                  ),
                ),
              SizedBox(
                width: 92,
                child: Text(
                  share == null ? '—' : inr(share!),
                  textAlign: TextAlign.right,
                  style: excon(17, color: share == null ? c.ink3 : c.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
        note: group.name,
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
            youPay
                ? 'To ${to.name}${payee.upiId == null ? '' : ' · ${payee.upiId}'}'
                : 'Mull just keeps the record — the money moves between them.',
            style: ranade(13, height: 1.5, color: c.ink3),
          ),
          const SizedBox(height: 22),
          if (youPay && payee.upiId != null) ...[
            PillButton('Pay ${inr(transfer.amount)} over UPI', onTap: payOverUpi),
            const SizedBox(height: 8),
            GhostButton('Already paid — just record it', onTap: record),
          ] else ...[
            PillButton('Mark as settled', onTap: record),
            if (youPay) ...[
              const SizedBox(height: 8),
              GhostButton(
                'Add their UPI ID',
                onTap: () {
                  Navigator.of(context).pop();
                  showMemberSheet(context, group, payee);
                },
              ),
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
              if (payee != null) 'To ${payee.name} · ${group.name}',
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
          GhostButton('Not this one', onTap: () => Navigator.of(sheet).pop()),
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
          GhostButton('Not yet', onTap: () => Navigator.of(sheet).pop()),
        ],
      ),
    ),
  );
}

// ------------------------------------------------------------------- member

/// Edit one person: their name, and the UPI ID that makes settling one tap.
Future<void> showMemberSheet(BuildContext context, Group group, Member member) => showMullSheet(
  context,
  height: 620,
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
    if (name.isNotEmpty) widget.member.name = name;
    final email = _email.text.trim().toLowerCase();
    widget.member.email = email.isEmpty ? null : email;
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
                          : 'Invite them here and this seat becomes theirs the moment they sign up — '
                                'with everything they already owe or are owed.',
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
                            Expanded(
                              child: Text('Their UPI ID', style: ranade(15.5, color: c.ink)),
                            ),
                            Text(
                              widget.member.upiId ?? 'Not set',
                              style: excon(15, color: c.ink2),
                            ),
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
                          : "That doesn't look like a UPI ID — they usually read name@bank.",
                      style: ranade(12, height: 1.5, color: c.ink3),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 8, 26, 30),
          child: PillButton('Save', onTap: looksRight ? _save : null),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------- settings

/// Resolves to 'deleted' when the group was removed.
Future<String?> showGroupSettings(BuildContext context, Group group) =>
    showMullSheet<String>(context, height: 640, builder: (_) => _GroupSettingsSheet(group: group));

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
            Text('Delete ${group.name}?', style: excon(28, tracking: -.02, color: sheet.c.ink)),
            const SizedBox(height: 10),
            Text(
              group.isSettled
                  ? 'Every expense goes with it.'
                  : 'Every expense goes with it — and this group is not settled up yet.',
              style: ranade(14, height: 1.6, color: sheet.c.ink3),
            ),
            const SizedBox(height: 24),
            PillButton('Delete group', onTap: () => Navigator.of(sheet).pop(true)),
            const SizedBox(height: 8),
            GhostButton('Keep it', onTap: () => Navigator.of(sheet).pop(false)),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    store.deleteGroup(group);
    nav.pop('deleted');
    if (mounted) {
      Toast.show(context, 'Deleted ${group.name}', action: 'Undo', onAction: () => store.restoreGroup(group));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final group = widget.group;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Group'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigField(controller: _name, hint: 'Name', onChanged: (_) => _apply()),
                const SizedBox(height: 28),
                Eyebrow('${group.members.length} people'),
                const SizedBox(height: 4),
                Text(
                  'Tap someone to add the UPI ID that makes settling one tap.',
                  style: ranade(12, color: c.ink3),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in group.members)
                      NameChip(
                        store.shortName(m),
                        detail: m.upiId == null ? null : '·',
                        selected: m.isYou,
                        onTap: () => showMemberSheet(context, group, m),
                        onRemove: store.canRemoveMember(group, m) ? () => store.removeMember(group, m) : null,
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                GhostButton(
                  'Add from friends',
                  onTap: () async {
                    final picked = await showFriendPicker(
                      context,
                      alreadyIn: {
                        for (final m in group.members)
                          if (m.userId != null) m.userId!,
                      },
                    );
                    if (picked == null) return;
                    for (final friend in picked) {
                      store.addFriendAsMember(
                        group,
                        userId: friend.userId!,
                        name: friend.label,
                        email: friend.email,
                        upiId: friend.upiId,
                      );
                    }
                  },
                ),
                const SizedBox(height: 12),
                _PeopleInput(onAdd: (n) => store.addMember(group, n)),
                const SizedBox(height: 12),
                Text(
                  'A friend brings their own name and UPI ID. Someone added by hand '
                  'is a placeholder until they join — you can fill in their details, '
                  'but a UPI ID you type yourself pays whoever owns it.',
                  style: ranade(11.5, height: 1.6, color: c.ink3),
                ),
                const SizedBox(height: 10),
                Text(
                  'Anyone who has paid for something or owes a share stays — removing '
                  'them would quietly change what everyone else owes.',
                  style: ranade(11.5, height: 1.6, color: c.ink3),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 8, 26, 30),
          child: GhostButton('Delete group', onTap: _delete),
        ),
      ],
    );
  }
}
