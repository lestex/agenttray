import AppKit

/// Shared geometry so every custom row lines up with the native menu items
/// around them.
enum MenuMetrics {
    static let leftInset: CGFloat = 15
    static let rightInset: CGFloat = 16
    static let width: CGFloat = 290
}

/// A plain line of menu text as a custom view. A disabled NSMenuItem is dimmed
/// by AppKit whatever colour its attributed title asks for, so a heading that
/// should read at full strength cannot be an ordinary item.
final class MenuTextView: NSView {
    private let text: NSAttributedString

    init(_ string: String, font: NSFont, color: NSColor) {
        text = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width,
                                 height: font.boundingRectForFont.height + 8))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        text.draw(at: NSPoint(x: MenuMetrics.leftInset, y: 4))
    }
}

/// One window as a menu item: title and percentage, a bar, and the reset time.
/// Drawn on a transparent background so the menu's own material shows through —
/// the row supplies content, the system still supplies the chrome.
final class GaugeRowView: NSView {
    private let title: String
    private let value: String
    private let detail: String
    private let detailOnRight: Bool
    private let fraction: Double

    private static let barHeight: CGFloat = 5

    init(title: String, percent: Double, detail: String, detailOnRight: Bool = false) {
        self.title = title
        self.value = Format.percent(percent)
        self.detail = detail
        self.detailOnRight = detailOnRight
        self.fraction = min(max(percent, 0), 100) / 100
        super.init(frame: NSRect(x: 0, y: 0, width: MenuMetrics.width, height: 52))
        autoresizingMask = [.width]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let left = MenuMetrics.leftInset
        let right = bounds.width - MenuMetrics.rightInset
        let titleFont = NSFont.menuFont(ofSize: 0)
        let detailFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)

        let name = NSAttributedString(string: title, attributes: [
            .font: titleFont, .foregroundColor: NSColor.labelColor,
        ])
        let percent = NSAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: titleFont.pointSize, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        name.draw(at: NSPoint(x: left, y: 6))
        percent.draw(at: NSPoint(x: right - percent.size().width, y: 6))

        let barY = 6 + name.size().height + 6
        let track = NSRect(x: left, y: barY, width: right - left, height: Self.barHeight)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        if fraction > 0 {
            let filled = NSRect(x: left, y: barY,
                                width: max(Self.barHeight, track.width * fraction),
                                height: Self.barHeight)
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: filled, xRadius: 2.5, yRadius: 2.5).fill()
        }

        let caption = NSAttributedString(string: detail, attributes: [
            .font: detailFont, .foregroundColor: NSColor.secondaryLabelColor,
        ])
        caption.draw(at: NSPoint(x: detailOnRight ? right - caption.size().width : left,
                                 y: barY + Self.barHeight + 5))
    }

    /// Height the row needs, so the menu item is never clipped.
    static func height() -> CGFloat {
        let title = NSFont.menuFont(ofSize: 0).boundingRectForFont.height
        let detail = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize).boundingRectForFont.height
        return 6 + title + 6 + barHeight + 5 + detail + 6
    }
}
