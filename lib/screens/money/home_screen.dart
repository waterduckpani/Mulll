import 'package:flutter/cupertino.dart';

import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../shell.dart';
import '../wishlist/add_sheet.dart';
import '../wishlist/item_sheets.dart';
import '../wishlist/need_check_sheet.dart';
import 'budget_sheet.dart';
import 'month_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final c = context.c;
    final cycle = store.cycle;
    final upNext = store.upNext;
    final total = store.items.length;
    final recheck = store.needsToRecheck;

    return MullPage(
      blobs: const [
        BlobSpec(340, 60, top: -60, right: -90),
        BlobSpec(300, 70, bottom: 60, left: -110),
      ],
      bottom: PillButton('Add something', onTap: () => showQuickAdd(context)),
      children: [
        PageTitle(cycle.label),
        const _BudgetCard(),
        if (recheck.isNotEmpty)
          Glass(
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
                            '${recheck.length} ${recheck.length == 1 ? 'need' : 'needs'} to re-check for ${cycle.label}',
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
          ),
        const Eyebrow('Up next', padding: EdgeInsets.fromLTRB(30, 14, 30, 0)),
        if (upNext.isEmpty)
          EmptyCard(
            title: total == 0 ? 'Nothing to buy yet.' : 'Nothing fits right now.',
            body: total == 0
                ? "Add the next thing you're thinking about. We'll show where it lands against your budget."
                : "Everything on your wishlist is past this month's budget. It's worth the wait.",
          )
        else
          Glass(
            margin: const EdgeInsets.fromLTRB(22, 14, 22, 0),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CardRows(
                  children: [
                    for (final item in upNext.take(2))
                      Pressable(
                        key: ValueKey(item.id),
                        onTap: () => showItemSheet(context, item),
                        onLongPress: () => showItemActions(context, item),
                        scale: .985,
                        haptic: false,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.name,
                                      style: ranade(16, color: c.ink),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      [item.kind == ItemKind.need ? 'Need' : 'Want', ?item.domain].join(' · '),
                                      style: ranade(11.5, color: c.ink3),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 14),
                              Text(inr(item.price), style: excon(19, color: c.ink)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
                const Hairline(),
                Pressable(
                  onTap: () => ShellScope.of(context).goTo(
                    MullTab.wishlist,
                    wishlistSegment: upNext.first.kind == ItemKind.need ? 0 : 1,
                  ),
                  scale: .985,
                  child: SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'See all $total ${total == 1 ? 'item' : 'items'}',
                            style: ranade(13.5, color: c.ink3),
                          ),
                        ),
                        MullIcon(MullGlyph.chevronRight, size: 16, color: c.ink3, strokeWidth: 1.7),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _BudgetCard extends StatelessWidget {
  const _BudgetCard();

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final c = context.c;
    final budget = store.budget;
    final spent = store.spent;
    final needs = store.needsTotal;
    final free = store.free;
    final days = store.cycle.daysLeft(store.now());
    final over = free < 0;

    double frac(int v) => budget <= 0 ? 0 : (v / budget).clamp(0.0, 1.0);
    final spentF = frac(spent);
    final needsF = frac(needs).clamp(0.0, 1 - spentF);

    return Glass(
      margin: const EdgeInsets.fromLTRB(22, 12, 22, 0),
      radius: 34,
      child: Pressable(
        onTap: () => Navigator.of(context).push(CupertinoPageRoute(builder: (_) => const MonthScreen())),
        scale: .985,
        haptic: false,
        semanticLabel: 'This month',
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 20, 26, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(over ? 'Over budget by' : 'Left to spend', style: ranade(12, tracking: .06, color: c.ink3)),
              const SizedBox(height: 10),
              SizedBox(
                height: 70,
                child: FittedBox(
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.scaleDown,
                  child: AnimatedAmount(
                    free.abs(),
                    style: excon(
                      72,
                      tracking: -.04,
                      height: .92,
                      color: c.ink,
                      weight: over ? FontWeight.w300 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      days <= 1 ? 'Resets tomorrow' : 'Resets in $days days',
                      style: ranade(13, color: c.ink3),
                    ),
                  ),
                  ChipButton('Adjust budget', onTap: () => showBudgetSheet(context)),
                ],
              ),
              const SizedBox(height: 26),
              SizedBox(
                height: 4,
                child: LayoutBuilder(
                  builder: (context, box) {
                    const gap = 4.0;
                    final w = box.maxWidth - gap * 2;
                    return Row(
                      children: [
                        _Seg(width: w * spentF, color: c.ink),
                        SizedBox(width: spentF > 0 ? gap : 0),
                        _Seg(width: w * needsF, color: c.ink.withValues(alpha: .35)),
                        SizedBox(width: needsF > 0 ? gap : 0),
                        Expanded(
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: c.line, borderRadius: BorderRadius.circular(2)),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 11),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Spent ${inr(spent)}', style: ranade(11.5, color: c.ink3)),
                  Text('Needs ${inr(needs)}', style: ranade(11.5, color: c.ink3)),
                  Text('Free ${inr(free < 0 ? 0 : free)}', style: ranade(11.5, color: c.ink3)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Seg extends StatelessWidget {
  const _Seg({required this.width, required this.color});

  final double width;
  final Color color;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: motion(context, const Duration(milliseconds: 600)),
    curve: Curves.easeOutCubic,
    width: width,
    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
  );
}
