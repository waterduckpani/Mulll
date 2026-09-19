import 'package:flutter/cupertino.dart';

import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/page.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'group_detail_screen.dart';
import 'group_sheets.dart';

class GroupsScreen extends StatelessWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final net = store.groupsNet;

    void open(Group g) =>
        Navigator.of(context).push(CupertinoPageRoute(builder: (_) => GroupDetailScreen(groupId: g.id)));

    return MullPage(
      blobs: const [
        BlobSpec(330, 64, top: 40, right: -110),
        BlobSpec(280, 70, bottom: 20, left: -100),
      ],
      bottom: PillButton('Start a group', onTap: () => showStartGroup(context, onCreated: open)),
      children: [
        PageTitle(
          'Groups',
          subtitle: store.groups.isEmpty
              ? 'Split trips, rent and dinners. Mull works out who owes whom — the money moves over UPI.'
              : null,
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        ),
        if (store.groups.isNotEmpty) _OverallCard(net: net),
        const SizedBox(height: 6),
        if (store.groups.isEmpty)
          const EmptyCard(
            margin: EdgeInsets.fromLTRB(22, 12, 22, 0),
            title: 'Sharing costs with someone?',
            body: 'Start a group for a trip, the flat or a night out. Add what people pay as it happens and settle up at the end.',
          )
        else
          for (final g in store.groups) _GroupCard(key: ValueKey(g.id), group: g, onTap: () => open(g)),
      ],
    );
  }
}

/// Where you stand across every group at once.
class _OverallCard extends StatelessWidget {
  const _OverallCard({required this.net});

  final int net;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Glass(
      margin: const EdgeInsets.fromLTRB(22, 14, 22, 0),
      radius: 30,
      padding: const EdgeInsets.fromLTRB(26, 20, 26, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            net == 0
                ? 'All square'
                : net > 0
                ? "You're owed"
                : 'You owe',
            style: ranade(12, tracking: .06, color: c.ink3),
          ),
          const SizedBox(height: 8),
          if (net == 0)
            Text('Nothing outstanding anywhere.', style: ranade(14, color: c.ink2))
          else
            AnimatedAmount(net.abs(), style: excon(46, tracking: -.03, height: .95, color: c.ink)),
        ],
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({super.key, required this.group, required this.onTap});

  final Group group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final balance = group.yourBalance;
    final shown = group.members.take(4).toList();
    final extra = group.members.length - shown.length;

    final (label, amount) = switch (balance) {
      0 => ('settled up', null),
      > 0 => ("you're owed", balance),
      _ => ('you owe', -balance),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 12, 22, 0),
      child: Pressable(
        onTap: onTap,
        scale: .98,
        child: Glass(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Text(
                      group.name,
                      style: ranade(17, color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (amount != null)
                    AnimatedAmount(amount, style: excon(24, tracking: -.02, color: c.ink))
                  else
                    Text('—', style: excon(24, color: c.ink3)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(child: Text(label, style: ranade(11.5, color: c.ink3))),
                  Text(
                    group.expenses.isEmpty
                        ? 'nothing added yet'
                        : '${inr(group.total)} spent',
                    style: ranade(11.5, color: c.ink3),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  for (final m in shown) ...[
                    Text(m.initials, style: excon(12, tracking: .1, color: c.ink3)),
                    const SizedBox(width: 12),
                  ],
                  if (extra > 0)
                    Opacity(
                      opacity: .6,
                      child: Text('+$extra', style: excon(12, tracking: .1, color: c.ink3)),
                    ),
                  const Spacer(),
                  Text(
                    '${group.members.length} ${group.members.length == 1 ? 'person' : 'people'}',
                    style: ranade(11.5, color: c.ink3),
                  ),
                ],
              ),
              if (store.groups.isNotEmpty && group.expenses.isNotEmpty && balance == 0) ...[
                const SizedBox(height: 12),
                Text('Everyone is square.', style: ranade(11.5, color: c.ink3)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
