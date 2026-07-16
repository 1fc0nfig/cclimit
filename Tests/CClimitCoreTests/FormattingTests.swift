import XCTest

@testable import CClimitCore

final class FormattingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_770_000_000)

    func at(minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func testCountdownMinutesAndHours() {
        XCTAssertEqual(Format.countdown(to: at(minutes: 42), from: now), "42 m")
        XCTAssertEqual(Format.countdown(to: at(minutes: 73), from: now), "1 h 13 m")
        XCTAssertEqual(Format.countdown(to: at(minutes: 120), from: now), "2 h")
    }

    func testCountdownRollsIntoDaysNotBareHours() {
        // A weekly reset ~2 days out must not read "51 h 0 m".
        XCTAssertEqual(Format.countdown(to: at(minutes: 51 * 60), from: now), "2 d 3 h")
        XCTAssertEqual(Format.countdown(to: at(minutes: 48 * 60), from: now), "2 d")
        XCTAssertEqual(Format.countdown(to: at(minutes: 5 * 24 * 60), from: now), "5 days")
    }

    func testCountdownEdgeCases() {
        XCTAssertEqual(Format.countdown(to: now, from: now), "now")
        XCTAssertEqual(Format.countdown(to: at(minutes: 0.2), from: now), "<1 m")
    }

    func testCompactCountdownRollsIntoDays() {
        XCTAssertEqual(Format.compactCountdown(to: at(minutes: 42), from: now), "42m")
        XCTAssertEqual(Format.compactCountdown(to: at(minutes: 73), from: now), "1h13m")
        XCTAssertEqual(Format.compactCountdown(to: at(minutes: 50 * 60), from: now), "2d")
    }

    func testResetStampAddsWeekdayWhenNotToday() {
        let later = now.addingTimeInterval(60 * 60) // same day
        XCTAssertEqual(Format.resetStamp(later, now: now), Format.clockTime(later))

        let twoDays = now.addingTimeInterval(2 * 24 * 3600)
        XCTAssertTrue(Format.resetStamp(twoDays, now: now).contains(Format.weekday(twoDays)))
    }

    // MARK: - etaRange (precision must match band width)

    func testEtaRangeTightBandReadsAsSingleEstimate() {
        let eta = at(minutes: 3 * 60)
        let text = Format.etaRange(earliest: eta, latest: eta, now: now)
        XCTAssertTrue(text.hasPrefix("≈"), "tight band should read as one estimate: \(text)")
        XCTAssertTrue(text.contains(Format.clockTime(eta)))
    }

    func testEtaRangeSameDayShowsHourSpan() {
        let earliest = at(minutes: 2 * 60)
        let latest = at(minutes: 5 * 60)
        let text = Format.etaRange(earliest: earliest, latest: latest, now: now)
        XCTAssertTrue(text.contains("today"), text)
        XCTAssertTrue(text.contains(Format.clockTime(earliest)), text)
        XCTAssertTrue(text.contains(Format.clockTime(latest)), text)
    }

    func testEtaRangeCrossDayNamesBothDays() {
        let earliest = at(minutes: 12 * 60)
        let latest = at(minutes: 36 * 60)
        let text = Format.etaRange(earliest: earliest, latest: latest, now: now)
        XCTAssertTrue(text.contains("today"), text)
        XCTAssertTrue(text.contains("tomorrow"), text)
    }

    func testEtaRangeAlreadyBegunReadsAsWithin() {
        // A band that starts now (or would start in the past) must not show a clock
        // stamp behind the current time — it reads as a countdown instead.
        let text = Format.etaRange(earliest: now, latest: at(minutes: 45), now: now)
        XCTAssertTrue(text.hasPrefix("within"), text)
        XCTAssertFalse(text.contains(":"), "no past-pointing clock stamp: \(text)")
    }

    func testEtaRangeWideBandFallsBackToDays() {
        // A band wider than two days must not pretend hour stamps.
        let earliest = at(minutes: 26 * 60)
        let latest = at(minutes: 100 * 60) // 74 h wide
        let text = Format.etaRange(earliest: earliest, latest: latest, now: now)
        XCTAssertFalse(text.contains(":"), "no clock times on a wide band: \(text)")
        XCTAssertTrue(text.contains("tomorrow"), text)
    }
}
