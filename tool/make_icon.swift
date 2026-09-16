// Renders the Mull app icon (Chillax wordmark on ink) to a 1024×1024 PNG.
// Usage: swift tool/make_icon.swift <font.otf> <out.png>
import AppKit
import CoreText

let args = CommandLine.arguments
let fontURL = URL(fileURLWithPath: args[1]) as CFURL
CTFontManagerRegisterFontsForURL(fontURL, .process, nil)
let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor(srgbRed: 0x13/255, green: 0x12/255, blue: 0x11/255, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let font = NSFont(name: "Chillax-Semibold", size: 300)!
let attrs: [NSAttributedString.Key: Any] = [
  .font: font,
  .foregroundColor: NSColor(srgbRed: 0xF4/255, green: 0xF3/255, blue: 0xF0/255, alpha: 1),
  .kern: -4.5,
]
let text = NSAttributedString(string: "mull", attributes: attrs)
let b = text.size()
text.draw(at: NSPoint(x: (size - b.width) / 2, y: (size - b.height) / 2 - 20))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
