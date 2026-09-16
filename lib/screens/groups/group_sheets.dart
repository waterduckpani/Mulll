import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';

class NameChip extends StatelessWidget {
  const NameChip(this.label, {super.key, this.selected = false, this.onTap, this.onRemove});

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .95,
      child: AnimatedContainer(
        duration: motion(context, const Duration(milliseconds: 200)),
        height: 40,
        padding: EdgeInsets.only(left: 16, right: onRemove == null ? 16 : 4),
        decoration: BoxDecoration(
          color: selected ? c.pill : c.pill.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? c.pill : c.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: ranade(14, color: selected ? c.pillInk : c.ink2)),
            if (onRemove != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRemove,
                child: SizedBox(
                  width: 34,
                  height: 40,
                  child: Center(child: MullIcon(MullGlyph.close, size: 13, color: c.ink3, strokeWidth: 2)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Inline "add a name" input that turns entries into chips.
class _PeopleInput extends StatefulWidget {
  const _PeopleInput({required this.onAdd});

  final ValueChanged<String> onAdd;

  @override
  State<_PeopleInput> createState() => _PeopleInputState();
}

class _PeopleInputState extends State<_PeopleInput> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final names = _ctrl.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
    for (final n in names) {
      widget.onAdd(n);
    }
    _ctrl.clear();
    _focus.requestFocus();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Container(
      padding: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              style: ranade(16, color: c.ink),
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              keyboardAppearance: c.isDark ? Brightness.dark : Brightness.light,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration.collapsed(
                hintText: 'Add a name',
                hintStyle: ranade(16, color: c.ink3.withValues(alpha: .6)),
              ),
            ),
          ),
          AnimatedOpacity(
            opacity: _ctrl.text.trim().isEmpty ? .3 : 1,
            duration: const Duration(milliseconds: 150),
            child: CircleButton(
              filled: false,
              semanticLabel: 'Add person',
              onTap: _ctrl.text.trim().isEmpty ? null : _submit,
              child: MullIcon(MullGlyph.plus, size: 18, color: c.ink, strokeWidth: 1.8),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- start a group

Future<void> showStartGroup(BuildContext context, {void Function(Group)? onCreated}) async {
  final group = await showMullSheet<Group>(context, height: 700, builder: (_) => const _StartGroupSheet());
  if (group != null) onCreated?.call(group);
}

class _StartGroupSheet extends StatefulWidget {
  const _StartGroupSheet();

  @override
  State<_StartGroupSheet> createState() => _StartGroupSheetState();
}

class _StartGroupSheetState extends State<_StartGroupSheet> {
  final _name = TextEditingController();
  final _target = AmountController();
  final _targetFocus = FocusNode();
  final _people = <String>[];

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _target.addListener(() => setState(() {}));
    _targetFocus.addListener(() {
      if (!_targetFocus.hasFocus) _target.tidy();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    _targetFocus.dispose();
    super.dispose();
  }

  bool get _valid => _name.text.trim().isNotEmpty && _target.amount != null;

  void _create() {
    final store = context.readStore;
    final g = store.addGroup(_name.text, _target.amount!, _people);
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(g);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Start a group'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 16, 30, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigField(
                  controller: _name,
                  autofocus: true,
                  hint: 'Goa flights',
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) => _targetFocus.requestFocus(),
                  help: const Text('A shared buy — a trip, a gift, the flat.'),
                ),
                const SizedBox(height: 22),
                BigField(
                  controller: _target,
                  focusNode: _targetFocus,
                  numeric: true,
                  hint: '₹0',
                  trailing: Text('total to split', style: ranade(11.5, color: c.ink3)),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 28),
                const Eyebrow("Who's in"),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    const NameChip('You', selected: true),
                    for (final (i, p) in _people.indexed)
                      NameChip(p, onRemove: () => setState(() => _people.removeAt(i))),
                  ],
                ),
                const SizedBox(height: 14),
                _PeopleInput(onAdd: (n) => setState(() => _people.add(n))),
                if (_people.isNotEmpty && _target.amount != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'About ${inr((_target.amount! / (_people.length + 1)).round())} each if split evenly.',
                    style: ranade(12, color: c.ink3),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(26, 8, 26, keyboardUp ? 4 : 30),
          child: Column(
            children: [
              PillButton('Start it', onTap: _valid ? _create : null),
              if (!keyboardUp)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('No money moves through Mull.', style: ranade(11.5, color: c.ink3)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ declare

Future<void> showDeclare(BuildContext context, Group group, {Member? member}) => showMullSheet(
  context,
  height: 640,
  builder: (_) => _DeclareSheet(group: group, initial: member),
);

class _DeclareSheet extends StatefulWidget {
  const _DeclareSheet({required this.group, this.initial});

  final Group group;
  final Member? initial;

  @override
  State<_DeclareSheet> createState() => _DeclareSheetState();
}

class _DeclareSheetState extends State<_DeclareSheet> {
  late Member _member =
      widget.initial ?? widget.group.members.firstWhere((m) => m.isYou, orElse: () => widget.group.members.first);
  late final _amount = AmountController(_initialAmount(_member));
  late Pledge _status = _member.status == Pledge.none ? Pledge.declared : _member.status;
  final _focus = FocusNode();

  int? _initialAmount(Member m) {
    if (m.status != Pledge.none) return m.amount;
    final g = widget.group;
    final left = g.undeclared;
    final waiting = g.yetToSay.length;
    if (left <= 0 || waiting == 0) return null;
    return (left / waiting).round();
  }

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
    _focus.addListener(() {
      if (!_focus.hasFocus) _amount.tidy();
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _pick(Member m) {
    setState(() {
      _member = m;
      final a = _initialAmount(m);
      _amount.text = a == null ? '' : inr(a);
      _status = m.status == Pledge.none ? Pledge.declared : m.status;
    });
  }

  void _save() {
    final a = _amount.amount;
    if (a == null) return;
    context.readStore.setPledge(_member, a, _status);
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final hasPledge = _member.status != Pledge.none;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader(widget.group.name),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Eyebrow('Who'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in widget.group.members)
                      NameChip(m.isYou ? 'You' : m.name, selected: m.id == _member.id, onTap: () => _pick(m)),
                  ],
                ),
                const SizedBox(height: 28),
                BigField(
                  controller: _amount,
                  focusNode: _focus,
                  numeric: true,
                  size: 44,
                  hint: '₹0',
                  help: Text(
                    _member.isYou ? "You're putting in this much." : '${_member.name} is putting in this much.',
                  ),
                ),
                const SizedBox(height: 26),
                ChoicePair<Pledge>(
                  options: const [(Pledge.declared, 'Declared'), (Pledge.settled, 'Settled')],
                  value: _status,
                  onChanged: (s) => setState(() => _status = s),
                ),
                const SizedBox(height: 12),
                Text(
                  _status == Pledge.settled
                      ? 'Settled means the money has changed hands.'
                      : 'Declared means they have said they will put it in.',
                  textAlign: TextAlign.center,
                  style: ranade(11.5, color: c.ink3),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(26, 8, 26, keyboardUp ? 4 : 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PillButton(hasPledge ? 'Save' : 'Declare it', onTap: _amount.amount == null ? null : _save),
              if (hasPledge && !keyboardUp) ...[
                const SizedBox(height: 8),
                GhostButton(
                  'Clear their contribution',
                  onTap: () {
                    store.setPledge(_member, 0, Pledge.none);
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------------- settings

/// Resolves to 'deleted' when the group was removed.
Future<String?> showGroupSettings(BuildContext context, Group group) =>
    showMullSheet<String>(context, height: 720, builder: (_) => _GroupSettingsSheet(group: group));

class _GroupSettingsSheet extends StatefulWidget {
  const _GroupSettingsSheet({required this.group});

  final Group group;

  @override
  State<_GroupSettingsSheet> createState() => _GroupSettingsSheetState();
}

class _GroupSettingsSheetState extends State<_GroupSettingsSheet> {
  late final _name = TextEditingController(text: widget.group.name);
  late final _target = AmountController(widget.group.target);
  final _targetFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _targetFocus.addListener(() {
      if (!_targetFocus.hasFocus) _target.tidy();
    });
  }

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    _targetFocus.dispose();
    super.dispose();
  }

  void _apply() {
    final g = widget.group;
    if (_name.text.trim().isNotEmpty) g.name = _name.text.trim();
    final t = _target.amount;
    if (t != null) g.target = t;
    context.readStore.updateGroup(g);
  }

  Future<void> _delete() async {
    final store = context.readStore;
    final nav = Navigator.of(context);
    final confirmed = await showMullSheet<bool>(
      context,
      fitContent: true,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(30, 30, 30, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Delete ${widget.group.name}?', style: excon(28, tracking: -.02, color: sheet.c.ink)),
            const SizedBox(height: 10),
            Text(
              'Everyone\'s declarations go with it. This can\'t be undone.',
              style: ranade(14, height: 1.6, color: sheet.c.ink3),
            ),
            const SizedBox(height: 24),
            PillButton('Delete group', onTap: () => Navigator.of(sheet).pop(true)),
            const SizedBox(height: 8),
            GhostButton('Keep it', onTap: () => Navigator.of(sheet).pop(false)),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    store.deleteGroup(widget.group);
    nav.pop('deleted');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final g = widget.group;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Group'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigField(controller: _name, hint: 'Name', onChanged: (_) => _apply()),
                const SizedBox(height: 22),
                BigField(
                  controller: _target,
                  focusNode: _targetFocus,
                  numeric: true,
                  hint: '₹0',
                  onChanged: (_) => _apply(),
                  trailing: Text('target', style: ranade(11.5, color: c.ink3)),
                ),
                const SizedBox(height: 28),
                Eyebrow('${g.members.length} people'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in g.members)
                      NameChip(
                        m.isYou ? 'You' : m.name,
                        selected: m.isYou,
                        onRemove: m.isYou ? null : () => store.removeMember(g, m),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                _PeopleInput(onAdd: (n) => store.addMember(g, n)),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(26, 8, 26, 30),
          child: GhostButton('Delete group', onTap: _delete),
        ),
      ],
    );
  }
}
