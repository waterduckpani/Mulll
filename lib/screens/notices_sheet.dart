/// What other people have told you.
///
/// Newest first, no filters and no folders. An inbox in a split app has a
/// handful of things in it and every one of them is about money between two
/// people — anything more structured than a list would be inventing a problem.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/dates.dart';
import '../core/money.dart';
import '../data/notices.dart';
import '../data/remote/notices_service.dart';
import '../data/store.dart';
import '../ui/icons.dart';
import '../ui/page.dart';
import '../ui/sheet.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'groups/group_detail_screen.dart';

/// [into] is the navigator a tapped notice should open its group on.
///
/// Needed because the banner is raised by the shell, which sits *above* the
/// navigator the app's screens live in — so `Navigator.of` from there finds
/// the root one and lands the group screen over the top of everything, outside
/// the shell that is supposed to recede behind it.
Future<void> showNoticesSheet(BuildContext context, {NavigatorState? into}) async {
  final inbox = context.readNotices;
  // Opening it is what marks it seen. A separate "mark all read" button is a
  // second thing to do about something you have already done.
  unawaited(inbox?.markAllRead());
  unawaited(inbox?.refresh());

  // The sheet answers with a group rather than navigating itself. Its own
  // context dies with it, and a route pushed from a dead context lands on the
  // root navigator — over the top of the sheet's own scrim, with no way back.
  final groupId = await showMullSheet<String>(
    context,
    height: 700,
    builder: (_) => const _NoticesSheet(),
  );
  if (groupId == null || !context.mounted) return;
  if (context.readStore.groupById(groupId) == null) return;
  await (into ?? Navigator.of(context)).push(
    CupertinoPageRoute(builder: (_) => GroupDetailScreen(groupId: groupId)),
  );
}

class _NoticesSheet extends StatelessWidget {
  const _NoticesSheet();

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final inbox = context.notices;
    final all = inbox?.all ?? const <Notified>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Activity'),
        Expanded(
          child: inbox == null
              ? _Empty(
                  line: 'This build has no server behind it, so there is nobody '
                      'to hear from.',
                )
              : inbox.isLoading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : all.isEmpty
              ? const _Empty(
                  line: 'Nothing yet. When someone adds an expense you are in, '
                      'settles with you, or gives you a nudge, it lands here.',
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(Gutter.text, 8, Gutter.text, 24),
                  itemCount: all.length,
                  itemBuilder: (context, i) => _NoticeRow(
                    notice: all[i],
                    first: i == 0,
                    last: i == all.length - 1,
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.text, 0, Gutter.text, 18),
          child: Text(
            'Mull only tells the people a change is actually about — the split, '
            'or the two ends of a payment. Never the whole group.',
            style: MullType.caption(c.ink3, size: 11.5),
          ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.line});

  final String line;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gutter.text, 10, Gutter.text, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('All quiet.', style: MullType.statement(c.ink, size: 30)),
          const SizedBox(height: 12),
          Text(line, style: MullType.body(c.ink3)),
        ],
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.notice, required this.first, required this.last});

  final Notified notice;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.readStore;
    final group = notice.groupId == null ? null : store.groupById(notice.groupId!);

    void open() {
      if (group == null) return;
      Navigator.of(context).pop(group.id);
    }

    return Column(
      children: [
        if (!first) const Hairline(),
        Pressable(
          onTap: group == null ? null : open,
          scale: .99,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: MullIcon(
                    _glyph(notice.kind),
                    size: 15,
                    color: notice.unread ? c.ink : c.ink3,
                    strokeWidth: 1.7,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notice.title,
                        style: ranade(15, height: 1.35, color: notice.unread ? c.ink : c.ink2),
                      ),
                      if (notice.body.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(notice.body, style: MullType.caption(c.ink3, size: 11.5)),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        daysAgo(notice.at, store.now()),
                        style: MullType.caption(c.ink3, size: 11),
                      ),
                    ],
                  ),
                ),
                if (notice.amount != null) ...[
                  const SizedBox(width: 12),
                  Text(inr(notice.amount!), style: MullType.listAmount(c.ink2)),
                ],
                if (group != null) ...[
                  const SizedBox(width: 10),
                  MullIcon(MullGlyph.chevronRight, size: 13, color: c.ink3, strokeWidth: 1.8),
                ],
              ],
            ),
          ),
        ),
        if (last) const SizedBox(height: 4),
      ],
    );
  }
}

MullGlyph _glyph(NoticeKind kind) => switch (kind) {
  NoticeKind.reminder => MullGlyph.bell,
  NoticeKind.addedToGroup => MullGlyph.groups,
  NoticeKind.expenseAdded || NoticeKind.expenseRemoved => MullGlyph.plus,
  NoticeKind.expenseChanged => MullGlyph.more,
  NoticeKind.settlementConfirmed => MullGlyph.check,
  NoticeKind.settlementDisputed || NoticeKind.settlementRemoved => MullGlyph.close,
  NoticeKind.settlementClaimed => MullGlyph.arrowUpRight,
  NoticeKind.nettedOff => MullGlyph.repeat,
};
