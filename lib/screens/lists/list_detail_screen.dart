import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../wishlist/add_sheet.dart';
import 'lists_screen.dart';

class ListDetailScreen extends StatelessWidget {
  const ListDetailScreen({super.key, required this.listId});

  final String listId;

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final c = context.c;
    final list = store.lists.where((l) => l.id == listId).firstOrNull;
    if (list == null) return const SizedBox.shrink();

    final budget = list.budget;
    final cut = list.reachBreak;
    final amount = budget == null ? list.total : list.inBudgetTotal;

    return MullPage(
      blobs: const [
        BlobSpec(340, 64, top: 60, right: -120),
        BlobSpec(300, 70, bottom: 0, left: -110),
      ],
      bottom: PillButton('Add to this list', onTap: () => _add(context, list)),
      children: [
        DetailBar(
          label: 'Named list',
          onLabelTap: () => _menu(context, list),
          trailing: CircleButton(
            filled: false,
            semanticLabel: 'List options',
            onTap: () => _menu(context, list),
            child: MullIcon(MullGlyph.more, size: 18, color: c.ink3),
          ),
        ),
        Glass(
          margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
          radius: 34,
          padding: const EdgeInsets.fromLTRB(26, 22, 26, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Text(list.name, style: excon(28, tracking: -.02, color: c.ink)),
                  ),
                  if (list.entries.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Text(
                        '${list.doneCount} of ${list.entries.length} done',
                        style: ranade(11.5, color: c.ink3),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  AnimatedAmount(amount, style: excon(56, tracking: -.04, height: .92, color: c.ink)),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Pressable(
                      onTap: () => showListSheet(context, list: list),
                      child: Text(
                        budget == null ? 'set a budget' : 'of ${inr(budget)}',
                        style: ranade(12.5, color: c.ink3),
                      ),
                    ),
                  ),
                ],
              ),
              if (budget != null) ...[
                const SizedBox(height: 20),
                ProgressTrack(value: budget == 0 ? 0 : amount / budget),
              ],
            ],
          ),
        ),
        if (list.entries.isEmpty)
          const EmptyCard(
            margin: EdgeInsets.fromLTRB(22, 22, 22, 0),
            title: 'An empty list.',
            body: 'Add what this needs. Tick things off as you get them.',
          )
        else
          Glass(
            margin: const EdgeInsets.fromLTRB(22, 22, 22, 0),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < list.entries.length; i++) ...[
                  if (i == cut)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: ReachLine('List budget stops here'),
                    )
                  else if (i > 0)
                    const Hairline(),
                  _EntryRow(
                    key: ValueKey(list.entries[i].id),
                    entry: list.entries[i],
                    beyond: cut != null && i >= cut,
                    onToggle: () {
                      HapticFeedback.lightImpact();
                      store.toggleEntry(list.entries[i]);
                    },
                    onTap: () => _entryActions(context, list, list.entries[i]),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _add(BuildContext context, NamedList list) async {
    final store = context.readStore;
    final result = await showMullSheet<AddResult>(
      context,
      height: 540,
      builder: (_) => AddSheet(title: 'Add to ${list.name}', cta: 'Add it', footnote: 'Tick it off once you have it.'),
    );
    if (result == null) return;
    store.addEntry(list, result.name, result.price);
    HapticFeedback.mediumImpact();
  }

  Future<void> _menu(BuildContext context, NamedList list) {
    final store = context.readStore;
    return showMullSheet(
      context,
      fitContent: true,
      builder: (sheet) {
        void run(VoidCallback f) {
          Navigator.of(sheet).pop();
          Future.delayed(const Duration(milliseconds: 160), f);
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(30, 26, 30, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Eyebrow('Named list'),
              const SizedBox(height: 8),
              Text(list.name, style: excon(24, tracking: -.02, color: sheet.c.ink)),
              const SizedBox(height: 16),
              CardRows(
                children: [
                  SheetAction('Rename or change budget', onTap: () => run(() => showListSheet(context, list: list))),
                  if (list.doneCount > 0)
                    SheetAction(
                      'Untick everything',
                      onTap: () => run(() {
                        for (final e in list.entries) {
                          e.done = false;
                        }
                        store.updateList(list);
                      }),
                    ),
                  SheetAction(
                    'Delete list',
                    destructive: true,
                    onTap: () => run(() {
                      Navigator.of(context).pop();
                      store.deleteList(list);
                      Toast.show(
                        context,
                        'Deleted ${list.name}',
                        action: 'Undo',
                        onAction: () => store.restoreList(list),
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

  Future<void> _entryActions(BuildContext context, NamedList list, ListEntry entry) {
    return showMullSheet(
      context,
      height: 560,
      builder: (_) => _EntrySheet(list: list, entry: entry),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({super.key, required this.entry, required this.beyond, required this.onToggle, required this.onTap});

  final ListEntry entry;
  final bool beyond;
  final VoidCallback onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final d = motion(context, const Duration(milliseconds: 220));
    final weight = beyond ? FontWeight.w300 : FontWeight.w400;
    return Opacity(
      opacity: beyond ? .38 : 1,
      child: Pressable(
        onTap: onTap,
        scale: .985,
        haptic: false,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: beyond ? 2 : 0),
          child: Row(
            children: [
              Transform.translate(
                offset: const Offset(-10, 0),
                child: Semantics(
                  checked: entry.done,
                  label: entry.name,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onToggle,
                    child: SizedBox(
                      width: 44,
                      height: 50,
                      child: Center(
                        child: AnimatedContainer(
                          duration: d,
                          curve: Curves.easeOutBack,
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: entry.done ? c.ink : c.ink.withValues(alpha: 0),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: entry.done ? c.ink : (beyond ? c.ink : c.line),
                              width: 1.5,
                            ),
                          ),
                          child: AnimatedScale(
                            scale: entry.done ? 1 : 0,
                            duration: d,
                            curve: Curves.easeOutBack,
                            child: MullIcon(MullGlyph.check, size: 12, color: c.screen, strokeWidth: 2.6),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Transform.translate(
                  offset: const Offset(-7, 0),
                  child: AnimatedOpacity(
                    duration: d,
                    opacity: entry.done ? .5 : 1,
                    child: Text(
                      entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ranade(
                        15.5,
                        weight: weight,
                        color: c.ink,
                        decoration: entry.done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              AnimatedOpacity(
                duration: d,
                opacity: entry.done ? .5 : 1,
                child: Text(
                  inr(entry.price),
                  style: excon(18, weight: weight, color: c.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EntrySheet extends StatefulWidget {
  const _EntrySheet({required this.list, required this.entry});

  final NamedList list;
  final ListEntry entry;

  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  late final _name = TextEditingController(text: widget.entry.name);
  late final _price = AmountController(widget.entry.price);
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
    _priceFocus.dispose();
    super.dispose();
  }

  void _apply() {
    final e = widget.entry;
    if (_name.text.trim().isNotEmpty) e.name = _name.text.trim();
    final p = _price.amount;
    if (p != null) e.price = p;
    context.readStore.updateList(widget.list);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.store;
    final list = widget.list;
    final entry = widget.entry;
    final index = list.entries.indexWhere((e) => e.id == entry.id);
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(list.name),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 16, 30, 16),
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
                ),
                const SizedBox(height: 24),
                ChoicePair<bool>(
                  options: const [(false, 'Still to get'), (true, 'Got it')],
                  value: entry.done,
                  onChanged: (v) {
                    if (v != entry.done) store.toggleEntry(entry);
                    setState(() {});
                  },
                ),
              ],
            ),
          ),
        ),
        if (!keyboardUp)
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 8, 26, 30),
            child: Row(
              children: [
                if (index > 0) ...[
                  Expanded(
                    child: GhostButton(
                      'Move to top',
                      onTap: () {
                        store.reorderEntry(list, index, 0);
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: GhostButton(
                    'Remove',
                    onTap: () {
                      Navigator.of(context).pop();
                      store.removeEntry(list, entry);
                      Toast.show(
                        context,
                        'Removed ${entry.name}',
                        action: 'Undo',
                        onAction: () => store.restoreEntry(list, entry, index),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
