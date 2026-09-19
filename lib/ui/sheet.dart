import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/cupertino.dart' show CupertinoDatePicker, CupertinoDatePickerMode, CupertinoTheme, CupertinoThemeData, CupertinoTextThemeData;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'icons.dart';
import 'tokens.dart';
import 'widgets.dart';

/// Sheet corners: 44 at the top, 54 at the bottom so they meet the screen's
/// own radius rather than cutting across it.
const _sheetShape = BorderRadius.only(
  topLeft: Radius.circular(44),
  topRight: Radius.circular(44),
  bottomLeft: Radius.circular(54),
  bottomRight: Radius.circular(54),
);

/// Tracks how "deep" into sheets we are so the shell can recede behind them.
class SheetDepth {
  static final ValueNotifier<double> value = ValueNotifier(0);
  static final Set<Animation<double>> _animations = {};

  static void _attach(Animation<double> a) {
    _animations.add(a);
    a.addListener(_update);
    _update();
  }

  static void _detach(Animation<double> a) {
    a.removeListener(_update);
    _animations.remove(a);
    _update();
  }

  static void _update() {
    value.value = _animations.fold(0.0, (m, a) => max(m, a.value));
  }
}

/// Bottom sheet: blurred scrim, drag to dismiss, and the shell receding behind it.
Future<T?> showMullSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  double height = 604,
  bool fitContent = false,
}) {
  HapticFeedback.lightImpact();
  return Navigator.of(context, rootNavigator: true).push<T>(
    _SheetRoute<T>(builder: builder, designHeight: height, fitContent: fitContent),
  );
}

class _SheetRoute<T> extends PopupRoute<T> {
  _SheetRoute({required this.builder, required this.designHeight, required this.fitContent});

  final WidgetBuilder builder;
  final double designHeight;
  final bool fitContent;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 460);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  void install() {
    super.install();
    SheetDepth._attach(animation!);
  }

  @override
  void dispose() {
    SheetDepth._detach(animation!);
    super.dispose();
  }

  AnimationController get sheetController => controller!;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    return _SheetFrame(route: this);
  }
}

class _SheetFrame extends StatefulWidget {
  const _SheetFrame({required this.route});

  final _SheetRoute route;

  @override
  State<_SheetFrame> createState() => _SheetFrameState();
}

class _SheetFrameState extends State<_SheetFrame> {
  double _sheetHeight = 1;
  bool _dragging = false;

  AnimationController get _ctrl => widget.route.sheetController;

  void _dragUpdate(DragUpdateDetails d) {
    _dragging = true;
    _ctrl.value = (_ctrl.value - d.primaryDelta! / _sheetHeight).clamp(0.0, 1.0);
  }

  void _dragEnd(DragEndDetails d) {
    _dragging = false;
    final v = d.primaryVelocity ?? 0;
    if (v > 700 || (_ctrl.value < .7 && v >= 0)) {
      Navigator.of(context).pop();
    } else {
      _ctrl.animateTo(1, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final mq = MediaQuery.of(context);
    final keyboard = mq.viewInsets.bottom;
    final available = mq.size.height - keyboard - mq.padding.top - 12;
    final height = min(widget.route.designHeight, available);
    final route = widget.route;

    return AnimatedBuilder(
      animation: route.animation!,
      builder: (context, child) {
        final raw = route.animation!.value;
        final forward = route.animation!.status != AnimationStatus.reverse;
        final t = _dragging ? raw : (forward ? Curves.easeOutQuart : Curves.easeInCubic).transform(raw);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: Opacity(
                  opacity: raw.clamp(0.0, 1.0),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                    child: ColoredBox(color: c.scrim),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: keyboard,
              child: FractionalTranslation(
                translation: Offset(0, 1 - t),
                child: child,
              ),
            ),
          ],
        );
      },
      child: GestureDetector(
        onVerticalDragUpdate: _dragUpdate,
        onVerticalDragEnd: _dragEnd,
        child: MeasureSize(
          onChange: (s) => _sheetHeight = max(1, s.height),
          child: DecoratedBox(
            // Lifting up off the scrim is the only thing separating the sheet
            // from what is behind it: the design has no borders to draw.
            decoration: const BoxDecoration(
              borderRadius: _sheetShape,
              boxShadow: [BoxShadow(color: Color(0xB3000000), blurRadius: 70, offset: Offset(0, -30))],
            ),
            child: ClipRRect(
              borderRadius: _sheetShape,
              child: Container(
                height: route.fitContent ? null : height,
                constraints: BoxConstraints(maxHeight: available),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: const Alignment(-.07, -1),
                    end: const Alignment(.07, 1),
                    colors: [c.sheetTop, c.sheetBottom],
                  ),
                ),
                child: MediaQuery.removeViewInsets(
                  context: context,
                  removeBottom: true,
                  child: Material(
                    type: MaterialType.transparency,
                    child: DefaultTextStyle(
                      style: ranade(15, color: c.ink),
                      child: SafeArea(
                        top: false,
                        bottom: keyboard == 0,
                        minimum: EdgeInsets.only(bottom: keyboard == 0 ? 0 : 12),
                        child: Column(
                          mainAxisSize: route.fitContent ? MainAxisSize.min : MainAxisSize.max,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Center(
                                child: Container(
                                  width: 40,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: c.ink.withValues(alpha: .2),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                            if (route.fitContent)
                              Flexible(child: _SheetInk(builder: route.builder))
                            else
                              Expanded(child: _SheetInk(builder: route.builder)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Re-themes everything inside a sheet: the faintest ink lightens and the
/// hairlines get heavier, because the surface under them is lighter than the
/// screen. Doing it here means no sheet has to remember.
class _SheetInk extends StatelessWidget {
  const _SheetInk({required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final inside = context.c.insideSheet;
    return Theme(
      data: Theme.of(context).copyWith(extensions: [inside]),
      child: Builder(builder: builder),
    );
  }
}

/// Standard sheet header: eyebrow on the left, close on the right.
class SheetHeader extends StatelessWidget {
  const SheetHeader(this.title, {super.key, this.showClose = true});

  final String title;
  final bool showClose;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 16, 20, 0),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Expanded(child: Eyebrow(title, size: 10.5, tracking: .18)),
            if (showClose)
              CircleButton(
                filled: false,
                semanticLabel: 'Close',
                onTap: () => Navigator.of(context).maybePop(),
                child: MullIcon(MullGlyph.close, size: 17, color: c.ink2, strokeWidth: 1.8),
              ),
          ],
        ),
      ),
    );
  }
}

/// A tappable row inside an action sheet.
class SheetAction extends StatelessWidget {
  const SheetAction(this.label, {super.key, required this.onTap, this.detail, this.destructive = false, this.trailing});

  final String label;
  final String? detail;
  final VoidCallback onTap;
  final bool destructive;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .985,
      child: SizedBox(
        height: 58,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: ranade(
                  16,
                  color: destructive ? c.ink3 : c.ink,
                  weight: destructive ? FontWeight.w300 : FontWeight.w400,
                ),
              ),
            ),
            if (detail != null) Text(detail!, style: ranade(13.5, color: c.ink3)),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------- toast

/// Glass capsule that floats above the tab bar, with optional undo.
class Toast {
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(BuildContext context, String message, {String? action, VoidCallback? onAction}) {
    hide();
    final overlay = Overlay.of(context, rootOverlay: true);
    final key = GlobalKey<_ToastViewState>();
    _entry = OverlayEntry(
      builder: (_) => _ToastView(
        key: key,
        message: message,
        action: action,
        onAction: () {
          onAction?.call();
          hide();
        },
      ),
    );
    overlay.insert(_entry!);
    _timer = Timer(const Duration(milliseconds: 3800), () async {
      await key.currentState?.dismiss();
      hide();
    });
  }

  static void hide() {
    _timer?.cancel();
    _entry?.remove();
    _entry = null;
  }
}

// --------------------------------------------------------------------- notice

/// Something somebody else did, arriving while you are looking at the screen.
///
/// Drops from the top rather than rising from the bottom, and that is the whole
/// distinction: the bottom of the screen is where Mull confirms what *you* just
/// did, and the top is where the world arrives. Sharing one shape for both
/// would make another person's expense look like your own action succeeding.
class NoticeBanner {
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(
    BuildContext context,
    String title, {
    String body = '',
    VoidCallback? onTap,
  }) {
    hide();
    final overlay = Overlay.of(context, rootOverlay: true);
    final key = GlobalKey<_NoticeViewState>();
    _entry = OverlayEntry(
      builder: (_) => _NoticeView(
        key: key,
        title: title,
        body: body,
        onTap: onTap == null
            ? null
            : () {
                hide();
                onTap();
              },
        onDismiss: hide,
      ),
    );
    overlay.insert(_entry!);
    _timer = Timer(const Duration(milliseconds: 5200), () async {
      await key.currentState?.dismiss();
      hide();
    });
  }

  static void hide() {
    _timer?.cancel();
    _entry?.remove();
    _entry = null;
  }
}

class _NoticeView extends StatefulWidget {
  const _NoticeView({
    super.key,
    required this.title,
    required this.body,
    this.onTap,
    required this.onDismiss,
  });

  final String title;
  final String body;
  final VoidCallback? onTap;
  final VoidCallback onDismiss;

  @override
  State<_NoticeView> createState() => _NoticeViewState();
}

class _NoticeViewState extends State<_NoticeView> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 420))..forward();

  Future<void> dismiss() => _c.reverse();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final topSafe = MediaQuery.paddingOf(context).top;
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);

    return Positioned(
      left: 16,
      right: 16,
      top: (topSafe > 0 ? topSafe : 18) + 6,
      child: FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, -.5), end: Offset.zero).animate(curve),
          child: Material(
            type: MaterialType.transparency,
            child: GestureDetector(
              // Flick it away. A notification you cannot get rid of is worse
              // than one you did not get.
              onVerticalDragEnd: (d) {
                if ((d.primaryVelocity ?? 0) < -200) widget.onDismiss();
              },
              child: Pressable(
                onTap: widget.onTap,
                scale: .98,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(26),
                    boxShadow: [
                      BoxShadow(color: c.shadowFocal, blurRadius: 44, offset: const Offset(0, 14)),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(20, 15, 18, 16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26),
                        gradient: LinearGradient(
                          begin: const Alignment(-.07, -1),
                          end: const Alignment(.07, 1),
                          colors: [c.sheetTop, c.sheetBottom],
                        ),
                      ),
                      child: Row(
                        children: [
                          MullIcon(MullGlyph.bell, size: 16, color: c.ink2, strokeWidth: 1.7),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: ranade(14.5, height: 1.3, color: c.ink),
                                ),
                                if (widget.body.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    widget.body,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: ranade(11.5, height: 1.4, color: c.ink3),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (widget.onTap != null) ...[
                            const SizedBox(width: 10),
                            MullIcon(MullGlyph.chevronRight, size: 13, color: c.ink3, strokeWidth: 1.8),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastView extends StatefulWidget {
  const _ToastView({super.key, required this.message, this.action, required this.onAction});

  final String message;
  final String? action;
  final VoidCallback onAction;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 380))
    ..forward();

  Future<void> dismiss() => _c.reverse();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final bottomSafe = MediaQuery.paddingOf(context).bottom;
    final curve = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return Positioned(
      left: 22,
      right: 22,
      bottom: (bottomSafe > 0 ? 28 : 20) + 12,
      child: FadeTransition(
        opacity: curve,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, .4), end: Offset.zero).animate(curve),
          child: Material(
            type: MaterialType.transparency,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  boxShadow: [
                    BoxShadow(color: c.shadowCard, blurRadius: 40, offset: const Offset(0, 16)),
                  ],
                ),
                child: Container(
                  height: 56,
                  padding: const EdgeInsets.only(left: 22, right: 8),
                  decoration: BoxDecoration(
                    color: c.pill,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.message,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ranade(14, color: c.pillInk),
                        ),
                      ),
                      if (widget.action != null)
                        Pressable(
                          onTap: widget.onAction,
                          child: Container(
                            height: 44,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            alignment: Alignment.center,
                            child: Text(
                              widget.action!,
                              style: ranade(14, weight: FontWeight.w500, color: c.pillInk),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------- date picker

/// A date, picked in a Mull-shaped sheet.
///
/// Cupertino's wheel rather than a calendar grid: every date Mull asks for is
/// near today — when an expense happened, when rent starts — and a wheel gets
/// to "three days ago" in one flick.
Future<DateTime?> showMullDatePicker(
  BuildContext context, {
  required DateTime initial,
  required DateTime first,
  required DateTime last,
  String title = 'Pick a date',
}) {
  var chosen = DateTime(initial.year, initial.month, initial.day);
  return showMullSheet<DateTime>(
    context,
    fitContent: true,
    builder: (sheet) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(title),
          SizedBox(
            height: 216,
            child: CupertinoTheme(
              data: CupertinoThemeData(
                brightness: sheet.c.isDark ? Brightness.dark : Brightness.light,
                textTheme: CupertinoTextThemeData(
                  dateTimePickerTextStyle: excon(20, color: sheet.c.ink),
                ),
              ),
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: chosen,
                minimumDate: DateTime(first.year, first.month, first.day),
                maximumDate: DateTime(last.year, last.month, last.day),
                onDateTimeChanged: (d) => chosen = DateTime(d.year, d.month, d.day),
              ),
            ),
          ),
          const SizedBox(height: 18),
          PillButton('Use this date', onTap: () => Navigator.of(sheet).pop(chosen)),
        ],
      ),
    ),
  );
}
