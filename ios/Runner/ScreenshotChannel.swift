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
      guard call.method == "pick" else {
        result(FlutterMethodNotImplemented)
        return
      }
      present(result)
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

  /// Recognises text and flattens it into something Dart can reason about:
  /// normalised boxes with (0,0) at the top-left, which is how the parser thinks.
  static func read(_ image: CGImage, orientation: CGImagePropertyOrientation) -> [String: Any] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false  // product names and prices are not prose
    request.recognitionLanguages = ["en-US"]

    let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
    try? handler.perform([request])

    let lines: [[String: Any]] = (request.results ?? []).compactMap { observation in
      guard let best = observation.topCandidates(1).first else { return nil }
      let box = observation.boundingBox  // normalised, origin bottom-left
      return [
        "text": best.string,
        "x": Double(box.minX),
        "y": Double(1 - box.maxY),
        "w": Double(box.width),
        "h": Double(box.height),
        "conf": Double(best.confidence),
      ]
    }
    return ["lines": lines, "thumb": FlutterStandardTypedData(bytes: thumbnail(image))]
  }

  /// Small preview so the sheet can show what it just read.
  private static func thumbnail(_ image: CGImage, width: CGFloat = 320) -> Data {
    let source = UIImage(cgImage: image)
    let scale = min(1, width / max(source.size.width, 1))
    let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
    let scaled = UIGraphicsImageRenderer(size: size).image { _ in
      source.draw(in: CGRect(origin: .zero, size: size))
    }
    return scaled.jpegData(compressionQuality: 0.7) ?? Data()
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
      self?.finish(ScreenshotChannel.read(cgImage, orientation: image.cgOrientation))
    }
  }
}

private extension UIImage {
  /// Screenshots are always `.up`, but a photo of a price tag might not be.
  var cgOrientation: CGImagePropertyOrientation {
    switch imageOrientation {
    case .up: return .up
    case .down: return .down
    case .left: return .left
    case .right: return .right
    case .upMirrored: return .upMirrored
    case .downMirrored: return .downMirrored
    case .leftMirrored: return .leftMirrored
    case .rightMirrored: return .rightMirrored
    @unknown default: return .up
    }
  }
}
