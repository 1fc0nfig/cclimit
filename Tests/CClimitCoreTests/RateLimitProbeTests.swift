import XCTest

@testable import CClimitCore

final class RateLimitProbeTests: XCTestCase {
    private func response(_ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: RateLimitProbe.endpoint, statusCode: 200, httpVersion: nil,
            headerFields: headers)!
    }

    func testParsesUnifiedHeadersAndScalesUtilization() {
        // Live shape (2026-07-16): utilization is a 0–1 fraction, reset is unix seconds.
        let snap = RateLimitProbe.snapshot(from: response([
            "anthropic-ratelimit-unified-5h-utilization": "0.65",
            "anthropic-ratelimit-unified-5h-reset": "1784228400",
            "anthropic-ratelimit-unified-7d-utilization": "0.31",
            "anthropic-ratelimit-unified-7d-reset": "1784278800",
        ]))
        XCTAssertEqual(try XCTUnwrap(snap?.fiveHour?.utilization), 65, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snap?.sevenDay?.utilization), 31, accuracy: 0.001)
        XCTAssertEqual(
            snap?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1784228400))
        XCTAssertEqual(
            snap?.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1784278800))
    }

    func testReturnsNilWhenNoUnifiedHeaders() {
        XCTAssertNil(RateLimitProbe.snapshot(from: response(["content-type": "application/json"])))
    }

    func testToleratesPartialHeaders() {
        let snap = RateLimitProbe.snapshot(from: response([
            "anthropic-ratelimit-unified-5h-utilization": "0.42",
            "anthropic-ratelimit-unified-5h-reset": "1784228400",
        ]))
        XCTAssertEqual(try XCTUnwrap(snap?.fiveHour?.utilization), 42, accuracy: 0.001)
        XCTAssertNil(snap?.sevenDay)
    }

    func testRequestCarriesClaudeCodeFingerprintAndSystemPrompt() {
        let request = RateLimitProbe.request(token: "sk-test", userAgentVersion: "2.1.173")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"), "claude-cli/2.1.173 (external, cli)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["max_tokens"] as? Int, 1)
        let system = body["system"] as? [[String: String]]
        XCTAssertEqual(system?.first?["text"], "You are Claude Code, Anthropic's official CLI for Claude.")
    }

    func testSystemPromptOmittedWhenDisabled() {
        let request = RateLimitProbe.request(token: "sk-test", sendSystemPrompt: false)
        let body = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertNil(body["system"])
    }
}
