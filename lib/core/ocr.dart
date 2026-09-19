/// One recognised line of text, as the native side hands it over.
///
/// Coordinates are normalised 0–1 with (0,0) at the top-left, and [h] is the
/// line's height — our proxy for font size, which is what tells the amount on a
/// receipt apart from every other number on it.
class OcrLine {
  const OcrLine(this.text, {this.x = 0, this.y = 0, this.w = 1, this.h = .02, this.conf = 1});

  factory OcrLine.fromMap(Map<Object?, Object?> m) => OcrLine(
    m['text'] as String? ?? '',
    x: _d(m['x']),
    y: _d(m['y']),
    w: _d(m['w']),
    h: _d(m['h']),
    conf: _d(m['conf']),
  );

  final String text;
  final double x;
  final double y;
  final double w;
  final double h;
  final double conf;

  static double _d(Object? v) => (v as num?)?.toDouble() ?? 0;
}
