import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'group_sheets.dart';

class GroupDetailScreen extends StatelessWidget {
  const GroupDetailScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final c = context.c;
    final group = store.groups.where((g) => g.id == groupId).firstOrNull;
    if (group == null) return const SizedBox.shrink();

    final pledged = group.members.where((m) => m.status != Pledge.none).toList()
      ..sort((a, b) => a.isYou ? -1 : (b.isYou ? 1 : b.status.index.compareTo(a.status.index)));
    final waiting = group.yetToSay;
    final over = group.declared - group.target;

    final summary = [
      if (over > 0)
        '${inr(over)} over target'
      else if (group.undeclared > 0)
        '${inr(group.undeclared)} undeclared'
      else
        'Fully declared',
      if (waiting.isNotEmpty) '${waiting.length} ${waiting.length == 1 ? 'person' : 'people'} yet to say',
    ].join(' · ');

    Future<void> settings() async {
      final result = await showGroupSettings(context, group);
      if (result == 'deleted' && context.mounted) Navigator.of(context).pop();
    }

    return MullPage(
      blobs: const [
        BlobSpec(360, 66, top: -70, left: -90),
        BlobSpec(280, 70, bottom: 40, right: -100),
      ],
      bottom: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'No money moves through Mull.\nSettle over UPI between yourselves.',
              textAlign: TextAlign.center,
              style: ranade(11.5, height: 1.6, color: c.ink3),
            ),
          ),
          PillButton('Declare a contribution', onTap: () => showDeclare(context, group)),
        ],
      ),
      children: [
        DetailBar(
          label: '${group.members.length} people',
          onLabelTap: settings,
          trailing: CircleButton(
            filled: false,
            semanticLabel: 'Group settings',
            onTap: settings,
            child: MullIcon(MullGlyph.more, size: 18, color: c.ink3),
          ),
        ),
        Glass(
          margin: const EdgeInsets.fromLTRB(22, 12, 22, 0),
          radius: 34,
          padding: const EdgeInsets.fromLTRB(26, 22, 26, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(group.name, style: excon(28, tracking: -.02, color: c.ink)),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  AnimatedAmount(group.declared, style: excon(56, tracking: -.04, height: .92, color: c.ink)),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text('of ${inr(group.target)}', style: ranade(12.5, color: c.ink3)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ProgressTrack(value: group.progress),
              const SizedBox(height: 11),
              Text(summary, style: ranade(11.5, color: c.ink3)),
            ],
          ),
        ),
        const Eyebrow("Who's putting in what", padding: EdgeInsets.fromLTRB(30, 18, 30, 0)),
        Glass(
          margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
          child: CardRows(
            children: [
              for (final m in pledged)
                _MemberRow(
                  key: ValueKey(m.id),
                  initials: m.initials,
                  name: store.displayName(m),
                  status: m.status == Pledge.settled ? 'Settled' : 'Declared',
                  amount: m.amount,
                  onTap: () => showDeclare(context, group, member: m),
                ),
              if (waiting.isNotEmpty)
                Opacity(
                  opacity: .4,
                  child: _MemberRow(
                    initials: waiting.first.initials,
                    name: waiting.map((m) => m.isYou ? 'You' : m.name.split(' ').first).join(', '),
                    status: 'Nothing yet',
                    light: true,
                    onTap: () => showDeclare(context, group, member: waiting.first),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.initials,
    required this.name,
    required this.status,
    this.amount,
    this.light = false,
    required this.onTap,
  });

  final String initials;
  final String name;
  final String status;
  final int? amount;
  final bool light;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .985,
      haptic: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 38,
              child: Text(initials, style: excon(12, tracking: .1, color: light ? c.ink : c.ink3)),
            ),
            Expanded(
              child: Text(
                name,
                style: ranade(15.5, weight: light ? FontWeight.w300 : FontWeight.w400, color: c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 10),
            Text(status.toUpperCase(), style: ranade(10, tracking: .12, color: light ? c.ink : c.ink3)),
            if (amount != null) ...[
              const SizedBox(width: 10),
              Text(inr(amount!), style: excon(18, color: c.ink)),
            ],
          ],
        ),
      ),
    );
  }
}
