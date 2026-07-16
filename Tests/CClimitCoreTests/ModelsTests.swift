import XCTest

@testable import CClimitCore

final class ModelsTests: XCTestCase {
    // The community-documented payload from product.md §3.
    let documentedPayload = """
        {
          "five_hour":        { "utilization": 33.0, "resets_at": "2026-04-11T07:00:00Z" },
          "seven_day":        { "utilization": 13.0, "resets_at": "2026-04-17T00:59:59Z" },
          "seven_day_opus":   null,
          "seven_day_sonnet": { "utilization": 1.0,  "resets_at": "2026-04-16T03:00:00Z" },
          "extra_usage":      { "is_enabled": false }
        }
        """

    func testDecodesDocumentedPayload() throws {
        let snap = try UsageJSON.decoder()
            .decode(UsageSnapshot.self, from: Data(documentedPayload.utf8))
        XCTAssertEqual(snap.fiveHour?.utilization, 33.0)
        XCTAssertEqual(snap.sevenDay?.utilization, 13.0)
        XCTAssertNil(snap.sevenDayOpus)
        XCTAssertEqual(snap.sevenDaySonnet?.utilization, 1.0)
        XCTAssertEqual(snap.extraUsage?.isEnabled, false)
        XCTAssertNotNil(snap.fiveHour?.resetsAt)
    }

    func testMostConstrainedPicksHighestUtilization() throws {
        let snap = try UsageJSON.decoder()
            .decode(UsageSnapshot.self, from: Data(documentedPayload.utf8))
        XCTAssertEqual(snap.mostConstrained?.utilization, 33.0)
    }

    func testToleratesUnknownFieldsAndMissingWindows() throws {
        let payload = """
            { "five_hour": { "utilization": 5.5, "resets_at": "2026-04-11T07:00:00Z" },
              "brand_new_window": { "whatever": true } }
            """
        let snap = try UsageJSON.decoder().decode(UsageSnapshot.self, from: Data(payload.utf8))
        XCTAssertEqual(snap.fiveHour?.utilization, 5.5)
        XCTAssertNil(snap.sevenDay)
    }

    func testToleratesMissingFieldsInsideWindow() throws {
        let payload = """
            { "five_hour": { "utilization": 12.0 }, "seven_day": { "resets_at": "2026-04-17T00:59:59Z" } }
            """
        let snap = try UsageJSON.decoder().decode(UsageSnapshot.self, from: Data(payload.utf8))
        XCTAssertEqual(snap.fiveHour?.utilization, 12.0)
        XCTAssertNil(snap.fiveHour?.resetsAt)
        XCTAssertNil(snap.sevenDay?.utilization)
        XCTAssertNotNil(snap.sevenDay?.resetsAt)
    }

    func testDecodesFractionalSecondDates() throws {
        let payload = """
            { "five_hour": { "utilization": 1.0, "resets_at": "2026-04-11T07:00:00.123Z" } }
            """
        let snap = try UsageJSON.decoder().decode(UsageSnapshot.self, from: Data(payload.utf8))
        XCTAssertNotNil(snap.fiveHour?.resetsAt)
    }

    func testEmptyObjectDecodes() throws {
        let snap = try UsageJSON.decoder().decode(UsageSnapshot.self, from: Data("{}".utf8))
        XCTAssertNil(snap.fiveHour)
        XCTAssertNil(snap.mostConstrained)
    }

    func testRequestCarriesRequiredHeaders() {
        let request = UsageClient.request(token: "sk-test", userAgentVersion: "2.1.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        // Must match Claude Code's real UA exactly (verified against the 2.1.173 binary);
        // the endpoint buckets rate limits by client fingerprint.
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "User-Agent"), "claude-cli/2.1.0 (external, cli)")
    }

    func testCredentialJSONParsing() throws {
        let json = """
            {"claudeAiOauth": {"accessToken": "sk-ant-oat01-x", "refreshToken": "sk-ant-ort01-y",
             "expiresAt": 1760000000000, "scopes": ["user:inference", "user:profile"]}}
            """
        let creds = try CredentialJSON.parse(Data(json.utf8))
        XCTAssertEqual(creds.accessToken, "sk-ant-oat01-x")
        XCTAssertEqual(creds.refreshToken, "sk-ant-ort01-y")
        XCTAssertTrue(creds.hasProfileScope)
        XCTAssertEqual(creds.expiresAt?.timeIntervalSince1970, 1_760_000_000)
    }

    func testCredentialJSONRejectsMissingToken() {
        let json = #"{"claudeAiOauth": {"scopes": []}}"#
        XCTAssertThrowsError(try CredentialJSON.parse(Data(json.utf8)))
    }
}
