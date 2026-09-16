import 'package:flutter/material.dart';

/// Colour tokens lifted 1:1 from the design file (`--ink`, `--glass`, …).
/// Affordability is expressed through weight, opacity and the reach line —
/// never through colour — so this palette is intentionally monochrome.
@immutable
class MullColors extends ThemeExtension<MullColors> {
  const MullColors({
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.glass,
    required this.glassBorder,
    required this.line,
    required this.screen,
    required this.pill,
    required this.pillInk,
    required this.blob,
    required this.scrim,
    required this.isDark,
  });

  final Color ink;
  final Color ink2;
  final Color ink3;
  final Color glass;
  final Color glassBorder;
  final Color line;
  final Color screen;
  final Color pill;
  final Color pillInk;
  final Color blob;
  final Color scrim;
  final bool isDark;

  static const light = MullColors(
    ink: Color(0xFF131211),
    ink2: Color(0xFF565450),
    ink3: Color(0xFF76736E),
    glass: Color(0x9EFFFFFF),
    glassBorder: Color(0xD9FFFFFF),
    line: Color(0x1A141210),
    screen: Color(0xFFEFEDEA),
    pill: Color(0xFF141312),
    pillInk: Color(0xFFF5F4F1),
    blob: Color(0x1A131211),
    scrim: Color(0x570C0C0B),
    isDark: false,
  );

  static const dark = MullColors(
    ink: Color(0xFFF4F3F0),
    ink2: Color(0xFFB3B1AB),
    ink3: Color(0xFF8B8984),
    glass: Color(0x12FFFFFF),
    glassBorder: Color(0x24FFFFFF),
    line: Color(0x1FFFFFFF),
    screen: Color(0xFF131312),
    pill: Color(0xFFF4F3F0),
    pillInk: Color(0xFF131312),
    blob: Color(0x1AFFFFFF),
    scrim: Color(0x99000000),
    isDark: true,
  );

  /// Opaque-ish surface used by sheets, where content behind is scrimmed.
  Color get sheet => isDark ? const Color(0xEB1C1C1B) : const Color(0xE6F7F6F4);

  @override
  MullColors copyWith() => this;

  @override
  MullColors lerp(MullColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return MullColors(
      ink: l(ink, other.ink),
      ink2: l(ink2, other.ink2),
      ink3: l(ink3, other.ink3),
      glass: l(glass, other.glass),
      glassBorder: l(glassBorder, other.glassBorder),
      line: l(line, other.line),
      screen: l(screen, other.screen),
      pill: l(pill, other.pill),
      pillInk: l(pillInk, other.pillInk),
      blob: l(blob, other.blob),
      scrim: l(scrim, other.scrim),
      isDark: t < .5 ? isDark : other.isDark,
    );
  }
}

extension MullTheme on BuildContext {
  MullColors get c => Theme.of(this).extension<MullColors>()!;
}

const _tabular = [FontFeature.tabularFigures()];

/// Display / numeric face. `tracking` is in em, like the CSS source.
TextStyle excon(
  double size, {
  FontWeight weight = FontWeight.w400,
  double tracking = 0,
  double? height,
  Color? color,
}) => TextStyle(
  fontFamily: 'Excon',
  fontSize: size,
  fontWeight: weight,
  letterSpacing: size * tracking,
  height: height,
  color: color,
  fontFeatures: _tabular,
);

/// Body / UI face.
TextStyle ranade(
  double size, {
  FontWeight weight = FontWeight.w400,
  double tracking = 0,
  double? height,
  Color? color,
  TextDecoration? decoration,
}) => TextStyle(
  fontFamily: 'Ranade',
  fontSize: size,
  fontWeight: weight,
  letterSpacing: size * tracking,
  height: height,
  color: color,
  decoration: decoration,
  decorationColor: color,
);

/// Uppercase eyebrow label ("UP NEXT", "IN REACH NOW").
TextStyle eyebrow(Color color, {double size = 11, double tracking = .16}) =>
    ranade(size, tracking: tracking, color: color);

ThemeData buildTheme(MullColors c) {
  final base = c.isDark ? ThemeData.dark() : ThemeData.light();
  return base.copyWith(
    extensions: [c],
    scaffoldBackgroundColor: c.screen,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    splashColor: Colors.transparent,
    platform: TargetPlatform.iOS,
    colorScheme: base.colorScheme.copyWith(
      primary: c.ink,
      surface: c.screen,
      onSurface: c.ink,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.ink,
      selectionColor: c.ink.withValues(alpha: .18),
      selectionHandleColor: c.ink,
    ),
    cupertinoOverrideTheme: null,
    textTheme: base.textTheme.apply(fontFamily: 'Ranade', bodyColor: c.ink, displayColor: c.ink),
  );
}
