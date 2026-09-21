import 'package:flutter/cupertino.dart';

import '../core/dates.dart';
import '../core/money.dart';
import '../data/models.dart';
import '../data/remote/friends_service.dart';
import '../data/remote/live_channel.dart';
import '../data/store.dart';
import '../ui/group_icons.dart';
import '../ui/icons.dart';
import '../ui/page.dart';
import '../ui/sheet.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'groups/create_group_flow.dart';
import 'groups/group_detail_screen.dart';
import 'groups/group_sheets.dart';
import 'groups/icon_picker.dart';
import 'groups/recurring_sheets.dart';
import 'groups/settle_up_screen.dart';
import 'friends_sheet.dart';
import 'people_sheet.dart';

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
    // Everyone you split with, netted across every ledger — not the one-to-one
    // ledgers, which are only one of the places a person turns up. Somebody
    // you owe on a trip and who owes you on the flat is one row here, in one
    // direction, which is the question this screen exists to answer.
    final people = store.standings;
    final claims = store.confirmationsForYou;
    final waiting = store.claimsAwaitingOthers;
    final due = store.dueRecurring;
    final empty = store.groups.isEmpty;

    void open(Group g) => Navigator.of(context).push(
      CupertinoPageRoute(builder: (_) => GroupDetailScreen(groupId: g.id)),
    );

    Future<void> start({String? name}) async {
      final group = await showCreateGroup(context, name: name);
      if (group != null && context.mounted) open(group);
    }

    // How much room a ledger row gets.
    //
    // One group should not look like a list of one. A person with a single
    // flat opens Mull to a screen that is mostly empty, and a 68px row sitting
    // under a 76pt number reads as an app waiting for something to happen —
    // so with one or two ledgers the row becomes a card with the icon, the
    // people and the balance in it. The moment there are several, the page has
    // a real job to do and the rows tighten up to let you scan them.
    final density = switch (groups.length) {
      1 => _Density.roomy,
      2 || 3 => _Density.medium,
      _ => _Density.compact,
    };

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
      onRefresh: store.pullNow,
      bottom: PillButton(
        'Start a group',
        glyph: MullGlyph.plus,
        onTap: () => start(),
      ),
      children: empty
          ? [
              // A new user's first screen is this one, and the request is how
              // the groups they were invited to reach them.
              _FriendRequestsCard(
                onOpenLedger: (id) {
                  final g = store.groupById(id);
                  if (g != null) open(g);
                },
              ),
              _EmptyHome(onStart: start),
            ]
          : [
              const _Headline(),
              _FriendRequestsCard(
                onOpenLedger: (id) {
                  final g = store.groupById(id);
                  if (g != null) open(g);
                },
              ),

              // Anything waiting on an answer sits directly under the number,
              // because the number is not finished until these are dealt with.
              for (final (group, settlement) in claims)
                _ClaimCard(
                  key: ValueKey(settlement.id),
                  group: group,
                  settlement: settlement,
                  lift: claim(),
                ),
              for (final (group, settlement) in waiting)
                _WaitingClaimCard(
                  key: ValueKey('waiting-${settlement.id}'),
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
                  gap: density == _Density.roomy ? 10 : 8,
                  padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
                  children: [
                    for (final g in groups)
                      _LedgerRow(
                        key: ValueKey(g.id),
                        group: g,
                        density: density,
                        onTap: () => open(g),
                      ),
                  ],
                ),
              ],
              if (people.isNotEmpty) ...[
                const Eyebrow('People', padding: EdgeInsets.fromLTRB(Gutter.text, 36, Gutter.text, 0)),
                const SizedBox(height: 14),
                Surface(
                  lift: Lift.card,
                  radius: 26,
                  margin: const EdgeInsets.symmetric(horizontal: Gutter.card),
                  padding: const EdgeInsets.fromLTRB(22, 4, 18, 4),
                  child: CardRows(
                    children: [
                      for (final standing in people) PersonRow(key: ValueKey(standing.member.id), standing: standing),
                    ],
                  ),
                ),
              ],
              const _Footer(),
            ],
    );
  }
}

/// "You owe, all in / ₹3,850", and then both halves of it.
///
/// The net on its own was half an answer. ₹3,850 reads as a small tidy debt
/// and can just as easily be ₹12,000 coming to you against ₹15,850 going out —
/// two facts you would act on completely differently. So when both directions
/// exist, both are said, and the line is tappable through to the names.
class _Headline extends StatelessWidget {
  const _Headline();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final net = store.netAcrossAll;
    final owed = store.totalOwedToYou;
    final owing = store.totalYouOwe;
    final bothWays = owed > 0 && owing > 0;

    final caption = switch (net) {
      0 => bothWays ? 'Square, all in' : 'All square',
      > 0 => "You're owed, all in",
      _ => 'You owe, all in',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HeroAmount(
          caption: caption,
          amount: net == 0 ? null : net.abs(),
          placeholder: bothWays ? 'It all\ncancels out.' : 'Nobody owes\nanybody.',
        ),
        if (bothWays)
          Pressable(
            onTap: () => _openWhoOwesWho(context),
            scale: .99,
            semanticLabel: 'Owed to you ${inr(owed)}, you owe ${inr(owing)}. Open who owes who.',
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gutter.text, 14, Gutter.text, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${inr(owed)} owed to you · ${inr(owing)} you owe',
                        style: MullType.caption(c.ink3, size: 12.5),
                      ),
                    ),
                    MullIcon(MullGlyph.chevronRight, size: 13, color: c.ink3, strokeWidth: 1.8),
                  ],
                ),
              ),
            ),
          ),
        // Said quietly, and only once a push has actually failed. A change that
        // exists only on this phone looks exactly like one everybody can see,
        // and the first anyone knew of the difference was "my group vanished".
        if (store.syncTrouble && store.hasPendingChanges)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gutter.text, 10, Gutter.text, 0),
            child: Text(
              LiveChannel.instance.connected.value
                  ? "Some changes haven't synced yet. Mull keeps trying."
                  : "Some changes haven't synced yet. They'll go up when you're back online.",
              style: MullType.caption(c.ink3, size: 12),
            ),
          ),
      ],
    );
  }
}

/// Opens the both-directions list, and follows it into a ledger if one was
/// tapped down there.
Future<void> _openWhoOwesWho(BuildContext context) async {
  final navigator = Navigator.of(context);
  final store = context.readStore;
  final groupId = await showWhoOwesWhat(context);
  if (groupId == null) return;
  final group = store.groupById(groupId);
  if (group == null) return;
  await navigator.push(
    CupertinoPageRoute(builder: (_) => GroupDetailScreen(groupId: group.id)),
  );
}

/// The line at the end of the list.
class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final people = store.standings.where((s) => !s.isSquare).length;
    if (people == 0) return const SizedBox(height: 12);

    return Pressable(
      onTap: () => _openWhoOwesWho(context),
      semanticLabel: 'Who owes who, across $people people',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.text, 30, Gutter.text, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  people == 1 ? 'One person to square up with' : '$people people to square up with',
                  style: MullType.caption(c.ink3, size: 12.5),
                ),
              ),
              Text('Who owes who', style: ranade(12.5, color: c.ink2)),
              const SizedBox(width: 6),
              MullIcon(MullGlyph.chevronRight, size: 13, color: c.ink3, strokeWidth: 1.8),
            ],
          ),
        ),
      ),
    );
  }
}

/// A claim *you* made that the other person has not answered.
///
/// The other half of the confirm loop, and it used to be invisible: you said
/// you had paid, and if they never confirmed, nothing anywhere told you so.
/// The money had left your account and the debt was still on your balance,
/// with no way to find out why short of opening the group and reading the
/// settlements tab.
class _WaitingClaimCard extends StatelessWidget {
  const _WaitingClaimCard({
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
    final to = group.memberById(settlement.toId);
    if (to == null) return const SizedBox.shrink();
    final disputed = settlement.status == SettlementStatus.disputed;

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
                  disputed
                      ? '${store.shortName(to)} has not seen your ${inr(settlement.amount)}'
                      : '${store.shortName(to)} has not confirmed your ${inr(settlement.amount)}',
                  style: ranade(16, height: 1.35, color: c.ink),
                  maxLines: 2,
                ),
                const SizedBox(height: 4),
                Text(
                  '${group.title} · claimed ${daysAgo(settlement.date, store.now())}',
                  style: MullType.caption(c.ink3, size: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          InlineButton(
            'Open it',
            height: 48,
            onTap: () => showOwnClaim(context, group, settlement),
          ),
        ],
      ),
    );
  }
}

/// Somebody wants to split with you.
///
/// Being added to a group by email only puts it on your phone once you have
/// accepted the person who added you — that acceptance is the consent, and
/// without it anyone who knew your address could hand you a debt. Which makes
/// the request the first thing a new user needs to see, and it used to be a
/// count inside the profile sheet.
class _FriendRequestsCard extends StatefulWidget {
  const _FriendRequestsCard({required this.onOpenLedger});

  final void Function(String groupId) onOpenLedger;

  @override
  State<_FriendRequestsCard> createState() => _FriendRequestsCardState();
}

class _FriendRequestsCardState extends State<_FriendRequestsCard> with WidgetsBindingObserver {
  List<Friend> _waiting = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    final friends = await FriendsService.list();
    if (!mounted) return;
    setState(() => _waiting = [for (final f in friends) if (f.state == FriendState.incoming) f]);
  }

  @override
  Widget build(BuildContext context) {
    if (_waiting.isEmpty) return const SizedBox.shrink();
    final c = context.c;
    final who = _waiting.length == 1 ? _waiting.single.label.split(' ').first : '${_waiting.length} people';

    return Surface(
      lift: Lift.card,
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
                  '$who ${_waiting.length == 1 ? 'wants' : 'want'} to split with you',
                  style: ranade(16, height: 1.35, color: c.ink),
                  maxLines: 2,
                ),
                const SizedBox(height: 4),
                Text(
                  'Accept to see the groups you share',
                  style: MullType.caption(c.ink3, size: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          InlineButton(
            'See',
            height: 48,
            onTap: () async {
              await showFriendsSheet(context, onOpenLedger: widget.onOpenLedger);
              await _load();
            },
          ),
        ],
      ),
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
                    for (final suggestion in const ['Flat', 'Trip', 'Dinner', 'Rent'])
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
          SizedBox(
            width: 34,
            child: Text(number, style: excon(20, color: c.ink3)),
          ),
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
                'Whoever paid, and what it was for. Split it evenly or set exact '
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

/// How much of the screen a ledger row is allowed to take.
enum _Density {
  /// One ledger. The number goes big and the card carries the detail.
  roomy,

  /// Two or three. The icon and the people stay, the number comes back down.
  medium,

  /// Four or more. A line you scan, which is all a list this long can be.
  compact,
}

/// One entry in the GROUPS or PEOPLE list.
class _LedgerRow extends StatelessWidget {
  const _LedgerRow({
    super.key,
    required this.group,
    required this.onTap,
    this.density = _Density.compact,
  });

  final Group group;
  final VoidCallback onTap;
  final _Density density;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
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
    final lift = settled ? Lift.flat : Lift.card;

    // One label for the whole row. Read out piece by piece it becomes "Goa
    // trip, you owe, two thousand four hundred" spread over four stops.
    Widget wrap(Widget child, {required double radius, required EdgeInsets padding}) => Semantics(
      button: true,
      label: amount == null ? '${group.title}, settled up' : '${group.title}, $label ${inr(amount)}',
      child: ExcludeSemantics(
        child: Pressable(
          onTap: onTap,
          onLongPress: () => showLedgerActions(context, group),
          scale: .985,
          // A settled ledger recedes by sitting flatter and saying "settled
          // up", not by being faded out. Wrapping the row in Opacity took
          // every caption on it to 2.6:1 against the screen, well under the
          // 4.5:1 this design went to some trouble to clear everywhere else —
          // and the rule here has always been that hierarchy is how high a
          // surface floats.
          child: Container(
            padding: padding,
            decoration: surfaceOf(c, lift, radius: BorderRadius.circular(radius)),
            child: child,
          ),
        ),
      ),
    );

    if (density == _Density.compact) {
      return wrap(
        radius: 26,
        padding: const EdgeInsets.fromLTRB(24, 21, 24, 21),
        Row(
          children: [
            if (group.isDirect) ...[
              MullIcon(MullGlyph.person, size: 15, color: c.ink3, strokeWidth: 1.6),
              const SizedBox(width: 10),
            ] else if (group.icon != null) ...[
              Icon(groupGlyph(group.icon), size: 16, color: c.ink3),
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
      );
    }

    final roomy = density == _Density.roomy;
    final others = group.members.where((m) => !m.isYou).toList();
    final roster = others.isEmpty
        ? 'Nobody else in here yet'
        : others.length <= 3
        ? others.map(store.shortName).join(', ')
        : '${others.take(2).map(store.shortName).join(', ')} and ${others.length - 2} more';

    return wrap(
      radius: roomy ? 32 : 28,
      padding: EdgeInsets.fromLTRB(24, roomy ? 24 : 20, 24, roomy ? 26 : 22),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GroupBadge(group: group, size: roomy ? 44 : 38, glyphSize: roomy ? 21 : 18, quiet: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.title,
                      style: MullType.cardTitle(settled ? c.ink2 : c.ink, size: roomy ? 21 : 19),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      roster,
                      style: MullType.caption(c.ink3, size: 11.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: roomy ? 24 : 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: Text(label, style: MullType.caption(c.ink3))),
              if (amount != null)
                AnimatedAmount(
                  amount,
                  style: roomy
                      ? excon(38, tracking: -.04, height: .95, color: c.ink)
                      : MullType.cardAmount(c.ink, size: 24),
                ),
            ],
          ),
        ],
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
                // The thing people most often came here to do, and the one
                // action this menu did not offer. Settling was four screens
                // deep with no shortcut to it anywhere.
                if (!group.isSettled)
                  SheetAction(
                    'Settle up',
                    detail: switch (group.yourBalance) {
                      0 => null,
                      > 0 => 'you get back ${inr(group.yourBalance)}',
                      _ => 'you owe ${inr(-group.yourBalance)}',
                    },
                    onTap: () => run(
                      () => Navigator.of(context).push(
                        CupertinoPageRoute(builder: (_) => SettleUpScreen(groupId: group.id)),
                      ),
                    ),
                  ),
                SheetAction(
                  'Send summary on WhatsApp',
                  onTap: () => run(() => shareGroupSummary(context, group)),
                ),
                // Only an admin can delete a group; the server refuses anyone
                // else, and the group used to vanish here and come back.
                if (group.youAreAdmin)
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
