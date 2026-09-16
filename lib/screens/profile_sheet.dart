import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/cycle.dart';
import '../core/money.dart';
import '../data/store.dart';
import '../ui/icons.dart';
import '../ui/sheet.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'money/budget_sheet.dart';

Future<void> showProfileSheet(BuildContext context) =>
    showMullSheet(context, height: 720, builder: (_) => const _ProfileSheet());

class _ProfileSheet extends StatefulWidget {
  const _ProfileSheet();

  @override
  State<_ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<_ProfileSheet> {
  late final _name = TextEditingController(text: context.readStore.profile.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
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
              'Your budget, wishlist, groups and lists are erased from this phone.',
              style: ranade(14, height: 1.6, color: sheet.c.ink3),
            ),
            const SizedBox(height: 24),
            PillButton('Erase everything', onTap: () => Navigator.of(sheet).pop(true)),
            const SizedBox(height: 8),
            GhostButton('Cancel', onTap: () => Navigator.of(sheet).pop(false)),
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

    Widget row(String label, String value, VoidCallback onTap) => Pressable(
      onTap: onTap,
      scale: .985,
      child: SizedBox(
        height: 58,
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: ranade(15.5, color: c.ink)),
            ),
            Text(value, style: excon(15, color: c.ink2)),
            const SizedBox(width: 8),
            MullIcon(MullGlyph.chevronRight, size: 16, color: c.ink3, strokeWidth: 1.7),
          ],
        ),
      ),
    );

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
                  help: const Text('Shown to you in groups. Everything stays on this phone.'),
                ),
                const SizedBox(height: 26),
                CardRows(
                  children: [
                    row('Monthly budget', inr(p.monthlyBudget), () => showBudgetSheet(context)),
                    row('Month starts on', 'the ${ordinal(p.resetDay)}', () => showBudgetSheet(context)),
                  ],
                ),
                Container(height: 1, color: c.line),
                const SizedBox(height: 28),
                const Eyebrow('Appearance'),
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
                if (kDebugMode) ...[
                  GhostButton(
                    'Load sample data',
                    onTap: () {
                      store.loadSample();
                      Navigator.of(context).pop();
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                GhostButton('Start over', onTap: _reset),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
