import Foundation

/// Pure polling policy. The endpoint 429s hard per token, with penalty windows observed
/// around 20+ minutes (Retry-After ~1300s). Retrying inside the penalty re-trips it, so the
/// server's Retry-After always wins over our own schedule and the blind cap must exceed
/// the penalty, or the app never recovers (product.md §3, §6).
public struct PollPolicy: Equatable, Sendable {
    public var activeInterval: TimeInterval   // session actively burning
    public var idleInterval: TimeInterval     // nothing moving
    public var backoffFloor: TimeInterval     // first backoff step after a 429
    public var backoffCap: TimeInterval

    /// Safety margin added on top of a server-provided Retry-After so the next attempt
    /// lands clearly outside the penalty window, not on its edge.
    public static let retryAfterMargin: TimeInterval = 30
    /// Ceiling for a server-provided Retry-After, in case the endpoint ever sends nonsense.
    public static let retryAfterCeiling: TimeInterval = 2 * 3600

    public init(
        activeInterval: TimeInterval = 60,
        idleInterval: TimeInterval = 300,
        backoffFloor: TimeInterval = 60,
        backoffCap: TimeInterval = 1800
    ) {
        self.activeInterval = max(30, activeInterval)
        self.idleInterval = max(60, idleInterval)
        self.backoffFloor = backoffFloor
        self.backoffCap = backoffCap
    }
}

public struct PollState: Equatable, Sendable {
    public var consecutiveRateLimits: Int
    public var consecutiveFailures: Int
    public var screenLocked: Bool
    public var activelyBurning: Bool
    /// Retry-After from the most recent 429, if the server sent one.
    public var serverRetryAfter: TimeInterval?

    public init(
        consecutiveRateLimits: Int = 0,
        consecutiveFailures: Int = 0,
        screenLocked: Bool = false,
        activelyBurning: Bool = false,
        serverRetryAfter: TimeInterval? = nil
    ) {
        self.consecutiveRateLimits = consecutiveRateLimits
        self.consecutiveFailures = consecutiveFailures
        self.screenLocked = screenLocked
        self.activelyBurning = activelyBurning
        self.serverRetryAfter = serverRetryAfter
    }

    public mutating func recordSuccess() {
        consecutiveRateLimits = 0
        consecutiveFailures = 0
        serverRetryAfter = nil
    }

    public mutating func recordRateLimit(retryAfter: TimeInterval? = nil) {
        consecutiveRateLimits += 1
        consecutiveFailures += 1
        serverRetryAfter = retryAfter
    }

    public mutating func recordFailure() {
        consecutiveFailures = 0 == consecutiveFailures ? 1 : consecutiveFailures + 1
    }
}

public enum PollDecision: Equatable, Sendable {
    case poll(after: TimeInterval)
    case paused // screen locked — resume on unlock, don't spin a timer
}

public func nextPoll(policy: PollPolicy, state: PollState) -> PollDecision {
    if state.screenLocked { return .paused }
    if state.consecutiveRateLimits > 0 {
        // The server's word beats our schedule: wait out the full penalty plus a margin.
        if let retryAfter = state.serverRetryAfter {
            let wait = min(retryAfter, PollPolicy.retryAfterCeiling) + PollPolicy.retryAfterMargin
            return .poll(after: max(wait, policy.backoffFloor))
        }
        // No Retry-After: exponential floor * 2^(n-1), capped. 60s -> 120s -> 240s -> ... -> cap.
        let exponent = min(state.consecutiveRateLimits - 1, 8)
        let backoff = policy.backoffFloor * pow(2, Double(exponent))
        return .poll(after: min(backoff, policy.backoffCap))
    }
    if state.consecutiveFailures > 0 {
        // Network/other errors: retry gently at idle pace, never faster.
        return .poll(after: policy.idleInterval)
    }
    return .poll(after: state.activelyBurning ? policy.activeInterval : policy.idleInterval)
}
