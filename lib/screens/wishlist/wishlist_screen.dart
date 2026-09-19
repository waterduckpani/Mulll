import 'package:flutter/material.dart';

import '../../core/cycle.dart';
import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../money/budget_card.dart';
import '../shell.dart';
import 'add_sheet.dart';
import 'item_sheets.dart';
import 'need_check_sheet.dart';

class WishlistScreen extends StatelessWidget {
  const WishlistScreen({super.key});

  static const blobs = [
    BlobSpec(320, 64, top: 120, left: -120),
    BlobSpec(300, 70, bottom: -40, right: -90),
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: wishlistSegment,
      builder: (context, segment, _) {
        final store = context.store;
        final c = context.c;
        final kind = segment == 0 ? ItemKind.need : ItemKind.want;
        final layout = store.reach(kind);
        final needCount = store.needs.length;
        final wantCount = store.wants.length;
        final total = needCount + wantCount;
        final kindTotal = (kind == ItemKind.need ? store.needs : store.wants).fold(0, (s, i) => s + i.price);

        return MullPage(
          blobs: blobs,
          bottom: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (total > 0)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    'Budget covers ${store.coveredCount} of $total · ${kind == ItemKind.need ? 'needs' : 'wants'} total ${inr(kindTotal)}',
                    textAlign: TextAlign.center,
                    style: ranade(12, color: c.ink3),
                  ),
                ),
              PillButton('Add to wishlist', onTap: () => showQuickAdd(context, kind: kind)),
            ],
          ),
          children: [
            const PageTitle('Wishlist'),
            const BudgetCard(),
            if (store.needsToRecheck.isNotEmpty) const _RecheckCard(),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
              child: Segmented(
                labels: const ['Needs', 'Wants'],
                counts: [needCount, wantCount],
                index: segment,
                onChanged: (i) => wishlistSegment.value = i,
              ),
            ),
            AnimatedSwitcher(
              duration: motion(context, const Duration(milliseconds: 220)),
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, .015), end: Offset.zero).animate(anim),
                  child: child,
                ),
              ),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.topCenter,
                children: [
                  ...previous.map((p) => Positioned(top: 0, left: 0, right: 0, child: p)),
                  ?current,
                ],
              ),
              child: KeyedSubtree(
                key: ValueKey(kind),
                child: _ReachList(kind: kind, layout: layout),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ReachList extends StatelessWidget {
  const _ReachList({required this.kind, required this.layout});

  final ItemKind kind;
  final ReachLayout layout;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final now = store.now();

    if (layout.count == 0) {
      return kind == ItemKind.need
          ? const EmptyCard(
              margin: EdgeInsets.fromLTRB(22, 10, 22, 0),
              title: 'No needs right now.',
              body: "Needs are set aside from your budget first, so there's always room for them.",
            )
          : const EmptyCard(
              margin: EdgeInsets.fromLTRB(22, 10, 22, 0),
              title: 'Nothing on the wishlist.',
              body: 'Add what you have your eye on. Mull shows what your budget already covers, and what is worth waiting for.',
            );
    }

    String subtitle(WishItem i) => i.domain ?? 'Added ${daysAgo(i.createdAt, now)}';

    return AnimatedSize(
      duration: motion(context, const Duration(milliseconds: 280)),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (layout.inReach.isNotEmpty)
            Glass(
              margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
              child: CardRows(
                children: [
                  for (final item in layout.inReach)
                    _Row(
                      key: ValueKey(item.id),
                      name: item.name,
                      subtitle: subtitle(item),
                      price: item.price,
                      onTap: () => showItemSheet(context, item),
                      onMore: () => showItemActions(context, item),
                    ),
                ],
              ),
            ),
          if (layout.outOfReach.isNotEmpty) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(30, layout.inReach.isEmpty ? 18 : 8, 30, 0),
              child: ReachLine(kind == ItemKind.need ? 'Needs outgrow budget here' : 'Budget stops here'),
            ),
            Opacity(
              opacity: .42,
              child: Glass(
                margin: const EdgeInsets.fromLTRB(22, 14, 22, 0),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                child: CardRows(
                  children: [
                    for (final (item, short) in layout.outOfReach)
                      _Row(
                        key: ValueKey(item.id),
                        name: item.name,
                        // When is far more useful than how much: "₹25,800
                        // short" is a dead end, "by December" is a plan.
                        subtitle: '${subtitle(item)} · ${_waitLabel(store, item, now) ?? '${inr(short)} short'}',
                        price: item.price,
                        dimmed: true,
                        onTap: () => showItemSheet(context, item),
                        onMore: () => showItemActions(context, item),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// "in reach next month" / "in reach by December", or null when we genuinely
/// cannot say — in which case the caller falls back to how far short it is.
String? _waitLabel(MullStore store, WishItem item, DateTime now) {
  final months = store.monthsToReach(item);
  if (months == null) return null;
  if (months == 1) return 'in reach next month';
  return 'in reach by ${monthLabel(store.reachDate(item)!, now)}';
}

/// Needs quietly reserve money every month, so they have to be re-confirmed
/// every month. Otherwise one forgotten need eats the budget forever.
class _RecheckCard extends StatelessWidget {
  const _RecheckCard();

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final c = context.c;
    final recheck = store.needsToRecheck;

    return Glass(
      margin: const EdgeInsets.fromLTRB(22, 12, 22, 0),
      radius: 26,
      child: Pressable(
        onTap: () => recheckNeeds(context),
        scale: .98,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 18, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Still needs?', style: ranade(15, color: c.ink)),
                    const SizedBox(height: 3),
                    Text(
                      '${recheck.length} ${recheck.length == 1 ? 'need' : 'needs'} to re-check for ${store.cycle.label}',
                      style: ranade(11.5, color: c.ink3),
                    ),
                  ],
                ),
              ),
              MullIcon(MullGlyph.chevronRight, size: 16, color: c.ink3, strokeWidth: 1.7),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.name,
    required this.subtitle,
    required this.price,
    required this.onTap,
    required this.onMore,
    this.dimmed = false,
  });

  final String name;
  final String subtitle;
  final int price;
  final VoidCallback onTap;
  final VoidCallback onMore;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final weight = dimmed ? FontWeight.w300 : FontWeight.w400;
    return Pressable(
      onTap: onTap,
      onLongPress: onMore,
      scale: .985,
      haptic: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: ranade(16, weight: weight, color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: ranade(11.5, color: dimmed ? c.ink : c.ink3),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Text(
              inr(price),
              style: excon(19, weight: weight, color: c.ink),
            ),
            if (!dimmed)
              Transform.translate(
                offset: const Offset(12, 0),
                child: Semantics(
                  label: 'More for $name',
                  child: CircleButton(
                    filled: false,
                    onTap: onMore,
                    child: MullIcon(MullGlyph.more, size: 18, color: c.ink3),
                  ),
                ),
              )
            else
              const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}
