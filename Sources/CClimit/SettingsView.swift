import CClimitCore
import CClimitUI
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "menubar.rectangle") }
            LayoutSettings()
                .tabItem { Label("Layout", systemImage: "line.3.horizontal") }
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
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Polling") {
                Picker("While active", selection: $pollActiveSeconds) {
                    Text("60 s").tag(60)
                    Text("90 s").tag(90)
                    Text("120 s").tag(120)
                }
                Picker("While idle", selection: $pollIdleSeconds) {
                    Text("5 min").tag(300)
                    Text("10 min").tag(600)
                }
                Text("Conservative on purpose — the usage API rate-limits per token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    @AppStorage("sectionOrder") private var sectionOrderRaw = ""
    @AppStorage("hiddenSections") private var hiddenSectionsRaw = ""

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
        }
        .padding()
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
