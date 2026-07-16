import Foundation

/// Pure polling policy. The endpoint 429s hard per token with no Retry-After,
/// so conservative intervals and a real backoff are non-negotiable (product.md §3, §6).
public struct PollPolicy: Equatable, Sendable {
    public var activeInterval: TimeInterval   // session actively burning
    public var idleInterval: TimeInterval     // nothing moving
    public var backoffFloor: TimeInterval     // first backoff step after a 429
    public var backoffCap: TimeInterval

    public init(
        activeInterval: TimeInterval = 60,
        idleInterval: TimeInterval = 300,
        backoffFloor: TimeInterval = 60,
        backoffCap: TimeInterval = 300
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

    public init(
        consecutiveRateLimits: Int = 0,
        consecutiveFailures: Int = 0,
        screenLocked: Bool = false,
        activelyBurning: Bool = false
    ) {
        self.consecutiveRateLimits = consecutiveRateLimits
        self.consecutiveFailures = consecutiveFailures
        self.screenLocked = screenLocked
        self.activelyBurning = activelyBurning
    }

    public mutating func recordSuccess() {
        consecutiveRateLimits = 0
        consecutiveFailures = 0
    }

    public mutating func recordRateLimit() {
        consecutiveRateLimits += 1
        consecutiveFailures += 1
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
        // Exponential: floor * 2^(n-1), capped. 60s -> 120s -> 240s -> cap.
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
