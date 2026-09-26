/// Your people.
///
/// A friend is not a social feature here — it is the mechanism that lets
/// someone's own name and UPI ID come from their own account instead of being
/// typed in by whoever is adding them to a group. Everything on this screen
/// exists to serve that.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:share_plus/share_plus.dart';

import '../core/links.dart';
import '../data/remote/backend.dart';
import '../data/remote/friends_service.dart';
import '../data/store.dart';
import '../ui/sheet.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';

/// [onOpenLedger] is how a tapped friend gets you to the ledger with them.
/// Supplied by the caller because this sheet sits above the navigator its
/// screens live on, and pushing from here lands the group outside the shell.
Future<void> showFriendsSheet(
  BuildContext context, {
  void Function(String groupId)? onOpenLedger,
}) => showMullSheet(
  context,
  height: 720,
  builder: (_) => _FriendsSheet(onOpenLedger: onOpenLedger),
);

class _FriendsSheet extends StatefulWidget {
  const _FriendsSheet({this.onOpenLedger});

  final void Function(String groupId)? onOpenLedger;

  @override
  State<_FriendsSheet> createState() => _FriendsSheetState();
}

class _FriendsSheetState extends State<_FriendsSheet> {
  void Function(String groupId)? get openLedger => widget.onOpenLedger;

  List<Friend>? _friends;
  List<({String userId, String name})> _blocked = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final (friends, blocked) = await (FriendsService.list(), FriendsService.blocked()).wait;
    if (mounted) {
      setState(() {
        _friends = friends;
        _blocked = blocked;
      });
    }
  }

  /// Remove, report or block. Only for someone with an account: an invite to
  /// an address nobody has signed up with has nobody behind it to report.
  Future<void> _more(Friend friend) async {
    final userId = friend.userId;
    final removeLabel = switch (friend.state) {
      FriendState.friends => 'Remove friend',
      FriendState.incoming => 'Decline',
      FriendState.outgoing => 'Cancel request',
    };
    // Unfriending with money still open is off the table; blocking is not.
    final stuck = friend.state == FriendState.friends && userId != null
        ? context.readStore.whyYouCannotUnfriend(userId)
        : null;
    final choice = await showMullSheet<String>(
      context,
      fitContent: true,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 26, 20, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 18),
              child: Text(friend.label, style: excon(26, tracking: -.02, color: sheet.c.ink)),
            ),
            if (stuck == null)
              SecondaryButton(removeLabel, onTap: () => Navigator.of(sheet).pop('remove'))
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                child: Text(stuck, style: ranade(13, height: 1.55, color: sheet.c.ink3)),
              ),
            if (userId != null) ...[
              const SizedBox(height: 8),
              SecondaryButton('Report', onTap: () => Navigator.of(sheet).pop('report')),
              const SizedBox(height: 8),
              SecondaryButton('Block', onTap: () => Navigator.of(sheet).pop('block')),
            ],
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'remove':
        await _act(() => FriendsService.remove(friend.friendshipId));
      case 'report' when userId != null:
        final sent = await showReportSheet(context, name: friend.label, userId: userId);
        if (sent == true) {
          if (mounted) Toast.show(context, 'Thanks. We will look at it.');
          await _load();
        }
      case 'block' when userId != null:
        if (await _confirmBlock(friend.label)) await _act(() => FriendsService.block(userId));
    }
  }

  Future<bool> _confirmBlock(String name) async {
    final ok = await showMullSheet<bool>(
      context,
      fitContent: true,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(30, 30, 30, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Block $name?', style: excon(28, tracking: -.02, color: sheet.c.ink)),
            const SizedBox(height: 10),
            Text(
              'They will not be able to send you friend requests, reminders or '
              'notifications, and they will not be told. Groups you already share '
              'stay, because they are everyone\'s records. You can leave those.',
              style: ranade(14, height: 1.6, color: sheet.c.ink3),
            ),
            const SizedBox(height: 24),
            PillButton('Block', onTap: () => Navigator.of(sheet).pop(true)),
            const SizedBox(height: 8),
            SecondaryButton('Cancel', onTap: () => Navigator.of(sheet).pop(false)),
          ],
        ),
      ),
    );
    return ok == true;
  }

  Future<void> _add() async {
    final sent = await showAddFriendSheet(context);
    if (sent == true) await _load();
  }

  Future<void> _act(Future<FriendsResult> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await action();
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.isOk) {
      HapticFeedback.mediumImpact();
      // An accepted request can hand over seats in groups, so the ledger may
      // have just grown.
      unawaited(context.readStore.pullNow());
      await _load();
    } else if (mounted && result.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result.error!)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final friends = _friends;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Friends'),
        Expanded(
          child: friends == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : friends.isEmpty && _blocked.isEmpty
              ? _Empty(onAdd: _add)
              : ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(30, 4, 30, 16),
                  children: [
                    Text(
                      'Adding a friend to a group brings their name and UPI ID '
                      'with them, straight from their account.',
                      style: ranade(13, height: 1.6, color: c.ink3),
                    ),
                    const SizedBox(height: 20),
                    for (final friend in friends) ...[
                      _FriendRow(
                        friend: friend,
                        busy: _busy,
                        onAccept: () => _act(() => FriendsService.accept(friend.friendshipId)),
                        onRemove: () => _act(() => FriendsService.remove(friend.friendshipId)),
                        onMore: friend.hasAccount ? () => _more(friend) : null,
                      ),
                      const SizedBox(height: 4),
                    ],
                    if (_blocked.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      const Eyebrow('Blocked'),
                      const SizedBox(height: 8),
                      for (final b in _blocked)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Row(
                            children: [
                              Expanded(child: Text(b.name, style: ranade(15, color: c.ink2))),
                              Pressable(
                                onTap: _busy ? null : () => _act(() => FriendsService.unblock(b.userId)),
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: Text('Unblock', style: ranade(12.5, color: c.ink3)),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PillButton('Add a friend', onTap: _add),
              const SizedBox(height: 8),
              SecondaryButton('Invite someone to Mull', onTap: () => inviteToMull(context)),
            ],
          ),
        ),
      ],
    );
  }
}

class _FriendRow extends StatelessWidget {
  const _FriendRow({
    required this.friend,
    required this.busy,
    required this.onAccept,
    required this.onRemove,
    this.onMore,
  });

  final Friend friend;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onRemove;

  /// Remove, report and block, for someone with an account. Null for an
  /// invite nobody has claimed, which keeps a plain Cancel.
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    final (note, action) = switch (friend.state) {
      FriendState.incoming => ('Wants to be friends', 'Accept'),
      // Worth saying plainly. A request to an address with no account is not
      // broken, it is waiting — and the person sending it should know that
      // nothing happens until the other person turns up.
      FriendState.outgoing => (
        friend.hasAccount ? 'Asked, waiting on them' : 'Invited, waiting for them to join Mull',
        null,
      ),
      FriendState.friends => (friend.upiId ?? 'No UPI ID on their account yet', null),
    };

    return Semantics(
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c.quiet, shape: BoxShape.circle),
              child: Text(friend.initials, style: excon(14, color: c.ink)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    friend.label,
                    style: ranade(15, color: c.ink),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    note,
                    style: ranade(12, color: c.ink3),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (action != null) ...[
              ChipButton(action, onTap: busy ? null : onAccept),
              const SizedBox(width: 8),
            ],
            if (onMore != null)
              Pressable(
                onTap: busy ? null : onMore,
                semanticLabel: 'More for ${friend.label}',
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
                  child: Icon(Icons.more_horiz, size: 22, color: c.ink3),
                ),
              )
            else
              Pressable(
                onTap: busy ? null : onRemove,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text('Cancel', style: ranade(12.5, color: c.ink3)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 0, 30, 20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Nobody yet.', style: excon(26, tracking: -.02, color: c.ink)),
          const SizedBox(height: 10),
          Text(
            'Add the people you actually split things with. Once you are '
            'connected, putting them in a group brings their name and UPI ID '
            'with them. No more typing someone else\'s payment details and '
            'hoping you got it right.',
            style: ranade(14, height: 1.7, color: c.ink3),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ invite

/// Asks someone who is not on Mull yet to join, through whatever they chat on.
///
/// The share sheet rather than WhatsApp: it has WhatsApp in it, and also
/// iMessage and Instagram for the people who do not live in WhatsApp. Your
/// address goes in the message because that is how they add you once they
/// are in — Mull has no usernames to search.
Future<void> inviteToMull(BuildContext context) async {
  HapticFeedback.lightImpact();
  final name = context.readStore.profile.name.trim().split(' ').first;
  final email = Backend.user?.email;
  final text = [
    '${name.isEmpty ? 'I' : name} use${name.isEmpty ? '' : 's'} Mull to split bills without the '
        '"who owes what" chat. Get it here: ${MullLinks.download}',
    if (email != null && email.isNotEmpty) 'Then add me as a friend: $email',
  ].join('\n\n');
  try {
    await SharePlus.instance.share(ShareParams(text: text));
  } catch (_) {
    // No share sheet (tests, the simulator without a host). Nothing to show.
  }
}

// --------------------------------------------------------------- add a friend

Future<bool?> showAddFriendSheet(BuildContext context) =>
    showMullSheet<bool>(context, height: 460, builder: (_) => const _AddFriendSheet());

class _AddFriendSheet extends StatefulWidget {
  const _AddFriendSheet();

  @override
  State<_AddFriendSheet> createState() => _AddFriendSheetState();
}

class _AddFriendSheetState extends State<_AddFriendSheet> {
  final _email = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    _email.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await FriendsService.request(_email.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = result.error;
      _sent = result.isOk;
    });
    if (result.isOk) HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;

    if (_sent) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('Request sent'),
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 0),
            child: Text(
              // Careful wording, and the vagueness is the feature. Mull will not
              // say whether that address has an account, because an answer here
              // would let anyone check a list of addresses against its users.
              'We\'ve sent your request to ${_email.text.trim()}. They\'ll see it '
              'next time they open Mull, or when they join if they haven\'t yet.',
              style: ranade(14, height: 1.7, color: c.ink3),
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
            child: PillButton('Done', onTap: () => Navigator.of(context).pop(true)),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Add a friend'),
        Padding(
          padding: const EdgeInsets.fromLTRB(30, 12, 30, 0),
          child: BigField(
            controller: _email,
            autofocus: true,
            size: 22,
            hint: 'their@email.com',
            keyboardType: TextInputType.emailAddress,
            onSubmitted: (_) => _email.text.trim().isEmpty ? null : _send(),
            help: Text(
              'The address they use for Mull. If they are not on it yet, the '
              'request waits for them.',
              style: ranade(12, height: 1.5, color: c.ink3),
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 14, 30, 0),
            child: Text(_error!, style: ranade(13, height: 1.5, color: c.ink)),
          ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
          child: PillButton(
            _busy ? 'Sending…' : 'Send request',
            onTap: _busy || _email.text.trim().isEmpty ? null : _send,
          ),
        ),
      ],
    );
  }
}

// --------------------------------------------------------- picking for a group

/// Choose friends to seat in a group.
///
/// Returns the ones picked. The caller seats them with their `userId` attached,
/// which is what makes their name and UPI ID come from their own account
/// instead of being typed in by whoever is doing the adding.
Future<List<Friend>?> showFriendPicker(
  BuildContext context, {
  required Set<String> alreadyIn,
}) => showMullSheet<List<Friend>>(
  context,
  height: 640,
  builder: (_) => _FriendPicker(alreadyIn: alreadyIn),
);

class _FriendPicker extends StatefulWidget {
  const _FriendPicker({required this.alreadyIn});

  /// User ids already seated, so nobody is offered twice.
  final Set<String> alreadyIn;

  @override
  State<_FriendPicker> createState() => _FriendPickerState();
}

class _FriendPickerState extends State<_FriendPicker> {
  List<Friend>? _available;
  final _picked = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await FriendsService.list();
    if (!mounted) return;
    setState(() {
      // Only settled friendships with a real account behind them. A pending
      // request has no profile to take a name or a VPA from, which is the
      // entire reason to pick someone from here rather than typing them.
      _available = all
          .where((f) => f.state == FriendState.friends && f.hasAccount)
          .where((f) => !widget.alreadyIn.contains(f.userId))
          .toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final available = _available;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('Add from friends'),
        Expanded(
          child: available == null
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : available.isEmpty
              ? Padding(
                  padding: const EdgeInsets.fromLTRB(30, 0, 30, 20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Nobody to add.', style: excon(24, tracking: -.02, color: c.ink)),
                      const SizedBox(height: 10),
                      Text(
                        'Everyone you are friends with is already in this group, '
                        'or you have not added anyone yet. You can still add a '
                        'name by hand and fill in their details later.',
                        style: ranade(14, height: 1.7, color: c.ink3),
                      ),
                    ],
                  ),
                )
              : ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(30, 4, 30, 16),
                  children: [
                    for (final friend in available)
                      Pressable(
                        onTap: () => setState(() {
                          final id = friend.userId!;
                          _picked.contains(id) ? _picked.remove(id) : _picked.add(id);
                        }),
                        scale: .99,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 11),
                          child: Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: _picked.contains(friend.userId) ? c.pill : c.quiet,
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  friend.initials,
                                  style: excon(
                                    14,
                                    color: _picked.contains(friend.userId) ? c.pillInk : c.ink,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(friend.label, style: ranade(15, color: c.ink)),
                                    const SizedBox(height: 2),
                                    Text(
                                      friend.upiId ?? 'No UPI ID yet',
                                      style: ranade(12, color: c.ink3),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
          child: PillButton(
            _picked.isEmpty ? 'Pick someone' : 'Add ${_picked.length}',
            onTap: _picked.isEmpty
                ? null
                : () => Navigator.of(context).pop(
                    available!.where((f) => _picked.contains(f.userId)).toList(),
                  ),
          ),
        ),
      ],
    );
  }
}


/// Why someone is being reported, and whether to block them too.
Future<bool?> showReportSheet(BuildContext context, {required String name, required String userId}) =>
    showMullSheet<bool>(context, height: 640, builder: (_) => _ReportSheet(name: name, userId: userId));

class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.name, required this.userId});

  final String name;
  final String userId;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  static const _reasons = [
    ('spam', 'Spam or a scam'),
    ('harassment', 'Harassing or threatening me'),
    ('impersonation', 'Pretending to be someone else'),
    ('other', 'Something else'),
  ];

  final _note = TextEditingController();
  String? _reason;
  bool _alsoBlock = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final reason = _reason;
    if (reason == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await FriendsService.report(
      widget.userId,
      reason: reason,
      note: _note.text,
      alsoBlock: _alsoBlock,
    );
    if (!mounted) return;
    if (result.isOk) {
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = result.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetHeader('Report ${widget.name}'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(30, 4, 30, 16),
            children: [
              Text(
                'Reports go to the people who run Mull, not to ${widget.name}. We read every one.',
                style: ranade(13, height: 1.6, color: c.ink3),
              ),
              const SizedBox(height: 16),
              for (final (key, label) in _reasons)
                Pressable(
                  onTap: () => setState(() => _reason = key),
                  scale: .99,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    child: Row(
                      children: [
                        Expanded(child: Text(label, style: ranade(15, color: c.ink))),
                        if (_reason == key) Icon(Icons.check, size: 20, color: c.ink),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 10),
              TextField(
                controller: _note,
                maxLength: 500,
                maxLines: 3,
                minLines: 2,
                style: ranade(14, color: c.ink),
                cursorColor: c.ink,
                decoration: InputDecoration(
                  hintText: 'Anything that would help (optional)',
                  hintStyle: ranade(14, color: c.ink3),
                  border: InputBorder.none,
                  counterStyle: ranade(11, color: c.ink3),
                ),
              ),
              Row(
                children: [
                  Expanded(child: Text('Block them as well', style: ranade(15, color: c.ink))),
                  Switch.adaptive(
                    value: _alsoBlock,
                    activeTrackColor: c.ink,
                    onChanged: (v) => setState(() => _alsoBlock = v),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: ranade(13, color: c.ink2)),
              ],
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
          child: PillButton(
            _busy ? 'Sending' : 'Send report',
            onTap: _reason == null || _busy ? null : _send,
          ),
        ),
      ],
    );
  }
}
