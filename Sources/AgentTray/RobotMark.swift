import AppKit
import SwiftUI

/// The robot-head silhouette used as the app's mark: a rounded head with an
/// antenna stub, an ear on each side, and two eyes punched out of the head.
///
/// Geometry is kept in a unit box (0...1 on both axes) traced from the source
/// artwork, so it stays crisp at any size. `aspect` is the box's width / height.
enum RobotMark {
    static let aspect: CGFloat = 1005.0 / 786.0

    // Unit-box geometry. y runs bottom-up.
    private static let head = CGRect(x: 0.144, y: 0.0, width: 0.707, height: 0.852)
    private static let headRadius: CGFloat = 0.109        // fraction of the box width
    private static let antenna = CGRect(x: 0.453, y: 0.852, width: 0.099, height: 0.148)
    private static let earSize = CGSize(width: 0.105, height: 0.391)
    private static let earBottom: CGFloat = 0.199
    private static let earRadius: CGFloat = 0.052
    private static let eyeCenters: [CGPoint] = [CGPoint(x: 0.361, y: 0.439), CGPoint(x: 0.642, y: 0.439)]
    private static let eyeRadius: CGFloat = 0.072

    /// Builds the mark filled with the even-odd rule, which is what knocks the
    /// eyes out of the head. Set `flipped` for y-down coordinate spaces.
    static func path(in rect: CGRect, flipped: Bool) -> NSBezierPath {
        // Fit the unit box inside `rect` without distorting it.
        let scale = min(rect.width / aspect, rect.height)
        let size = CGSize(width: scale * aspect, height: scale)
        let origin = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * size.width,
                    y: origin.y + (flipped ? 1 - y : y) * size.height)
        }
        func box(_ unit: CGRect) -> CGRect {
            let a = point(unit.minX, unit.minY), b = point(unit.maxX, unit.maxY)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
        let unitToPoints = size.width // radii are expressed against the box width

        let path = NSBezierPath()
        path.windingRule = .evenOdd
        path.appendRoundedRect(box(head),
                               xRadius: headRadius * unitToPoints,
                               yRadius: headRadius * unitToPoints)

        // The antenna butts up against the head instead of overlapping it —
        // an overlap would be punched out by the even-odd rule.
        path.append(stub(box(antenna), radius: antenna.width / 2 * unitToPoints, flipped: flipped))

        for x in [head.minX - 0.04 - earSize.width, head.maxX + 0.04] {
            let ear = CGRect(x: x, y: earBottom, width: earSize.width, height: earSize.height)
            path.appendRoundedRect(box(ear),
                                   xRadius: earRadius * unitToPoints,
                                   yRadius: earRadius * unitToPoints)
        }

        for centre in eyeCenters {
            let r = eyeRadius * unitToPoints
            let c = point(centre.x, centre.y)
            path.appendOval(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        return path
    }

    /// A rectangle rounded on the far side from the head only.
    private static func stub(_ rect: CGRect, radius: CGFloat, flipped: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        let r = min(radius, rect.width / 2, rect.height)
        let capY = flipped ? rect.minY + r : rect.maxY - r
        let baseY = flipped ? rect.maxY : rect.minY
        path.move(to: CGPoint(x: rect.minX, y: baseY))
        path.line(to: CGPoint(x: rect.minX, y: capY))
        // Sweep over the cap, away from the head: that is clockwise in a y-up
        // space and counter-clockwise once the y axis is flipped.
        path.appendArc(withCenter: CGPoint(x: rect.midX, y: capY), radius: r,
                       startAngle: 180, endAngle: 0, clockwise: !flipped)
        path.line(to: CGPoint(x: rect.maxX, y: baseY))
        path.close()
        return path
    }
}

/// SwiftUI wrapper so the popover header uses the same geometry.
struct RobotShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(RobotMark.path(in: rect, flipped: true).cgPath)
    }

    // Even-odd is what leaves the eyes hollow.
    static let fillStyle = FillStyle(eoFill: true)
}
