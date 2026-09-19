import Foundation

/// A first guess at what a screenshot is showing, good enough to fill in a
/// field the user is already looking at.
///
/// This is not a second implementation of the parser. `ScreenshotReader` in
/// Dart stays authoritative for anything the user does not confirm — it has the
/// test suite, and `flutter test` can reach it. This exists only because the
/// share sheet has no Flutter engine to ask, and an empty form in the share
/// sheet would be worse than no share sheet at all. Every field it produces
/// lands in an editable box with the screenshot next to it, so a wrong guess
/// costs one tap, not a bad entry.
enum MullProductGuess {
  struct Result {
    var name: String?
    var price: Int?

    var isEmpty: Bool { name == nil && price == nil }
  }

  static func read(_ lines: [MullScreenshot.Line]) -> Result {
    let price = bestPrice(lines)
    return Result(name: bestName(lines, priceY: price?.y), price: price?.value)
  }

  // ------------------------------------------------------------------ price

  /// Money written the way stores write it, with the currency either side.
  private static let marked = regex(#"(?:₹|rs\.?|inr)\s*([\d][\d,]*(?:\.\d{1,2})?)"#)
  private static let markedAfter = regex(#"([\d][\d,]*(?:\.\d{1,2})?)\s*(?:₹|rs\.?|inr)\b"#)
  private static let bare = regex(#"\b([\d][\d,]{2,}(?:\.\d{1,2})?)\b"#)
  private static let mrp = regex(#"\bm\.?r\.?p\.?"#)

  /// Marketing and metadata that is never the name and never the price.
  private static let junk = regex(#"(★|☆|\bemi\b|\bcoupon\b|\bcashback\b|\brating|\breview|\bdeliver|\bbought\b)"#)

  /// Traps for prices only. "off" and "save" stay out of `junk` because
  /// Off-White and Savage are things people buy. Any percent belongs here: the
  /// "100" in "100% WOOL" is otherwise a tempting number.
  private static let priceJunk = regex(#"(\boff\b|\bmonth\b|\bsave\b|%)"#)

  /// A discount badge, capped at two digits — nothing is ever 100% off, but
  /// half of fashion names lead with a fibre percentage.
  private static let discount = regex(#"\b\d{1,2}\s*%"#)

  private static let domainPattern = regex(#"\b(?:[a-z0-9-]+\.)+(?:com|in|net|org|co|shop|store|io)\b"#)

  private static func bestPrice(_ lines: [MullScreenshot.Line]) -> (value: Int, y: Double)? {
    var best: (value: Int, y: Double, score: Double)?

    for line in lines {
      if matches(junk, line.text) || matches(priceJunk, line.text) { continue }
      let discounted = matches(mrp, line.text) ? 0.5 : 1.0

      let candidates =
        captures(marked, line.text).map { (true, $0) }
        + captures(markedAfter, line.text).map { (true, $0) }
        + captures(bare, line.text).map { (false, $0) }

      for (isMarked, raw) in candidates {
        guard let value = amount(raw) else { continue }
        if !isMarked && value < 100 { continue }  // ratings, sizes, counts
        if value > 5_000_000 { continue }  // order numbers, phone numbers

        let score = line.h * line.conf * (isMarked ? 1.7 : 1) * discounted
        if best == nil || score > best!.score {
          best = (value, line.y, score)
        } else if score > best!.score * 0.9 && value < best!.value {
          // Two prices set the same size: the selling one, not the struck-out one.
          best = (value, line.y, best!.score)
        }
      }
    }
    guard let best else { return nil }
    return (best.value, best.y)
  }

  // ------------------------------------------------------------------- name

  /// Interface furniture that sits near the product but never describes it.
  private static let chrome = [
    "add to cart", "add to bag", "add to basket", "add to wishlist", "buy now",
    "sponsored", "delivery", "select size", "size guide", "reviews", "ratings",
    "in stock", "out of stock", "secure transaction", "sold by", "quantity",
    "returns", "share", "search", "cancel", "done", "similar items", "checkout",
    "you may also like", "more like this", "view details", "see all", "shop now",
    "inclusive of all taxes", "wishlist", "notify me", "find in store",
    "view look", "view product", "complete the look", "size chart",
  ]

  private static func bestName(_ lines: [MullScreenshot.Line], priceY: Double?) -> String? {
    var best: String?
    var bestScore = 0.0

    for line in lines {
      let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let lower = text.lowercased()
      if text.count < 4 || text.count > 90 { continue }
      if text.filter(\.isLetter).count < 3 { continue }  // prices, sizes, clock
      if matches(junk, text) { continue }
      if matches(discount, text) { continue }
      if matches(marked, text) || matches(markedAfter, text) { continue }
      if matches(domainPattern, text) { continue }  // the address bar
      if chrome.contains(where: { lower.contains($0) }) { continue }
      if line.y > 0.85 { continue }  // tab bar

      var score = line.h * line.conf
      if line.y < 0.1 { score *= 0.35 }  // status bar and the store's own logo
      if let priceY {
        if line.y < priceY && priceY - line.y < 0.2 {
          score *= 1.6  // titles sit just above the price
        } else if line.y > priceY {
          score *= 0.7  // descriptions and offers trail it
        }
      }
      if score > bestScore {
        bestScore = score
        best = text
      }
    }
    return best
  }

  // ------------------------------------------------------------------ utils

  /// Postel's law, the short version: strip the noise, keep the number.
  private static func amount(_ raw: String) -> Int? {
    let cleaned = raw.replacingOccurrences(of: ",", with: "")
    guard let value = Double(cleaned), value > 0 else { return nil }
    return Int(value.rounded())
  }

  private static func regex(_ pattern: String) -> NSRegularExpression {
    // Patterns are literals checked at build time; a throw here is a bug, not
    // a runtime condition worth carrying an optional around for.
    try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
  }

  private static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
    re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  /// Every first capture group in `text`.
  private static func captures(_ re: NSRegularExpression, _ text: String) -> [String] {
    re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
      guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
      return String(text[range])
    }
  }
}
