import Foundation

/// Menu bar icon styles. All are selectable at runtime; the renderer lives app-side
/// (AppKit), the selection logic here so it stays pure and testable.
public enum IconStyle: String, CaseIterable, Identifiable, Sendable {
    // Declaration order == gallery order. Spark leads: it's the CClimit mark, and the
    // gallery gives it its own full-width row at the top.
    case spark         // the CClimit mark as a clock-tick meter (fills clockwise, warms in color)
    case dualBars      // stacked mini bars: 5h + weekly, optional third (model weekly)
    case bars          // configurable multi-metric composition (labels/values)
    case singleBar     // one bar for the binding window
    case dot           // minimal color dot
    case ring          // donut arc
    case gauge         // arc + needle
    case percent       // "66%"
    case percentTime   // "66% · 1h13m"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .spark: return "Spark"
        case .dualBars: return "Stacked bars"
        case .bars: return "Configurable bars"
        case .singleBar: return "Bar"
        case .gauge: return "Gauge"
        case .ring: return "Ring"
        case .percent: return "Percent"
        case .percentTime: return "Percent + time"
        case .dot: return "Dot"
        }
    }

    /// Text styles render as a SwiftUI `Text`; the rest draw an `NSImage`.
    public var isText: Bool { self == .percent || self == .percentTime }

    /// The configurable multi-metric composition.
    public var isBars: Bool { self == .bars }

    /// Whether the single "icon source" picker applies. Bars and dual bars carry their own
    /// window selection, so they ignore it.
    public var usesSource: Bool { self != .dualBars && self != .bars }
}

/// Which window the icon reflects.
public enum IconSource: Equatable, Sendable {
    case auto          // most constrained
    case fiveHour
    case weekly
    case model(String) // a specific per-model weekly window (e.g. Fable)

    public var storage: String {
        switch self {
        case .auto: return "auto"
        case .fiveHour: return "fiveHour"
        case .weekly: return "weekly"
        case .model(let name): return "model:\(name)"
        }
    }

    public static func parse(_ raw: String) -> IconSource {
        switch raw {
        case "fiveHour": return .fiveHour
        case "weekly": return .weekly
        default:
            if raw.hasPrefix("model:") { return .model(String(raw.dropFirst("model:".count))) }
            return .auto
        }
    }

    /// The window this source resolves to in a given snapshot (nil if unavailable).
    public func binding(in snapshot: UsageSnapshot) -> UsageWindow? {
        switch self {
        case .auto: return snapshot.mostConstrained
        case .fiveHour: return snapshot.fiveHour
        case .weekly: return snapshot.sevenDay
        case .model(let name):
            return snapshot.perModelWindows.first { $0.name == name }?.window
        }
    }
}
