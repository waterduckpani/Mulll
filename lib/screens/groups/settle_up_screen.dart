import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../core/split.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/page.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'group_sheets.dart';

/// The fewest payments that clear the group, and what to do about each one.
///
/// The whole point of Mull in one screen: eleven expenses between four people
/// come down to two transfers, and every one of them says plainly whose move
/// it is.
class SettleUpScreen extends StatelessWidget {
  const SettleUpScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final group = store.groupById(groupId);
    if (group == null) return const SizedBox.shrink();

    final transfers = simplify(group.balances);
    final me = group.you?.id;

    // A claim already sitting against a transfer changes what the row is for:
    // there is nothing to pay, only something to confirm.
    Settlement? claimAgainst(Transfer t) => group.settlements
        .where(
          (s) =>
              s.status == SettlementStatus.pending &&
              s.fromId == t.from &&
              s.toId == t.to,
        )
        .firstOrNull;

    // One focal object: the first row that is actually yours to move on.
    Transfer? focal;
    for (final t in transfers) {
      if (t.from == me || t.to == me) {
        focal = t;
        break;
      }
    }

    return MullPage(
      glow: const GlowSpec(size: 440, top: -160, right: -150),
      header: const DetailBar(),
      footnote: transfers.isEmpty
          ? null
          : 'Money never moves through Mull.\nPay over UPI, then say it went through.',
      bottom: transfers.isEmpty
          ? null
          : SecondaryButton(
              'Send summary on WhatsApp',
              onTap: () => shareGroupSummary(context, group),
            ),
      children: [
        PageStatement(
          switch (transfers.length) {
            0 => group.expenses.isEmpty
                ? 'Nothing added to this group yet'
                : 'Everyone is square',
            1 => 'One payment clears this group',
            2 => 'Two payments clear this group',
            3 => 'Three payments clear this group',
            _ => '${transfers.length} payments clear this group',
          },
          body: group.expenses.isEmpty
              ? 'Add an expense and Mull starts working out who owes whom.'
              : '${group.title} · ${inr(group.total)} spent between '
                    '${group.members.length} people',
          padding: const EdgeInsets.fromLTRB(Gutter.text, 30, Gutter.text, 0),
        ),

        if (transfers.isNotEmpty) ...[
          const SizedBox(height: 40),
          Stacked(
            gap: 8,
            padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
            children: [
              for (final t in transfers)
                _TransferCard(
                  key: ValueKey('${t.from}-${t.to}'),
                  group: group,
                  transfer: t,
                  claim: claimAgainst(t),
                  lift: t == focal ? Lift.focal : Lift.card,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _TransferCard extends StatelessWidget {
  const _TransferCard({
    super.key,
    required this.group,
    required this.transfer,
    required this.claim,
    required this.lift,
  });

  final Group group;
  final Transfer transfer;
  final Settlement? claim;
  final Lift lift;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final from = group.memberById(transfer.from);
    final to = group.memberById(transfer.to);
    if (from == null || to == null) return const SizedBox.shrink();

    final youPay = from.isYou;
    final youAreOwed = to.isYou;

    final title = youPay
        ? 'You pay ${store.shortName(to)}'
        : youAreOwed
        ? '${store.shortName(from)} pays you'
        : '${store.shortName(from)} pays ${store.shortName(to)}';

    final detail = switch (null) {
      _ when claim != null && youAreOwed => 'They said they sent it · waiting on you to confirm',
      _ when claim != null => 'Claimed · waiting on ${store.shortName(to)} to confirm',
      _ when youPay && to.upiId != null => 'Pay over UPI, then say it went through',
      _ when youPay => 'No UPI ID on their seat yet · settle in person, then mark it',
      _ when !from.isLinked && youAreOwed => 'Not on Mull · settle in person, then mark it',
      _ when youAreOwed => 'Nudge them, or mark it once it lands',
      _ => 'Between them. Mull just keeps the record',
    };

    return Pressable(
      onTap: () {
        final pending = claim;
        if (pending != null && youAreOwed) {
          showClaimCheck(context, group, pending);
        } else {
          showSettleUp(context, group, transfer);
        }
      },
      scale: .985,
      semanticLabel: '$title ${inr(transfer.amount)}. $detail',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 22),
          decoration: surfaceOf(c, lift, radius: BorderRadius.circular(28)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: MullType.cardTitle(c.ink, size: 18),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(inr(transfer.amount), style: MullType.cardAmount(c.ink, size: 22)),
                ],
              ),
              const SizedBox(height: 8),
              Text(detail, style: MullType.body(c.ink3)),
            ],
          ),
        ),
      ),
    );
  }
}
