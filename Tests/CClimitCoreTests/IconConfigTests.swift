import XCTest

@testable import CClimitCore

final class IconConfigTests: XCTestCase {
    let snap = UsageSnapshot(
        fiveHour: UsageWindow(utilization: 11, resetsAt: nil),
        sevenDay: UsageWindow(utilization: 37, resetsAt: nil),
        limits: [
            Limit(kind: "weekly_scoped", group: "weekly", percent: 66, resetsAt: nil,
                  isActive: true, severity: "normal",
                  scope: Limit.Scope(model: Limit.Scope.Model(displayName: "Fable")))
        ])

    func testSourceRoundTrips() {
        for source: IconSource in [.auto, .fiveHour, .weekly, .model("Fable")] {
            XCTAssertEqual(IconSource.parse(source.storage), source)
        }
    }

    func testUnknownStorageDefaultsToAuto() {
        XCTAssertEqual(IconSource.parse("garbage"), .auto)
    }

    func testBindingResolvesEachSource() {
        XCTAssertEqual(IconSource.auto.binding(in: snap)?.utilization, 66)      // Fable binds
        XCTAssertEqual(IconSource.fiveHour.binding(in: snap)?.utilization, 11)
        XCTAssertEqual(IconSource.weekly.binding(in: snap)?.utilization, 37)
        XCTAssertEqual(IconSource.model("Fable").binding(in: snap)?.utilization, 66)
        XCTAssertNil(IconSource.model("Nonexistent").binding(in: snap))
    }

    func testDualBarsIgnoresSourceOthersDont() {
        XCTAssertFalse(IconStyle.dualBars.usesSource)
        XCTAssertTrue(IconStyle.singleBar.usesSource)
        XCTAssertTrue(IconStyle.ring.usesSource)
    }

    func testTextStyles() {
        XCTAssertTrue(IconStyle.percent.isText)
        XCTAssertTrue(IconStyle.percentTime.isText)
        XCTAssertFalse(IconStyle.gauge.isText)
    }
}

final class SectionLayoutTests: XCTestCase {
    func testDefaultOrderWhenNothingStored() {
        let order = SectionLayout.ordered(stored: [], seenModels: ["Fable"])
        XCTAssertEqual(order, ["fiveHour", "weekly", "model:Fable", "forecast", "attribution"])
    }

    func testStoredOrderIsHonored() {
        let stored = ["forecast", "weekly", "fiveHour", "attribution"]
        let order = SectionLayout.ordered(stored: stored, seenModels: [])
        XCTAssertEqual(order.prefix(4).map { $0 }, stored)
    }

    func testNewModelIsAppendedNotLost() {
        // User reordered; then Fable appears for the first time.
        let stored = ["weekly", "fiveHour", "forecast", "attribution"]
        let order = SectionLayout.ordered(stored: stored, seenModels: ["Fable"])
        XCTAssertEqual(order.prefix(4).map { $0 }, stored)
        XCTAssertTrue(order.contains("model:Fable"))
    }

    func testStaleSectionsAreDropped() {
        let stored = ["fiveHour", "model:GoneModel", "weekly"]
        let order = SectionLayout.ordered(stored: stored, seenModels: [])
        XCTAssertFalse(order.contains("model:GoneModel"))
    }

    func testDisplayNames() {
        XCTAssertEqual(SectionLayout.displayName("fiveHour"), "5-hour window")
        XCTAssertEqual(SectionLayout.displayName("model:Fable"), "Fable (weekly)")
    }
}
