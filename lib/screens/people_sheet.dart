/// Where you stand with one person, and what to do about it.
///
/// The screen Mull was missing. Everything else in the app is organised by
/// ledger — the trip, the flat, the dinner — which is how the money was spent
/// and not how anybody thinks about it afterwards. What you actually want to
/// know is whether you and Ananya are square, and that question was previously
/// answerable only by opening three groups and doing the sums yourself.
///
/// So: one number per person, netted across every ledger the two of you share,
/// with the ledgers underneath it as the working. Settling starts here rather
/// than four screens into a group.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/money.dart';
import '../core/upi.dart';
import '../data/models.dart';
import '../data/remote/notices_service.dart';
import '../data/store.dart';
import '../ui/icons.dart';
import '../ui/sheet.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

/// Answers with the ledger to open, if one was tapped.
///
/// The sheet does not navigate itself: its own context dies with it, and a
/// route pushed from a dead context lands on the root navigator — over the top
/// of the sheet's own scrim, with no way back. The same reason the notices
/// sheet hands its group back rather than pushing it.
Future<String?> showPersonSheet(BuildContext context, Standing standing) => showMullSheet<String>(
  context,
  height: 660,
  builder: (_) => _PersonSheet(personKey: standing.member.id),
);

/// Held by member id rather than by the [Standing] itself, because a standing
/// is a snapshot: settle something and the object the sheet was handed is
/// instantly out of date, showing the old amount over a ledger that has moved.
/// Looking it up again on every build costs nothing and is always true.
class _PersonSheet extends StatelessWidget {
  const _PersonSheet({required this.personKey});

  final String personKey;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final standing = store.standings.where((s) => s.seats.values.contains(personKey)).firstOrNull;
    if (standing == null) return const SizedBox.shrink();

    final name = store.shortName(standing.member);
    final ledgers = store.ledgersWith(standing);
    final canNet = store.canNetOff(standing);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(standing.member.name),
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            // Room at the bottom for the footer to float over, so the last
            // ledger row can be scrolled out from under the button.
            padding: EdgeInsets.fromLTRB(30, 8, 30, standing.isSquare ? 20 : 96),
            children: [
              // The whole answer, in words and then in figures. Never a signed
              // number: "−₹2,400" makes the reader do the work of deciding
              // which way that points.
              Text(
                switch (standing.amount) {
                  0 => 'You are square',
                  > 0 => '$name owes you',
                  _ => 'You owe $name',
                },
                style: MullType.caption(c.ink3),
              ),
              const SizedBox(height: 10),
              Text(
                standing.isSquare ? 'Nothing between you' : inr(standing.magnitude),
                style: standing.isSquare
                    ? MullType.statement(c.ink, size: 26)
                    : excon(46, tracking: -.03, color: c.ink),
              ),

              if (canNet) ...[
                const SizedBox(height: 24),
                _NetOffCard(standing: standing),
              ],

              if (ledgers.isNotEmpty) ...[
                const SizedBox(height: 28),
                const Eyebrow('Across', size: 10.5, tracking: .18),
                const SizedBox(height: 10),
                CardRows(
                  children: [
                    for (final (group, amount) in ledgers)
                      _LedgerLine(
                        group: group,
                        amount: amount,
                        name: name,
                        onTap: () => Navigator.of(context).pop(group.id),
                      ),
                  ],
                ),
              ],

              const SizedBox(height: 22),
              Text(
                standing.isSquare
                    ? 'Every ledger you share with $name adds up to nothing. '
                          'Anything new shows up here.'
                    : 'Money never moves through Mull. Pay over UPI, then say '
                          'it went through.',
                style: MullType.caption(c.ink3),
              ),
            ],
          ),
        ),

        // Settling is what this sheet is for, so it sits in the footer rather
        // than at the end of the list. With a net-off card on screen the
        // button was under the fold, which turns the one action worth having
        // here into something you have to go looking for.
        if (!standing.isSquare && !store.canSettleAcross(standing))
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 4, 30, 30),
            child: Text(
              'Mull is matching these by name only, so they may not be the same '
              '$name. Settle in each ledger, so the money goes to the right one.',
              style: MullType.caption(c.ink3),
            ),
          )
        else if (!standing.isSquare)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PillButton(
                  standing.theyOweYou ? 'Record what $name paid' : 'Pay $name',
                  onTap: () => _settle(context, standing),
                ),
                if (standing.theyOweYou) ...[
                  const SizedBox(height: 8),
                  _RemindButton(standing: standing),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// One ledger's contribution, so the net above has visible working.
class _LedgerLine extends StatelessWidget {
  const _LedgerLine({
    required this.group,
    required this.amount,
    required this.name,
    required this.onTap,
  });

  final Group group;
  final int amount;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .99,
      semanticLabel: '${group.title}, ${amount > 0 ? 'owes you' : 'you owe'} ${inr(amount.abs())}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 13),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  group.isDirect ? 'Just the two of you' : group.title,
                  style: ranade(15, color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                amount > 0 ? 'owes you' : 'you owe',
                style: MullType.caption(c.ink3, size: 11),
              ),
              const SizedBox(width: 8),
              Text(inr(amount.abs()), style: MullType.listAmount(c.ink)),
              const SizedBox(width: 8),
              MullIcon(MullGlyph.chevronRight, size: 13, color: c.ink3, strokeWidth: 1.8),
            ],
          ),
        ),
      ),
    );
  }
}

/// Debts pointing both ways, and the offer to cancel them.
class _NetOffCard extends StatelessWidget {
  const _NetOffCard({required this.standing});

  final Standing standing;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final name = store.shortName(standing.member);
    final cancels = store.netOffAmount(standing);

    return Surface(
      lift: Lift.focal,
      radius: 28,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Eyebrow('These cancel out', size: 10.5, tracking: .18),
          const SizedBox(height: 14),
          Text(
            'You owe $name in one ledger and $name owes you in another. '
            '${inr(cancels)} of that is the same money going both ways.',
            style: MullType.body(c.ink3),
          ),
          const SizedBox(height: 20),
          InlineButton(
            'Net off ${inr(cancels)}',
            height: 48,
            expand: true,
            onTap: () {
              final written = store.netOff(standing);
              if (written.isEmpty) return;
              HapticFeedback.mediumImpact();
              Toast.show(context, '${inr(cancels)} cancelled out. Nothing moved.');
            },
          ),
          const SizedBox(height: 12),
          Text(
            'No money changes hands. Both ledgers are written up so each one '
            'is honestly square.',
            style: MullType.caption(c.ink3),
          ),
        ],
      ),
    );
  }
}

class _RemindButton extends StatelessWidget {
  const _RemindButton({required this.standing});

  final Standing standing;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final name = store.shortName(standing.member);
    if (!store.canNudge(standing)) {
      // Said, not greyed out. Faded on top of a disabled button's own fade,
      // the one sentence explaining why there was no button came out at about
      // an eighth of full strength — unreadable, and against the rule that
      // nothing recedes by going translucent.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Text(
          "You've reminded $name twice today. You can again tomorrow.",
          textAlign: TextAlign.center,
          style: MullType.caption(context.c.ink3),
        ),
      );
    }
    return SecondaryButton('Remind $name', onTap: () => nudgePerson(context, standing));
  }
}

// ---------------------------------------------------------------- settling

/// Settle with a person, in whatever part of it is actually being paid.
///
/// The amount is a field rather than a fixed figure, which is the difference
/// between recording what happened and recording what the app expected. "I'll
/// send you 500 of the 1,800 now" is the most ordinary sentence in splitting
/// money and Mull had no way to write it down.
Future<void> _settle(BuildContext context, Standing standing) => showMullSheet(
  context,
  height: 520,
  builder: (_) => _SettleAcrossSheet(personKey: standing.member.id),
);

class _SettleAcrossSheet extends StatefulWidget {
  const _SettleAcrossSheet({required this.personKey});

  final String personKey;

  @override
  State<_SettleAcrossSheet> createState() => _SettleAcrossSheetState();
}

class _SettleAcrossSheetState extends State<_SettleAcrossSheet> {
  late final AmountController _amount;
  final _focus = FocusNode();
  Standing? _standing;

  @override
  void initState() {
    super.initState();
    _standing = _find(context);
    // Prefilled with the whole thing, because clearing the debt is what most
    // people are here to do — and selected, so typing a part payment replaces
    // it rather than appending to it.
    _amount = AmountController(_standing?.magnitude)..addListener(() => setState(() {}));
  }

  Standing? _find(BuildContext context) =>
      context.readStore.standings.where((s) => s.seats.values.contains(widget.personKey)).firstOrNull;

  @override
  void dispose() {
    _amount.dispose();
    _focus.dispose();
    super.dispose();
  }

  int get _max => _standing?.magnitude ?? 0;
  int? get _value => _amount.amount;
  bool get _valid => _value != null && _value! > 0 && _value! <= _max;

  /// Their VPA, from whichever seat has one.
  String? get _payeeUpi {
    final standing = _standing;
    if (standing == null) return null;
    for (final group in standing.groups) {
      final seat = group.memberById(standing.seats[group.id] ?? '');
      if (seat?.upiId != null) return seat!.upiId;
    }
    return standing.member.upiId;
  }

  void _record({String? utr}) {
    final standing = _standing!;
    final store = context.readStore;
    store.settleAcross(standing, amount: _value!, utr: utr);
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
    Toast.show(
      context,
      _value! == _max
          ? 'Settled with ${store.shortName(standing.member)}'
          : '${inr(_value!)} recorded · ${inr(_max - _value!)} left',
    );
  }

  Future<void> _payOverUpi() async {
    final standing = _standing!;
    final upi = _payeeUpi;
    if (upi == null) return;
    final opened = await openUpiPayment(
      upiId: upi,
      name: standing.member.name,
      amount: _value!,
      note: standing.groups.length == 1 ? standing.groups.first.title : 'Mull',
    );
    if (!mounted) return;
    if (!opened) {
      Toast.show(
        context,
        'No UPI app could open that',
        // Some UPI apps refuse a payment link they did not start themselves.
        // Pasting the ID into one by hand always works.
        action: 'Copy ID',
        onAction: () => Clipboard.setData(ClipboardData(text: upi)),
      );
      return;
    }
    // Mull cannot see the UPI app, so the only honest thing is to ask.
    final went = await _didItGoThrough(context);
    if (!mounted || went != true) return;
    _record();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final standing = _standing;
    if (standing == null) return const SizedBox.shrink();

    final name = store.shortName(standing.member);
    final theyOwe = standing.theyOweYou;
    final upi = _payeeUpi;
    final part = _valid && _value! < _max;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(theyOwe ? 'Record a payment' : 'Settle with $name'),
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 8, 30, 20),
            children: [
              Text(
                theyOwe ? '$name owes you ${inr(_max)}' : 'You owe $name ${inr(_max)}',
                style: MullType.caption(c.ink3),
              ),
              const SizedBox(height: 18),
              BigField(
                controller: _amount,
                focusNode: _focus,
                numeric: true,
                hint: '₹0',
                size: 40,
                trailing: _value != null && _value! != _max
                    ? Pressable(
                        onTap: () {
                          _amount.text = _max.toString();
                          setState(() {});
                        },
                        child: Text('All of it', style: ranade(12.5, color: c.ink2)),
                      )
                    : Text('of ${inr(_max)}', style: ranade(11.5, color: c.ink3)),
              ),
              const SizedBox(height: 14),
              Text(
                switch (null) {
                  _ when _value == null => 'How much is actually changing hands.',
                  _ when _value! > _max =>
                    'That is more than ${theyOwe ? '$name owes' : 'you owe'}. '
                        'Anything over ${inr(_max)} would leave the balance '
                        'pointing the other way.',
                  _ when part => '${inr(_max - _value!)} would still be open afterwards.',
                  _ => 'That clears it.',
                },
                style: ranade(12.5, height: 1.5, color: c.ink3),
              ),

              if (standing.groups.length > 1) ...[
                const SizedBox(height: 22),
                Text(
                  [
                    // Recording this nets off first, which writes both ledgers
                    // up. That is the only way the netted figure above can be
                    // cleared, and it should not happen without being said.
                    if (store.canNetOff(standing))
                      'This also cancels the ${inr(store.netOffAmount(standing))} that '
                          'goes both ways between you, in both ledgers.',
                    'Spread across ${standing.groups.length} ledgers, biggest '
                        'first, so whole ones close rather than every one of them '
                        'being left slightly short.',
                  ].join(' '),
                  style: MullType.caption(c.ink3),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!theyOwe && upi != null) ...[
                PillButton(
                  _valid ? 'Pay ${inr(_value!)} over UPI' : 'Pay over UPI',
                  onTap: _valid ? _payOverUpi : null,
                ),
                const SizedBox(height: 8),
                SecondaryButton(
                  'Already paid, just record it',
                  onTap: _valid ? _record : null,
                ),
              ] else
                PillButton(
                  theyOwe ? 'Record it' : 'Mark as settled',
                  onTap: _valid ? _record : null,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<bool?> _didItGoThrough(BuildContext context) => showMullSheet<bool>(
  context,
  fitContent: true,
  builder: (sheet) => Padding(
    padding: const EdgeInsets.fromLTRB(30, 28, 30, 26),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Did it go through?', style: excon(28, tracking: -.02, color: sheet.c.ink)),
        const SizedBox(height: 10),
        Text(
          'Mull cannot see your UPI app, so it only records what you tell it.',
          style: ranade(13, height: 1.6, color: sheet.c.ink3),
        ),
        const SizedBox(height: 24),
        PillButton('Yes, mark it settled', onTap: () => Navigator.of(sheet).pop(true)),
        const SizedBox(height: 8),
        SecondaryButton('Not yet', onTap: () => Navigator.of(sheet).pop(false)),
      ],
    ),
  ),
);

// ---------------------------------------------------------------- reminders

/// Chases someone inside Mull, for the netted amount.
///
/// This used to open WhatsApp with the message pre-written, which was the one
/// feature guaranteeing the ledger stayed in the chat — the whole point of the
/// app is that it does not. So a reminder is a notification now, to their copy
/// of Mull, from the person they actually owe.
///
/// Someone who is not on Mull has no inbox to send to, and for them WhatsApp
/// is still the honest answer rather than a dead button.
Future<void> nudgePerson(BuildContext context, Standing standing) async {
  final store = context.readStore;
  final message = store.nudgeMessage(standing);
  HapticFeedback.mediumImpact();

  final userId = standing.member.userId;
  if (userId == null) {
    final sent = await shareOnWhatsApp(message, phone: standing.member.phone);
    if (!context.mounted) return;
    if (sent) {
      store.markNudged(standing);
      Toast.show(context, '${store.shortName(standing.member)} is not on Mull — sent on WhatsApp');
    } else {
      Toast.show(context, "Couldn't open WhatsApp");
    }
    return;
  }

  final outcome = await NoticesService.remind(
    toUserId: userId,
    groupId: standing.groups.length == 1 ? standing.groups.first.id : null,
    title: '${store.profile.name.trim().split(' ').first} is waiting on ${inr(standing.amount)}',
    body: standing.groups.length == 1 ? standing.groups.first.title : 'Across ${standing.groups.length} ledgers',
    amount: standing.amount,
  );
  if (!context.mounted) return;

  switch (outcome) {
    case ReminderOutcome.sent:
      // Only counted locally once the server took it, so a failed send does
      // not spend one of the two.
      store.markNudged(standing);
      final left = store.nudgesLeft(standing);
      Toast.show(
        context,
        left > 0
            ? 'Nudged ${store.shortName(standing.member)} · one more today'
            : 'Nudged ${store.shortName(standing.member)}',
      );
    case ReminderOutcome.outOfTurns:
      // Make the local copy agree with the server rather than arguing with it.
      // The count that matters is the one that was just enforced.
      store.spendNudges(standing);
      Toast.show(context, "That's both of today's nudges. Try again tomorrow.");
    case ReminderOutcome.failed:
      Toast.show(context, "Couldn't send that. Check your connection.");
  }
}

/// Everyone you are not square with, both directions, netted per person.
Future<String?> showWhoOwesWhat(BuildContext context) => showMullSheet<String>(
  context,
  height: (300 + context.readStore.standings.length * 76).clamp(360, 700).toDouble(),
  builder: (_) => const _EveryoneSheet(),
);

class _EveryoneSheet extends StatelessWidget {
  const _EveryoneSheet();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final owed = store.owedToYou;
    final owing = store.youOweThem;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Who owes who'),
        Expanded(
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 24),
            children: [
              Text(
                'Netted per person across every ledger you share, so nobody is '
                'chased for money you are holding half of yourself.',
                style: MullType.caption(c.ink3),
              ),
              const SizedBox(height: 22),
              if (owed.isEmpty && owing.isEmpty)
                Text('Everybody is square.', style: ranade(15, color: c.ink2))
              else ...[
                if (owing.isNotEmpty) ...[
                  const Eyebrow('You owe', size: 10.5, tracking: .18),
                  const SizedBox(height: 10),
                  CardRows(
                    children: [
                      for (final s in owing)
                        PersonRow(
                          key: ValueKey(s.member.id),
                          standing: s,
                          onOpenLedger: (id) => Navigator.of(context).pop(id),
                        ),
                    ],
                  ),
                ],
                if (owed.isNotEmpty) ...[
                  SizedBox(height: owing.isEmpty ? 0 : 28),
                  const Eyebrow('Owed to you', size: 10.5, tracking: .18),
                  const SizedBox(height: 10),
                  CardRows(
                    children: [
                      for (final s in owed)
                        PersonRow(
                          key: ValueKey(s.member.id),
                          standing: s,
                          onOpenLedger: (id) => Navigator.of(context).pop(id),
                        ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// One person, netted. Says the direction in words — there is no colour in
/// this app to say it with, and a bare signed number is a puzzle.
class PersonRow extends StatelessWidget {
  const PersonRow({
    super.key,
    required this.standing,
    this.showLedgers = true,
    this.onOpenLedger,
  });

  final Standing standing;
  final bool showLedgers;

  /// Where a ledger tapped inside the person sheet should be opened. Null in
  /// a sheet that has no navigator of its own to put a screen on.
  final void Function(String groupId)? onOpenLedger;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final square = standing.isSquare;

    final detail = [
      if (standing.groups.length == 1)
        standing.groups.first.isDirect ? 'just the two of you' : standing.groups.first.title
      else if (standing.groups.length > 1)
        'across ${standing.groups.length} ledgers',
      if (store.canNetOff(standing)) 'some cancels out',
    ].join(' · ');

    return Pressable(
      onTap: () async {
        final groupId = await showPersonSheet(context, standing);
        if (groupId != null) onOpenLedger?.call(groupId);
      },
      scale: .99,
      semanticLabel: square
          ? '${standing.member.name}, square'
          : '${standing.member.name}, '
                '${standing.theyOweYou ? 'owes you' : 'you owe'} '
                '${inr(standing.magnitude)}',
      child: ExcludeSemantics(
        // Square people recede by saying "square", not by fading: opacity on
        // a whole row takes its caption under the contrast floor.
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      store.shortName(standing.member),
                      style: ranade(16, color: square ? c.ink2 : c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (showLedgers && detail.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        detail,
                        style: MullType.caption(c.ink3, size: 11.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (square)
                Text('square', style: MullType.caption(c.ink3, size: 11.5))
              else ...[
                Text(
                  standing.theyOweYou ? 'owes you' : 'you owe',
                  style: MullType.caption(c.ink3, size: 11),
                ),
                const SizedBox(width: 9),
                Text(inr(standing.magnitude), style: MullType.cardAmount(c.ink, size: 19)),
              ],
              const SizedBox(width: 6),
              MullIcon(MullGlyph.chevronRight, size: 13, color: c.ink3, strokeWidth: 1.8),
            ],
          ),
        ),
      ),
    );
  }
}
