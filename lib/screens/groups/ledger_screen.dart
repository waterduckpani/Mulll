import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'group_sheets.dart';

/// Everything that has happened in a group, in two lists.
///
/// Expenses and settlements are different kinds of fact and get told apart
/// rather than interleaved: one is what things cost, the other is who has paid
/// whom back. Nothing is ever removed for being old.
class LedgerScreen extends StatefulWidget {
  const LedgerScreen({super.key, required this.groupId});

  final String groupId;

  @override
  State<LedgerScreen> createState() => _LedgerScreenState();
}

class _LedgerScreenState extends State<LedgerScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final group = store.groupById(widget.groupId);
    if (group == null) return const SizedBox.shrink();

    final onExpenses = _tab == 0;
    final settled = store.settledExpenses(group);

    final expenses = [...group.expenses]..sort((a, b) => b.date.compareTo(a.date));
    final settlements = [...group.settlements]..sort((a, b) => b.date.compareTo(a.date));

    return MullPage(
      glow: const GlowSpec(size: 430, top: -160, left: -150, right: null),
      header: const DetailBar(),
      footnote: onExpenses
          ? (expenses.isEmpty ? null : 'Settled items stay here for good.')
          : (settlements.isEmpty ? null : 'A claim only clears a balance once it is confirmed.'),
      bottom: PillButton(
        'Add an expense',
        onTap: () => showAddExpense(context, group),
      ),
      children: [
        const PageTitle('Ledger', padding: EdgeInsets.fromLTRB(Gutter.text, 22, Gutter.text, 0)),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.card, 24, Gutter.card, 0),
          child: Segmented(
            labels: const ['Expenses', 'Settlements'],
            index: _tab,
            onChanged: (i) => setState(() => _tab = i),
          ),
        ),
        const SizedBox(height: 28),

        if (onExpenses)
          if (expenses.isEmpty)
            const _Nothing(
              title: 'Nothing spent yet',
              body: 'Add the first expense and it shows up here, with who paid '
                  'and how it was split.',
            )
          else
            ..._byMonth(
              context,
              store,
              [for (final e in expenses) (e.date, e)],
              (item) => _ExpenseRow(
                key: ValueKey(item.id as String),
                group: group,
                expense: item as Expense,
                settled: settled.contains(item.id),
              ),
            )
        else if (settlements.isEmpty)
          const _Nothing(
            title: 'Nobody has paid anybody yet',
            body: 'Every payment between the people in this group lands here, '
                'along with who confirmed it.',
          )
        else
          ..._byMonth(
            context,
            store,
            [for (final s in settlements) (s.date, s)],
            (item) => _SettlementRow(
              key: ValueKey((item as Settlement).id),
              group: group,
              settlement: item,
            ),
          ),
      ],
    );
  }
}

/// Groups rows under a month eyebrow, newest month first.
List<Widget> _byMonth(
  BuildContext context,
  MullStore store,
  List<(DateTime, Object)> items,
  Widget Function(dynamic item) row,
) {
  final out = <Widget>[];
  String? month;
  for (final (date, item) in items) {
    final label = monthLabel(date, store.now());
    if (label != month) {
      month = label;
      out.add(
        Eyebrow(
          label,
          size: 10.5,
          tracking: .18,
          padding: EdgeInsets.fromLTRB(Gutter.text, out.isEmpty ? 0 : 30, Gutter.text, 14),
        ),
      );
    }
    out.add(row(item));
  }
  return out;
}

/// One line in the ledger. No card: rows are separated by a hairline, which is
/// the only place in Mull that draws a rule.
class _Row extends StatelessWidget {
  const _Row({
    required this.title,
    required this.caption,
    required this.amount,
    this.dimmed = false,
    this.trailing,
    this.onTap,
    this.onLongPress,
  });

  final String title;
  final String caption;
  final int amount;
  final bool dimmed;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: .99,
      haptic: false,
      semanticLabel: '$title, ${inr(amount)}, $caption',
      child: ExcludeSemantics(
        child: Opacity(
          opacity: dimmed ? .55 : 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
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
                                    title,
                                    style: ranade(16, color: c.ink),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                ?trailing,
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              caption,
                              style: MullType.caption(c.ink3, size: 11.5),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),
                      Text(inr(amount), style: MullType.listAmount(c.ink)),
                    ],
                  ),
                ),
                const Hairline(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpenseRow extends StatelessWidget {
  const _ExpenseRow({
    super.key,
    required this.group,
    required this.expense,
    required this.settled,
  });

  final Group group;
  final Expense expense;
  final bool settled;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final payer = group.memberById(expense.payerId);

    final split = switch (expense.method) {
      SplitMethod.equal => 'split ${expense.shares.length} ways',
      SplitMethod.exact => 'exact amounts',
      SplitMethod.shares => 'by shares',
      SplitMethod.percent => 'by percentage',
    };

    return _Row(
      title: expense.description,
      caption: [
        payer == null ? 'someone paid' : '${store.shortName(payer)} paid',
        if (settled) 'settled' else split,
        shortDate(expense.date),
      ].join(' · '),
      amount: expense.amount,
      dimmed: settled,
      trailing: expense.isRecurring
          ? Padding(
              padding: const EdgeInsets.only(left: 8),
              child: MullIcon(MullGlyph.repeat, size: 13, color: c.ink3, strokeWidth: 1.7),
            )
          : null,
      onTap: () => showAddExpense(context, group, existing: expense),
      onLongPress: () => showExpenseActions(context, group, expense),
    );
  }
}

class _SettlementRow extends StatelessWidget {
  const _SettlementRow({super.key, required this.group, required this.settlement});

  final Group group;
  final Settlement settlement;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final from = group.memberById(settlement.fromId);
    final to = group.memberById(settlement.toId);
    String name(Member? m) => m == null ? 'Someone' : store.shortName(m);

    return _Row(
      title: settlement.status == SettlementStatus.confirmed
          ? '${name(from)} paid ${name(to)}'
          : '${name(from)} says they paid ${name(to)}',
      caption: [
        switch (settlement.status) {
          SettlementStatus.confirmed => 'Confirmed',
          SettlementStatus.pending => 'Waiting to be confirmed',
          SettlementStatus.disputed => 'Not received',
        },
        if (settlement.utr != null) 'UPI ref ${settlement.utr}',
        shortDate(settlement.date),
      ].join(' · '),
      amount: settlement.amount,
      dimmed: settlement.status == SettlementStatus.confirmed,
      onTap: settlement.status == SettlementStatus.pending &&
              settlement.toId == group.you?.id
          ? () => showClaimCheck(context, group, settlement)
          : null,
      onLongPress: () {
        store.removeSettlement(group, settlement);
        Toast.show(
          context,
          'Settlement removed',
          action: 'Undo',
          onAction: () {
            group.settlements.add(settlement);
            store.updateGroup(group);
          },
        );
      },
    );
  }
}

class _Nothing extends StatelessWidget {
  const _Nothing({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gutter.text, 16, Gutter.text, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: MullType.statement(c.ink, size: 26)),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 300),
            child: Text(body, style: MullType.body(c.ink3)),
          ),
        ],
      ),
    );
  }
}
