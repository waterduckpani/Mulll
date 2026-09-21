import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/money.dart';
import '../data/notices.dart';
import '../data/store.dart';
import '../ui/sheet.dart';
import '../ui/tokens.dart';
import 'home_screen.dart';
import 'notices_sheet.dart';

/// The app around the home screen.
///
/// There is no tab bar to hold, so this is only what a screen cannot do for
/// itself: notice when the day has changed under a backgrounded app, and let
/// sheets push the whole thing back as they rise.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  MullStore? _store;
  NoticesInbox? _inbox;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_announceAutoAdded());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = context.readStore;
    final inbox = context.readNotices;
    if (inbox != _inbox) {
      _inbox?.arrived.removeListener(_onNoticeArrived);
      _inbox = inbox?..arrived.addListener(_onNoticeArrived);
    }
  }

  /// Puts a notice on screen the moment it lands.
  ///
  /// Only ever live arrivals — [NoticesInbox.arrived] fires on the realtime
  /// insert and on nothing else. Replaying the inbox as banners at launch
  /// would be a wall of them every morning.
  void _onNoticeArrived() {
    final notice = _inbox?.arrived.value;
    if (notice == null || !mounted) return;
    // Not over a sheet. Something half-written behind a keyboard is not the
    // moment to drop a bar over the top of the screen.
    if (SheetDepth.value.value > 0) return;
    NoticeBanner.show(
      context,
      notice.title,
      body: notice.body,
      onTap: () => showNoticesSheet(context, into: _navigator.currentState),
    );
  }

  @override
  void dispose() {
    _inbox?.arrived.removeListener(_onNoticeArrived);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _store?.refresh();
      // `refresh()` only re-reads the clock. Coming back from the background is
      // also the single most likely moment for the screen to be stale — the
      // socket was suspended and the other person has been adding things — so
      // ask the server outright.
      unawaited(_store?.pullNow());
      // Whatever arrived while the socket was suspended is in the inbox but
      // not in memory, and the badge is what tells anyone to go and look.
      unawaited(_inbox?.refresh());
      unawaited(_announceAutoAdded());
    } else if (state == AppLifecycleState.paused) {
      _store?.flush();
    }
  }

  /// A schedule set to add itself has just done so. Saying nothing would make
  /// it an expense nobody checked, which is the one thing recurring must not be.
  ///
  /// After a pull, not before. Straight after launch this phone's copy of a
  /// schedule can be a day stale — a flatmate's phone already added this
  /// month's rent and moved it on — and running against it added the rent a
  /// second time. The occurrence ids are shared across phones as well (see
  /// [MullStore.addDue]), so a race that slips through lands on one row; this
  /// keeps it from being attempted in the first place.
  bool _addingDue = false;

  Future<void> _announceAutoAdded() async {
    final store = _store;
    if (store == null || _addingDue) return;
    _addingDue = true;
    try {
      await store.pullNow().timeout(const Duration(seconds: 8), onTimeout: () {});
      if (!mounted) return;
      final made = store.runAutoRecurring();
      if (made.isEmpty || !mounted) return;
      final total = made.fold(0, (s, m) => s + m.$2.amount);
      Toast.show(
        context,
        made.length == 1
            ? 'Added ${made.first.$2.description} · ${inr(made.first.$2.amount)}'
            : 'Added ${made.length} repeating expenses · ${inr(total)}',
      );
    } finally {
      _addingDue = false;
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
