import AppKit
import CClimitCore

/// Draws the image parts of the menu bar icon. Text (labels/values) is never baked in —
/// SwiftUI renders it so it adapts to the menu bar's own color.
public enum IconRenderer {
    public static let size = NSSize(width: 20, height: 16)

    /// Empty track behind fills. Mid-gray on purpose: the menu bar can be light or dark
    /// (it follows the wallpaper, not just the theme) and a black- or white-based rail
    /// disappears on one of them. 50% gray at ~45% opacity reads on both.
    static let rail = NSColor(white: 0.5, alpha: 0.45)

    static func color(forUtilization utilization: Double) -> NSColor {
        switch utilization {
        case ..<70: return .systemGreen
        case ..<90: return .systemOrange
        default: return .systemRed
        }
    }

    /// The compact stacked preset: 2 or 3 bars, first value on top. Bar height shrinks to
    /// keep three within the ~16px menu bar ceiling (5px each for two, 4px for three).
    public static func stackedBars(values: [Double?], template: Bool, degraded: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let count = max(values.count, 1)
            let gap: CGFloat = count >= 3 ? 2 : 3
            let barHeight: CGFloat = count >= 3 ? 4 : 5
            let totalHeight = barHeight * CGFloat(count) + gap * CGFloat(count - 1)
            let originY = (rect.height - totalHeight) / 2
            for (i, value) in values.enumerated() {
                let y = originY + (barHeight + gap) * CGFloat(count - 1 - i)
                drawBar(value: value,
                        in: NSRect(x: 1, y: y, width: rect.width - 2, height: barHeight),
                        template: template, degraded: degraded)
            }
            return true
        }
        image.isTemplate = template || degraded
        return image
    }

    /// The full inline `bars` composition — labels, bars, and values — as ONE image.
    ///
    /// One image is a hard requirement: MenuBarExtra flattens its label to a single
    /// image + text, so an HStack of per-bar images silently drops all but the first.
    /// Text is drawn with dynamic NSColors (labelColor & friends) that resolve at draw
    /// time against the menu bar's appearance, so it stays legible on light and dark.
    public static func inlineComposition(
        _ bars: [IconDescriptor.InlineBar], template: Bool, degraded: Bool
    ) -> NSImage {
        let barWidth: CGFloat = 16
        let barHeight: CGFloat = 6
        let height: CGFloat = 16
        let innerGap: CGFloat = 4   // label ↔ bar ↔ value
        let groupGap: CGFloat = 7   // between metrics

        let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)

        func valueString(_ value: Double?) -> String {
            value.map { "\(Int($0.rounded()))%" } ?? "—"
        }
        func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
            ceil(text.size(withAttributes: [.font: font]).width)
        }

        var width: CGFloat = 0
        for (i, bar) in bars.enumerated() {
            if i > 0 { width += groupGap }
            if bar.item.showLabel { width += textWidth(bar.item.ref.shortLabel, labelFont) + innerGap }
            width += barWidth
            if bar.item.showValue { width += innerGap + textWidth(valueString(bar.value), valueFont) }
        }
        width = max(width, barWidth)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            func draw(text: String, font: NSFont, color: NSColor, atX x: CGFloat) -> CGFloat {
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: attrs)
                return ceil(size.width)
            }
            var x: CGFloat = 0
            for (i, bar) in bars.enumerated() {
                if i > 0 { x += groupGap }
                if bar.item.showLabel {
                    let color = template ? NSColor.black : .labelColor
                    x += draw(text: bar.item.ref.shortLabel, font: labelFont, color: color, atX: x) + innerGap
                }
                drawBar(value: bar.value,
                        in: NSRect(x: x, y: (height - barHeight) / 2, width: barWidth, height: barHeight),
                        template: template, degraded: degraded)
                x += barWidth
                if bar.item.showValue {
                    x += innerGap
                    let color: NSColor = if template {
                        .black
                    } else if let value = bar.value, !degraded {
                        UsageColor.numberNSColor(value)
                    } else {
                        .labelColor
                    }
                    x += draw(text: valueString(bar.value), font: valueFont, color: color, atX: x)
                }
            }
            return true
        }
        image.isTemplate = template || degraded
        return image
    }

    /// The single-value image styles (singleBar / gauge / ring / dot). Any other style
    /// falls back to a dot — used e.g. by text styles before the first reading.
    public static func single(style: IconStyle, value: Double?, template: Bool, degraded: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            switch style {
            case .singleBar:
                let barHeight: CGFloat = 6
                drawBar(value: value,
                        in: NSRect(x: 1, y: (rect.height - barHeight) / 2,
                                   width: rect.width - 2, height: barHeight),
                        template: template, degraded: degraded)
            case .gauge:
                drawGauge(rect: rect, value: value, template: template, degraded: degraded, ring: false)
            case .ring:
                drawGauge(rect: rect, value: value, template: template, degraded: degraded, ring: true)
            case .spark:
                drawSpark(rect: rect, value: value, template: template, degraded: degraded)
            default:
                drawDot(rect: rect, value: value, template: template, degraded: degraded)
            }
            return true
        }
        image.isTemplate = template || degraded
        return image
    }

    // MARK: - Primitives

    private static func drawBar(value: Double?, in frame: NSRect, template: Bool, degraded: Bool) {
        let radius = frame.height / 2
        rail.setFill()
        NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()

        guard let value, value > 0, !degraded else { return }
        let clamped = min(max(value, 0), 100)
        let fillWidth = max(frame.height, frame.width * clamped / 100)
        let fillRect = NSRect(x: frame.minX, y: frame.minY, width: fillWidth, height: frame.height)
        (template ? NSColor.black : color(forUtilization: clamped)).setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius).fill()
    }

    /// Shared arc renderer: `ring` draws a full donut; otherwise a 270° needle gauge.
    private static func drawGauge(rect: NSRect, value: Double?, template: Bool, degraded: Bool, ring: Bool) {
        let clamped = min(max(value ?? 0, 0), 100)
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let outerR = min(rect.width, rect.height) / 2 - 1
        let lineWidth: CGFloat = ring ? 2.5 : 2.0
        let r = outerR - lineWidth / 2

        let (start, sweep): (CGFloat, CGFloat) = ring ? (90, 360) : (225, 270)
        let fillColor = degraded ? rail : (template ? NSColor.black : color(forUtilization: clamped))

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: r, startAngle: start, endAngle: start - sweep, clockwise: true)
        track.lineWidth = lineWidth
        track.lineCapStyle = .round
        rail.setStroke()
        track.stroke()

        guard !degraded, value != nil, clamped > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: r, startAngle: start,
                      endAngle: start - sweep * clamped / 100, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        fillColor.setStroke()
        arc.stroke()
    }

    /// The CClimit spark (eight hand-drawn rays), rendered as a clock-tick meter.
    ///
    /// The rays light up clockwise from 12 o'clock — one "tick" per 12.5% of the binding
    /// window, so the glyph fills as the day burns through the limit. The whole spark shares
    /// the current usage color, so it also *warms* green → amber → red as you close on the
    /// cap: the limit, drawn into the mark itself. Unlit rays stay on the faint rail.
    ///
    /// Ray table + geometry are ported from the web `Asterisk` (24px box, inner 2.6,
    /// span 7.4), scaled to fit the ~16px menu bar. Angles are SVG y-down (270° = up);
    /// we flip y when placing points so 12 o'clock reads up in AppKit's y-up space.
    private static let sparkRays: [(angle: Double, length: Double)] = [
        (0, 1), (45, 0.72), (90, 0.94), (135, 0.7),
        (180, 1), (225, 0.74), (270, 0.94), (315, 0.68),
    ]
    /// Clockwise from 12 o'clock — the order the ticks fill in.
    private static let sparkClockwise: [Double] = [270, 315, 0, 45, 90, 135, 180, 225]

    private static func drawSpark(rect: NSRect, value: Double?, template: Bool, degraded: Bool) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let scale = (min(rect.width, rect.height) / 2 - 0.5) / 10  // web outer max is 10 in a 24 box
        let inner = 2.6 * scale
        let span = 7.4 * scale
        let lineWidth: CGFloat = 1.9

        let clamped = min(max(value ?? 0, 0), 100)
        let hasReading = value != nil && !degraded
        let litUnits = clamped / 12.5   // one ray per 12.5%
        let litColor = template ? NSColor.black : color(forUtilization: clamped)

        for (angle, length) in sparkRays {
            let rad = angle * .pi / 180
            let outer = inner + span * length
            let p1 = NSPoint(x: center.x + inner * CGFloat(cos(rad)),
                             y: center.y - inner * CGFloat(sin(rad)))
            let p2 = NSPoint(x: center.x + outer * CGFloat(cos(rad)),
                             y: center.y - outer * CGFloat(sin(rad)))
            let path = NSBezierPath()
            path.move(to: p1)
            path.line(to: p2)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round

            // Fullness of this ray: 1 past the fill line, 0 before it, eased across the
            // boundary tick so the "hand" sweeps onto the next ray instead of snapping.
            let k = sparkClockwise.firstIndex(of: angle) ?? 0
            let fullness = hasReading ? min(max(litUnits - Double(k), 0), 1) : 0
            if fullness < 1 {
                // Faint rail underneath — the headroom left in the window.
                rail.setStroke()
                path.stroke()
            }
            if fullness > 0 {
                // Lit color on top, eased in across the boundary tick.
                litColor.withAlphaComponent(CGFloat(fullness)).setStroke()
                path.stroke()
            }
        }
    }

    private static func drawDot(rect: NSRect, value: Double?, template: Bool, degraded: Bool) {
        let d: CGFloat = 8
        let frame = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        if degraded || value == nil {
            rail.setFill()
        } else {
            (template ? NSColor.black : color(forUtilization: min(max(value!, 0), 100))).setFill()
        }
        NSBezierPath(ovalIn: frame).fill()
    }
}
