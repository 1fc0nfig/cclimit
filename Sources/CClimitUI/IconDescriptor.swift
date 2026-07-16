import CClimitCore
import Foundation

/// Everything the menu bar icon shows, resolved from settings + the live snapshot.
///
/// This is the single source of truth: the menu bar label, the Settings live preview, and
/// the "Now showing …" caption all render from the same descriptor, so the preview cannot
/// drift from reality — there is no second code path to drift.
public struct IconDescriptor: Equatable {
    public struct Bar: Equatable {
        /// Short human name for captions ("5-hour", "weekly", "Fable weekly").
        public let name: String
        public let value: Double?

        public init(name: String, value: Double?) {
            self.name = name
            self.value = value
        }
    }

    public struct InlineBar: Equatable {
        public let item: BarItem
        public let value: Double?

        public init(item: BarItem, value: Double?) {
            self.item = item
            self.value = value
        }
    }

    public enum Content: Equatable {
        case stacked([Bar])                 // the compact stacked preset (2 or 3 bars)
        case inline([InlineBar])            // the configurable composition
        case image(IconStyle, Double?)      // singleBar / gauge / ring / dot
        case text(String?, Double?)         // rendered string + the utilization behind it
    }

    public let content: Content
    /// What the icon reflects, for the Settings caption ("5-hour + weekly + Fable weekly").
    public let summary: String

    public init(content: Content, summary: String) {
        self.content = content
        self.summary = summary
    }
}

public enum IconResolver {
    public static func resolve(
        style: IconStyle,
        source: IconSource,
        composition: [BarItem],
        thirdModelBar: Bool,
        snapshot: UsageSnapshot?,
        now: Date = Date()
    ) -> IconDescriptor {
        switch style {
        case .dualBars:
            var bars = [
                IconDescriptor.Bar(name: "5-hour", value: snapshot?.fiveHour?.utilization),
                IconDescriptor.Bar(name: "weekly", value: snapshot?.sevenDay?.utilization),
            ]
            if thirdModelBar, let third = mostConstrainedModel(in: snapshot) {
                bars.append(third)
            }
            return IconDescriptor(
                content: .stacked(bars),
                summary: bars.map(\.name).joined(separator: " + "))

        case .bars:
            let inline = composition.map { item in
                IconDescriptor.InlineBar(
                    item: item,
                    value: snapshot.flatMap { item.ref.window(in: $0)?.utilization })
            }
            return IconDescriptor(
                content: .inline(inline),
                summary: composition.map(\.ref.longLabel).joined(separator: " + "))

        case .percent, .percentTime:
            let window = snapshot.flatMap { source.binding(in: $0) }
            let value = window?.utilization
            var text = value.map { Format.percent($0) }
            if style == .percentTime, text != nil, let reset = window?.resetsAt {
                text! += " · \(Format.compactCountdown(to: reset, from: now))"
            }
            return IconDescriptor(
                content: .text(text, value),
                summary: sourceLabel(source, in: snapshot))

        case .singleBar, .gauge, .ring, .dot, .spark:
            let value = snapshot.flatMap { source.binding(in: $0)?.utilization }
            return IconDescriptor(
                content: .image(style, value),
                summary: sourceLabel(source, in: snapshot))
        }
    }

    /// The per-model window closest to its cap (e.g. Fable) — the optional third stacked bar.
    private static func mostConstrainedModel(in snapshot: UsageSnapshot?) -> IconDescriptor.Bar? {
        let candidates = (snapshot?.perModelWindows ?? []).compactMap { model in
            model.window.utilization.map { (name: model.name, value: $0) }
        }
        guard let top = candidates.max(by: { $0.value < $1.value }) else { return nil }
        return IconDescriptor.Bar(name: "\(top.name) weekly", value: top.value)
    }

    /// Names the window a source resolves to, so "most constrained" isn't a mystery.
    private static func sourceLabel(_ source: IconSource, in snapshot: UsageSnapshot?) -> String {
        switch source {
        case .fiveHour: return "5-hour window"
        case .weekly: return "weekly cap"
        case .model(let name): return "\(name) weekly"
        case .auto:
            guard let snapshot else { return "most constrained limit" }
            let binding = snapshot.mostConstrained?.utilization
            if binding == snapshot.fiveHour?.utilization { return "5-hour window (most constrained)" }
            if let model = snapshot.perModelWindows.first(where: { $0.window.utilization == binding }) {
                return "\(model.name) weekly (most constrained)"
            }
            return "weekly cap (most constrained)"
        }
    }
}
