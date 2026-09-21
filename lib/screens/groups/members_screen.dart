/// Who is in a group, and who runs it.
///
/// This did not exist. Membership lived as a row of chips at the bottom of a
/// settings sheet, every seat looked identical, and the only honest answer to
/// "who added Kabir?" was "somebody did". Four people splitting real money
/// need a name against the decisions and a list they can point at.
///
/// Two roles and no more. Everything about the *ledger* — adding an expense,
/// settling up, confirming a payment — stays open to everyone, because that is
/// what being in a group is. Being an admin is about the group itself: its
/// name, its icon, who is in it, and whether it still exists.
library;

import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../friends_sheet.dart';
import 'create_group_flow.dart' show showAddSomeoneSheet;
import 'group_sheets.dart';

class GroupMembersScreen extends StatelessWidget {
  const GroupMembersScreen({super.key, required this.groupId});

  final String groupId;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final group = store.groupById(groupId);
    if (group == null) return const SizedBox.shrink();

    final youAreAdmin = group.youAreAdmin;
    final admins = group.admins.length;
    // Your own seat carries no account id locally — it is built from the
    // profile, which has none — so asking `isLinked` about yourself says no
    // and the header confidently reported you as not on Mull.
    final onMull = group.members.where((m) => m.isYou || m.isLinked).length;

    Future<void> addFromFriends() async {
      final picked = await showFriendPicker(
        context,
        alreadyIn: {
          for (final m in group.members)
            if (m.userId != null) m.userId!,
        },
      );
      if (picked == null) return;
      for (final friend in picked) {
        store.addFriendAsMember(
          group,
          userId: friend.userId!,
          name: friend.label,
          email: friend.email,
          upiId: friend.upiId,
        );
      }
    }

    Future<void> addByHand() async {
      final name = await showAddSomeoneSheet(context);
      if (name == null || !context.mounted) return;
      store.addMember(group, name);
    }

    Future<void> leave() async {
      final nav = Navigator.of(context);
      if (await confirmLeaveGroup(context, group)) {
        // Two pops: this screen and the group behind it, both of which are
        // now about a group this phone is no longer in.
        nav
          ..pop()
          ..pop();
      }
    }

    return MullPage(
      glow: const GlowSpec(size: 420, top: -160, right: -150),
      onRefresh: store.pullNow,
      header: const DetailBar(),
      bottom: youAreAdmin && !group.isDirect
          ? PillButton('Add people', glyph: MullGlyph.plus, onTap: addFromFriends)
          : null,
      children: [
        PageTitle(
          group.isDirect ? 'Just you two' : 'People',
          subtitle: group.isDirect
              ? null
              : [
                  '${group.members.length} ${group.members.length == 1 ? 'person' : 'people'}',
                  '$admins ${admins == 1 ? 'admin' : 'admins'}',
                  if (onMull < group.members.length) '${group.members.length - onMull} not on Mull',
                ].join(' · '),
          padding: const EdgeInsets.fromLTRB(Gutter.text, 22, Gutter.text, 0),
        ),

        const SizedBox(height: 30),

        Stacked(
          gap: 8,
          padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
          children: [
            for (final m in _ordered(group))
              _MemberRow(
                key: ValueKey(m.id),
                group: group,
                member: m,
                youAreAdmin: youAreAdmin,
              ),
          ],
        ),

        if (youAreAdmin && !group.isDirect) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Gutter.text, 22, Gutter.text, 0),
            child: Pressable(
              onTap: addByHand,
              scale: .99,
              child: Row(
                children: [
                  MullIcon(MullGlyph.plus, size: 16, color: c.ink2, strokeWidth: 1.8),
                  const SizedBox(width: 12),
                  Text('Add someone not on Mull', style: ranade(15, color: c.ink2)),
                ],
              ),
            ),
          ),
        ],

        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.text, 26, Gutter.text, 0),
          child: Text(
            group.isDirect
                ? 'A one-to-one ledger belongs to both of you. Either of you can '
                      'rename or delete it.'
                : youAreAdmin
                ? 'Admins rename the group, change its icon, add and remove '
                      'people, and delete it. Everyone can add expenses and settle up.'
                : 'Everyone here can add expenses and settle up. Renaming the '
                      'group and changing who is in it is an admin’s job.',
            style: MullType.caption(c.ink3),
          ),
        ),

        if (!group.isDirect) ...[
          const SizedBox(height: 26),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
            child: SecondaryButton('Leave this group', onTap: leave),
          ),
        ],
      ],
    );
  }
}

/// You first, then admins, then everyone else alphabetically. A list whose
/// order changes every time somebody pays for something is a list nobody can
/// find anyone in.
List<Member> _ordered(Group group) {
  final members = [...group.members];
  members.sort((a, b) {
    if (a.isYou != b.isYou) return a.isYou ? -1 : 1;
    if (a.isAdmin != b.isAdmin) return a.isAdmin ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return members;
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.group,
    required this.member,
    required this.youAreAdmin,
  });

  final Group group;
  final Member member;
  final bool youAreAdmin;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    // What they owe *you* here, not what they owe the group.
    //
    // "Sahil is owed ₹1,600" was the group's number against a name, which
    // almost everyone read as being about them and you. It can point the
    // opposite way to the truth: Sahil can be owed by the group while owing
    // you directly, and the screen said so with a straight face.
    final balance = member.isYou
        ? group.yourBalance
        : group.pairBalanceWithYou(member.id);

    final standing = switch (null) {
      _ when !member.isYou && !member.isLinked => 'Not on Mull yet',
      _ when member.isAdmin => 'Admin',
      _ => 'Member',
    };

    return Pressable(
      onTap: () => showMemberSheet(context, group, member),
      scale: .985,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: surfaceOf(c, Lift.card, radius: BorderRadius.circular(24)),
        child: Row(
          children: [
            // Initials rather than a photo. There are no avatars anywhere in
            // Mull and adding one here would mean an upload, a crop and a
            // bucket for something read at 15 pixels.
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: surfaceOf(c, Lift.low, radius: BorderRadius.circular(20)),
              child: Text(member.initials, style: ranade(13.5, color: c.ink2)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          store.displayName(member),
                          style: MullType.cardTitle(c.ink, size: 16.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (member.isAdmin && !group.isDirect) ...[
                        const SizedBox(width: 8),
                        const _RoleTag('Admin'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (group.isDirect || !member.isAdmin) standing,
                      if (!member.isYou && member.isLinked && member.upiId == null) 'no UPI ID yet',
                      if (!member.isYou && !member.isLinked && member.email != null) member.email!,
                    ].where((s) => s.isNotEmpty).join(' · '),
                    style: MullType.caption(c.ink3, size: 11.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (balance != 0)
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    member.isYou
                        ? (balance > 0 ? 'you get back' : 'you owe')
                        : (balance > 0 ? 'owes you' : 'you owe them'),
                    style: MullType.caption(c.ink3, size: 11),
                  ),
                  const SizedBox(height: 1),
                  Text(inr(balance.abs()), style: MullType.listAmount(c.ink)),
                ],
              )
            else
              Text('square', style: MullType.caption(c.ink3, size: 11.5)),
          ],
        ),
      ),
    );
  }
}

/// The word "Admin" against a name, in the only way this design allows: a
/// quiet pill, no colour.
class _RoleTag extends StatelessWidget {
  const _RoleTag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.quiet, borderRadius: BorderRadius.circular(9)),
      child: Text(label.toUpperCase(), style: eyebrow(c.ink2, size: 9, tracking: .14)),
    );
  }
}
