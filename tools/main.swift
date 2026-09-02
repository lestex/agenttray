import AppKit

// Renders Resources/AppIcon.iconset from the same vector the menu bar uses,
// then iconutil turns it into the .icns. Run via tools/make-icon.sh.

let out = CommandLine.arguments[1]
// Graphite, not a vendor colour: the app is not tied to one agent.
let plateTop = NSColor(srgbRed: 0.298, green: 0.322, blue: 0.357, alpha: 1)     // #4C525B
let plateBottom = NSColor(srgbRed: 0.153, green: 0.169, blue: 0.192, alpha: 1)  // #272B31

func icon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
        // macOS icons draw their own rounded square, inset from the canvas.
        let inset = size * 0.098
        let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let radius = plate.width * 0.2237      // the system's corner proportion
        let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)
        NSGradient(starting: plateTop, ending: plateBottom)?.draw(in: shape, angle: -90)

        let markHeight = plate.height * 0.46
        let markWidth = markHeight * RobotMark.aspect
        let box = NSRect(x: plate.midX - markWidth / 2, y: plate.midY - markHeight / 2,
                         width: markWidth, height: markHeight)
        NSColor.white.setFill()
        RobotMark.path(in: box, flipped: false).fill()
        return true
    }
}

for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                       ("icon_32x32", 32), ("icon_32x32@2x", 64),
                       ("icon_128x128", 128), ("icon_128x128@2x", 256),
                       ("icon_256x256", 256), ("icon_256x256@2x", 512),
                       ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let image = icon(size: CGFloat(pixels))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("wrote \(out)")
