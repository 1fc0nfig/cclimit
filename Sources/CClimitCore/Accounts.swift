import CryptoKit
import Foundation

/// The subscription plan behind a login, read from the credential JSON Claude Code stores.
/// The weight is the plan's capacity relative to Pro, so a pooled reading counts an Ultra
/// (formerly Max 20x) account as twenty Pro accounts instead of averaging the two percentages.
public enum PlanTier: Equatable, Sendable {
    case pro
    case max5x
    case max20x
    case team
    case enterprise
    case unknown

    public init(subscriptionType: String?, rateLimitTier: String?) {
        let tier = rateLimitTier?.lowercased() ?? ""
        let type = subscriptionType?.lowercased() ?? ""
        // Max 20x became Ultra on 2026-10-31. Tokens issued before then still say max_20x.
        if tier.contains("max_20x") || tier.contains("max20x") || tier.contains("ultra") || type == "ultra" {
            self = .max20x
        } else if tier.contains("max_5x") || tier.contains("max5x") || type == "max" {
            self = .max5x
        } else if type == "pro" || tier.contains("pro") {
            self = .pro
        } else if type == "team" || tier.contains("team") {
            self = .team
        } else if type == "enterprise" || tier.contains("enterprise") {
            self = .enterprise
        } else {
            self = .unknown
        }
    }

    public var label: String? {
        switch self {
        case .pro: return "Pro"
        case .max5x: return "Max 5x"
        case .max20x: return "Ultra"
        case .team: return "Team"
        case .enterprise: return "Enterprise"
        case .unknown: return nil
        }
    }

    public var weight: Double {
        switch self {
        case .max5x: return 5
        case .max20x: return 20
        case .pro, .team, .enterprise, .unknown: return 1
        }
    }
}

/// One Claude Code login found on this Mac. Claude Code keeps the default login in the
/// Keychain item "Claude Code-credentials"; a login made with `CLAUDE_CONFIG_DIR` set gets
/// "Claude Code-credentials-<first 8 hex of sha256(config dir)>". The id is that suffix.
public struct ClaudeAccount: Identifiable, Equatable, Sendable {
    public static let defaultID = "default"

    public let id: String
    public let service: String
    /// The config dir this login belongs to, when cclimit could match the hash. The default
    /// login always maps to ~/.claude.
    public let configDir: URL?
    public let email: String?
    public let organization: String?
    public let accountUUID: String?
    public let plan: PlanTier
    public let tokenExpiresAt: Date?
    /// Derived from the config dir name or the email. The user can override it in Settings.
    public var suggestedName: String
    /// The CLI proxy's `auth_index` for this login, when the proxy holds it. Such an account
    /// reads its usage through the proxy, which costs no request from this Mac.
    public var proxyAuthIndex: String?

    public var isDefault: Bool { id == Self.defaultID }

    /// Prefix of accounts the proxy holds and no Claude Code login on this Mac matches.
    public static let proxyIDPrefix = "proxy-"

    /// A login only the CLI proxy holds: no Keychain item, no config dir, no transcripts.
    public var isProxyOnly: Bool { id.hasPrefix(Self.proxyIDPrefix) }

    /// An account for a proxy login that matches no local login.
    public static func proxyOnly(_ login: ProxyLogin) -> ClaudeAccount {
        var account = ClaudeAccount(
            id: proxyIDPrefix + login.authIndex, service: "", configDir: nil, email: login.email,
            organization: nil, accountUUID: nil, plan: .unknown, tokenExpiresAt: nil,
            suggestedName: login.email.flatMap { $0.split(separator: "@").first.map(String.init) } ?? "Proxy")
        account.proxyAuthIndex = login.authIndex
        return account
    }

    /// Ties proxy logins to local ones by email: one Anthropic account has one quota,
    /// whichever way it is reached. Unmatched proxy logins become accounts of their own.
    public static func merging(local: [ClaudeAccount], proxy: [ProxyLogin]) -> [ClaudeAccount] {
        var out = local
        for login in proxy {
            let email = login.email?.lowercased()
            if let email, let i = out.firstIndex(where: { $0.email?.lowercased() == email && $0.proxyAuthIndex == nil }) {
                out[i].proxyAuthIndex = login.authIndex
            } else if email == nil || !out.contains(where: { $0.email?.lowercased() == email }) {
                out.append(proxyOnly(login))
            }
        }
        return AccountDiscovery.deduplicateNames(out)
    }

    public init(
        id: String, service: String, configDir: URL?, email: String?, organization: String?,
        accountUUID: String?, plan: PlanTier, tokenExpiresAt: Date?, suggestedName: String
    ) {
        self.id = id
        self.service = service
        self.configDir = configDir
        self.email = email
        self.organization = organization
        self.accountUUID = accountUUID
        self.plan = plan
        self.tokenExpiresAt = tokenExpiresAt
        self.suggestedName = suggestedName
    }

    /// Claude Code refreshes a token only while that login is in use, and cclimit never
    /// refreshes one itself. A token expired for a week belongs to a login nobody uses:
    /// it starts hidden instead of showing a permanent "signed out" row.
    public func isDormant(now: Date = Date()) -> Bool {
        guard let tokenExpiresAt else { return false }
        return now.timeIntervalSince(tokenExpiresAt) > 7 * 24 * 3600
    }

    /// Where this login keeps its transcripts, for per-account attribution.
    public var projectsDir: URL? { configDir?.appendingPathComponent("projects", isDirectory: true) }

    /// Suffix for per-account data files. Empty for the default login, so existing sample
    /// history and per-model caches stay where they are.
    public var storageSuffix: String { isDefault ? "" : "-\(id)" }
}

public enum AccountDiscovery {
    public static let baseService = "Claude Code-credentials"

    /// Service names of Claude Code login items in `security dump-keychain` output. Only
    /// the base name and the 8-hex config-dir variants count: Claude Code builds the name as
    /// `Claude Code<OAUTH_FILE_SUFFIX>-credentials<-hash>`, and staging suffixes are not ours.
    public static func services(inKeychainDump dump: String) -> [String] {
        var found: [String] = []
        for line in dump.split(separator: "\n") {
            guard let range = line.range(of: "\"svce\"<blob>=\"") else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            let name = String(rest[..<end])
            guard isLoginService(name), !found.contains(name) else { continue }
            found.append(name)
        }
        return found
    }

    static func isLoginService(_ name: String) -> Bool {
        if name == baseService { return true }
        guard name.hasPrefix(baseService + "-") else { return false }
        let suffix = name.dropFirst(baseService.count + 1)
        return suffix.count == 8 && suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The hash Claude Code appends for a `CLAUDE_CONFIG_DIR` (binary fn `vj`):
    /// `sha256(dir.normalize("NFC")).hex.substring(0, 8)`.
    public static func suffix(forConfigDir path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
    }

    /// Spellings of one dir that a shell could hand Claude Code as `CLAUDE_CONFIG_DIR`. The
    /// hash covers the raw string, so a trailing slash or a symlink gives a different item.
    static func spellings(of url: URL) -> [String] {
        let plain = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().path
        var out: [String] = []
        for path in [plain, resolved] {
            for variant in [path, path.hasSuffix("/") ? String(path.dropLast()) : path + "/"]
            where !out.contains(variant) {
                out.append(variant)
            }
        }
        return out
    }

    /// Dirs that may be a `CLAUDE_CONFIG_DIR`: anything named like "claude" in the home
    /// folder and in ~/.config (plus one level inside, for "~/.claude-accounts/work"), and
    /// every `CLAUDE_CONFIG_DIR=` value in the usual shell startup files. `extra` adds the
    /// folders cclimit created itself ("Add Account…"), whatever their name.
    public static func candidateConfigDirs(
        home: URL, extra: [URL] = [], fileManager fm: FileManager = .default
    ) -> [URL] {
        var dirs: [URL] = []
        func add(_ url: URL) {
            let std = url.standardizedFileURL
            if !dirs.contains(std) { dirs.append(std) }
        }
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        for parent in [home, home.appendingPathComponent(".config")] {
            for child in children(parent) where child.lastPathComponent.lowercased().contains("claude") {
                add(child)
                for grandchild in children(child) where grandchild.lastPathComponent.first != "." {
                    // Only dirs that look like a config home, to keep the scan cheap.
                    if fm.fileExists(atPath: grandchild.appendingPathComponent(".claude.json").path)
                        || fm.fileExists(atPath: grandchild.appendingPathComponent("settings.json").path) {
                        add(grandchild)
                    }
                }
            }
        }
        for path in configDirsInShellFiles(home: home) {
            add(URL(fileURLWithPath: path))
        }
        extra.forEach(add)
        return dirs
    }

    /// `CLAUDE_CONFIG_DIR=<value>` assignments in shell startup files, with `~` and `$HOME`
    /// expanded. Picks up the common `alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'`.
    public static func configDirsInShellFiles(home: URL) -> [String] {
        let files = [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile",
                     ".config/fish/config.fish"]
        var out: [String] = []
        for file in files {
            guard let text = try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8)
            else { continue }
            out.append(contentsOf: configDirAssignments(in: text, home: home.path))
        }
        return out
    }

    static func configDirAssignments(in text: String, home: String) -> [String] {
        var out: [String] = []
        var search = text[...]
        while let range = search.range(of: "CLAUDE_CONFIG_DIR") {
            search = search[range.upperBound...]
            // `CLAUDE_CONFIG_DIR=value` or fish's `set -x CLAUDE_CONFIG_DIR value`.
            var rest = search.drop { $0 == " " }
            if rest.first == "=" { rest = rest.dropFirst() }
            var value = ""
            var quote: Character?
            if let first = rest.first, first == "\"" || first == "'" {
                quote = first
                rest = rest.dropFirst()
            }
            for char in rest {
                if let quote, char == quote { break }
                if quote == nil && (char.isWhitespace || char == ";" || char == "'" || char == "\"") { break }
                value.append(char)
            }
            guard !value.isEmpty, !value.hasPrefix("$(") else { continue }
            if value.hasPrefix("~") {
                value = home + value.dropFirst()
            }
            value = value.replacingOccurrences(of: "${HOME}", with: home)
                .replacingOccurrences(of: "$HOME", with: home)
            guard value.hasPrefix("/"), !out.contains(value) else { continue }
            out.append(value)
        }
        return out
    }

    /// The `oauthAccount` block Claude Code writes to `.claude.json`: email, org, uuid.
    public struct Profile: Equatable, Sendable {
        public let email: String?
        public let organization: String?
        public let accountUUID: String?
        /// `organizationType` and `organizationRateLimitTier`: the plan, without a secret.
        public var organizationType: String? = nil
        public var rateLimitTier: String? = nil

        /// "claude_max" + "default_claude_max_20x" reads as Ultra (formerly Max 20x).
        public var plan: PlanTier {
            let type = organizationType?.lowercased().replacingOccurrences(of: "claude_", with: "")
            return PlanTier(subscriptionType: type, rateLimitTier: rateLimitTier)
        }
    }

    /// The default login keeps its config in ~/.claude.json, a `CLAUDE_CONFIG_DIR` login in
    /// `<dir>/.claude.json`.
    public static func profile(configDir: URL?, home: URL) -> Profile? {
        let file = configDir.map { $0.appendingPathComponent(".claude.json") }
            ?? home.appendingPathComponent(".claude.json")
        guard
            let data = try? Data(contentsOf: file),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["oauthAccount"] as? [String: Any]
        else { return nil }
        return Profile(
            email: oauth["emailAddress"] as? String,
            organization: oauth["organizationName"] as? String,
            accountUUID: oauth["accountUuid"] as? String,
            organizationType: oauth["organizationType"] as? String,
            rateLimitTier: (oauth["organizationRateLimitTier"] ?? oauth["userRateLimitTier"]) as? String)
    }

    /// A short, human name: "Work" for ~/.claude-work, the email's local part otherwise.
    static func suggestedName(configDir: URL?, email: String?, isDefault: Bool) -> String {
        if !isDefault, let dir = configDir {
            var name = dir.lastPathComponent
            while name.hasPrefix(".") { name.removeFirst() }
            for prefix in ["claude-", "claude_", "claude."] where name.lowercased().hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
            if !name.isEmpty, name.lowercased() != "claude" {
                return name.prefix(1).uppercased() + name.dropFirst()
            }
        }
        if let local = email?.split(separator: "@").first, !local.isEmpty {
            return String(local)
        }
        return isDefault ? "Main" : "Account"
    }

    /// Every readable login on this Mac. Reads each item through `/usr/bin/security`, so no
    /// consent dialog appears. Items without a `claudeAiOauth` block (Claude Code also keeps
    /// MCP-only items under the same name) are not logins and are skipped.
    public static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        extraConfigDirs: [URL] = [],
        keychainDump: () -> String = dumpKeychain,
        loadCredentials: (String) throws -> OAuthCredentials = { try SecurityToolCredentialSource(service: $0).load() },
        readSecrets: Bool = true
    ) -> [ClaudeAccount] {
        // The default login goes first, so a dedupe below keeps it over a hashed copy.
        var services = services(inKeychainDump: keychainDump()).filter { $0 != baseService }
        services.insert(baseService, at: 0)

        // Map every candidate dir's hash back to the dir, to name and locate each login.
        var dirByHash: [String: URL] = [:]
        for dir in candidateConfigDirs(home: home, extra: extraConfigDirs) {
            for spelling in spellings(of: dir) where dirByHash[suffix(forConfigDir: spelling)] == nil {
                dirByHash[suffix(forConfigDir: spelling)] = dir
            }
        }

        var accounts: [ClaudeAccount] = []
        for service in services {
            let isDefault = service == baseService
            let id = isDefault ? ClaudeAccount.defaultID : String(service.dropFirst(baseService.count + 1))
            let dir = isDefault ? home.appendingPathComponent(".claude", isDirectory: true) : dirByHash[id]
            let profile = isDefault || dir != nil ? profile(configDir: isDefault ? nil : dir, home: home) : nil
            // With secrets, a login is an item that holds an OAuth login. Without them (usage
            // through Claude Code), it is an item whose folder has a signed-in profile: an
            // MCP-only item has no matching folder or no `oauthAccount`.
            let creds: OAuthCredentials?
            if readSecrets {
                do {
                    creds = try loadCredentials(service)
                } catch CredentialError.notFound, CredentialError.malformed {
                    // Not a login: an MCP-only item, or one Claude Code removed.
                    continue
                } catch {
                    // Denied or locked for now (after sleep, a locked Keychain). A known login
                    // stays, so its monitor and backoff survive. Its poll reports the denial.
                    guard profile?.email != nil else { continue }
                    creds = nil
                }
            } else {
                guard profile?.email != nil else { continue }
                creds = nil
            }
            // The same login stored twice (one account logged into two config dirs) is one
            // account with one quota: keep the first, which is the default when present.
            if let uuid = profile?.accountUUID, accounts.contains(where: { $0.accountUUID == uuid }) {
                continue
            }
            // The profile wins: Claude Code rewrites it on every start, but writes the token's
            // plan only at login or refresh, so after an upgrade the token lags by hours.
            let profilePlan = profile.map(\.plan).flatMap { $0 == .unknown ? nil : $0 }
            let tokenPlan = creds.map(\.plan).flatMap { $0 == .unknown ? nil : $0 }
            accounts.append(ClaudeAccount(
                id: id,
                service: service,
                configDir: dir,
                email: profile?.email,
                organization: profile?.organization,
                accountUUID: profile?.accountUUID,
                plan: profilePlan ?? tokenPlan ?? .unknown,
                tokenExpiresAt: creds?.expiresAt,
                suggestedName: suggestedName(configDir: dir, email: profile?.email, isDefault: isDefault)))
        }
        return deduplicateNames(accounts)
    }

    /// Two logins named "matyas" read as one in a segmented control: number the repeats.
    static func deduplicateNames(_ accounts: [ClaudeAccount]) -> [ClaudeAccount] {
        var counts: [String: Int] = [:]
        return accounts.map { account in
            var copy = account
            let key = account.suggestedName.lowercased()
            counts[key, default: 0] += 1
            if let count = counts[key], count > 1 { copy.suggestedName += " \(count)" }
            return copy
        }
    }

    /// Item attributes only. `dump-keychain` without `-d` prints no secrets and shows no dialog.
    public static func dumpKeychain() -> String {
        guard let result = try? ChildProcess.run(
            URL(fileURLWithPath: "/usr/bin/security"), arguments: ["dump-keychain"], timeout: 15),
            !result.timedOut
        else { return "" }
        return String(decoding: result.output, as: UTF8.self)
    }
}

/// Pools several accounts into one reading: each window is the capacity-weighted mean of
/// the accounts that report it, and resets at the earliest of their resets, when the first
/// capacity frees up.
public enum AccountPool {
    public struct Member: Sendable {
        public let snapshot: UsageSnapshot
        public let weight: Double

        public init(snapshot: UsageSnapshot, weight: Double) {
            self.snapshot = snapshot
            self.weight = weight
        }
    }

    public static func combine(_ members: [Member]) -> UsageSnapshot? {
        guard !members.isEmpty else { return nil }
        if members.count == 1 { return members[0].snapshot }

        func pool(_ windows: [(UsageWindow, Double)]) -> UsageWindow? {
            let measured = windows.compactMap { window, weight in
                window.utilization.map { ($0, weight) }
            }
            let resets = windows.compactMap(\.0.resetsAt)
            guard !measured.isEmpty || !resets.isEmpty else { return nil }
            let totalWeight = measured.reduce(0) { $0 + $1.1 }
            let utilization = totalWeight > 0
                ? measured.reduce(0) { $0 + $1.0 * $1.1 } / totalWeight
                : nil
            return UsageWindow(utilization: utilization, resetsAt: resets.min())
        }

        let fiveHour = pool(members.compactMap { m in m.snapshot.fiveHour.map { ($0, m.weight) } })
        let sevenDay = pool(members.compactMap { m in m.snapshot.sevenDay.map { ($0, m.weight) } })

        var modelNames: [String] = []
        for member in members {
            for model in member.snapshot.perModelWindows where !modelNames.contains(model.name) {
                modelNames.append(model.name)
            }
        }
        let limits: [Limit] = modelNames.compactMap { name in
            let entries = members.compactMap { m -> (ModelWindow, Double)? in
                m.snapshot.perModelWindows.first { $0.name == name }.map { ($0, m.weight) }
            }
            guard let window = pool(entries.map { ($0.0.window, $0.1) }) else { return nil }
            return Limit(
                kind: "weekly_scoped", group: "weekly", percent: window.utilization,
                resetsAt: window.resetsAt, isActive: entries.contains { $0.0.isActive },
                severity: nil, scope: .init(model: .init(displayName: name)))
        }

        return UsageSnapshot(
            fiveHour: fiveHour, sevenDay: sevenDay, limits: limits.isEmpty ? nil : limits)
    }
}
