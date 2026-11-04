import AppKit
import CClimitCore
import Combine
import Foundation

/// Owns one `AccountMonitor` per Claude Code login on this Mac, and the popover's account
/// selection. With one visible account it is a thin pass-through to that monitor. With
/// several, "All" pools them and the menu bar follows whatever the popover shows.
@MainActor
final class AppState: ObservableObject {
    static let allID = "all"

    /// Every discovered login, hidden ones included (Settings lists them all).
    @Published private(set) var monitors: [AccountMonitor] = []
    /// "all" or an account id. The menu bar icon follows it.
    @Published var selection: String {
        didSet { defaults.set(selection, forKey: "accountSelection") }
    }
    /// User overrides: display names and show/hide, keyed by account id.
    @Published private var customNames: [String: String]
    @Published private var visibilityOverrides: [String: Bool]
    /// Accounts another login pushed out of their config dir. Settings lists them.
    @Published private(set) var replacedLogins: [ReplacedLogin]
    /// The login the Add Account sheet waits for.
    @Published private(set) var pendingLogin: PendingLogin?
    /// A CLIProxyAPI server this Mac's Claude Code sends traffic to, found in its settings.
    /// The popover offers to connect it while cclimit is not connected to a proxy.
    @Published private(set) var detectedProxy: URL?
    /// Config dirs whose Claude Code goes through a proxy and that no login here owns. The
    /// proxy picks the login for each request, so their transcripts belong to no single
    /// account: they form one pool, shown once.
    @Published private(set) var proxyRoots: [URL] = []
    let proxyTranscripts = TranscriptReports(index: TranscriptIndex(roots: [], storeURL: nil))

    /// Last seen account behind each Keychain item, to notice a `/login` that replaced it.
    private var knownIdentities: [String: AccountIdentity]
    /// Config dirs cclimit created. Discovery scans them whatever their name.
    private var accountFolders: [String]
    /// The user's account order, by id. Accounts not in it follow in discovery order.
    private var accountOrder: [String]
    private var pendingTask: Task<Void, Never>?
    /// Bumped by each Add Account start and cancel, so a cancelled start stays cancelled.
    private var addGeneration = 0

    private let defaults = UserDefaults.standard
    private var forwarding: [String: AnyCancellable] = [:]
    private var proxyTranscriptsChanged: AnyCancellable?
    private var started = false
    private var lastDiscovery: Date?
    /// Discoveries overlap (timer, popover open, Look Again, Add Account). Only the newest
    /// applies, so a slow one that started before a removal cannot bring the account back.
    private var discoveryGeneration = 0
    private var discoveryTimer: Timer?
    private var statsTimer: Timer?
    private var screenLocked = false
    /// Debug renders: fixed demo accounts, no discovery or polling.
    private var isDemo = false

    init() {
        selection = defaults.string(forKey: "accountSelection") ?? Self.allID
        customNames = defaults.dictionary(forKey: "accountNames") as? [String: String] ?? [:]
        visibilityOverrides = defaults.dictionary(forKey: "accountVisibility") as? [String: Bool] ?? [:]
        replacedLogins = Self.decode([ReplacedLogin].self, defaults.data(forKey: "replacedLogins")) ?? []
        knownIdentities = Self.decode([String: AccountIdentity].self, defaults.data(forKey: "accountIdentities")) ?? [:]
        accountFolders = defaults.stringArray(forKey: "accountFolders") ?? []
        accountOrder = defaults.stringArray(forKey: "accountOrder") ?? []
        proxyTranscriptsChanged = proxyTranscripts.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func persist<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    // MARK: - Accounts

    var visibleMonitors: [AccountMonitor] { monitors.filter { isVisible($0.account) } }

    var isMultiAccount: Bool { visibleMonitors.count > 1 }

    /// The account the popover (and icon) shows, or nil for the pooled "All" view.
    var selectedMonitor: AccountMonitor? {
        let visible = visibleMonitors
        guard visible.count > 1 else { return visible.first }
        return visible.first { $0.id == selection }
    }

    var showsPool: Bool { isMultiAccount && selectedMonitor == nil }

    func isVisible(_ account: ClaudeAccount) -> Bool {
        if let override = visibilityOverrides[account.id] { return override }
        // A dormant login hides by default, but only while another login is live: an app
        // with every account hidden shows nothing and explains nothing.
        return !account.isDormant()
            || !monitors.contains { $0.account.id != account.id && !$0.account.isDormant() }
    }

    func setVisible(_ visible: Bool, for account: ClaudeAccount) {
        visibilityOverrides[account.id] = visible
        defaults.set(visibilityOverrides, forKey: "accountVisibility")
        syncRunning()
        syncLabels()
    }

    func name(for account: ClaudeAccount) -> String {
        if let custom = customNames[account.id]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            return custom
        }
        return account.suggestedName
    }

    /// The name for tight places (the segmented switcher). An email reads as its domain,
    /// "mailnail" for matyas@mailnail.com, or as its local part at a common mail provider.
    func shortName(for account: ClaudeAccount) -> String {
        let name = name(for: account)
        let parts = name.split(separator: "@")
        guard parts.count == 2 else { return name }
        let domain = parts[1].split(separator: ".").first.map(String.init) ?? ""
        let common: Set<String> = ["gmail", "googlemail", "icloud", "me", "outlook", "hotmail", "live",
                                   "yahoo", "proton", "protonmail", "email", "seznam", "centrum", "gmx", "fastmail"]
        return common.contains(domain.lowercased()) || domain.isEmpty ? String(parts[0]) : domain
    }

    /// cclimit made this account's folder with Add Account, so it may also remove it.
    func createdFolder(for account: ClaudeAccount) -> Bool {
        guard let dir = account.configDir?.standardizedFileURL.path else { return false }
        return accountFolders.contains { URL(fileURLWithPath: $0).standardizedFileURL.path == dir }
    }

    /// Signs the account out through Claude Code's own `auth logout`, which deletes its
    /// Keychain item, then forgets it. A folder cclimit created goes to the Trash. The default
    /// login is never removed here: it is the one plain `claude` uses.
    func remove(_ account: ClaudeAccount) async -> String? {
        if account.isDefault { return "cclimit can only hide the default login." }
        if account.isProxyOnly {
            return "This login lives on the CLI proxy. Remove it there, or hide it here."
        }
        guard let dir = account.configDir else {
            return "cclimit does not know this login's folder. Run `claude auth logout` with its CLAUDE_CONFIG_DIR, or hide it here."
        }
        enum Outcome { case done, notFound, failed, timedOut }
        let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
            guard let claude = ClaudeCodeCLI.locate() else { return .notFound }
            guard let result = try? ChildProcess.run(
                claude, arguments: ["auth", "logout"],
                environment: ClaudeCodeUsageSource.environment(configDir: dir), timeout: 30)
            else { return .failed }
            if result.timedOut { return .timedOut }
            return result.status == 0 ? .done : .failed
        }.value
        let manual = "`CLAUDE_CONFIG_DIR=\(dir.path) claude auth logout`"
        switch outcome {
        case .done: break
        case .notFound: return "cclimit cannot find the claude command to sign out."
        case .timedOut: return "Claude Code did not finish signing out in 30 seconds. Try \(manual)."
        case .failed: return "Claude Code could not sign this account out. Try \(manual)."
        }

        if createdFolder(for: account) {
            let trashed = await Task.detached(priority: .userInitiated) {
                (try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)) != nil
            }.value
            if !trashed { Log.poll.error("accounts: could not move \(dir.path, privacy: .public) to the Trash") }
            accountFolders.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.path == dir.standardizedFileURL.path }
            defaults.set(accountFolders, forKey: "accountFolders")
        }
        customNames[account.id] = nil
        defaults.set(customNames, forKey: "accountNames")
        visibilityOverrides[account.id] = nil
        defaults.set(visibilityOverrides, forKey: "accountVisibility")
        knownIdentities[account.id] = nil
        persist(knownIdentities, "accountIdentities")
        // Drop it here, not through discovery: with no other login left, discovery finds
        // nothing and keeps the known monitors, this one included.
        monitors.first { $0.id == account.id }?.discardHistory()
        monitors.removeAll { $0.id == account.id }
        forwarding[account.id] = nil
        if selection == account.id { selection = Self.allID }
        await discoverAndApply()
        return nil
    }

    /// Settings > Accounts drag: the switcher and the All list follow this order.
    func moveAccounts(fromOffsets source: IndexSet, toOffset destination: Int) {
        var next = monitors
        next.move(fromOffsets: source, toOffset: destination)
        accountOrder = next.map(\.id)
        defaults.set(accountOrder, forKey: "accountOrder")
        monitors = next
    }

    /// Discovery order, then the user's order on top: known ids by their stored rank,
    /// new ones after them.
    private func ordered(_ monitors: [AccountMonitor]) -> [AccountMonitor] {
        let rank = Dictionary(accountOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return monitors.enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    func rename(_ account: ClaudeAccount, to name: String) {
        // Trimmed when read, not here: trimming per keystroke eats the space between words.
        customNames[account.id] = name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : name
        defaults.set(customNames, forKey: "accountNames")
        syncLabels()
    }

    // MARK: - What the menu bar and Settings read

    var snapshot: UsageSnapshot? { showsPool ? pooledSnapshot : selectedMonitor?.snapshot }

    var health: Health {
        guard showsPool else { return selectedMonitor?.health ?? .starting }
        let healths = visibleMonitors.map(\.health)
        if healths.contains(.ok) { return .ok }
        if healths.allSatisfy({ $0 == .starting }) { return .starting }
        return healths.first { $0.isError } ?? .starting
    }

    var lastUpdated: Date? {
        showsPool ? visibleMonitors.compactMap(\.lastUpdated).max() : selectedMonitor?.lastUpdated
    }

    /// Capacity-weighted across the visible accounts that have a reading.
    var pooledSnapshot: UsageSnapshot? {
        AccountPool.combine(visibleMonitors.compactMap { monitor in
            monitor.snapshot.map { AccountPool.Member(snapshot: $0, weight: monitor.account.plan.weight) }
        })
    }

    /// Union of per-model window names ever seen, across accounts.
    var seenModelNames: [String] { defaults.stringArray(forKey: "seenModels") ?? [] }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        observeScreenLock()
        rediscover()
        // New logins appear without a relaunch. Discovery is a few `security` calls.
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rediscover() }
        }
        // Keep the project stats warm, so the popover opens on finished numbers and does not
        // grow once a scan lands. A warm index update takes about half a second, off main.
        statsTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.screenLocked else { return }
                self.refreshAttributionIfStale()
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            refreshAttributionIfStale()
        }
    }

    /// Settings > General > Usage source is "Claude Code": no Keychain secret is read.
    var readsThroughClaudeCode: Bool { defaults.string(forKey: "usageSource") == "claudeCode" }

    /// The usage source changed: find accounts the new way and take a reading at once.
    func usageSourceChanged() {
        objectWillChange.send()
        rediscover()
        visibleMonitors.forEach { $0.refreshNow() }
    }

    /// The CLI proxy was connected or disconnected: find its logins and read them at once.
    func proxyChanged() {
        objectWillChange.send()
        rediscover()
    }

    /// Re-reads the Keychain for logins, keeps the monitors that still exist (their polling
    /// state and backoff must survive), adds new ones, and stops the ones that are gone.
    func rediscover() {
        lastDiscovery = Date()
        Task { await discoverAndApply() }
    }

    @discardableResult
    private func discoverAndApply() async -> [ClaudeAccount] {
        guard !isDemo else { return monitors.map(\.account) }
        let extra = accountFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let readSecrets = !readsThroughClaudeCode
        discoveryGeneration += 1
        let generation = discoveryGeneration
        var found = await Task.detached(priority: .utility) {
            AccountDiscovery.discover(extraConfigDirs: extra, readSecrets: readSecrets)
        }.value
        guard generation == discoveryGeneration else { return found }
        let localFound = !found.isEmpty
        if localFound { trackIdentities(found) }
        let proxy = ProxyHub.shared
        await proxy.ready()
        guard generation == discoveryGeneration else { return found }
        if proxy.isConfigured {
            // A failed listing keeps the last known logins, so a proxy outage shows as an
            // error on each account, not as accounts that vanish and come back.
            let logins = (try? await proxy.logins()) ?? proxy.lastLogins
            guard generation == discoveryGeneration else { return found }
            found = ClaudeAccount.merging(local: found, proxy: logins)
        }
        if found.isEmpty, monitors.contains(where: { $0.account.email != nil }) {
            // Nothing readable right now, but logins were here: most likely a locked Keychain
            // or a stalled `security`. Keep the monitors and their backoff. Their polls report it.
            Log.poll.notice("accounts: discovery found nothing · keeping \(self.monitors.count, privacy: .public) known")
            return monitors.map(\.account)
        }
        if found.isEmpty {
            // No readable login. Keep a default monitor so its health explains why.
            found = [ClaudeAccount(
                id: ClaudeAccount.defaultID, service: AccountDiscovery.baseService,
                configDir: nil, email: nil, organization: nil, accountUUID: nil,
                plan: .unknown, tokenExpiresAt: nil, suggestedName: "Main")]
        } else if !localFound, let known = monitors.first(where: { !$0.account.isProxyOnly && $0.account.email != nil }) {
            // Only the proxy answered, while a local login was known: the Keychain is
            // locked for now. Keep the local monitors next to the proxy accounts.
            let keep = monitors.map(\.account).filter { !$0.isProxyOnly }
            Log.poll.notice("accounts: local discovery empty · keeping \(keep.count, privacy: .public) known (first \(known.id, privacy: .public))")
            found = ClaudeAccount.merging(local: keep.map { var a = $0; a.proxyAuthIndex = nil; return a },
                                          proxy: proxy.lastLogins)
        }
        apply(discovered: found)
        await refreshProxyRoutes(extra: extra)
        return found
    }

    // MARK: - Proxy traffic

    /// Finds the config dirs routed through a proxy, pools the ones no login owns, and
    /// checks whether a server is CLIProxyAPI. The check is one keyless GET, so it cannot
    /// trip the proxy's ban on wrong keys.
    private func refreshProxyRoutes(extra: [URL]) async {
        let routes = await Task.detached(priority: .utility) {
            ProxyDetection.routes(extraConfigDirs: extra)
        }.value
        let owned = Set(monitors.compactMap { $0.account.configDir?.standardizedFileURL.path })
        let roots = routes.filter { !owned.contains($0.configDir.path) }.map(\.projectsDir)
        if roots != proxyRoots {
            proxyRoots = roots
            Log.poll.notice("proxy: \(roots.count, privacy: .public) routed config dir(s) pooled")
            proxyTranscripts.replace(index: TranscriptIndex(
                roots: roots,
                storeURL: roots.isEmpty ? nil : TranscriptReports.dataDir.appendingPathComponent("transcripts-proxy.plist")))
        }

        var found: URL?
        var seen = Set<URL>()
        for route in routes where seen.insert(route.baseURL).inserted {
            if await ProxyDetection.isCLIProxy(baseURL: route.baseURL) {
                found = route.baseURL
                break
            }
        }
        if found != detectedProxy {
            Log.poll.notice("proxy: CLIProxyAPI \(found?.absoluteString ?? "not found", privacy: .public)")
            detectedProxy = found
        }
    }

    /// The pool joins the view that can hold it: "All", the only account, or an account the
    /// proxy serves. A login that never touches the proxy keeps its own numbers.
    func showsProxyTranscripts(for monitors: [AccountMonitor]) -> Bool {
        guard !proxyRoots.isEmpty else { return false }
        guard isMultiAccount, monitors.count == 1, let only = monitors.first else { return true }
        return only.account.isProxyOnly || only.account.proxyAuthIndex != nil
    }

    private static let proxySuggestionKey = "proxySuggestionDismissed"

    /// The proxy to offer in the popover: found, not connected, and not dismissed.
    var proxySuggestion: URL? {
        guard let url = detectedProxy, !ProxyHub.shared.isConfigured,
              defaults.string(forKey: Self.proxySuggestionKey) != url.absoluteString else { return nil }
        return url
    }

    func dismissProxySuggestion() {
        guard let url = detectedProxy else { return }
        defaults.set(url.absoluteString, forKey: Self.proxySuggestionKey)
        objectWillChange.send()
    }

    /// Notices a `/login` that replaced the account behind a Keychain item, and forgets a
    /// replaced account once it shows up again in a folder of its own.
    private func trackIdentities(_ found: [ClaudeAccount]) {
        let result = IdentityTracker.reconcile(
            known: knownIdentities, replaced: replacedLogins, discovered: found)
        if result.known != knownIdentities {
            knownIdentities = result.known
            persist(knownIdentities, "accountIdentities")
        }
        if result.replaced != replacedLogins {
            for entry in result.replaced where !replacedLogins.contains(entry) {
                Log.poll.notice("accounts: login \(entry.accountID, privacy: .public) was replaced")
            }
            replacedLogins = result.replaced
            persist(replacedLogins, "replacedLogins")
        }
    }

    func dismissReplaced(_ entry: ReplacedLogin) {
        replacedLogins.removeAll { $0.id == entry.id }
        persist(replacedLogins, "replacedLogins")
    }

    // MARK: - Add Account

    /// Makes the folder, remembers it for discovery, adds the optional alias, opens the
    /// login in Terminal, and then polls until the login shows up (3 s, up to 10 min).
    func beginAddAccount(name: String, slug: String, folder: URL, aliasShell: AccountSetup.Shell?) async {
        pendingTask?.cancel()
        addGeneration += 1
        let generation = addGeneration
        var pending = PendingLogin(name: name, folder: folder, phase: .waiting)
        do {
            try AddAccountLauncher.createFolder(folder)
        } catch {
            pending.phase = .failed("cclimit could not make the folder \(folder.path).")
            pendingLogin = pending
            return
        }
        if !accountFolders.contains(folder.path) {
            accountFolders.append(folder.path)
            defaults.set(accountFolders, forKey: "accountFolders")
        }
        if let shell = aliasShell {
            let home = FileManager.default.homeDirectoryForCurrentUser
            do {
                if try AccountSetup.installAlias(slug: slug, folder: folder, shell: shell, home: home) == .added {
                    pending.aliasNote = "Open a new terminal window to use \(AccountSetup.commandName(slug: slug))."
                }
            } catch {
                pending.aliasNote = "cclimit could not write \(shell.rcDisplayPath). Add the alias yourself."
            }
        }
        do {
            try await AddAccountLauncher.openLoginInTerminal(folder: folder, slug: slug)
            // Cancel while Terminal opened: no waiting login behind a closed sheet.
            guard generation == addGeneration else { return }
        } catch {
            guard generation == addGeneration else { return }
            pending.phase = .failed(
                "Terminal did not open. Run claude auth login with CLAUDE_CONFIG_DIR set to \(folder.path).")
            pendingLogin = pending
            return
        }
        pendingLogin = pending
        pendingTask = Task { [weak self] in await self?.waitForLogin(folder: folder, name: name) }
    }

    func cancelPendingLogin() {
        addGeneration += 1
        pendingTask?.cancel()
        pendingTask = nil
        pendingLogin = nil
    }

    /// Clears a finished result. A login still being waited for stays.
    func clearPendingLogin() {
        guard pendingLogin?.phase != .waiting else { return }
        pendingLogin = nil
    }

    /// Polls `dump-keychain` (names only, no secret) for the folder's item. Once it is
    /// there, runs a full discovery to name the account and read its email.
    private func waitForLogin(folder: URL, name: String) async {
        let services = AccountSetup.expectedServices(forConfigDir: folder)
        let ids = Set(services.map { String($0.dropFirst(AccountDiscovery.baseService.count + 1)) })
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(3))
            if Task.isCancelled { return }
            let present = await Task.detached(priority: .utility) {
                !services.isDisjoint(with: AccountDiscovery.services(inKeychainDump: AccountDiscovery.dumpKeychain()))
            }.value
            guard present, !Task.isCancelled else { continue }
            lastDiscovery = Date()
            let found = await discoverAndApply()
            if Task.isCancelled { return }
            if let account = found.first(where: { ids.contains($0.id) }) {
                rename(account, to: name)
                setPhase(.added(label: account.email ?? name))
                return
            }
            // The item exists but discovery dropped it: the same account is already tracked.
            let home = FileManager.default.homeDirectoryForCurrentUser
            if let uuid = AccountDiscovery.profile(configDir: folder, home: home)?.accountUUID,
               let existing = monitors.first(where: { $0.account.accountUUID == uuid }) {
                setPhase(.alreadyTracked(name: self.name(for: existing.account)))
                return
            }
            // Claude Code writes `.claude.json` just after the item. Look again next tick.
        }
        if !Task.isCancelled { setPhase(.timedOut) }
    }

    private func setPhase(_ phase: PendingLogin.Phase) {
        pendingLogin?.phase = phase
        pendingTask = nil
    }

    private func apply(discovered: [ClaudeAccount]) {
        var next: [AccountMonitor] = []
        for account in discovered {
            if let existing = monitors.first(where: { $0.id == account.id }),
               !Self.isDifferentLogin(existing.account, account) {
                existing.update(account: account)
                next.append(existing)
            } else {
                if let replaced = monitors.first(where: { $0.id == account.id }) {
                    // Another account logged in to this folder. Its token, history, forecasts,
                    // and name belong to the old account: start this one clean.
                    Log.poll.notice("accounts: \(account.id, privacy: .public) is a new login · starting fresh")
                    replaced.stop()
                    replaced.discardHistory()
                    customNames[account.id] = nil
                    defaults.set(customNames, forKey: "accountNames")
                }
                let monitor = AccountMonitor(account: account)
                forwarding[account.id] = monitor.objectWillChange.sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                next.append(monitor)
            }
        }
        for gone in monitors where !next.contains(where: { $0.id == gone.id }) {
            gone.stop()
            forwarding[gone.id] = nil
        }
        next = ordered(next)
        let names = next.map(\.id)
        if names != monitors.map(\.id) {
            Log.poll.notice("accounts: [\(names.joined(separator: ","), privacy: .public)]")
        }
        monitors = next
        syncRunning()
        syncLabels()
    }

    /// Same Keychain item, other account: both account UUIDs are known and differ.
    private static func isDifferentLogin(_ old: ClaudeAccount, _ new: ClaudeAccount) -> Bool {
        guard let a = old.accountUUID, let b = new.accountUUID else { return false }
        return a != b
    }

    /// Visible accounts poll, hidden ones do not: a hidden login costs nothing.
    private func syncRunning() {
        for monitor in monitors {
            if isVisible(monitor.account) {
                if !monitor.isRunning {
                    monitor.setScreenLocked(screenLocked)
                    monitor.start()
                }
            } else if monitor.isRunning {
                monitor.stop()
            }
        }
    }

    private func syncLabels() {
        let multi = isMultiAccount
        for monitor in monitors {
            monitor.notificationLabel = multi ? name(for: monitor.account) : nil
        }
    }

    // MARK: - Refresh

    /// A refresh the user asked for is still running on a shown account.
    var isRefreshing: Bool {
        (showsPool ? visibleMonitors : selectedMonitor.map { [$0] } ?? []).contains(where: \.isRefreshing)
    }

    func refreshNow() {
        if let selected = selectedMonitor {
            selected.refreshNow()
        } else {
            visibleMonitors.forEach { $0.refreshNow() }
        }
    }

    func refreshOnOpen() {
        guard !isDemo else { return }
        visibleMonitors.forEach { $0.refreshOnOpen() }
        if let last = lastDiscovery, Date().timeIntervalSince(last) < 120 { return }
        rediscover()
    }

    func refreshAttributionIfStale() {
        guard !isDemo else { return }
        let targets = showsPool ? visibleMonitors : selectedMonitor.map { [$0] } ?? []
        let range = Self.attributionRange(for: targets)
        targets.forEach { $0.refreshAttributionIfStale(range: range) }
        if showsProxyTranscripts(for: targets) {
            proxyTranscripts.refreshIfStale(range: range, span: Self.attributionSpan(range: range, page: 0, for: targets))
        }
    }

    /// The range the popover shows for these accounts. One rule for the popover and the
    /// background refresh, so the refresh warms the page the popover opens on.
    static func attributionRange(for monitors: [AccountMonitor]) -> AttributionRange {
        AttributionRange.shown(
            stored: UserDefaults.standard.string(forKey: "attributionRange"),
            hasFiveHour: monitors.contains { $0.snapshot.map { !$0.lacksFiveHour } ?? true })
    }

    /// A page's span: the first account's, so its 5-hour window sets the start.
    static func attributionSpan(range: AttributionRange, page: Int, for monitors: [AccountMonitor]) -> DateInterval {
        monitors.first?.interval(range: range, page: page)
            ?? range.interval(page: page, now: Date(), fiveHourReset: nil, weeklyReset: nil)
    }

    private func observeScreenLock() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setScreenLocked(true) }
        }
        center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setScreenLocked(false) }
        }
    }

    private func setScreenLocked(_ locked: Bool) {
        screenLocked = locked
        monitors.forEach { $0.setScreenLocked(locked) }
    }
}

#if DEBUG
extension AppState {
    /// Debug: fixed demo accounts, no polling. Lets the multi-account UI be rendered and
    /// checked on a Mac with only one login (`CCLIMIT_RENDER_POPOVER=/dir`).
    func installDemoAccounts() {
        isDemo = true
        let now = Date()
        func account(_ id: String, _ name: String, _ email: String, _ plan: PlanTier) -> ClaudeAccount {
            ClaudeAccount(
                id: id, service: AccountDiscovery.baseService + "-" + id, configDir: nil, email: email,
                organization: nil, accountUUID: id, plan: plan, tokenExpiresAt: nil, suggestedName: name)
        }
        /// `five: nil` is an account without a 5-hour limit (Ultra since 2026-10-31).
        func snap(_ five: Double?, _ week: Double, fable: Double?) -> UsageSnapshot {
            UsageSnapshot(
                fiveHour: five.map { UsageWindow(utilization: $0, resetsAt: now.addingTimeInterval(5_400)) },
                sevenDay: UsageWindow(utilization: week, resetsAt: now.addingTimeInterval(3 * 86_400)),
                limits: fable.map {
                    [Limit(kind: "weekly_scoped", group: "weekly", percent: $0,
                           resetsAt: now.addingTimeInterval(3 * 86_400), isActive: true, severity: nil,
                           scope: .init(model: .init(displayName: "Fable")))]
                })
        }
        let demo: [(ClaudeAccount, UsageSnapshot?, Health)] = [
            (account("aaaaaaaa", "Work", "matyas@acme.com", .max20x), snap(nil, 44, fable: 78), .ok),
            (account("bbbbbbbb", "Personal", "matyas@mailnail.com", .max5x), snap(12, 38, fable: nil), .ok),
            (account("cccccccc", "Client", "dev@client.io", .pro), snap(93, 71, fable: nil),
             .rateLimited(retryAfter: 600)),
        ]
        replacedLogins = [ReplacedLogin(
            accountID: ClaudeAccount.defaultID, accountUUID: "old", email: "matyas@mailnail.com",
            planLabel: "Max 5x", configDirPath: nil, replacedAt: now.addingTimeInterval(-86_400))]
        monitors = demo.map { account, snapshot, health in
            let monitor = AccountMonitor(account: account)
            monitor.snapshot = snapshot
            monitor.health = health
            monitor.lastUpdated = now.addingTimeInterval(-20)
            switch account.id {
            case "aaaaaaaa":
                monitor.projections = [
                    SectionLayout.weekly: Projection(atReset: 63, wall: nil),
                    SectionLayout.modelID("Fable"): Projection(
                        atReset: 100,
                        wall: .between(now.addingTimeInterval(30 * 3600), now.addingTimeInterval(40 * 3600))),
                ]
                let since = Calendar.current.startOfDay(for: now)
                let hours = Int(now.timeIntervalSince(since) / 3600) + 1
                let names = ["cclimit", "mailnail", "t3code", "dotfiles"]
                monitor.setDemoReport(UsageReport(
                    since: since, bucketSize: 3600,
                    projects: [
                        ProjectStats(name: "cclimit", tokens: 4_200_000, share: 0.52, input: 900_000,
                                     output: 410_000, cacheWrite: 2_890_000, sessions: 6,
                                     subagentTokens: 760_000,
                                     models: [.init(name: "Opus 5.5", tokens: 3_100_000),
                                              .init(name: "Haiku 4.5", tokens: 1_100_000)],
                                     lastActive: now.addingTimeInterval(-300)),
                        ProjectStats(name: "mailnail", tokens: 2_100_000, share: 0.26, sessions: 3,
                                     models: [.init(name: "Fable 5.1", tokens: 2_100_000)],
                                     lastActive: now.addingTimeInterval(-7200)),
                        ProjectStats(name: "t3code", tokens: 1_200_000, share: 0.15, sessions: 2),
                        ProjectStats(name: "dotfiles", tokens: 560_000, share: 0.07, sessions: 1),
                    ],
                    buckets: (0..<hours).map { h in
                        let wave = [0, 0, 0, 0, 0, 0, 0, 0, 2, 5, 7, 4, 1, 3, 8, 9, 6, 2, 1, 0, 0, 0, 0, 0]
                        let base = wave[h % 24] * 120_000
                        let split = Dictionary(uniqueKeysWithValues: names.enumerated().map { i, n in
                            (n, base / (i + 2))
                        })
                        return ActivityBucket(
                            start: since.addingTimeInterval(Double(h) * 3600),
                            tokens: split.values.reduce(0, +), byProject: split)
                    }), range: .today)
            case "bbbbbbbb":
                monitor.projections = [SectionLayout.fiveHour: Projection(atReset: 31, wall: nil)]
            default:
                break
            }
            return monitor
        }
    }

    func setDemoPendingLogin(_ pending: PendingLogin?) {
        pendingLogin = pending
    }
}
#endif
