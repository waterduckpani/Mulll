import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/page.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'list_detail_screen.dart';

class ListsScreen extends StatelessWidget {
  const ListsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.store;

    void open(NamedList l) =>
        Navigator.of(context).push(CupertinoPageRoute(builder: (_) => ListDetailScreen(listId: l.id)));

    return MullPage(
      blobs: const [
        BlobSpec(340, 64, top: 60, right: -120),
        BlobSpec(300, 70, bottom: 0, left: -110),
      ],
      bottom: PillButton(
        'Start a list',
        onTap: () async {
          final list = await showListSheet(context);
          if (list != null) open(list);
        },
      ),
      children: [
        const PageTitle(
          'Lists',
          subtitle: 'A trip, a move, a party. Each list keeps its own budget, separate from your month.',
          padding: EdgeInsets.fromLTRB(24, 12, 24, 0),
        ),
        const SizedBox(height: 6),
        if (store.lists.isEmpty)
          const EmptyCard(
            margin: EdgeInsets.fromLTRB(22, 12, 22, 0),
            title: 'Planning something?',
            body: 'Make a named list for everything a trip or a move needs. Give it a budget and Mull shows where it runs out.',
          )
        else
          for (final l in store.lists) _ListCard(key: ValueKey(l.id), list: l, onTap: () => open(l)),
      ],
    );
  }
}

class _ListCard extends StatelessWidget {
  const _ListCard({super.key, required this.list, required this.onTap});

  final NamedList list;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final budget = list.budget;
    final amount = budget == null ? list.total : list.inBudgetTotal;
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
                      list.name,
                      style: ranade(17, color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 12),
                  AnimatedAmount(amount, style: excon(24, tracking: -.02, color: c.ink)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      list.entries.isEmpty ? 'Empty' : '${list.doneCount} of ${list.entries.length} done',
                      style: ranade(11.5, color: c.ink3),
                    ),
                  ),
                  Text(budget == null ? 'no budget' : 'of ${inr(budget)}', style: ranade(11.5, color: c.ink3)),
                ],
              ),
              if (budget != null) ...[
                const SizedBox(height: 14),
                ProgressTrack(value: budget == 0 ? 0 : amount / budget, height: 3),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Create (or edit, when [list] is given) a named list.
Future<NamedList?> showListSheet(BuildContext context, {NamedList? list}) =>
    showMullSheet<NamedList>(context, height: 520, builder: (_) => _ListSheet(list: list));

class _ListSheet extends StatefulWidget {
  const _ListSheet({this.list});

  final NamedList? list;

  @override
  State<_ListSheet> createState() => _ListSheetState();
}

class _ListSheetState extends State<_ListSheet> {
  late final _name = TextEditingController(text: widget.list?.name ?? '');
  late final _budget = AmountController(widget.list?.budget);
  final _budgetFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _budget.addListener(() => setState(() {}));
    _budgetFocus.addListener(() {
      if (!_budgetFocus.hasFocus) _budget.tidy();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _budget.dispose();
    _budgetFocus.dispose();
    super.dispose();
  }

  bool get _budgetOk => _budget.text.trim().isEmpty || _budget.amount != null;
  bool get _valid => _name.text.trim().isNotEmpty && _budgetOk;

  void _save() {
    final store = context.readStore;
    final existing = widget.list;
    NamedList result;
    if (existing != null) {
      existing
        ..name = _name.text.trim()
        ..budget = _budget.amount;
      store.updateList(existing);
      result = existing;
    } else {
      result = store.addList(_name.text, _budget.amount);
    }
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(widget.list == null ? 'Start a list' : 'Edit list'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 16, 30, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigField(
                  controller: _name,
                  autofocus: widget.list == null,
                  hint: 'Goa trip',
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _budgetFocus.requestFocus(),
                ),
                const SizedBox(height: 22),
                BigField(
                  controller: _budget,
                  focusNode: _budgetFocus,
                  numeric: true,
                  hint: '₹0',
                  trailing: Text('optional', style: ranade(11.5, color: c.ink3)),
                  help: const Text('With a budget, the list shows where the money runs out.'),
                  onSubmitted: (_) => _valid ? _save() : null,
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(26, 8, 26, keyboardUp ? 4 : 34),
          child: PillButton(widget.list == null ? 'Start it' : 'Save', onTap: _valid ? _save : null),
        ),
      ],
    );
  }
}
