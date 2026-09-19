import Foundation

/// A first read of a UPI receipt, good enough to show the person what they just
/// shared before they commit to it.
///
/// This is not a second implementation of the parser. `UpiReceiptReader` in Dart
/// stays authoritative — it has the test suite, and `flutter test` can reach it,
/// and it is what actually matches a receipt to a debt. This exists only because
/// the share sheet has no Flutter engine to ask, and "Saved to Mull" with no
/// idea what was saved is how a share sheet loses people's trust.
///
/// So it reads for confirmation, never for a decision.
enum MullReceiptGuess {
  struct Result {
    var amount: Int?
    var payee: String?

    /// An amount alone proves nothing — a photo of a menu has one of those.
    /// A payee or a reference is what makes it a payment.
    var looksLikePayment: Bool { amount != nil && (payee != nil || hasReference) }
    var hasReference = false
    var failed = false
  }

  private static let amountPattern = try? NSRegularExpression(
    pattern: #"(?:₹|rs\.?|inr)\s*([\d][\d,]*(?:\.\d{1,2})?)"#,
    options: .caseInsensitive
  )
  private static let vpaPattern = try? NSRegularExpression(
    pattern: #"\b([a-z0-9.\-_]{2,256}@[a-z]{2,64})\b"#,
    options: .caseInsensitive
  )
  private static let referencePattern = try? NSRegularExpression(
    pattern: #"(?:utr|rrn|upi\s*(?:transaction\s*)?(?:id|ref(?:erence)?)|transaction\s*id)\D{0,12}(\d{9,22})|(?<!\d)(\d{12})(?!\d)"#,
    options: .caseInsensitive
  )

  private static let failureWords = ["failed", "failure", "unsuccessful", "declined", "cancelled", "canceled"]
  private static let successWords = ["paid", "success", "successful", "completed", "sent", "debited"]

  static func read(_ lines: [MullScreenshot.Line]) -> Result {
    var out = Result()

    // The amount is the hero on every UPI receipt — several times the size of
    // anything else on the screen — so the tallest match wins rather than the
    // first one.
    var tallest = 0.0
    for line in lines {
      for value in matches(amountPattern, in: line.text, group: 1) {
        guard let amount = rupees(value) else { continue }
        if out.amount == nil || line.h > tallest {
          out.amount = amount
          tallest = line.h
        }
      }
      if !out.hasReference, hasMatch(referencePattern, in: line.text) {
        // Never the amount: that one carries a symbol.
        out.hasReference = !hasMatch(amountPattern, in: line.text)
      }
      if out.payee == nil, !namesThePayer(line.text) {
        out.payee = matches(vpaPattern, in: line.text, group: 1).first?.lowercased()
      }
    }

    let text = lines.map { $0.text.lowercased() }.joined(separator: " ")
    out.failed = failureWords.contains { text.contains($0) }
      && !successWords.contains { text.contains($0) }
    return out
  }

  /// "From", "debited from" — the other party on the receipt.
  private static func namesThePayer(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("from") || lower.contains("sender") || lower.contains("paid by")
  }

  private static func rupees(_ raw: String) -> Int? {
    let cleaned = raw.replacingOccurrences(of: ",", with: "")
    guard let value = Double(cleaned), value > 0, value < 100_000_000 else { return nil }
    return Int(value.rounded())
  }

  private static func hasMatch(_ regex: NSRegularExpression?, in text: String) -> Bool {
    guard let regex else { return false }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  private static func matches(_ regex: NSRegularExpression?, in text: String, group: Int) -> [String] {
    guard let regex else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard match.numberOfRanges > group,
            let captured = Range(match.range(at: group), in: text)
      else { return nil }
      return String(text[captured])
    }
  }
}
