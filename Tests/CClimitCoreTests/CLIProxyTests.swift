import XCTest
@testable import CClimitCore

final class CLIProxyTests: XCTestCase {
    /// Trimmed from a live CLIProxyAPI v8.0.11 `auth-files` answer (2026-10-31): one Ultra
    /// login without the 5h headers, one Max login with them, one Codex login.
    let authFiles = Data("""
    {"files":[
      {"auth_index":"0355c4543c166324","email":"cernymatyas@email.cz","provider":"claude","status":"active",
       "status_message":"","disabled":false,"unavailable":false,
       "quota":{"observed_at":"2026-10-31T23:42:13.206082216+08:00","signals":{
         "Anthropic-Ratelimit-Unified-7d-Reset":"1793955600",
         "Anthropic-Ratelimit-Unified-7d-Utilization":"0.37",
         "Anthropic-Ratelimit-Unified-Representative-Claim":"seven_day"}}},
      {"auth_index":"ae40c6d18224f10f","email":"matyas@mailnail.com","provider":"claude","status":"active",
       "disabled":false,"unavailable":false,
       "quota":{"observed_at":"2026-10-31T23:24:12.077298017+08:00","signals":{
         "Anthropic-Ratelimit-Unified-5h-Reset":"1793461800",
         "Anthropic-Ratelimit-Unified-5h-Utilization":"0.28",
         "Anthropic-Ratelimit-Unified-7d-Reset":"1793973600",
         "Anthropic-Ratelimit-Unified-7d-Utilization":"0.33"}}},
      {"auth_index":"06dabd2cc72b9b88","email":"cernymatyas@email.cz","provider":"codex","status":"active",
       "quota":{"signals":{"X-Codex-Primary-Used-Percent":"17"}}}
    ]}
    """.utf8)

    func testParsesClaudeLoginsOnly() throws {
        let logins = try CLIProxyClient.parseLogins(authFiles)
        XCTAssertEqual(logins.map(\.authIndex), ["0355c4543c166324", "ae40c6d18224f10f"])
        XCTAssertTrue(logins.allSatisfy(\.isActive))
    }

    func testUltraLoginHasNoFiveHourWindow() throws {
        let ultra = try CLIProxyClient.parseLogins(authFiles)[0]
        XCTAssertNil(ultra.signals?.fiveHour)
        XCTAssertEqual(ultra.signals?.sevenDay?.utilization ?? 0, 37, accuracy: 0.001)
        XCTAssertEqual(ultra.signals?.lacksFiveHour, true)
        XCTAssertNotNil(ultra.observedAt)
    }

    func testMaxLoginKeepsFiveHourWindow() throws {
        let max = try CLIProxyClient.parseLogins(authFiles)[1]
        XCTAssertEqual(max.signals?.fiveHour?.utilization ?? 0, 28, accuracy: 0.001)
        XCTAssertEqual(max.signals?.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1793461800))
        XCTAssertEqual(max.signals?.lacksFiveHour, false)
    }

    func testGoNanosecondDates() {
        let date = CLIProxyClient.parseDate("2026-10-31T23:42:13.206082216+08:00")
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1793461333.206, accuracy: 0.01)
        XCTAssertNotNil(CLIProxyClient.parseDate("2026-10-31T15:42:13Z"))
    }

    func testAPICallUnwrapsUpstreamBody() throws {
        let body = #"{"five_hour":null,"seven_day":{"utilization":38,"resets_at":"2026-11-06T09:00:00.353271+00:00"},"limits":[{"kind":"weekly_scoped","percent":4,"scope":{"model":{"display_name":"Fable"}}}]}"#
        let wrapped = try JSONSerialization.data(withJSONObject: ["status_code": 200, "header": [:], "body": body])
        let snap = try CLIProxyClient.parseAPICall(wrapped)
        XCTAssertNil(snap.fiveHour)
        XCTAssertEqual(snap.sevenDay?.utilization, 38)
        XCTAssertEqual(snap.perModelWindows.first?.name, "Fable")
    }

    func testAPICallRateLimitCarriesRetryAfter() throws {
        let wrapped = try JSONSerialization.data(withJSONObject: [
            "status_code": 429, "header": ["Retry-After": ["1300"]], "body": "{}",
        ])
        XCTAssertThrowsError(try CLIProxyClient.parseAPICall(wrapped)) { error in
            XCTAssertEqual(error as? UsageError, .rateLimited(retryAfter: 1300))
        }
    }

    func testBanAndRejectedKey() {
        let ban = Data(#"{"error":"IP banned due to too many failed attempts. Try again in 1m32s"}"#.utf8)
        XCTAssertEqual(CLIProxyClient.error(status: 403, body: ban), .proxyBanned(retryAfter: 92))
        let wrong = Data(#"{"error":"invalid management key"}"#.utf8)
        XCTAssertEqual(CLIProxyClient.error(status: 401, body: wrong), .proxyKeyRejected)
        XCTAssertNil(CLIProxyClient.error(status: 200, body: Data()))
        XCTAssertEqual(CLIProxyClient.retryAfter(inBanMessage: "Try again in 1h2m3s"), 3723)
    }

    func testNormalizedURL() {
        XCTAssertEqual(ProxyConfig.normalizedURL("100.94.42.52:8317")?.absoluteString, "http://100.94.42.52:8317")
        XCTAssertEqual(ProxyConfig.normalizedURL(" https://pi:8317/ ")?.absoluteString, "https://pi:8317")
        XCTAssertNil(ProxyConfig.normalizedURL(""))
    }

    func testMergingTiesProxyLoginsToLocalOnesByEmail() throws {
        let logins = try CLIProxyClient.parseLogins(authFiles)
        let local = ClaudeAccount(
            id: "default", service: "Claude Code-credentials", configDir: nil, email: "CernyMatyas@email.cz",
            organization: nil, accountUUID: nil, plan: .max20x, tokenExpiresAt: nil, suggestedName: "cernymatyas")
        let merged = ClaudeAccount.merging(local: [local], proxy: logins)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].id, "default")
        XCTAssertEqual(merged[0].proxyAuthIndex, "0355c4543c166324")
        XCTAssertEqual(merged[1].id, "proxy-ae40c6d18224f10f")
        XCTAssertTrue(merged[1].isProxyOnly)
        XCTAssertEqual(merged[1].suggestedName, "matyas")
    }

    func testIconDropsFiveHourWithoutTheWindow() {
        let ultra = UsageSnapshot(fiveHour: nil, sevenDay: UsageWindow(utilization: 40, resetsAt: nil))
        XCTAssertEqual(IconSource.fiveHour.binding(in: ultra)?.utilization, 40)
        let max = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: nil), sevenDay: UsageWindow(utilization: 40, resetsAt: nil))
        XCTAssertEqual(IconSource.fiveHour.binding(in: max)?.utilization, 10)
        XCTAssertFalse(UsageSnapshot(fiveHour: nil, sevenDay: nil).lacksFiveHour)
    }

    func testPoolKeepsFiveHourOfTheAccountsThatHaveIt() {
        let ultra = UsageSnapshot(fiveHour: nil, sevenDay: UsageWindow(utilization: 40, resetsAt: nil))
        let max = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 30, resetsAt: nil), sevenDay: UsageWindow(utilization: 20, resetsAt: nil))
        let pooled = AccountPool.combine([.init(snapshot: ultra, weight: 20), .init(snapshot: max, weight: 5)])
        XCTAssertEqual(pooled?.fiveHour?.utilization, 30)
        XCTAssertEqual(pooled?.sevenDay?.utilization ?? 0, 36, accuracy: 0.001)
        let onlyUltra = AccountPool.combine([.init(snapshot: ultra, weight: 20), .init(snapshot: ultra, weight: 20)])
        XCTAssertNil(onlyUltra?.fiveHour)
    }
}
