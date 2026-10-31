import AppKit

// Renders docs/menubar.png and docs/menubar-long.png from StatusIcon itself, so
// the README pictures can never drift from what the app draws. Run via
// tools/make-menubar-images.sh.

let out = CommandLine.arguments[1]
let scale: CGFloat = 3
// The dark menu bar, as the earlier screenshots had it.
let background = NSColor(srgbRed: 0.101, green: 0.102, blue: 0.113, alpha: 1)

// The numbers shown in the pictures.
let limits = [
    Limit(key: "five_hour", title: "5-hour window", short: "5H", utilization: 19, resetsAt: nil, order: 0),
    Limit(key: "seven_day", title: "Weekly", short: "WEEK", utilization: 7, resetsAt: nil, order: 1),
    Limit(key: "iguana_necktie", title: "Weekly Fable", short: "FABLE", utilization: 0, resetsAt: nil, order: 2),
]
let extra = ExtraUsage(utilization: 21, used: "$8.32", limit: "$40.00")

func write(_ icon: NSImage, to name: String) {
    let width = Int((icon.size.width * scale).rounded(.up))
    let height = Int(icon.size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // The icon's colours are the system's dynamic ones: draw as dark mode.
    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
        background.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        icon.draw(in: NSRect(x: 0, y: 0, width: icon.size.width * scale, height: icon.size.height * scale))
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}

write(StatusIcon.image(for: limits, extra: extra, showsPercentage: false, status: nil), to: "menubar")
write(StatusIcon.image(for: limits, extra: extra, showsPercentage: true, status: nil), to: "menubar-long")
print("wrote \(out)/menubar.png and menubar-long.png")
