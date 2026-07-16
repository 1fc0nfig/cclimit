import Foundation

/// Popover section ordering + visibility. Sections are identified by stable string IDs so
/// the persisted order survives across launches; per-model sections ("model:Fable") are
/// discovered at runtime and merged in without losing the user's manual order.
public enum SectionLayout {
    public static let fiveHour = "fiveHour"
    public static let weekly = "weekly"
    public static let forecast = "forecast"
    public static let attribution = "attribution"

    public static func modelID(_ name: String) -> String { "model:\(name)" }

    public static func modelName(_ id: String) -> String? {
        id.hasPrefix("model:") ? String(id.dropFirst("model:".count)) : nil
    }

    /// The full set of sections that can exist, in canonical default order:
    /// 5-hour, weekly, per-model windows, forecast, attribution.
    public static func universe(seenModels: [String]) -> [String] {
        [fiveHour, weekly] + seenModels.map(modelID) + [forecast, attribution]
    }

    /// Merge a stored order with the current universe: honor the stored order for anything
    /// still valid, then append newly-appeared sections (e.g. a model seen for the first
    /// time) in canonical position order. Drops stale IDs.
    public static func ordered(stored: [String], seenModels: [String]) -> [String] {
        let universe = universe(seenModels: seenModels)
        let universeSet = Set(universe)
        var result = stored.filter { universeSet.contains($0) }
        let present = Set(result)
        for id in universe where !present.contains(id) {
            result.append(id)
        }
        return result
    }

    public static func displayName(_ id: String) -> String {
        switch id {
        case fiveHour: return "5-hour window"
        case weekly: return "Weekly cap"
        case forecast: return "Forecast"
        case attribution: return "Attribution"
        default:
            if let model = modelName(id) { return "\(model) (weekly)" }
            return id
        }
    }
}
