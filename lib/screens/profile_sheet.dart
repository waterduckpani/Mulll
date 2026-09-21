import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/links.dart';
import '../core/upi.dart';
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
import 'upi_picker.dart';

Future<void> showProfileSheet(BuildContext context) =>
    showMullSheet(context, height: 780, builder: (_) => const _ProfileSheet());

/// A yes-or-no sheet for something that cannot be taken back.
Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final ok = await showMullSheet<bool>(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(30, 30, 30, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: excon(28, tracking: -.02, color: sheet.c.ink)),
          const SizedBox(height: 10),
          Text(body, style: ranade(14, height: 1.6, color: sheet.c.ink3)),
          const SizedBox(height: 24),
          PillButton(action, onTap: () => Navigator.of(sheet).pop(true)),
          const SizedBox(height: 8),
          SecondaryButton('Cancel', onTap: () => Navigator.of(sheet).pop(false)),
        ],
      ),
    ),
  );
  return ok == true;
}

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
            // Everything local goes with the account, so anything that has not
            // reached the server yet goes with it. Say so first.
            if (store.hasPendingChanges &&
                !await _confirm(
                  context,
                  title: 'Not everything has synced',
                  body: 'Some changes on this phone have not reached the server yet. '
                      'Signing out now loses them. Connect first to keep them.',
                  action: 'Sign out anyway',
                )) {
              return;
            }
            await AuthService.signOut();
            // Groups and the profile belong to the account, not the phone.
            // Leaving them behind showed the next person to sign in a ledger
            // that was not theirs, under your name and with your UPI ID in
            // their reminders.
            await store.forgetAccount();
            nav.pop();
          },
        ),
        const SizedBox(height: 8),
        SecondaryButton(
          'Delete account',
          onTap: () async {
            final store = context.readStore;
            final nav = Navigator.of(context);
            final messenger = ScaffoldMessenger.of(context);
            if (!await _confirm(
              context,
              title: 'Delete your account?',
              body: 'Your account, friends and inbox are deleted. The groups you were '
                  'in keep their history for everyone else, under your name, with '
                  'no way left to reach or pay you. This cannot be undone.',
              action: 'Delete my account',
            )) {
              return;
            }
            final result = await AuthService.deleteAccount();
            if (!result.isOk) {
              messenger.showSnackBar(SnackBar(content: Text(result.error!)));
              return;
            }
            HapticFeedback.heavyImpact();
            await store.forgetAccount();
            nav.pop();
          },
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final (label, page) in [
              ('Privacy', MullLinks.privacy),
              ('Terms', MullLinks.terms),
              ('Help', MullLinks.support),
            ])
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => MullLinks.open(page),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Text(label, style: ranade(12.5, color: c.ink3)),
                ),
              ),
          ],
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

  /// The server copy of your name, saved once typing stops. It never used to
  /// be saved from here at all, and the pull takes your seat's name from the
  /// account — so a rename snapped back within twenty seconds and nobody else
  /// ever saw it.
  Timer? _saveName;

  void _nameChanged(String value) {
    final name = value.trim();
    context.readStore.updateProfile((p) => p.name = name);
    _saveName?.cancel();
    if (name.isEmpty) return;
    _saveName = Timer(const Duration(milliseconds: 700), () => AuthService.saveProfile(name: name));
  }

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
    // Closing the sheet mid-word still saves the word.
    if (_saveName?.isActive ?? false) {
      _saveName!.cancel();
      final name = _name.text.trim();
      if (name.isNotEmpty) unawaited(AuthService.saveProfile(name: name));
    }
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
      // People pay you at whatever is saved here, and a handle with a typo in
      // it either fails in their UPI app or pays somebody else.
      builder: (sheet) => ListenableBuilder(
        listenable: controller,
        builder: (sheet, _) {
          final typed = controller.text.trim();
          final looksRight = typed.isEmpty || isUpiId(typed);
          return Column(
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
                  help: Text(
                    looksRight
                        ? 'Goes into the summaries you send, so people can pay you back.'
                        : "That doesn't look like a UPI ID. They usually read name@bank.",
                  ),
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
                child: PillButton(
                  'Save',
                  onTap: looksRight ? () => Navigator.of(sheet).pop(controller.text) : null,
                ),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    if (saved == null || !mounted) return;
    final value = saved.trim();
    store.updateProfile((p) => p.upiId = value.isEmpty ? null : value);
    await AuthService.saveProfile(upiId: value);
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
                  onChanged: _nameChanged,
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
                      label: 'Pay with',
                      value: UpiApp.byKey(p.payWith)?.label ?? 'Ask me',
                      onTap: () => chooseUpiApp(context, ask: true),
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
              ],
            ),
          ),
        ),
      ],
    );
  }
}
