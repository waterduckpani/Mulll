import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../ui/page.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import 'item_sheets.dart';

/// Peak-end: the moment a want you waited on fits the budget.
class InReachScreen extends StatefulWidget {
  const InReachScreen({super.key, required this.item});

  final WishItem item;

  static Route<void> route(WishItem item) => PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 520),
    reverseTransitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (_, _, _) => InReachScreen(item: item),
    transitionsBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  );

  @override
  State<InReachScreen> createState() => _InReachScreenState();
}

class _InReachScreenState extends State<InReachScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  late final int _free = context.readStore.leftForWants;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      _enter.forward();
      HapticFeedback.mediumImpact();
      Future.delayed(const Duration(milliseconds: 950), () {
        if (mounted) HapticFeedback.heavyImpact();
      });
    });
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  String get _headline {
    final name = widget.item.name.trim();
    final lower = name.length > 1 && name[1] == name[1].toLowerCase()
        ? name[0].toLowerCase() + name.substring(1)
        : name;
    return 'The $lower you waited on is yours.';
  }

  void _finish(bool buy) {
    if (_done) return;
    _done = true;
    final store = context.readStore;
    final item = widget.item;
    if (buy) {
      buyWithUndo(context, item);
      if (item.url != null) openLink(item.url!);
    } else {
      store.keepWaiting(item);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final store = context.store;
    final item = widget.item;
    final waited = store.now().difference(item.createdAt).inDays;
    final saved = item.originalPrice - item.price;
    final details = [
      'Waited $waited ${waited == 1 ? 'day' : 'days'}',
      if (saved > 0) 'saved ${inr(saved)} by waiting',
    ].join(' · ');

    Widget stagger(double start, Widget child) {
      final anim = CurvedAnimation(
        parent: _enter,
        curve: Interval(start, (start + .55).clamp(0, 1), curve: Curves.easeOutCubic),
      );
      return AnimatedBuilder(
        animation: anim,
        builder: (context, child) => Opacity(
          opacity: anim.value,
          child: Transform.translate(offset: Offset(0, 18 * (1 - anim.value)), child: child),
        ),
        child: child,
      );
    }

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_done) {
          _done = true;
          store.keepWaiting(item);
        }
      },
      child: Stack(
        children: [
          const Positioned.fill(
            child: Backdrop(
              blobs: [
                BlobSpec(360, 62, top: -40, left: -90),
                BlobSpec(300, 70, bottom: 100, right: -110),
              ],
            ),
          ),
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: ShellMetrics.tabBarBottom(context) + ShellMetrics.tabBarHeight + 14),
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
                        child: BrandBar(initial: store.profile.initial),
                      ),
                      const Spacer(),
                      stagger(
                        0,
                        Glass(
                          radius: 38,
                          margin: const EdgeInsets.symmetric(horizontal: 22),
                          padding: const EdgeInsets.fromLTRB(28, 34, 28, 30),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Eyebrow('In reach now'),
                              const SizedBox(height: 16),
                              Text(
                                _headline,
                                style: excon(34, weight: FontWeight.w500, height: 1.2, tracking: -.02, color: c.ink),
                              ),
                              const SizedBox(height: 22),
                              stagger(
                                .2,
                                Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.end,
                                  spacing: 12,
                                  children: [
                                    FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: Text(
                                        inr(item.price),
                                        style: excon(52, tracking: -.04, height: .92, color: c.ink),
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 2),
                                      child: Text('of ${inr(_free)} free', style: ranade(12.5, color: c.ink3)),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 20),
                              AnimatedBuilder(
                                animation: _enter,
                                builder: (context, _) => _enter.value < .3
                                    ? const ProgressTrack(value: 0)
                                    : const ProgressTrack(value: 1, fromZero: true),
                              ),
                              const SizedBox(height: 12),
                              stagger(.45, Text(details, style: ranade(12, color: c.ink3))),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      stagger(
                        .5,
                        Padding(
                          padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              PillButton('Buy it', onTap: () => _finish(true)),
                              const SizedBox(height: 10),
                              GhostButton('Keep waiting', onTap: () => _finish(false)),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(30, 6, 30, 0),
                        child: Text(
                          'Either way, nothing else in your month moves.',
                          textAlign: TextAlign.center,
                          style: ranade(11.5, color: c.ink3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
