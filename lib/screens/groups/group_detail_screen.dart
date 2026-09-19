import 'package:flutter/cupertino.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../core/split.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'group_sheets.dart';
import 'ledger_screen.dart';
import 'recurring_screen.dart';
import 'recurring_sheets.dart';
import 'settle_up_screen.dart';

/// One ledger: where it stands, and the three places you can go from it.
///
/// This screen used to be everything at once, which meant the number you came
/// for was competing with eleven expenses, four schedules and a settlement
/// history. Now it answers "where do I stand" and hands off: settling up,
/// what repeats, and what happened are each their own screen.
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
    final claims = group.awaitingYourConfirmation;
    final due = group.recurring.where((r) => r.isDue(store.now())).toList();
    final active = group.recurring.where((r) => r.isActive).length;
    final settlements = group.settlements.length;

    Future<void> settings() async {
      final result = await showGroupSettings(context, group);
      if (result == 'deleted' && context.mounted) Navigator.of(context).pop();
    }

    void push(Widget screen) =>
        Navigator.of(context).push(CupertinoPageRoute(builder: (_) => screen));

    // One focal object. Whatever is waiting on an answer takes it; with
    // nothing outstanding, settling up does.
    final somethingWaiting = claims.isNotEmpty || due.isNotEmpty;

    return MullPage(
      glow: const GlowSpec(size: 440, top: -160, left: -150, right: null),
      header: DetailBar(
        // The people count is the subtitle under the title. Repeating it up
        // here as an eyebrow reads as a mistake.
        trailing: CircleButton(
          semanticLabel: 'Group settings',
          onTap: settings,
          child: MullIcon(MullGlyph.more, size: 17, color: c.ink2),
        ),
      ),
      bottom: PillButton(
        'Add an expense',
        glyph: MullGlyph.plus,
        onTap: () => showAddExpense(context, group),
      ),
      children: [
        PageTitle(
          group.title,
          subtitle: group.isDirect ? 'Just you two' : '${group.members.length} people',
          padding: const EdgeInsets.fromLTRB(Gutter.text, 22, Gutter.text, 0),
        ),

        HeroAmount(
          caption: balance == 0
              ? (group.expenses.isEmpty ? 'Nothing added yet' : 'All settled up')
              : balance > 0
              ? 'You get back'
              : 'You owe',
          amount: balance == 0 ? null : balance.abs(),
          size: 68,
          placeholder: group.expenses.isEmpty ? 'Add the first\nexpense.' : 'Nobody owes\nanybody.',
          padding: const EdgeInsets.fromLTRB(Gutter.text, 34, Gutter.text, 0),
        ),

        const SizedBox(height: 42),

        // Anything with a deadline on it, before the destinations.
        if (claims.isNotEmpty)
          Stacked(
            gap: 8,
            padding: const EdgeInsets.fromLTRB(Gutter.card, 0, Gutter.card, 10),
            children: [
              for (final settlement in claims)
                _ClaimCard(
                  key: ValueKey(settlement.id),
                  group: group,
                  settlement: settlement,
                  lift: settlement == claims.first ? Lift.focal : Lift.card,
                ),
            ],
          ),
        if (due.isNotEmpty)
          Stacked(
            gap: 8,
            padding: const EdgeInsets.fromLTRB(Gutter.card, 0, Gutter.card, 10),
            children: [
              for (final schedule in due)
                _DueCard(
                  key: ValueKey(schedule.id),
                  group: group,
                  schedule: schedule,
                  lift: claims.isEmpty && schedule == due.first ? Lift.focal : Lift.card,
                ),
            ],
          ),

        Stacked(
          gap: 8,
          padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
          children: [
            _Destination(
              title: 'Settle up',
              body: transfers.isEmpty
                  ? 'Nothing outstanding right now'
                  : transfers.length == 1
                  ? 'One payment clears the group'
                  : '${_words(transfers.length)} payments clear the group',
              lift: somethingWaiting ? Lift.card : Lift.focal,
              onTap: () => push(SettleUpScreen(groupId: group.id)),
            ),
            _Destination(
              title: 'Recurring',
              detail: active == 0
                  ? 'none yet'
                  : '$active ${active == 1 ? 'schedule' : 'schedules'}',
              lift: Lift.flat,
              onTap: () => push(RecurringScreen(groupId: group.id)),
            ),
            _Destination(
              title: 'Ledger',
              detail: group.expenses.isEmpty && settlements == 0
                  ? 'nothing yet'
                  : '${group.expenses.length} ${group.expenses.length == 1 ? 'expense' : 'expenses'}',
              lift: Lift.flat,
              onTap: () => push(LedgerScreen(groupId: group.id)),
            ),
          ],
        ),

        if (group.expenses.isNotEmpty)
          Footnote(
            '${inr(group.total)} spent between ${group.members.length} people',
            padding: const EdgeInsets.fromLTRB(Gutter.text, 26, Gutter.text, 0),
          ),
      ],
    );
  }
}

/// Small counts read better as words in a sentence than as digits.
String _words(int n) => switch (n) {
  2 => 'Two',
  3 => 'Three',
  4 => 'Four',
  5 => 'Five',
  _ => '$n',
};

/// A place to go. Either the one focal card on the screen, or a quiet row.
class _Destination extends StatelessWidget {
  const _Destination({
    required this.title,
    this.body,
    this.detail,
    required this.lift,
    required this.onTap,
  });

  final String title;

  /// A supporting line under the title, on the focal variant.
  final String? body;

  /// A short right-aligned count, on the quiet variant.
  final String? detail;

  final Lift lift;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final quiet = lift == Lift.flat;
    return Pressable(
      onTap: onTap,
      scale: .985,
      semanticLabel: [title, ?body, ?detail].join(', '),
      child: ExcludeSemantics(
        child: Container(
          padding: EdgeInsets.fromLTRB(24, quiet ? 20 : 20, 20, quiet ? 20 : 22),
          decoration: surfaceOf(c, lift, radius: BorderRadius.circular(quiet ? 24 : 28)),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: MullType.cardTitle(quiet ? c.ink2 : c.ink, size: 18)),
                    if (body != null) ...[
                      const SizedBox(height: 6),
                      Text(body!, style: MullType.body(c.ink3)),
                    ],
                  ],
                ),
              ),
              if (detail != null) ...[
                const SizedBox(width: 12),
                Text(detail!, style: MullType.caption(c.ink3)),
              ],
              const SizedBox(width: 12),
              MullIcon(
                MullGlyph.chevronRight,
                size: 15,
                color: quiet ? c.ink3 : c.ink2,
                strokeWidth: 1.8,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Someone says they have paid you, inside the group it happened in.
class _ClaimCard extends StatelessWidget {
  const _ClaimCard({
    super.key,
    required this.group,
    required this.settlement,
    required this.lift,
  });

  final Group group;
  final Settlement settlement;
  final Lift lift;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final from = group.memberById(settlement.fromId);
    if (from == null) return const SizedBox.shrink();

    return Surface(
      lift: lift,
      radius: 28,
      padding: const EdgeInsets.fromLTRB(22, 18, 16, 18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${store.shortName(from)} says they sent you',
                  style: ranade(16, height: 1.35, color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(inr(settlement.amount), style: ranade(16, height: 1.35, color: c.ink)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          InlineButton(
            'Check',
            height: 48,
            onTap: () => showClaimCheck(context, group, settlement),
          ),
        ],
      ),
    );
  }
}

/// A schedule whose turn has come.
class _DueCard extends StatelessWidget {
  const _DueCard({
    super.key,
    required this.group,
    required this.schedule,
    required this.lift,
  });

  final Group group;
  final Recurring schedule;
  final Lift lift;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;

    return Surface(
      lift: lift,
      radius: 28,
      padding: const EdgeInsets.fromLTRB(22, 18, 16, 18),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${schedule.description} is due ${relativeDay(schedule.nextDue, store.now())}',
                  style: ranade(16, height: 1.35, color: c.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '${inr(schedule.amount)} · ${schedule.frequency.shortLabel}',
                  style: MullType.caption(c.ink3, size: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          InlineButton(
            'Open it',
            height: 48,
            onTap: () => showDueRecurring(context, group, schedule),
          ),
        ],
      ),
    );
  }
}
