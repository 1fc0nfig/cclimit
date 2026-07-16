import XCTest

@testable import CClimitCore

final class ForecastTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_770_000_000)

    func sample(minutesAgo: Double, fiveHour: Double?, weekly: Double? = nil,
                fiveHourReset: Date? = nil, weeklyReset: Date? = nil) -> Sample {
        Sample(
            ts: now.addingTimeInterval(-minutesAgo * 60),
            fiveHourUtil: fiveHour,
            fiveHourReset: fiveHourReset,
            sevenDayUtil: weekly,
            sevenDayReset: weeklyReset)
    }

    // MARK: - 5h verdicts

    func testNoSamplesMeansNoData() {
        XCTAssertEqual(ForecastEngine.fiveHour(samples: [], now: now), .noData)
    }

    func testFlatUsageIsIdle() {
        let reset = now.addingTimeInterval(3600)
        let samples = (0..<5).map {
            sample(minutesAgo: Double(12 - $0 * 3), fiveHour: 40.0, fiveHourReset: reset)
        }
        guard case .idle(let utilization, _) = ForecastEngine.fiveHour(samples: samples, now: now) else {
            return XCTFail("expected idle")
        }
        XCTAssertEqual(utilization, 40.0)
    }

    func testSteadyBurnHittingWallBeforeReset() {
        // 60 -> 70% over 10 minutes = 1 point/min; wall in ~30 min, reset in 2 h.
        let reset = now.addingTimeInterval(2 * 3600)
        let samples = [
            sample(minutesAgo: 10, fiveHour: 60, fiveHourReset: reset),
            sample(minutesAgo: 5, fiveHour: 65, fiveHourReset: reset),
            sample(minutesAgo: 0, fiveHour: 70, fiveHourReset: reset),
        ]
        guard case .willHitWall(let eta, let resetsAt, _) =
            ForecastEngine.fiveHour(samples: samples, now: now)
        else {
            return XCTFail("expected willHitWall")
        }
        XCTAssertEqual(eta.timeIntervalSince(now), 30 * 60, accuracy: 60)
        XCTAssertEqual(resetsAt, reset)
    }

    func testSteadyBurnButResetArrivesFirst() {
        // Same pace, but reset in 15 min < 30 min to wall.
        let reset = now.addingTimeInterval(15 * 60)
        let samples = [
            sample(minutesAgo: 10, fiveHour: 60, fiveHourReset: reset),
            sample(minutesAgo: 5, fiveHour: 65, fiveHourReset: reset),
            sample(minutesAgo: 0, fiveHour: 70, fiveHourReset: reset),
        ]
        guard case .onPace = ForecastEngine.fiveHour(samples: samples, now: now) else {
            return XCTFail("expected onPace")
        }
    }

    func testTwoSamplesAreNotEnoughToForecast() {
        let samples = [
            sample(minutesAgo: 5, fiveHour: 60),
            sample(minutesAgo: 0, fiveHour: 70),
        ]
        guard case .idle = ForecastEngine.fiveHour(samples: samples, now: now) else {
            return XCTFail("expected idle — burn gate needs 3 samples")
        }
    }

    func testSubNoiseRiseIsIdle() {
        let samples = [
            sample(minutesAgo: 10, fiveHour: 60.0),
            sample(minutesAgo: 5, fiveHour: 60.4),
            sample(minutesAgo: 0, fiveHour: 60.8),
        ]
        guard case .idle = ForecastEngine.fiveHour(samples: samples, now: now) else {
            return XCTFail("expected idle — rise below noise threshold")
        }
    }

    func testWindowRolloverTrimsHistory() {
        // 90% then reset to 2%: the old burn must not fabricate a forecast.
        let samples = [
            sample(minutesAgo: 12, fiveHour: 80),
            sample(minutesAgo: 8, fiveHour: 90),
            sample(minutesAgo: 4, fiveHour: 2),
            sample(minutesAgo: 0, fiveHour: 3),
        ]
        guard case .idle(let utilization, _) = ForecastEngine.fiveHour(samples: samples, now: now) else {
            return XCTFail("expected idle after rollover")
        }
        XCTAssertEqual(utilization, 3)
    }

    func testExhaustedWindow() {
        let samples = [sample(minutesAgo: 0, fiveHour: 100)]
        guard case .exhausted = ForecastEngine.fiveHour(samples: samples, now: now) else {
            return XCTFail("expected exhausted")
        }
    }

    // MARK: - Weekly verdicts

    func testWeeklySlowPaceIsFine() {
        // ~1 point/day — cap is months away.
        let samples = [
            sample(minutesAgo: 2 * 24 * 60, fiveHour: nil, weekly: 20),
            sample(minutesAgo: 24 * 60, fiveHour: nil, weekly: 21),
            sample(minutesAgo: 0, fiveHour: nil, weekly: 22),
        ]
        guard case .paceFine = ForecastEngine.weekly(samples: samples, now: now) else {
            return XCTFail("expected paceFine")
        }
    }

    func testWeeklyHeavyPaceForecastsDayRange() {
        // 30 points/day from 40%: cap in ~2 days, reset 5 days out.
        let reset = now.addingTimeInterval(5 * 86400)
        let samples = [
            sample(minutesAgo: 24 * 60, fiveHour: nil, weekly: 10, weeklyReset: reset),
            sample(minutesAgo: 12 * 60, fiveHour: nil, weekly: 25, weeklyReset: reset),
            sample(minutesAgo: 0, fiveHour: nil, weekly: 40, weeklyReset: reset),
        ]
        guard case .likelyExhaustion(let earliest, let latest, _, _) =
            ForecastEngine.weekly(samples: samples, now: now)
        else {
            return XCTFail("expected likelyExhaustion")
        }
        XCTAssertLessThan(earliest, latest)
        // Day granularity, roughly two days out.
        XCTAssertEqual(earliest.timeIntervalSince(now) / 86400, 2, accuracy: 1.01)
    }

    func testWeeklyPaceIrrelevantWhenResetComesFirst() {
        // Heavy pace but reset lands tomorrow, before the projected wall.
        let reset = now.addingTimeInterval(86400)
        let samples = [
            sample(minutesAgo: 24 * 60, fiveHour: nil, weekly: 10, weeklyReset: reset),
            sample(minutesAgo: 0, fiveHour: nil, weekly: 40, weeklyReset: reset),
        ]
        guard case .paceFine = ForecastEngine.weekly(samples: samples, now: now) else {
            return XCTFail("expected paceFine — reset first")
        }
    }

    func testWeeklyNeedsAnHourOfHistory() {
        let samples = [
            sample(minutesAgo: 10, fiveHour: nil, weekly: 10),
            sample(minutesAgo: 0, fiveHour: nil, weekly: 40),
        ]
        guard case .paceFine = ForecastEngine.weekly(samples: samples, now: now) else {
            return XCTFail("expected paceFine — not enough history to call a pace")
        }
    }

    // MARK: - Weekly hour-band estimates (two-pace model)

    func testWeeklySteadyPaceCollapsesToTightHourBand() {
        // Sustained and recent pace agree (≈1.67 pts/h from 70%) → ETA ~18 h out,
        // and the band collapses to the rounding hour.
        let reset = now.addingTimeInterval(5 * 86400)
        let samples = [
            sample(minutesAgo: 24 * 60, fiveHour: nil, weekly: 30, weeklyReset: reset),
            sample(minutesAgo: 12 * 60, fiveHour: nil, weekly: 50, weeklyReset: reset),
            sample(minutesAgo: 5 * 60, fiveHour: nil, weekly: 61.7, weeklyReset: reset),
            sample(minutesAgo: 60, fiveHour: nil, weekly: 68.3, weeklyReset: reset),
            sample(minutesAgo: 0, fiveHour: nil, weekly: 70, weeklyReset: reset),
        ]
        guard case .likelyExhaustion(let earliest, let latest, _, _) =
            ForecastEngine.weekly(samples: samples, now: now)
        else { return XCTFail("expected likelyExhaustion") }
        XCTAssertEqual(earliest.timeIntervalSince(now), 18 * 3600, accuracy: 2.5 * 3600)
        XCTAssertLessThanOrEqual(latest.timeIntervalSince(earliest), 3 * 3600,
                                 "agreeing paces must give a tight, hour-level band")
    }

    func testWeeklyBurstWidensTheBand() {
        // Days of near-idle, then a heavy burst in the last 3 h: recent pace says soon,
        // sustained says far — the band must be wide (day-level), not a fake tight hour.
        let reset = now.addingTimeInterval(5 * 86400)
        let samples = [
            sample(minutesAgo: 60 * 60, fiveHour: nil, weekly: 40, weeklyReset: reset),
            sample(minutesAgo: 36 * 60, fiveHour: nil, weekly: 41, weeklyReset: reset),
            sample(minutesAgo: 3 * 60, fiveHour: nil, weekly: 42, weeklyReset: reset),
            sample(minutesAgo: 90, fiveHour: nil, weekly: 45, weeklyReset: reset),
            sample(minutesAgo: 0, fiveHour: nil, weekly: 48, weeklyReset: reset),
        ]
        guard case .likelyExhaustion(let earliest, let latest, _, _) =
            ForecastEngine.weekly(samples: samples, now: now)
        else { return XCTFail("expected likelyExhaustion") }
        XCTAssertGreaterThan(latest.timeIntervalSince(earliest), 24 * 3600,
                             "disagreeing paces must widen the band")
        // Burst pace: 6 pts / 3 h = 2/h → 52 remaining ≈ 26 h to the wall.
        XCTAssertEqual(earliest.timeIntervalSince(now), 26 * 3600, accuracy: 2 * 3600)
    }

    func testWeeklySinglePaceGetsUncertaintyStripe() {
        // Only the sustained pace exists (no samples in the last 6 h beyond one point):
        // 30 pts/day from 40% → wall ≈ 48 h; the stripe spans ±15%.
        let reset = now.addingTimeInterval(5 * 86400)
        let samples = [
            sample(minutesAgo: 24 * 60, fiveHour: nil, weekly: 10, weeklyReset: reset),
            sample(minutesAgo: 12 * 60, fiveHour: nil, weekly: 25, weeklyReset: reset),
            sample(minutesAgo: 0, fiveHour: nil, weekly: 40, weeklyReset: reset),
        ]
        guard case .likelyExhaustion(let earliest, let latest, _, _) =
            ForecastEngine.weekly(samples: samples, now: now)
        else { return XCTFail("expected likelyExhaustion") }
        let span = latest.timeIntervalSince(earliest)
        XCTAssertEqual(span, 0.3 * 48 * 3600, accuracy: 2.5 * 3600)
    }

    func testWeeklyBandEdgesAreWholeHours() {
        let reset = now.addingTimeInterval(5 * 86400)
        let samples = [
            sample(minutesAgo: 24 * 60, fiveHour: nil, weekly: 10, weeklyReset: reset),
            sample(minutesAgo: 0, fiveHour: nil, weekly: 40, weeklyReset: reset),
        ]
        guard case .likelyExhaustion(let earliest, let latest, _, _) =
            ForecastEngine.weekly(samples: samples, now: now)
        else { return XCTFail("expected likelyExhaustion") }
        for edge in [earliest, latest] {
            XCTAssertEqual(
                edge.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 3600), 0,
                "band edges must land on whole hours — minutes are false precision")
        }
    }

    func testWeeklyBandIsClampedToReset() {
        // Wall band ≈ 41–56 h, reset at 44 h: the band must not extend past reset.
        let reset = now.addingTimeInterval(44 * 3600)
        let samples = [
            sample(minutesAgo: 24 * 60, fiveHour: nil, weekly: 10, weeklyReset: reset),
            sample(minutesAgo: 0, fiveHour: nil, weekly: 40, weeklyReset: reset),
        ]
        guard case .likelyExhaustion(_, let latest, _, _) =
            ForecastEngine.weekly(samples: samples, now: now)
        else { return XCTFail("expected likelyExhaustion") }
        XCTAssertLessThanOrEqual(latest, reset)
    }

    func testWeeklyNearCapBandNeverStartsInThePast() {
        // At 99% the remaining 1% projects to minutes; hour-flooring must not push the
        // band's start behind now (the "cap ≈ today 22:00 at 22:30" bug).
        let reset = now.addingTimeInterval(36 * 3600)
        let samples = [
            sample(minutesAgo: 6 * 60, fiveHour: nil, weekly: 70, weeklyReset: reset),
            sample(minutesAgo: 3 * 60, fiveHour: nil, weekly: 90, weeklyReset: reset),
            sample(minutesAgo: 0, fiveHour: nil, weekly: 99, weeklyReset: reset),
        ]
        guard case .likelyExhaustion(let earliest, let latest, _, _) =
            ForecastEngine.weekly(samples: samples, now: now)
        else { return XCTFail("expected likelyExhaustion") }
        XCTAssertGreaterThanOrEqual(earliest, now, "band must never start in the past")
        XCTAssertGreaterThan(latest, now)
    }

    // MARK: - Per-model weekly (the Fable fix)

    func modelSample(minutesAgo: Double, name: String, util: Double, reset: Date?) -> Sample {
        Sample(
            ts: now.addingTimeInterval(-minutesAgo * 60),
            fiveHourUtil: nil, fiveHourReset: nil, sevenDayUtil: nil, sevenDayReset: nil,
            models: [ModelSample(name: name, util: util, reset: reset)])
    }

    func testPerModelWeeklyForecastsIndependently() {
        // Fable climbing 40 -> 70 over 24h, reset 5 days out: should predict a day range.
        let reset = now.addingTimeInterval(5 * 86400)
        let samples = [
            modelSample(minutesAgo: 24 * 60, name: "Fable", util: 40, reset: reset),
            modelSample(minutesAgo: 12 * 60, name: "Fable", util: 55, reset: reset),
            modelSample(minutesAgo: 0, name: "Fable", util: 70, reset: reset),
        ]
        guard case .likelyExhaustion = ForecastEngine.weeklyForModel("Fable", samples: samples, now: now) else {
            return XCTFail("expected likelyExhaustion for Fable")
        }
        // A model we have no samples for is noData, not a false pace.
        XCTAssertEqual(ForecastEngine.weeklyForModel("Opus", samples: samples, now: now), .noData)
    }

    func testPerModelRolloverTrims() {
        let samples = [
            modelSample(minutesAgo: 48 * 60, name: "Fable", util: 95, reset: nil),
            modelSample(minutesAgo: 1, name: "Fable", util: 4, reset: nil),
        ]
        // After a reset to 4%, no false "about to exhaust".
        let verdict = ForecastEngine.weeklyForModel("Fable", samples: samples, now: now)
        if case .likelyExhaustion = verdict { XCTFail("should not forecast exhaustion right after rollover") }
    }
}
