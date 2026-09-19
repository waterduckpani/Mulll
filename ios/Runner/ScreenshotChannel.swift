import Flutter
import PhotosUI
import UIKit
import Vision

/// Pulls one screenshot out of the photo library and reads it, all on-device.
///
/// Scraping a product page only works on stores that allow it — Zara, Massimo
/// Dutti and Amazon all refuse. A screenshot is just pixels, so this path works
/// on every store, every app, and a price tag in a shop window.
///
/// `PHPickerViewController` runs out of process, so this needs no photo-library
/// permission: the user hands over exactly one image and the app sees nothing
/// else. Vision recognises the text locally, so what someone is shopping for
/// never leaves the phone.
enum ScreenshotChannel {
  /// Held only while the picker is on screen — PHPicker does not retain its delegate.
  private static var pending: ScreenshotPicker?

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mull/screenshot", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "pick":
        present(result)
      case "drain":
        // Off the main thread: Vision on a handful of screenshots would
        // otherwise stall the first frame after launch.
        DispatchQueue.global(qos: .userInitiated).async {
          let items = Inbox.drain()
          DispatchQueue.main.async { result(items) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func present(_ result: @escaping FlutterResult) {
    guard let host = topViewController else {
      result(nil)
      return
    }

    // No `photoLibrary:` argument — that is what keeps us permission-free.
    var config = PHPickerConfiguration()
    // Not `.screenshots`: a product saved from WhatsApp, or a photo of a price
    // tag in a shop, is not a screenshot. Recents puts the fresh one first anyway.
    config.filter = .images
    config.selectionLimit = 1

    let delegate = ScreenshotPicker { payload in
      pending = nil
      result(payload)
    }
    pending = delegate

    let picker = PHPickerViewController(configuration: config)
    picker.delegate = delegate
    host.present(picker, animated: true)
  }

  private static var topViewController: UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  /// Wraps the shared recogniser for the method channel. The recognition lives
  /// in `Shared/MullScreenshot.swift` so the extension runs the same code.
  static func read(_ image: CGImage, orientation: CGImagePropertyOrientation) -> [String: Any] {
    [
      "lines": MullScreenshot.lines(image, orientation: orientation).map(\.json),
      "thumb": FlutterStandardTypedData(bytes: MullScreenshot.thumbnail(image)),
    ]
  }
}

/// Reads what the share extension queued in the App Group container.
///
/// The writing half lives in `ShareExtension/ShareViewController.swift`; both
/// sides go through `Shared/MullInbox.swift`, so the paths and entry shapes
/// cannot drift apart.
enum Inbox {
  private static var directory: URL? { MullInbox.directory }

  /// Everything shared since the last launch, oldest first, with screenshots
  /// already recognised. Each entry is removed as it is read, so a crash
  /// mid-drain costs at most the one item being worked on.
  static func drain() -> [[String: Any]] {
    guard let directory,
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }

    var out: [[String: Any]] = []
    // The share writes a millisecond-stamped name, so sorting restores order.
    for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      defer { try? FileManager.default.removeItem(at: file) }

      guard let data = try? Data(contentsOf: file),
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let items = payload["items"] as? [[String: Any]]
      else { continue }

      for item in items {
        if let resolved = resolve(item, in: directory) {
          out.append(resolved)
        }
      }
    }
    return out
  }

  private static func resolve(_ item: [String: Any], in directory: URL) -> [String: Any]? {
    switch item["kind"] as? String {
    case "resolved":
      // Already triaged in the share sheet — hand it straight through.
      return item
    case "image":
      guard let name = item["file"] as? String else { return nil }
      let path = directory.appendingPathComponent(name)
      defer { try? FileManager.default.removeItem(at: path) }
      guard let data = try? Data(contentsOf: path),
        let image = UIImage(data: data),
        let cgImage = image.cgImage
      else { return nil }
      var read = ScreenshotChannel.read(cgImage, orientation: image.mullOrientation)
      read["kind"] = "image"
      return read
    case "link":
      guard let url = item["url"] as? String else { return nil }
      return ["kind": "link", "url": url]
    case "text":
      guard let text = item["text"] as? String else { return nil }
      return ["kind": "text", "text": text]
    default:
      return nil
    }
  }
}

private final class ScreenshotPicker: NSObject, PHPickerViewControllerDelegate {
  init(completion: @escaping ([String: Any]?) -> Void) {
    self.completion = completion
  }

  private let completion: ([String: Any]?) -> Void
  private var finished = false

  /// Cancelling and picking can both land here; Dart gets exactly one reply.
  private func finish(_ payload: [String: Any]?) {
    guard !finished else { return }
    finished = true
    DispatchQueue.main.async { self.completion(payload) }
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
      finish(nil)  // backed out
      return
    }
    provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
      guard let image = object as? UIImage, let cgImage = image.cgImage else {
        self?.finish(nil)
        return
      }
      self?.finish(ScreenshotChannel.read(cgImage, orientation: image.mullOrientation))
    }
  }
}
