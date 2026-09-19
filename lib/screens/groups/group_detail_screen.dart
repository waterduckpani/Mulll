import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/cycle.dart';
import '../../core/money.dart';
import '../../core/split.dart';
import '../../core/upi.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'group_sheets.dart';

class GroupDetailScreen extends StatelessWidget {
  const GroupDetailScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final c = context.c;
    final group = store.groups.where((g) => g.id == groupId).firstOrNull;
    if (group == null) return const SizedBox.shrink();

    final balance = group.yourBalance;
    final transfers = simplify(group.balances);
    final activity = store.activity(group);

    Future<void> settings() async {
      final result = await showGroupSettings(context, group);
      if (result == 'deleted' && context.mounted) Navigator.of(context).pop();
    }

    Future<void> share() async {
      final sent = await shareOnWhatsApp(store.groupSummary(group));
      if (!sent && context.mounted) Toast.show(context, "Couldn't open WhatsApp");
    }

    return MullPage(
      blobs: const [
        BlobSpec(360, 66, top: -70, left: -90),
        BlobSpec(280, 70, bottom: 40, right: -100),
      ],
      bottom: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PillButton('Add an expense', onTap: () => showAddExpense(context, group)),
          if (transfers.isNotEmpty) ...[
            const SizedBox(height: 8),
            GhostButton('Send summary on WhatsApp', onTap: share),
          ],
        ],
      ),
      children: [
        DetailBar(
          label: '${group.members.length} people',
          onLabelTap: settings,
          trailing: CircleButton(
            filled: false,
            semanticLabel: 'Group settings',
            onTap: settings,
            child: MullIcon(MullGlyph.more, size: 18, color: c.ink3),
          ),
        ),
        Glass(
          margin: const EdgeInsets.fromLTRB(22, 12, 22, 0),
          radius: 34,
          padding: const EdgeInsets.fromLTRB(26, 22, 26, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(group.name, style: excon(28, tracking: -.02, color: c.ink)),
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
                  '${inr(group.total)} spent across ${group.expenses.length} ${group.expenses.length == 1 ? 'expense' : 'expenses'}',
                  style: ranade(11.5, color: c.ink3),
                ),
              ],
            ],
          ),
        ),
        for (final claim in group.awaitingYourConfirmation)
          _ClaimCard(key: ValueKey(claim.id), group: group, settlement: claim),
        if (transfers.isNotEmpty) ...[
          const Eyebrow('Who pays whom', padding: EdgeInsets.fromLTRB(30, 20, 30, 0)),
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 4, 30, 0),
            child: Text(
              transfers.length == 1
                  ? 'One payment clears the whole group.'
                  : '${transfers.length} payments clear the whole group.',
              style: ranade(11.5, color: c.ink3),
            ),
          ),
          Glass(
            margin: const EdgeInsets.fromLTRB(22, 12, 22, 0),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: CardRows(
              children: [
                for (final t in transfers)
                  _TransferRow(
                    key: ValueKey('${t.from}-${t.to}'),
                    group: group,
                    transfer: t,
                  ),
              ],
            ),
          ),
        ],
        if (activity.isNotEmpty) ...[
          const Eyebrow('Activity', padding: EdgeInsets.fromLTRB(30, 22, 30, 0)),
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
                  Text(
                    expense.description,
                    style: ranade(15.5, color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
