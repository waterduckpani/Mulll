import 'package:flutter/material.dart';

import '../../core/dates.dart';
import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'recurring_sheets.dart';

/// The things that come round on their own.
///
/// Mull asks rather than posts. A split app that quietly files rent on the 1st
/// files the *old* rent after everyone's landlord put it up, and nobody notices
/// for four months. So the next one due is the focal object on this screen,
/// with the amount right there to be changed before it is recorded.
class RecurringScreen extends StatelessWidget {
  const RecurringScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final c = context.c;
    final group = store.groupById(groupId);
    if (group == null) return const SizedBox.shrink();

    final now = store.now();
    final active = [...group.recurring.where((r) => r.isActive)]..sort((a, b) => a.nextDue.compareTo(b.nextDue));
    final resting = group.recurring.where((r) => !r.isActive).toList();
    final next = active.firstOrNull;

    // Everything else, grouped under how often it happens.
    final rest = active.skip(next == null ? 0 : 1).toList();
    final byFrequency = <Frequency, List<Recurring>>{};
    for (final r in rest) {
      byFrequency.putIfAbsent(r.frequency, () => []).add(r);
    }

    return MullPage(
      glow: const GlowSpec(size: 430, top: -160, right: -150),
      header: const DetailBar(),
      bottom: SecondaryButton(
        'Add a recurring cost',
        glyph: MullGlyph.plus,
        onTap: () => showRecurringEditor(context, group),
      ),
      children: [
        PageTitle(
          'Recurring',
          body: active.isEmpty
              ? 'Rent, wifi, the house help. Anything that comes round on its '
                    'own. Mull never posts one behind your back: each one '
                    're-opens on its date and asks.'
              : 'Standing costs for ${group.title}. Each one re-opens on its '
                    'date and settles like any other expense.',
          padding: const EdgeInsets.fromLTRB(Gutter.text, 22, Gutter.text, 0),
        ),

        if (next != null) ...[
          const SizedBox(height: 36),
          _NextUp(key: ValueKey(next.id), group: group, schedule: next, now: now),
        ],

        for (final frequency in Frequency.values)
          if (byFrequency[frequency] case final list?) ...[
            Eyebrow(
              frequency.label,
              size: 10.5,
              tracking: .18,
              padding: const EdgeInsets.fromLTRB(Gutter.text, 38, Gutter.text, 14),
            ),
            Stacked(
              gap: 8,
              padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
              children: [
                for (final schedule in list)
                  _ScheduleCard(key: ValueKey(schedule.id), group: group, schedule: schedule),
              ],
            ),
          ],

        if (resting.isNotEmpty) ...[
          const Eyebrow(
            'Paused and finished',
            size: 10.5,
            tracking: .18,
            padding: EdgeInsets.fromLTRB(Gutter.text, 38, Gutter.text, 14),
          ),
          Stacked(
            gap: 8,
            padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
            children: [
              for (final schedule in resting)
                _ScheduleCard(
                  key: ValueKey(schedule.id),
                  group: group,
                  schedule: schedule,
                  quiet: true,
                ),
            ],
          ),
        ],

        if (active.isEmpty && resting.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gutter.card, 36, Gutter.card, 0),
            child: Surface(
              lift: Lift.focal,
              radius: 28,
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Eyebrow('Nothing repeating yet', size: 10.5, tracking: .18),
                  const SizedBox(height: 14),
                  Text(
                    'Set up the first one and it shows up here a few days before '
                    'it is owed, with the amount ready to change.',
                    style: MullType.body(c.ink3),
                  ),
                  const SizedBox(height: 20),
                  InlineButton(
                    'Set one up',
                    height: 48,
                    expand: true,
                    onTap: () => showRecurringEditor(context, group),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The next thing owed, and the one focal object on this screen.
class _NextUp extends StatelessWidget {
  const _NextUp({
    super.key,
    required this.group,
    required this.schedule,
    required this.now,
  });

  final Group group;
  final Recurring schedule;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final days = daysBetween(now, schedule.nextDue);
    final yourShare = schedule.shares[group.you?.id] ?? 0;
    final payer = group.memberById(schedule.payerId);

    final when = switch (days) {
      <= 0 => 'Due now',
      1 => 'Due tomorrow',
      _ => 'Due in $days days',
    };

    return Surface(
      lift: Lift.focal,
      radius: 28,
      margin: const EdgeInsets.symmetric(horizontal: Gutter.card),
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(when, size: 10.5, tracking: .18),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      schedule.description,
                      style: MullType.cardTitle(c.ink, size: 19),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      yourShare > 0
                          ? 'Your share of ${inr(schedule.amount)}'
                          : payer == null
                          ? inr(schedule.amount)
                          : '${store.shortName(payer)} pays ${inr(schedule.amount)}',
                      style: MullType.caption(c.ink3, size: 12.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                inr(yourShare > 0 ? yourShare : schedule.amount),
                style: excon(30, tracking: -.03, color: c.ink),
              ),
            ],
          ),
          const SizedBox(height: 20),
          InlineButton(
            days <= 0 ? 'Add it now' : 'Add it early',
            height: 48,
            expand: true,
            onTap: () => showDueRecurring(context, group, schedule),
          ),
        ],
      ),
    );
  }
}

/// One standing cost in the list under its frequency.
class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({
    super.key,
    required this.group,
    required this.schedule,
    this.quiet = false,
  });

  final Group group;
  final Recurring schedule;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final payer = group.memberById(schedule.payerId);

    // "1st" reads better than "every month" under an EVERY MONTH heading.
    final cadence = switch (schedule.frequency) {
      Frequency.monthly || Frequency.quarterly || Frequency.yearly => ordinal(schedule.nextDue.day),
      _ => shortDate(schedule.nextDue),
    };

    final last = schedule.lastAddedOn;

    return Pressable(
      onTap: () => showRecurringEditor(context, group, existing: schedule),
      scale: .985,
      semanticLabel: '${schedule.description}, ${inr(schedule.amount)}',
      child: ExcludeSemantics(
        // A paused or finished schedule steps back by sitting flat, not by
        // going translucent — at 55% its caption fell to about 2.6:1 against
        // the screen, which is the exact thing the design rules out.
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 22),
          decoration: surfaceOf(
            c,
            quiet ? Lift.flat : Lift.card,
            radius: BorderRadius.circular(26),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(
                    child: Text(
                      schedule.description,
                      style: MullType.cardTitle(quiet ? c.ink2 : c.ink, size: 18),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(inr(schedule.amount), style: MullType.cardAmount(c.ink)),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                [
                  if (schedule.paused) 'Paused' else if (schedule.hasEnded) 'Finished' else cadence,
                  'split ${schedule.shares.length} ways',
                  if (payer != null && !payer.isYou) '${store.shortName(payer)} pays',
                  if (schedule.autoAdd) 'adds itself',
                  if (last != null) '${monthLabel(last, store.now())} added',
                ].join(' · '),
                style: MullType.caption(c.ink3, size: 11.5),
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
