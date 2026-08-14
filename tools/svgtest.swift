import AppKit

// Test: can NSImage load the whale SVG directly? Render to PNG if so.
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/dsh-whale.svg"
guard let image = NSImage(contentsOfFile: path) else {
    print("LOAD-FAILED")
    exit(1)
}
print("LOADED size=\(image.size)")
let size = NSSize(width: 128, height: 128)
let out = NSImage(size: size)
out.lockFocus()
NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()
image.draw(in: NSRect(origin: .zero, size: size))
out.unlockFocus()
guard let tiff = out.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("RENDER-FAILED")
    exit(1)
}
let outPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/tmp/dsh-whale.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("RENDERED \(outPath)")
