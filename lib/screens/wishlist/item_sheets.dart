import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/cycle.dart';
import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';

/// Buys [item], pausing first only when the buy lands past this month's line.
///
/// Nothing is asked when it fits. Two wants being in reach together already
/// means the budget covers both, so buying one costs the other nothing — a
/// confirmation there would be theatre. Going past the line is the one moment
/// that deserves a beat.
Future<void> buyWithUndo(BuildContext context, WishItem item) async {
  final store = context.readStore;
  final over = store.overBudgetBy(item);
  final needsMoney = item.kind == ItemKind.want && over == 0 && item.price > store.leftForWants;

  if (over > 0 || needsMoney) {
    final go = await _confirmStretch(context, item, over: over, needsMoney: needsMoney);
    if (go != true || !context.mounted) return;
  }

  final spend = store.buyItem(item);
  HapticFeedback.heavyImpact();
  Toast.show(
    context,
    'Bought ${item.name} · ${inr(item.price)} logged',
    action: 'Undo',
    onAction: () {
      store.removeSpend(spend);
    },
  );
}

Future<bool?> _confirmStretch(
  BuildContext context,
  WishItem item, {
  required int over,
  required bool needsMoney,
}) {
  final store = context.readStore;
  final waitUntil = store.reachDate(item);
  final now = store.now();

  return showMullSheet<bool>(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Eyebrow(over > 0 ? 'Past this month' : 'That is needs money'),
          const SizedBox(height: 10),
          Text(
            over > 0
                ? '${inr(over)} more than ${store.cycle.label} has left.'
                : 'Buying this dips into what you set aside for your needs.',
            style: excon(24, tracking: -.02, height: 1.2, color: sheet.c.ink),
          ),
          const SizedBox(height: 12),
          Text(
            waitUntil == null
                ? 'You can still buy it — Mull just logs it and the month runs short.'
                : 'Wait and it comes into reach by ${monthLabel(waitUntil, now)}.',
            style: ranade(13, height: 1.55, color: sheet.c.ink3),
          ),
          const SizedBox(height: 22),
          PillButton('Buy it anyway', onTap: () => Navigator.of(sheet).pop(true)),
          const SizedBox(height: 8),
          GhostButton("I'll wait", onTap: () => Navigator.of(sheet).pop(false)),
        ],
      ),
    ),
  );
}

void removeWithUndo(BuildContext context, WishItem item) {
  final store = context.readStore;
  store.removeItem(item);
  HapticFeedback.mediumImpact();
  Toast.show(context, 'Removed ${item.name}', action: 'Undo', onAction: () => store.restoreItem(item));
}

Future<void> openLink(String url) async {
  final uri = Uri.tryParse(url);
  if (uri != null) await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// The ⋯ menu on a wishlist row.
Future<void> showItemActions(BuildContext context, WishItem item) {
  final store = context.readStore;
  final isFirst = store.reach(item.kind).inReach.firstOrNull?.id == item.id;
  return showMullSheet(
    context,
    fitContent: true,
    builder: (sheet) {
      void run(VoidCallback action) {
        Navigator.of(sheet).pop();
        Future.delayed(const Duration(milliseconds: 160), action);
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
                      Eyebrow(item.kind == ItemKind.need ? 'Need' : 'Want'),
                      const SizedBox(height: 8),
                      Text(item.name, style: excon(24, tracking: -.02, color: sheet.c.ink), maxLines: 2),
                    ],
                  ),
                ),
                Text(inr(item.price), style: excon(20, color: sheet.c.ink)),
              ],
            ),
            const SizedBox(height: 16),
            CardRows(
              children: [
                SheetAction('I bought it', onTap: () => run(() => buyWithUndo(context, item))),
                SheetAction('Edit details', onTap: () => run(() => showItemSheet(context, item))),
                if (!isFirst)
                  SheetAction(
                    'Move to the top',
                    onTap: () => run(() {
                      store.moveToTop(item);
                      HapticFeedback.lightImpact();
                    }),
                  ),
                SheetAction(
                  item.kind == ItemKind.need ? 'Make it a want' : 'Make it a need',
                  onTap: () =>
                      run(() => store.setKind(item, item.kind == ItemKind.need ? ItemKind.want : ItemKind.need)),
                ),
                if (item.url != null) SheetAction('Open ${item.domain}', onTap: () => run(() => openLink(item.url!))),
                SheetAction('Remove', destructive: true, onTap: () => run(() => removeWithUndo(context, item))),
              ],
            ),
          ],
        ),
      );
    },
  );
}

Future<void> showItemSheet(BuildContext context, WishItem item) =>
    showMullSheet(context, height: 700, builder: (_) => ItemSheet(item: item));

/// Edit everything about an item. Changes apply live.
class ItemSheet extends StatefulWidget {
  const ItemSheet({super.key, required this.item});

  final WishItem item;

  @override
  State<ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<ItemSheet> {
  late final _name = TextEditingController(text: widget.item.name);
  late final _price = AmountController(widget.item.price);
  late final _url = TextEditingController(text: widget.item.url ?? '');
  final _priceFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _priceFocus.addListener(() {
      if (!_priceFocus.hasFocus) _price.tidy();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _url.dispose();
    _priceFocus.dispose();
    super.dispose();
  }

  void _apply() {
    final store = context.readStore;
    final item = widget.item;
    final name = _name.text.trim();
    if (name.isNotEmpty) item.name = name;
    final price = _price.amount;
    if (price != null) item.price = price;
    final url = _url.text.trim();
    item.url = url.isEmpty ? null : (url.startsWith('http') ? url : 'https://$url');
    store.updateItem(item);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final item = widget.item;
    final now = store.now();
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final saved = item.originalPrice - item.price;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(item.kind == ItemKind.need ? 'Edit need' : 'Edit want'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigField(controller: _name, hint: 'Name', onChanged: (_) => _apply()),
                const SizedBox(height: 22),
                BigField(
                  controller: _price,
                  focusNode: _priceFocus,
                  numeric: true,
                  hint: '₹0',
                  onChanged: (_) => _apply(),
                  trailing: Text(
                    saved > 0 ? '${inr(saved)} less than when added' : 'update if it changes',
                    style: ranade(11.5, color: c.ink3),
                  ),
                ),
                const SizedBox(height: 22),
                Container(
                  padding: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.line)),
                  ),
                  child: TextField(
                    controller: _url,
                    onChanged: (_) => _apply(),
                    style: ranade(15, color: c.ink),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    keyboardAppearance: c.isDark ? Brightness.dark : Brightness.light,
                    decoration: InputDecoration.collapsed(
                      hintText: 'Link (optional)',
                      hintStyle: ranade(15, color: c.ink3.withValues(alpha: .6)),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                ChoicePair<ItemKind>(
                  options: const [(ItemKind.need, 'Need'), (ItemKind.want, 'Want')],
                  value: item.kind,
                  onChanged: (k) {
                    store.setKind(item, k);
                    setState(() {});
                  },
                ),
                const SizedBox(height: 16),
                Text(
                  'Added ${daysAgo(item.createdAt, now)}',
                  textAlign: TextAlign.center,
                  style: ranade(11.5, color: c.ink3),
                ),
              ],
            ),
          ),
        ),
        if (!keyboardUp)
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 8, 26, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PillButton(
                  'I bought it',
                  onTap: () {
                    Navigator.of(context).pop();
                    buyWithUndo(context, item);
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (item.url != null) ...[
                      Expanded(child: GhostButton('Open ${item.domain}', onTap: () => openLink(item.url!))),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: GhostButton(
                        'Remove',
                        onTap: () {
                          Navigator.of(context).pop();
                          removeWithUndo(context, item);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
