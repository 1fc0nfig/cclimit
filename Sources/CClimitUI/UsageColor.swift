import SwiftUI

/// One source of truth for the green/amber/red state mapping, split by role.
///
/// Bars are solid fills and tolerate low contrast, so they carry the full green→red ramp.
/// Numbers are text on the popover material — green fails WCAG contrast there — so the
/// number stays ink at rest and only takes color as it escalates. Color earns attention;
/// it isn't decoration.
public enum UsageColor {
    public static func bar(_ utilization: Double) -> Color {
        switch utilization {
        case ..<70: return .green
        case ..<90: return .orange
        default: return .red
        }
    }

    public static func number(_ utilization: Double) -> Color {
        switch utilization {
        case ..<70: return .primary
        case ..<90: return Color(nsColor: warnAmber)
        default: return Color(nsColor: critRed)
        }
    }

    /// NSColor variant for text drawn into the menu bar image. All three are dynamic
    /// providers, so they resolve at draw time against the menu bar's own appearance —
    /// a fixed color would go invisible on the opposite theme.
    public static func numberNSColor(_ utilization: Double) -> NSColor {
        switch utilization {
        case ..<70: return .labelColor
        case ..<90: return warnAmber
        default: return critRed
        }
    }

    /// The menu bar text styles show only a number, so it carries the whole state like a
    /// bar does: green at rest too, in a shade that stays legible on light and dark bars.
    public static func menuTextNSColor(_ utilization: Double) -> NSColor {
        utilization < 70 ? okGreen : numberNSColor(utilization)
    }

    private static let okGreen = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) == nil
            ? NSColor(calibratedRed: 0.10, green: 0.52, blue: 0.22, alpha: 1)
            : NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1)
    }

    /// Legible on both light and dark popover materials, unlike the vivid system variants.
    private static let warnAmber = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) == nil
            ? NSColor(calibratedRed: 0.72, green: 0.42, blue: 0.0, alpha: 1)   // light
            : NSColor(calibratedRed: 1.0, green: 0.66, blue: 0.26, alpha: 1)   // dark
    }

    private static let critRed = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) == nil
            ? NSColor(calibratedRed: 0.78, green: 0.12, blue: 0.10, alpha: 1)
            : NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.42, alpha: 1)
    }
}
