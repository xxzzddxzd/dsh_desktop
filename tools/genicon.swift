import Foundation
import AppKit

// Generates the DSH Desktop app icon: DeepSeek-blue rounded square + white
// whale (from the official favicon SVG). Usage:
//   swift tools/genicon.swift <output.png> <whale.svg>

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let svgPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// Rounded-rect clip + subtle vertical gradient
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let radius: CGFloat = size * 0.225
let path = NSBezierPath(roundedRect: rect.insetBy(dx: 12, dy: 12), xRadius: radius, yRadius: radius)
path.addClip()

let colors = [
    NSColor(calibratedRed: 0x3A / 255.0, green: 0x55 / 255.0, blue: 0xFE / 255.0, alpha: 1).cgColor,
    NSColor(calibratedRed: 0x4D / 255.0, green: 0x6B / 255.0, blue: 0xFE / 255.0, alpha: 1).cgColor
]
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// White whale
if let svgPath, let whale = NSImage(contentsOfFile: svgPath) {
    let inset: CGFloat = size * 0.26
    let whaleRect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    whale.isTemplate = true
    whale.draw(in: whaleRect)
    NSColor.white.setFill()
    whaleRect.fill(using: .sourceIn)
} else {
    // Fallback wordmark
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.36, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]
    let text = "DSH" as NSString
    let textSize = text.size(withAttributes: attrs)
    text.draw(in: NSRect(x: 0, y: (size - textSize.height) / 2 - size * 0.02, width: size, height: textSize.height), withAttributes: attrs)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }

try! png.write(to: URL(fileURLWithPath: outPath))
print(outPath)
