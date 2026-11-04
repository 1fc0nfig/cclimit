import AppKit
import CClimitCore
import Combine
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
    case claudeCodeNotFound
    case claudeCodeFailed
    case proxyKeyRejected
    case proxyBanned(retryAfter: TimeInterval?)
    case proxyLoginGone

    var isError: Bool { self != .ok && self != .starting }

    /// Two or three words for a compact account row in the pooled view.
    var shortMessage: String? {
        switch self {
        case .starting, .ok: return nil
        case .noCredentials: return "Not signed in"
        case .credentialAccessDenied: return "Keychain access denied"
        case .unauthorized: return "Token expired"
        case .forbidden: return "No usage access"
        case .rateLimited: return "Rate limited"
        case .offline: return "Offline"
        case .schemaChanged: return "API changed"
        case .claudeCodeNotFound: return "Claude Code not found"
        case .claudeCodeFailed: return "Claude Code did not answer"
        case .proxyKeyRejected: return "Proxy key rejected"
        case .proxyBanned: return "Proxy blocked this Mac"
        case .proxyLoginGone: return "Not on the proxy"
        }
    }

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
        case .claudeCodeNotFound:
            return "cclimit reads usage through Claude Code, but it cannot find the `claude` command. Install Claude Code, or switch the usage source to Direct in Settings."
        case .claudeCodeFailed:
            return "Claude Code started but did not answer. cclimit tries again at the next poll. Run `claude` once to check that it works."
        case .proxyKeyRejected:
            return "The CLI proxy rejected the management key. cclimit stopped asking, because wrong keys get this Mac banned. Enter the key again in Settings > Accounts."
        case .proxyBanned(let retryAfter):
            let wait = retryAfter.map { " for ~\(max(1, Int(($0 / 60).rounded(.up)))) min" } ?? ""
            return "The CLI proxy blocked this Mac\(wait) after too many wrong keys. Another client, such as an open management page, may still send an old key."
        case .proxyLoginGone:
            return "The CLI proxy no longer holds this login."
        }
    }
}

/// Polls one Claude Code login: credentials, probe, per-model supplement, forecasts,
/// notifications, attribution. `AppState` owns one monitor per discovered account.
@MainActor
final class AccountMonitor: ObservableObject, Identifiable {
    @Published private(set) var account: ClaudeAccount
    @Published var snapshot: UsageSnapshot?
    @Published var lastUpdated: Date?
    @Published var health: Health = .starting
    @Published var fiveHourVerdict: FiveHourVerdict = .noData
    /// Forecast for every weekly window: overall ("Weekly cap") first, then each model
    /// (e.g. Fable). Highest-utilization first so the binding one leads.
    @Published var weeklyForecasts: [WeeklyForecast] = []
    /// What each window's bar draws past its fill, keyed by section id (SectionLayout).
    @Published var projections: [String: Projection] = [:]
    /// When the per-model (e.g. Fable) data was last fetched fresh from the usage endpoint.
    /// May lag `lastUpdated` (the always-fresh probe) when that endpoint is rate limited.
    @Published var perModelUpdated: Date?

    struct WeeklyForecast: Identifiable, Equatable {
        let name: String        // "Weekly cap" or a model name
        let utilization: Double?
        let verdict: WeeklyVerdict
        var id: String { name }
    }

    nonisolated var id: String { accountID }
    private nonisolated let accountID: String

    /// Prefix for notifications ("Work: …"). Set by `AppState`, nil while only one account shows.
    var notificationLabel: String?

    /// Previous 5h utilization (weekly without a 5h window), to detect a rise between polls
    /// and switch to active cadence.
    private var lastActivityUtil: Double?

    let sampleStore: SampleStore
    /// UA tracks the Claude Code actually installed here; the pinned default is only a fallback.
    static let ua = ClaudeCodeVersion.detect() ?? UsageClient.defaultUserAgentVersion
    /// PRIMARY source: 5h + weekly utilization from the unified rate-limit headers on a
    /// /v1/messages probe — the mechanism Claude Code uses. Rides the generous message limit
    /// instead of /api/oauth/usage's tiny per-account bucket, so it polls without penalties.
    private let probe = RateLimitProbe(userAgentVersion: AccountMonitor.ua)
    /// SUPPLEMENT: the usage endpoint, called rarely, only for the per-model (e.g. Fable)
    /// weekly breakdown the headers don't carry. Non-fatal — a 429 here just leaves per-model
    /// data stale; the header-driven 5h/weekly gauge keeps working.
    private let client = UsageClient(userAgentVersion: AccountMonitor.ua)
    /// Spacing between usage-endpoint supplement calls on success (respects its scarce budget).
    /// On a 429 we wait the server's Retry-After instead; on other errors, idle pace.
    private let perModelRefreshInterval: TimeInterval = 15 * 60
    private let perModelStore: PerModelStore
    private var lastPerModelSnapshot: UsageSnapshot?
    /// When the next supplement fetch is allowed. Driven by the outcome of the last one:
    /// success → +interval, 429 → escalating backoff, other error → +idle. nil means fetch now.
    private var perModelNextFetch: Date?
    /// Consecutive 429s from the usage endpoint — drives the escalating backoff, since each
    /// contact re-triggers its penalty and retrying at a fixed cadence never lets it recover.
    private var perModelConsecutive429 = 0
    private var credentials: ChainedCredentialSource
    /// In-memory only (product.md §5). Reads go through `/usr/bin/security`, which the item's
    /// ACL always trusts, so they never prompt. Caching still saves a subprocess per poll:
    /// re-read only on expiry or 401.
    private var cachedCredentials: OAuthCredentials?
    private let notifier: Notifier
    /// Project stats from this login's transcripts. The index is persisted, so a 30-day
    /// range costs one full scan, ever.
    let transcripts: TranscriptReports
    private var transcriptsChanged: AnyCancellable?

    /// A manual refresh is in flight. The footer shows a spinner until its poll ends.
    @Published private(set) var isRefreshing = false
    /// A refresh asked for while a poll ran. The loop polls again instead of sleeping.
    private var refreshRequested = false

    private var pollState = PollState()
    private var pollTask: Task<Void, Never>?
    private var wakeSignal: CheckedContinuation<Void, Never>?

    private let defaults = UserDefaults.standard

    init(account: ClaudeAccount) {
        self.account = account
        self.accountID = account.id
        // Per-account files. The default login keeps the original names, so history survives.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CClimit", isDirectory: true)
        sampleStore = SampleStore(fileURL: dir.appendingPathComponent("samples\(account.storageSuffix).jsonl"))
        perModelStore = PerModelStore(fileURL: dir.appendingPathComponent("per-model\(account.storageSuffix).json"))
        credentials = Self.credentials(for: account)
        notifier = Notifier(keySuffix: account.storageSuffix)
        transcripts = TranscriptReports(index: Self.transcriptIndex(for: account))
        // Hydrate per-model data from the last run so Fable et al. show immediately (stale,
        // clearly stamped) instead of blank while the usage endpoint is rate limited.
        if let cached = perModelStore.load() {
            lastPerModelSnapshot = cached.snapshot
            perModelUpdated = cached.ts
        }
        // A report landing redraws whatever shows this account.
        transcriptsChanged = transcripts.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private static var dataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CClimit", isDirectory: true)
    }

    private static func credentials(for account: ClaudeAccount) -> ChainedCredentialSource {
        let file: CredentialSource = account.isDefault
            ? FileCredentialSource()
            : (account.configDir.map { FileCredentialSource(configDir: $0) }
                ?? FileCredentialSource(url: dataDir.appendingPathComponent("none")))
        return ChainedCredentialSource(sources: [
            SecurityToolCredentialSource(service: account.service), file,
        ])
    }

    /// A second login with no known folder gets no transcripts: the default folder's
    /// projects belong to the default login, not to this one.
    private static func transcriptIndex(for account: ClaudeAccount) -> TranscriptIndex {
        let root = account.projectsDir
            ?? (account.isDefault ? AttributionEngine.defaultRoot() : dataDir.appendingPathComponent("none"))
        return TranscriptIndex(
            root: root, storeURL: dataDir.appendingPathComponent("transcripts\(account.storageSuffix).plist"))
    }

    /// Rediscovery found new metadata for this login (plan change, renamed config dir).
    func update(account: ClaudeAccount) {
        guard account != self.account else { return }
        let folderChanged = account.configDir != self.account.configDir
        if account.proxyAuthIndex != self.account.proxyAuthIndex {
            // Another source answers now: fetch its full payload at the next poll.
            perModelNextFetch = nil
            perModelConsecutive429 = 0
        }
        self.account = account
        if folderChanged {
            // The folder resolved later: read its token and transcripts, not the fallback.
            credentials = Self.credentials(for: account)
            cachedCredentials = nil
            transcripts.replace(index: Self.transcriptIndex(for: account))
        }
    }

    /// A removed or replaced login: its history must not come back under the same id.
    /// The files move to `CClimit/Replaced`, not the Trash, so a mistake can be undone.
    func discardHistory() {
        stop()
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        let archive = Self.dataDir.appendingPathComponent("Replaced", isDirectory: true)
        try? fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let suffix = account.storageSuffix
        for name in ["samples\(suffix).jsonl", "per-model\(suffix).json", "transcripts\(suffix).plist"] {
            let file = Self.dataDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: file.path) else { continue }
            try? fm.moveItem(at: file, to: archive.appendingPathComponent("\(stamp)-\(name)"))
        }
        let prefix = "notified\(suffix)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// The banner text. A second login refreshes through its own config dir, so the generic
    /// "use `claude` once" advice would point at the wrong account.
    var healthMessage: String? {
        guard !account.isDefault else { return health.message }
        let command = account.configDir.map { "`CLAUDE_CONFIG_DIR=\(Self.tildePath($0)) claude`" }
            ?? "Claude Code with this account"
        switch health {
        case .unauthorized:
            return "Token expired. Run \(command) once to refresh it — cclimit picks it up automatically."
        case .noCredentials:
            return "This login is gone from the Keychain. Run \(command) and log in again."
        default:
            return health.message
        }
    }

    private static func tildePath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    /// Union of per-model window names ever seen (e.g. ["Fable"]), for Settings + layout.
    var seenModelNames: [String] { defaults.stringArray(forKey: "seenModels") ?? [] }

    /// A note when per-model data is older than a refresh cycle (the usage endpoint has been
    /// unavailable), so the rows read as "last known", not current. Nil while fresh.
    func perModelStaleNote(now: Date = Date()) -> String? {
        guard let updated = perModelUpdated else { return nil }
        guard now.timeIntervalSince(updated) > perModelRefreshInterval + 120 else { return nil }
        return "updated \(Format.staleness(since: updated, now: now))"
    }

    var policy: PollPolicy {
        if readsThroughClaudeCode {
            // `get_usage` spends the usage endpoint's small budget, which Claude Code's own
            // `/usage` shares. Ten minutes keeps both clear of its penalties.
            return PollPolicy(
                activeInterval: Self.claudeCodeInterval, idleInterval: Self.claudeCodeInterval,
                backoffFloor: Self.claudeCodeInterval, backoffCap: 6 * 3600)
        }
        return PollPolicy(
            activeInterval: TimeInterval(defaults.object(forKey: "pollActiveSeconds") as? Int ?? 60),
            idleInterval: TimeInterval(defaults.object(forKey: "pollIdleSeconds") as? Int ?? 300)
        )
    }

    static let claudeCodeInterval: TimeInterval = 10 * 60

    /// Settings > General > Usage source. "claudeCode" asks Claude Code for every reading and
    /// never reads the Keychain. "direct" (the default) reads Claude Code's token for the
    /// fast header probe and still asks Claude Code for the per-model supplement.
    var readsThroughClaudeCode: Bool { defaults.string(forKey: "usageSource") == "claudeCode" }

    /// Claude Code, started with this account's config dir. Nil for a second login whose
    /// folder is unknown: without `CLAUDE_CONFIG_DIR`, `claude` answers for the default login.
    private var claudeCode: ClaudeCodeUsageSource? {
        if account.isDefault { return ClaudeCodeUsageSource(configDir: nil) }
        return account.configDir.map { ClaudeCodeUsageSource(configDir: $0) }
    }

    var isRunning: Bool { pollTask != nil }

    func start() {
        guard pollTask == nil else { return }
        transcripts.warm()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshRequested = false
                await self.pollOnce()
                self.isRefreshing = false
                let decision = nextPoll(policy: self.policy, state: self.pollState)
                switch decision {
                case .paused:
                    Log.poll.debug("[\(self.accountID, privacy: .public)] paused (screen locked) — waiting for unlock")
                    await self.waitForWake()
                case .poll(let interval):
                    let reason = self.pollState.consecutiveRateLimits > 0
                        ? "rate-limit backoff (429 ×\(self.pollState.consecutiveRateLimits))"
                        : (self.pollState.consecutiveFailures > 0 ? "after failure" : "normal")
                    Log.poll.notice("[\(self.accountID, privacy: .public)] next poll in \(Int(interval), privacy: .public)s · \(reason, privacy: .public)")
                    await self.sleepInterruptibly(interval)
                }
            }
        }
    }

    /// Stops polling, for an account the user hid or that left the Keychain.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isRefreshing = false
        refreshRequested = false
        wake()
    }

    func setScreenLocked(_ locked: Bool) {
        pollState.screenLocked = locked
        if !locked { wake() }
    }

    func refreshNow() {
        Log.poll.notice("[\(self.accountID, privacy: .public)] manual refresh")
        guard isRunning else { return }
        isRefreshing = true
        requestPoll()
    }

    /// Wakes a sleeping loop, or marks a running poll to go again: a click during a poll
    /// used to do nothing.
    private func requestPoll() {
        if wakeSignal == nil { refreshRequested = true }
        wake()
    }

    /// Called when the popover opens. Fetches fresh data so the numbers reflect "now", not the
    /// last background poll — but throttled, so rapid re-opens don't spam the probe, and
    /// suppressed during an active rate-limit backoff so we never poke a live penalty.
    func refreshOnOpen() {
        let now = Date()
        if pollState.consecutiveRateLimits > 0 {
            Log.poll.debug("[\(self.accountID, privacy: .public)] popover open · skip refresh (in rate-limit backoff)")
            return
        }
        // Through Claude Code a reading spends the usage endpoint's small budget: never
        // sooner than the poll interval chosen to protect it.
        let fresh: TimeInterval = readsThroughClaudeCode ? Self.claudeCodeInterval : 15
        if let last = lastUpdated, now.timeIntervalSince(last) < fresh {
            Log.poll.debug("[\(self.accountID, privacy: .public)] popover open · skip refresh (updated \(Int(now.timeIntervalSince(last)), privacy: .public)s ago)")
            return
        }
        Log.poll.notice("[\(self.accountID, privacy: .public)] popover open · refreshing")
        // Only a sleeping loop: a poll in flight already brings fresh numbers.
        wake()
    }

    // MARK: - Poll cycle

    func pollOnce() async {
        if let index = account.proxyAuthIndex, ProxyHub.shared.isConfigured {
            await pollThroughProxy(authIndex: index)
            return
        }
        if account.isProxyOnly {
            // The proxy was disconnected. Discovery drops this account at its next run.
            apply(error: .proxyLoginGone)
            return
        }
        if readsThroughClaudeCode {
            await pollThroughClaudeCode()
            return
        }
        let creds: OAuthCredentials
        if let cached = cachedCredentials, !cached.isExpired() {
            creds = cached
        } else {
            do {
                // `security` is a child process: keep it off the main thread, or a popover
                // opened during a poll waits for it.
                let source = credentials
                creds = try await Task.detached(priority: .userInitiated) { try source.load() }.value
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
            Log.poll.notice("[\(self.accountID, privacy: .public)] probe 200 · 5h=\(probeSnap.fiveHour?.utilization ?? -1, privacy: .public)% weekly=\(probeSnap.sevenDay?.utilization ?? -1, privacy: .public)%")
            if snapshot == nil {
                // The first reading shows at once. The supplement can take Claude Code
                // several seconds to answer, and the popover must not wait on it.
                snapshot = Self.combine(probeSnap, with: lastPerModelSnapshot)
                lastUpdated = now
                health = .ok
            }
            let merged = await mergeWithPerModel(probeSnap, token: creds.accessToken, now: now)
            await apply(snapshot: merged, at: now)
        } catch let error as UsageError {
            if case .unauthorized = error {
                // Token the store gave us is stale — drop it so the next cycle re-reads.
                cachedCredentials = nil
            }
            Log.poll.error("[\(self.accountID, privacy: .public)] probe failed: \(String(describing: error), privacy: .public)")
            apply(error: error)
        } catch {
            Log.poll.error("[\(self.accountID, privacy: .public)] probe threw non-UsageError: \(String(describing: error), privacy: .public)")
            health = .offline
            pollState.recordFailure()
        }
    }

    /// One reading from Claude Code: 5h, weekly, and per-model in one answer, no token read.
    private func pollThroughClaudeCode() async {
        let now = Date()
        do {
            guard let claudeCode else {
                // No folder means no way to ask Claude Code for this login.
                apply(error: .noCredentials)
                return
            }
            let reading = try await claudeCode.fetch()
            // Stopped while Claude Code answered (hidden, removed, replaced): write nothing.
            guard !Task.isCancelled else { return }
            let snap = reading.snapshot
            Log.poll.notice("[\(self.accountID, privacy: .public)] claude get_usage · 5h=\(snap.fiveHour?.utilization ?? -1, privacy: .public)% weekly=\(snap.sevenDay?.utilization ?? -1, privacy: .public)% models=[\(snap.perModelWindows.map(\.name).joined(separator: ","), privacy: .public)]")
            lastPerModelSnapshot = snap
            perModelUpdated = now
            perModelStore.save(snap, at: now)
            await apply(snapshot: snap, at: now)
        } catch let error as UsageError {
            Log.poll.error("[\(self.accountID, privacy: .public)] claude get_usage failed: \(String(describing: error), privacy: .public)")
            apply(error: error)
        } catch {
            health = .offline
            pollState.recordFailure()
        }
    }

    /// One reading through the CLI proxy. 5h and weekly come from the headers the proxy saw
    /// on real traffic, at no cost. The full payload (per-model windows, and fresh numbers
    /// when no traffic went through for a while) comes from `api-call` on the supplement's
    /// schedule and backoff. Whichever of the two is newer gives 5h and weekly.
    private func pollThroughProxy(authIndex: String) async {
        let now = Date()
        let hub = ProxyHub.shared
        do {
            guard let login = try await hub.logins(now: now).first(where: { $0.authIndex == authIndex }) else {
                throw UsageError.proxyLoginGone
            }
            guard !Task.isCancelled else { return }
            let signals = login.signals.map { Self.expiringPastResets($0, now: now) }
            Log.poll.notice("[\(self.accountID, privacy: .public)] proxy · 5h=\(signals?.fiveHour?.utilization ?? -1, privacy: .public)% weekly=\(signals?.sevenDay?.utilization ?? -1, privacy: .public)% observed \(login.observedAt.map { Int(now.timeIntervalSince($0)) } ?? -1, privacy: .public)s ago")
            await updateSupplement(now: now) {
                try await hub.usage(authIndex: authIndex, userAgentVersion: AccountMonitor.ua)
            }
            guard !Task.isCancelled else { return }
            let full = lastPerModelSnapshot.map { Self.expiringPastResets($0, now: now) }
            let merged: UsageSnapshot
            if let signals, let full {
                let signalsNewer = (login.observedAt ?? .distantPast) > (perModelUpdated ?? .distantPast)
                merged = signalsNewer ? Self.combine(signals, with: full) : full
            } else if let any = signals ?? full {
                merged = any
            } else {
                // No traffic seen yet and no payload: nothing honest to show.
                throw UsageError.schemaChanged("the proxy has no usage for this login yet")
            }
            await apply(snapshot: merged, at: now)
        } catch let error as UsageError {
            Log.poll.error("[\(self.accountID, privacy: .public)] proxy failed: \(String(describing: error), privacy: .public)")
            apply(error: error)
        } catch {
            health = .offline
            pollState.recordFailure()
        }
    }

    /// A window read some time ago may have reset since. Past its reset it holds nothing.
    private static func expiringPastResets(_ snap: UsageSnapshot, now: Date) -> UsageSnapshot {
        func fresh(_ window: UsageWindow?) -> UsageWindow? {
            guard let window, let reset = window.resetsAt, reset <= now else { return window }
            return UsageWindow(utilization: 0, resetsAt: nil)
        }
        let limits = snap.limits?.map { limit -> Limit in
            guard let reset = limit.resetsAt, reset <= now else { return limit }
            return Limit(kind: limit.kind, group: limit.group, percent: 0, resetsAt: nil,
                         isActive: limit.isActive, severity: limit.severity, scope: limit.scope)
        }
        return UsageSnapshot(
            fiveHour: fresh(snap.fiveHour), sevenDay: fresh(snap.sevenDay),
            sevenDayOpus: fresh(snap.sevenDayOpus), sevenDaySonnet: fresh(snap.sevenDaySonnet),
            limits: limits, extraUsage: snap.extraUsage)
    }

    /// The supplement through Claude Code, so cclimit does not spend the usage endpoint's
    /// budget with the token itself. Falls back to the direct call only without Claude Code.
    private func fetchSupplement(token: String) async throws -> UsageSnapshot {
        guard let claudeCode else { return try await client.fetch(token: token) }
        do {
            return try await claudeCode.fetch().snapshot
        } catch UsageError.claudeCodeNotFound {
            return try await client.fetch(token: token)
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
        await updateSupplement(now: now) { try await self.fetchSupplement(token: token) }
        if Task.isCancelled { return probeSnap }
        return Self.combine(probeSnap, with: lastPerModelSnapshot)
    }

    /// Fetches the full usage payload when it is due, and schedules the next fetch from the
    /// outcome. The result lands in `lastPerModelSnapshot`.
    private func updateSupplement(now: Date, fetch: () async throws -> UsageSnapshot) async {
        let due = perModelNextFetch.map { now >= $0 } ?? true
        if due {
            do {
                let full = try await fetch()
                if Task.isCancelled { return }
                lastPerModelSnapshot = full
                perModelUpdated = now
                perModelConsecutive429 = 0
                perModelStore.save(full, at: now)
                perModelNextFetch = now.addingTimeInterval(perModelRefreshInterval)
                Log.poll.notice("[\(self.accountID, privacy: .public)] supplement 200 · models=[\(full.perModelWindows.map(\.name).joined(separator: ","), privacy: .public)]")
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
                    Log.poll.notice("[\(self.accountID, privacy: .public)] supplement 429 (×\(self.perModelConsecutive429, privacy: .public), retry-after=\(retryAfter.map { String(Int($0)) } ?? "none", privacy: .public)s) · backing off \(Int(wait), privacy: .public)s · keeping \(self.lastPerModelSnapshot == nil ? "no" : "cached", privacy: .public) data")
                } else {
                    wait = policy.idleInterval
                    Log.poll.notice("[\(self.accountID, privacy: .public)] supplement \(String(describing: error), privacy: .public) · next in \(Int(wait), privacy: .public)s")
                }
                perModelNextFetch = now.addingTimeInterval(wait)
            } catch {
                perModelNextFetch = now.addingTimeInterval(policy.idleInterval)
                Log.poll.notice("[\(self.accountID, privacy: .public)] supplement failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Header values win for 5h/weekly (always fresh). Borrow only per-model and extra usage.
    /// Headers without 5h mean the account has no 5-hour limit (Ultra since 2026-10-31): a
    /// cached payload from before the change must not bring the old window back.
    private static func combine(_ probeSnap: UsageSnapshot, with supplement: UsageSnapshot?) -> UsageSnapshot {
        guard let supplement else { return probeSnap }
        return UsageSnapshot(
            fiveHour: probeSnap.sevenDay != nil ? probeSnap.fiveHour : supplement.fiveHour,
            sevenDay: probeSnap.sevenDay ?? supplement.sevenDay,
            sevenDayOpus: supplement.sevenDayOpus,
            sevenDaySonnet: supplement.sevenDaySonnet,
            limits: supplement.limits,
            extraUsage: supplement.extraUsage)
    }

    private func apply(snapshot snap: UsageSnapshot, at now: Date) async {
        // A stopped monitor's history may already be archived: do not recreate its files.
        guard !Task.isCancelled else { return }
        snapshot = snap
        lastUpdated = now
        health = .ok
        pollState.recordSuccess()
        rememberModelNames(snap.perModelWindows.map(\.name))
        await recomputeForecasts(adding: Sample(ts: now, snapshot: snap), snapshot: snap, now: now)

        // Switch to active (60s) cadence the moment usage moves, not only once the forecast
        // has already confirmed a burn — otherwise idle 5-min polling never gathers the
        // closely-spaced samples the forecast needs (a deadlock).
        // Without a 5-hour window (Ultra), the weekly cap is the one that moves.
        let current = snap.fiveHour?.utilization ?? snap.sevenDay?.utilization
        let rising: Bool
        if let current, let previous = lastActivityUtil {
            rising = current > previous + 0.001
        } else {
            rising = false
        }
        lastActivityUtil = current
        pollState.activelyBurning = rising || {
            if case .onPace = fiveHourVerdict { return true }
            if case .willHitWall = fiveHourVerdict { return true }
            return false
        }()

        notifier.evaluate(
            snapshot: snap, fiveHourVerdict: fiveHourVerdict, now: now, accountLabel: notificationLabel)
    }

    private func apply(error: UsageError) {
        guard !Task.isCancelled else { return }
        switch error {
        case .rateLimited(let retryAfter):
            Log.poll.error("[\(self.accountID, privacy: .public)] RATE LIMITED (429) · server Retry-After=\(retryAfter.map { String(Int($0)) } ?? "none", privacy: .public)s · consecutive=\(self.pollState.consecutiveRateLimits + 1, privacy: .public)")
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
        case .claudeCodeNotFound:
            health = .claudeCodeNotFound
            pollState.recordFailure()
        case .claudeCodeFailed:
            health = .claudeCodeFailed
            pollState.recordFailure()
        case .proxyKeyRejected:
            health = .proxyKeyRejected
            pollState.recordFailure()
        case .proxyBanned(let retryAfter):
            health = .proxyBanned(retryAfter: retryAfter)
            pollState.recordRateLimit(retryAfter: retryAfter)
        case .proxyLoginGone:
            health = .proxyLoginGone
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

    /// The last four days of samples, kept in memory after the first load. Reading and
    /// decoding the whole file on every poll took the main thread for a noticeable moment.
    private var recentSamples: [Sample]?

    /// Appends the sample and runs every forecast off the main thread, then publishes.
    private func recomputeForecasts(adding sample: Sample, snapshot snap: UsageSnapshot, now: Date) async {
        let store = sampleStore
        let cached = recentSamples
        let lookback = ForecastEngine.burnLookback(pollInterval: policy.activeInterval)
        let result = await Task.detached(priority: .utility) {
            store.append(sample)
            let horizon = now.addingTimeInterval(-4 * 24 * 3600)
            var samples = cached.map { $0 + [sample] } ?? store.load(since: horizon)
            samples.removeAll { $0.ts < horizon }
            return (samples, ForecastSet(samples: samples, snapshot: snap, now: now, lookback: lookback))
        }.value
        recentSamples = result.0
        fiveHourVerdict = result.1.fiveHour
        weeklyForecasts = result.1.weekly
        projections = result.1.projections
    }

    // MARK: - Attribution (computed lazily on popover open, throttled)

    #if DEBUG
    func setDemoReport(_ report: UsageReport, range: AttributionRange, page: Int = 0) {
        transcripts.setDemoReport(report, range: range, span: interval(range: range, page: page))
    }
    #endif

    func interval(range: AttributionRange, page: Int, now: Date = Date()) -> DateInterval {
        range.interval(
            page: page, now: now, fiveHourReset: snapshot?.fiveHour?.resetsAt,
            weeklyReset: snapshot?.sevenDay?.resetsAt)
    }

    func hasPage(range: AttributionRange, page: Int, now: Date = Date()) -> Bool {
        range.hasPage(
            page, now: now, fiveHourReset: snapshot?.fiveHour?.resetsAt,
            weeklyReset: snapshot?.sevenDay?.resetsAt)
    }

    /// The finished report for a page, or nil while it loads.
    func report(range: AttributionRange, page: Int, now: Date = Date()) -> UsageReport? {
        transcripts.report(range: range, span: interval(range: range, page: page, now: now))
    }

    func refreshAttributionIfStale(range: AttributionRange, page: Int = 0) {
        transcripts.refreshIfStale(range: range, span: interval(range: range, page: page))
    }

    // MARK: - Sleep / wake plumbing

    /// Invalidates timers from earlier sleeps. Without this, a sleep cut short by a manual
    /// refresh or unlock leaves its timer pending, and that stale timer later wakes the NEXT
    /// sleep early — polls creep faster than policy, which can hammer through a 429 penalty.
    private var sleepGeneration = 0

    private func sleepInterruptibly(_ interval: TimeInterval) async {
        // A stop() that lands mid-poll must not leave the old loop parked on a new sleep.
        guard !Task.isCancelled else { return }
        if refreshRequested {
            refreshRequested = false
            isRefreshing = true
            return
        }
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
        // A stop() that lands mid-poll must not leave the old loop parked on a new sleep.
        guard !Task.isCancelled else { return }
        sleepGeneration += 1  // orphan any timer from the sleep this pause replaced
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            wakeSignal = cont
        }
    }

    private func wake() {
        wakeSignal?.resume()
        wakeSignal = nil
    }
}

/// Every forecast for one reading. Pure, so it runs off the main thread.
private struct ForecastSet: Sendable {
    let fiveHour: FiveHourVerdict
    let weekly: [AccountMonitor.WeeklyForecast]
    let projections: [String: Projection]

    init(samples: [Sample], snapshot: UsageSnapshot, now: Date, lookback: TimeInterval) {
        fiveHour = ForecastEngine.fiveHour(samples: samples, now: now, lookback: lookback)

        // Forecast every weekly window, overall and each per-model, so the one the user
        // actually burns (e.g. Fable) gets a prediction, not just the aggregate cap.
        var forecasts: [AccountMonitor.WeeklyForecast] = [
            .init(
                name: "Weekly cap",
                utilization: snapshot.sevenDay?.utilization,
                verdict: ForecastEngine.weekly(samples: samples, now: now))
        ]
        for model in snapshot.perModelWindows {
            forecasts.append(.init(
                name: "\(model.name) weekly",
                utilization: model.window.utilization,
                verdict: ForecastEngine.weeklyForModel(model.name, samples: samples, now: now)))
        }
        // Binding (highest utilization) first.
        weekly = forecasts.sorted { ($0.utilization ?? 0) > ($1.utilization ?? 0) }

        var next: [String: Projection] = [
            SectionLayout.fiveHour: ForecastEngine.fiveHourProjection(samples: samples, now: now, lookback: lookback),
            SectionLayout.weekly: ForecastEngine.weeklyProjection(samples: samples, now: now),
        ]
        for model in snapshot.perModelWindows {
            next[SectionLayout.modelID(model.name)] =
                ForecastEngine.weeklyProjectionForModel(model.name, samples: samples, now: now)
        }
        projections = next
    }
}
