import Foundation

/// A concrete window a bar can point at. Unlike IconSource there is no "auto" — a bar
/// composition names each window explicitly.
public enum BarWindow: Equatable, Sendable, Hashable {
    case fiveHour
    case weekly
    case model(String)

    public var storage: String {
        switch self {
        case .fiveHour: return "fiveHour"
        case .weekly: return "weekly"
        case .model(let name): return "model:\(name)"
        }
    }

    public static func parse(_ raw: String) -> BarWindow? {
        switch raw {
        case "fiveHour": return .fiveHour
        case "weekly": return .weekly
        default:
            if raw.hasPrefix("model:") { return .model(String(raw.dropFirst("model:".count))) }
            return nil
        }
    }

    /// Short label for the menu bar (kept tiny so inline layout stays compact).
    public var shortLabel: String {
        switch self {
        case .fiveHour: return "5h"
        case .weekly: return "Wk"
        case .model(let name): return name
        }
    }

    public var longLabel: String {
        switch self {
        case .fiveHour: return "5-hour window"
        case .weekly: return "Weekly cap"
        case .model(let name): return "\(name) weekly"
        }
    }

    public func window(in snapshot: UsageSnapshot) -> UsageWindow? {
        switch self {
        case .fiveHour: return snapshot.fiveHour
        case .weekly: return snapshot.sevenDay
        case .model(let name): return snapshot.perModelWindows.first { $0.name == name }?.window
        }
    }
}

/// One bar in the menu bar composition: which window, and whether to draw its label / value.
public struct BarItem: Equatable, Sendable {
    public var ref: BarWindow
    public var showLabel: Bool
    public var showValue: Bool

    public init(ref: BarWindow, showLabel: Bool = false, showValue: Bool = false) {
        self.ref = ref
        self.showLabel = showLabel
        self.showValue = showValue
    }

    public var storage: String { "\(ref.storage)|\(showLabel ? 1 : 0)|\(showValue ? 1 : 0)" }

    public static func parse(_ raw: String) -> BarItem? {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
        guard let first = parts.first, let ref = BarWindow.parse(String(first)) else { return nil }
        return BarItem(
            ref: ref,
            showLabel: parts.count > 1 && parts[1] == "1",
            showValue: parts.count > 2 && parts[2] == "1")
    }
}

/// Persisted menu bar bar-composition (a newline-joined list of BarItem.storage). Kept in
/// core so parsing is testable and the renderer/settings share one source of truth.
public enum BarComposition {
    /// Equivalent to the old fixed dual bars, but now editable: 5h + weekly, labels off.
    public static func makeDefault() -> [BarItem] {
        [BarItem(ref: .fiveHour), BarItem(ref: .weekly)]
    }

    public static func parse(_ raw: String) -> [BarItem] {
        let items = raw.split(separator: "\n").compactMap { BarItem.parse(String($0)) }
        return items.isEmpty ? makeDefault() : items
    }

    public static func serialize(_ items: [BarItem]) -> String {
        items.map(\.storage).joined(separator: "\n")
    }

    /// Windows available to add that aren't already in the composition.
    public static func addable(existing: [BarItem], seenModels: [String]) -> [BarWindow] {
        let universe: [BarWindow] = [.fiveHour, .weekly] + seenModels.map(BarWindow.model)
        let present = Set(existing.map(\.ref))
        return universe.filter { !present.contains($0) }
    }
}
