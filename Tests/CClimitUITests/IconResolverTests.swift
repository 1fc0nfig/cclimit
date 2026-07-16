import CClimitCore
import XCTest

@testable import CClimitUI

final class IconResolverTests: XCTestCase {
    // 5h 36%, weekly 42%, Fable weekly 73% — Fable is the binding limit.
    private func snapshot(fable: Double? = 73) -> UsageSnapshot {
        var limits: [Limit] = []
        if let fable {
            limits.append(Limit(
                kind: "weekly_scoped", group: "weekly", percent: fable,
                resetsAt: Date(timeIntervalSinceReferenceDate: 800_000),
                isActive: true, severity: nil,
                scope: .init(model: .init(displayName: "Fable"))))
        }
        return UsageSnapshot(
            fiveHour: UsageWindow(
                utilization: 36, resetsAt: Date(timeIntervalSinceReferenceDate: 500_000)),
            sevenDay: UsageWindow(
                utilization: 42, resetsAt: Date(timeIntervalSinceReferenceDate: 900_000)),
            limits: limits.isEmpty ? nil : limits)
    }

    private func resolve(
        style: IconStyle,
        source: IconSource = .auto,
        composition: [BarItem] = BarComposition.makeDefault(),
        third: Bool = false,
        snapshot: UsageSnapshot?,
        seenModels: [String] = []
    ) -> IconDescriptor {
        IconResolver.resolve(
            style: style, source: source, composition: composition,
            thirdModelBar: third, snapshot: snapshot, seenModels: seenModels,
            now: Date(timeIntervalSinceReferenceDate: 400_000))
    }

    // MARK: - Stacked (the compact preset)

    func testStackedDefaultIsTwoBars() {
        let d = resolve(style: .dualBars, snapshot: snapshot())
        guard case .stacked(let bars) = d.content else { return XCTFail("expected stacked") }
        XCTAssertEqual(bars.map(\.name), ["5-hour", "weekly"])
        XCTAssertEqual(bars.map(\.value), [36, 42])
        XCTAssertEqual(d.summary, "5-hour + weekly")
    }

    func testStackedThirdBarAddsBindingModel() {
        let d = resolve(style: .dualBars, third: true, snapshot: snapshot())
        guard case .stacked(let bars) = d.content else { return XCTFail("expected stacked") }
        XCTAssertEqual(bars.count, 3)
        XCTAssertEqual(bars[2].name, "Fable weekly")
        XCTAssertEqual(bars[2].value, 73)
        XCTAssertEqual(d.summary, "5-hour + weekly + Fable weekly")
    }

    func testStackedThirdBarShowsBlankForSeenButMissingModel() {
        // Supplement unavailable (no per-model in snapshot) but Fable was seen before →
        // keep a third bar with a nil value so the menu bar shows it's pending, not gone.
        let d = resolve(style: .dualBars, third: true, snapshot: snapshot(fable: nil),
                        seenModels: ["Fable"])
        guard case .stacked(let bars) = d.content else { return XCTFail("expected stacked") }
        XCTAssertEqual(bars.count, 3)
        XCTAssertEqual(bars[2].name, "Fable weekly")
        XCTAssertNil(bars[2].value)
    }

    func testStackedThirdBarStaysTwoWhenNoModelEverSeen() {
        // No per-model data and nothing seen before → no invented third bar.
        let d = resolve(style: .dualBars, third: true, snapshot: snapshot(fable: nil))
        guard case .stacked(let bars) = d.content else { return XCTFail("expected stacked") }
        XCTAssertEqual(bars.count, 2)
    }

    func testStackedThirdBarRequiresTheToggle() {
        // Model present but toggle off → strictly two bars.
        let d = resolve(style: .dualBars, third: false, snapshot: snapshot())
        guard case .stacked(let bars) = d.content else { return XCTFail("expected stacked") }
        XCTAssertEqual(bars.count, 2)
    }

    func testStackedThirdBarRequiresAModel() {
        // Toggle on but no per-model window seen → two bars, not a phantom third.
        let d = resolve(style: .dualBars, third: true, snapshot: snapshot(fable: nil))
        guard case .stacked(let bars) = d.content else { return XCTFail("expected stacked") }
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(d.summary, "5-hour + weekly")
    }

    func testStackedNoSnapshotHasNilValues() {
        let d = resolve(style: .dualBars, third: true, snapshot: nil)
        guard case .stacked(let bars) = d.content else { return XCTFail("expected stacked") }
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars.map(\.value), [nil, nil])
    }

    func testStackedThirdPicksTheMostConstrainedModel() {
        var limits = [
            Limit(kind: "weekly_scoped", group: "weekly", percent: 20, resetsAt: nil,
                  isActive: false, severity: nil,
                  scope: .init(model: .init(displayName: "Opus"))),
            Limit(kind: "weekly_scoped", group: "weekly", percent: 73, resetsAt: nil,
                  isActive: true, severity: nil,
                  scope: .init(model: .init(displayName: "Fable"))),
        ]
        limits.shuffle()
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: nil),
            sevenDay: UsageWindow(utilization: 12, resetsAt: nil),
            limits: limits)
        let d = resolve(style: .dualBars, third: true, snapshot: snap)
        guard case .stacked(let bars) = d.content else { return XCTFail("expected stacked") }
        XCTAssertEqual(bars[2].name, "Fable weekly")
        XCTAssertEqual(bars[2].value, 73)
    }

    // MARK: - Inline composition

    func testInlineResolvesEachItemsWindow() {
        let items = [
            BarItem(ref: .fiveHour, showLabel: true, showValue: true),
            BarItem(ref: .model("Fable")),
        ]
        let d = resolve(style: .bars, composition: items, snapshot: snapshot())
        guard case .inline(let bars) = d.content else { return XCTFail("expected inline") }
        XCTAssertEqual(bars.map(\.value), [36, 73])
        XCTAssertEqual(bars.map(\.item), items)
        XCTAssertEqual(d.summary, "5-hour window + Fable weekly")
    }

    func testInlineUnknownModelResolvesNil() {
        let d = resolve(
            style: .bars, composition: [BarItem(ref: .model("Sonnet"))], snapshot: snapshot())
        guard case .inline(let bars) = d.content else { return XCTFail("expected inline") }
        XCTAssertEqual(bars.map(\.value), [nil])
    }

    // MARK: - Text styles

    func testPercentText() {
        let d = resolve(style: .percent, source: .fiveHour, snapshot: snapshot())
        guard case .text(let text, let value) = d.content else { return XCTFail("expected text") }
        XCTAssertEqual(text, "36%")
        XCTAssertEqual(value, 36)
        XCTAssertEqual(d.summary, "5-hour window")
    }

    func testPercentTimeAppendsCountdown() {
        let d = resolve(style: .percentTime, source: .fiveHour, snapshot: snapshot())
        guard case .text(let text, _) = d.content else { return XCTFail("expected text") }
        XCTAssertNotNil(text)
        XCTAssertTrue(text!.hasPrefix("36% · "), "got \(text!)")
    }

    func testTextNoSnapshotIsNil() {
        let d = resolve(style: .percent, snapshot: nil)
        guard case .text(let text, let value) = d.content else { return XCTFail("expected text") }
        XCTAssertNil(text)
        XCTAssertNil(value)
    }

    // MARK: - Single-value image styles + source naming

    func testAutoSourceNamesTheBindingWindow() {
        // Fable (73%) binds → the caption must say so, not a generic "auto".
        let d = resolve(style: .ring, source: .auto, snapshot: snapshot())
        guard case .image(let style, let value) = d.content else { return XCTFail("expected image") }
        XCTAssertEqual(style, .ring)
        XCTAssertEqual(value, 73)
        XCTAssertEqual(d.summary, "Fable weekly (most constrained)")
    }

    func testExplicitSource() {
        let d = resolve(style: .gauge, source: .weekly, snapshot: snapshot())
        guard case .image(_, let value) = d.content else { return XCTFail("expected image") }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(d.summary, "weekly cap")
    }
}
