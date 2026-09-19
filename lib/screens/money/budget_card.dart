import 'package:flutter/cupertino.dart';

import '../../core/money.dart';
import '../../data/store.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'budget_sheet.dart';
import 'month_screen.dart';

/// The ruler, at the top of the wishlist.
///
/// It leads with what is left for wants rather than "left to spend", because
/// nothing here has left anyone's account — needs are simply first in the
/// queue, so they are measured off the budget before everything else.
class BudgetCard extends StatelessWidget {
  const BudgetCard({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final c = context.c;
    final budget = store.budget;
    final spent = store.spent;
    final needs = store.needsReserved;
    final left = store.leftForWants;
    final days = store.cycle.daysLeft(store.now());
    final short = left < 0;

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
              Text(
                short ? 'Needs outgrow your budget by' : 'Left for wants',
                style: ranade(12, tracking: .06, color: c.ink3),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 70,
                child: FittedBox(
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.scaleDown,
                  child: AnimatedAmount(
                    left.abs(),
                    style: excon(
                      72,
                      tracking: -.04,
                      height: .92,
                      color: c.ink,
                      weight: short ? FontWeight.w300 : FontWeight.w400,
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
              Text(
                'Spent ${inr(spent)} · Needs ${inr(needs)}',
                style: ranade(11.5, color: c.ink3),
              ),
              const SizedBox(height: 4),
              Text('of ${inr(budget)} this month', style: ranade(11.5, color: c.ink3)),
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
