import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/split.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'group_sheets.dart';
import 'recurring_sheets.dart';

/// One ledger: where it stands, who pays whom, what repeats, what happened.
///
/// The same screen serves a ten-person trip and a one-to-one with a friend —
/// the arithmetic does not care, so neither does the layout. Only the bits that
/// would be nonsense for two people are hidden.
class GroupDetailScreen extends StatelessWidget {
  const GroupDetailScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final c = context.c;
    final group = store.groupById(groupId);
    if (group == null) return const SizedBox.shrink();

    final balance = group.yourBalance;
    final transfers = simplify(group.balances);
    final activity = store.activity(group);
    final due = group.recurring.where((r) => r.isDue(store.now())).toList();
    final upcoming = group.recurring.where((r) => r.isActive && !r.isDue(store.now())).toList()
      ..sort((a, b) => a.nextDue.compareTo(b.nextDue));

    Future<void> settings() async {
      final result = await showGroupSettings(context, group);
      if (result == 'deleted' && context.mounted) Navigator.of(context).pop();
    }

    return MullPage(
      blobs: const [
        BlobSpec(360, 66, top: -70, left: -90),
        BlobSpec(280, 70, bottom: 40, right: -100),
      ],
      header: DetailBar(
        label: group.isDirect ? 'Just you two' : '${group.members.length} people',
        onLabelTap: settings,
        trailing: CircleButton(
          filled: false,
          semanticLabel: 'Settings',
          onTap: settings,
          child: MullIcon(MullGlyph.more, size: 18, color: c.ink3),
        ),
      ),
      bottom: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PillButton('Add an expense', glyph: MullGlyph.plus, onTap: () => showAddExpense(context, group)),
          if (transfers.isNotEmpty) ...[
            const SizedBox(height: 8),
            GhostButton('Send summary on WhatsApp', onTap: () => shareGroupSummary(context, group)),
          ],
        ],
      ),
      children: [
        Glass(
          margin: const EdgeInsets.fromLTRB(22, 12, 22, 0),
          radius: 34,
          padding: const EdgeInsets.fromLTRB(26, 22, 26, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(group.title, style: excon(28, tracking: -.02, color: c.ink)),
              const SizedBox(height: 18),
              Text(
                balance == 0
                    ? (group.expenses.isEmpty ? 'Nothing added yet' : 'All settled up')
                    : balance > 0
                    ? "You're owed"
                    : 'You owe',
                style: ranade(12, tracking: .06, color: c.ink3),
              ),
              const SizedBox(height: 6),
              if (balance != 0)
                AnimatedAmount(balance.abs(), style: excon(52, tracking: -.04, height: .95, color: c.ink))
              else
                Text(
                  group.expenses.isEmpty
                      ? 'Add the first expense and Mull starts keeping score.'
                      : 'Nobody owes anybody.',
                  style: ranade(14, height: 1.5, color: c.ink2),
                ),
              if (group.expenses.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  '${inr(group.total)} spent across ${group.expenses.length} '
                  '${group.expenses.length == 1 ? 'expense' : 'expenses'}',
                  style: ranade(11.5, color: c.ink3),
                ),
              ],
            ],
          ),
        ),

        for (final claim in group.awaitingYourConfirmation)
          _ClaimCard(key: ValueKey(claim.id), group: group, settlement: claim),

        if (due.isNotEmpty) ...[
          const Eyebrow('Due now', padding: EdgeInsets.fromLTRB(30, 22, 30, 0)),
          for (final schedule in due)
            _DueRow(key: ValueKey(schedule.id), group: group, schedule: schedule),
        ],

        if (transfers.isNotEmpty) ...[
          const Eyebrow('Who pays whom', padding: EdgeInsets.fromLTRB(30, 22, 30, 0)),
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 4, 30, 0),
            child: Text(
              transfers.length == 1
                  ? 'One payment clears the whole thing.'
                  : '${transfers.length} payments clear the whole thing.',
              style: ranade(11.5, color: c.ink3),
            ),
          ),
          Glass(
            margin: const EdgeInsets.fromLTRB(22, 12, 22, 0),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: CardRows(
              children: [
                for (final t in transfers)
                  _TransferRow(key: ValueKey('${t.from}-${t.to}'), group: group, transfer: t),
              ],
            ),
          ),
        ],

        // The schedules sit above the history because they are the only thing
        // on this screen that is about what happens next.
        Padding(
          padding: const EdgeInsets.fromLTRB(30, 26, 30, 0),
          child: Row(
            children: [
              Expanded(child: Eyebrow('Repeating${group.recurring.isEmpty ? '' : ' · ${group.recurring.length}'}')),
              Pressable(
                onTap: () => showRecurringList(context, group),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                  child: Text(
                    group.recurring.isEmpty ? 'Set one up' : 'Manage',
                    style: ranade(12, color: c.ink2),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (upcoming.isEmpty && due.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 8, 30, 0),
            child: Text(
              'Rent, wifi, the maid — anything that comes round on its own. Mull '
              'asks when each one is due.',
              style: ranade(11.5, height: 1.6, color: c.ink3),
            ),
          )
        else if (upcoming.isNotEmpty)
          Glass(
            margin: const EdgeInsets.fromLTRB(22, 12, 22, 0),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: CardRows(
              children: [
                for (final r in upcoming)
                  _UpcomingRow(key: ValueKey(r.id), group: group, schedule: r),
              ],
            ),
          ),

        if (activity.isNotEmpty) ...[
          const Eyebrow('Activity', padding: EdgeInsets.fromLTRB(30, 26, 30, 0)),
          Glass(
            margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: CardRows(
              children: [
                for (final entry in activity)
                  if (entry is Expense)
                    _ExpenseRow(key: ValueKey(entry.id), group: group, expense: entry)
                  else
                    _SettlementRow(key: ValueKey((entry as Settlement).id), group: group, settlement: entry),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Someone says they have paid you. Only you can say whether it landed, so
/// this sits above everything else until you answer it.
class _ClaimCard extends StatelessWidget {
  const _ClaimCard({super.key, required this.group, required this.settlement});

  final Group group;
  final Settlement settlement;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final from = group.memberById(settlement.fromId);
    if (from == null) return const SizedBox.shrink();

    return Glass(
      margin: const EdgeInsets.fromLTRB(22, 14, 22, 0),
      radius: 28,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow('${store.shortName(from)} says they paid you'),
          const SizedBox(height: 10),
          Text(inr(settlement.amount), style: excon(34, tracking: -.03, color: c.ink)),
          const SizedBox(height: 8),
          Text(
            settlement.utr == null
                ? 'Until you say it arrived, they still owe it.'
                : 'UPI ref ${settlement.utr} · until you say it arrived, they still owe it.',
            style: ranade(12, height: 1.5, color: c.ink3),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: PillButton(
                  'It arrived',
                  onTap: () {
                    store.confirmSettlement(group, settlement);
                    HapticFeedback.mediumImpact();
                    Toast.show(context, '${inr(settlement.amount)} settled');
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GhostButton(
                  "It hasn't",
                  onTap: () {
                    store.disputeSettlement(group, settlement);
                    Toast.show(context, 'Marked as not received');
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A schedule whose turn has come, inside the group it belongs to.
class _DueRow extends StatelessWidget {
  const _DueRow({super.key, required this.group, required this.schedule});

  final Group group;
  final Recurring schedule;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;

    return Glass(
      margin: const EdgeInsets.fromLTRB(22, 12, 22, 0),
      radius: 26,
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              MullIcon(MullGlyph.repeat, size: 15, color: c.ink3, strokeWidth: 1.7),
              const SizedBox(width: 8),
              Expanded(
                child: Text(schedule.description, style: ranade(16, color: c.ink), maxLines: 1),
              ),
              Text(inr(schedule.amount), style: excon(19, color: c.ink)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Due ${relativeDay(schedule.nextDue, store.now())} · ${schedule.frequency.shortLabel}',
            style: ranade(11.5, color: c.ink3),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: PillButton('Add it', onTap: () => showDueRecurring(context, group, schedule)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GhostButton(
                  'Not this time',
                  onTap: () {
                    store.skipDue(group, schedule);
                    Toast.show(context, 'Skipped · next ${shortDate(schedule.nextDue)}');
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _UpcomingRow extends StatelessWidget {
  const _UpcomingRow({super.key, required this.group, required this.schedule});

  final Group group;
  final Recurring schedule;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;

    return Pressable(
      onTap: () => showRecurringEditor(context, group, existing: schedule),
      scale: .985,
      haptic: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    schedule.description,
                    style: ranade(15.5, weight: FontWeight.w300, color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${schedule.frequency.label} · next ${shortDateWithYear(schedule.nextDue, store.now())}'
                    '${schedule.autoAdd ? ' · adds itself' : ''}',
                    style: ranade(11.5, color: c.ink3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(inr(schedule.amount), style: excon(18, weight: FontWeight.w300, color: c.ink)),
          ],
        ),
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({super.key, required this.group, required this.transfer});

  final Group group;
  final Transfer transfer;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final from = group.memberById(transfer.from);
    final to = group.memberById(transfer.to);
    if (from == null || to == null) return const SizedBox.shrink();

    final mine = from.isYou || to.isYou;

    return Pressable(
      onTap: () => showSettleUp(context, group, transfer),
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
                  Text(
                    '${store.shortName(from)} → ${store.shortName(to)}',
                    style: ranade(15.5, weight: mine ? FontWeight.w400 : FontWeight.w300, color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    from.isYou
                        ? (to.upiId == null ? 'Tap to settle' : 'Tap to pay over UPI')
                        : to.isYou
                        ? 'Tap to record it, or send a reminder'
                        : 'Tap when it is paid',
                    style: ranade(11.5, color: c.ink3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(inr(transfer.amount), style: excon(19, color: c.ink)),
          ],
        ),
      ),
    );
  }
}

class _ExpenseRow extends StatelessWidget {
  const _ExpenseRow({super.key, required this.group, required this.expense});

  final Group group;
  final Expense expense;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final payer = group.memberById(expense.payerId);
    final yourShare = expense.shares[group.you?.id] ?? 0;

    return Pressable(
      onTap: () => showAddExpense(context, group, existing: expense),
      onLongPress: () => _expenseActions(context, group, expense),
      scale: .985,
      haptic: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          expense.description,
                          style: ranade(15.5, color: c.ink),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (expense.isRecurring) ...[
                        const SizedBox(width: 8),
                        MullIcon(MullGlyph.repeat, size: 13, color: c.ink3, strokeWidth: 1.6),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      payer == null ? 'someone paid' : '${store.shortName(payer)} paid',
                      if (yourShare > 0) 'your share ${inr(yourShare)}',
                      shortDate(expense.date),
                    ].join(' · '),
                    style: ranade(11.5, color: c.ink3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (expense.note != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      expense.note!,
                      style: ranade(11.5, height: 1.5, color: c.ink3),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(inr(expense.amount), style: excon(18, color: c.ink)),
          ],
        ),
      ),
    );
  }
}

class _SettlementRow extends StatelessWidget {
  const _SettlementRow({super.key, required this.group, required this.settlement});

  final Group group;
  final Settlement settlement;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final from = group.memberById(settlement.fromId);
    final to = group.memberById(settlement.toId);

    return Pressable(
      onLongPress: () {
        store.removeSettlement(group, settlement);
        Toast.show(context, 'Settlement removed');
      },
      scale: .985,
      haptic: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    settlement.status == SettlementStatus.confirmed
                        ? '${from == null ? '?' : store.shortName(from)} paid ${to == null ? '?' : store.shortName(to)}'
                        : '${from == null ? '?' : store.shortName(from)} says they paid ${to == null ? '?' : store.shortName(to)}',
                    style: ranade(15.5, weight: FontWeight.w300, color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    switch (settlement.status) {
                      SettlementStatus.confirmed => 'Settled · ${shortDate(settlement.date)}',
                      SettlementStatus.pending => 'Waiting to be confirmed · ${shortDate(settlement.date)}',
                      SettlementStatus.disputed => 'Not received · ${shortDate(settlement.date)}',
                    },
                    style: ranade(11.5, color: c.ink3),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(inr(settlement.amount), style: excon(18, weight: FontWeight.w300, color: c.ink)),
          ],
        ),
      ),
    );
  }
}

Future<void> _expenseActions(BuildContext context, Group group, Expense expense) {
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
                  child: Text(expense.description, style: excon(24, tracking: -.02, color: sheet.c.ink), maxLines: 2),
                ),
                Text(inr(expense.amount), style: excon(20, color: sheet.c.ink)),
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
