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
        for _ in 0..<5 {
            state.recordRateLimit()
            if case .poll(let after) = nextPoll(policy: policy, state: state) {
                intervals.append(after)
            }
        }
        XCTAssertEqual(intervals, [60, 120, 240, 300, 300])
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
