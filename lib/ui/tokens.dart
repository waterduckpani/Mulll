import 'package:flutter/material.dart';

/// Colour and type tokens, lifted from the Mull UI specification.
///
/// Two rules carry the whole system and are worth stating before the values:
///
/// 1. **No colour, ever.** Owing and being owed are told apart by the words and
///    the weight, never by hue. There is no accent and no red/green.
/// 2. **No borders, no outlines, no glass.** Hierarchy is carried entirely by
///    how high a surface floats: a gradient fill plus a shadow, nothing else.
@immutable
class MullColors extends ThemeExtension<MullColors> {
  const MullColors({
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.screen,
    required this.pill,
    required this.pillInk,
    required this.glow,
    required this.scrim,
    required this.surfTop,
    required this.surfBottom,
    required this.raisedTop,
    required this.raisedBottom,
    required this.quiet,
    required this.sheetTop,
    required this.sheetBottom,
    required this.line,
    required this.sheetLine,
    required this.inputLine,
    required this.shadowFocal,
    required this.shadowCard,
    required this.shadowLow,
    required this.isDark,
  });

  /// Primary text, icons, filled buttons.
  final Color ink;

  /// Secondary text, muted rows, the inactive half of a segmented control.
  final Color ink2;

  /// Captions, eyebrows, metadata.
  final Color ink3;

  /// Flat screen background.
  final Color screen;

  /// Inverse pair: a light fill carrying dark text.
  final Color pill;
  final Color pillInk;

  /// The single soft radial wash behind each screen.
  final Color glow;

  /// Behind any sheet.
  final Color scrim;

  /// Default floating card and secondary button.
  final Color surfTop;
  final Color surfBottom;

  /// The one focal object on a screen.
  final Color raisedTop;
  final Color raisedBottom;

  /// Destination rows, settled groups, field rows. Sinks into the background.
  final Color quiet;

  /// Bottom sheet body.
  final Color sheetTop;
  final Color sheetBottom;

  /// Dividers: list hairline, the heavier one inside a sheet, input underline.
  final Color line;
  final Color sheetLine;
  final Color inputLine;

  final Color shadowFocal;
  final Color shadowCard;
  final Color shadowLow;

  final bool isDark;

  /// Dark is the primary theme; all eight reference screens are dark.
  static const dark = MullColors(
    ink: Color(0xFFF4F3F0),
    ink2: Color(0xFFADAAA4),
    ink3: Color(0xFF948F88),
    screen: Color(0xFF0B0B0A),
    pill: Color(0xFFF4F3F0),
    pillInk: Color(0xFF131211),
    glow: Color(0x17FFFFFF),
    scrim: Color(0x9E060605),
    surfTop: Color(0x12FFFFFF),
    surfBottom: Color(0x08FFFFFF),
    raisedTop: Color(0x23FFFFFF),
    raisedBottom: Color(0x11FFFFFF),
    quiet: Color(0x0AFFFFFF),
    sheetTop: Color(0xFA262624),
    sheetBottom: Color(0xFA141413),
    line: Color(0x12F4F3F0),
    sheetLine: Color(0x29F4F3F0),
    inputLine: Color(0x33F4F3F0),
    shadowFocal: Color(0x9C000000),
    shadowCard: Color(0x85000000),
    shadowLow: Color(0x59000000),
    isDark: true,
  );

  /// The paper theme. Same geometry and the same rules, inverted: a card is a
  /// slightly lighter paper that lifts off the page rather than a lit surface.
  ///
  /// Three of these values were wrong in a way that only shows up on paper,
  /// and all three came from inverting the dark theme's *numbers* rather than
  /// its intent:
  ///
  ///   - `ink3` at #78746D ran 3.98:1 on this background, under the 4.5:1 that
  ///     body text needs. It carries every caption, every eyebrow and every
  ///     line of helper text in the app, so it was the single biggest legibility
  ///     problem here. #67635C clears 4.5:1 both on the screen (5.1) and on
  ///     the recessed `quiet` surface it often sits on (4.5) — the second case
  ///     is the one an eyeballed fix misses.
  ///   - `quiet` was white at 28%, which on near-white paper is *nothing*. A
  ///     flat surface is meant to be a recess, so on paper it has to go
  ///     darker, not lighter — the old value made settled rows, chips and the
  ///     segmented control's track effectively invisible.
  ///   - the shadows were faint enough that a card had neither a lift nor an
  ///     edge, leaving the hierarchy to a 3% difference in fill.
  static const light = MullColors(
    ink: Color(0xFF131211),
    ink2: Color(0xFF55524D),
    ink3: Color(0xFF67635C),
    screen: Color(0xFFEFEDE9),
    pill: Color(0xFF141312),
    pillInk: Color(0xFFF5F4F1),
    glow: Color(0x8AFFFFFF),
    scrim: Color(0x701A1917),
    surfTop: Color(0xFFFFFFFF),
    surfBottom: Color(0xFFF7F5F2),
    raisedTop: Color(0xFFFFFFFF),
    raisedBottom: Color(0xFFF8F6F3),
    // A well in the paper rather than a highlight on it.
    quiet: Color(0x0F131211),
    sheetTop: Color(0xFCFCFBF9),
    sheetBottom: Color(0xFCF2F0ED),
    line: Color(0x1F131211),
    sheetLine: Color(0x29131211),
    inputLine: Color(0x47131211),
    shadowFocal: Color(0x33131211),
    shadowCard: Color(0x24131211),
    shadowLow: Color(0x1A131211),
    isDark: false,
  );

  /// Inside a sheet the faintest ink lightens and the hairlines get heavier,
  /// because the surface underneath them is itself lighter than the screen.
  MullColors get insideSheet => MullColors(
    ink: ink,
    ink2: ink2,
    ink3: isDark ? const Color(0xFF9A968F) : const Color(0xFF635F58),
    screen: sheetBottom,
    pill: pill,
    pillInk: pillInk,
    glow: glow,
    scrim: scrim,
    surfTop: surfTop,
    surfBottom: surfBottom,
    raisedTop: raisedTop,
    raisedBottom: raisedBottom,
    quiet: quiet,
    sheetTop: sheetTop,
    sheetBottom: sheetBottom,
    line: sheetLine,
    sheetLine: sheetLine,
    inputLine: inputLine,
    shadowFocal: shadowFocal,
    shadowCard: shadowCard,
    shadowLow: shadowLow,
    isDark: isDark,
  );

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
      screen: l(screen, other.screen),
      pill: l(pill, other.pill),
      pillInk: l(pillInk, other.pillInk),
      glow: l(glow, other.glow),
      scrim: l(scrim, other.scrim),
      surfTop: l(surfTop, other.surfTop),
      surfBottom: l(surfBottom, other.surfBottom),
      raisedTop: l(raisedTop, other.raisedTop),
      raisedBottom: l(raisedBottom, other.raisedBottom),
      quiet: l(quiet, other.quiet),
      sheetTop: l(sheetTop, other.sheetTop),
      sheetBottom: l(sheetBottom, other.sheetBottom),
      line: l(line, other.line),
      sheetLine: l(sheetLine, other.sheetLine),
      inputLine: l(inputLine, other.inputLine),
      shadowFocal: l(shadowFocal, other.shadowFocal),
      shadowCard: l(shadowCard, other.shadowCard),
      shadowLow: l(shadowLow, other.shadowLow),
      isDark: t < .5 ? isDark : other.isDark,
    );
  }
}

extension MullTheme on BuildContext {
  MullColors get c => Theme.of(this).extension<MullColors>()!;
}

// ------------------------------------------------------------------ surfaces

/// The CSS source tilts every surface gradient 176deg — a hair off straight
/// down, so the highlight runs across the top edge rather than dead level.
const _gradientBegin = Alignment(-.07, -1);
const _gradientEnd = Alignment(.07, 1);

/// How high a surface floats. This is the only hierarchy Mull has.
enum Lift {
  /// Exactly one per screen.
  focal,

  /// Group rows, settle rows, recurring cards, secondary buttons.
  card,

  /// Circular icon buttons and avatars.
  low,

  /// Quiet destinations and settled items: no shadow at all.
  flat,
}

/// The fill and shadow for a given [Lift].
BoxDecoration surfaceOf(MullColors c, Lift lift, {required BorderRadius radius}) => switch (lift) {
  Lift.focal => BoxDecoration(
    borderRadius: radius,
    gradient: LinearGradient(
      begin: _gradientBegin,
      end: _gradientEnd,
      colors: [c.raisedTop, c.raisedBottom],
    ),
    boxShadow: [BoxShadow(color: c.shadowFocal, blurRadius: 50, offset: const Offset(0, 23))],
  ),
  Lift.card => BoxDecoration(
    borderRadius: radius,
    gradient: LinearGradient(
      begin: _gradientBegin,
      end: _gradientEnd,
      colors: [c.surfTop, c.surfBottom],
    ),
    boxShadow: [BoxShadow(color: c.shadowCard, blurRadius: 42, offset: const Offset(0, 19))],
  ),
  Lift.low => BoxDecoration(
    borderRadius: radius,
    gradient: LinearGradient(
      begin: _gradientBegin,
      end: _gradientEnd,
      colors: [c.surfTop, c.surfBottom],
    ),
    boxShadow: [BoxShadow(color: c.shadowLow, blurRadius: 18, offset: const Offset(0, 8))],
  ),
  Lift.flat => BoxDecoration(borderRadius: radius, color: c.quiet),
};

// ---------------------------------------------------------------- typography

const _tabular = [FontFeature.tabularFigures()];

/// Numerals, screen titles, big statements. Always tabular, so a rolling amount
/// does not jitter. `tracking` is in em, like the CSS source.
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

/// Every other UI string. Ranade is the body default.
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

/// The wordmark, and nothing else.
TextStyle chillax(double size, {Color? color}) => TextStyle(
  fontFamily: 'Chillax',
  fontSize: size,
  fontWeight: FontWeight.w600,
  letterSpacing: size * -.005,
  height: 1,
  color: color,
);

/// Uppercase, tracked, quiet: "GROUPS", "SEPTEMBER", "1 OF 2".
TextStyle eyebrow(Color color, {double size = 11, double tracking = .17}) =>
    ranade(size, tracking: tracking, color: color);

/// The named roles from the specification, so a screen asks for a role rather
/// than re-deriving a size and a tracking value each time.
abstract final class MullType {
  static TextStyle hero(Color color) => excon(76, tracking: -.05, height: .9, color: color);
  static TextStyle groupAmount(Color color) => excon(68, tracking: -.05, height: .9, color: color);
  static TextStyle statement(Color color, {double size = 38}) =>
      excon(size, tracking: -.035, height: 1.1, color: color);
  static TextStyle screenTitle(Color color) => excon(32, tracking: -.03, height: 1.1, color: color);
  static TextStyle sheetAmount(Color color) => excon(54, tracking: -.045, height: .92, color: color);
  static TextStyle cardAmount(Color color, {double size = 21}) =>
      excon(size, weight: FontWeight.w500, color: color);
  static TextStyle listAmount(Color color) => excon(18, color: color);
  static TextStyle cardTitle(Color color, {double size = 17}) => ranade(size, color: color);
  static TextStyle button(Color color, {double size = 15.5}) => ranade(size, color: color);
  static TextStyle body(Color color) => ranade(14.5, height: 1.45, color: color);
  static TextStyle caption(Color color, {double size = 12}) => ranade(size, height: 1.6, color: color);
}

// --------------------------------------------------------------------- theme

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
    textTheme: base.textTheme.apply(fontFamily: 'Ranade', bodyColor: c.ink, displayColor: c.ink),
  );
}
