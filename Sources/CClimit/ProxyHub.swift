import CClimitCore
import Foundation

/// The one connection to the CLI proxy (Settings > Accounts > CLI Proxy). Every account
/// the proxy holds reads from it, so one `auth-files` call serves all of them.
///
/// The proxy bans an IP after a few wrong keys and extends the ban on each try during it.
/// So a rejected key stops all calls until the user changes the settings, and a ban holds
/// every call until it ends.
@MainActor
final class ProxyHub: ObservableObject {
    static let shared = ProxyHub()

    static let urlKey = "proxyURL"

    @Published private(set) var config: ProxyConfig?
    /// The last answer, for Settings: logins found, or the error that stopped the calls.
    @Published private(set) var lastLogins: [ProxyLogin] = []
    @Published private(set) var lastError: UsageError?
    @Published private(set) var lastFetched: Date?

    private var bannedUntil: Date?
    private var inFlight: Task<[ProxyLogin], Error>?
    /// Monitors poll one after another. A listing this young serves them all.
    private let maxAge: TimeInterval = 20

    private let defaults = UserDefaults.standard

    /// Reads the saved key once per launch. `security` is a child process that can stall on
    /// a locked Keychain for up to 10 s, so it runs off the main thread.
    private var loading: Task<Void, Never>?

    private init() {
        guard
            let raw = defaults.string(forKey: Self.urlKey),
            let url = ProxyConfig.normalizedURL(raw)
        else { return }
        let account = url.absoluteString
        loading = Task { [weak self] in
            let key = await Task.detached(priority: .userInitiated) { ProxyKeyStore.load(account: account) }.value
            // A connect or disconnect while this ran wins.
            guard let self, self.config == nil, self.defaults.string(forKey: Self.urlKey) == raw else { return }
            self.config = key.map { ProxyConfig(baseURL: url, managementKey: $0) }
        }
    }

    /// Waits for the saved key. Discovery calls it before it asks `isConfigured`.
    func ready() async {
        await loading?.value
    }

    var isConfigured: Bool { config != nil }

    /// Tests the address and key with one call, and saves them only when the proxy accepts
    /// them. Returns the Claude logins found.
    func connect(urlText: String, key: String) async throws -> [ProxyLogin] {
        guard let url = ProxyConfig.normalizedURL(urlText) else {
            throw UsageError.schemaChanged("That is not a proxy address. Example: http://host:8317")
        }
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = ProxyConfig(baseURL: url, managementKey: trimmedKey)
        let logins = try await CLIProxyClient(config: candidate).logins()
        let account = url.absoluteString
        let saved = await Task.detached { ProxyKeyStore.save(trimmedKey, account: account) }.value
        guard saved else {
            throw UsageError.schemaChanged("The proxy accepted the key, but the Keychain did not store it.")
        }
        if let old = config, old.baseURL != url {
            let oldAccount = old.baseURL.absoluteString
            await Task.detached { ProxyKeyStore.delete(account: oldAccount) }.value
        }
        defaults.set(url.absoluteString, forKey: Self.urlKey)
        reset(to: candidate)
        record(logins)
        return logins
    }

    func disconnect() {
        if let old = config {
            let account = old.baseURL.absoluteString
            Task.detached { ProxyKeyStore.delete(account: account) }
        }
        defaults.removeObject(forKey: Self.urlKey)
        reset(to: nil)
    }

    private func reset(to config: ProxyConfig?) {
        self.config = config
        inFlight?.cancel()
        inFlight = nil
        bannedUntil = nil
        lastError = nil
        lastLogins = []
        lastFetched = nil
    }

    /// The proxy's Claude logins, from a listing at most `maxAge` old.
    func logins(now: Date = Date()) async throws -> [ProxyLogin] {
        guard let config else { return [] }
        if case .proxyKeyRejected? = lastError { throw UsageError.proxyKeyRejected }
        if let bannedUntil, now < bannedUntil {
            throw UsageError.proxyBanned(retryAfter: bannedUntil.timeIntervalSince(now))
        }
        if let lastFetched, now.timeIntervalSince(lastFetched) < maxAge, lastError == nil {
            return lastLogins
        }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await CLIProxyClient(config: config).logins() }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        do {
            let logins = try await task.value
            // Settings changed while this call ran: its answer belongs to the old proxy.
            guard self.config == config else { return [] }
            record(logins)
            return logins
        } catch let error as UsageError {
            guard self.config == config else { throw error }
            lastError = error
            if case .proxyBanned(let retryAfter) = error {
                bannedUntil = now.addingTimeInterval((retryAfter ?? 300) + 5)
            }
            throw error
        }
    }

    /// The full usage payload for one login, through the proxy's `api-call`.
    func usage(authIndex: String, userAgentVersion: String, now: Date = Date()) async throws -> UsageSnapshot {
        guard let config else { throw UsageError.proxyLoginGone }
        if case .proxyKeyRejected? = lastError { throw UsageError.proxyKeyRejected }
        // Every call during a ban extends it, whichever endpoint it hits.
        if let bannedUntil, now < bannedUntil {
            throw UsageError.proxyBanned(retryAfter: bannedUntil.timeIntervalSince(now))
        }
        do {
            return try await CLIProxyClient(config: config)
                .usage(authIndex: authIndex, userAgentVersion: userAgentVersion)
        } catch let error as UsageError {
            guard self.config == config else { throw error }
            switch error {
            case .proxyKeyRejected: lastError = error
            case .proxyBanned(let retryAfter):
                lastError = error
                bannedUntil = now.addingTimeInterval((retryAfter ?? 300) + 5)
            default: break
            }
            throw error
        }
    }

    private func record(_ logins: [ProxyLogin]) {
        lastLogins = logins
        lastError = nil
        lastFetched = Date()
    }
}
