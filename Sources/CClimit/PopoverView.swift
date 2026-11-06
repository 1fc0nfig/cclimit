import CClimitCore
import CClimitUI
import Charts
import Combine
import SwiftUI

struct PopoverView: View {
    @ObservedObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    @State private var now = Date()
    @State private var hostWindow = WindowHandle()
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        // Every "resets in …" / "updated … ago" string is relative to the wall clock, but
        // SwiftUI only re-runs a row's body when that row's data changes — an untouched
        // window would keep the countdown it was first drawn with, so the popover showed
        // three rows each frozen at a different minute. One `now`, advanced every 15 s, is
        // handed down the whole tree so the clock text stays true. (A timer, not a
        // TimelineView: that looped at 100% CPU in the menu bar label.)
        content(now: now)
        // The MenuBarExtra window grows with its content but never shrinks back. Smaller
        // content then sits centered in the old height, with an empty band above it. So the
        // content's own height drives the window, top edge under the menu bar.
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { fitWindow(to: geo.size.height) }
                .onChange(of: geo.size.height) { _, height in fitWindow(to: height) }
        })
        .background(WindowReader(handle: hostWindow))
        // If the window is ever taller than the content, the content stays at the top.
        .frame(maxHeight: .infinity, alignment: .top)
        .onReceive(tick) { now = $0 }
        .onAppear {
            now = Date()
            state.refreshOnOpen()
            state.refreshAttributionIfStale()
        }
        // A MenuBarExtra window keeps its view alive between opens, so `onAppear` fires only
        // the first time. The window turning key marks every later open.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow.window else { return }
            // Where the system opened it, under the icon: later resizes keep this left edge.
            hostWindow.left = window.frame.minX
            PopoverAnchor.pin(window, height: hostWindow.contentHeight, left: hostWindow.left)
            now = Date()
            state.refreshOnOpen()
            state.refreshAttributionIfStale()
        }
        // AppKit keeps a window's bottom edge when its content changes height, so a section
        // that grows or shrinks after opening (stats landing, another account) would pull the
        // popover off the menu bar. Pin the top edge where the system placed it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow.window else { return }
            // Only the edges: the height is `fitWindow`'s job.
            PopoverAnchor.pin(window, height: nil, left: hostWindow.left)
        }
        .onChange(of: state.selection) { _, _ in state.refreshAttributionIfStale() }
    }

    private func fitWindow(to height: CGFloat) {
        guard height > 0 else { return }
        hostWindow.contentHeight = height
        if let window = hostWindow.window {
            PopoverAnchor.pin(window, height: height, left: hostWindow.left)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            if let proxy = state.proxySuggestion {
                ProxySuggestion(url: proxy) {
                    SettingsTab.open(.accounts)
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                } onDismiss: {
                    state.dismissProxySuggestion()
                }
            }
            if state.isMultiAccount {
                AccountSwitcher(state: state)
            }

            if let monitor = state.selectedMonitor {
                AccountDetail(
                    monitor: monitor, showsIdentity: state.isMultiAccount, now: now,
                    pool: state.proxyTranscripts,
                    includesPool: state.showsProxyTranscripts(for: [monitor]))
                    // A fresh view per account: no value carries over between accounts.
                    .id(monitor.id)
            } else {
                PoolView(state: state, now: now)
            }

            footer(now: now)
                .padding(.horizontal, 4)
        }
        .padding(8)
        .frame(width: 300)
    }

    /// The bold title of a system menu, with the plan or account count on the right.
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude Code").font(.headline)
            Spacer()
            Group {
                if state.showsPool {
                    Text("\(state.visibleMonitors.count) accounts")
                } else if let plan = state.selectedMonitor?.account.plan.label {
                    Text(plan)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
        .padding(.bottom, -2)
    }

    private func footer(now: Date) -> some View {
        HStack(spacing: 8) {
            if let updated = state.lastUpdated {
                Text(
                    state.health.isError
                        ? "stale · \(Format.staleness(since: updated, now: now))"
                        : "updated \(Format.staleness(since: updated, now: now))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            FooterButtons {
                FooterButton(symbol: "arrow.clockwise", help: state.showsPool ? "Refresh all accounts" : "Refresh now",
                             busy: state.isRefreshing) {
                    state.refreshNow()
                }
                .keyboardShortcut("r")
                FooterButton(symbol: "gearshape", help: "Settings") {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",")
                FooterButton(symbol: "power", help: "Quit cclimit") {
                    // AppKit refuses to quit while a window shows a sheet. Quit means quit.
                    for window in NSApp.windows {
                        if let sheet = window.attachedSheet { window.endSheet(sheet) }
                    }
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}

/// The footer's icon row. Plain icons, tight spacing, like the Wi-Fi and Battery menus.
private struct FooterButtons<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
    }
}

/// A Control Center module: a rounded tile for one group of rows. Content sits on a quiet
/// fill, not on glass. Glass belongs to controls, and glass on glass reads muddy.
private struct Module<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A monochrome icon button: no chrome at rest, a quiet circle on hover and press.
/// Glass circles crowded the glyphs and drew heavy rims on macOS 27.
private struct FooterButton: View {
    let symbol: String
    let help: String
    /// A refresh in flight: a small spinner in place of the icon, so a click visibly took.
    var busy = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(hovering ? .primary : .secondary)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(FooterButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct FooterButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle().fill(Color.primary.opacity(
                    configuration.isPressed ? 0.16 : hovering ? 0.08 : 0)))
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// "All" plus one segment per account. Past four accounts the segments get too narrow
/// to read at 300 pt, so it falls back to a pop-up menu.
private struct AccountSwitcher: View {
    @ObservedObject var state: AppState

    private var selection: Binding<String> {
        Binding(
            get: { state.selectedMonitor?.id ?? AppState.allID },
            set: { state.selection = $0 })
    }

    var body: some View {
        let picker = Picker("Account", selection: selection) {
            Text("All").tag(AppState.allID)
            ForEach(state.visibleMonitors) { monitor in
                Text(state.shortName(for: monitor.account)).tag(monitor.id)
            }
        }
        .labelsHidden()

        if state.visibleMonitors.count > 4 {
            picker.pickerStyle(.menu).fixedSize()
        } else {
            picker.pickerStyle(.segmented)
        }
    }
}

/// One account in full: the user's section layout, exactly as before multi-account.
private struct AccountDetail: View {
    @ObservedObject var monitor: AccountMonitor
    let showsIdentity: Bool
    let now: Date
    let pool: TranscriptReports
    let includesPool: Bool
    @AppStorage("hiddenSections") private var hiddenSectionsRaw = ""
    @AppStorage("sectionOrder") private var sectionOrderRaw = ""

    private var hiddenSections: Set<String> {
        Set(hiddenSectionsRaw.split(separator: "\n").map(String.init))
    }

    /// Section IDs to render, in the user's stored order, filtered to the visible ones.
    private var visibleSections: [String] {
        let stored = sectionOrderRaw.split(separator: "\n").map(String.init)
        return SectionLayout.ordered(stored: stored, seenModels: monitor.seenModelNames)
            .filter { !hiddenSections.contains($0) }
    }

    /// "you@work.com": which login this is, when the switcher alone can't say.
    private var identity: String? {
        monitor.account.email
    }

    var body: some View {
        if showsIdentity, let identity {
            Text(identity)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
            .padding(.top, -2)
        }

        if let message = monitor.healthMessage {
            HealthBanner(message: message)
        }

        if let snap = monitor.snapshot {
            let sections = visibleSections
            let limits = sections.filter { $0 != SectionLayout.attribution }
            let projectsFirst = sections.first == SectionLayout.attribution
            if projectsFirst, sections.contains(SectionLayout.attribution) { projectsModule }
            if !limits.isEmpty {
                Module(spacing: 9) {
                    ForEach(limits, id: \.self) { sectionView($0, snap: snap) }
                }
            }
            if !projectsFirst, sections.contains(SectionLayout.attribution) { projectsModule }
        } else if !monitor.health.isError {
            Module { FetchingRow() }
        }
    }

    private var projectsModule: some View {
        Module { AttributionSection(monitors: [monitor], pool: pool, includesPool: includesPool) }
    }

    @ViewBuilder
    private func sectionView(_ id: String, snap: UsageSnapshot) -> some View {
        switch id {
        case SectionLayout.fiveHour:
            // An account without a 5-hour limit (Ultra) has no row for it: the weekly cap leads.
            if let window = snap.fiveHour {
                WindowRow(
                    title: "5-hour window", window: window, now: now,
                    projection: monitor.projections[id])
            }
        case SectionLayout.weekly:
            WindowRow(
                title: "Weekly cap", window: snap.sevenDay, now: now,
                projection: monitor.projections[id])
        default:
            if let name = SectionLayout.modelName(id) {
                if let model = snap.perModelWindows.first(where: { $0.name == name }) {
                    WindowRow(
                        title: "Weekly · \(model.name)",
                        window: model.window,
                        now: now,
                        badge: model.isActive ? "active" : nil,
                        note: monitor.perModelStaleNote(now: now),
                        projection: monitor.perModelStaleNote(now: now) == nil ? monitor.projections[id] : nil)
                } else {
                    // Seen in a prior run but absent from the current snapshot: the per-model
                    // supplement (usage endpoint) hasn't answered yet — often because it's
                    // rate-limited. Render a blank bar so it's clear the row is pending, not
                    // that the limit is empty.
                    WindowRow(title: "Weekly · \(name)", window: nil, now: now, badge: "unavailable")
                }
            }
        }
    }
}

/// "All": the pooled reading on top, then one compact row per account. A row opens that
/// account. Only alarming forecasts surface here, each named by its account.
private struct PoolView: View {
    @ObservedObject var state: AppState
    let now: Date
    @AppStorage("hiddenSections") private var hiddenSectionsRaw = ""
    @AppStorage("sectionOrder") private var sectionOrderRaw = ""
    @AppStorage("poolShowsAccounts") private var showsAccounts = true
    @AppStorage(ForecastStyle.key) private var forecastStyleRaw = ForecastStyle.bars.rawValue

    /// The same sections, in the same order, as one account shows (Settings > Layout).
    private var sections: [String] {
        let hidden = Set(hiddenSectionsRaw.split(separator: "\n").map(String.init))
        return SectionLayout.ordered(
            stored: sectionOrderRaw.split(separator: "\n").map(String.init),
            seenModels: state.seenModelNames)
            .filter { !hidden.contains($0) }
    }

    var body: some View {
        let monitors = state.visibleMonitors
        let sections = sections
        let limits = sections.filter { $0 != SectionLayout.attribution }
        if let pooled = state.pooledSnapshot {
            if !limits.isEmpty {
                Module(spacing: 9) {
                    HStack(spacing: 4) {
                        Text("Pooled")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Each account counts by its plan size: an Ultra login weighs four times a Max 5x one. The 5-hour window and each model limit pool only the accounts that have them. Resets show when the first account frees up.")
                        Spacer()
                    }
                    ForEach(limits, id: \.self) { row($0, pooled: pooled) }
                }
            }
        } else if !state.health.isError {
            Module { FetchingRow() }
        }

        let alerts = !(ForecastStyle(rawValue: forecastStyleRaw)?.showsText ?? false) ? [] : monitors.flatMap { AccountAlerts.lines(for: $0, name: state.shortName(for: $0.account), now: now) }
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(alerts.prefix(3), id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }

        if showsAccounts {
            Module(spacing: 2) {
                VStack(spacing: 2) {
                    ForEach(monitors) { monitor in
                        AccountSummaryRow(monitor: monitor, name: state.shortName(for: monitor.account)) {
                            state.selection = monitor.id
                        }
                    }
                }
                // Rows carry their own hover inset; pull them out inside the module so their
                // text lines up with the rest of it.
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
            }
        }

        if sections.contains(SectionLayout.attribution) {
            Module {
                AttributionSection(
                    monitors: monitors, pool: state.proxyTranscripts,
                    includesPool: state.showsProxyTranscripts(for: monitors))
            }
        }
    }

    @ViewBuilder
    private func row(_ id: String, pooled: UsageSnapshot) -> some View {
        switch id {
        case SectionLayout.fiveHour:
            // Pools only the accounts that still have a 5-hour limit, like a model limit.
            if let window = pooled.fiveHour {
                WindowRow(title: "5-hour window", window: window, now: now, resetLabel: "first resets",
                          segments: segments(id))
            }
        case SectionLayout.weekly:
            WindowRow(title: "Weekly cap", window: pooled.sevenDay, now: now, resetLabel: "first resets",
                      segments: segments(id))
        default:
            if let name = SectionLayout.modelName(id),
               let model = pooled.perModelWindows.first(where: { $0.name == name }) {
                WindowRow(
                    title: "Weekly · \(model.name)", window: model.window, now: now,
                    badge: model.isActive ? "active" : nil, resetLabel: "first resets",
                    segments: segments(id))
            }
        }
    }

    /// One slice of the pooled bar per account that has this limit, as wide as its plan
    /// weighs in the pool. The slices fill to the same total as the pooled reading.
    private func segments(_ id: String) -> [PoolSegment] {
        let parts = state.visibleMonitors.compactMap { monitor -> PoolSegment? in
            guard let snapshot = monitor.snapshot else { return nil }
            let window: UsageWindow?
            switch id {
            case SectionLayout.fiveHour: window = snapshot.fiveHour
            case SectionLayout.weekly: window = snapshot.sevenDay
            default:
                window = SectionLayout.modelName(id).flatMap { name in
                    snapshot.perModelWindows.first { $0.name == name }?.window
                }
            }
            guard let utilization = window?.utilization else { return nil }
            return PoolSegment(
                id: monitor.id, name: state.shortName(for: monitor.account),
                weight: monitor.account.plan.weight, utilization: utilization,
                projection: monitor.projections[id])
        }
        return parts
    }
}

/// The forecasts worth a line in the pooled view: walls and run-outs, never "pace fine".
enum AccountAlerts {
    @MainActor
    static func lines(for monitor: AccountMonitor, name: String, now: Date) -> [String] {
        var lines: [String] = []
        switch monitor.fiveHourVerdict {
        case .willHitWall(let eta, _, _):
            lines.append("\(name): 5-hour wall ≈ \(Format.clockTime(eta)) — in \(Format.countdown(to: eta, from: now)).")
        case .exhausted(let reset):
            lines.append("\(name): 5-hour limit reached" + (reset.map { " — resets \(Format.resetStamp($0, now: now))." } ?? "."))
        default:
            break
        }
        for forecast in monitor.weeklyForecasts {
            switch forecast.verdict {
            case .likelyExhaustion(let earliest, let latest, _, _):
                lines.append("\(name): \(forecast.name) runs out \(Format.etaRange(earliest: earliest, latest: latest, now: now)).")
            case .exhausted:
                lines.append("\(name): \(forecast.name) reached.")
            default:
                break
            }
        }
        return lines
    }
}

/// One account in the pooled list: name, plan, and two thin meters. The second meter is
/// whichever weekly window binds (the overall cap, or a model cap such as Fable), so the
/// row stays two meters wide without hiding the limit that matters.
private struct AccountSummaryRow: View {
    @ObservedObject var monitor: AccountMonitor
    let name: String
    let onOpen: () -> Void
    @State private var hovering = false
    /// The forecast of the meter under the pointer, shown where the health note sits.
    @State private var meterNote: String?

    private var weekly: (label: String, value: Double?, id: String) {
        let overall = monitor.snapshot?.sevenDay?.utilization
        let model = monitor.snapshot?.perModelWindows
            .max { ($0.window.utilization ?? 0) < ($1.window.utilization ?? 0) }
        if let model, let value = model.window.utilization, value > (overall ?? 0) {
            return (model.name, value, SectionLayout.modelID(model.name))
        }
        return ("Week", overall, SectionLayout.weekly)
    }

    /// Two meters. With a 5-hour limit: 5h and the binding weekly. Without one (Ultra): the
    /// weekly cap and the fullest model cap, so the row keeps its width and loses nothing.
    private var meters: [(label: String, value: Double?, id: String)] {
        guard let snapshot = monitor.snapshot, snapshot.fiveHour == nil else {
            return [("5h", monitor.snapshot?.fiveHour?.utilization, SectionLayout.fiveHour), weekly]
        }
        let overall = ("Week", snapshot.sevenDay?.utilization, SectionLayout.weekly)
        guard let model = snapshot.perModelWindows
            .max(by: { ($0.window.utilization ?? 0) < ($1.window.utilization ?? 0) })
        else { return [overall] }
        return [overall, (model.name, model.window.utilization, SectionLayout.modelID(model.name))]
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name)
                        .lineLimit(1)
                    if let plan = monitor.account.plan.label {
                        Text(plan)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer(minLength: 4)
                    if let meterNote {
                        Text(meterNote)
                            .font(.caption)
                            .lineLimit(1)
                    } else if let problem = monitor.health.shortMessage {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 14) {
                    ForEach(meters, id: \.id) { meter in
                        MiniMeter(
                            label: meter.label, value: meter.value,
                            projection: monitor.projections[meter.id],
                            onHover: { meterNote = $0 })
                    }
                }
                // Last-known numbers stay readable but recede while the account is failing.
                .opacity(monitor.health.isError ? 0.5 : 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.07) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Label, a 4 pt bar on the state ramp, and the percent: a WindowRow folded onto one line.
private struct MiniMeter: View {
    let label: String
    let value: Double?
    var projection: Projection? = nil
    var now = Date()
    var onHover: (String?) -> Void = { _ in }
    @AppStorage(ForecastStyle.key) private var styleRaw = ForecastStyle.bars.rawValue

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            UsageBar(value: value, projected: projection?.atReset, height: 4)
                .onHover { inside in
                    // The name line is short: "Week runs out from Thu 17:00".
                    let forecast = (ForecastStyle(rawValue: styleRaw)?.showsBars ?? true)
                        ? ForecastStyle.help(projection, current: value, now: now) : nil
                    onHover(inside ? forecast.map { "\(label) " + $0.replacingOccurrences(of: "At this pace, ", with: "") } : nil)
                }
            Text(value.map(Format.percent) ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(value.map(UsageColor.number) ?? .secondary)
                .frame(minWidth: 30, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FetchingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Fetching usage…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
    }
}

/// Claude Code on this Mac talks to a CLIProxyAPI server cclimit is not connected to. One
/// quiet row: Connect opens Settings with the address filled in. Dismissed, it stays hidden
/// for that address.
private struct ProxySuggestion: View {
    let url: URL
    let onConnect: () -> Void
    let onDismiss: () -> Void

    private var address: String {
        guard let host = url.host else { return url.absoluteString }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
            Text("Claude Code uses a CLI proxy at \(address).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Connect", action: onConnect)
                .controlSize(.small)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Hide. Settings > Accounts > CLI Proxy still connects it.")
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct HealthBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct WindowRow: View {
    @AppStorage(ForecastStyle.key) private var styleRaw = ForecastStyle.bars.rawValue
    private var style: ForecastStyle { ForecastStyle(rawValue: styleRaw) ?? .bars }

    /// "Runs out ≈ 17:20 at this pace": only when the wall lands before the reset.
    private var warning: String? {
        style.showsText ? ForecastStyle.warning(projection, now: now) : nil
    }

    let title: String
    let window: UsageWindow?
    /// The popover's ticking clock — every relative string is measured from it.
    let now: Date
    var badge: String? = nil
    /// Optional muted footnote, e.g. "updated 2h ago" when this row's data is stale.
    var note: String? = nil
    /// "first resets" for a pooled row, where the reset is the earliest account's.
    var resetLabel: String = "resets"
    /// The forecast for this window: a ghost extension on the bar, and a warning line
    /// when the window runs out before it resets.
    var projection: Projection? = nil
    /// A pooled row splits its bar into one slice per account. Empty draws one bar.
    var segments: [PoolSegment] = []
    /// The forecast of the bar under the pointer, shown in place of the reset line.
    @State private var hoverText: String?

    /// The projected landing point, only when it says more than the fill already does.
    private var landing: Double? {
        guard style.showsText, projection?.wall == nil, let target = projection?.atReset,
              let current = window?.utilization, target >= current + 1 else { return nil }
        return target
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if let utilization = window?.utilization {
                    Text(Format.percent(utilization))
                        .font(.body.weight(.medium).monospacedDigit())
                        .foregroundStyle(UsageColor.number(utilization))
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            if segments.count > 1 {
                SegmentedUsageBar(segments: segments, now: now, hoverText: $hoverText)
            } else {
                // A pool of one draws that account's own forecast.
                let projection = segments.first?.projection ?? projection
                UsageBar(value: window?.utilization, projected: projection?.atReset, height: 5)
                    .onHover { inside in
                        hoverText = inside && style.showsBars
                            ? ForecastStyle.help(projection, current: window?.utilization, now: now) : nil
                    }
            }
            HStack(spacing: 6) {
                if let hoverText {
                    // The menu bar window shows no tooltips: the caption line carries it.
                    Text(hoverText)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if let reset = window?.resetsAt {
                    if reset <= now {
                        // The stored reading predates its own reset: the next poll replaces it.
                        Text("reset \(Format.clockTime(reset)) · refreshing")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("\(resetLabel) \(Format.resetStamp(reset, now: now)) · in \(Format.countdown(to: reset, from: now))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if let landing, hoverText == nil {
                    Text("→ \(Format.percent(landing)) at reset")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(landing >= 70 ? UsageColor.number(landing) : Color.secondary)
                        .help("Where this window lands when it resets, if the current pace holds.")
                }
            }
            if let warning {
                Label {
                    Text(warning).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(UsageColor.number(95))
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Where the tokens went, over a range the user picks from the header: a Screen Time style
/// activity chart, then the projects. Hovering a project lights up its share of every bar.
/// Clicking one opens its sessions, model mix, and token split.
private struct AttributionSection: View {
    /// One account, or every visible one for "All". The parent observes them, so this view
    /// redraws when any of their reports lands.
    let monitors: [AccountMonitor]
    /// Transcripts of the config dirs routed through the CLI proxy. They belong to no single
    /// login, so they join only the views `AppState.showsProxyTranscripts` allows.
    @ObservedObject var pool: TranscriptReports
    let includesPool: Bool
    @AppStorage("attributionRange") private var rangeRaw = AttributionRange.window.rawValue
    @State private var hoveredProject: String?
    @State private var hoveredBucket: ActivityBucket?
    @State private var expanded: String?
    /// 0 is today or the last 7 days, 1 the day or 7 days before, and so on back 31 days.
    @State private var page = 0

    /// "This 5-hour window" means nothing when no shown account has one (Ultra): the
    /// range reads as Today then, and the menu leaves the option out. The stored choice
    /// stays, so it comes back for an account that still has the window.
    private var hasFiveHour: Bool {
        monitors.contains { $0.snapshot.map { !$0.lacksFiveHour } ?? true }
    }

    private var ranges: [AttributionRange] {
        hasFiveHour ? AttributionRange.allCases : AttributionRange.allCases.filter { $0 != .window }
    }

    private var range: AttributionRange {
        AttributionRange.shown(stored: rangeRaw, hasFiveHour: hasFiveHour)
    }
    /// The accounts' reports for this page, merged. Nil until every account's has landed,
    /// so the total does not grow under the pointer.
    private var report: UsageReport? {
        var reports = monitors.map { $0.report(range: range, page: page) }
        if includesPool { reports.append(pool.report(range: range, span: span)) }
        guard !reports.contains(where: { $0 == nil }) else { return nil }
        return UsageReport.merge(reports.compactMap { $0 }) ?? .empty(since: span.start, bucketSize: range.bucketSize)
    }

    private var span: DateInterval {
        AppState.attributionSpan(range: range, page: page, for: monitors)
    }

    private var hasEarlierPage: Bool {
        monitors.first?.hasPage(range: range, page: page + 1)
            ?? range.hasPage(page + 1, now: Date(), fiveHourReset: nil, weeklyReset: nil)
    }

    /// "Yesterday", "Sat 24 Oct", "12–19 Oct". Nil on the current page: the picker names it.
    private var pageLabel: String? {
        guard page > 0 else { return nil }
        let start = span.start
        switch range {
        case .today:
            return page == 1 ? "Yesterday" : start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        case .week:
            let last = span.end.addingTimeInterval(-1)
            return "\(start.formatted(.dateTime.day().month(.abbreviated)))–\(last.formatted(.dateTime.day().month(.abbreviated)))"
        case .window, .month:
            return nil
        }
    }

    private var emptyText: String {
        switch (range, pageLabel) {
        case (.today, let label?): return "No Claude Code activity on \(label)."
        case (.week, let label?): return "No Claude Code activity \(label)."
        case (.week, nil): return "No Claude Code activity in the last 7 days."
        case (.month, _): return "No Claude Code activity in the last 30 days."
        default: return "No Claude Code activity \(range.shortLabel)."
        }
    }

    /// Top five, and everything else folded into one row.
    private var rows: [ProjectStats] {
        let projects = report?.projects ?? []
        guard projects.count > 6 else { return projects }
        let rest = projects.dropFirst(5)
        return Array(projects.prefix(5)) + [ProjectStats(
            name: "\(rest.count) others",
            tokens: rest.reduce(0) { $0 + $1.tokens },
            share: rest.reduce(0) { $0 + $1.share },
            cost: rest.reduce(0) { $0 + $1.cost })]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let report, report.total > 0 {
                summary(report)
                ActivityChart(
                    report: report, domain: domain(for: report), range: range,
                    highlight: hoveredProject, hovered: $hoveredBucket)
                VStack(spacing: 0) {
                    let top = rows.first?.share ?? 1
                    ForEach(rows) { project in
                        ProjectRow(
                            project: project,
                            relative: top > 0 ? project.share / top : 0,
                            isExpanded: expanded == project.name,
                            isHighlighted: hoveredProject == project.name,
                            canExpand: !project.name.hasSuffix(" others"),
                            onToggle: {
                                // No animation: the row grows the window, and the window does not animate.
                                expanded = expanded == project.name ? nil : project.name
                            })
                            .onHover { hoveredProject = $0 ? project.name : nil }
                    }
                }
                .padding(.horizontal, -6)
            } else if report == nil {
                AttributionSkeleton()
            } else {
                if let pageLabel {
                    Text(pageLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, -4)
                }
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .center)
            }
        }
        .onChange(of: rangeRaw) { _, _ in
            expanded = nil
            page = 0
            load()
        }
        .onChange(of: page) { _, _ in
            expanded = nil
            load()
        }
        .onAppear { load() }
    }

    private func load() {
        monitors.forEach { $0.refreshAttributionIfStale(range: range, page: page) }
        if includesPool { pool.refreshIfStale(range: range, span: span) }
    }

    private var header: some View {
        HStack {
            Text("Projects")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .help("Measured from your local Claude Code transcripts, the CLI proxy's included. Token counts leave cache reads out: they cost little and would swamp the rest. Dollar amounts are what the same work would cost at Anthropic's API list prices, cache reads included. On a subscription you do not pay them.")
            Spacer()
            if range.pages {
                HStack(spacing: 0) {
                    PageButton(symbol: "chevron.left", help: range == .today ? "Previous day" : "Previous week") {
                        page += 1
                    }
                    .disabled(!hasEarlierPage)
                    .opacity(hasEarlierPage ? 1 : 0.4)
                    PageButton(symbol: "chevron.right", help: range == .today ? "Next day" : "Next week") {
                        page -= 1
                    }
                    .disabled(page == 0)
                    .opacity(page == 0 ? 0.4 : 1)
                }
            }
            Picker("Range", selection: Binding(get: { range.rawValue }, set: { rangeRaw = $0 })) {
                ForEach(ranges) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// The range total, or the hovered bar's value while the pointer is on the chart.
    private func summary(_ report: UsageReport) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            let prefix = pageLabel.map { "\($0) · " } ?? ""
            if let bucket = hoveredBucket {
                let cost = hoveredProject.map { bucket.costByProject[$0] ?? 0 } ?? bucket.cost
                Text("\(range == .today ? prefix : "")\(bucketLabel(bucket.start)) · \(Format.tokens(bucket.tokens)) tokens · ≈ \(Format.dollars(cost))")
            } else {
                Text("\(prefix)\(Format.tokens(report.total)) tokens · ≈ \(Format.dollars(report.cost)) · \(report.sessions) session\(report.sessions == 1 ? "" : "s")")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.top, -4)
    }

    /// The whole span the range covers, so a fresh day shows its empty afternoon too.
    private func domain(for report: UsageReport) -> ClosedRange<Date> {
        let start = report.since
        let end: Date
        switch range {
        case .window: end = start.addingTimeInterval(5 * 3600)
        case .today: end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        case .week: end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        case .month: end = (report.buckets.last?.start ?? start).addingTimeInterval(report.bucketSize)
        }
        return start...max(end, start.addingTimeInterval(report.bucketSize))
    }

    private func bucketLabel(_ start: Date) -> String {
        switch range {
        case .window, .today: return Format.clockTime(start)
        case .week: return "\(Format.weekday(start)) \(Format.clockTime(start))"
        case .month: return start.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

/// Steps the projects range one day or one week.
private struct PageButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// Stands in for the summary, chart and project rows while a page loads, at their height,
/// so the popover does not jump when the numbers land. Static: no shimmer.
private struct AttributionSkeleton: View {
    private static let bars: [CGFloat] = [0.2, 0.35, 0.6, 0.45, 0.8, 0.55, 0.3, 0.7, 0.9, 0.5, 0.25, 0.4]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("00M tokens · ≈ $00.00 · 0 sessions")
                .font(.caption)
                .padding(.top, -4)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Self.bars.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40 * Self.bars[index])
                }
            }
            .frame(height: 56, alignment: .bottom)
            .foregroundStyle(.quaternary)
            VStack(spacing: 0) {
                ForEach(["project name", "another project", "third one"], id: \.self) { name in
                    HStack(spacing: 8) {
                        Text(name)
                        Spacer(minLength: 8)
                        Text("0.0M").font(.caption)
                        Text("$00").font(.caption)
                        Capsule().fill(.quaternary).frame(width: 44, height: 4)
                        Text("00%").font(.caption).frame(width: 30, alignment: .trailing)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading project stats")
    }
}

/// Token activity over the range, one bar per bucket, in the style of Screen Time. A hovered
/// project keeps its slice of each bar at full strength and dims the rest.
private struct ActivityChart: View {
    let report: UsageReport
    let domain: ClosedRange<Date>
    let range: AttributionRange
    let highlight: String?
    @Binding var hovered: ActivityBucket?

    var body: some View {
        Chart(report.buckets) { bucket in
            let end = bucket.start.addingTimeInterval(report.bucketSize * 0.8)
            let lit = highlight.map { bucket.byProject[$0] ?? 0 } ?? bucket.tokens
            let dim = hovered != nil && hovered?.start != bucket.start
            RectangleMark(
                xStart: .value("Start", bucket.start), xEnd: .value("End", end),
                yStart: .value("Tokens", 0), yEnd: .value("Tokens", lit))
                .foregroundStyle(Color.accentColor.opacity(dim ? 0.55 : 1))
                .cornerRadius(1.5)
            if lit < bucket.tokens {
                RectangleMark(
                    xStart: .value("Start", bucket.start), xEnd: .value("End", end),
                    yStart: .value("Tokens", lit), yEnd: .value("Tokens", bucket.tokens))
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .cornerRadius(1.5)
            }
        }
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                AxisValueLabel(anchor: .topLeading) {
                    if let date = value.as(Date.self) { Text(label(date)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let tokens = value.as(Double.self) { Text(Format.tokens(Int(tokens))) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let point) = phase, let plot = proxy.plotFrame,
                              let date: Date = proxy.value(atX: point.x - geo[plot].origin.x)
                        else { hovered = nil; return }
                        hovered = report.buckets.last { $0.start <= date && $0.tokens > 0 }
                            .flatMap { date < $0.start.addingTimeInterval(report.bucketSize) ? $0 : nil }
                    }
            }
        }
        .font(.caption2)
        .frame(height: 56)
        .animation(.easeOut(duration: 0.15), value: highlight)
    }

    /// Wall-clock ticks: a 25-hour DST day still labels 00, 06, 12, 18.
    private var ticks: [Date] {
        let calendar = Calendar.current
        let (unit, step, count): (Calendar.Component, Int, Int) = switch range {
        case .window: (.hour, 1, 6)
        case .today: (.hour, 6, 4)
        case .week: (.day, 1, 7)
        case .month: (.day, 7, 5)
        }
        let base = range == .window ? domain.lowerBound : calendar.startOfDay(for: domain.lowerBound)
        return (0..<count)
            .compactMap { index -> Date? in
                // Hours set on the clock, not added: adding counts the repeated DST hour.
                if range == .today {
                    return calendar.date(bySettingHour: index * step, minute: 0, second: 0, of: base)
                }
                return calendar.date(byAdding: unit, value: index * step, to: base)
            }
            .filter { domain.contains($0) && $0 < domain.upperBound }
    }

    private func label(_ date: Date) -> String {
        switch range {
        case .window, .today: return Format.clockTime(date)
        case .week: return String(Format.weekday(date).prefix(2))
        case .month: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

/// A project: name, tokens, a short share bar, and its percent.
private struct ProjectRow: View {
    let project: ProjectStats
    /// Share relative to the top project, so the leader fills its bar.
    let relative: Double
    let isExpanded: Bool
    let isHighlighted: Bool
    let canExpand: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(project.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Format.tokens(project.tokens))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(Format.dollars(project.cost))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("What this project's work would cost at Anthropic's API list prices")
                ShareBar(share: project.share, lit: isHighlighted)
                    .frame(width: 44)
                Text("\(Int((project.share * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
            if isExpanded {
                ProjectDetail(project: project)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHighlighted || isExpanded ? Color.primary.opacity(0.06) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture { if canExpand { onToggle() } }
    }
}

/// The expanded part of a project row: three short caption lines.
private struct ProjectDetail: View {
    let project: ProjectStats

    private var modelMix: String? {
        guard !project.models.isEmpty, project.tokens > 0 else { return nil }
        return project.models.prefix(3).map {
            "\($0.name) \(Int((Double($0.tokens) / Double(project.tokens) * 100).rounded()))%"
        }.joined(separator: " · ")
    }

    private var activity: String {
        var parts = ["\(project.sessions) session\(project.sessions == 1 ? "" : "s")"]
        if project.subagentTokens > 0 {
            parts.append("\(Int((project.subagentShare * 100).rounded()))% by subagents")
        }
        if let last = project.lastActive {
            parts.append("last \(Format.staleness(since: last))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(activity)
            if let modelMix { Text(modelMix) }
            Text("in \(Format.tokens(project.input)) · out \(Format.tokens(project.output)) · cache \(Format.tokens(project.cacheWrite)) written, \(Format.tokens(project.cacheRead)) read")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }
}

/// The usage bar: the system linear progress bar, tinted on the state ramp. With forecasts
/// on the bars, a faded stretch past the fill shows where the window lands at reset, in
/// the color of that landing point. A window that runs out reaches the end.
struct UsageBar: View {
    let value: Double?
    var projected: Double? = nil
    var height: CGFloat = 5
    @AppStorage(ForecastStyle.key) private var styleRaw = ForecastStyle.bars.rawValue

    private var ghost: Double? {
        guard ForecastStyle(rawValue: styleRaw)?.showsBars ?? true,
              let value, let projected, projected >= value + 1 else { return nil }
        return min(projected, 100)
    }

    var body: some View {
        let current = min(max(value ?? 0, 0), 100)
        // With a forecast the whole bar is drawn here: the stock fill ends in a glow, and
        // even an empty stock bar leaves a dot at its start. The stock bar keeps the size.
        ProgressView(value: current, total: 100)
            .progressViewStyle(.linear)
            .tint(value == nil ? .secondary : UsageColor.bar(current))
            .labelsHidden()
            .opacity(ghost == nil ? 1 : 0)
            .overlay(alignment: .leading) {
                if let ghost {
                    // The faded stretch runs from the start, and the fill draws again on top,
                    // so the fill's rounded end covers the joint instead of crossing it.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(.quaternary)
                                .frame(width: geo.size.width, height: height)
                            Capsule()
                                .fill(UsageColor.bar(ghost).opacity(0.4))
                                .frame(width: geo.size.width * ghost / 100, height: height)
                            if current > 0 {
                                Capsule()
                                    .fill(UsageColor.bar(current))
                                    .frame(width: max(height, geo.size.width * current / 100), height: height)
                            }
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
            }
            // The stock bar is invisible under a forecast, and an invisible view takes no
            // pointer: without this shape the hover text never shows.
            .contentShape(Rectangle())
            // No motion: switching accounts must show the other account's bars at once,
            // not slide them up or down from the previous account's values.
            .transaction { $0.animation = nil }
    }
}

/// Where forecasts show: as a faded stretch on each bar, as text lines, both, or nowhere.
enum ForecastStyle: String, CaseIterable, Identifiable {
    case bars, text, both, off

    static let key = "forecastStyle"
    var id: String { rawValue }
    var showsBars: Bool { self == .bars || self == .both }
    var showsText: Bool { self == .text || self == .both }

    var label: String {
        switch self {
        case .bars: return "On the bars"
        case .text: return "As text"
        case .both: return "Bars and text"
        case .off: return "Off"
        }
    }

    /// "At this pace, runs out around 17:20": only when the wall lands before the reset.
    static func warning(_ projection: Projection?, now: Date) -> String? {
        switch projection?.wall {
        case .at(let date):
            guard date > now else { return nil }
            return "At this pace, runs out around \(Format.clockTime(date))"
        case .between(let earliest, _):
            return earliest <= now
                ? "At this pace, runs out before it resets"
                : "At this pace, runs out from \(Format.resetStamp(earliest, now: now))"
        case .reached, nil:
            return nil
        }
    }

    /// The hover text of a bar with a forecast: the run-out time, or the landing point.
    static func help(_ projection: Projection?, current: Double?, now: Date) -> String? {
        if let warning = warning(projection, now: now) { return warning }
        guard let target = projection?.atReset, let current, target >= current + 1 else { return nil }
        return "At this pace, \(Format.percent(target)) when it resets"
    }
}

struct PoolSegment: Identifiable {
    let id: String
    let name: String
    let weight: Double
    let utilization: Double
    var projection: Projection? = nil
}

/// The pooled bar cut into one stock bar per account, each as wide as its plan weighs, so
/// a full account shows inside the pool instead of hiding in the average.
private struct SegmentedUsageBar: View {
    let segments: [PoolSegment]
    let now: Date
    @Binding var hoverText: String?
    private let gap: CGFloat = 3

    var body: some View {
        WeightedRow(weights: segments.map(\.weight), gap: gap) {
            ForEach(segments) { segment in
                UsageBar(value: segment.utilization, projected: segment.projection?.atReset)
                    .onHover { inside in
                        if inside {
                            hoverText = help(segment)
                        } else if hoverText == help(segment) {
                            hoverText = nil
                        }
                    }
            }
        }
    }

    private func help(_ segment: PoolSegment) -> String {
        let reading = "\(segment.name): \(Format.percent(segment.utilization))"
        guard let forecast = ForecastStyle.help(segment.projection, current: segment.utilization, now: now)
        else { return reading }
        return "\(reading) · \(forecast)"
    }
}

/// Lays its children side by side, each as wide as its share of the weights, as tall as
/// the tallest one. A GeometryReader would need a fixed height, and the stock bar has its own.
private struct WeightedRow: Layout {
    let weights: [Double]
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 200
        let widths = widths(total: width, count: subviews.count)
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: proposal.height)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(total: bounds.width, count: subviews.count)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + gap
        }
    }

    private func widths(total: CGFloat, count: Int) -> [CGFloat] {
        let weights = (0..<count).map { $0 < self.weights.count ? max(self.weights[$0], 0) : 0 }
        let sum = weights.reduce(0, +)
        let usable = max(0, total - gap * CGFloat(max(count - 1, 0)))
        return weights.map { sum > 0 ? usable * CGFloat($0 / sum) : usable / CGFloat(max(count, 1)) }
    }
}

/// A thin monochrome proportion bar. Attribution is informational, so it stays ink, not
/// the green/amber/red state ramp used for limits. It takes the accent while its project
/// is lit in the chart, to tie the row to its bars.
private struct ShareBar: View {
    let share: Double
    var lit = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(lit ? Color.accentColor : Color.secondary)
                    .frame(width: max(3, geo.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

/// Holds the popover's own window, so a key-window notice from Settings is not read as an open.
final class WindowHandle {
    weak var window: NSWindow?
    /// The content's natural height, which the window must match.
    var contentHeight: CGFloat?
    /// The left edge the system chose when the popover opened.
    var left: CGFloat?
}

/// Keeps the popover hanging from the menu bar. The system places it under the icon, then
/// any change in content height keeps the bottom edge and drops the top. The top belongs at
/// the bottom of the menu bar, which is the top of the screen's visible frame.
enum PopoverAnchor {
    @MainActor
    static func pin(_ window: NSWindow, height: CGFloat?, left: CGFloat?) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let top = screen.visibleFrame.maxY
        let frameHeight = height.map { window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1, height: $0)).height }
            ?? window.frame.height
        // MenuBarExtra moves the window sideways on its own when the content grows. Keep the
        // left edge it opened with, kept on screen.
        let x = min(max(left ?? window.frame.minX, screen.visibleFrame.minX),
                    screen.visibleFrame.maxX - window.frame.width)
        let target = NSRect(x: x, y: top - frameHeight, width: window.frame.width, height: frameHeight)
        guard window.frame.integral != target.integral else { return }
        window.setFrame(target, display: true)
    }
}

private struct WindowReader: NSViewRepresentable {
    let handle: WindowHandle

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { handle.window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if handle.window == nil { DispatchQueue.main.async { handle.window = view.window } }
    }
}
