import CClimitCore
import CClimitUI
import ServiceManagement
import SwiftUI

/// The Settings tab to show. The popover sets it before it opens Settings for a task.
enum SettingsTab: String {
    case general, appearance, layout, accounts

    static let key = "settingsTab"

    static func open(_ tab: SettingsTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: key)
    }
}

struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general.rawValue

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "menubar.rectangle") }
                .tag(SettingsTab.appearance.rawValue)
            LayoutSettings()
                .tabItem { Label("Layout", systemImage: "line.3.horizontal") }
                .tag(SettingsTab.layout.rawValue)
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.2") }
                .tag(SettingsTab.accounts.rawValue)
        }
        .frame(width: 480, height: 620)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var updater: UpdaterViewModel
    @AppStorage("pollActiveSeconds") private var pollActiveSeconds = 60
    @AppStorage("pollIdleSeconds") private var pollIdleSeconds = 300
    @AppStorage("notifyThresholdLow") private var notifyThresholdLow = 75
    @AppStorage("notifyThresholdHigh") private var notifyThresholdHigh = 90
    @EnvironmentObject private var state: AppState
    @AppStorage("usageSource") private var usageSource = "direct"
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Picker("Read usage", selection: $usageSource) {
                    Text("Directly").tag("direct")
                    Text("Through Claude Code").tag("claudeCode")
                }
                .onChange(of: usageSource) { _, _ in state.usageSourceChanged() }
                if usageSource == "claudeCode" {
                    Text("cclimit asks Claude Code for your usage every 10 minutes. It never reads your Keychain or your token.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("While active", selection: $pollActiveSeconds) {
                        Text("60 s").tag(60)
                        Text("90 s").tag(90)
                        Text("120 s").tag(120)
                    }
                    Picker("While idle", selection: $pollIdleSeconds) {
                        Text("5 min").tag(300)
                        Text("10 min").tag(600)
                    }
                    Text("cclimit reads the token Claude Code stores and checks your limits every minute while you work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Usage source")
            }

            Section("Notifications") {
                Picker("First warning at", selection: $notifyThresholdLow) {
                    Text("Off").tag(0)
                    Text("70 %").tag(70)
                    Text("75 %").tag(75)
                    Text("80 %").tag(80)
                }
                Picker("Final warning at", selection: $notifyThresholdHigh) {
                    Text("Off").tag(0)
                    Text("85 %").tag(85)
                    Text("90 %").tag(90)
                    Text("95 %").tag(95)
                }
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        launchAtLogin = LaunchAtLogin.set(enabled: enabled)
                    }
                    .disabled(!LaunchAtLogin.isAvailable)
                if !LaunchAtLogin.isAvailable {
                    Text("Available when running as an app bundle (make app).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecksForUpdates)
                LabeledContent("Version \(updater.currentVersion)") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
                Text("Updates are downloaded from cclimit.app and verified before install.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Icon style (with live preview of your real usage) + which limit the icon reflects.
private struct AppearanceSettings: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("iconStyle") private var iconStyleRaw = IconStyle.spark.rawValue
    @AppStorage("iconSource") private var iconSourceRaw = IconSource.auto.storage
    @AppStorage("iconTemplate") private var iconTemplate = false
    @AppStorage("barComposition") private var barCompositionRaw = ""
    @AppStorage("dualBarsThirdModel") private var dualBarsThirdModel = false

    private var style: IconStyle { IconStyle(rawValue: iconStyleRaw) ?? .spark }
    private var source: IconSource { IconSource.parse(iconSourceRaw) }

    /// Resolves the descriptor for any style against the user's current settings + live
    /// snapshot. Every gallery tile renders through this, so each preview is the real icon
    /// with real data — not a mock.
    private func descriptor(for style: IconStyle) -> IconDescriptor {
        IconResolver.resolve(
            style: style,
            source: source,
            composition: BarComposition.parse(barCompositionRaw),
            thirdModelBar: dualBarsThirdModel,
            snapshot: state.snapshot,
            seenModels: state.seenModelNames)
    }

    /// The exact resolution the menu bar renders for the selected style — the caption reads
    /// from this, so it can't drift from reality.
    private var descriptor: IconDescriptor { descriptor(for: style) }

    private var degraded: Bool { state.health.isError && state.snapshot == nil }

    /// Names every bar the icon is currently showing, with its live value.
    private var caption: String {
        guard state.snapshot != nil else { return "Waiting for the first usage reading…" }
        func pct(_ value: Double?) -> String {
            value.map { " \(Int($0.rounded()))%" } ?? ""
        }
        switch descriptor.content {
        case .stacked(let bars):
            return "Now showing " + bars.map { "\($0.name)\(pct($0.value))" }
                .joined(separator: " + ")
        case .inline(let bars):
            return "Now showing " + bars.map { "\($0.item.ref.shortLabel)\(pct($0.value))" }
                .joined(separator: " + ")
        case .image(_, let value), .text(_, let value):
            return "Now showing \(descriptor.summary)" + (value.map { " · \(Int($0.rounded()))%" } ?? "")
        }
    }

    var body: some View {
        Form {
            Section("Menu bar icon") {
                IconStyleGallery(
                    selected: style,
                    template: iconTemplate,
                    degraded: degraded,
                    descriptor: descriptor(for:),
                    onSelect: { iconStyleRaw = $0.rawValue })
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Monochrome", isOn: $iconTemplate.animation(.easeInOut(duration: 0.15)))
            }

            if style == .dualBars {
                StackedBarsOptions(seenModels: state.seenModelNames)
            } else if style.isBars {
                BarCompositionEditor(seenModels: state.seenModelNames)
            } else if style.usesSource {
                Section("Which limit the icon reflects") {
                    Picker("Reflect", selection: $iconSourceRaw) {
                        Text("Whatever's closest to its limit").tag(IconSource.auto.storage)
                        Text("5-hour window").tag(IconSource.fiveHour.storage)
                        Text("Weekly cap").tag(IconSource.weekly.storage)
                        ForEach(state.seenModelNames, id: \.self) { model in
                            Text("\(model) weekly limit").tag(IconSource.model(model).storage)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A gallery of live style previews — pick by tapping the real icon, not a name in a menu.
/// Every tile renders the actual `MenuBarIconView` with your usage data, so switching
/// Monochrome flips all of them together.
private struct IconStyleGallery: View {
    let selected: IconStyle
    let template: Bool
    let degraded: Bool
    let descriptor: (IconStyle) -> IconDescriptor
    let onSelect: (IconStyle) -> Void

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    /// The mark leads on its own full-width row; the rest fill the two-column grid below.
    private var featured: IconStyle { IconStyle.allCases.first ?? .spark }
    private var rest: [IconStyle] { Array(IconStyle.allCases.dropFirst()) }

    var body: some View {
        VStack(spacing: 8) {
            tile(featured)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(rest) { tile($0) }
            }
        }
        .padding(.vertical, 2)
    }

    private func tile(_ style: IconStyle) -> some View {
        IconStyleTile(
            style: style,
            descriptor: descriptor(style),
            template: template,
            degraded: degraded,
            isSelected: style == selected,
            onTap: { onSelect(style) })
    }
}

private struct IconStyleTile: View {
    let style: IconStyle
    let descriptor: IconDescriptor
    let template: Bool
    let degraded: Bool
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            MenuBarIconView(descriptor: descriptor, template: template, degraded: degraded)
                .frame(maxWidth: .infinity, minHeight: 22)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                      lineWidth: isSelected ? 2 : 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(style.displayName)
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

/// Two or three bars for the compact stacked preset — an explicit choice, so the icon
/// never shows more bars than the settings claim.
private struct StackedBarsOptions: View {
    let seenModels: [String]
    @AppStorage("dualBarsThirdModel") private var thirdModel = false

    private var thirdName: String {
        seenModels.count == 1 ? "\(seenModels[0]) weekly" : "the most constrained model"
    }

    var body: some View {
        Section("Stacked bars") {
            Picker("Bars", selection: $thirdModel) {
                Text("Two — 5-hour + weekly").tag(false)
                Text("Three — adds \(thirdName)").tag(true)
            }
            .pickerStyle(.radioGroup)
            .disabled(seenModels.isEmpty)
            Text(seenModels.isEmpty
                ? "The third bar unlocks once a per-model limit (e.g. Fable) has been seen."
                : "The third bar tracks whichever model limit is closest to its cap.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Add / remove / reorder the metrics shown as bars, each with optional label + value —
/// the iStat-style "combined" composition, adapted to CClimit's windows.
private struct BarCompositionEditor: View {
    let seenModels: [String]
    @AppStorage("barComposition") private var raw = ""

    private var items: [BarItem] { BarComposition.parse(raw) }

    private func write(_ items: [BarItem]) { raw = BarComposition.serialize(items) }

    private var addable: [BarWindow] { BarComposition.addable(existing: items, seenModels: seenModels) }

    var body: some View {
        Section("Bars") {
            ForEach(Array(items.enumerated()), id: \.element.ref) { index, item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Text(item.ref.longLabel)
                        Spacer()
                        Button(role: .destructive) {
                            var next = items
                            next.remove(at: index)
                            if !next.isEmpty { write(next) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(items.count <= 1)
                    }
                    HStack(spacing: 16) {
                        Toggle("Label", isOn: binding(for: index, keyPath: \.showLabel))
                        Toggle("Value", isOn: binding(for: index, keyPath: \.showValue))
                    }
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .padding(.leading, 20)
                }
            }
            .onMove { indices, newOffset in
                var next = items
                next.move(fromOffsets: indices, toOffset: newOffset)
                write(next)
            }

            if !addable.isEmpty {
                Menu {
                    ForEach(addable, id: \.self) { ref in
                        Button(ref.longLabel) { write(items + [BarItem(ref: ref)]) }
                    }
                } label: {
                    Label("Add a bar", systemImage: "plus.circle")
                }
            }

            Text("Drag to reorder. Bars render left-to-right; keep it to a few so the menu bar stays compact.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func binding(for index: Int, keyPath: WritableKeyPath<BarItem, Bool>) -> Binding<Bool> {
        Binding(
            get: { items.indices.contains(index) ? items[index][keyPath: keyPath] : false },
            set: { newValue in
                var next = items
                guard next.indices.contains(index) else { return }
                next[index][keyPath: keyPath] = newValue
                write(next)
            })
    }
}

/// Drag-to-reorder popover sections with per-section show/hide. Model sections (e.g. Fable)
/// appear automatically once seen; the stored order survives new arrivals.
private struct LayoutSettings: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("sectionOrder") private var sectionOrderRaw = ""
    @AppStorage("hiddenSections") private var hiddenSectionsRaw = ""
    @AppStorage("poolShowsAccounts") private var poolShowsAccounts = true
    @AppStorage(ForecastStyle.key) private var forecastStyleRaw = ForecastStyle.bars.rawValue

    private var seenModels: [String] {
        UserDefaults.standard.stringArray(forKey: "seenModels") ?? []
    }

    private var order: [String] {
        SectionLayout.ordered(
            stored: sectionOrderRaw.split(separator: "\n").map(String.init),
            seenModels: seenModels)
    }

    private var hidden: Set<String> {
        Set(hiddenSectionsRaw.split(separator: "\n").map(String.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Popover sections")
                .font(.headline)
            Text("Drag to reorder. Toggle to show or hide.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(order, id: \.self) { id in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.tertiary)
                        Text(SectionLayout.displayName(id))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !hidden.contains(id) },
                            set: { show in
                                var h = hidden
                                if show { h.remove(id) } else { h.insert(id) }
                                hiddenSectionsRaw = h.sorted().joined(separator: "\n")
                            }))
                        .labelsHidden()
                    }
                }
                .onMove { indices, newOffset in
                    var ids = order
                    ids.move(fromOffsets: indices, toOffset: newOffset)
                    sectionOrderRaw = ids.joined(separator: "\n")
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Text("The menu bar icon always reflects the true binding limit, even if its section is hidden here.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if state.monitors.count > 1 {
                Divider().padding(.vertical, 4)
                Text("Account order")
                    .font(.headline)
                Text("Drag to reorder, or Control-click a row. The account switcher and the All screen follow this order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                List {
                    ForEach(state.monitors) { monitor in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.tertiary)
                            Text(state.name(for: monitor.account))
                            Spacer()
                            if let plan = monitor.account.plan.label {
                                Text(plan)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            let index = state.monitors.firstIndex { $0.id == monitor.id } ?? 0
                            Button("Move Up") {
                                state.moveAccounts(fromOffsets: [index], toOffset: index - 1)
                            }
                            .disabled(index == 0)
                            Button("Move Down") {
                                state.moveAccounts(fromOffsets: [index], toOffset: index + 2)
                            }
                            .disabled(index == state.monitors.count - 1)
                        }
                    }
                    .onMove { state.moveAccounts(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: CGFloat(state.monitors.count) * 28 + 12)
            }

            Divider().padding(.vertical, 4)
            Toggle("Show each account on the All screen", isOn: $poolShowsAccounts)
            Text("With several accounts, All shows these sections pooled across them. The account list sits below the limits.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)
            Picker("Forecasts", selection: $forecastStyleRaw) {
                ForEach(ForecastStyle.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text("On the bars, a faded stretch past the fill shows where each limit lands at reset. A limit that runs out reaches the end. Point at a bar for the time. As text, a warning line shows under the bar, and All lists each account's warnings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }
}

/// Every Claude Code login cclimit found, with a name and a show/hide switch each.
struct AccountsSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var addRequest: AddAccountRequest?

    var body: some View {
        Form {
            Section {
                if state.monitors.isEmpty {
                    Text("Looking for Claude Code logins…")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.monitors) { monitor in
                    AccountSettingsRow(monitor: monitor)
                }
                ForEach(state.replacedLogins) { entry in
                    ReplacedLoginRow(
                        entry: entry,
                        onAddBack: { openAddSheet(name: AccountSetup.name(fromEmail: entry.email)) },
                        onDismiss: { state.dismissReplaced(entry) })
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Change the account order in Layout. Hidden accounts are not polled. With two or more shown, the popover gets an account switcher and the menu bar icon follows it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ProxySettingsSection()

            Section {
                LabeledContent {
                    Button("Add Account…") { openAddSheet() }
                } label: {
                    Text("Track another Claude account")
                    Text("cclimit makes a folder for it and opens Terminal to log in.")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prefer the terminal? Add this alias to your shell, then run claude-work to log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                }
                LabeledContent("Logged in just now?") {
                    Button("Look Again") { state.rediscover() }
                }
            } header: {
                Text("Add an account")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $addRequest) { request in
            AddAccountSheet(prefill: request.name)
                .environmentObject(state)
        }
    }

    /// A finished result from an earlier run (added, timed out) does not carry over.
    private func openAddSheet(name: String = "") {
        state.clearPendingLogin()
        addRequest = AddAccountRequest(name: name)
    }
}

/// Settings > Accounts > CLI Proxy. Connects a CLIProxyAPI instance through its management
/// API. Every Claude login it holds shows as an account. A login also signed in on this Mac
/// stays one account and reads its usage through the proxy.
private struct ProxySettingsSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var hub = ProxyHub.shared
    @State private var urlText = UserDefaults.standard.string(forKey: ProxyHub.urlKey) ?? ""
    @State private var key = ""
    @State private var connecting = false
    @State private var result: String?
    @State private var editing = false
    @FocusState private var keyFocused: Bool

    private var connected: Bool { hub.isConfigured && !editing }

    var body: some View {
        Section {
            if connected, let config = hub.config {
                LabeledContent {
                    HStack(spacing: 6) {
                        Button("Change…") {
                            urlText = config.baseURL.absoluteString
                            key = ""
                            result = nil
                            editing = true
                        }
                        Button("Disconnect") {
                            hub.disconnect()
                            result = nil
                            state.proxyChanged()
                        }
                    }
                    .controlSize(.small)
                } label: {
                    Text(config.baseURL.absoluteString)
                    Text(status)
                }
            } else {
                TextField("Address", text: $urlText, prompt: Text("http://host:8317"))
                SecureField("Management key", text: $key, prompt: Text("remote-management secret-key"))
                    .focused($keyFocused)
                HStack {
                    if let result {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if editing {
                        Button("Cancel") {
                            editing = false
                            result = nil
                        }
                    }
                    if connecting {
                        ProgressView().controlSize(.small)
                    }
                    Button("Connect") { connect() }
                        .disabled(connecting || urlText.isEmpty || key.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        } header: {
            Text("CLI Proxy")
        } footer: {
            Text("Shows the Claude logins of a CLIProxyAPI server. cclimit fills in the address your Claude Code already uses. The management key is the proxy's remote-management secret-key. cclimit reads the limits the proxy saw on its own traffic, and asks it for the full numbers every 15 minutes. Logins stay on the proxy. The key goes to your Keychain. The proxy blocks a Mac after a few wrong keys, so cclimit stops at the first rejection.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: prefill)
        .onChange(of: state.detectedProxy) { _, _ in prefill() }
    }

    /// The address Claude Code already uses goes in by itself. Only the key is left to type.
    private func prefill() {
        guard !hub.isConfigured, urlText.isEmpty, let found = state.detectedProxy else { return }
        urlText = found.absoluteString
        keyFocused = true
    }

    private var status: String {
        if let error = hub.lastError { return Self.describe(error) }
        let logins = hub.lastLogins
        guard hub.lastFetched != nil else { return "Connected" }
        let local = Set(state.monitors.compactMap { $0.account.isProxyOnly ? nil : $0.account.email?.lowercased() })
        let shared = logins.filter { $0.email.map { local.contains($0.lowercased()) } ?? false }.count
        var text = logins.count == 1 ? "1 Claude login" : "\(logins.count) Claude logins"
        if shared > 0 { text += ", \(shared) also on this Mac" }
        return text
    }

    private func connect() {
        connecting = true
        result = nil
        Task {
            do {
                let logins = try await hub.connect(urlText: urlText, key: key)
                key = ""
                editing = false
                result = nil
                state.proxyChanged()
                if logins.isEmpty { result = "Connected, but the proxy holds no Claude login." }
            } catch let error as UsageError {
                result = Self.describe(error)
            } catch {
                result = error.localizedDescription
            }
            connecting = false
        }
    }

    static func describe(_ error: UsageError) -> String {
        switch error {
        case .proxyKeyRejected: return "The proxy rejected this key. Enter it again to retry."
        case .proxyBanned(let retryAfter):
            let wait = retryAfter.map { "Try again in \(max(1, Int(($0 / 60).rounded(.up)))) min. " } ?? ""
            return "The proxy blocked this Mac after too many wrong keys. \(wait)Close any management page that still sends an old key."
        case .offline: return "The proxy did not answer at this address."
        case .schemaChanged(let detail): return detail
        default: return String(describing: error)
        }
    }
}

/// An account another login pushed out of its folder. Muted, with a way to add it back.
struct ReplacedLoginRow: View {
    let entry: ReplacedLogin
    let onAddBack: () -> Void
    let onDismiss: () -> Void

    private var email: String { entry.email ?? "The previous account" }

    private var title: String {
        var parts = [email]
        if let plan = entry.planLabel { parts.append(plan) }
        parts.append("signed out on \(entry.replacedAt.formatted(date: .abbreviated, time: .omitted))")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Another account logged in to this folder. Give \(email) its own folder to track both.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Spacer()
                Button("Dismiss", action: onDismiss)
                Button("Add Back…", action: onAddBack)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

private struct AccountSettingsRow: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var monitor: AccountMonitor

    private var account: ClaudeAccount { monitor.account }
    @State private var confirmingRemove = false
    @State private var removing = false
    @State private var removeError: String?

    private var details: String {
        var parts: [String] = []
        if let email = account.email { parts.append(email) }
        if let plan = account.plan.label { parts.append(plan) }
        if let dir = account.configDir, !account.isDefault {
            parts.append(dir.path.replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
        } else if account.isDefault {
            parts.append("default login")
        }
        if account.isProxyOnly {
            parts.append("on the CLI proxy only")
        } else if account.proxyAuthIndex != nil {
            parts.append("read through the CLI proxy")
        }
        return parts.joined(separator: " · ")
    }

    private var status: String? {
        if account.isDormant(), let expired = account.tokenExpiresAt {
            return "Unused since \(expired.formatted(date: .abbreviated, time: .omitted)) — the token has expired."
        }
        return monitor.health.shortMessage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    "Name",
                    text: Binding(
                        get: { state.name(for: account) },
                        set: { state.rename(account, to: $0) }),
                    prompt: Text(account.suggestedName))
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .labelsHidden()
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !account.isDefault && !account.isProxyOnly {
                if removing {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Remove…") { confirmingRemove = true }
                        .controlSize(.small)
                }
            }
            Toggle(
                "Show",
                isOn: Binding(
                    get: { state.isVisible(account) },
                    set: { state.setVisible($0, for: account) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
        .confirmationDialog(
            "Remove \(state.name(for: account))?", isPresented: $confirmingRemove
        ) {
            Button("Sign Out and Remove", role: .destructive) {
                removing = true
                Task {
                    removeError = await state.remove(account)
                    removing = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(state.createdFolder(for: account)
                ? "Claude Code signs this account out, and cclimit moves its folder to the Trash."
                : "Claude Code signs this account out. Its folder stays where it is.")
        }
        .alert("Could not remove the account", isPresented: Binding(
            get: { removeError != nil }, set: { if !$0 { removeError = nil } })
        ) {
            Button("OK") { removeError = nil }
        } message: {
            Text(removeError ?? "")
        }
    }
}

enum LaunchAtLogin {
    // SMAppService needs a real bundle; bare `swift run` has none.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state so the toggle can snap back on failure.
    static func set(enabled: Bool) -> Bool {
        guard isAvailable else { return false }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin failed: \(error)")
        }
        return isEnabled
    }
}
