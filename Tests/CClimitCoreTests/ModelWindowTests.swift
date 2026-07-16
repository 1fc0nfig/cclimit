import XCTest

@testable import CClimitCore

final class ModelWindowTests: XCTestCase {
    // Shape mirrors the live endpoint: modern `limits[]` array with a model-scoped
    // weekly entry (Fable), alongside the legacy top-level fields (here null).
    let modernPayload = """
        {
          "five_hour": { "utilization": 11, "resets_at": "2026-07-15T15:20:00.970050+00:00" },
          "seven_day": { "utilization": 37, "resets_at": "2026-07-17T09:00:00.970072+00:00" },
          "seven_day_opus": null,
          "seven_day_sonnet": null,
          "limits": [
            { "kind": "session", "group": "session", "percent": 11, "is_active": false,
              "resets_at": "2026-07-15T15:20:00.970050+00:00", "scope": null, "severity": "normal" },
            { "kind": "weekly_all", "group": "weekly", "percent": 37, "is_active": false,
              "resets_at": "2026-07-17T09:00:00.970072+00:00", "scope": null, "severity": "normal" },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 66, "is_active": true,
              "resets_at": "2026-07-17T09:00:00.970459+00:00",
              "scope": { "model": { "display_name": "Fable", "id": null }, "surface": null },
              "severity": "normal" }
          ],
          "extra_usage": { "is_enabled": false }
        }
        """

    func decode(_ s: String) throws -> UsageSnapshot {
        try UsageJSON.decoder().decode(UsageSnapshot.self, from: Data(s.utf8))
    }

    func testParsesFableFromLimitsArray() throws {
        let snap = try decode(modernPayload)
        let models = snap.perModelWindows
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.name, "Fable")
        XCTAssertEqual(models.first?.window.utilization, 66)
        XCTAssertEqual(models.first?.isActive, true)
    }

    func testMostConstrainedIncludesScopedModelLimit() throws {
        let snap = try decode(modernPayload)
        // Fable (66) binds over 5h (11) and weekly-all (37).
        XCTAssertEqual(snap.mostConstrained?.utilization, 66)
    }

    func testFallsBackToLegacyPerModelFields() throws {
        let legacy = """
            { "five_hour": { "utilization": 5 }, "seven_day": { "utilization": 10 },
              "seven_day_opus": { "utilization": 80, "resets_at": "2026-04-16T03:00:00Z" },
              "seven_day_sonnet": { "utilization": 20, "resets_at": "2026-04-16T03:00:00Z" } }
            """
        let snap = try decode(legacy)
        let models = snap.perModelWindows.map(\.name).sorted()
        XCTAssertEqual(models, ["Opus", "Sonnet"])
        XCTAssertEqual(snap.mostConstrained?.utilization, 80)
    }

    func testNoModelWindowsWhenNeitherPresent() throws {
        let snap = try decode(#"{ "five_hour": { "utilization": 3 } }"#)
        XCTAssertTrue(snap.perModelWindows.isEmpty)
    }

    func testUnknownScopedModelStillSurfaces() throws {
        // A future model we've never heard of must still render.
        let payload = """
            { "limits": [ { "kind": "weekly_scoped", "percent": 50, "is_active": true,
              "scope": { "model": { "display_name": "Mythos" } } } ] }
            """
        let snap = try decode(payload)
        XCTAssertEqual(snap.perModelWindows.first?.name, "Mythos")
    }
}
