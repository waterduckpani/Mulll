import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/remote/auth_service.dart';
import '../data/remote/backend.dart';
import '../data/remote/friends_service.dart';
import '../data/store.dart';
import '../ui/icons.dart';
import '../ui/sheet.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'friends_sheet.dart';
import 'home_screen.dart' show showHowItWorks;

Future<void> showProfileSheet(BuildContext context) =>
    showMullSheet(context, height: 780, builder: (_) => const _ProfileSheet());

/// Whether groups are shared with anyone, and the way in or out.
class _AccountRow extends StatefulWidget {
  const _AccountRow();

  @override
  State<_AccountRow> createState() => _AccountRowState();
}

class _AccountRowState extends State<_AccountRow> {
  @override
  Widget build(BuildContext context) {
    final c = context.c;

    if (!BackendConfig.isConfigured) {
      return Text(
        'This build has no server behind it, so groups stay on this phone.',
        style: ranade(13, height: 1.6, color: c.ink3),
      );
    }

    // Signing in is the gate, so by the time anyone reaches this sheet there is
    // an account. A null email here means the session went away underneath us.
    final email = Backend.user?.email ?? 'Not signed in';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Signed in as $email', style: ranade(13, height: 1.6, color: c.ink2)),
        const SizedBox(height: 4),
        Text('Your groups follow the account, not this phone.', style: ranade(11.5, color: c.ink3)),
        const SizedBox(height: 12),
        SecondaryButton(
          'Sign out',
          onTap: () async {
            final store = context.readStore;
            final nav = Navigator.of(context);
            await AuthService.signOut();
            // Groups belong to the account, not the phone. Leaving them behind
            // would show the next person to sign in on this device a ledger
            // that is not theirs — and the first edit would push it back up
            // under their name.
            store.replaceGroups(const []);
            nav.pop();
          },
        ),
      ],
    );
  }
}

class _ProfileSheet extends StatefulWidget {
  const _ProfileSheet();

  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  late final _name = TextEditingController(text: context.readStore.profile.name);

  /// A count, and a nudge when someone is waiting on an answer — a request
  /// nobody notices is the same as no request.
  String _friendsLabel = '';

  @override
  void initState() {
    super.initState();
    _countFriends();
  }

  Future<void> _countFriends() async {
    final friends = await FriendsService.list();
    if (!mounted) return;
    final waiting = friends.where((f) => f.state == FriendState.incoming).length;
    final connected = friends.where((f) => f.state == FriendState.friends).length;
    setState(() {
      _friendsLabel = waiting > 0
          ? '$waiting waiting'
          : connected == 0
          ? 'None yet'
          : '$connected';
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Your own VPA — the one that goes into the summaries you send people.
  Future<void> _editUpi() async {
    final store = context.readStore;
    final controller = TextEditingController(text: store.profile.upiId ?? '');
    final saved = await showMullSheet<String>(
      context,
      height: 420,
      builder: (sheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetHeader('Your UPI ID'),
          Padding(
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 0),
            child: BigField(
              controller: controller,
              autofocus: true,
              size: 22,
              hint: 'name@bank',
              help: const Text('Goes into the summaries you send, so people can pay you back.'),
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
            child: PillButton('Save', onTap: () => Navigator.of(sheet).pop(controller.text)),
          ),
        ],
      ),
    );
    controller.dispose();
    if (saved == null || !mounted) return;
    final value = saved.trim();
    store.updateProfile((p) => p.upiId = value.isEmpty ? null : value);
    await AuthService.saveProfile(upiId: value);
  }

  Future<void> _reset() async {
    final store = context.readStore;
    final nav = Navigator.of(context);
    final ok = await showMullSheet<bool>(
      context,
      fitContent: true,
      builder: (sheet) => Padding(
        padding: const EdgeInsets.fromLTRB(30, 30, 30, 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Start over?', style: excon(28, tracking: -.02, color: sheet.c.ink)),
            const SizedBox(height: 10),
            Text(
              'Every group, expense and settlement is erased from this phone.',
              style: ranade(14, height: 1.6, color: sheet.c.ink3),
            ),
            const SizedBox(height: 24),
            PillButton('Erase everything', onTap: () => Navigator.of(sheet).pop(true)),
            const SizedBox(height: 8),
            SecondaryButton('Cancel', onTap: () => Navigator.of(sheet).pop(false)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    HapticFeedback.heavyImpact();
    nav.pop();
    await store.resetAll();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final p = store.profile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SheetHeader('You'),
        Expanded(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 12, 30, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BigField(
                  controller: _name,
                  hint: 'Your name',
                  capitalization: TextCapitalization.words,
                  onChanged: (v) => store.updateProfile((p) => p.name = v.trim()),
                  help: const Text('The name people see next to your share of a bill.'),
                ),
                const SizedBox(height: 28),
                Stacked(
                  gap: 8,
                  children: [
                    FieldRow(
                      label: 'Your UPI ID',
                      value: p.upiId ?? 'Not set',
                      onTap: _editUpi,
                      trailing: MullIcon(
                        MullGlyph.chevronRight,
                        size: 14,
                        color: c.ink2,
                        strokeWidth: 1.8,
                      ),
                    ),
                    FieldRow(
                      label: 'Friends',
                      value: _friendsLabel,
                      onTap: () => showFriendsSheet(context),
                      trailing: MullIcon(
                        MullGlyph.chevronRight,
                        size: 14,
                        color: c.ink2,
                        strokeWidth: 1.8,
                      ),
                    ),
                    FieldRow(
                      label: 'How it works',
                      value: 'A minute',
                      onTap: () => showHowItWorks(context),
                      trailing: MullIcon(
                        MullGlyph.chevronRight,
                        size: 14,
                        color: c.ink2,
                        strokeWidth: 1.8,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 30),
                const Eyebrow('Groups', size: 10.5, tracking: .18),
                const SizedBox(height: 12),
                const _AccountRow(),
                const SizedBox(height: 30),
                const Eyebrow('Appearance', size: 10.5, tracking: .18),
                const SizedBox(height: 12),
                Segmented(
                  labels: const ['System', 'Light', 'Dark'],
                  index: switch (p.theme) {
                    ThemeMode.system => 0,
                    ThemeMode.light => 1,
                    ThemeMode.dark => 2,
                  },
                  onChanged: (i) => store.updateProfile((p) => p.theme = ThemeMode.values[[0, 1, 2][i]]),
                ),
                const SizedBox(height: 28),
                SecondaryButton('Start over', onTap: _reset),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
