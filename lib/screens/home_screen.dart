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
import 'groups/create_group_flow.dart';
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

    Future<void> start({String? name}) async {
      final group = await showCreateGroup(context, name: name);
      if (group != null && context.mounted) open(group);
    }

    // Exactly one focal object per screen. The first thing waiting on an
    // answer takes it; everything below is an ordinary card.
    var focalTaken = false;
    Lift claim() {
      if (focalTaken) return Lift.card;
      focalTaken = true;
      return Lift.focal;
    }

    return MullPage(
      glow: const GlowSpec(size: 450, top: -170, right: -150),
      bottom: PillButton(
        'Start a group',
        glyph: MullGlyph.plus,
        onTap: () => start(),
      ),
      children: empty
          ? [_EmptyHome(onStart: start)]
          : [
              const _Headline(),

              // Anything waiting on an answer sits directly under the number,
              // because the number is not finished until these are dealt with.
              for (final (group, settlement) in claims)
                _ClaimCard(
                  key: ValueKey(settlement.id),
                  group: group,
                  settlement: settlement,
                  lift: claim(),
                ),
              for (final (group, schedule) in due)
                _DueCard(
                  key: ValueKey(schedule.id),
                  group: group,
                  schedule: schedule,
                  lift: claim(),
                ),

              if (groups.isNotEmpty) ...[
                const Eyebrow('Groups', padding: EdgeInsets.fromLTRB(Gutter.text, 40, Gutter.text, 0)),
                const SizedBox(height: 14),
                Stacked(
                  padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
                  children: [
                    for (final g in groups)
                      _LedgerRow(key: ValueKey(g.id), group: g, onTap: () => open(g)),
                  ],
                ),
              ],
              if (people.isNotEmpty) ...[
                const Eyebrow('People', padding: EdgeInsets.fromLTRB(Gutter.text, 36, Gutter.text, 0)),
                const SizedBox(height: 14),
                Stacked(
                  padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
                  children: [
                    for (final g in people)
                      _LedgerRow(key: ValueKey(g.id), group: g, onTap: () => open(g)),
                  ],
                ),
              ],
              const _Waiting(),
            ],
    );
  }
}

/// "You owe, all in / ₹3,850".
class _Headline extends StatelessWidget {
  const _Headline();

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final net = store.netAcrossAll;

    final caption = switch (net) {
      0 => 'All square',
      > 0 => "You're owed, all in",
      _ => 'You owe, all in',
    };

    return HeroAmount(
      caption: caption,
      amount: net == 0 ? null : net.abs(),
      placeholder: 'Nobody owes\nanybody.',
    );
  }
}

// --------------------------------------------------------------- empty state

/// The first screen of an app with nothing in it.
///
/// A blank page with one button is the honest thing to draw and the wrong
/// thing to show: it reads as an app that is broken or waiting for something.
/// So this one says what Mull is for, offers the three groups people actually
/// make, and starts one from a single tap on a chip.
class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onStart});

  final Future<void> Function({String? name}) onStart;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final name = store.profile.name.trim().split(' ').first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Rise(
          step: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gutter.text, 40, Gutter.text, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isEmpty ? 'Nothing to settle yet' : 'Nothing to settle yet, $name',
                  style: MullType.caption(c.ink3),
                ),
                const SizedBox(height: 16),
                Text('Who paid.\nWho owes.\nSorted.', style: MullType.statement(c.ink, size: 40)),
                const SizedBox(height: 20),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: Text(
                    'Add what people pay as it happens. Mull works out the fewest '
                    'payments that clear it, and the money moves over UPI.',
                    style: MullType.body(c.ink3),
                  ),
                ),
              ],
            ),
          ),
        ),

        _Rise(
          step: 1,
          child: Surface(
            lift: Lift.focal,
            radius: 28,
            margin: const EdgeInsets.fromLTRB(Gutter.card, 42, Gutter.card, 0),
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Eyebrow('Start one in a tap', size: 10.5, tracking: .18),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final suggestion in const ['Flat', 'Goa trip', 'Dinner', 'Rent'])
                      ChipButton(suggestion, onTap: () => onStart(name: suggestion)),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  'Pick one and Mull asks who is in it. Nothing is final: you can '
                  'rename it or add people whenever.',
                  style: MullType.caption(c.ink3),
                ),
              ],
            ),
          ),
        ),

        _Rise(
          step: 2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gutter.card, 10, Gutter.card, 0),
            child: _QuietDestination(
              title: 'How settling up works',
              detail: 'A minute',
              onTap: () => showHowItWorks(context),
            ),
          ),
        ),

        _Rise(
          step: 3,
          child: const Footnote(
            'Money never moves through Mull.\nPay over UPI, then say it went through.',
            padding: EdgeInsets.fromLTRB(Gutter.text, 30, Gutter.text, 0),
          ),
        ),
      ],
    );
  }
}

/// Fades and lifts its child into place, a beat after the one above it.
///
/// Only used on screens that would otherwise arrive all at once with nothing
/// on them. A list of real groups does not need choreography.
class _Rise extends StatefulWidget {
  const _Rise({required this.step, required this.child});

  final int step;
  final Widget child;

  @override
  State<_Rise> createState() => _RiseState();
}

class _RiseState extends State<_Rise> {
  bool _in = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: 90 + widget.step * 110), () {
      if (mounted) setState(() => _in = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = motion(context, const Duration(milliseconds: 520));
    return AnimatedSlide(
      offset: _in ? Offset.zero : const Offset(0, .06),
      duration: d,
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(opacity: _in ? 1 : 0, duration: d, child: widget.child),
    );
  }
}

/// A row that goes somewhere. Flat, so it sinks back into the page.
class _QuietDestination extends StatelessWidget {
  const _QuietDestination({required this.title, this.detail, required this.onTap});

  final String title;
  final String? detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .99,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 20, 20),
        decoration: surfaceOf(c, Lift.flat, radius: BorderRadius.circular(24)),
        child: Row(
          children: [
            Expanded(child: Text(title, style: MullType.cardTitle(c.ink2))),
            if (detail != null) ...[
              Text(detail!, style: MullType.caption(c.ink3)),
              const SizedBox(width: 10),
            ],
            MullIcon(MullGlyph.chevronRight, size: 14, color: c.ink3, strokeWidth: 1.8),
          ],
        ),
      ),
    );
  }
}

/// Three beats: what Mull records, who confirms it, and where the money goes.
///
/// Reachable from the empty home screen and from the profile sheet. The claim
/// and confirm loop is the one thing about Mull that is not obvious from
/// looking at it, and an app that never explains it gets used as a calculator.
Future<void> showHowItWorks(BuildContext context) => showMullSheet(
  context,
  height: 720,
  builder: (sheet) {
    final c = sheet.c;
    Widget beat(String number, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 26),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 34, child: Text(number, style: excon(20, color: c.ink3))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: MullType.cardTitle(c.ink)),
                const SizedBox(height: 6),
                Text(body, style: MullType.body(c.ink3)),
              ],
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('How it works'),
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(Gutter.text, 14, Gutter.text, 24),
            children: [
              Text('Three things, and that is all of it.', style: MullType.statement(c.ink, size: 30)),
              const SizedBox(height: 28),
              beat(
                '01',
                'Add what people pay',
                'Whoever paid, and who it was for. Split it evenly or set exact '
                    'amounts. The balance updates as you go.',
              ),
              beat(
                '02',
                'Mull finds the fewest payments',
                'Four people and eleven expenses usually come down to two '
                    'transfers. You see who pays whom, not a wall of arithmetic.',
              ),
              beat(
                '03',
                'Pay, then say it went through',
                'Money moves over UPI between you, never through Mull. The payer '
                    'says they sent it and the person owed confirms it arrived, '
                    'so a balance only changes when both sides agree.',
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.card, 6, Gutter.card, 26),
          child: PillButton('Got it', onTap: () => Navigator.of(sheet).pop()),
        ),
      ],
    );
  },
);

// ---------------------------------------------------------------------- cards

/// Someone says they have paid you. Only you can say whether it landed, so it
/// sits above everything else until you answer.
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
      margin: const EdgeInsets.fromLTRB(Gutter.card, 34, Gutter.card, 0),
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

/// A standing expense whose turn has come round.
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
    final yourShare = schedule.shares[group.you?.id] ?? 0;

    return Surface(
      lift: lift,
      radius: 28,
      margin: const EdgeInsets.fromLTRB(Gutter.card, 10, Gutter.card, 0),
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
                  [
                    group.title,
                    inr(schedule.amount),
                    if (yourShare > 0) 'your share ${inr(yourShare)}',
                  ].join(' · '),
                  style: MullType.caption(c.ink3, size: 11.5),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
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

    // A settled ledger is still worth seeing and not worth reading. It sinks
    // rather than disappearing, so the list stays a record of who you split
    // with instead of emptying out every time everyone pays up.
    return Semantics(
      button: true,
      label: amount == null
          ? '${group.title}, settled up'
          : '${group.title}, $label ${inr(amount)}',
      child: ExcludeSemantics(
        child: Pressable(
          onTap: onTap,
          onLongPress: () => showLedgerActions(context, group),
          scale: .985,
          child: Opacity(
            opacity: settled ? .55 : 1,
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 21, 24, 21),
              decoration: surfaceOf(
                c,
                settled ? Lift.flat : Lift.card,
                radius: BorderRadius.circular(26),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (group.isDirect) ...[
                    MullIcon(MullGlyph.person, size: 15, color: c.ink3, strokeWidth: 1.6),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      group.title,
                      style: MullType.cardTitle(settled ? c.ink2 : c.ink, size: 18),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(label, style: MullType.caption(c.ink3)),
                  if (amount != null) ...[
                    const SizedBox(width: 10),
                    AnimatedAmount(amount, style: MullType.cardAmount(c.ink)),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The quiet line at the end of the list.
class _Waiting extends StatelessWidget {
  const _Waiting();

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final owed = store.owedToYou;
    final c = context.c;
    if (owed.isEmpty) return const SizedBox(height: 12);

    final total = owed.fold(0, (s, o) => s + o.amount);
    return Pressable(
      onTap: () => showWhoOwesYou(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gutter.text, 30, Gutter.text, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                owed.length == 1
                    ? '${store.shortName(owed.first.member)} owes you ${inr(total)}'
                    : '${owed.length} people owe you ${inr(total)}',
                style: MullType.caption(c.ink3, size: 12.5),
              ),
            ),
            Text('Remind', style: ranade(12.5, color: c.ink2)),
            const SizedBox(width: 6),
            MullIcon(MullGlyph.chevronRight, size: 13, color: c.ink3, strokeWidth: 1.8),
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
        padding: const EdgeInsets.fromLTRB(Gutter.text, 26, Gutter.text, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(group.title, style: MullType.screenTitle(sheet.c.ink), maxLines: 2),
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
Future<void> showWhoOwesYou(BuildContext context) => showMullSheet(
  context,
  height: (280 + context.readStore.owedToYou.length * 78).clamp(340, 680).toDouble(),
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
            padding: const EdgeInsets.fromLTRB(Gutter.text, 12, Gutter.text, 24),
            children: [
              Text(
                'Netted per person, so a friend you have been to three dinners '
                'with is chased once.',
                style: MullType.caption(c.ink3),
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
                  style: MullType.caption(c.ink3, size: 11.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Opacity(
            opacity: ready ? 1 : .35,
            child: InlineButton(
              'Remind',
              filled: false,
              onTap: ready ? () => nudge(context, owing) : null,
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
