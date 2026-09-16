import UIKit
import UniformTypeIdentifiers

/// Takes whatever the share sheet hands over and drops it in Mull's inbox.
///
/// Deliberately dumb: it does no OCR, no parsing and no writing to `mull.json`.
/// The main app already knows how to read a screenshot, and two processes
/// writing the store would race its debounced writer. So this only queues, and
/// Mull drains the queue the next time it opens.
///
/// Speed is the whole point — the user is mid-scroll in Zara and should get
/// back there. Nothing here blocks on the network.
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    ingest()
  }

  private func ingest() {
    let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
      .flatMap { $0.attachments ?? [] }

    guard !attachments.isEmpty else {
      finish(saved: false)
      return
    }

    // One share can carry the same item several ways — Safari offers a URL and
    // a preview image for the same page. First match wins, in the order that
    // gives the parser the most to work with.
    let group = DispatchGroup()
    var entries: [MullInbox.Entry] = []
    let lock = NSLock()

    for provider in attachments {
      group.enter()
      load(provider) { entry in
        if let entry {
          lock.lock()
          entries.append(entry)
          lock.unlock()
        }
        group.leave()
      }
    }

    // If an extension hangs the share sheet, iOS kills it and the user blames
    // Mull. Take whatever arrived in time and get out.
    let timedOut = group.wait(timeout: .now() + 4) == .timedOut
    lock.lock()
    let collected = entries
    lock.unlock()

    let saved = MullInbox.append(collected)
    finish(saved: saved && !(collected.isEmpty && timedOut))
  }

  private func load(_ provider: NSItemProvider, completion: @escaping (MullInbox.Entry?) -> Void) {
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
        guard let data, let name = MullInbox.writeImage(data) else {
          completion(nil)
          return
        }
        completion(.image(file: name))
      }
      return
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
        guard let url = item as? URL, url.scheme?.hasPrefix("http") == true else {
          completion(nil)
          return
        }
        completion(.link(url: url.absoluteString))
      }
      return
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
        guard let text = item as? String, !text.isEmpty else {
          completion(nil)
          return
        }
        completion(.text(text))
      }
      return
    }

    completion(nil)
  }

  /// A brief confirmation, then out of the way. Anything longer and the user is
  /// waiting on us rather than shopping.
  private func finish(saved: Bool) {
    DispatchQueue.main.async {
      self.showToast(saved ? "Saved to Mull" : "Couldn't save that one")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
        self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
      }
    }
  }

  private func showToast(_ message: String) {
    let toast = UILabel()
    toast.text = message
    toast.textColor = .white
    toast.font = .systemFont(ofSize: 15, weight: .medium)
    toast.textAlignment = .center
    toast.backgroundColor = UIColor.black.withAlphaComponent(0.85)
    toast.layer.cornerRadius = 14
    toast.layer.masksToBounds = true
    toast.alpha = 0
    toast.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(toast)

    NSLayoutConstraint.activate([
      toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      toast.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      toast.widthAnchor.constraint(equalToConstant: 190),
      toast.heightAnchor.constraint(equalToConstant: 46),
    ])

    UIView.animate(withDuration: 0.18) { toast.alpha = 1 }
  }
}

/// The shared container Mull and the extension both see.
///
/// One file per share rather than a single appended `inbox.json`: two shares in
/// quick succession would otherwise read-modify-write the same array and one
/// would vanish. Separate files cannot collide, so no locking is needed on
/// either side.
enum MullInbox {
  static let appGroup = "group.com.bharatkhanna.mull"

  enum Entry {
    case image(file: String)
    case link(url: String)
    case text(String)

    var json: [String: Any] {
      switch self {
      case .image(let file): return ["kind": "image", "file": file]
      case .link(let url): return ["kind": "link", "url": url]
      case .text(let text): return ["kind": "text", "text": text]
      }
    }
  }

  static var container: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
  }

  static var inbox: URL? {
    guard let container else { return nil }
    let dir = container.appendingPathComponent("inbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Returns the file name to reference from the queued entry.
  static func writeImage(_ data: Data) -> String? {
    guard let inbox else { return nil }
    let name = "\(UUID().uuidString).img"
    do {
      try data.write(to: inbox.appendingPathComponent(name), options: .atomic)
      return name
    } catch {
      return nil
    }
  }

  @discardableResult
  static func append(_ entries: [Entry]) -> Bool {
    guard !entries.isEmpty, let inbox else { return false }

    // Millisecond prefix keeps the queue in share order when Mull drains it.
    let stamp = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
    let payload: [String: Any] = [
      "at": Date().timeIntervalSince1970,
      "items": entries.map(\.json),
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
    let file = inbox.appendingPathComponent("\(stamp)-\(UUID().uuidString).json")
    return (try? data.write(to: file, options: .atomic)) != nil
  }
}
