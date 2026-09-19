import UIKit

/// The design file's tokens, for the parts of Mull that are not Flutter.
///
/// Monochrome on purpose: affordability is shown through weight, opacity and
/// the reach line, never through colour. Kept in sync with `lib/ui/tokens.dart`.
enum MullPalette {
  static let ink = dynamic(light: 0x13_12_11, dark: 0xF4_F3_F0)
  static let ink2 = dynamic(light: 0x56_54_50, dark: 0xB3_B1_AB)
  static let ink3 = dynamic(light: 0x76_73_6E, dark: 0x8B_89_84)
  static let screen = dynamic(light: 0xEF_ED_EA, dark: 0x13_13_12)
  static let card = dynamic(light: 0xF7_F6_F4, dark: 0x1C_1C_1B)
  static let pill = dynamic(light: 0x14_13_12, dark: 0xF4_F3_F0)
  static let pillInk = dynamic(light: 0xF5_F4_F1, dark: 0x13_13_12)

  static let line = UIColor { $0.userInterfaceStyle == .dark
    ? UIColor(white: 1, alpha: 0.12)
    : UIColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 0.10)
  }

  private static func dynamic(light: Int, dark: Int) -> UIColor {
    UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) }
  }

  private static func rgb(_ hex: Int) -> UIColor {
    UIColor(
      red: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1
    )
  }
}
