import AppKit

/// Deliberately provider-neutral: no vendor colours. Everything reads as system
/// chrome until usage is worth noticing, and only then takes a warning tint.
enum Palette {
    static let warnNS = NSColor(srgbRed: 0.929, green: 0.612, blue: 0.196, alpha: 1)   // #EE9C32
    static let dangerNS = NSColor(srgbRed: 0.898, green: 0.282, blue: 0.302, alpha: 1) // #E5484D

    /// Colour for a utilisation percentage: calm until it starts to matter.
    static func levelNS(_ percent: Double) -> NSColor {
        switch percent {
        case ..<60: return .labelColor
        case ..<85: return warnNS
        default: return dangerNS
        }
    }
}
