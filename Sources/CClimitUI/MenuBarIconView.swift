import CClimitCore
import SwiftUI

/// Renders an IconDescriptor. This exact view is the menu bar label AND the Settings live
/// preview — one code path, so what you preview is what you get.
public struct MenuBarIconView: View {
    let descriptor: IconDescriptor
    let template: Bool
    let degraded: Bool

    public init(descriptor: IconDescriptor, template: Bool, degraded: Bool) {
        self.descriptor = descriptor
        self.template = template
        self.degraded = degraded
    }

    public var body: some View {
        switch descriptor.content {
        case .stacked(let bars):
            Image(nsImage: IconRenderer.stackedBars(
                values: bars.map(\.value), template: template, degraded: degraded))

        case .inline(let bars):
            // One image on purpose: MenuBarExtra flattens its label to a single image,
            // so composing per-bar images in an HStack drops all but the first.
            Image(nsImage: IconRenderer.inlineComposition(
                bars, template: template, degraded: degraded))

        case .image(let style, let value):
            Image(nsImage: IconRenderer.single(
                style: style, value: value, template: template, degraded: degraded))

        case .text(let text, let value):
            if let text {
                // An image, not a Text: MenuBarExtra redraws a Text label in its own font
                // and as a template, so it came out too big and never took a color.
                Image(nsImage: IconRenderer.text(
                    text, value: value, template: template, degraded: degraded))
            } else {
                // No reading yet — fall back to a neutral dot.
                Image(nsImage: IconRenderer.single(
                    style: .dot, value: nil, template: template, degraded: degraded))
            }
        }
    }
}
