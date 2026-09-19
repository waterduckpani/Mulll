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

// ------------------------------------------------------------------- surfaces

/// Any floating object. A fill and a shadow, never a border.
///
/// [lift] is the whole hierarchy: exactly one [Lift.focal] per screen,
/// [Lift.card] for the ordinary ones, [Lift.flat] for anything that should
/// sink back into the page.
class Surface extends StatelessWidget {
  const Surface({
    super.key,
    required this.child,
    this.lift = Lift.card,
    this.radius = 26,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
  });

  final Widget child;
  final Lift lift;
  final double radius;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) => Padding(
    padding: margin,
    child: DecoratedBox(
      decoration: surfaceOf(context.c, lift, radius: BorderRadius.circular(radius)),
      child: Padding(padding: padding, child: child),
    ),
  );
}

// -------------------------------------------------------------------- buttons

/// The one light-filled button at the foot of a screen.
class PillButton extends StatelessWidget {
  const PillButton(
    this.label, {
    super.key,
    this.onTap,
    this.busy = false,
    this.glyph,
    this.glyphTrailing = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool busy;

  /// Optional mark: the "+" on "Start a group", the "›" on "Next".
  final MullGlyph? glyph;

  /// Puts [glyph] after the label rather than before it. A plus belongs in
  /// front of what it adds; an arrow belongs after what it moves on from.
  final bool glyphTrailing;

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
          height: 58,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.pill,
            borderRadius: BorderRadius.circular(29),
            boxShadow: [
              BoxShadow(
                color: c.isDark ? const Color(0x99000000) : const Color(0x26131211),
                blurRadius: 35,
                offset: const Offset(0, 17),
              ),
            ],
          ),
          child: busy
              ? SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: c.pillInk),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (glyph != null && !glyphTrailing) ...[
                      MullIcon(glyph!, size: 17, color: c.pillInk, strokeWidth: 1.8),
                      const SizedBox(width: 9),
                    ],
                    Text(label, style: MullType.button(c.pillInk)),
                    if (glyph != null && glyphTrailing) ...[
                      const SizedBox(width: 9),
                      MullIcon(glyph!, size: 17, color: c.pillInk, strokeWidth: 1.8),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

/// Same geometry as [PillButton], but a floating card rather than the inverse
/// fill. Used where a screen offers a second thing to do.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton(this.label, {super.key, this.onTap, this.glyph});

  final String label;
  final VoidCallback? onTap;
  final MullGlyph? glyph;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .98,
      child: AnimatedOpacity(
        opacity: onTap == null ? .32 : 1,
        duration: const Duration(milliseconds: 200),
        child: Container(
          height: 58,
          alignment: Alignment.center,
          decoration: surfaceOf(c, Lift.card, radius: BorderRadius.circular(29)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (glyph != null) ...[
                MullIcon(glyph!, size: 17, color: c.ink, strokeWidth: 1.8),
                const SizedBox(width: 9),
              ],
              Text(label, style: MullType.button(c.ink)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The short capsule that sits inside a card: "Check", "Pay my share".
class InlineButton extends StatelessWidget {
  const InlineButton(
    this.label, {
    super.key,
    this.onTap,
    this.filled = true,
    this.height = 40,
    this.expand = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final double height;

  /// A 48px inset button stretched across a focal card, rather than a capsule
  /// hugging its own label.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final radius = BorderRadius.circular(height / 2);
    return Pressable(
      onTap: onTap,
      scale: .96,
      child: AnimatedOpacity(
        opacity: onTap == null ? .32 : 1,
        duration: const Duration(milliseconds: 200),
        child: Container(
          height: height,
          width: expand ? double.infinity : null,
          padding: expand ? null : const EdgeInsets.symmetric(horizontal: 22),
          alignment: Alignment.center,
          decoration: filled
              ? BoxDecoration(color: c.pill, borderRadius: radius)
              : surfaceOf(c, Lift.card, radius: radius),
          child: Text(
            label,
            style: MullType.button(filled ? c.pillInk : c.ink, size: height >= 48 ? 14.5 : 13.5),
          ),
        ),
      ),
    );
  }
}

/// 38px capsule in a row of suggestions.
class ChipButton extends StatelessWidget {
  const ChipButton(this.label, {super.key, this.onTap, this.selected = false});

  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .95,
      // No `alignment:` here. A Container with one set expands to fill loose
      // constraints, which inside a Wrap means every chip takes the whole row
      // and the row of suggestions becomes a stack of full-width buttons.
      child: AnimatedContainer(
        duration: motion(context, const Duration(milliseconds: 200)),
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 15),
        decoration: BoxDecoration(
          color: selected ? c.pill : c.quiet,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: ranade(13, color: selected ? c.pillInk : c.ink2)),
          ],
        ),
      ),
    );
  }
}

/// 44px circular icon button. Stays 44px even when the glyph inside is 18px.
class CircleButton extends StatelessWidget {
  const CircleButton({
    super.key,
    required this.child,
    this.onTap,
    this.semanticLabel,
    this.filled = true,
  });

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
        decoration: filled ? surfaceOf(c, Lift.low, radius: BorderRadius.circular(22)) : null,
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
    child: MullIcon(MullGlyph.chevronLeft, size: 17, color: context.c.ink, strokeWidth: 1.8),
  );
}

class CloseButtonCircle extends StatelessWidget {
  const CloseButtonCircle({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => CircleButton(
    semanticLabel: 'Close',
    onTap: onTap ?? () => Navigator.of(context).maybePop(),
    child: MullIcon(MullGlyph.close, size: 17, color: context.c.ink, strokeWidth: 1.8),
  );
}

// --------------------------------------------------------------------- labels

class Eyebrow extends StatelessWidget {
  const Eyebrow(
    this.text, {
    super.key,
    this.padding = EdgeInsets.zero,
    this.size = 11,
    this.tracking = .17,
    this.color,
  });

  final String text;
  final EdgeInsetsGeometry padding;
  final double size;
  final double tracking;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Text(
      text.toUpperCase(),
      style: eyebrow(color ?? context.c.ink3, size: size, tracking: tracking),
    ),
  );
}

/// Centred, quiet, sits directly above the primary button or at the base of a
/// list.
class Footnote extends StatelessWidget {
  const Footnote(this.text, {super.key, this.padding = EdgeInsets.zero});

  final String text;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: MullType.caption(context.c.ink3),
    ),
  );
}

/// Wordmark on the left, avatar on the right. The home screen's top bar.
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
            child: Text('mull', style: chillax(20, color: c.ink)),
          ),
          const Spacer(),
          Pressable(
            onTap: onProfile,
            scale: .92,
            semanticLabel: 'Profile and settings',
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: surfaceOf(c, Lift.low, radius: BorderRadius.circular(20)),
              child: Text(initial, style: ranade(14.5, color: c.ink2)),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------- numerals

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

/// A 1px divider at the list weight.
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.color});

  final Color? color;

  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: color ?? context.c.line);
}

// ---------------------------------------------------------------- backgrounds

/// One soft radial wash per screen, offset off a top corner.
class GlowSpec {
  const GlowSpec({this.size = 440, this.top = -150, this.left, this.right = -140});

  final double size;
  final double? top;
  final double? left;
  final double? right;
}

/// Flat background plus the screen's single glow.
class Backdrop extends StatelessWidget {
  const Backdrop({super.key, this.glow = const GlowSpec()});

  final GlowSpec glow;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return RepaintBoundary(
      child: ColoredBox(
        color: c.screen,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              top: glow.top,
              left: glow.left,
              right: glow.right,
              child: IgnorePointer(
                child: Container(
                  width: glow.size,
                  height: glow.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [c.glow, c.glow.withValues(alpha: 0)],
                      stops: const [0, .7],
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

/// A person being picked into a group.
///
/// Selected is the raised gradient with a filled check; unselected sinks flat
/// with an empty ring. No tick colour, no accent: only the lift changes.
class SelectionRow extends StatelessWidget {
  const SelectionRow({
    super.key,
    required this.label,
    required this.selected,
    this.detail,
    this.onTap,
  });

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .985,
      semanticLabel: '$label, ${selected ? 'selected' : 'not selected'}',
      child: AnimatedContainer(
        duration: motion(context, const Duration(milliseconds: 220)),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.fromLTRB(24, 20, 20, 20),
        decoration: surfaceOf(
          c,
          selected ? Lift.card : Lift.flat,
          radius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: ranade(16, color: selected ? c.ink : c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      detail!,
                      style: MullType.caption(c.ink3, size: 11.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            AnimatedContainer(
              duration: motion(context, const Duration(milliseconds: 220)),
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? c.ink : c.ink.withValues(alpha: .1),
              ),
              child: selected
                  ? MullIcon(MullGlyph.check, size: 13, color: c.screen, strokeWidth: 2.6)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Two equal segments with a sliding light thumb.
class Segmented extends StatelessWidget {
  const Segmented({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final d = motion(context, const Duration(milliseconds: 280));
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: c.quiet,
        borderRadius: BorderRadius.circular(22),
      ),
      child: SizedBox(
        height: 38,
        child: LayoutBuilder(
          builder: (context, box) {
            const gap = 4.0;
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
                    decoration: BoxDecoration(
                      color: c.pill,
                      borderRadius: BorderRadius.circular(19),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var i = 0; i < labels.length; i++) ...[
                      if (i > 0) const SizedBox(width: gap),
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
                                style: ranade(13, color: i == index ? c.pillInk : c.ink2),
                                child: Text(labels[i]),
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

/// 44 × 26 switch. On is the inverse fill.
class MullToggle extends StatelessWidget {
  const MullToggle({super.key, required this.value, required this.onChanged, this.semanticLabel});

  final bool value;
  final ValueChanged<bool> onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final d = motion(context, const Duration(milliseconds: 220));
    return Semantics(
      toggled: value,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onChanged(!value);
        },
        child: AnimatedContainer(
          duration: d,
          curve: Curves.easeOutCubic,
          width: 44,
          height: 26,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value ? c.pill : c.ink.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(13),
          ),
          child: AnimatedAlign(
            duration: d,
            curve: Curves.easeOutCubic,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: value ? c.pillInk : c.ink.withValues(alpha: .55),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------- chips

/// A name already in the group, with an optional way to take it out again.
class NameChip extends StatelessWidget {
  const NameChip(
    this.label, {
    super.key,
    this.selected = false,
    this.onTap,
    this.onRemove,
    this.detail,
  });

  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .95,
      child: AnimatedContainer(
        duration: motion(context, const Duration(milliseconds: 200)),
        height: 38,
        padding: EdgeInsets.only(left: 15, right: onRemove == null ? 15 : 2),
        decoration: BoxDecoration(
          color: selected ? c.pill : c.quiet,
          borderRadius: BorderRadius.circular(19),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: ranade(13, color: selected ? c.pillInk : c.ink2)),
            if (detail != null) ...[
              const SizedBox(width: 7),
              Text(detail!, style: excon(12.5, color: selected ? c.pillInk : c.ink3)),
            ],
            if (onRemove != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onRemove,
                child: SizedBox(
                  width: 32,
                  height: 38,
                  child: Center(
                    child: MullIcon(
                      MullGlyph.close,
                      size: 12,
                      color: selected ? c.pillInk : c.ink3,
                      strokeWidth: 1.9,
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

// --------------------------------------------------------------------- fields

/// Large input with no box: the value, a caret, and an underline below it.
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
    this.underline = true,
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
  final bool underline;

  /// Overrides the keyboard the field would otherwise pick from [numeric]. An
  /// email address wants its own, with the @ to hand.
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final style = excon(size, tracking: size > 40 ? -.04 : -.02, color: c.ink, height: 1.15);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.only(bottom: 16),
          decoration: underline
              ? BoxDecoration(border: Border(bottom: BorderSide(color: c.inputLine)))
              : null,
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
                  cursorHeight: size,
                  cursorRadius: Radius.zero,
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
            padding: const EdgeInsets.only(top: 12),
            child: DefaultTextStyle(
              style: MullType.caption(c.ink3),
              child: help!,
            ),
          ),
      ],
    );
  }
}

/// A labelled value with a chevron, stacked inside a sheet.
class FieldRow extends StatelessWidget {
  const FieldRow({
    super.key,
    required this.label,
    required this.value,
    this.onTap,
    this.trailing,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;

  /// Replaces the chevron: a toggle, say.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Pressable(
      onTap: onTap,
      scale: .99,
      semanticLabel: '$label, $value',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        decoration: BoxDecoration(
          color: c.quiet,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            // Both sides are tight, one part label to two parts value. A loose
            // value would shrink to its own text and strand the chevron in the
            // middle of the row; the design has it hard against the edge.
            Expanded(
              flex: 4,
              child: Text(
                label,
                style: ranade(14.5, color: c.ink2),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 5,
              child: Text(
                value,
                style: ranade(15, color: c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              trailing!,
            ] else if (onTap != null) ...[
              const SizedBox(width: 10),
              MullIcon(MullGlyph.chevronDown, size: 14, color: c.ink2, strokeWidth: 1.8),
            ],
          ],
        ),
      ),
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

/// Rows inside a card, separated by hairlines.
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

/// Cards in a stack sit 8px apart; related rows sit 2px apart so they read as
/// one block.
class Stacked extends StatelessWidget {
  const Stacked({super.key, required this.children, this.gap = 8, this.padding = EdgeInsets.zero});

  final List<Widget> children;
  final double gap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          children[i],
        ],
      ],
    ),
  );
}
