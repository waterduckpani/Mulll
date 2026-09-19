import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/inbox.dart';
import '../core/money.dart';
import '../data/store.dart';
import '../ui/sheet.dart';
import '../ui/tokens.dart';
import 'groups/group_sheets.dart';
import 'home_screen.dart';

/// The app around the home screen.
///
/// There is no tab bar to hold, so this is only what a screen cannot do for
/// itself: take in what was shared from other apps, notice when the day has
/// changed under a backgrounded app, and let sheets push the whole thing back
/// as they rise.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  bool _draining = false;
  MullStore? _store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _announceAutoAdded();
      _drainInbox();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = context.readStore;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _store?.refresh();
      _announceAutoAdded();
      // Receipts are shared while Mull is backgrounded — you pay in GPay, then
      // come back here — so resuming is the common case, not launching.
      _drainInbox();
    } else if (state == AppLifecycleState.paused) {
      _store?.flush();
    }
  }

  /// A schedule set to add itself has just done so. Saying nothing would make
  /// it an expense nobody checked, which is the one thing recurring must not be.
  void _announceAutoAdded() {
    final store = _store;
    if (store == null) return;
    final made = store.runAutoRecurring();
    if (made.isEmpty || !mounted) return;
    final total = made.fold(0, (s, m) => s + m.$2.amount);
    Toast.show(
      context,
      made.length == 1
          ? 'Added ${made.first.$2.description} · ${inr(made.first.$2.amount)}'
          : 'Added ${made.length} repeating expenses · ${inr(total)}',
    );
  }

  /// Takes in whatever was shared into Mull from other apps.
  Future<void> _drainInbox() async {
    if (_draining || !mounted) return;
    _draining = true;
    try {
      // Wait for a clear screen *before* draining, not after. Reading the queue
      // deletes it, so anything pulled while a sheet is up would sit in memory
      // with nothing on disk to recover it — closing the app there would lose
      // the share silently.
      await _waitForClearScreen();
      if (!mounted) return;

      final shared = await Inbox.drain();
      final store = _store!;
      var unmatched = 0;

      for (final item in shared) {
        if (!item.isUsable) {
          unmatched++;
          continue;
        }
        final match = store.matchReceipt(item.receipt);
        if (match == null) {
          unmatched++;
          continue;
        }
        await _waitForClearScreen();
        if (!mounted) return;
        await showReceiptSettle(context, match.$1, match.$2, item.receipt);
      }

      // Silence after a share reads as the app having lost it. Better to say
      // there was nothing it lined up with than to leave the person wondering.
      if (unmatched > 0 && mounted) {
        Toast.show(
          context,
          unmatched == 1
              ? "That receipt didn't match anything you owe"
              : "$unmatched receipts didn't match anything you owe",
        );
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _waitForClearScreen() async {
    while (mounted && SheetDepth.value.value > 0) {
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ColoredBox(
      color: const Color(0xFF000000),
      child: ValueListenableBuilder<double>(
        valueListenable: SheetDepth.value,
        builder: (context, depth, child) {
          final d = depth.clamp(0.0, 1.0);
          if (d == 0) return child!;
          return Transform.scale(
            scale: 1 - .05 * d,
            alignment: Alignment.topCenter,
            child: ClipRRect(borderRadius: BorderRadius.circular(54 * d), child: child),
          );
        },
        child: Material(
          color: c.screen,
          child: Navigator(
            key: _navigator,
            onGenerateRoute: (settings) =>
                CupertinoPageRoute(builder: (_) => const HomeScreen(), settings: settings),
          ),
        ),
      ),
    );
  }
}
