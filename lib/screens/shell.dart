import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/inbox.dart';
import '../data/store.dart';
import '../ui/icons.dart';
import '../ui/page.dart';
import '../ui/sheet.dart';
import '../ui/tokens.dart';
import '../ui/widgets.dart';
import 'groups/groups_screen.dart';
import 'lists/lists_screen.dart';
import 'money/home_screen.dart';
import 'wishlist/add_sheet.dart';
import 'wishlist/in_reach_screen.dart';
import 'wishlist/wishlist_screen.dart';

enum MullTab { money, wishlist, groups, lists }

/// Lets any screen switch tabs (e.g. "See all 11 items" → Wishlist).
class ShellScope extends InheritedWidget {
  const ShellScope({super.key, required this.goTo, required super.child});

  final void Function(MullTab tab, {int? wishlistSegment}) goTo;

  static ShellScope of(BuildContext context) => context.getInheritedWidgetOfExactType<ShellScope>()!;

  @override
  bool updateShouldNotify(ShellScope oldWidget) => false;
}

/// Requested segment for the wishlist tab (0 = needs, 1 = wants).
final ValueNotifier<int> wishlistSegment = ValueNotifier(1);

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  MullTab _tab = MullTab.money;
  final _navigators = {for (final t in MullTab.values) t: GlobalKey<NavigatorState>()};
  bool _showingReach = false;
  bool _draining = false;
  MullStore? _store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainInbox());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.readStore;
    if (store != _store) {
      _store?.removeListener(_checkMoments);
      _store = store..addListener(_checkMoments);
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkMoments());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _store?.removeListener(_checkMoments);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _store?.refresh();
      // Shares land while Mull is backgrounded, so resuming is the common case
      // — the user shares from Zara, then opens Mull.
      _drainInbox();
    } else if (state == AppLifecycleState.paused) {
      _store?.flush();
    }
  }

  /// Offers whatever was shared into Mull from other apps, one item at a time.
  ///
  /// The share extension only queues; every guess still has to pass through the
  /// same editable sheet as a typed entry, because OCR is a guess and the user
  /// is the one who knows what they actually looked at.
  Future<void> _drainInbox() async {
    if (_draining || !mounted) return;
    _draining = true;
    try {
      // Wait for a clear screen *before* draining, not after. Reading the queue
      // deletes it, so anything pulled while a sheet or the in-reach moment is
      // up would sit in memory with nothing on disk to recover it — closing the
      // app there would lose the share silently.
      await _waitForClearScreen();
      if (!mounted) return;

      for (final item in await Inbox.drain()) {
        await _waitForClearScreen();
        if (!mounted) return;
        _select(MullTab.wishlist);
        await showQuickAdd(context, shared: item);
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _waitForClearScreen() async {
    while (mounted && (SheetDepth.value.value > 0 || _showingReach)) {
      await Future.delayed(const Duration(milliseconds: 600));
    }
  }

  /// Peak-end: when a want that waited below the line crosses it, celebrate once.
  void _checkMoments() {
    if (_showingReach || !mounted) return;
    final pending = _store!.pendingInReach;
    if (pending.isEmpty) return;
    // Never interrupt a sheet or a flow in progress.
    if (SheetDepth.value.value > 0) {
      Future.delayed(const Duration(milliseconds: 600), _checkMoments);
      return;
    }
    _showingReach = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _select(MullTab.wishlist);
      final nav = _navigators[MullTab.wishlist]!.currentState!;
      await nav.push(InReachScreen.route(pending.first));
      _showingReach = false;
      if (mounted) Future.delayed(const Duration(milliseconds: 400), _checkMoments);
    });
  }

  void _select(MullTab tab, {int? segment}) {
    if (segment != null) wishlistSegment.value = segment;
    if (tab == _tab) {
      _navigators[tab]!.currentState?.popUntil((r) => r.isFirst);
      return;
    }
    setState(() => _tab = tab);
  }

  Widget _root(MullTab tab) => switch (tab) {
    MullTab.money => const HomeScreen(),
    MullTab.wishlist => const WishlistScreen(),
    MullTab.groups => const GroupsScreen(),
    MullTab.lists => const ListsScreen(),
  };

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ShellScope(
      goTo: (tab, {wishlistSegment}) => _select(tab, segment: wishlistSegment),
      child: ColoredBox(
        color: Colors.black,
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
            child: Stack(
              children: [
                for (final tab in MullTab.values)
                  _TabLayer(
                    active: tab == _tab,
                    child: Navigator(
                      key: _navigators[tab],
                      onGenerateRoute: (settings) => CupertinoPageRoute(builder: (_) => _root(tab), settings: settings),
                    ),
                  ),
                Positioned(
                  left: 22,
                  right: 22,
                  bottom: ShellMetrics.tabBarBottom(context),
                  child: _TabBar(current: _tab, onSelect: _select),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabLayer extends StatelessWidget {
  const _TabLayer({required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !active,
        // The fade must keep ticking as a tab leaves, so TickerMode sits inside it.
        child: AnimatedOpacity(
          opacity: active ? 1 : 0,
          duration: motion(context, const Duration(milliseconds: 180)),
          curve: Curves.easeOut,
          child: TickerMode(
            enabled: active,
            child: ExcludeSemantics(excluding: !active, child: child),
          ),
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.current, required this.onSelect});

  final MullTab current;
  final void Function(MullTab) onSelect;

  static const _items = [
    (MullTab.money, MullGlyph.money, 'Money'),
    (MullTab.wishlist, MullGlyph.wishlist, 'Wishlist'),
    (MullTab.groups, MullGlyph.groups, 'Groups'),
    (MullTab.lists, MullGlyph.lists, 'Lists'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final d = motion(context, const Duration(milliseconds: 340));
    return ClipRRect(
      borderRadius: BorderRadius.circular(34),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          height: ShellMetrics.tabBarHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: c.isDark ? c.glass : c.glass.withValues(alpha: .74),
            borderRadius: BorderRadius.circular(34),
            border: Border.all(color: c.glassBorder),
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              const gap = 6.0;
              final w = (box.maxWidth - gap * 3) / 4;
              return Stack(
                alignment: Alignment.centerLeft,
                children: [
                  AnimatedPositioned(
                    duration: d,
                    curve: Curves.easeOutBack,
                    left: current.index * (w + gap),
                    width: w,
                    top: 5,
                    bottom: 5,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: c.pill, borderRadius: BorderRadius.circular(24)),
                    ),
                  ),
                  Row(
                    children: [
                      for (final (tab, glyph, label) in _items) ...[
                        if (tab.index > 0) const SizedBox(width: gap),
                        SizedBox(
                          width: w,
                          height: 56,
                          child: Semantics(
                            selected: tab == current,
                            button: true,
                            label: label,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                onSelect(tab);
                              },
                              child: TweenAnimationBuilder<Color?>(
                                tween: ColorTween(end: tab == current ? c.pillInk : c.ink3),
                                duration: d,
                                builder: (context, color, _) => ExcludeSemantics(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      MullIcon(glyph, color: color),
                                      const SizedBox(height: 4),
                                      Text(label, style: ranade(10.5, tracking: .04, color: color, height: 1.1)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
