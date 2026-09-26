import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../core/split.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/page.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'group_sheets.dart';

/// What you owe, and what you are owed, in one group — and nothing else.
///
/// It used to show the fewest transfers that clear the whole group. That put
/// other people's payments on your screen with a "Mark as settled" button, and
/// it netted you out of the middle: owed ₹226 by one person and owing ₹226 to
/// another, you were "square" and they were told to pay each other.
class SettleUpScreen extends StatelessWidget {
  const SettleUpScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final group = store.groupById(groupId);
    if (group == null) return const SizedBox.shrink();

    final transfers = group.yourTransfers;
    final books = group.placeholderTransfers;
    final owing = group.youOweHere;
    final owed = group.owedToYouHere;
    // Balances between other people are theirs. Said once, so an empty screen
    // in a group that is plainly not settled does not read as a bug.
    final othersOpen = transfers.isEmpty && books.isEmpty && !group.isSettled;

    return MullPage(
      glow: const GlowSpec(size: 440, top: -160, right: -150),
      header: const DetailBar(),
      footnote: transfers.isEmpty
          ? null
          : 'Money never moves through Mull.\nPay over UPI, then say it went through.',
      bottom: group.isSettled
          ? null
          : SecondaryButton(
              'Send summary on WhatsApp',
              onTap: () => shareGroupSummary(context, group),
            ),
      children: [
        PageStatement(
          switch (null) {
            _ when group.expenses.isEmpty => 'Nothing added to this group yet',
            _ when transfers.isEmpty => "You're square here",
            _ when owing > 0 && owed > 0 => 'You owe ${inr(owing)} and are owed ${inr(owed)}',
            _ when owing > 0 => 'You owe ${inr(owing)}',
            _ => "You're owed ${inr(owed)}",
          },
          body: switch (null) {
            _ when group.expenses.isEmpty => 'Add an expense and Mull starts working out who owes whom.',
            _ when othersOpen =>
              'Other people here still owe each other. That is between them, '
                  'and only they can settle it.',
            _ when owing > 0 && owed > 0 =>
              'These are separate people, so they do not cancel out. Each one '
                  'is settled on its own.',
            _ => '${group.title} · ${inr(group.total)} spent between '
                '${group.members.length} people',
          },
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
                  lift: t == transfers.first ? Lift.focal : Lift.card,
                ),
            ],
          ),
        ],

        // Two people with no account between them have nobody else to write
        // their payment down. Anybody else's is theirs alone.
        if (books.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Gutter.text, 40, Gutter.text, 14),
            child: Text(
              'Neither of these people is on Mull, so you keep the record for them.',
              style: MullType.caption(context.c.ink3),
            ),
          ),
          Stacked(
            gap: 8,
            padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
            children: [
              for (final t in books)
                _TransferCard(
                  key: ValueKey('${t.from}-${t.to}'),
                  group: group,
                  transfer: t,
                  lift: Lift.flat,
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
    required this.lift,
  });

  final Group group;
  final Transfer transfer;
  final Lift lift;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final from = group.memberById(transfer.from);
    final to = group.memberById(transfer.to);
    if (from == null || to == null) return const SizedBox.shrink();

    final youPay = from.isYou;
    final forThem = !youPay && !to.isYou;
    final other = youPay ? to : from;
    final name = store.shortName(other);

    // What has already been said to have gone, and what that leaves. A claim
    // does not move the balance until it is confirmed, so without this the
    // card kept offering the whole amount again — pay twice, and send them a
    // second "says they sent you" for the same money.
    final claimed = group.claimedBetween(transfer.from, transfer.to);
    final left = (transfer.amount - claimed).clamp(0, transfer.amount);
    final claim = group.settlements
        .where(
          (s) =>
              s.status == SettlementStatus.pending &&
              s.fromId == transfer.from &&
              s.toId == transfer.to,
        )
        .firstOrNull;

    final title = forThem
        ? '${store.shortName(from)} pays ${store.shortName(to)}'
        : youPay
        ? 'You pay $name'
        : '$name pays you';
    final shown = claimed > 0 && left > 0 ? left : transfer.amount;

    final detail = switch (null) {
      _ when forThem => 'Neither is on Mull · mark it once they have settled',
      _ when claim != null && !youPay && left == 0 => 'They said they sent it · check and confirm',
      _ when claim != null && !youPay =>
        'They said they sent ${inr(claimed)} · check and confirm',
      _ when claim != null && left == 0 => 'Sent · waiting on $name to confirm',
      _ when claim != null => '${inr(claimed)} sent, waiting on $name · ${inr(left)} still to pay',
      _ when youPay && to.upiId != null => 'Pay over UPI, then say it went through',
      _ when youPay => 'No UPI ID on their seat yet · settle in person, then mark it',
      _ when !from.isLinked => 'Not on Mull · settle in person, then mark it',
      _ => 'Nudge them, or mark it once it lands',
    };

    void open() {
      switch (claim) {
        case _ when forThem:
          showSettleUp(context, group, transfer);
        case final pending? when !youPay:
          showClaimCheck(context, group, pending);
        case final pending? when left == 0:
          showOwnClaim(context, group, pending);
        default:
          showSettleUp(
            context,
            group,
            Transfer(from: transfer.from, to: transfer.to, amount: youPay ? left : transfer.amount),
          );
      }
    }

    return Pressable(
      onTap: open,
      scale: .985,
      semanticLabel: '$title ${inr(shown)}. $detail',
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
                  Text(inr(shown), style: MullType.cardAmount(c.ink, size: 22)),
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
