import XCTest

@testable import CClimitCore

final class BarConfigTests: XCTestCase {
    func testBarWindowRoundTrips() {
        for ref: BarWindow in [.fiveHour, .weekly, .model("Fable")] {
            XCTAssertEqual(BarWindow.parse(ref.storage), ref)
        }
        XCTAssertNil(BarWindow.parse("bogus"))
    }

    func testBarItemRoundTrips() {
        let item = BarItem(ref: .model("Fable"), showLabel: true, showValue: true)
        XCTAssertEqual(BarItem.parse(item.storage), item)
    }

    func testBarItemDefaultsFlagsOff() {
        let parsed = BarItem.parse("fiveHour")
        XCTAssertEqual(parsed, BarItem(ref: .fiveHour, showLabel: false, showValue: false))
    }

    func testCompositionDefaultIsFiveHourAndWeekly() {
        let items = BarComposition.parse("")
        XCTAssertEqual(items.map(\.ref), [.fiveHour, .weekly])
    }

    func testCompositionRoundTrips() {
        let items = [
            BarItem(ref: .fiveHour, showLabel: true, showValue: false),
            BarItem(ref: .model("Fable"), showLabel: true, showValue: true),
            BarItem(ref: .weekly),
        ]
        let restored = BarComposition.parse(BarComposition.serialize(items))
        XCTAssertEqual(restored, items)
    }

    func testAddableExcludesPresent() {
        let existing = [BarItem(ref: .fiveHour)]
        let addable = BarComposition.addable(existing: existing, seenModels: ["Fable", "Opus"])
        XCTAssertEqual(addable, [.weekly, .model("Fable"), .model("Opus")])
    }

    func testShortLabels() {
        XCTAssertEqual(BarWindow.fiveHour.shortLabel, "5h")
        XCTAssertEqual(BarWindow.weekly.shortLabel, "Wk")
        XCTAssertEqual(BarWindow.model("Fable").shortLabel, "Fable")
    }

    func testWindowResolution() {
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 11, resetsAt: nil),
            sevenDay: UsageWindow(utilization: 37, resetsAt: nil),
            limits: [Limit(kind: "weekly_scoped", group: "weekly", percent: 66, resetsAt: nil,
                           isActive: true, severity: nil,
                           scope: Limit.Scope(model: Limit.Scope.Model(displayName: "Fable")))])
        XCTAssertEqual(BarWindow.fiveHour.window(in: snap)?.utilization, 11)
        XCTAssertEqual(BarWindow.weekly.window(in: snap)?.utilization, 37)
        XCTAssertEqual(BarWindow.model("Fable").window(in: snap)?.utilization, 66)
    }
}
