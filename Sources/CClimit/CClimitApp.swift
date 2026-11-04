import AppKit
import CClimitCore
import CClimitUI
import Combine
import SwiftUI

@main
struct CClimitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @StateObject private var updater = UpdaterViewModel()
    @AppStorage("iconTemplate") private var iconTemplate = false

    @AppStorage("iconStyle") private var iconStyleRaw = IconStyle.spark.rawValue
    @AppStorage("iconSource") private var iconSourceRaw = IconSource.auto.storage

    init() {
        // A write to a child that already exited (a `claude` that died at start) must fail
        // with EPIPE, not kill the whole app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
    }

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
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["CCLIMIT_RENDER_POPOVER"] {
            PopoverDebug.dump(to: dir)
            NSApp.terminate(nil)
            return
        }
        #endif
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

#if DEBUG
@MainActor
enum PopoverDebug {
    /// Renders the popover with demo accounts, one PNG per selection, light and dark. Goes
    /// through a real window so AppKit controls (the segmented switcher) draw too.
    static func dump(to dir: String) {
        if ProcessInfo.processInfo.environment["CCLIMIT_RENDER_REAL"] != nil {
            dumpReal(to: dir)
            return
        }
        UserDefaults.standard.set(AttributionRange.today.rawValue, forKey: "attributionRange")
        let state = AppState()
        state.installDemoAccounts()
        let selections = [AppState.allID] + state.monitors.map(\.id)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for selection in selections {
                state.selection = selection
                if ProcessInfo.processInfo.environment["CCLIMIT_RENDER_LIVE"] != nil {
                    let name = "live-\(selection)-\(appearance == .aqua ? "light" : "dark").png"
                    captureLive(PopoverView(state: state), appearance: appearance,
                                to: URL(fileURLWithPath: dir).appendingPathComponent(name))
                    continue
                }
                let host = NSHostingView(rootView: PopoverView(state: state)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: appearance)
                let size = host.fittingSize
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                    backing: .buffered, defer: false)
                window.appearance = host.appearance
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let name = "popover-\(selection)-\(appearance == .aqua ? "light" : "dark").png"
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
        render(AccountsSettings().environmentObject(state).frame(width: 480, height: 620),
               to: URL(fileURLWithPath: dir).appendingPathComponent("settings-accounts.png"))

        // The Add Account sheet: the name form, a refused name, then the waiting state.
        let out = URL(fileURLWithPath: dir)
        let sheetBackground = Color(nsColor: .windowBackgroundColor)
        render(AddAccountSheet(prefill: "Team").environmentObject(state).background(sheetBackground),
               to: out.appendingPathComponent("sheet-add-account.png"))
        render(AddAccountSheet(prefill: "Personal").environmentObject(state).background(sheetBackground),
               to: out.appendingPathComponent("sheet-add-account-duplicate.png"))
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-work")
        state.setDemoPendingLogin(PendingLogin(name: "Work", folder: folder, phase: .waiting))
        render(AddAccountSheet().environmentObject(state).background(sheetBackground),
               to: out.appendingPathComponent("sheet-add-account-waiting.png"))
        state.setDemoPendingLogin(PendingLogin(name: "Work", folder: folder, phase: .added(label: "matyas@acme.com")))
        render(AddAccountSheet().environmentObject(state).background(sheetBackground),
               to: out.appendingPathComponent("sheet-add-account-added.png"))
        state.setDemoPendingLogin(nil)
    }

    /// The popover on this Mac's real accounts and transcripts: discovery, proxy detection,
    /// and project stats, rendered once every selection's numbers landed (or after 90 s).
    private static func dumpReal(to dir: String) {
        let state = AppState()
        state.start()
        let deadline = Date().addingTimeInterval(90)
        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        spin(10)
        let selections = [AppState.allID] + state.visibleMonitors.map(\.id)
        for selection in selections {
            state.selection = selection
            state.refreshAttributionIfStale()
            while Date() < deadline {
                spin(1)
                let targets = state.showsPool ? state.visibleMonitors : state.selectedMonitor.map { [$0] } ?? []
                let range = AppState.attributionRange(for: targets)
                let ready = targets.allSatisfy { $0.report(range: range, page: 0) != nil }
                    && (!state.showsProxyTranscripts(for: targets)
                        || state.proxyTranscripts.report(
                            range: range, span: AppState.attributionSpan(range: range, page: 0, for: targets)) != nil)
                if ready { break }
                state.refreshAttributionIfStale()
            }
            spin(1)
            render(PopoverView(state: state).background(Color(nsColor: .windowBackgroundColor)),
                   to: URL(fileURLWithPath: dir).appendingPathComponent("real-\(selection).png"))
        }
    }

    /// Shows the popover on screen over a menu-like material and captures the composited
    /// window, so glass and system controls draw as they do live. Needs screen recording
    /// permission for the calling terminal.
    private static func captureLive(_ view: some View, appearance: NSAppearance.Name, to url: URL) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        host.frame = effect.bounds
        effect.addSubview(host)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let window = KeyableWindow(
            contentRect: NSRect(x: screen.maxX - size.width - 40, y: screen.maxY - size.height - 8,
                                width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.appearance = NSAppearance(named: appearance)
        window.contentView = effect
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try? capture.run()
        capture.waitUntilExit()
        window.orderOut(nil)
    }

    /// A borderless window that can turn key, so controls draw in their active colors.
    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private static func render(_ view: some View, to url: URL) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif

/// The menu bar label: resolves the icon descriptor from settings + live state and renders
/// it via the same MenuBarIconView the Settings preview uses.
private struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    let style: IconStyle
    let source: IconSource
    let template: Bool

    @AppStorage("barComposition") private var barCompositionRaw = ""
    @AppStorage("dualBarsThirdModel") private var dualBarsThirdModel = false

    /// The percent+time style prints a countdown, which would otherwise only be redrawn when a
    /// poll changes the snapshot — up to 5 minutes of drift. A minute timer advances `now`.
    /// Not a TimelineView: inside a MenuBarExtra label it re-rendered in a tight loop
    /// (100% CPU, the main thread never got to start polling).
    @State private var now = Date()
    private let minuteTick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var degraded: Bool { state.health.isError && state.snapshot == nil }

    var body: some View {
        MenuBarIconView(
            descriptor: IconResolver.resolve(
                style: style,
                source: source,
                composition: BarComposition.parse(barCompositionRaw),
                thirdModelBar: dualBarsThirdModel,
                snapshot: state.snapshot,
                seenModels: state.seenModelNames,
                now: now),
            template: template,
            degraded: degraded)
        .onReceive(minuteTick) { now = $0 }
    }
}
