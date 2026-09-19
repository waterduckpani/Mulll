import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models.dart';
import '../../data/remote/friends_service.dart';
import '../../data/store.dart';
import '../../ui/icons.dart';
import '../../ui/page.dart';
import '../../ui/sheet.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../friends_sheet.dart';

/// Starting a group, in two questions.
///
/// Two full screens rather than one sheet with everything on it. Naming a
/// thing and deciding who is in it are separate decisions, and a sheet that
/// asks both at once ends up as a form: a field, a list, a wall of helper text,
/// and a button that is disabled for reasons you have to hunt for.
///
/// Returns the group it made, or null if the flow was closed.
Future<Group?> showCreateGroup(
  BuildContext context, {
  String? name,
  GroupKind kind = GroupKind.group,
}) {
  return Navigator.of(context).push<Group>(
    PageRouteBuilder(
      transitionDuration: const Duration(milliseconds: 420),
      reverseTransitionDuration: const Duration(milliseconds: 280),
      opaque: false,
      barrierColor: null,
      pageBuilder: (_, _, _) => CreateGroupFlow(initialName: name, kind: kind),
      transitionsBuilder: (context, animation, _, child) {
        final t = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutQuart,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: t,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, .04), end: Offset.zero).animate(t),
            child: child,
          ),
        );
      },
    ),
  );
}

class CreateGroupFlow extends StatefulWidget {
  const CreateGroupFlow({super.key, this.initialName, this.kind = GroupKind.group});

  /// Pre-filled when the flow was started from a suggestion on the home screen.
  final String? initialName;
  final GroupKind kind;

  @override
  State<CreateGroupFlow> createState() => _CreateGroupFlowState();
}

class _CreateGroupFlowState extends State<CreateGroupFlow> {
  final _name = TextEditingController();
  final _nameFocus = FocusNode();

  /// People with a Mull account behind them, so their name and UPI ID come off
  /// their own profile rather than being typed in here.
  List<Friend>? _friends;
  final _picked = <String>{};

  /// Names typed by hand, for anyone not on Mull.
  final _typed = <String>[];

  int _step = 0;

  /// A direct ledger has one other seat and no name of its own, so it skips
  /// straight to the question of who it is with.
  ///
  /// Not derived from the argument, because the first screen offers to switch:
  /// "the flat" and "what I owe Ritu" are the same ledger underneath, and
  /// making someone back out and start again to say which one they meant is
  /// the kind of dead end that loses people.
  late bool _direct = widget.kind == GroupKind.direct;

  @override
  void initState() {
    super.initState();
    _name.text = widget.initialName ?? '';
    _name.addListener(() => setState(() {}));
    if (_direct) _step = 1;
    _loadFriends();
    // A pre-filled name has already answered step one, so the keyboard would
    // only be in the way. An empty one wants the caret straight away.
    if (!_direct && (widget.initialName ?? '').isEmpty) {
      Future.delayed(const Duration(milliseconds: 420), () {
        if (mounted && _step == 0) _nameFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    final all = await FriendsService.list();
    if (!mounted) return;
    setState(() {
      _friends = all.where((f) => f.state == FriendState.friends && f.hasAccount).toList();
    });
  }

  String get _title => _name.text.trim();

  void _next() {
    FocusScope.of(context).unfocus();
    HapticFeedback.lightImpact();
    setState(() => _step = 1);
  }

  /// Back out of the people step: a ledger that was switched to one person
  /// goes back to being a group first, so the switch is undoable.
  void _backFromPeople() {
    HapticFeedback.lightImpact();
    setState(() {
      _direct = false;
      _step = 0;
    });
    Future.delayed(const Duration(milliseconds: 360), () {
      if (mounted && _step == 0) _nameFocus.requestFocus();
    });
  }

  Future<void> _addByHand() async {
    final name = await showAddSomeoneSheet(context);
    if (name == null || !mounted) return;
    setState(() => _typed.add(name));
  }

  Future<void> _inviteToMull() async {
    final added = await showAddFriendSheet(context);
    if (added != true || !mounted) return;
    await _loadFriends();
  }

  List<Friend> get _pickedFriends =>
      (_friends ?? const []).where((f) => _picked.contains(f.userId)).toList();

  /// "You, Sahil, Ananya" — the line under the list, so the group is legible
  /// before it exists.
  String get _roster {
    final names = [
      'You',
      for (final f in _pickedFriends) f.label.split(' ').first,
      for (final t in _typed) t.split(' ').first,
    ];
    return names.join(', ');
  }

  void _create() {
    final store = context.readStore;
    final Group group;
    if (_direct) {
      final friend = _pickedFriends.firstOrNull;
      group = store.directWith(
        name: friend?.label ?? _typed.first,
        userId: friend?.userId,
        email: friend?.email,
        upiId: friend?.upiId,
      );
    } else {
      group = store.addGroup(
        _title,
        _typed,
        friends: [
          for (final f in _pickedFriends)
            Member(name: f.label, userId: f.userId, email: f.email, upiId: f.upiId),
        ],
      );
    }
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(group);
  }

  bool get _canCreate => _direct ? (_picked.length + _typed.length) == 1 : true;

  @override
  Widget build(BuildContext context) {
    final onName = _step == 0;
    return PopScope(
      canPop: onName || widget.kind == GroupKind.direct,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backFromPeople();
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: onName ? _nameStep() : _peopleStep(),
      ),
    );
  }

  // ------------------------------------------------------------ 1 of 2: name

  Widget _nameStep() {
    final c = context.c;
    return MullPage(
      key: const ValueKey('name'),
      glow: const GlowSpec(size: 440, top: -160, left: -150, right: null),
      header: DetailBar(
        leading: const CloseButtonCircle(),
        label: '1 of 2',
      ),
      bottom: PillButton(
        'Next',
        glyph: MullGlyph.chevronRight,
        glyphTrailing: true,
        onTap: _title.isEmpty ? null : _next,
      ),
      children: [
        const PageStatement(
          'What are you sharing?',
          padding: EdgeInsets.fromLTRB(Gutter.text, 40, Gutter.text, 0),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.text, 40, Gutter.text, 0),
          child: BigField(
            controller: _name,
            focusNode: _nameFocus,
            hint: 'Goa trip',
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _title.isEmpty ? null : _next(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.text, 26, Gutter.text, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final suggestion in const ['Flat', 'Dinner', 'Weekend', 'Trip'])
                ChipButton(
                  suggestion,
                  selected: _title.toLowerCase() == suggestion.toLowerCase(),
                  onTap: () {
                    _name
                      ..text = suggestion
                      ..selection = TextSelection.collapsed(offset: suggestion.length);
                  },
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.text, 26, Gutter.text, 0),
          child: Text(
            'A trip, the flat, a night out. Anywhere costs get shared.',
            style: MullType.caption(c.ink3),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.text, 26, Gutter.text, 0),
          child: Pressable(
            onTap: () {
              FocusScope.of(context).unfocus();
              HapticFeedback.lightImpact();
              setState(() {
                _direct = true;
                _step = 1;
              });
            },
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Just one person?', style: MullType.caption(c.ink3, size: 13)),
                Text(
                  'Keep a ledger with them',
                  style: ranade(13, color: c.ink2, decoration: TextDecoration.underline),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // --------------------------------------------------- 2 of 2: who is in it

  Widget _peopleStep() {
    final c = context.c;
    final friends = _friends;
    final title = _direct ? 'this' : _title;

    return MullPage(
      key: const ValueKey('people'),
      glow: const GlowSpec(size: 440, top: -160, right: -150),
      header: DetailBar(
        leading: widget.kind == GroupKind.direct
            ? const CloseButtonCircle()
            : BackButtonCircle(onTap: _backFromPeople),
        label: _direct ? null : '2 of 2',
      ),
      footnote: _direct ? null : _roster,
      bottom: PillButton(
        _direct
            ? 'Start this ledger'
            : _title.isEmpty
            ? 'Start it'
            : 'Start $_title',
        onTap: _canCreate ? _create : null,
      ),
      children: [
        PageStatement(
          _direct ? "Who's it with?" : "Who's in on $title?",
          padding: const EdgeInsets.fromLTRB(Gutter.text, 36, Gutter.text, 0),
        ),
        const SizedBox(height: 34),

        if (friends == null)
          const Padding(
            padding: EdgeInsets.only(top: 30),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else ...[
          Stacked(
            gap: 8,
            padding: const EdgeInsets.symmetric(horizontal: Gutter.card),
            children: [
              for (final friend in friends)
                SelectionRow(
                  key: ValueKey(friend.userId),
                  label: friend.label,
                  detail: friend.upiId == null ? 'No UPI ID on their account yet' : null,
                  selected: _picked.contains(friend.userId),
                  onTap: () => setState(() {
                    final id = friend.userId!;
                    if (_picked.contains(id)) {
                      _picked.remove(id);
                    } else {
                      // One other seat is the whole point of a direct ledger.
                      if (_direct) {
                        _picked.clear();
                        _typed.clear();
                      }
                      _picked.add(id);
                    }
                  }),
                ),
              for (final (i, name) in _typed.indexed)
                SelectionRow(
                  key: ValueKey('typed-$i-$name'),
                  label: name,
                  detail: 'Not on Mull, settle in person',
                  selected: true,
                  onTap: () => setState(() => _typed.removeAt(i)),
                ),
            ],
          ),
          if (friends.isEmpty && _typed.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Gutter.text, 4, Gutter.text, 0),
              child: Text(
                _direct
                    ? 'Add the person you are splitting with. If they are on Mull, '
                          'their UPI ID comes from their own account.'
                    : 'Nobody on Mull yet. Add names by hand for now, or invite '
                          'someone so their UPI ID comes from their own account.',
                style: MullType.caption(c.ink3),
              ),
            ),
          _AddRow(
            label: 'Add someone not on Mull',
            onTap: _addByHand,
          ),
          _AddRow(
            label: 'Invite someone to Mull',
            onTap: _inviteToMull,
          ),
        ],
      ],
    );
  }
}

/// The quiet "+ do this" line under a list.
class _AddRow extends StatelessWidget {
  const _AddRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .99,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gutter.text, 18, Gutter.text, 0),
        child: Row(
          children: [
            MullIcon(MullGlyph.plus, size: 16, color: c.ink2, strokeWidth: 1.8),
            const SizedBox(width: 12),
            Text(label, style: ranade(15, color: c.ink2)),
          ],
        ),
      ),
    );
  }
}

/// Just a name. Everything else about a placeholder can be filled in later,
/// and asking for it now is what stops people adding the friend who is sitting
/// across the table from them.
Future<String?> showAddSomeoneSheet(BuildContext context) {
  final controller = TextEditingController();
  return showMullSheet<String>(
    context,
    fitContent: true,
    builder: (sheet) => _AddSomeoneSheet(controller: controller),
  ).whenComplete(controller.dispose);
}

class _AddSomeoneSheet extends StatefulWidget {
  const _AddSomeoneSheet({required this.controller});

  final TextEditingController controller;

  @override
  State<_AddSomeoneSheet> createState() => _AddSomeoneSheetState();
}

class _AddSomeoneSheetState extends State<_AddSomeoneSheet> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  void _submit() {
    final name = widget.controller.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Add someone'),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.text, 16, Gutter.text, 0),
          child: BigField(
            controller: widget.controller,
            autofocus: true,
            hint: 'Their name',
            capitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            help: Text(
              'A placeholder seat. You can settle up with them in person and '
              'mark it here, or invite them to Mull later.',
              style: MullType.caption(c.ink3),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gutter.card, 26, Gutter.card, 26),
          child: PillButton(
            'Add them',
            onTap: widget.controller.text.trim().isEmpty ? null : _submit,
          ),
        ),
      ],
    );
  }
}
