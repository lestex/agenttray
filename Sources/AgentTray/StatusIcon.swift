import AppKit

/// Renders the menu bar item. Short form is the robot mark plus four slim
/// gauges; long form is the labelled "5H 7%  WEEK 35%  FABLE 0%" pills on their
/// own. A `status` string replaces either, which is how a failed fetch shows a
/// bare "!".
enum StatusIcon {
    static let height: CGFloat = 22
    private static let pillHeight: CGFloat = 19
    private static let pillGap: CGFloat = 4
    private static let padding: CGFloat = 6
    private static let markHeight: CGFloat = 13
    private static let markWidth: CGFloat = (13 * RobotMark.aspect).rounded() + 4

    private static let barWidth: CGFloat = 3
    private static let barGap: CGFloat = 3
    private static let barHeight: CGFloat = 13
    private static let barRadius: CGFloat = 1.5
    private static let stripGap: CGFloat = 6

    private static let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
    private static let valueFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)

    static func image(for limits: [Limit], extra: ExtraUsage?, showsPercentage: Bool, status: String?) -> NSImage {
        // Anything wrong with the data outranks the gauges: show the marker.
        if let status {
            return image(withText: status, tint: status == "!" ? Palette.warnNS : .secondaryLabelColor)
        }
        let pills = limits.filter { $0.short != nil }
        if pills.isEmpty { return image(withText: "—") }

        if showsPercentage {
            // Just the pills — the gauges would only repeat what they say.
            let widths = pills.map { limit -> CGFloat in
                let label = attributed(limit.short!.uppercased(), font: labelFont,
                                       color: .secondaryLabelColor, kern: 0.6)
                let value = attributed(Format.percent(limit.utilization, spaced: false), font: valueFont,
                                       color: .labelColor, kern: 0)
                return max(label.size().width, value.size().width) + 10
            }
            return render(width: widths.reduce(0, +) + pillGap * CGFloat(widths.count)) {
                var x: CGFloat = 0
                for (limit, width) in zip(pills, widths) {
                    drawPill(limit, at: x, width: width)
                    x += width + pillGap
                }
            }
        }

        // Four gauges: the labelled windows, then extra-usage credits.
        let gauges = (pills.map(\.utilization) + [extra?.utilization].compactMap { $0 }).prefix(4)
        let stripWidth = gauges.isEmpty ? padding
            : CGFloat(gauges.count) * barWidth + CGFloat(gauges.count - 1) * barGap + stripGap
        return render(width: markWidth + stripWidth) {
            drawMark(at: NSPoint(x: 0, y: 0))
            var x = markWidth
            for value in gauges {
                drawBar(value, at: x)
                x += barWidth + barGap
            }
        }
    }

    private static func render(width: CGFloat, _ body: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            body()
            return true
        }
        image.isTemplate = false
        return image
    }

    static func image(withText text: String, tint: NSColor = .secondaryLabelColor) -> NSImage {
        let string = attributed(text, font: NSFont.systemFont(ofSize: 12, weight: .bold),
                                color: tint, kern: 0)
        let width = markWidth + string.size().width + padding
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            drawMark(at: NSPoint(x: 0, y: 0))
            string.draw(at: NSPoint(x: markWidth, y: (height - string.size().height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Pieces

    private static func drawMark(at origin: NSPoint) {
        let box = NSRect(x: origin.x, y: origin.y + (height - markHeight) / 2,
                         width: markWidth - 4, height: markHeight)
        NSColor.labelColor.setFill()
        RobotMark.path(in: box, flipped: false).fill()
    }

    /// A slim vertical gauge: a faint full-height track with the used portion
    /// filled from the bottom.
    private static func drawBar(_ percent: Double, at x: CGFloat) {
        let y = (height - barHeight) / 2
        let track = NSRect(x: x, y: y, width: barWidth, height: barHeight)
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: barRadius, yRadius: barRadius).fill()

        // An empty window shows the bare track; anything above it keeps a
        // minimum sliver so a small percentage still reads as "some".
        guard percent > 0 else { return }
        let filled = min(barHeight, max(3, barHeight * percent / 100))
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: filled),
                     xRadius: barRadius, yRadius: barRadius).fill()
    }

    private static func drawPill(_ limit: Limit, at x: CGFloat, width: CGFloat) {
        let y = (height - pillHeight) / 2
        let rect = NSRect(x: x, y: y, width: width, height: pillHeight)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

        let label = attributed(limit.short!.uppercased(), font: labelFont,
                               color: .secondaryLabelColor, kern: 0.6)
        let value = attributed(Format.percent(limit.utilization, spaced: false), font: valueFont,
                               color: Palette.levelNS(limit.utilization), kern: 0)
        label.draw(at: NSPoint(x: x + (width - label.size().width) / 2, y: y + 9.5))
        value.draw(at: NSPoint(x: x + (width - value.size().width) / 2, y: y - 0.5))
    }

    private static func attributed(_ text: String, font: NSFont, color: NSColor, kern: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .kern: kern,
        ])
    }
}
