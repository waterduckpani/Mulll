import Foundation

/// The App Group queue Mull and its share extension both see.
///
/// One file per share rather than a single appended `inbox.json`: two shares in
/// quick succession would otherwise read-modify-write the same array and one
/// would vanish. Separate files cannot collide, so neither side needs a lock.
enum MullInbox {
  static let appGroup = "group.in.mull.app"

  /// What a share can leave behind.
  ///
  /// `resolved` is the fast path: the user already said what this is in the
  /// share sheet, so Mull files it on next launch without asking again. The
  /// other three are the raw path, kept because a share the user did not stop
  /// to triage is still worth keeping — Mull parses those on the way in.
  enum Entry {
    case resolved(name: String, price: Int, isNeed: Bool, url: String?)
    case image(file: String)
    case link(url: String)
    case text(String)

    var json: [String: Any] {
      switch self {
      case .resolved(let name, let price, let isNeed, let url):
        var out: [String: Any] = [
          "kind": "resolved",
          "name": name,
          "price": price,
          "itemKind": isNeed ? "need" : "want",
        ]
        if let url { out["url"] = url }
        return out
      case .image(let file): return ["kind": "image", "file": file]
      case .link(let url): return ["kind": "link", "url": url]
      case .text(let text): return ["kind": "text", "text": text]
      }
    }
  }

  static var directory: URL? {
    guard
      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    else { return nil }
    let dir = container.appendingPathComponent("inbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Returns the file name to reference from the queued entry.
  static func writeImage(_ data: Data) -> String? {
    guard let directory else { return nil }
    let name = "\(UUID().uuidString).img"
    do {
      try data.write(to: directory.appendingPathComponent(name), options: .atomic)
      return name
    } catch {
      return nil
    }
  }

  @discardableResult
  static func append(_ entries: [Entry]) -> Bool {
    guard !entries.isEmpty, let directory else { return false }

    // Millisecond prefix keeps the queue in share order when Mull drains it.
    let stamp = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
    let payload: [String: Any] = [
      "at": Date().timeIntervalSince1970,
      "items": entries.map(\.json),
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
    let file = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString).json")
    return (try? data.write(to: file, options: .atomic)) != nil
  }
}
