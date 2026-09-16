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

    void open(Group g) =>
        Navigator.of(context).push(CupertinoPageRoute(builder: (_) => GroupDetailScreen(groupId: g.id)));

    return MullPage(
      blobs: const [
        BlobSpec(330, 64, top: 40, right: -110),
        BlobSpec(280, 70, bottom: 20, left: -100),
      ],
      bottom: PillButton('Start a group', onTap: () => showStartGroup(context, onCreated: open)),
      children: [
        const PageTitle(
          'Groups',
          subtitle: "Mull tracks what everyone said they'd put in. Money is settled outside the app.",
          padding: EdgeInsets.fromLTRB(24, 12, 24, 0),
        ),
        const SizedBox(height: 6),
        if (store.groups.isEmpty)
          const EmptyCard(
            margin: EdgeInsets.fromLTRB(22, 12, 22, 0),
            title: 'Buying something together?',
            body: 'Start a group for a trip, a gift or the flat. Everyone declares what they will put in, and you can see what is still missing.',
          )
        else
          for (final g in store.groups) _GroupCard(key: ValueKey(g.id), group: g, onTap: () => open(g)),
      ],
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
    final shown = group.members.take(3).toList();
    final extra = group.members.length - shown.length;
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
                  AnimatedAmount(group.declared, style: excon(24, tracking: -.02, color: c.ink)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text('declared of ${inr(group.target)}', style: ranade(11.5, color: c.ink3)),
                  ),
                  Text('${(group.progress * 100).round()}%', style: ranade(11.5, color: c.ink3)),
                ],
              ),
              const SizedBox(height: 14),
              ProgressTrack(value: group.progress, height: 3),
              const SizedBox(height: 14),
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
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
