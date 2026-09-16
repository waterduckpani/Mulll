import 'package:flutter/material.dart';

import '../../core/cycle.dart';
import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/page.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../wishlist/add_sheet.dart';
import 'budget_sheet.dart';

/// Everything spent this cycle, with the ability to log or undo a spend.
class MonthScreen extends StatelessWidget {
  const MonthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final c = context.c;
    final cycle = store.cycle;
    final spends = store.cycleSpends;
    final budget = store.budget;
    final days = cycle.daysLeft(store.now());

    return MullPage(
      blobs: const [
        BlobSpec(360, 66, top: -70, left: -90),
        BlobSpec(280, 70, bottom: 40, right: -100),
      ],
      bottom: PillButton('Log a spend', onTap: () => _logSpend(context)),
      children: [
        const DetailBar(label: 'This month'),
        Glass(
          margin: const EdgeInsets.fromLTRB(22, 12, 22, 0),
          radius: 34,
          padding: const EdgeInsets.fromLTRB(26, 22, 26, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(cycle.label, style: excon(28, tracking: -.02, color: c.ink)),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  AnimatedAmount(store.spent, style: excon(56, tracking: -.04, height: .92, color: c.ink)),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Pressable(
                      onTap: () => showBudgetSheet(context),
                      child: Text('spent of ${inr(budget)}', style: ranade(12.5, color: c.ink3)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ProgressTrack(value: budget <= 0 ? 0 : store.spent / budget),
              const SizedBox(height: 11),
              Text(
                '${shortDate(cycle.start)} – ${shortDate(cycle.end.subtract(const Duration(days: 1)))} · $days ${days == 1 ? 'day' : 'days'} left',
                style: ranade(11.5, color: c.ink3),
              ),
            ],
          ),
        ),
        const Eyebrow('What you spent', padding: EdgeInsets.fromLTRB(30, 18, 30, 0)),
        if (spends.isEmpty)
          const EmptyCard(
            margin: EdgeInsets.fromLTRB(22, 10, 22, 0),
            title: 'Nothing spent yet.',
            body: 'When you buy something from your wishlist it shows up here. You can log other spends too.',
          )
        else
          Glass(
            margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: CardRows(
              children: [
                for (final s in spends)
                  Pressable(
                    key: ValueKey(s.id),
                    onTap: () => _spendActions(context, s),
                    scale: .985,
                    haptic: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.name,
                                  style: ranade(15.5, color: c.ink),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  [shortDate(s.date), if (s.item != null) 'from wishlist'].join(' · '),
                                  style: ranade(11.5, color: c.ink3),
                                ),
                              ],
                            ),
                          ),
                          Text(inr(s.amount), style: excon(18, color: c.ink)),
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

  Future<void> _logSpend(BuildContext context) async {
    final store = context.readStore;
    final result = await showMullSheet<AddResult>(
      context,
      height: 520,
      builder: (_) => const AddSheet(
        title: 'Log a spend',
        cta: 'Log it',
        readLinks: false,
        namePlaceholder: 'What was it?',
        priceHint: 'what you paid',
        footnote: 'Counts against this month.',
      ),
    );
    if (result == null) return;
    store.logSpend(result.name, result.price);
    if (context.mounted) Toast.show(context, 'Logged ${inr(result.price)}');
  }

  Future<void> _spendActions(BuildContext context, Spend spend) {
    final store = context.readStore;
    return showMullSheet(
      context,
      fitContent: true,
      builder: (sheet) {
        void run(VoidCallback f) {
          Navigator.of(sheet).pop();
          f();
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(30, 26, 30, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Eyebrow('Spent ${shortDate(spend.date)}'),
                        const SizedBox(height: 8),
                        Text(spend.name, style: excon(24, tracking: -.02, color: sheet.c.ink)),
                      ],
                    ),
                  ),
                  Text(inr(spend.amount), style: excon(20, color: sheet.c.ink)),
                ],
              ),
              const SizedBox(height: 16),
              CardRows(
                children: [
                  if (spend.item != null)
                    SheetAction(
                      'Put back on wishlist',
                      onTap: () => run(() {
                        store.removeSpend(spend);
                        Toast.show(context, '${spend.name} is back on your wishlist');
                      }),
                    ),
                  SheetAction(
                    'Delete this spend',
                    destructive: true,
                    onTap: () => run(() {
                      store.removeSpend(spend, restoreItem: false);
                      Toast.show(
                        context,
                        'Deleted ${inr(spend.amount)} spend',
                        action: 'Undo',
                        onAction: () => store.restoreSpend(spend),
                      );
                    }),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
