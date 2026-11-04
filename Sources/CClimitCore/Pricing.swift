import Foundation

/// What a response would cost at Anthropic's API list prices. On a subscription nobody pays
/// this: it is the value of the work, a way to compare projects and days in money.
/// A model missing from the table costs nothing here. cclimit never guesses a price.
public struct ModelPrice: Equatable, Sendable {
    /// US dollars per million tokens.
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    /// Prompts above this many tokens bill at the `long` rates (Haiku 5.5 only).
    public var longPromptThreshold: Int? = nil
    public var long: (input: Double, output: Double, cacheRead: Double)? = nil

    public static func == (a: ModelPrice, b: ModelPrice) -> Bool {
        a.input == b.input && a.output == b.output && a.cacheRead == b.cacheRead
            && a.longPromptThreshold == b.longPromptThreshold
    }
}

public enum Pricing {
    /// Cache writes cost a multiple of the input rate: 1.25x for the 5-minute TTL, 2x for 1 hour.
    static let write5m = 1.25
    static let write1h = 2.0

    /// Keyed by the display name `Format.modelName` gives ("Opus 5.5"). Source: Anthropic's
    /// pricing table, 2026-10. Update it together with a store version bump in
    /// `TranscriptIndex`, so indexed costs are recomputed.
    static let table: [String: ModelPrice] = [
        "Fable 5.1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
        "Mythos 5.1": ModelPrice(input: 10, output: 50, cacheRead: 0.25),
        "Fable 5": ModelPrice(input: 10, output: 50, cacheRead: 1),
        "Mythos 5": ModelPrice(input: 10, output: 50, cacheRead: 1),
        "Opus 5.5": ModelPrice(input: 4, output: 20, cacheRead: 0.2),
        "Opus 5": ModelPrice(input: 5, output: 25, cacheRead: 0.5),
        "Opus 4.8": ModelPrice(input: 5, output: 25, cacheRead: 0.5),
        "Opus 4.7": ModelPrice(input: 5, output: 25, cacheRead: 0.5),
        "Opus 4.6": ModelPrice(input: 5, output: 25, cacheRead: 0.5),
        "Opus 4.5": ModelPrice(input: 5, output: 25, cacheRead: 0.5),
        "Opus 4.1": ModelPrice(input: 15, output: 75, cacheRead: 1.5),
        "Opus 4": ModelPrice(input: 15, output: 75, cacheRead: 1.5),
        "Sonnet 5.5": ModelPrice(input: 2, output: 10, cacheRead: 0.2),
        "Sonnet 5": ModelPrice(input: 2, output: 10, cacheRead: 0.2),
        "Sonnet 4.6": ModelPrice(input: 3, output: 15, cacheRead: 0.3),
        "Sonnet 4.5": ModelPrice(input: 3, output: 15, cacheRead: 0.3),
        "Sonnet 4": ModelPrice(input: 3, output: 15, cacheRead: 0.3),
        "Haiku 5.5": ModelPrice(
            input: 0.1, output: 0.5, cacheRead: 0.01,
            longPromptThreshold: 100_000, long: (input: 0.5, output: 2.5, cacheRead: 0.05)),
        "Haiku 4.5": ModelPrice(input: 1, output: 5, cacheRead: 0.1),
        "Haiku 3.5": ModelPrice(input: 0.8, output: 4, cacheRead: 0.08),
    ]

    /// Fast mode bills at twice the standard rate on the models that have it.
    static let fastMultiplier: [String: Double] = ["Opus 5.5": 2, "Opus 5": 2]

    public static func price(forModel displayName: String) -> ModelPrice? {
        table[displayName]
    }

    /// The token counts of one response, as the transcript's `usage` block gives them.
    public struct Usage: Equatable, Sendable {
        public var input = 0
        public var output = 0
        public var cacheWrite5m = 0
        public var cacheWrite1h = 0
        public var cacheRead = 0
        public var fast = false

        public init(input: Int = 0, output: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0,
                    cacheRead: Int = 0, fast: Bool = false) {
            self.input = input
            self.output = output
            self.cacheWrite5m = cacheWrite5m
            self.cacheWrite1h = cacheWrite1h
            self.cacheRead = cacheRead
            self.fast = fast
        }

        /// Reads `input_tokens`, `output_tokens`, `cache_read_input_tokens`, and the TTL split
        /// under `cache_creation`. Without the split, every cache write counts as 5-minute.
        public init(json usage: [String: Any]) {
            func int(_ any: Any?) -> Int { (any as? Int) ?? (any as? Double).map(Int.init) ?? 0 }
            input = int(usage["input_tokens"])
            output = int(usage["output_tokens"])
            cacheRead = int(usage["cache_read_input_tokens"])
            let written = int(usage["cache_creation_input_tokens"])
            if let split = usage["cache_creation"] as? [String: Any] {
                cacheWrite1h = min(int(split["ephemeral_1h_input_tokens"]), written)
                cacheWrite5m = written - cacheWrite1h
            } else {
                cacheWrite5m = written
            }
            fast = (usage["speed"] as? String) == "fast"
        }

        public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
        var prompt: Int { input + cacheWrite + cacheRead }
    }

    /// US dollars at list price, or 0 for a model the table does not know.
    public static func cost(model displayName: String?, usage: Usage) -> Double {
        guard let displayName, let price = table[displayName] else { return 0 }
        var input = price.input, output = price.output, read = price.cacheRead
        if let threshold = price.longPromptThreshold, let long = price.long, usage.prompt > threshold {
            (input, output, read) = long
        }
        let dollars = (Double(usage.input) * input
            + Double(usage.output) * output
            + Double(usage.cacheRead) * read
            + Double(usage.cacheWrite5m) * input * write5m
            + Double(usage.cacheWrite1h) * input * write1h) / 1_000_000
        return usage.fast ? dollars * (fastMultiplier[displayName] ?? 1) : dollars
    }
}
