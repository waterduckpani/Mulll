import 'package:flutter/cupertino.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'group_sheets.dart';
import 'icon_picker.dart';
import 'ledger_screen.dart';
import 'members_screen.dart';
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

    // Your two directions, never netted into one: owed ₹226 by one person and
    // owing ₹226 to another is not "all settled up".
    final owing = group.youOweHere;
    final owed = group.owedToYouHere;
    final transfers = group.yourTransfers;
    final claims = group.awaitingYourConfirmation;
    final due = group.recurring.where((r) => r.isDue(store.now())).toList();
    final active = group.recurring.where((r) => r.isActive).length;
    final settlements = group.settlements.length;

    void push(Widget screen) =>
        Navigator.of(context).push(CupertinoPageRoute(builder: (_) => screen));

    Future<void> settings() async {
      final result = await showGroupSettings(context, group);
      if (!context.mounted) return;
      if (result == 'deleted') {
        Navigator.of(context).pop();
      } else if (result == 'people') {
        push(GroupMembersScreen(groupId: group.id));
      } else if (result == 'add-recurring') {
        showRecurringEditor(context, group);
      }
    }

    // One focal object. Whatever is waiting on an answer takes it; with
    // nothing outstanding, settling up does.
    final somethingWaiting = claims.isNotEmpty || due.isNotEmpty;

    // A group of one is a group that cannot do anything: every split is a
    // split with yourself. It is easy to end up in by tapping straight through
    // the create flow, so the screen says so rather than looking broken.
    final alone = group.members.length < 2;

    return MullPage(
      glow: const GlowSpec(size: 440, top: -160, left: -150, right: null),
      onRefresh: store.pullNow,
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
        // The icon sits beside the title, not above it.
        //
        // Above was the first attempt and it cost 66 points of height, which
        // this screen turns out not to have: adding People to the
        // destinations already pushed Ledger under the fold on a 6.3" phone.
        // Beside costs nothing, and a 44px badge next to a 32pt title reads as
        // part of the name rather than as a control.
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.text, 22, Gutter.text, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (!group.isDirect) ...[
                Pressable(
                  onTap: group.youAreAdmin ? () => pickGroupIcon(context, group) : null,
                  scale: .92,
                  semanticLabel: 'Group icon',
                  child: GroupBadge(group: group, size: 44, glyphSize: 21),
                ),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        group.title,
                        style: MullType.screenTitle(c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      group.isDirect ? 'Just you two' : '${group.members.length} people',
                      style: MullType.caption(c.ink3, size: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        HeroAmount(
          caption: switch (null) {
            _ when owing > 0 => 'You owe',
            _ when owed > 0 => 'You get back',
            _ when group.expenses.isEmpty => 'Nothing added yet',
            _ => "You're square",
          },
          amount: owing > 0 ? owing : (owed > 0 ? owed : null),
          size: 68,
          placeholder: group.expenses.isEmpty ? 'Add the first\nexpense.' : 'You owe\nnobody here.',
          padding: const EdgeInsets.fromLTRB(Gutter.text, 34, Gutter.text, 0),
        ),
        if (owing > 0 && owed > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gutter.text, 12, Gutter.text, 0),
            child: Text(
              'And you get back ${inr(owed)} from someone else. Separate people, '
              'so neither cancels the other.',
              style: MullType.caption(c.ink3, size: 12.5),
            ),
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

        if (alone)
          Surface(
            lift: Lift.focal,
            radius: 28,
            margin: const EdgeInsets.fromLTRB(Gutter.card, 0, Gutter.card, 10),
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Eyebrow('Nobody else in here yet', size: 10.5, tracking: .18),
                const SizedBox(height: 14),
                Text(
                  'Add the people you are splitting with and Mull starts working '
                  'out who owes whom.',
                  style: MullType.body(c.ink3),
                ),
                const SizedBox(height: 20),
                InlineButton(
                  'Add people',
                  height: 48,
                  expand: true,
                  onTap: () => push(GroupMembersScreen(groupId: group.id)),
                ),
              ],
            ),
          ),

        Stacked(
          gap: 8,
          padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
          children: [
            _Destination(
              title: 'Settle up',
              body: switch (transfers.length) {
                0 => 'Nothing between you and anyone here',
                1 => 'One payment with you in it',
                final n => '${_words(n)} payments with you in them',
              },
              lift: somethingWaiting || alone ? Lift.card : Lift.focal,
              onTap: () => push(SettleUpScreen(groupId: group.id)),
            ),
            _Destination(
              title: group.isDirect ? 'The two of you' : 'People',
              detail: group.isDirect
                  ? null
                  : [
                      '${group.members.length}',
                      if (group.youAreAdmin) 'you run it',
                    ].join(' · '),
              lift: Lift.flat,
              onTap: () => push(GroupMembersScreen(groupId: group.id)),
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

        // The last thing that happened, in one line. What changed since you
        // last looked is the most common question anyone opens a group with,
        // and it was two taps away in the ledger. A line rather than a list,
        // because this screen has no height to spare (see the icon above).
        if (store.activity(group).firstOrNull case final latest?)
          Footnote(
            switch (latest) {
              Expense e =>
                'Latest: ${e.description}, ${inr(e.amount)}, ${daysAgo(e.date, store.now())}',
              Settlement s =>
                'Latest: ${group.memberById(s.fromId) == null ? 'Someone' : store.shortName(group.memberById(s.fromId)!)} '
                    '${s.offset ? 'netted off' : 'paid'} ${inr(s.amount)}, ${daysAgo(s.date, store.now())}',
              _ => '',
            },
            padding: const EdgeInsets.fromLTRB(Gutter.text, 26, Gutter.text, 0),
          ),
        if (group.expenses.isNotEmpty)
          Footnote(
            '${inr(group.total)} spent between ${group.members.length} people',
            padding: const EdgeInsets.fromLTRB(Gutter.text, 8, Gutter.text, 0),
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
