import Foundation

/// One rolling limit window as returned by /api/oauth/usage.
/// Every field is optional: the endpoint is undocumented and must never crash the app on change.
public struct UsageWindow: Codable, Equatable, Sendable {
    public let utilization: Double?
    public let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    public init(utilization: Double?, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct ExtraUsage: Codable, Equatable, Sendable {
    public let isEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
    }

    public init(isEnabled: Bool?) {
        self.isEnabled = isEnabled
    }
}

/// One entry of the endpoint's generic `limits[]` array — the modern, model-agnostic
/// representation. A `weekly_scoped` entry carries the model it applies to (e.g. Fable),
/// so new models appear automatically without a code change.
public struct Limit: Codable, Equatable, Sendable {
    public let kind: String?        // "session" | "weekly_all" | "weekly_scoped" | ...
    public let group: String?       // "session" | "weekly"
    public let percent: Double?
    public let resetsAt: Date?
    public let isActive: Bool?
    public let severity: String?
    public let scope: Scope?

    public struct Scope: Codable, Equatable, Sendable {
        public let model: Model?
        public struct Model: Codable, Equatable, Sendable {
            public let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            public init(displayName: String?) { self.displayName = displayName }
        }
        public init(model: Model?) { self.model = model }
    }

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    public init(
        kind: String?, group: String?, percent: Double?, resetsAt: Date?,
        isActive: Bool?, severity: String?, scope: Scope?
    ) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.resetsAt = resetsAt
        self.isActive = isActive
        self.severity = severity
        self.scope = scope
    }

    /// Display name of the model this limit is scoped to, if any (e.g. "Fable").
    public var modelName: String? { scope?.model?.displayName }

    public var asWindow: UsageWindow { UsageWindow(utilization: percent, resetsAt: resetsAt) }
}

/// A per-model weekly window, normalized from either the modern `limits[]` array or the
/// legacy `seven_day_<model>` fields.
public struct ModelWindow: Equatable, Sendable, Identifiable {
    public let name: String
    public let window: UsageWindow
    public let isActive: Bool

    public var id: String { name }

    public init(name: String, window: UsageWindow, isActive: Bool) {
        self.name = name
        self.window = window
        self.isActive = isActive
    }
}

/// Full response of GET /api/oauth/usage. Every field optional; tolerant to schema drift.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let sevenDayOpus: UsageWindow?
    public let sevenDaySonnet: UsageWindow?
    public let limits: [Limit]?
    public let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
        case extraUsage = "extra_usage"
    }

    public init(
        fiveHour: UsageWindow?,
        sevenDay: UsageWindow?,
        sevenDayOpus: UsageWindow? = nil,
        sevenDaySonnet: UsageWindow? = nil,
        limits: [Limit]? = nil,
        extraUsage: ExtraUsage? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.limits = limits
        self.extraUsage = extraUsage
    }

    /// Per-model weekly windows (Fable, Opus, Sonnet, …). Prefers the modern `limits[]`
    /// array; falls back to legacy `seven_day_<model>` fields when the array is absent.
    public var perModelWindows: [ModelWindow] {
        if let scoped = limits?.filter({ $0.kind == "weekly_scoped" && $0.modelName != nil }),
           !scoped.isEmpty {
            return scoped.map {
                ModelWindow(name: $0.modelName!, window: $0.asWindow, isActive: $0.isActive ?? false)
            }
        }
        var legacy: [ModelWindow] = []
        if let opus = sevenDayOpus {
            legacy.append(ModelWindow(name: "Opus", window: opus, isActive: false))
        }
        if let sonnet = sevenDaySonnet {
            legacy.append(ModelWindow(name: "Sonnet", window: sonnet, isActive: false))
        }
        return legacy
    }

    /// The window closer to its cap — drives the menu bar icon. Includes per-model limits,
    /// so an active model cap (e.g. Fable at 66%) correctly binds the icon.
    public var mostConstrained: UsageWindow? {
        var candidates = [fiveHour, sevenDay].compactMap { $0 }
        candidates.append(contentsOf: perModelWindows.map(\.window))
        return candidates.max { ($0.utilization ?? 0) < ($1.utilization ?? 0) }
    }
}

public enum UsageJSON {
    /// Decoder tolerant to both plain and fractional-second ISO 8601 timestamps.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = plain.date(from: raw) ?? fractional.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognized date: \(raw)")
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
