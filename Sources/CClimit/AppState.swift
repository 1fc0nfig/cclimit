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
    case rateLimited(retryAfter: TimeInterval?)
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
            return "Keychain access was denied. cclimit only reads the token Claude Code already stores — re-grant access, or log in via `claude` to create ~/.claude/.credentials.json."
        case .unauthorized:
            return "Token expired. Use `claude` once to refresh it — cclimit picks it up automatically."
        case .forbidden:
            return "This token can't read usage (missing user:profile scope). Log in with `claude`, not `claude setup-token`."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                let minutes = max(1, Int((retryAfter / 60).rounded(.up)))
                return "Rate limited by the usage API — retrying in ~\(minutes) min."
            }
            return "Rate limited by the usage API — backing off."
        case .offline:
            return "Network unreachable."
        case .schemaChanged:
            return "The usage API changed shape — check for a cclimit update."
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
    /// When the per-model (e.g. Fable) data was last fetched fresh from the usage endpoint.
    /// May lag `lastUpdated` (the always-fresh probe) when that endpoint is rate limited.
    @Published var perModelUpdated: Date?

    struct WeeklyForecast: Identifiable, Equatable {
        let name: String        // "Weekly cap" or a model name
        let utilization: Double?
        let verdict: WeeklyVerdict
        var id: String { name }
    }

    /// Previous 5h utilization, to detect a rise between polls and switch to active cadence.
    private var lastFiveHourUtil: Double?

    let sampleStore = SampleStore()
    /// UA tracks the Claude Code actually installed here; the pinned default is only a fallback.
    private static let ua = ClaudeCodeVersion.detect() ?? UsageClient.defaultUserAgentVersion
    /// PRIMARY source: 5h + weekly utilization from the unified rate-limit headers on a
    /// /v1/messages probe — the mechanism Claude Code uses. Rides the generous message limit
    /// instead of /api/oauth/usage's tiny per-account bucket, so it polls without penalties.
    private let probe = RateLimitProbe(userAgentVersion: AppState.ua)
    /// SUPPLEMENT: the usage endpoint, called rarely, only for the per-model (e.g. Fable)
    /// weekly breakdown the headers don't carry. Non-fatal — a 429 here just leaves per-model
    /// data stale; the header-driven 5h/weekly gauge keeps working.
    private let client = UsageClient(userAgentVersion: AppState.ua)
    /// Spacing between usage-endpoint supplement calls on success (respects its scarce budget).
    /// On a 429 we wait the server's Retry-After instead; on other errors, idle pace.
    private let perModelRefreshInterval: TimeInterval = 15 * 60
    private let perModelStore = PerModelStore()
    private var lastPerModelSnapshot: UsageSnapshot?
    /// When the next supplement fetch is allowed. Driven by the outcome of the last one:
    /// success → +interval, 429 → escalating backoff, other error → +idle. nil means fetch now.
    private var perModelNextFetch: Date?
    /// Consecutive 429s from the usage endpoint — drives the escalating backoff, since each
    /// contact re-triggers its penalty and retrying at a fixed cadence never lets it recover.
    private var perModelConsecutive429 = 0
    private let credentials = ChainedCredentialSource()
    /// In-memory only (product.md §5). Caching also matters for UX: reading the Keychain
    /// item every poll re-triggers the consent prompt whenever Claude Code has rewritten
    /// the item (each token refresh resets its ACL). Re-read only on expiry or 401.
    private var cachedCredentials: OAuthCredentials?
    private let notifier = Notifier()

    private var pollState = PollState()
    private var pollTask: Task<Void, Never>?
    private var wakeSignal: CheckedContinuation<Void, Never>?

    private let defaults = UserDefaults.standard

    init() {
        // Hydrate per-model data from the last run so Fable et al. show immediately (stale,
        // clearly stamped) instead of blank while the usage endpoint is rate limited.
        if let cached = perModelStore.load() {
            lastPerModelSnapshot = cached.snapshot
            perModelUpdated = cached.ts
        }
    }

    /// Union of per-model window names ever seen (e.g. ["Fable"]), for Settings + layout.
    var seenModelNames: [String] { defaults.stringArray(forKey: "seenModels") ?? [] }

    /// A note when per-model data is older than a refresh cycle (the usage endpoint has been
    /// unavailable), so the rows read as "last known", not current. Nil while fresh.
    var perModelStaleNote: String? {
        guard let updated = perModelUpdated else { return nil }
        guard Date().timeIntervalSince(updated) > perModelRefreshInterval + 120 else { return nil }
        return "updated \(Format.staleness(since: updated))"
    }

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
                    Log.poll.debug("paused (screen locked) — waiting for unlock")
                    await self.waitForWake()
                case .poll(let interval):
                    let reason = self.pollState.consecutiveRateLimits > 0
                        ? "rate-limit backoff (429 ×\(self.pollState.consecutiveRateLimits))"
                        : (self.pollState.consecutiveFailures > 0 ? "after failure" : "normal")
                    Log.poll.notice(
                        "next poll in \(Int(interval), privacy: .public)s · \(reason, privacy: .public)")
                    await self.sleepInterruptibly(interval)
                }
            }
        }
    }

    func refreshNow() {
        Log.poll.notice("manual refresh")
        wake()
    }

    /// Called when the popover opens. Fetches fresh data so the numbers reflect "now", not the
    /// last background poll — but throttled, so rapid re-opens don't spam the probe, and
    /// suppressed during an active rate-limit backoff so we never poke a live penalty.
    func refreshOnOpen() {
        let now = Date()
        if pollState.consecutiveRateLimits > 0 {
            Log.poll.debug("popover open · skip refresh (in rate-limit backoff)")
            return
        }
        if let last = lastUpdated, now.timeIntervalSince(last) < 15 {
            Log.poll.debug("popover open · skip refresh (updated \(Int(now.timeIntervalSince(last)), privacy: .public)s ago)")
            return
        }
        Log.poll.notice("popover open · refreshing")
        wake()
    }

    // MARK: - Poll cycle

    func pollOnce() async {
        let creds: OAuthCredentials
        if let cached = cachedCredentials, !cached.isExpired() {
            creds = cached
        } else {
            do {
                creds = try credentials.load()
                cachedCredentials = creds
            } catch CredentialError.accessDenied {
                health = .credentialAccessDenied
                pollState.recordFailure()
                return
            } catch {
                health = .noCredentials
                pollState.recordFailure()
                return
            }
        }

        let now = Date()
        do {
            // Primary: header-driven 5h + weekly. This is the poll that must not be starved.
            let probeSnap = try await probe.fetch(token: creds.accessToken)
            Log.poll.notice(
                "probe 200 · 5h=\(probeSnap.fiveHour?.utilization ?? -1, privacy: .public)% weekly=\(probeSnap.sevenDay?.utilization ?? -1, privacy: .public)%")
            let merged = await mergeWithPerModel(probeSnap, token: creds.accessToken, now: now)
            apply(snapshot: merged, at: now)
        } catch let error as UsageError {
            if case .unauthorized = error {
                // Token the store gave us is stale — drop it so the next cycle re-reads.
                cachedCredentials = nil
            }
            Log.poll.error("probe failed: \(String(describing: error), privacy: .public)")
            apply(error: error)
        } catch {
            Log.poll.error("probe threw non-UsageError: \(String(describing: error), privacy: .public)")
            health = .offline
            pollState.recordFailure()
        }
    }

    /// Fold the per-model weekly windows from the usage endpoint into the header snapshot.
    /// The supplement is fetched at most every `perModelRefreshInterval`; between fetches the
    /// last successful per-model data is reused. A failure here is swallowed on purpose — the
    /// header-driven 5h/weekly gauge is what the user relies on, and the usage endpoint's
    /// budget is too scarce to let its 429s degrade the primary reading.
    private func mergeWithPerModel(
        _ probeSnap: UsageSnapshot, token: String, now: Date
    ) async -> UsageSnapshot {
        let due = perModelNextFetch.map { now >= $0 } ?? true
        if due {
            do {
                let full = try await client.fetch(token: token)
                lastPerModelSnapshot = full
                perModelUpdated = now
                perModelConsecutive429 = 0
                perModelStore.save(full, at: now)
                perModelNextFetch = now.addingTimeInterval(perModelRefreshInterval)
                Log.poll.notice(
                    "supplement 200 · models=[\(full.perModelWindows.map(\.name).joined(separator: ","), privacy: .public)]")
            } catch let error as UsageError {
                let wait: TimeInterval
                if case .rateLimited(let retryAfter) = error {
                    perModelConsecutive429 += 1
                    // This endpoint RE-TRIGGERS its penalty on any contact — a clean retry after
                    // the stated window still came back with a fresh 3600s (observed 2026-07-16).
                    // So honoring Retry-After alone just keeps it hot forever. Escalate hard on
                    // repeats (15m→30m→1h→2h→4h, cap 6h) to give it real quiet time, with the
                    // server's Retry-After as a floor.
                    let escalated = min(
                        perModelRefreshInterval * pow(2, Double(min(perModelConsecutive429 - 1, 5))),
                        6 * 3600)
                    let serverFloor = (retryAfter.map { min($0, PollPolicy.retryAfterCeiling) } ?? 0)
                        + PollPolicy.retryAfterMargin
                    wait = max(escalated, serverFloor)
                    Log.poll.notice(
                        "supplement 429 (×\(self.perModelConsecutive429, privacy: .public), retry-after=\(retryAfter.map { String(Int($0)) } ?? "none", privacy: .public)s) · backing off \(Int(wait), privacy: .public)s · keeping \(self.lastPerModelSnapshot == nil ? "no" : "cached", privacy: .public) data")
                } else {
                    wait = policy.idleInterval
                    Log.poll.notice(
                        "supplement \(String(describing: error), privacy: .public) · next in \(Int(wait), privacy: .public)s")
                }
                perModelNextFetch = now.addingTimeInterval(wait)
            } catch {
                perModelNextFetch = now.addingTimeInterval(policy.idleInterval)
                Log.poll.notice("supplement failed: \(String(describing: error), privacy: .public)")
            }
        }
        guard let supplement = lastPerModelSnapshot else { return probeSnap }
        // Header values win for 5h/weekly (always fresh); borrow only per-model + extra usage.
        return UsageSnapshot(
            fiveHour: probeSnap.fiveHour ?? supplement.fiveHour,
            sevenDay: probeSnap.sevenDay ?? supplement.sevenDay,
            sevenDayOpus: supplement.sevenDayOpus,
            sevenDaySonnet: supplement.sevenDaySonnet,
            limits: supplement.limits,
            extraUsage: supplement.extraUsage)
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
        case .rateLimited(let retryAfter):
            Log.poll.error(
                "RATE LIMITED (429) · server Retry-After=\(retryAfter.map { String(Int($0)) } ?? "none", privacy: .public)s · consecutive=\(self.pollState.consecutiveRateLimits + 1, privacy: .public)")
            health = .rateLimited(retryAfter: retryAfter)
            pollState.recordRateLimit(retryAfter: retryAfter)
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

    /// Invalidates timers from earlier sleeps. Without this, a sleep cut short by a manual
    /// refresh or unlock leaves its timer pending, and that stale timer later wakes the NEXT
    /// sleep early — polls creep faster than policy, which can hammer through a 429 penalty.
    private var sleepGeneration = 0

    private func sleepInterruptibly(_ interval: TimeInterval) async {
        sleepGeneration += 1
        let generation = sleepGeneration
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wakeSignal = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                guard let self, self.sleepGeneration == generation else { return }
                self.wake()
            }
        }
    }

    private func waitForWake() async {
        sleepGeneration += 1  // orphan any timer from the sleep this pause replaced
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
