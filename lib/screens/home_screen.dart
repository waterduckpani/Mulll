import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../core/dates.dart';
import '../core/money.dart';
import '../core/upi.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../ui/icons.dart';
import '../ui/page.dart';
import '../ui/sheet.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'groups/group_detail_screen.dart';
import 'groups/group_sheets.dart';
import 'groups/recurring_sheets.dart';

/// Mull, all of it.
///
/// One number at the top, then the things that need an answer, then the
/// ledgers. There is no tab bar because there is nothing to switch to: the
/// whole app is "who owes whom, and what do I do about it".
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final groups = store.namedGroups;
    final people = store.directLedgers;
    final claims = store.confirmationsForYou;
    final due = store.dueRecurring;
    final empty = store.groups.isEmpty;

    void open(Group g) => Navigator.of(context).push(
      CupertinoPageRoute(builder: (_) => GroupDetailScreen(groupId: g.id)),
    );

    return MullPage(
      blobs: const [
        BlobSpec(330, 64, top: 40, right: -110),
        BlobSpec(280, 70, bottom: 20, left: -100),
      ],
      bottom: PillButton(
        'Start a group',
        glyph: MullGlyph.plus,
        onTap: () => showStartGroup(context, onCreated: open),
      ),
      children: [
        const _Headline(),

        // Anything waiting on an answer sits directly under the number, because
        // the number is not finished until these are dealt with.
        for (final (group, claim) in claims)
          _ClaimCard(key: ValueKey(claim.id), group: group, settlement: claim),
        for (final (group, schedule) in due)
          _DueCard(key: ValueKey(schedule.id), group: group, schedule: schedule),

        if (empty)
          const EmptyCard(
            margin: EdgeInsets.fromLTRB(22, 26, 22, 0),
            title: 'Sharing costs with someone?',
            body:
                'Start a group for a trip, the flat or a night out. Add what people '
                'pay as it happens, and Mull works out the fewest payments that '
                'clear it — over UPI, straight from here.',
          )
        else ...[
          if (groups.isNotEmpty) ...[
            const Eyebrow('Groups', padding: EdgeInsets.fromLTRB(30, 34, 30, 0)),
            for (final g in groups) _LedgerRow(key: ValueKey(g.id), group: g, onTap: () => open(g)),
          ],
          if (people.isNotEmpty) ...[
            const Eyebrow('People', padding: EdgeInsets.fromLTRB(30, 30, 30, 0)),
            for (final g in people) _LedgerRow(key: ValueKey(g.id), group: g, onTap: () => open(g)),
          ],
          const _Footnote(),
        ],
      ],
    );
  }
}

/// "You owe, all in / ₹3,850".
class _Headline extends StatelessWidget {
  const _Headline();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final net = store.netAcrossAll;
    final empty = store.groups.isEmpty;

    final label = switch (net) {
      _ when empty => 'Nothing to settle',
      0 => 'All square',
      > 0 => "You're owed, all in",
      _ => 'You owe, all in',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 46, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: ranade(15, tracking: .01, color: c.ink3)),
          const SizedBox(height: 10),
          if (net == 0)
            Text(
              empty ? 'Yet.' : 'Nobody owes anybody.',
              style: excon(46, tracking: -.03, height: 1, color: c.ink2),
            )
          else
            // The number is the page. It gets whatever width the phone has and
            // shrinks rather than wrapping — ₹1,24,600 must never break across
            // two lines.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Semantics(
                header: true,
                child: AnimatedAmount(
                  net.abs(),
                  style: excon(72, tracking: -.045, height: .98, color: c.ink),
                ),
              ),
            ),
          if (net != 0 && store.totalYouOwe > 0 && store.totalOwedToYou > 0) ...[
            const SizedBox(height: 12),
            Text(
              '${inr(store.totalYouOwe)} out, ${inr(store.totalOwedToYou)} back in',
              style: ranade(12.5, color: c.ink3),
            ),
          ],
        ],
      ),
    );
  }
}

/// Someone says they have paid you. Only you can say whether it landed, so it
/// sits above everything else until you answer.
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

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 0),
      child: Glass(
        radius: 28,
        padding: const EdgeInsets.fromLTRB(22, 18, 14, 18),
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
            _CheckButton(
              onTap: () => showClaimCheck(context, group, settlement),
            ),
          ],
        ),
      ),
    );
  }
}

/// The light capsule on the claim card — the one thing on the screen that
/// answers back.
class _CheckButton extends StatelessWidget {
  const _CheckButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .95,
      semanticLabel: 'Check this payment',
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 26),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: c.pill, borderRadius: BorderRadius.circular(26)),
        child: Text('Check', style: ranade(15.5, color: c.pillInk)),
      ),
    );
  }
}

/// A standing expense whose turn has come round.
class _DueCard extends StatelessWidget {
  const _DueCard({super.key, required this.group, required this.schedule});

  final Group group;
  final Recurring schedule;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final payer = group.memberById(schedule.payerId);
    final yourShare = schedule.shares[group.you?.id] ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
      child: Pressable(
        onTap: () => showDueRecurring(context, group, schedule),
        scale: .985,
        child: Glass(
          radius: 28,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  MullIcon(MullGlyph.repeat, size: 15, color: c.ink3, strokeWidth: 1.7),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${schedule.description} is due ${relativeDay(schedule.nextDue, store.now())}',
                      style: ranade(16, height: 1.35, color: c.ink),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                [
                  group.title,
                  inr(schedule.amount),
                  if (payer != null) '${store.shortName(payer)} pays',
                  if (yourShare > 0) 'your share ${inr(yourShare)}',
                ].join(' · '),
                style: ranade(11.5, color: c.ink3),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One line in the GROUPS or PEOPLE list.
class _LedgerRow extends StatelessWidget {
  const _LedgerRow({super.key, required this.group, required this.onTap});

  final Group group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final balance = group.yourBalance;
    final settled = balance == 0;

    final (label, amount) = switch (balance) {
      0 => ('settled up', null),
      > 0 => ('you get back', balance),
      _ => ('you owe', -balance),
    };

    // A settled ledger is still worth seeing and not worth reading. It recedes
    // rather than disappearing, so the list stays a record of who you split
    // with instead of emptying out every time everyone pays up.
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
      child: Semantics(
        button: true,
        label: amount == null
            ? '${group.title}, settled up'
            : '${group.title}, $label ${inr(amount)}',
        child: ExcludeSemantics(
          child: Pressable(
            onTap: onTap,
            onLongPress: () => showLedgerActions(context, group),
            scale: .98,
            child: Opacity(
              opacity: settled ? .55 : 1,
              child: Glass(
                radius: 26,
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (group.isDirect) ...[
                      MullIcon(MullGlyph.person, size: 16, color: c.ink3, strokeWidth: 1.6),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        group.title,
                        style: ranade(20, color: settled ? c.ink2 : c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(label, style: ranade(13, color: c.ink3)),
                    if (amount != null) ...[
                      const SizedBox(width: 10),
                      AnimatedAmount(amount, style: excon(22, tracking: -.02, color: c.ink)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The quiet line at the end of the list.
class _Footnote extends StatelessWidget {
  const _Footnote();

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final owed = store.owedToYou;
    final c = context.c;
    if (owed.isEmpty) return const SizedBox(height: 10);

    final total = owed.fold(0, (s, o) => s + o.amount);
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 4),
      child: Pressable(
        onTap: () => showWhoOwesYou(context),
        child: Row(
          children: [
            Expanded(
              child: Text(
                owed.length == 1
                    ? '${store.shortName(owed.first.member)} owes you ${inr(total)}'
                    : '${owed.length} people owe you ${inr(total)}',
                style: ranade(12.5, color: c.ink3),
              ),
            ),
            Text('Remind', style: ranade(12.5, color: c.ink2)),
            const SizedBox(width: 6),
            MullIcon(MullGlyph.chevronRight, size: 13, color: c.ink3, strokeWidth: 1.7),
          ],
        ),
      ),
    );
  }
}

/// Long-press on a ledger row.
Future<void> showLedgerActions(BuildContext context, Group group) {
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
            Text(group.title, style: excon(26, tracking: -.02, color: sheet.c.ink), maxLines: 2),
            const SizedBox(height: 16),
            CardRows(
              children: [
                SheetAction('Add an expense', onTap: () => run(() => showAddExpense(context, group))),
                SheetAction(
                  'Send summary on WhatsApp',
                  onTap: () => run(() => shareGroupSummary(context, group)),
                ),
                SheetAction(
                  group.isDirect ? 'Delete this ledger' : 'Delete group',
                  destructive: true,
                  onTap: () => run(() {
                    store.deleteGroup(group);
                    Toast.show(
                      context,
                      'Deleted ${group.title}',
                      action: 'Undo',
                      onAction: () => store.restoreGroup(group),
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

/// Everyone who owes you, netted per person, with a nudge against each.
///
/// Sized to the list rather than to a round number: one person owing you money
/// should not open half a screen of nothing.
Future<void> showWhoOwesYou(BuildContext context) => showMullSheet(
  context,
  height: (260 + context.readStore.owedToYou.length * 78).clamp(320, 680).toDouble(),
  builder: (_) => const _OwedSheet(),
);

class _OwedSheet extends StatelessWidget {
  const _OwedSheet();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final owed = store.owedToYou;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Waiting on'),
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 24),
            children: [
              Text(
                'Netted per person, so a friend you have been to three dinners '
                'with is chased once.',
                style: ranade(12.5, height: 1.6, color: c.ink3),
              ),
              const SizedBox(height: 20),
              if (owed.isEmpty)
                Text('Nobody owes you anything.', style: ranade(15, color: c.ink2))
              else
                CardRows(
                  children: [for (final o in owed) _OwedRow(key: ValueKey(o.member.id), owing: o)],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OwedRow extends StatelessWidget {
  const _OwedRow({super.key, required this.owing});

  final Owing owing;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final ready = store.canNudge(owing);
    final last = owing.lastNudgedAt;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(store.shortName(owing.member), style: ranade(16, color: c.ink)),
                const SizedBox(height: 3),
                Text(
                  [
                    inr(owing.amount),
                    owing.groups.length == 1
                        ? owing.groups.first.title
                        : '${owing.groups.length} ledgers',
                    if (last != null) 'nudged ${daysAgo(last, store.now())}',
                  ].join(' · '),
                  style: ranade(11.5, color: c.ink3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Pressable(
            onTap: ready ? () => nudge(context, owing) : null,
            scale: .94,
            semanticLabel: 'Remind ${store.shortName(owing.member)}',
            child: Opacity(
              opacity: ready ? 1 : .35,
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: c.line),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MullIcon(MullGlyph.bell, size: 14, color: c.ink2, strokeWidth: 1.6),
                    const SizedBox(width: 8),
                    Text('Remind', style: ranade(13, color: c.ink2)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hands the reminder to WhatsApp, already written.
///
/// Mull does not send anything itself, and that is on purpose: a message that
/// arrives from an app reads as a collections notice, while the same words from
/// you read as a person asking. It also means nobody has to have Mull.
Future<void> nudge(BuildContext context, Owing owing) async {
  final store = context.readStore;
  final message = store.nudgeMessage(owing);
  HapticFeedback.mediumImpact();
  final sent = await shareOnWhatsApp(message, phone: owing.member.phone);
  if (!context.mounted) return;
  if (sent) {
    store.markNudged(owing);
    Toast.show(context, 'Reminder ready in WhatsApp');
  } else {
    Toast.show(context, "Couldn't open WhatsApp");
  }
}
