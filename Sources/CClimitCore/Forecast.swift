import Foundation

/// The wedge (deliberation D2b): forecasts are session-aware and honestly framed.
/// The 5-hour forecast only speaks while usage is actually moving, and answers the
/// real question — "do I make it to reset?" — as a verdict, not a raw timestamp.
/// The weekly forecast projects two paces — sustained (trailing days) and recent
/// (last hours) — and reports the band between them. A steady pace collapses the band
/// to hour precision; an erratic one widens it, and past two days of spread the UI
/// falls back to day names. Precision is earned by the data, never asserted.
public enum FiveHourVerdict: Equatable, Sendable {
    case noData
    case exhausted(resetsAt: Date?)
    /// Not actively burning — a slope forecast would be noise, so stay quiet.
    case idle(utilization: Double, resetsAt: Date?)
    /// Burning, but the window resets before the wall at this pace.
    case onPace(utilization: Double, resetsAt: Date)
    /// Burning and the wall arrives first.
    case willHitWall(eta: Date, resetsAt: Date?, utilization: Double)
}

public enum WeeklyVerdict: Equatable, Sendable {
    case noData
    case exhausted(resetsAt: Date?)
    /// Trailing pace won't reach the cap before the weekly reset.
    case paceFine(utilization: Double, resetsAt: Date?)
    /// At this week's pace the cap lands inside this day range (before reset).
    case likelyExhaustion(earliest: Date, latest: Date, resetsAt: Date?, utilization: Double)
}

public enum ForecastEngine {
    // 5h tuning: at least 3 samples over the last 15 min showing >= 1 percentage point
    // of movement before we call it a burn — the API reports coarse percentages, so
    // smaller deltas are indistinguishable from noise.
    static let burnLookback: TimeInterval = 15 * 60
    static let minBurnSamples = 3
    static let minBurnRise: Double = 1.0
    static let exhaustedAt: Double = 99.5

    // Weekly tuning: sustained pace over up to 3 days, recent pace over the last 6 h.
    // Beyond an 8-day horizon (past any weekly reset) "fine" is the only honest statement.
    static let weeklyLookback: TimeInterval = 3 * 24 * 3600
    static let recentLookback: TimeInterval = 6 * 3600
    static let maxWeeklyHorizon: TimeInterval = 8 * 24 * 3600
    /// With only one pace to go on, the ETA gets an honest ±15% uncertainty stripe.
    static let singleRateStripe = 0.15

    public static func fiveHour(samples: [Sample], now: Date) -> FiveHourVerdict {
        let recent = trimAfterReset(
            samples.filter { $0.ts >= now.addingTimeInterval(-burnLookback) },
            value: { $0.fiveHourUtil })
        guard let last = recent.last, let current = last.fiveHourUtil else { return .noData }
        let reset = last.fiveHourReset

        if current >= exhaustedAt { return .exhausted(resetsAt: reset) }

        guard
            recent.count >= minBurnSamples,
            let first = recent.first?.fiveHourUtil,
            let firstTs = recent.first?.ts,
            current - first >= minBurnRise,
            last.ts > firstTs
        else {
            return .idle(utilization: current, resetsAt: reset)
        }

        let slope = (current - first) / last.ts.timeIntervalSince(firstTs) // points per second
        let secondsToWall = (100 - current) / slope
        let eta = now.addingTimeInterval(secondsToWall)

        if let reset, reset <= eta {
            return .onPace(utilization: current, resetsAt: reset)
        }
        return .willHitWall(eta: eta, resetsAt: reset, utilization: current)
    }

    /// The overall (seven_day) weekly cap.
    public static func weekly(samples: [Sample], now: Date) -> WeeklyVerdict {
        weeklyVerdict(samples: samples, now: now, value: { $0.sevenDayUtil }, reset: { $0.sevenDayReset })
    }

    /// A per-model weekly window (e.g. Fable) — same pace logic, different series.
    public static func weeklyForModel(_ name: String, samples: [Sample], now: Date) -> WeeklyVerdict {
        weeklyVerdict(samples: samples, now: now, value: { $0.modelUtil(name) }, reset: { $0.modelReset(name) })
    }

    /// Generic weekly pace forecast over any utilization series.
    ///
    /// Two paces get projected to the cap: the sustained trailing pace (how this week
    /// has actually gone) and the recent pace (how the last hours are going). The band
    /// between the two ETAs IS the estimate — tight when usage is steady, wide when a
    /// burst and the trailing average disagree. Recomputed on every poll, so it tracks
    /// live usage.
    static func weeklyVerdict(
        samples: [Sample],
        now: Date,
        value: (Sample) -> Double?,
        reset: (Sample) -> Date?
    ) -> WeeklyVerdict {
        let recent = trimAfterReset(
            samples.filter { $0.ts >= now.addingTimeInterval(-weeklyLookback) },
            value: value)
        guard let last = recent.last, let current = value(last) else { return .noData }
        let resetsAt = reset(last)

        if current >= exhaustedAt { return .exhausted(resetsAt: resetsAt) }

        // Points per hour over each horizon; nil when the data can't support a rate.
        let sustained = pace(of: recent, value: value, minSpan: 3600, minRise: 1.0)
        let burst = pace(
            of: recent.filter { $0.ts >= now.addingTimeInterval(-recentLookback) },
            value: value, minSpan: 1800, minRise: 0.5)

        let remaining = 100 - current
        let horizons = [sustained, burst].compactMap { $0 }.map { remaining / $0 * 3600 }
        guard let soonest = horizons.min(), let furthest = horizons.max(),
              soonest <= maxWeeklyHorizon
        else {
            return .paceFine(utilization: current, resetsAt: resetsAt)
        }

        // One pace → uncertainty stripe around it; two → the band between them.
        var earliestTi = soonest, latestTi = furthest
        if horizons.count == 1 {
            earliestTi = soonest * (1 - singleRateStripe)
            latestTi = soonest * (1 + singleRateStripe)
        }
        // Hour granularity: floor/ceil to whole hours — minutes would be false precision.
        // Near the cap the horizon shrinks below an hour and the floor would point into
        // the past; the band's start is never earlier than now.
        let earliest = max(floorHour(now.addingTimeInterval(earliestTi)), now)
        var latest = ceilHour(now.addingTimeInterval(latestTi))

        if let resetsAt {
            if resetsAt <= earliest {
                return .paceFine(utilization: current, resetsAt: resetsAt)
            }
            latest = min(latest, resetsAt)
        }
        return .likelyExhaustion(
            earliest: earliest, latest: latest, resetsAt: resetsAt, utilization: current)
    }

    /// Endpoint slope in points per hour, or nil when the samples can't carry a rate
    /// (too short a span, or a rise within API noise).
    static func pace(
        of samples: [Sample], value: (Sample) -> Double?, minSpan: TimeInterval, minRise: Double
    ) -> Double? {
        guard
            let first = samples.first, let firstUtil = value(first),
            let last = samples.last, let lastUtil = value(last)
        else { return nil }
        let span = last.ts.timeIntervalSince(first.ts)
        guard span >= minSpan, lastUtil - firstUtil >= minRise else { return nil }
        return (lastUtil - firstUtil) / (span / 3600)
    }

    static func floorHour(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate:
            (date.timeIntervalSinceReferenceDate / 3600).rounded(.down) * 3600)
    }

    static func ceilHour(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate:
            (date.timeIntervalSinceReferenceDate / 3600).rounded(.up) * 3600)
    }

    /// A utilization drop means the window rolled over; only samples after the
    /// last drop describe the current window.
    static func trimAfterReset(_ samples: [Sample], value: (Sample) -> Double?) -> [Sample] {
        let valued = samples.filter { value($0) != nil }
        var lastDrop = 0
        for i in 1..<max(valued.count, 1) {
            if let prev = value(valued[i - 1]), let cur = value(valued[i]), cur < prev - 0.5 {
                lastDrop = i
            }
        }
        return Array(valued.suffix(from: min(lastDrop, max(valued.count - 1, 0))))
    }
}
