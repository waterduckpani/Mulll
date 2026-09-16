import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';

/// Hick's law: one question, two answers.
Future<void> showNeedCheck(BuildContext context, WishItem item, {bool recheck = false}) async {
  final store = context.readStore;
  final answer = await showMullSheet<ItemKind>(
    context,
    height: 640,
    builder: (_) => NeedCheckSheet(item: item, recheck: recheck),
  );
  if (answer == null) return;
  if (answer == ItemKind.need) {
    store.confirmNeed(item);
  } else {
    store.setKind(item, ItemKind.want);
    if (context.mounted) Toast.show(context, '${item.name} moved to wants');
  }
}

/// Walks through every need that hasn't been re-confirmed this month.
Future<void> recheckNeeds(BuildContext context) async {
  final store = context.readStore;
  for (final item in store.needsToRecheck) {
    if (!context.mounted) return;
    final before = item.needCheckedCycle;
    await showNeedCheck(context, item, recheck: true);
    // Dismissed without answering — stop the run.
    if (item.kind == ItemKind.need && item.needCheckedCycle == before) return;
    await Future.delayed(const Duration(milliseconds: 220));
  }
}

class NeedCheckSheet extends StatelessWidget {
  const NeedCheckSheet({super.key, required this.item, this.recheck = false});

  final WishItem item;
  final bool recheck;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 40, 32, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Eyebrow(recheck ? 'Still a need?' : 'Tagging as a need'),
                    const SizedBox(height: 8),
                    Text(
                      item.name,
                      style: ranade(16, color: c.ink),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Text(inr(item.price), style: excon(20, color: c.ink)),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "What happens if you don't buy this for thirty days?",
                        style: excon(35, tracking: -.02, height: 1.24, color: c.ink),
                      ),
                      const SizedBox(height: 22),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 280),
                        child: Text(
                          'A need is something the next month gets worse without. Everything else is a want — and wants are fine.',
                          style: ranade(14, height: 1.7, color: c.ink3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 0, 26, 34),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PillButton(
                recheck ? 'Yes, still a need' : "Yes, it's a need",
                onTap: () {
                  HapticFeedback.mediumImpact();
                  Navigator.of(context).pop(ItemKind.need);
                },
              ),
              const SizedBox(height: 8),
              GhostButton('Actually, make it a want', onTap: () => Navigator.of(context).pop(ItemKind.want)),
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  "Either way, we'll ask again next month.",
                  textAlign: TextAlign.center,
                  style: ranade(11.5, color: c.ink3),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
