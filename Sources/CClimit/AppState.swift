import AppKit
import CClimitCore
import Foundation
import SwiftUI

/// Connection health, mapped 1:1 from the failure-mode matrix in product.md §5.
/// Every state renders as something honest — never a stale green.
enum Health: Equatable {
    case starting
    case ok
    case noCredentials
    case credentialAccessDenied
    case unauthorized
    case forbidden
    case rateLimited
    case offline
    case schemaChanged

    var isError: Bool { self != .ok && self != .starting }

    var message: String? {
        switch self {
        case .starting, .ok:
            return nil
        case .noCredentials:
            return "No Claude Code credentials found. Install Claude Code and run `claude` once to log in."
        case .credentialAccessDenied:
            return "Keychain access was denied. CClimit only reads the token Claude Code already stores — re-grant access, or log in via `claude` to create ~/.claude/.credentials.json."
        case .unauthorized:
            return "Token expired. Use `claude` once to refresh it — CClimit picks it up automatically."
        case .forbidden:
            return "This token can't read usage (missing user:profile scope). Log in with `claude`, not `claude setup-token`."
        case .rateLimited:
            return "Rate limited by the usage API — backing off."
        case .offline:
            return "Network unreachable."
        case .schemaChanged:
            return "The usage API changed shape — check for a CClimit update."
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var lastUpdated: Date?
    @Published var health: Health = .starting
    @Published var fiveHourVerdict: FiveHourVerdict = .noData
    /// Forecast for every weekly window: overall ("Weekly cap") first, then each model
    /// (e.g. Fable). Highest-utilization first so the binding one leads.
    @Published var weeklyForecasts: [WeeklyForecast] = []
    @Published var burns: [ProjectBurn] = []
    @Published var burnsUpdated: Date?

    struct WeeklyForecast: Identifiable, Equatable {
        let name: String        // "Weekly cap" or a model name
        let utilization: Double?
        let verdict: WeeklyVerdict
        var id: String { name }
    }

    /// Previous 5h utilization, to detect a rise between polls and switch to active cadence.
    private var lastFiveHourUtil: Double?

    let sampleStore = SampleStore()
    private let client = UsageClient()
    private let credentials = ChainedCredentialSource()
    private let notifier = Notifier()

    private var pollState = PollState()
    private var pollTask: Task<Void, Never>?
    private var wakeSignal: CheckedContinuation<Void, Never>?

    private let defaults = UserDefaults.standard

    /// Union of per-model window names ever seen (e.g. ["Fable"]), for Settings + layout.
    var seenModelNames: [String] { defaults.stringArray(forKey: "seenModels") ?? [] }

    var policy: PollPolicy {
        PollPolicy(
            activeInterval: TimeInterval(defaults.object(forKey: "pollActiveSeconds") as? Int ?? 60),
            idleInterval: TimeInterval(defaults.object(forKey: "pollIdleSeconds") as? Int ?? 300)
        )
    }

    func start() {
        observeScreenLock()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                let decision = nextPoll(policy: self.policy, state: self.pollState)
                switch decision {
                case .paused:
                    await self.waitForWake()
                case .poll(let interval):
                    await self.sleepInterruptibly(interval)
                }
            }
        }
    }

    func refreshNow() {
        wake()
    }

    // MARK: - Poll cycle

    func pollOnce() async {
        let creds: OAuthCredentials
        do {
            creds = try credentials.load()
        } catch CredentialError.accessDenied {
            health = .credentialAccessDenied
            pollState.recordFailure()
            return
        } catch {
            health = .noCredentials
            pollState.recordFailure()
            return
        }

        do {
            let snap = try await client.fetch(token: creds.accessToken)
            apply(snapshot: snap, at: Date())
        } catch let error as UsageError {
            apply(error: error)
        } catch {
            health = .offline
            pollState.recordFailure()
        }
    }

    private func apply(snapshot snap: UsageSnapshot, at now: Date) {
        snapshot = snap
        lastUpdated = now
        health = .ok
        pollState.recordSuccess()

        sampleStore.append(Sample(ts: now, snapshot: snap))
        rememberModelNames(snap.perModelWindows.map(\.name))
        recomputeForecasts(now: now)

        // Switch to active (60s) cadence the moment usage moves, not only once the forecast
        // has already confirmed a burn — otherwise idle 5-min polling never gathers the
        // closely-spaced samples the forecast needs (a deadlock).
        let currentFiveHour = snap.fiveHour?.utilization
        let rising: Bool
        if let current = currentFiveHour, let previous = lastFiveHourUtil {
            rising = current > previous + 0.001
        } else {
            rising = false
        }
        lastFiveHourUtil = currentFiveHour
        pollState.activelyBurning = rising || {
            if case .onPace = fiveHourVerdict { return true }
            if case .willHitWall = fiveHourVerdict { return true }
            return false
        }()

        notifier.evaluate(snapshot: snap, fiveHourVerdict: fiveHourVerdict, now: now)
    }

    private func apply(error: UsageError) {
        switch error {
        case .rateLimited:
            health = .rateLimited
            pollState.recordRateLimit()
        case .unauthorized:
            // Claude Code refreshes the token on use; our next cycle re-reads the store.
            health = .unauthorized
            pollState.recordFailure()
        case .forbidden:
            health = .forbidden
            pollState.recordFailure()
        case .offline:
            health = .offline
            pollState.recordFailure()
        case .schemaChanged:
            health = .schemaChanged
            pollState.recordFailure()
        case .noCredentials:
            health = .noCredentials
            pollState.recordFailure()
        case .credentialAccessDenied:
            health = .credentialAccessDenied
            pollState.recordFailure()
        }
    }

    /// Persist the union of model names ever seen so Settings can offer a toggle per model,
    /// even for one not present in the latest poll.
    private func rememberModelNames(_ names: [String]) {
        guard !names.isEmpty else { return }
        var seen = Set(defaults.stringArray(forKey: "seenModels") ?? [])
        let before = seen.count
        seen.formUnion(names)
        if seen.count != before {
            defaults.set(seen.sorted(), forKey: "seenModels")
        }
    }

    private func recomputeForecasts(now: Date) {
        let samples = sampleStore.load(since: now.addingTimeInterval(-4 * 24 * 3600))
        fiveHourVerdict = ForecastEngine.fiveHour(samples: samples, now: now)

        // Forecast every weekly window — overall and each per-model — so the one the user
        // actually burns (e.g. Fable) gets a prediction, not just the aggregate cap.
        var forecasts: [WeeklyForecast] = [
            WeeklyForecast(
                name: "Weekly cap",
                utilization: snapshot?.sevenDay?.utilization,
                verdict: ForecastEngine.weekly(samples: samples, now: now))
        ]
        for model in snapshot?.perModelWindows ?? [] {
            forecasts.append(
                WeeklyForecast(
                    name: "\(model.name) weekly",
                    utilization: model.window.utilization,
                    verdict: ForecastEngine.weeklyForModel(model.name, samples: samples, now: now)))
        }
        // Binding (highest utilization) first.
        weeklyForecasts = forecasts.sorted { ($0.utilization ?? 0) > ($1.utilization ?? 0) }
    }

    // MARK: - Attribution (computed lazily on popover open, throttled)

    func refreshAttributionIfStale() {
        let now = Date()
        if let last = burnsUpdated, now.timeIntervalSince(last) < 300 { return }
        burnsUpdated = now
        let windowStart = snapshot?.fiveHour?.resetsAt.map { $0.addingTimeInterval(-5 * 3600) }
            ?? now.addingTimeInterval(-5 * 3600)
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                AttributionEngine.burn(since: windowStart, now: now)
            }.value
            self?.burns = result
        }
    }

    // MARK: - Sleep / wake plumbing

    private func sleepInterruptibly(_ interval: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wakeSignal = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.wake()
            }
        }
    }

    private func waitForWake() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wakeSignal = cont
        }
    }

    private func wake() {
        wakeSignal?.resume()
        wakeSignal = nil
    }

    private func observeScreenLock() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pollState.screenLocked = true }
        }
        center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollState.screenLocked = false
                self?.wake()
            }
        }
    }
}
