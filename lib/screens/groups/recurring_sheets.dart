/// Standing expenses: rent, wifi, the maid, the shared Netflix.
///
/// The rule the whole feature is built around is that Mull asks. A split app
/// that quietly posts rent on the 1st is a split app that posts the *old* rent
/// after everyone's landlord put it up, and nobody notices for four months. So
/// a due schedule surfaces as a card with the amount in an editable field, and
/// what you confirm is what gets recorded — and becomes the new normal.
///
/// [Recurring.autoAdd] exists for the ones that genuinely never change, and
/// even then the app says what it did rather than saying nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'split_editor.dart';

// ------------------------------------------------------------------ due card

/// "Rent is due today" — confirm the amount, or skip this one.
Future<void> showDueRecurring(BuildContext context, Group group, Recurring schedule) => showMullSheet(
  context,
  height: 640,
  builder: (_) => _DueSheet(group: group, schedule: schedule),
);

class _DueSheet extends StatefulWidget {
  const _DueSheet({required this.group, required this.schedule});

  final Group group;
  final Recurring schedule;

  @override
  State<_DueSheet> createState() => _DueSheetState();
}

class _DueSheetState extends State<_DueSheet> {
  late final _amount = AmountController(widget.schedule.amount);
  final _amountFocus = FocusNode();
  late final SplitModel _split;
  bool _editingSplit = false;

  @override
  void initState() {
    super.initState();
    _split = SplitModel(
      group: widget.group,
      payerId: widget.schedule.payerId,
      method: widget.schedule.method,
      shares: widget.schedule.shares,
      amount: widget.schedule.amount,
    )..addListener(_bump);
    _amount.addListener(() {
      _split.amount = _amount.amount ?? 0;
      setState(() {});
    });
    _amountFocus.addListener(() {
      if (!_amountFocus.hasFocus) _amount.tidy();
      setState(() {});
    });
  }

  void _bump() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _amount.dispose();
    _amountFocus.dispose();
    _split
      ..removeListener(_bump)
      ..dispose();
    super.dispose();
  }

  bool get _changed => _amount.amount != widget.schedule.amount;

  void _add() {
    final store = context.readStore;
    store.addDue(
      widget.group,
      widget.schedule,
      amount: _amount.amount,
      shares: _split.shares,
      payerId: _split.payerId,
    );
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
    Toast.show(context, '${widget.schedule.description} added');
  }

  void _skip() {
    final store = context.readStore;
    store.skipDue(widget.group, widget.schedule);
    HapticFeedback.lightImpact();
    Navigator.of(context).pop();
    Toast.show(
      context,
      'Skipped · next ${shortDate(widget.schedule.nextDue)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final schedule = widget.schedule;
    final payer = widget.group.memberById(_split.payerId);
    final yourShare = _split.shares[widget.group.you?.id] ?? 0;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Due again'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(schedule.description, style: excon(30, tracking: -.02, color: c.ink)),
                const SizedBox(height: 8),
                Text(
                  '${widget.group.title} · ${schedule.frequency.shortLabel} · '
                  'due ${relativeDay(schedule.nextDue, store.now())}',
                  style: ranade(12.5, height: 1.55, color: c.ink3),
                ),
                const SizedBox(height: 26),
                BigField(
                  controller: _amount,
                  focusNode: _amountFocus,
                  numeric: true,
                  hint: '₹0',
                  trailing: Text('this time', style: ranade(11.5, color: c.ink3)),
                  help: Text(
                    _changed
                        ? 'Saved as the new amount. Next time will ask for this instead.'
                        : 'Rent goes up, bills move. Change it here and the schedule follows.',
                    style: ranade(12, height: 1.5, color: c.ink3),
                  ),
                ),
                const SizedBox(height: 22),
                if (!_editingSplit)
                  Pressable(
                    onTap: () => setState(() => _editingSplit = true),
                    scale: .99,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: c.line)),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              [
                                if (payer != null) payer.isYou ? 'You pay' : '${store.shortName(payer)} pays',
                                if (yourShare > 0) 'your share ${inr(yourShare)}',
                              ].join(' · '),
                              style: ranade(14, color: c.ink2),
                            ),
                          ),
                          Text('Change', style: ranade(13, color: c.ink3)),
                          const SizedBox(width: 6),
                          MullIcon(MullGlyph.chevronRight, size: 14, color: c.ink3, strokeWidth: 1.7),
                        ],
                      ),
                    ),
                  )
                else
                  SplitFields(model: _split),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, keyboardUp ? 4 : 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PillButton(
                'Add ${inr(_amount.amount ?? 0)}',
                onTap: _split.isValid ? _add : null,
              ),
              const SizedBox(height: 8),
              SecondaryButton('Not this time', onTap: _skip),
            ],
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ editor

Future<void> showRecurringEditor(BuildContext context, Group group, {Recurring? existing}) =>
    showMullSheet(context, height: 900, builder: (_) => _RecurringEditor(group: group, existing: existing));

class _RecurringEditor extends StatefulWidget {
  const _RecurringEditor({required this.group, this.existing});

  final Group group;
  final Recurring? existing;

  @override
  State<_RecurringEditor> createState() => _RecurringEditorState();
}

class _RecurringEditorState extends State<_RecurringEditor> {
  late final _description = TextEditingController(text: widget.existing?.description ?? '');
  late final _amount = AmountController(widget.existing?.amount);
  final _amountFocus = FocusNode();

  late final SplitModel _split;
  late Frequency _frequency;
  late DateTime _nextDue;
  late DateTime? _endsOn;
  late bool _autoAdd;
  late bool _paused;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    final store = context.readStore;
    _frequency = existing?.frequency ?? Frequency.monthly;
    _nextDue = existing?.nextDue ?? dayOf(store.now()).add(const Duration(days: 1));
    _endsOn = existing?.endsOn;
    _autoAdd = existing?.autoAdd ?? false;
    _paused = existing?.paused ?? false;

    _split = SplitModel(
      group: widget.group,
      payerId: existing?.payerId,
      method: existing?.method ?? SplitMethod.equal,
      shares: existing?.shares,
      amount: existing?.amount ?? 0,
    )..addListener(_bump);

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

  void _bump() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    _amountFocus.dispose();
    _split
      ..removeListener(_bump)
      ..dispose();
    super.dispose();
  }

  bool get _valid => _description.text.trim().isNotEmpty && _amount.amount != null && _split.isValid;

  void _save() {
    final store = context.readStore;
    final existing = widget.existing;
    if (existing != null) {
      existing
        ..description = _description.text.trim()
        ..amount = _amount.amount!
        ..payerId = _split.payerId
        ..shares = _split.shares
        ..method = _split.method
        ..frequency = _frequency
        ..nextDue = _nextDue
        ..endsOn = _endsOn
        ..autoAdd = _autoAdd
        ..paused = _paused;
      store.updateRecurring(widget.group, existing);
    } else {
      store.addRecurring(
        widget.group,
        description: _description.text.trim(),
        amount: _amount.amount!,
        payerId: _split.payerId,
        shares: _split.shares,
        method: _split.method,
        frequency: _frequency,
        startsOn: _nextDue,
        endsOn: _endsOn,
        autoAdd: _autoAdd,
      );
    }
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
  }

  Future<void> _pick({required bool isEnd}) async {
    final store = context.readStore;
    final today = dayOf(store.now());
    final picked = await showMullDatePicker(
      context,
      title: isEnd ? 'Stops after' : 'Next one on',
      initial: isEnd ? (_endsOn ?? addMonths(_nextDue, 12)) : _nextDue,
      first: isEnd ? _nextDue : today.subtract(const Duration(days: 31)),
      last: DateTime(today.year + 10),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isEnd) {
        _endsOn = picked;
      } else {
        _nextDue = picked;
      }
    });
  }

  Future<void> _delete() async {
    final store = context.readStore;
    final schedule = widget.existing!;
    final nav = Navigator.of(context);
    final ok = await showMullSheet<bool>(
      context,
      fitContent: true,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(30, 30, 30, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Stop ${schedule.description}?', style: excon(26, tracking: -.02, color: sheet.c.ink)),
            const SizedBox(height: 10),
            Text(
              'The schedule goes. Everything it has already added stays, because '
              'that was real money.',
              style: ranade(14, height: 1.6, color: sheet.c.ink3),
            ),
            const SizedBox(height: 24),
            PillButton('Stop it', onTap: () => Navigator.of(sheet).pop(true)),
            const SizedBox(height: 8),
            SecondaryButton('Keep it', onTap: () => Navigator.of(sheet).pop(false)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    store.removeRecurring(widget.group, schedule);
    nav.pop();
    if (mounted) {
      Toast.show(
        context,
        'Stopped ${schedule.description}',
        action: 'Undo',
        onAction: () => store.restoreRecurring(widget.group, schedule),
      );
    }
  }

  /// The split, opened as its own sheet.
  ///
  /// It is the one part of a schedule that can take a whole screen on its own,
  /// and burying a per-person editor inside a list of one-line field rows is
  /// what made the old version a scroll rather than a form.
  Future<void> _editSplit() => showMullSheet(
    context,
    height: 720,
    builder: (sheet) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Who pays, and how it splits'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 14, 30, 20),
            child: ListenableBuilder(
              listenable: _split,
              builder: (context, _) => SplitFields(model: _split, payerLabel: 'Who pays it'),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 26),
          child: PillButton('Done', onTap: () => Navigator.of(sheet).pop()),
        ),
      ],
    ),
  );

  Future<void> _pickFrequency() async {
    final picked = await showOptionSheet<Frequency>(
      context,
      title: 'How often',
      value: _frequency,
      options: [for (final f in Frequency.values) (f, f.label, null)],
    );
    if (picked != null && mounted) setState(() => _frequency = picked);
  }

  /// "5th of the month" reads as a rule; "25 Sep" reads as one date.
  String get _charges => switch (_frequency) {
    Frequency.monthly => '${ordinal(_nextDue.day)} of the month',
    Frequency.quarterly => '${ordinal(_nextDue.day)}, every 3 months',
    Frequency.yearly => '${shortDate(_nextDue)}, every year',
    _ => shortDateWithYear(_nextDue, context.readStore.now()),
  };

  String get _splitSummary {
    final count = _split.included.length;
    return switch (_split.method) {
      SplitMethod.equal => 'Equally, $count ${count == 1 ? 'way' : 'ways'}',
      SplitMethod.exact => 'Exact amounts',
      SplitMethod.shares => 'By shares',
      SplitMethod.percent => 'By percentage',
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final payer = widget.group.memberById(_split.payerId);
    final yourShare = _split.shares[widget.group.you?.id] ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader('Recurring · ${widget.group.title}'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 14, 30, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigField(
                  controller: _description,
                  autofocus: widget.existing == null,
                  hint: 'House help',
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _amountFocus.requestFocus(),
                ),
                const SizedBox(height: 26),
                BigField(
                  controller: _amount,
                  focusNode: _amountFocus,
                  numeric: true,
                  size: 44,
                  hint: '₹0',
                  underline: false,
                  trailing: Text(
                    _frequency.label.toLowerCase(),
                    style: MullType.caption(c.ink3),
                  ),
                ),
                const SizedBox(height: 22),

                Stacked(
                  gap: 8,
                  children: [
                    FieldRow(
                      label: 'Repeats',
                      value: _frequency.label,
                      onTap: _pickFrequency,
                    ),
                    FieldRow(
                      label: widget.existing == null ? 'Starts on' : 'Charges on',
                      value: _charges,
                      onTap: () => _pick(isEnd: false),
                    ),
                    FieldRow(
                      label: 'Paid by',
                      value: payer == null ? 'Someone' : store.displayName(payer),
                      onTap: _editSplit,
                    ),
                    FieldRow(
                      label: 'Split',
                      value: _splitSummary,
                      onTap: _editSplit,
                    ),
                    FieldRow(
                      label: 'Stops after',
                      value: _endsOn == null ? 'Never' : shortDateWithYear(_endsOn!, store.now()),
                      onTap: () => _pick(isEnd: true),
                    ),
                  ],
                ),

                if (!_split.isValid && _amount.amount != null) ...[
                  const SizedBox(height: 14),
                  Text(_split.status, style: MullType.caption(c.ink2)),
                ],

                const SizedBox(height: 18),
                _ToggleCard(
                  title: 'Open it automatically',
                  body: yourShare > 0
                      ? 'Everyone gets asked for their ${inr(yourShare)} on the '
                            '${ordinal(_nextDue.day)}.'
                      : 'Mull adds it on the day and tells everyone it did. Only '
                            'for the ones that truly never change.',
                  value: _autoAdd,
                  onChanged: (v) => setState(() => _autoAdd = v),
                ),

                if (widget.existing != null) ...[
                  const SizedBox(height: 8),
                  _ToggleCard(
                    title: 'Pause it',
                    body: 'Keeps the schedule without it piling up. Nothing is '
                        'owed for the time it was off.',
                    value: _paused,
                    onChanged: (v) => setState(() => _paused = v),
                  ),
                  const SizedBox(height: 22),
                  SecondaryButton('Stop this schedule', onTap: _delete),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(20, 6, 20, keyboardUp ? 4 : 26),
          child: PillButton(
            widget.existing == null ? 'Set it up' : 'Save it',
            onTap: _valid ? _save : null,
          ),
        ),
      ],
    );
  }
}

/// A switch with the sentence that explains what it will do.
class _ToggleCard extends StatelessWidget {
  const _ToggleCard({
    required this.title,
    required this.body,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String body;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 18, 18, 20),
      decoration: BoxDecoration(
        color: c.quiet,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: MullType.cardTitle(c.ink, size: 16)),
                const SizedBox(height: 5),
                Text(body, style: MullType.caption(c.ink3)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: MullToggle(value: value, onChanged: onChanged, semanticLabel: title),
          ),
        ],
      ),
    );
  }
}

/// One choice out of a short list, in a sheet sized to the list.
Future<T?> showOptionSheet<T>(
  BuildContext context, {
  required String title,
  required T value,
  required List<(T, String, String?)> options,
}) => showMullSheet<T>(
  context,
  fitContent: true,
  builder: (sheet) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(title),
        const SizedBox(height: 10),
        Stacked(
          gap: 8,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          children: [
            for (final (option, label, detail) in options)
              SelectionRow(
                label: label,
                detail: detail,
                selected: option == value,
                onTap: () => Navigator.of(sheet).pop(option),
              ),
          ],
        ),
      ],
    ),
  ),
);
