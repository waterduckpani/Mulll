import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../core/money.dart';
import 'icons.dart';
import 'tokens.dart';

/// Honour iOS "Reduce Motion".
Duration motion(BuildContext context, Duration d) =>
    MediaQuery.maybeDisableAnimationsOf(context) == true ? Duration.zero : d;

// ------------------------------------------------------------------ pressable

/// Tap target that gently compresses, with a selection haptic.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = .97,
    this.haptic = true,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final bool haptic;
  final String? semanticLabel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: () => _set(false),
        onTap: widget.onTap == null
            ? null
            : () {
                if (widget.haptic) HapticFeedback.selectionClick();
                widget.onTap!();
              },
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                _set(false);
                HapticFeedback.mediumImpact();
                widget.onLongPress!();
              },
        child: AnimatedScale(
          scale: _down ? widget.scale : 1,
          duration: motion(context, Duration(milliseconds: _down ? 90 : 220)),
          curve: _down ? Curves.easeOut : Curves.easeOutBack,
          child: AnimatedOpacity(
            opacity: _down ? .82 : 1,
            duration: motion(context, const Duration(milliseconds: 120)),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------- glass

class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 32,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
    this.blur = 0,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  /// Real backdrop blur is reserved for surfaces that float over moving content.
  final double blur;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final shape = BorderRadius.circular(radius);
    Widget box = DecoratedBox(
      decoration: BoxDecoration(
        color: c.glass,
        borderRadius: shape,
        border: Border.all(color: c.glassBorder),
        boxShadow: c.isDark ? null : const [BoxShadow(color: Color(0x0A000000), blurRadius: 28, offset: Offset(0, 10))],
      ),
      child: Padding(padding: padding, child: child),
    );
    if (blur > 0) {
      box = ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: box,
        ),
      );
    }
    return Padding(padding: margin, child: box);
  }
}

// -------------------------------------------------------------------- buttons

class PillButton extends StatelessWidget {
  const PillButton(this.label, {super.key, this.onTap, this.busy = false});

  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = onTap != null && !busy;
    return Pressable(
      onTap: enabled ? onTap : null,
      scale: .98,
      child: AnimatedOpacity(
        opacity: enabled || busy ? 1 : .32,
        duration: const Duration(milliseconds: 200),
        child: Container(
          height: 60,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.pill, borderRadius: BorderRadius.circular(30)),
          child: busy
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: c.pillInk),
                )
              : Text(label, style: ranade(15.5, color: c.pillInk)),
        ),
      ),
    );
  }
}

class GhostButton extends StatelessWidget {
  const GhostButton(this.label, {super.key, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .98,
      child: Container(
        height: 56,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: c.line),
        ),
        child: Text(label, style: ranade(15, color: c.ink2)),
      ),
    );
  }
}

/// Small glass capsule — "Adjust budget".
class ChipButton extends StatelessWidget {
  const ChipButton(this.label, {super.key, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.glass,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.glassBorder),
        ),
        child: Text(label, style: ranade(13, color: c.ink)),
      ),
    );
  }
}

class CircleButton extends StatelessWidget {
  const CircleButton({super.key, required this.child, this.onTap, this.semanticLabel, this.filled = true});

  final Widget child;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .92,
      semanticLabel: semanticLabel,
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: filled
            ? BoxDecoration(
                color: c.glass,
                shape: BoxShape.circle,
                border: Border.all(color: c.glassBorder),
              )
            : null,
        child: child,
      ),
    );
  }
}

class BackButtonCircle extends StatelessWidget {
  const BackButtonCircle({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => CircleButton(
    semanticLabel: 'Back',
    onTap: onTap ?? () => Navigator.of(context).maybePop(),
    child: MullIcon(MullGlyph.chevronLeft, color: context.c.ink, strokeWidth: 1.7),
  );
}

// --------------------------------------------------------------------- labels

class Eyebrow extends StatelessWidget {
  const Eyebrow(this.text, {super.key, this.padding = EdgeInsets.zero, this.size = 11, this.tracking = .16});

  final String text;
  final EdgeInsetsGeometry padding;
  final double size;
  final double tracking;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Text(
      text.toUpperCase(),
      style: eyebrow(context.c.ink3, size: size, tracking: tracking),
    ),
  );
}

/// Wordmark + profile — present on every tab.
class BrandBar extends StatelessWidget {
  const BrandBar({super.key, required this.initial, this.onProfile});

  final String initial;
  final VoidCallback? onProfile;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Semantics(
            header: true,
            label: 'Mull',
            child: Text(
              'mull',
              style: TextStyle(
                fontFamily: 'Chillax',
                fontSize: 20,
                fontWeight: FontWeight.w600,
                letterSpacing: -.1,
                height: 1,
                color: c.ink,
              ),
            ),
          ),
          const Spacer(),
          CircleButton(
            onTap: onProfile,
            semanticLabel: 'Profile and settings',
            child: Text(initial, style: excon(15, color: c.ink)),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ reach & progress

/// "BUDGET STOPS HERE" — the dashed reach line.
class ReachLine extends StatelessWidget {
  const ReachLine(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    Widget dash() => Expanded(
      child: CustomPaint(size: const Size.fromHeight(1), painter: _DashPainter(c.line)),
    );
    return Semantics(
      label: label,
      child: Row(
        children: [
          dash(),
          const SizedBox(width: 10),
          Text(label.toUpperCase(), style: eyebrow(c.ink3, size: 9, tracking: .18)),
          const SizedBox(width: 10),
          dash(),
        ],
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 6) {
      canvas.drawLine(Offset(x, .5), Offset((x + 3).clamp(0, size.width), .5), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}

/// Thin track with an animated fill.
class ProgressTrack extends StatelessWidget {
  const ProgressTrack({
    super.key,
    required this.value,
    this.height = 4,
    this.delay = Duration.zero,
    this.fromZero = false,
  });

  final double value;
  final double height;
  final Duration delay;
  final bool fromZero;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final v = value.isNaN ? 0.0 : value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: Container(
        height: height,
        color: c.line,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: fromZero ? 0 : v, end: v),
          duration: motion(context, fromZero ? const Duration(milliseconds: 1100) : const Duration(milliseconds: 550)),
          curve: Curves.easeOutCubic,
          builder: (context, t, _) => FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: t,
            child: DecoratedBox(
              decoration: BoxDecoration(color: c.ink, borderRadius: BorderRadius.circular(height / 2)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Number that rolls to its new value.
class AnimatedAmount extends StatelessWidget {
  const AnimatedAmount(this.value, {super.key, required this.style, this.fromZero = false});

  final int value;
  final TextStyle style;
  final bool fromZero;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: fromZero ? 0 : value.toDouble(), end: value.toDouble()),
      duration: motion(context, const Duration(milliseconds: 700)),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) => Text(
        inr(v.round()),
        style: style,
        maxLines: 1,
        semanticsLabel: inr(value),
      ),
    );
  }
}

/// A row divider matching `border-bottom: 1px solid var(--line)`.
class Hairline extends StatelessWidget {
  const Hairline({super.key});

  @override
  Widget build(BuildContext context) => Container(height: 1, color: context.c.line);
}

// ---------------------------------------------------------------- backgrounds

class BlobSpec {
  const BlobSpec(this.size, this.blur, {this.top, this.left, this.right, this.bottom});
  final double size;
  final double blur;
  final double? top, left, right, bottom;
}

/// Soft blurred circles that give the glass something to sit on.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.blobs});

  final List<BlobSpec> blobs;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return RepaintBoundary(
      child: ColoredBox(
        color: c.screen,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            for (final b in blobs)
              Positioned(
                top: b.top == null ? null : b.top! - b.blur * 1.5,
                left: b.left == null ? null : b.left! - b.blur * 1.5,
                right: b.right == null ? null : b.right! - b.blur * 1.5,
                bottom: b.bottom == null ? null : b.bottom! - b.blur * 1.5,
                child: IgnorePointer(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: b.blur / 2, sigmaY: b.blur / 2, tileMode: TileMode.decal),
                    child: Padding(
                      padding: EdgeInsets.all(b.blur * 1.5),
                      child: Container(
                        width: b.size,
                        height: b.size,
                        decoration: BoxDecoration(color: c.blob, shape: BoxShape.circle),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- selection

/// Two big tiles — Need / Want, Declared / Settled.
class ChoicePair<T> extends StatelessWidget {
  const ChoicePair({super.key, required this.options, required this.value, required this.onChanged, this.height = 64});

  final List<(T, String)> options;
  final T? value;
  final ValueChanged<T> onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(
            child: Pressable(
              onTap: () => onChanged(options[i].$1),
              scale: .96,
              semanticLabel: options[i].$2,
              child: AnimatedContainer(
                duration: motion(context, const Duration(milliseconds: 220)),
                curve: Curves.easeOutCubic,
                height: height,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: value == options[i].$1 ? c.pill : c.pill.withValues(alpha: 0),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: value == options[i].$1 ? c.pill : c.line),
                ),
                child: AnimatedDefaultTextStyle(
                  duration: motion(context, const Duration(milliseconds: 220)),
                  style: ranade(16, color: value == options[i].$1 ? c.pillInk : c.ink2),
                  child: Text(options[i].$2),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Glass segmented control with a sliding pill ("Needs 4 | Wants 7").
class Segmented extends StatelessWidget {
  const Segmented({super.key, required this.labels, required this.index, required this.onChanged, this.counts});

  final List<String> labels;
  final List<int>? counts;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final d = motion(context, const Duration(milliseconds: 280));
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: c.glass,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: c.glassBorder),
      ),
      child: SizedBox(
        height: 44,
        child: LayoutBuilder(
          builder: (context, box) {
            final gap = 4.0;
            final w = (box.maxWidth - gap * (labels.length - 1)) / labels.length;
            return Stack(
              children: [
                AnimatedPositioned(
                  duration: d,
                  curve: Curves.easeOutCubic,
                  left: index * (w + gap),
                  top: 0,
                  bottom: 0,
                  width: w,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: c.pill, borderRadius: BorderRadius.circular(22)),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < labels.length; i++) ...[
                      if (i > 0) SizedBox(width: gap),
                      SizedBox(
                        width: w,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (i == index) return;
                            HapticFeedback.selectionClick();
                            onChanged(i);
                          },
                          child: Semantics(
                            selected: i == index,
                            button: true,
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: d,
                                style: ranade(14.5, color: i == index ? c.pillInk : c.ink3),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(labels[i]),
                                    if (counts != null) ...[
                                      const SizedBox(width: 7),
                                      Text('${counts![i]}', style: excon(14.5, color: i == index ? c.pillInk : c.ink3)),
                                    ],
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
    );
  }
}

// --------------------------------------------------------------------- fields

/// Large underlined input (name / amount) from the quick-add sheet.
class BigField extends StatelessWidget {
  const BigField({
    super.key,
    required this.controller,
    this.focusNode,
    this.hint,
    this.trailing,
    this.help,
    this.size = 30,
    this.numeric = false,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
    this.capitalization = TextCapitalization.sentences,
    this.keyboardType,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;
  final String? hint;
  final Widget? trailing;
  final Widget? help;
  final double size;
  final bool numeric;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;
  final TextCapitalization capitalization;

  /// Overrides the keyboard the field would otherwise pick from [numeric] —
  /// an email address wants its own, with the @ to hand.
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final style = excon(size, tracking: size > 40 ? -.04 : -.02, color: c.ink, height: 1.15);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.line)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: autofocus,
                  style: style,
                  cursorColor: c.ink,
                  cursorWidth: 2,
                  cursorHeight: size * .9,
                  cursorOpacityAnimates: true,
                  keyboardAppearance: c.isDark ? Brightness.dark : Brightness.light,
                  textCapitalization: numeric ? TextCapitalization.none : capitalization,
                  keyboardType:
                      keyboardType ??
                      (numeric
                          ? const TextInputType.numberWithOptions(signed: true, decimal: true)
                          : TextInputType.text),
                  autocorrect: !numeric && keyboardType == null,
                  textInputAction: textInputAction,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  decoration: InputDecoration.collapsed(
                    hintText: hint,
                    hintStyle: style.copyWith(color: c.ink3.withValues(alpha: .55)),
                  ),
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            ],
          ),
        ),
        if (help != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: DefaultTextStyle(
              style: ranade(12, height: 1.55, color: c.ink3),
              child: help!,
            ),
          ),
      ],
    );
  }
}

/// Keeps an amount field forgiving while typing and tidy afterwards.
class AmountController extends TextEditingController {
  AmountController([int? initial]) : super(text: initial == null ? '' : inr(initial));

  int? get amount => parseAmount(text);

  void tidy() {
    final a = amount;
    if (a != null && text != inr(a)) {
      value = TextEditingValue(
        text: inr(a),
        selection: TextSelection.collapsed(offset: inr(a).length),
      );
    }
  }
}

// --------------------------------------------------------------------- layout

/// Reports its child's size after layout.
class MeasureSize extends SingleChildRenderObjectWidget {
  const MeasureSize({super.key, required this.onChange, required Widget super.child});

  final ValueChanged<Size> onChange;

  @override
  RenderObject createRenderObject(BuildContext context) => _MeasureRender(onChange);

  @override
  void updateRenderObject(BuildContext context, covariant RenderObject renderObject) =>
      (renderObject as _MeasureRender).onChange = onChange;
}

class _MeasureRender extends RenderProxyBox {
  _MeasureRender(this.onChange);
  ValueChanged<Size> onChange;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    if (size != _last) {
      _last = size;
      final s = size;
      WidgetsBinding.instance.addPostFrameCallback((_) => onChange(s));
    }
  }
}

/// Rows inside a glass list card, separated by hairlines.
class CardRows extends StatelessWidget {
  const CardRows({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Hairline(),
          children[i],
        ],
      ],
    );
  }
}

/// Friendly empty state inside a glass card.
class EmptyCard extends StatelessWidget {
  const EmptyCard({
    super.key,
    required this.title,
    required this.body,
    this.margin = const EdgeInsets.fromLTRB(22, 14, 22, 0),
  });

  final String title;
  final String body;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Glass(
      margin: margin,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: excon(22, tracking: -.02, color: c.ink, height: 1.25)),
          const SizedBox(height: 10),
          Text(body, style: ranade(13, height: 1.6, color: c.ink3)),
        ],
      ),
    );
  }
}
