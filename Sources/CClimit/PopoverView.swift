import CClimitCore
import CClimitUI
import SwiftUI

struct PopoverView: View {
    @ObservedObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @AppStorage("hiddenSections") private var hiddenSectionsRaw = ""
    @AppStorage("sectionOrder") private var sectionOrderRaw = ""

    private var hiddenSections: Set<String> {
        Set(hiddenSectionsRaw.split(separator: "\n").map(String.init))
    }

    /// Section IDs to render, in the user's stored order, filtered to the visible ones.
    private func visibleSections(_ snap: UsageSnapshot) -> [String] {
        let stored = sectionOrderRaw.split(separator: "\n").map(String.init)
        let seen = state.seenModelNames
        return SectionLayout.ordered(stored: stored, seenModels: seen)
            .filter { !hiddenSections.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = state.health.message {
                HealthBanner(message: message)
            }

            if let snap = state.snapshot {
                ForEach(Array(visibleSections(snap).enumerated()), id: \.element) { index, id in
                    if index > 0 && isDivided(id) { Divider() }
                    sectionView(id, snap: snap)
                }
            } else if !state.health.isError {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching usage…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { state.refreshAttributionIfStale() }
    }

    /// Forecast and attribution get a divider above them; window rows flow together.
    private func isDivided(_ id: String) -> Bool {
        id == SectionLayout.forecast || id == SectionLayout.attribution
    }

    @ViewBuilder
    private func sectionView(_ id: String, snap: UsageSnapshot) -> some View {
        switch id {
        case SectionLayout.fiveHour:
            WindowRow(title: "5-hour window", window: snap.fiveHour)
        case SectionLayout.weekly:
            WindowRow(title: "Weekly cap", window: snap.sevenDay)
        case SectionLayout.forecast:
            ForecastSection(fiveHour: state.fiveHourVerdict, weeklyForecasts: state.weeklyForecasts)
        case SectionLayout.attribution:
            if !state.burns.isEmpty { AttributionSection(burns: state.burns) }
        default:
            if let name = SectionLayout.modelName(id) {
                if let model = snap.perModelWindows.first(where: { $0.name == name }) {
                    WindowRow(
                        title: "Weekly · \(model.name)",
                        window: model.window,
                        badge: model.isActive ? "active" : nil)
                } else {
                    // Seen in a prior run but absent from the current snapshot: the per-model
                    // supplement (usage endpoint) hasn't answered yet — often because it's
                    // rate-limited. Render a blank bar so it's clear the row is pending, not
                    // that the limit is empty.
                    WindowRow(title: "Weekly · \(name)", window: nil, badge: "unavailable")
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let updated = state.lastUpdated {
                Text(
                    state.health.isError
                        ? "stale · \(Format.staleness(since: updated))"
                        : "updated \(Format.staleness(since: updated))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                state.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            Button {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit cclimit")
        }
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
    let title: String
    let window: UsageWindow?
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.medium))
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
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(UsageColor.number(utilization))
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            ProgressView(value: min(max(window?.utilization ?? 0, 0), 100), total: 100)
                .tint(window.map { UsageColor.bar($0.utilization ?? 0) } ?? .gray)
            if let reset = window?.resetsAt {
                Text("resets \(Format.resetStamp(reset)) · in \(Format.countdown(to: reset))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ForecastSection: View {
    let fiveHour: FiveHourVerdict
    let weeklyForecasts: [AppState.WeeklyForecast]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(fiveHourText, systemImage: fiveHourSymbol)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            // Every weekly window that has a meaningful verdict, binding one first.
            // Suppresses "pace fine" for non-binding windows to avoid a wall of green.
            ForEach(Array(weeklyForecasts.enumerated()), id: \.element.id) { index, forecast in
                if index == 0 || isNoteworthy(forecast.verdict) {
                    Label(weeklyText(forecast), systemImage: weeklySymbol(forecast.verdict))
                        .font(.callout)
                        .foregroundStyle(isAlarming(forecast.verdict) ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func isNoteworthy(_ verdict: WeeklyVerdict) -> Bool {
        switch verdict {
        case .likelyExhaustion, .exhausted: return true
        case .noData, .paceFine: return false
        }
    }

    private func isAlarming(_ verdict: WeeklyVerdict) -> Bool {
        if case .likelyExhaustion = verdict { return true }
        if case .exhausted = verdict { return true }
        return false
    }

    private var fiveHourSymbol: String {
        if case .willHitWall = fiveHour { return "exclamationmark.triangle" }
        return "gauge.with.needle"
    }

    private func weeklySymbol(_ verdict: WeeklyVerdict) -> String {
        isAlarming(verdict) ? "exclamationmark.triangle" : "calendar"
    }

    private var fiveHourText: String {
        switch fiveHour {
        case .noData:
            return "5-hour: collecting data…"
        case .exhausted(let reset):
            if let reset { return "5-hour limit reached — resets \(Format.clockTime(reset))." }
            return "5-hour limit reached."
        case .idle:
            return "5-hour: not burning right now."
        case .onPace(_, let reset):
            return "5-hour: pace is fine — resets \(Format.clockTime(reset)) before you'd hit it."
        case .willHitWall(let eta, let reset, _):
            var text = "5-hour: wall ≈ \(Format.clockTime(eta)) at this pace — in \(Format.countdown(to: eta))"
            if let reset { text += ", before reset (\(Format.countdown(to: reset)))" }
            return text + "."
        }
    }

    private func weeklyText(_ forecast: AppState.WeeklyForecast) -> String {
        let name = forecast.name
        switch forecast.verdict {
        case .noData:
            return "\(name): collecting data…"
        case .exhausted(let reset):
            if let reset { return "\(name) reached — resets \(Format.weekday(reset)) \(Format.clockTime(reset))." }
            return "\(name) reached."
        case .paceFine:
            return "\(name): pace is fine."
        case .likelyExhaustion(let earliest, let latest, _, _):
            return "\(name): runs out \(Format.etaRange(earliest: earliest, latest: latest)) at this pace."
        }
    }
}

private struct AttributionSection: View {
    let burns: [ProjectBurn]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Text("This window, by project")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Measured from your local Claude Code activity — each project's share of what you've spent this 5-hour window.")
                Spacer()
            }
            ForEach(burns.prefix(4)) { burn in
                HStack(spacing: 8) {
                    Text(burn.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    ShareBar(share: burn.share)
                        .frame(width: 60)
                    Text("\(Int((burn.share * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
    }
}

/// A thin monochrome proportion bar — attribution is informational, so it stays ink,
/// not the green/amber/red state ramp used for limits.
private struct ShareBar: View {
    let share: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.secondary)
                    .frame(width: max(3, geo.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}
