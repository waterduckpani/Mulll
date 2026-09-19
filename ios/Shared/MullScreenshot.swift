import CoreGraphics
import UIKit
import Vision

/// On-device text recognition, compiled into both Mull and its share extension.
///
/// Deliberately free of Flutter types. The app wraps the output for the method
/// channel; the extension uses it directly, because by the time the share sheet
/// is on screen there is no Flutter engine running and there must not be — the
/// user is mid-scroll in Zara and waiting on us.
enum MullScreenshot {
  /// One recognised line, normalised to 0–1 with (0,0) at the top-left, which
  /// is how both the Swift guess and the Dart parser think about a page.
  struct Line {
    let text: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let conf: Double

    var json: [String: Any] {
      ["text": text, "x": x, "y": y, "w": w, "h": h, "conf": conf]
    }
  }

  static func lines(_ image: CGImage, orientation: CGImagePropertyOrientation) -> [Line] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false  // product names and prices are not prose
    request.recognitionLanguages = ["en-US"]

    let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
    try? handler.perform([request])

    return (request.results ?? []).compactMap { observation in
      guard let best = observation.topCandidates(1).first else { return nil }
      let box = observation.boundingBox  // normalised, origin bottom-left
      return Line(
        text: best.string,
        x: Double(box.minX),
        y: Double(1 - box.maxY),
        w: Double(box.width),
        h: Double(box.height),
        conf: Double(best.confidence)
      )
    }
  }

  /// Small preview so a sheet can show what it just read.
  static func thumbnail(_ image: CGImage, width: CGFloat = 320) -> Data {
    let source = UIImage(cgImage: image)
    let scale = min(1, width / max(source.size.width, 1))
    let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
    let scaled = UIGraphicsImageRenderer(size: size).image { _ in
      source.draw(in: CGRect(origin: .zero, size: size))
    }
    return scaled.jpegData(compressionQuality: 0.7) ?? Data()
  }
}

extension UIImage {
  /// Screenshots are always `.up`, but a photo of a price tag might not be.
  var mullOrientation: CGImagePropertyOrientation {
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
