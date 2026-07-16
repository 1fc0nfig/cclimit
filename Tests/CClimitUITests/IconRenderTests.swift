import AppKit
import CClimitCore
import XCTest

@testable import CClimitUI

/// Pixel-level tests of the drawn icon: bar counts, rail visibility on light AND dark
/// menu bars, and the color ramp. These are the checks the eye does in the menu bar.
final class IconRenderTests: XCTestCase {
    // MARK: - Helpers

    /// Draws the image over a solid backdrop (menu bars can be light or dark), optionally
    /// under an explicit NSAppearance so dynamic colors resolve like they would in situ.
    private func composite(
        _ image: NSImage, over backdrop: NSColor, appearance: NSAppearance.Name? = nil
    ) -> NSBitmapImageRep {
        let w = Int(image.size.width), h = Int(image.size.height)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let draw = {
            backdrop.setFill()
            NSRect(x: 0, y: 0, width: w, height: h).fill()
            image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        }
        if let appearance, let resolved = NSAppearance(named: appearance) {
            resolved.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    private func differs(
        _ rep: NSBitmapImageRep, _ x: Int, _ y: Int, from backdrop: (r: CGFloat, g: CGFloat, b: CGFloat),
        by threshold: CGFloat = 0.05
    ) -> Bool {
        let p = rgb(rep, x, y)
        return max(abs(p.r - backdrop.r), abs(p.g - backdrop.g), abs(p.b - backdrop.b)) > threshold
    }

    /// Counts contiguous vertical runs of pixels that differ from the backdrop in column x —
    /// i.e. how many bars are actually visible.
    private func bandCount(_ image: NSImage, over backdrop: NSColor, atX x: Int) -> Int {
        let rep = composite(image, over: backdrop)
        let bg = backdrop.usingColorSpace(.deviceRGB)!
        let bgc = (bg.redComponent, bg.greenComponent, bg.blueComponent)
        var bands = 0
        var inBand = false
        for y in 0..<rep.pixelsHigh {
            let hit = differs(rep, x, y, from: bgc)
            if hit && !inBand { bands += 1 }
            inBand = hit
        }
        return bands
    }

    // MARK: - Bar count: what the settings say is what the menu bar draws

    func testStackedTwoValuesDrawsTwoBars() {
        let image = IconRenderer.stackedBars(values: [36, 42], template: false, degraded: false)
        XCTAssertEqual(bandCount(image, over: .black, atX: 10), 2)
        XCTAssertEqual(bandCount(image, over: .white, atX: 10), 2)
    }

    func testStackedThreeValuesDrawsThreeBars() {
        let image = IconRenderer.stackedBars(values: [36, 42, 73], template: false, degraded: false)
        XCTAssertEqual(bandCount(image, over: .black, atX: 10), 3)
        XCTAssertEqual(bandCount(image, over: .white, atX: 10), 3)
    }

    // MARK: - Rail visibility (the empty track must read on light AND dark menu bars)

    func testEmptyRailIsVisibleOnDarkAndLight() {
        // Zero utilization → rail only. The old black-alpha rail vanished on dark menu bars.
        let image = IconRenderer.stackedBars(values: [0, 0], template: false, degraded: false)
        XCTAssertEqual(bandCount(image, over: .black, atX: 10), 2, "rail invisible on a dark menu bar")
        XCTAssertEqual(bandCount(image, over: .white, atX: 10), 2, "rail invisible on a light menu bar")
    }

    func testNilValueRailIsVisibleBothWays() {
        let image = IconRenderer.inlineComposition(
            [.init(item: BarItem(ref: .fiveHour), value: nil)], template: false, degraded: false)
        XCTAssertEqual(bandCount(image, over: .black, atX: 8), 1)
        XCTAssertEqual(bandCount(image, over: .white, atX: 8), 1)
    }

    // MARK: - Inline composition (must be ONE image — MenuBarExtra drops extra images)

    private func inline(_ items: [BarItem], values: [Double?]) -> [IconDescriptor.InlineBar] {
        zip(items, values).map { .init(item: $0, value: $1) }
    }

    /// Counts bars along a horizontal scanline — the inline layout is left-to-right.
    private func bandCountInRow(_ image: NSImage, over backdrop: NSColor, atY y: Int) -> Int {
        let rep = composite(image, over: backdrop)
        let bg = backdrop.usingColorSpace(.deviceRGB)!
        let bgc = (bg.redComponent, bg.greenComponent, bg.blueComponent)
        var bands = 0
        var inBand = false
        for x in 0..<rep.pixelsWide {
            let hit = differs(rep, x, y, from: bgc)
            if hit && !inBand { bands += 1 }
            inBand = hit
        }
        return bands
    }

    func testInlineCompositionDrawsEveryBar() {
        let image = IconRenderer.inlineComposition(
            inline([BarItem(ref: .fiveHour), BarItem(ref: .weekly), BarItem(ref: .model("Fable"))],
                   values: [46, 53, 95]),
            template: false, degraded: false)
        let midY = Int(image.size.height) / 2
        XCTAssertEqual(bandCountInRow(image, over: .black, atY: midY), 3)
        XCTAssertEqual(bandCountInRow(image, over: .white, atY: midY), 3)
    }

    func testInlineLabelsAndValuesWidenTheImage() {
        let bare = IconRenderer.inlineComposition(
            inline([BarItem(ref: .fiveHour)], values: [46]), template: false, degraded: false)
        let full = IconRenderer.inlineComposition(
            inline([BarItem(ref: .fiveHour, showLabel: true, showValue: true)], values: [46]),
            template: false, degraded: false)
        XCTAssertGreaterThan(full.size.width, bare.size.width + 10,
                             "label + value must actually be drawn into the image")
    }

    /// The original sin: text baked in literal black was invisible on dark menu bars.
    /// The text color must resolve at draw time against the ambient appearance.
    func testInlineTextAdaptsToMenuBarAppearance() {
        let image = IconRenderer.inlineComposition(
            inline([BarItem(ref: .fiveHour, showLabel: true, showValue: true)], values: [46]),
            template: false, degraded: false)

        func brightest(_ appearance: NSAppearance.Name, over backdrop: NSColor) -> CGFloat {
            let rep = composite(image, over: backdrop, appearance: appearance)
            var best: CGFloat = 0
            // Text lives right of the 16px bar; scan that region only.
            for x in 20..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    let p = rgb(rep, x, y)
                    best = max(best, (p.r + p.g + p.b) / 3)
                }
            }
            return best
        }

        XCTAssertGreaterThan(brightest(.darkAqua, over: .black), 0.6,
                             "text must render light on a dark menu bar")

        func darkest(_ appearance: NSAppearance.Name, over backdrop: NSColor) -> CGFloat {
            let rep = composite(image, over: backdrop, appearance: appearance)
            var best: CGFloat = 1
            for x in 20..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    let p = rgb(rep, x, y)
                    best = min(best, (p.r + p.g + p.b) / 3)
                }
            }
            return best
        }

        XCTAssertLessThan(darkest(.aqua, over: .white), 0.4,
                          "text must render dark on a light menu bar")
    }

    func testRingTrackIsVisibleBothWays() {
        let image = IconRenderer.single(style: .ring, value: 0, template: false, degraded: false)
        XCTAssertGreaterThan(bandCount(image, over: .black, atX: 10), 0)
        XCTAssertGreaterThan(bandCount(image, over: .white, atX: 10), 0)
    }

    // MARK: - Color ramp

    /// Samples inside the filled part of a single bar (left edge, vertical center).
    private func fillPixel(value: Double?, degraded: Bool = false) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let image = IconRenderer.single(style: .singleBar, value: value, template: false, degraded: degraded)
        let rep = composite(image, over: .black)
        return rgb(rep, 3, rep.pixelsHigh / 2)
    }

    func testFillIsGreenBelow70() {
        let p = fillPixel(value: 50)
        XCTAssertGreaterThan(p.g, p.r + 0.15, "expected green, got \(p)")
    }

    func testFillIsOrangeFrom70() {
        let p = fillPixel(value: 80)
        XCTAssertGreaterThan(p.r, p.g, "expected orange, got \(p)")
        XCTAssertGreaterThan(p.g, 0.35, "expected orange, not red: \(p)")
    }

    func testFillIsRedFrom90() {
        let p = fillPixel(value: 95)
        XCTAssertGreaterThan(p.r, 0.6, "expected red, got \(p)")
        XCTAssertLessThan(p.g, 0.35, "expected red, not orange: \(p)")
    }

    func testDegradedDrawsNoColoredFill() {
        // Health error + no data → the bar must not pretend a green reading.
        let p = fillPixel(value: 80, degraded: true)
        XCTAssertLessThan(abs(p.r - p.g), 0.1, "degraded fill must be neutral, got \(p)")
        XCTAssertLessThan(abs(p.g - p.b), 0.1, "degraded fill must be neutral, got \(p)")
    }

    func testDotWithoutDataIsNeutralNotGreen() {
        let image = IconRenderer.single(style: .dot, value: nil, template: false, degraded: false)
        let rep = composite(image, over: .black)
        let p = rgb(rep, rep.pixelsWide / 2, rep.pixelsHigh / 2)
        XCTAssertLessThan(abs(p.r - p.g), 0.1, "no-data dot must be neutral, got \(p)")
    }

    // MARK: - Spark (the logo as a clock-tick meter)

    /// Counts pixels that differ from the backdrop — a proxy for "how much of the spark
    /// is drawn / lit". More utilization → more lit rays → more non-backdrop pixels.
    private func drawnPixelCount(_ image: NSImage, over backdrop: NSColor, threshold: CGFloat) -> Int {
        let rep = composite(image, over: backdrop)
        let bg = backdrop.usingColorSpace(.deviceRGB)!
        let bgc = (bg.redComponent, bg.greenComponent, bg.blueComponent)
        var n = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where differs(rep, x, y, from: bgc, by: threshold) {
                n += 1
            }
        }
        return n
    }

    func testSparkRailVisibleWithoutData() {
        // No reading → all eight rays on the faint rail, on light AND dark menu bars.
        let image = IconRenderer.single(style: .spark, value: nil, template: false, degraded: false)
        XCTAssertGreaterThan(drawnPixelCount(image, over: .black, threshold: 0.05), 0,
                             "spark rail invisible on a dark menu bar")
        XCTAssertGreaterThan(drawnPixelCount(image, over: .white, threshold: 0.05), 0,
                             "spark rail invisible on a light menu bar")
    }

    func testSparkLitAreaGrowsWithUtilization() {
        // Only the strongly-colored (lit) pixels count — a high threshold ignores the rail.
        let low = IconRenderer.single(style: .spark, value: 20, template: false, degraded: false)
        let high = IconRenderer.single(style: .spark, value: 95, template: false, degraded: false)
        XCTAssertGreaterThan(drawnPixelCount(high, over: .black, threshold: 0.35),
                             drawnPixelCount(low, over: .black, threshold: 0.35),
                             "more of the spark should light up as the window fills")
    }

    func testSparkWarmsGreenToRed() {
        func litColor(_ value: Double) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let image = IconRenderer.single(style: .spark, value: value, template: false, degraded: false)
            let rep = composite(image, over: .black)
            // The 12-o'clock ray points straight up from center — sample just above center.
            return rgb(rep, rep.pixelsWide / 2, rep.pixelsHigh / 2 - 4)
        }
        let green = litColor(20)
        XCTAssertGreaterThan(green.g, green.r + 0.15, "spark should read green when low, got \(green)")
        let red = litColor(95)
        XCTAssertGreaterThan(red.r, 0.5, "spark should read red when near the cap, got \(red)")
        XCTAssertLessThan(red.g, 0.4, "spark should be red, not orange, near the cap: \(red)")
    }

    // MARK: - Template mode

    func testTemplateFlagFollowsMonochromeSetting() {
        XCTAssertTrue(IconRenderer.stackedBars(values: [1, 2], template: true, degraded: false).isTemplate)
        XCTAssertFalse(IconRenderer.stackedBars(values: [1, 2], template: false, degraded: false).isTemplate)
        XCTAssertTrue(IconRenderer.inlineComposition(
            [.init(item: BarItem(ref: .fiveHour), value: 5)], template: true, degraded: false).isTemplate)
        XCTAssertTrue(IconRenderer.single(style: .ring, value: 5, template: true, degraded: false).isTemplate)
        // Degraded renders template so the system dims it like a disabled item.
        XCTAssertTrue(IconRenderer.stackedBars(values: [nil, nil], template: false, degraded: true).isTemplate)
    }
}
