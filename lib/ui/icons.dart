import 'package:flutter/material.dart';

enum MullGlyph { money, wishlist, groups, lists, chevronRight, chevronLeft, close, check, more, plus, arrowUpRight }

/// The design's hand-drawn 24×24 stroke icons, painted directly (no SVG dependency).
class MullIcon extends StatelessWidget {
  const MullIcon(this.glyph, {super.key, this.size = 20, this.color, this.strokeWidth});

  final MullGlyph glyph;
  final double size;
  final Color? color;
  final double? strokeWidth;

  @override
  Widget build(BuildContext context) {
    final c = color ?? DefaultTextStyle.of(context).style.color ?? IconTheme.of(context).color!;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _GlyphPainter(glyph, c, strokeWidth)),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color, this.strokeWidth);

  final MullGlyph glyph;
  final Color color;
  final double? strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = strokeWidth ?? 1.6;
    final fill = Paint()..color = color;

    switch (glyph) {
      case MullGlyph.money:
        canvas.drawRRect(RRect.fromLTRBR(3, 6, 21, 19, const Radius.circular(4.5)), stroke);
        canvas.drawCircle(const Offset(16.5, 12.5), 1.3, fill);
      case MullGlyph.wishlist:
        canvas.drawLine(const Offset(5, 8), const Offset(19, 8), stroke);
        canvas.drawLine(const Offset(5, 12.5), const Offset(19, 12.5), stroke);
        canvas.drawLine(const Offset(5, 17), const Offset(14, 17), stroke);
      case MullGlyph.groups:
        canvas.drawCircle(const Offset(9.5, 10), 3.2, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(4, 18.5)
            ..cubicTo(4, 15.7, 6.4, 14.1, 9.5, 14.1)
            ..cubicTo(12.6, 14.1, 15, 15.7, 15, 18.5),
          stroke,
        );
        canvas.drawCircle(const Offset(17, 10.5), 2.3, stroke);
      case MullGlyph.lists:
        canvas.drawPath(
          Path()
            ..moveTo(7, 4)
            ..lineTo(17, 4)
            ..arcToPoint(const Offset(18.5, 5.5), radius: const Radius.circular(1.5))
            ..lineTo(18.5, 20)
            ..lineTo(12, 16.2)
            ..lineTo(5.5, 20)
            ..lineTo(5.5, 5.5)
            ..arcToPoint(const Offset(7, 4), radius: const Radius.circular(1.5))
            ..close(),
          stroke,
        );
      case MullGlyph.chevronRight:
        canvas.drawPath(
          Path()
            ..moveTo(9.5, 5.5)
            ..lineTo(16, 12)
            ..lineTo(9.5, 18.5),
          stroke,
        );
      case MullGlyph.chevronLeft:
        canvas.drawPath(
          Path()
            ..moveTo(14.5, 5.5)
            ..lineTo(8, 12)
            ..lineTo(14.5, 18.5),
          stroke,
        );
      case MullGlyph.close:
        canvas.drawLine(const Offset(6, 6), const Offset(18, 18), stroke);
        canvas.drawLine(const Offset(18, 6), const Offset(6, 18), stroke);
      case MullGlyph.check:
        canvas.drawPath(
          Path()
            ..moveTo(5, 12.5)
            ..lineTo(9.5, 17)
            ..lineTo(19, 7),
          stroke,
        );
      case MullGlyph.more:
        for (final y in [6.0, 12.0, 18.0]) {
          canvas.drawCircle(Offset(12, y), 1.5, fill);
        }
      case MullGlyph.plus:
        canvas.drawLine(const Offset(12, 5), const Offset(12, 19), stroke);
        canvas.drawLine(const Offset(5, 12), const Offset(19, 12), stroke);
      case MullGlyph.arrowUpRight:
        canvas.drawLine(const Offset(7, 17), const Offset(17, 7), stroke);
        canvas.drawPath(
          Path()
            ..moveTo(8.5, 7)
            ..lineTo(17, 7)
            ..lineTo(17, 15.5),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color || old.strokeWidth != strokeWidth;
}
