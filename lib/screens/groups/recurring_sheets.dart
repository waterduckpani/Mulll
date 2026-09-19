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
                        ? 'Saved as the new amount — next time will ask for this instead.'
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
                                if (payer != null) '${store.shortName(payer)} pays',
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
          padding: EdgeInsets.fromLTRB(26, 8, 26, keyboardUp ? 4 : 26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PillButton(
                'Add ${inr(_amount.amount ?? 0)}',
                onTap: _split.isValid ? _add : null,
              ),
              const SizedBox(height: 8),
              GhostButton('Not this time', onTap: _skip),
            ],
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------- the schedules

/// Every standing expense in a group.
Future<void> showRecurringList(BuildContext context, Group group) =>
    showMullSheet(context, height: 680, builder: (_) => _RecurringListSheet(group: group));

class _RecurringListSheet extends StatelessWidget {
  const _RecurringListSheet({required this.group});

  final Group group;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final live = group.recurring.where((r) => r.isActive).toList()
      ..sort((a, b) => a.nextDue.compareTo(b.nextDue));
    final resting = group.recurring.where((r) => !r.isActive).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Repeating'),
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 20),
            children: [
              Text(
                'The things that come round on their own. Mull asks when each one '
                'is due rather than posting it quietly.',
                style: ranade(12.5, height: 1.6, color: c.ink3),
              ),
              const SizedBox(height: 22),
              if (group.recurring.isEmpty)
                Text(
                  'Nothing repeating yet. Rent, wifi and the maid are the usual '
                  'three.',
                  style: ranade(15, height: 1.6, color: c.ink2),
                )
              else ...[
                CardRows(
                  children: [
                    for (final r in live)
                      _ScheduleRow(key: ValueKey(r.id), group: group, schedule: r),
                  ],
                ),
                if (resting.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  const Eyebrow('Paused and finished'),
                  const SizedBox(height: 8),
                  CardRows(
                    children: [
                      for (final r in resting)
                        _ScheduleRow(key: ValueKey(r.id), group: group, schedule: r),
                    ],
                  ),
                ],
              ],
              const SizedBox(height: 26),
              PillButton(
                'Add a repeating expense',
                glyph: MullGlyph.plus,
                onTap: () => showRecurringEditor(context, group),
              ),
              const SizedBox(height: 14),
              Text(
                'Everything already added stays put if you delete a schedule — '
                'those were real payments.',
                style: ranade(11.5, height: 1.6, color: c.ink3),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({super.key, required this.group, required this.schedule});

  final Group group;
  final Recurring schedule;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final due = schedule.isDue(store.now());

    return Pressable(
      onTap: () => showRecurringEditor(context, group, existing: schedule),
      scale: .985,
      haptic: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (schedule.paused) ...[
                        MullIcon(MullGlyph.pause, size: 13, color: c.ink3, strokeWidth: 1.8),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          schedule.description,
                          style: ranade(15.5, color: schedule.isActive ? c.ink : c.ink3),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    switch (schedule) {
                      _ when schedule.paused => 'Paused',
                      _ when schedule.hasEnded => 'Finished',
                      _ when due => 'Due ${relativeDay(schedule.nextDue, store.now())}',
                      _ => '${schedule.frequency.label} · next ${shortDateWithYear(schedule.nextDue, store.now())}',
                    },
                    style: ranade(11.5, color: c.ink3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              inr(schedule.amount),
              style: excon(18, color: schedule.isActive ? c.ink : c.ink3),
            ),
          ],
        ),
      ),
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
              'The schedule goes. Everything it has already added stays — that '
              'was real money.',
              style: ranade(14, height: 1.6, color: sheet.c.ink3),
            ),
            const SizedBox(height: 24),
            PillButton('Stop it', onTap: () => Navigator.of(sheet).pop(true)),
            const SizedBox(height: 8),
            GhostButton('Keep it', onTap: () => Navigator.of(sheet).pop(false)),
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

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Not the description: the field right below already says it, and
        // a header that repeats the first line reads as a mistake.
        SheetHeader(widget.existing == null ? 'New repeating expense' : 'Repeating expense'),
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
                  hint: 'Rent',
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _amountFocus.requestFocus(),
                ),
                const SizedBox(height: 22),
                BigField(
                  controller: _amount,
                  focusNode: _amountFocus,
                  numeric: true,
                  hint: '₹0',
                  trailing: Text('each time', style: ranade(11.5, color: c.ink3)),
                ),
                const SizedBox(height: 28),
                const Eyebrow('How often'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final f in Frequency.values)
                      NameChip(f.label, selected: f == _frequency, onTap: () => setState(() => _frequency = f)),
                  ],
                ),
                const SizedBox(height: 20),
                _DateRow(
                  label: widget.existing == null ? 'Starts' : 'Next one',
                  value: shortDateWithYear(_nextDue, store.now()),
                  onTap: () => _pick(isEnd: false),
                ),
                _DateRow(
                  label: 'Stops after',
                  value: _endsOn == null ? 'Never' : shortDateWithYear(_endsOn!, store.now()),
                  onTap: () => _pick(isEnd: true),
                  onClear: _endsOn == null ? null : () => setState(() => _endsOn = null),
                ),
                const SizedBox(height: 26),
                SplitFields(model: _split, payerLabel: 'Who pays it'),
                const SizedBox(height: 26),
                CheckRow(
                  on: _autoAdd,
                  label: 'Add it without asking',
                  onTap: () => setState(() => _autoAdd = !_autoAdd),
                  help:
                      'Only for the ones that truly never change. Mull will still '
                      'tell you afterwards — an expense nobody was told about is an '
                      'expense nobody checked.',
                ),
                if (widget.existing != null) ...[
                  const SizedBox(height: 20),
                  CheckRow(
                    on: _paused,
                    label: 'Pause it',
                    onTap: () => setState(() => _paused = !_paused),
                    help:
                        'Keeps the schedule without it piling up. Nothing is owed '
                        'for the time it was off.',
                  ),
                  const SizedBox(height: 26),
                  GhostButton('Stop this schedule', onTap: _delete),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(26, 8, 26, keyboardUp ? 4 : 30),
          child: PillButton(widget.existing == null ? 'Set it up' : 'Save', onTap: _valid ? _save : null),
        ),
      ],
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({required this.label, required this.value, required this.onTap, this.onClear});

  final String label;
  final String value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

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
            const SizedBox(width: 6),
            if (onClear != null)
              CircleButton(
                filled: false,
                semanticLabel: 'Clear $label',
                onTap: onClear,
                child: MullIcon(MullGlyph.close, size: 15, color: c.ink3, strokeWidth: 1.8),
              )
            else
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: MullIcon(MullGlyph.chevronRight, size: 15, color: c.ink3, strokeWidth: 1.7),
              ),
          ],
        ),
      ),
    );
  }
}
