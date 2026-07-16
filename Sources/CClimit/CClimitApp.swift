import AppKit
import CClimitCore
import CClimitUI
import SwiftUI

@main
struct CClimitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @StateObject private var updater = UpdaterViewModel()
    @AppStorage("iconTemplate") private var iconTemplate = false

    @AppStorage("iconStyle") private var iconStyleRaw = IconStyle.spark.rawValue
    @AppStorage("iconSource") private var iconSourceRaw = IconSource.auto.storage

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: state)
        } label: {
            MenuBarLabel(
                state: state,
                style: IconStyle(rawValue: iconStyleRaw) ?? .spark,
                source: IconSource.parse(iconSourceRaw),
                template: iconTemplate
            )
            .task { state.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(updater)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug: render icon variants to a dir and exit — lets us battle-test the glyphs
        // without pixel-hunting a crowded menu bar. `CCLIMIT_RENDER_ICON=/dir open …`.
        if let dir = ProcessInfo.processInfo.environment["CCLIMIT_RENDER_ICON"] {
            IconDebug.dump(to: dir)
            NSApp.terminate(nil)
            return
        }
        // Menu-bar-only. The bundle sets LSUIElement; this covers bare `swift run`.
        NSApp.setActivationPolicy(.accessory)
    }
}

enum IconDebug {
    /// Renders each style at a sample (5h 36, weekly 42, Fable 73) at 6× so we can eyeball it.
    static func dump(to dir: String) {
        let scale: CGFloat = 6
        func save(_ image: NSImage, _ name: String, on backdrop: NSColor = .black) {
            let target = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let scaled = NSImage(size: target, flipped: false) { rect in
                backdrop.setFill(); rect.fill() // menu-bar-like backdrop
                image.draw(in: rect)
                return true
            }
            guard let tiff = scaled.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        let f = 36.0, w = 42.0, m = 73.0
        save(IconRenderer.stackedBars(values: [f, w], template: false, degraded: false), "dualBars.png")
        save(IconRenderer.stackedBars(values: [f, w, m], template: false, degraded: false), "tripleBars.png")
        save(IconRenderer.stackedBars(values: [f, w], template: false, degraded: false), "dualBars-light.png", on: .white)
        save(IconRenderer.single(style: .ring, value: m, template: false, degraded: false), "ring.png")
        save(IconRenderer.single(style: .gauge, value: m, template: false, degraded: false), "gauge.png")
    }
}

/// The menu bar label: resolves the icon descriptor from settings + live state and renders
/// it via the same MenuBarIconView the Settings preview uses.
private struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    let style: IconStyle
    let source: IconSource
    let template: Bool

    @AppStorage("barComposition") private var barCompositionRaw = ""
    @AppStorage("dualBarsThirdModel") private var dualBarsThirdModel = false

    private var degraded: Bool { state.health.isError && state.snapshot == nil }

    var body: some View {
        MenuBarIconView(
            descriptor: IconResolver.resolve(
                style: style,
                source: source,
                composition: BarComposition.parse(barCompositionRaw),
                thirdModelBar: dualBarsThirdModel,
                snapshot: state.snapshot,
                seenModels: state.seenModelNames),
            template: template,
            degraded: degraded)
    }
}
