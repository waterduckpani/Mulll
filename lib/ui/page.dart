import 'dart:ui';

import 'package:flutter/material.dart';

import '../data/store.dart';
import '../screens/profile_sheet.dart';
import 'tokens.dart';
import 'widgets.dart';

/// Layout constants shared by every page.
///
/// There is no tab bar any more — Mull is one thing, so the groups list is the
/// app rather than a tab of it, and the call-to-action sits straight above the
/// home indicator.
class ShellMetrics {
  /// Distance from the screen bottom to the pinned call-to-action.
  static double ctaBottom(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom > 0 ? 28 : 20;
}

/// Standard page: backdrop blobs, a brand bar that frosts on scroll, scrolling
/// content, and a pinned call-to-action at the bottom.
class MullPage extends StatefulWidget {
  const MullPage({
    super.key,
    required this.blobs,
    required this.children,
    this.bottom,
    this.header,
  });

  final List<BlobSpec> blobs;
  final List<Widget> children;
  final Widget? bottom;

  /// Replaces the wordmark bar — detail pages put a back button there instead.
  final Widget? header;

  @override
  State<MullPage> createState() => _MullPageState();
}

class _MullPageState extends State<MullPage> {
  final _scroll = ScrollController();
  double _bottomHeight = 0;
  bool _scrolled = false;
  bool _overflowing = false;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    final scrolled = n.metrics.pixels > 6;
    final overflowing = n.metrics.pixels < n.metrics.maxScrollExtent - 4;
    if (scrolled != _scrolled || overflowing != _overflowing) {
      setState(() {
        _scrolled = scrolled;
        _overflowing = overflowing;
      });
    }
    return false;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Content can change height without scrolling, so re-check after each layout.
  void _checkOverflow() {
    if (!mounted || !_scroll.hasClients) return;
    final p = _scroll.position;
    final overflowing = p.pixels < p.maxScrollExtent - 4;
    if (overflowing != _overflowing) setState(() => _overflowing = overflowing);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOverflow());
    final c = context.c;
    final store = context.store;
    final top = MediaQuery.paddingOf(context).top;
    final headerTop = top > 0 ? top - 6 : 20.0;
    final ctaBottom = ShellMetrics.ctaBottom(context);

    return Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle(
        style: ranade(15, color: c.ink),
        child: Stack(
          children: [
            Positioned.fill(child: Backdrop(blobs: widget.blobs)),
            Positioned.fill(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: ListView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  padding: EdgeInsets.only(
                    top: headerTop + 44,
                    bottom: ctaBottom + _bottomHeight + 20,
                  ),
                  children: widget.children,
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _FrostedHeader(
                visible: _scrolled,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(22, headerTop, 22, 0),
                  child: widget.header ??
                      BrandBar(
                        initial: store.profile.initial,
                        onProfile: () => showProfileSheet(context),
                      ),
                ),
              ),
            ),
            if (widget.bottom != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                // A fade strip, then a solid block the content sits directly on.
                //
                // This used to be one gradient behind the whole footer, which
                // only reached full opacity a third of the way down: fine under
                // a lone button, but any text in `bottom` sat in the
                // see-through part and collided with the list behind it.
                child: MeasureSize(
                  onChange: (s) {
                    if ((s.height - _bottomHeight).abs() > .5) setState(() => _bottomHeight = s.height);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        key: const ValueKey('footerScrim'),
                        duration: const Duration(milliseconds: 240),
                        // Tall enough to hide a row of body text as it passes
                        // under the button. With the tab bar gone the solid
                        // band starts much lower down the screen, so a short
                        // fade left a half-legible line sliced by the CTA.
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            // Fully opaque, not almost: at 98% the rows behind
                            // still ghost through as readable text along the
                            // bottom edge.
                            colors: [
                              c.screen.withValues(alpha: 0),
                              _overflowing ? c.screen : c.screen.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 240),
                        color: _overflowing ? c.screen : c.screen.withValues(alpha: 0),
                        padding: EdgeInsets.only(bottom: ctaBottom),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 22),
                          child: widget.bottom!,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FrostedHeader extends StatelessWidget {
  const _FrostedHeader({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return ClipRect(
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: visible ? 1 : 0),
        duration: const Duration(milliseconds: 220),
        builder: (context, t, child) => BackdropFilter(
          enabled: t > 0,
          filter: ImageFilter.blur(sigmaX: 20 * t, sigmaY: 20 * t),
          child: Container(
            padding: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              color: c.screen.withValues(alpha: .72 * t),
              border: Border(
                bottom: BorderSide(
                  color: c.line.withValues(alpha: c.line.a * t),
                ),
              ),
            ),
            child: child,
          ),
        ),
        child: child,
      ),
    );
  }
}

/// Large page title — "September", "Wishlist".
class PageTitle extends StatelessWidget {
  const PageTitle(
    this.text, {
    super.key,
    this.subtitle,
    this.padding = const EdgeInsets.fromLTRB(24, 14, 24, 0),
  });

  final String text;
  final String? subtitle;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              text,
              style: excon(30, tracking: -.02, color: c.ink, height: 1.2),
            ),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 290),
                child: Text(
                  subtitle!,
                  style: ranade(12.5, height: 1.6, color: c.ink3),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Back button + right-aligned eyebrow. Goes in [MullPage.header], so it
/// carries no padding of its own.
class DetailBar extends StatelessWidget {
  const DetailBar({
    super.key,
    required this.label,
    this.onLabelTap,
    this.trailing,
  });

  final String label;
  final VoidCallback? onLabelTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const BackButtonCircle(),
          const Spacer(),
          Pressable(
            onTap: onLabelTap,
            haptic: onLabelTap != null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
              child: Eyebrow(label, size: 12, tracking: .14),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 4), trailing!],
        ],
      ),
    );
  }
}
