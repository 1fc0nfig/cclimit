import XCTest

@testable import CClimitCore

final class PollingTests: XCTestCase {
    let policy = PollPolicy()

    func testActiveVsIdleIntervals() {
        XCTAssertEqual(
            nextPoll(policy: policy, state: PollState(activelyBurning: true)),
            .poll(after: 60))
        XCTAssertEqual(
            nextPoll(policy: policy, state: PollState(activelyBurning: false)),
            .poll(after: 300))
    }

    func testScreenLockPauses() {
        XCTAssertEqual(
            nextPoll(policy: policy, state: PollState(screenLocked: true)),
            .paused)
    }

    func testRateLimitBackoffDoublesAndCaps() {
        var state = PollState()
        var intervals: [TimeInterval] = []
        for _ in 0..<7 {
            state.recordRateLimit()
            if case .poll(let after) = nextPoll(policy: policy, state: state) {
                intervals.append(after)
            }
        }
        XCTAssertEqual(intervals, [60, 120, 240, 480, 960, 1800, 1800])
    }

    func testServerRetryAfterBeatsExponentialSchedule() {
        // Live behavior 2026-07-16: 429 with Retry-After: 1300. Waiting less than the
        // penalty re-trips it, so the server value (plus margin) must win outright.
        var state = PollState()
        state.recordRateLimit(retryAfter: 1300)
        XCTAssertEqual(
            nextPoll(policy: policy, state: state),
            .poll(after: 1300 + PollPolicy.retryAfterMargin))
    }

    func testAbsurdRetryAfterIsCeilinged() {
        var state = PollState()
        state.recordRateLimit(retryAfter: 999_999)
        XCTAssertEqual(
            nextPoll(policy: policy, state: state),
            .poll(after: PollPolicy.retryAfterCeiling + PollPolicy.retryAfterMargin))
    }

    func testSuccessClearsServerRetryAfter() {
        var state = PollState()
        state.recordRateLimit(retryAfter: 1300)
        state.recordSuccess()
        XCTAssertNil(state.serverRetryAfter)
    }

    func testSuccessResetsBackoff() {
        var state = PollState(activelyBurning: true)
        state.recordRateLimit()
        state.recordRateLimit()
        state.recordSuccess()
        XCTAssertEqual(nextPoll(policy: policy, state: state), .poll(after: 60))
    }

    func testTransientFailureRetriesAtIdlePaceNeverFaster() {
        var state = PollState(activelyBurning: true)
        state.recordFailure()
        XCTAssertEqual(nextPoll(policy: policy, state: state), .poll(after: 300))
    }

    func testPolicyRefusesHotIntervals() {
        let hot = PollPolicy(activeInterval: 1, idleInterval: 5)
        XCTAssertGreaterThanOrEqual(hot.activeInterval, 30)
        XCTAssertGreaterThanOrEqual(hot.idleInterval, 60)
    }
}
