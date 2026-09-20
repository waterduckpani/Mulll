import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../data/notices.dart';
import '../data/store.dart';
import '../screens/friends_sheet.dart';
import '../screens/notices_sheet.dart';
import '../screens/profile_sheet.dart';
import 'tokens.dart';
import 'widgets.dart';
import '../screens/groups/group_detail_screen.dart';

/// Layout constants shared by every page.
///
/// Two gutters, deliberately different: text and titles sit at 30, cards and
/// buttons at 20, so a card visibly breaks outboard of the copy above it. The
/// offset is the whole look and is not worth "tidying up".
abstract final class Gutter {
  static const text = 30.0;
  static const card = 20.0;

  static const textPad = EdgeInsets.symmetric(horizontal: text);
  static const cardPad = EdgeInsets.symmetric(horizontal: card);
}

abstract final class ShellMetrics {
  /// Distance from the screen bottom to the pinned call-to-action.
  static double ctaBottom(BuildContext context) =>
      MediaQuery.paddingOf(context).bottom > 0 ? 30 : 22;
}

/// Standard page: a flat background with one glow, a top bar, scrolling
/// content, and a button block pinned above the home indicator.
class MullPage extends StatefulWidget {
  const MullPage({
    super.key,
    required this.children,
    this.glow = const GlowSpec(),
    this.bottom,
    this.footnote,
    this.header,
    this.onRefresh,
  });

  final List<Widget> children;
  final GlowSpec glow;

  /// Drag the page down to ask the server again.
  ///
  /// Mull refreshes itself — realtime, a poll behind it, and a pull on resume —
  /// so this is not how the screen stays current. It is here because someone
  /// looking at a number they believe is wrong will reach for it, and a page
  /// that does not answer that reach feels broken whatever it is doing
  /// underneath.
  final Future<void> Function()? onRefresh;

  /// The button block at the foot of the screen.
  final Widget? bottom;

  /// Centred quiet line sitting directly above [bottom].
  final String? footnote;

  /// Replaces the wordmark bar. Detail pages put a back button there instead.
  final Widget? header;

  @override
  State<MullPage> createState() => _MullPageState();
}

class _MullPageState extends State<MullPage> {
  final _scroll = ScrollController();
  double _bottomHeight = 0;
  bool _overflowing = false;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    final overflowing = n.metrics.pixels < n.metrics.maxScrollExtent - 4;
    if (overflowing != _overflowing) setState(() => _overflowing = overflowing);
    return false;
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Content can change height without anyone scrolling, so re-check each frame.
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
    // Subscribed to, not merely read: the unread dot has to appear the moment
    // a notice arrives, without anyone touching the screen.
    final inbox = context.notices;
    final isHome = widget.header == null;
    final top = MediaQuery.paddingOf(context).top;
    final headerTop = (top > 0 ? top : 20.0) + (isHome ? 18.0 : 14.0);
    final ctaBottom = ShellMetrics.ctaBottom(context);

    return Material(
      type: MaterialType.transparency,
      child: DefaultTextStyle(
        style: ranade(15, color: c.ink),
        child: Stack(
          children: [
            Positioned.fill(child: Backdrop(glow: widget.glow)),
            Positioned.fill(
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: CustomScrollView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                  slivers: [
                    // First, and it has to be: the control reads the scroll
                    // view's own overscroll, and anything above it absorbs the
                    // drag before it ever gets there. Its indicator carries the
                    // top inset itself so it lands under the bar rather than
                    // behind it.
                    if (widget.onRefresh != null)
                      CupertinoSliverRefreshControl(
                        refreshTriggerPullDistance: 120,
                        refreshIndicatorExtent: 74,
                        onRefresh: widget.onRefresh,
                        builder: (_, mode, pulled, trigger, extent) => _PullIndicator(
                          mode: mode,
                          pulled: pulled,
                          trigger: trigger,
                          topInset: headerTop,
                        ),
                      ),
                    SliverPadding(
                      padding: EdgeInsets.only(
                        top: headerTop + 44,
                        bottom: ctaBottom + _bottomHeight + 24,
                      ),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate(widget.children),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _TopFade(
                visible: _overflowing,
                top: headerTop,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    isHome ? 26.0 : Gutter.card,
                    headerTop,
                    isHome ? 26.0 : Gutter.card,
                    0,
                  ),
                  child: widget.header ??
                      BrandBar(
                        initial: store.profile.initial,
                        onProfile: () => showProfileSheet(context),
                        onFriends: () => showFriendsSheet(
                          context,
                          onOpenLedger: (id) => Navigator.of(context).push(
                            CupertinoPageRoute(
                              builder: (_) => GroupDetailScreen(groupId: id),
                            ),
                          ),
                        ),
                        onNotices: inbox == null ? null : () => showNoticesSheet(context),
                        unread: inbox?.unread ?? 0,
                      ),
                ),
              ),
            ),
            if (widget.bottom != null || widget.footnote != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                // A fade strip, then a solid block the content sits directly
                // on. One gradient behind the whole footer only reaches full
                // opacity a third of the way down, which is fine under a lone
                // button and useless under a footnote: the text sat in the
                // see-through part and collided with the list behind it.
                child: MeasureSize(
                  onChange: (s) {
                    if ((s.height - _bottomHeight).abs() > .5) {
                      setState(() => _bottomHeight = s.height);
                    }
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        key: const ValueKey('footerScrim'),
                        duration: const Duration(milliseconds: 240),
                        height: 44,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
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
                        padding: EdgeInsets.fromLTRB(Gutter.card, 0, Gutter.card, ctaBottom),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (widget.footnote != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 14, left: 10, right: 10),
                                child: Footnote(widget.footnote!),
                              ),
                            ?widget.bottom,
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
    );
  }
}

/// What a pull-to-refresh draws.
///
/// Not Cupertino's stock spinner: it is grey, it is always at full strength,
/// and it appears the instant you touch the screen. This fades up with the
/// drag, so a page that was not being pulled deliberately shows nothing at all,
/// and settles into a ring while the answer is on its way.
class _PullIndicator extends StatelessWidget {
  const _PullIndicator({
    required this.mode,
    required this.pulled,
    required this.trigger,
    required this.topInset,
  });

  final RefreshIndicatorMode mode;
  final double pulled;
  final double trigger;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final progress = (pulled / trigger).clamp(0.0, 1.0);
    final busy = mode == RefreshIndicatorMode.refresh || mode == RefreshIndicatorMode.armed;

    return Padding(
      padding: EdgeInsets.only(top: topInset + 10),
      child: Align(
        alignment: Alignment.topCenter,
        child: Opacity(
          opacity: busy ? 1 : progress,
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(
              strokeWidth: 1.8,
              color: c.ink2,
              // Before it fires, the ring is the drag itself drawn back at you.
              value: busy ? null : progress,
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps the top bar legible once content starts passing behind it.
///
/// A fade rather than a frosted bar with a rule under it: the design has no
/// borders anywhere, and a hairline appearing on scroll is the one place the
/// app would grow one.
class _TopFade extends StatelessWidget {
  const _TopFade({required this.visible, required this.top, required this.child});

  final bool visible;
  final double top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 240),
              opacity: visible ? 1 : 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [c.screen, c.screen, c.screen.withValues(alpha: 0)],
                    stops: const [0, .62, 1],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(padding: EdgeInsets.only(bottom: top * .35), child: child),
      ],
    );
  }
}

/// Large page title at the text gutter: "Ledger", "Recurring", "Goa trip".
class PageTitle extends StatelessWidget {
  const PageTitle(
    this.text, {
    super.key,
    this.subtitle,
    this.body,
    this.padding = const EdgeInsets.fromLTRB(Gutter.text, 26, Gutter.text, 0),
  });

  final String text;

  /// A short qualifier directly under the title: "4 people".
  final String? subtitle;

  /// A paragraph, where the screen needs to explain itself.
  final String? body;

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
            child: Text(text, style: MullType.screenTitle(c.ink)),
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(subtitle!, style: MullType.body(c.ink3)),
            ),
          if (body != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(body!, style: MullType.body(c.ink3)),
              ),
            ),
        ],
      ),
    );
  }
}

/// A statement rather than a label: "Two payments clear this group".
class PageStatement extends StatelessWidget {
  const PageStatement(
    this.text, {
    super.key,
    this.body,
    this.size = 38,
    this.padding = const EdgeInsets.fromLTRB(Gutter.text, 24, Gutter.text, 0),
  });

  final String text;
  final String? body;
  final double size;
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
            child: Text(text, style: MullType.statement(c.ink, size: size)),
          ),
          if (body != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 330),
                child: Text(body!, style: MullType.body(c.ink3)),
              ),
            ),
        ],
      ),
    );
  }
}

/// The hero number, left-aligned at the text gutter and never boxed.
class HeroAmount extends StatelessWidget {
  const HeroAmount({
    super.key,
    required this.caption,
    required this.amount,
    this.size = 76,
    this.placeholder,
    this.detail,
    this.padding = const EdgeInsets.fromLTRB(Gutter.text, 34, Gutter.text, 0),
  });

  final String caption;

  /// Null draws [placeholder] instead, for a ledger with nothing in it.
  final int? amount;
  final double size;
  final String? placeholder;
  final String? detail;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(caption, style: MullType.caption(c.ink3)),
          const SizedBox(height: 13),
          if (amount == null)
            Text(
              placeholder ?? '',
              style: excon(size * .6, tracking: -.03, height: 1, color: c.ink2),
            )
          else
            // The number is the page. It takes whatever width the phone has and
            // shrinks rather than wrapping: ₹1,24,600 must never break in two.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Semantics(
                header: true,
                child: AnimatedAmount(
                  amount!,
                  style: excon(size, tracking: -.05, height: .9, color: c.ink),
                ),
              ),
            ),
          if (detail != null) ...[
            const SizedBox(height: 14),
            Text(detail!, style: MullType.caption(c.ink3, size: 12.5)),
          ],
        ],
      ),
    );
  }
}

/// Back button on the left, an optional eyebrow or control on the right.
class DetailBar extends StatelessWidget {
  const DetailBar({
    super.key,
    this.label,
    this.onLabelTap,
    this.trailing,
    this.leading,
  });

  final String? label;
  final VoidCallback? onLabelTap;
  final Widget? trailing;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          leading ?? const BackButtonCircle(),
          const Spacer(),
          if (label != null)
            Pressable(
              onTap: onLabelTap,
              haptic: onLabelTap != null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
                child: Eyebrow(label!, size: 11.5, tracking: .16),
              ),
            ),
          ?trailing,
        ],
      ),
    );
  }
}
