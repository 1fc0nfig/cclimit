import XCTest

@testable import CClimitCore

/// Fed with lines recorded from Claude Code 2.1.309 (`-p --output-format stream-json`).
final class ClaudeCodeUsageTests: XCTestCase {
    private let initOK = #"{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{"account":{"email":"me@x.cz","subscriptionType":"Claude Max","apiProvider":"firstParty"}}}}"#
    private let initSignedOut = #"{"type":"control_response","response":{"subtype":"success","request_id":"init","response":{"account":{"tokenSource":"none","apiProvider":"firstParty"}}}}"#

    private func usage(_ body: String) -> String {
        #"{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":"# + body + "}}"
    }

    private func feed(_ lines: [String], chunked: Bool = false) throws -> ClaudeCodeUsageSource.Reading? {
        var parser = ControlStreamParser()
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if !chunked { return try parser.feed(data) }
        // Pipes deliver arbitrary slices: a line can split anywhere.
        var result: ClaudeCodeUsageSource.Reading?
        for start in stride(from: 0, to: data.count, by: 7) {
            if let r = try parser.feed(data.subdata(in: start..<min(start + 7, data.count))) { result = r }
        }
        return result
    }

    func testReadsWindowsModelsAndAccount() throws {
        let body = #"{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":8,"resets_at":"2026-10-25T14:59:59.639751+00:00"},"seven_day":{"utilization":13,"resets_at":"2026-10-30T08:59:59.639775+00:00"},"limits":[{"kind":"weekly_scoped","group":"weekly","percent":2,"severity":"normal","resets_at":"2026-10-30T08:59:59.639946+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}}"#
        let lines = [#"{"type":"system","subtype":"hook_started"}"#, initOK, usage(body)]
        for chunked in [false, true] {
            let reading = try XCTUnwrap(try feed(lines, chunked: chunked))
            XCTAssertEqual(reading.snapshot.fiveHour?.utilization, 8)
            XCTAssertEqual(reading.snapshot.sevenDay?.utilization, 13)
            XCTAssertNotNil(reading.snapshot.fiveHour?.resetsAt, "microsecond timestamps must parse")
            XCTAssertEqual(reading.snapshot.perModelWindows.map(\.name), ["Fable"])
            XCTAssertEqual(reading.email, "me@x.cz")
            XCTAssertEqual(reading.subscription, "Claude Max")
        }
    }

    func testSignedOutFolderIsNoCredentials() {
        XCTAssertThrowsError(try feed([initSignedOut])) { XCTAssertEqual($0 as? UsageError, .noCredentials) }
    }

    func testEmptyLimitsBackOffAsRateLimited() {
        let lines = [initOK, usage(#"{"rate_limits_available":true,"rate_limits":null}"#)]
        XCTAssertThrowsError(try feed(lines)) {
            XCTAssertEqual($0 as? UsageError, .rateLimited(retryAfter: nil))
        }
    }

    func testNoSubscriptionWindowsIsForbidden() {
        let lines = [initOK, usage(#"{"rate_limits_available":false}"#)]
        XCTAssertThrowsError(try feed(lines)) { XCTAssertEqual($0 as? UsageError, .forbidden) }
    }

    func testErrorAnswerMapsRateLimit() {
        let line = #"{"type":"control_response","response":{"subtype":"error","request_id":"usage","error":"Request failed with status code 429"}}"#
        XCTAssertThrowsError(try feed([initOK, line])) {
            XCTAssertEqual($0 as? UsageError, .rateLimited(retryAfter: nil))
        }
    }

    func testErrorWordsDoNotReadAsRateLimit() {
        let line = #"{"type":"control_response","response":{"subtype":"error","request_id":"usage","error":"Could not generate a separate report"}}"#
        XCTAssertThrowsError(try feed([initOK, line])) {
            guard case .schemaChanged = $0 as? UsageError else { return XCTFail("got \($0)") }
        }
    }

    func testChildEnvironmentSetsConfigDirOnlyForOtherLogins() {
        let work = URL(fileURLWithPath: "/Users/t/.claude-work")
        XCTAssertEqual(ClaudeCodeUsageSource.environment(configDir: work)["CLAUDE_CONFIG_DIR"], work.path)
        XCTAssertNil(ClaudeCodeUsageSource.environment(configDir: nil)["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(ClaudeCodeUsageSource.environment(configDir: nil)["ENABLE_CLAUDEAI_MCP_SERVERS"], "false")
        XCTAssertTrue(ClaudeCodeUsageSource.arguments.contains("--no-session-persistence"))
    }
}
