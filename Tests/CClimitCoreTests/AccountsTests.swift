import XCTest

@testable import CClimitCore

final class AccountDiscoveryTests: XCTestCase {
    private let dump = """
        keychain: "/Users/test/Library/Keychains/login.keychain-db"
        attributes:
            "svce"<blob>="Claude Code-credentials"
        attributes:
            "svce"<blob>="Claude Code-credentials-03abf0ee"
        attributes:
            "svce"<blob>="Claude Code-credentials-03abf0ee"
        attributes:
            "svce"<blob>="Claude Code-staging-credentials-12345678"
        attributes:
            "svce"<blob>="Claude Code-credentials-notahash"
        attributes:
            "svce"<blob>="Something else"
        """

    func testServicesKeepsOnlyLoginItemsOnce() {
        XCTAssertEqual(
            AccountDiscovery.services(inKeychainDump: dump),
            ["Claude Code-credentials", "Claude Code-credentials-03abf0ee"])
    }

    func testSuffixMatchesClaudeCodeHash() {
        // printf '%s' /Users/test/.claude-work | shasum -a 256 | cut -c1-8
        XCTAssertEqual(AccountDiscovery.suffix(forConfigDir: "/Users/test/.claude-work"), "03abf0ee")
    }

    func testShellAssignmentsExpandHome() {
        let text = """
            alias cw='CLAUDE_CONFIG_DIR=~/.claude-work claude'
            export CLAUDE_CONFIG_DIR="$HOME/accounts/personal"
            set -x CLAUDE_CONFIG_DIR /opt/claude
            CLAUDE_CONFIG_DIR=$(mktemp -d) claude
            """
        XCTAssertEqual(
            AccountDiscovery.configDirAssignments(in: text, home: "/Users/test"),
            ["/Users/test/.claude-work", "/Users/test/accounts/personal", "/opt/claude"])
    }

    func testSuggestedNames() {
        XCTAssertEqual(
            AccountDiscovery.suggestedName(
                configDir: URL(fileURLWithPath: "/Users/t/.claude-work"), email: "a@b.c", isDefault: false),
            "Work")
        XCTAssertEqual(
            AccountDiscovery.suggestedName(configDir: nil, email: "matyas@x.com", isDefault: true), "matyas")
        XCTAssertEqual(AccountDiscovery.suggestedName(configDir: nil, email: nil, isDefault: true), "Main")
        XCTAssertEqual(
            AccountDiscovery.suggestedName(
                configDir: URL(fileURLWithPath: "/Users/t/.claude"), email: nil, isDefault: false),
            "Account")
    }

    func testDiscoverMapsHashToConfigDirAndSkipsNonLogins() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-home-\(UUID().uuidString)")
        let work = home.appendingPathComponent(".claude-work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"oauthAccount":{"emailAddress":"me@work.com","accountUuid":"w"}}"#
            .write(to: work.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try #"{"oauthAccount":{"emailAddress":"me@home.com","accountUuid":"h"}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let workHash = AccountDiscovery.suffix(forConfigDir: work.standardizedFileURL.path)
        let dump = """
            "svce"<blob>="Claude Code-credentials"
            "svce"<blob>="Claude Code-credentials-\(workHash)"
            "svce"<blob>="Claude Code-credentials-0badf00d"
            """
        let accounts = AccountDiscovery.discover(
            home: home,
            keychainDump: { dump },
            loadCredentials: { service in
                if service.hasSuffix("0badf00d") { throw CredentialError.malformed("mcp only") }
                return OAuthCredentials(
                    accessToken: "t", refreshToken: nil, expiresAt: nil, scopes: [],
                    subscriptionType: "max",
                    rateLimitTier: service.hasSuffix(workHash) ? "default_claude_max_20x" : "default_claude_max_5x")
            })

        XCTAssertEqual(accounts.map(\.id), [ClaudeAccount.defaultID, workHash])
        XCTAssertEqual(accounts[0].email, "me@home.com")
        XCTAssertEqual(accounts[0].plan, .max5x)
        XCTAssertEqual(accounts[1].configDir?.standardizedFileURL, work.standardizedFileURL)
        XCTAssertEqual(accounts[1].email, "me@work.com")
        XCTAssertEqual(accounts[1].plan, .max20x)
        XCTAssertEqual(accounts[1].suggestedName, "Work")
        XCTAssertEqual(accounts[1].storageSuffix, "-\(workHash)")
        XCTAssertEqual(accounts[0].storageSuffix, "")
    }

    func testDiscoverDropsSameAccountInTwoConfigDirs() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-home-\(UUID().uuidString)")
        let copy = home.appendingPathComponent(".claude-copy")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = #"{"oauthAccount":{"emailAddress":"me@home.com","accountUuid":"same"}}"#
        try profile.write(to: copy.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try profile.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let hash = AccountDiscovery.suffix(forConfigDir: copy.standardizedFileURL.path)

        let accounts = AccountDiscovery.discover(
            home: home,
            keychainDump: { "\"svce\"<blob>=\"Claude Code-credentials-\(hash)\"" },
            loadCredentials: { _ in
                OAuthCredentials(accessToken: "t", refreshToken: nil, expiresAt: nil, scopes: [])
            })
        XCTAssertEqual(accounts.map(\.id), [ClaudeAccount.defaultID])
    }

    func testDeniedReadKeepsKnownLoginAndDefaultComesFirst() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-home-\(UUID().uuidString)")
        let work = home.appendingPathComponent(".claude-work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"oauthAccount":{"emailAddress":"me@work.com","accountUuid":"w"}}"#
            .write(to: work.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try #"{"oauthAccount":{"emailAddress":"me@home.com","accountUuid":"h"}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let workHash = AccountDiscovery.suffix(forConfigDir: work.standardizedFileURL.path)
        // The dump lists the hashed item before the default one.
        let dump = """
            "svce"<blob>="Claude Code-credentials-\(workHash)"
            "svce"<blob>="Claude Code-credentials"
            """
        let accounts = AccountDiscovery.discover(
            home: home, keychainDump: { dump },
            loadCredentials: { service in
                // A locked Keychain after sleep: the work read is denied for now.
                if service.hasSuffix(workHash) { throw CredentialError.accessDenied }
                return OAuthCredentials(accessToken: "t", refreshToken: nil, expiresAt: nil, scopes: [])
            })
        XCTAssertEqual(accounts.map(\.id), [ClaudeAccount.defaultID, workHash])
        XCTAssertEqual(accounts[1].email, "me@work.com")
    }

    func testProfilePlanWinsOverStaleTokenAfterUpgrade() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"oauthAccount":{"emailAddress":"me@home.com","accountUuid":"h","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x"}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let accounts = AccountDiscovery.discover(
            home: home, keychainDump: { "" },
            loadCredentials: { _ in
                // The token still carries the plan from before the upgrade.
                OAuthCredentials(
                    accessToken: "t", refreshToken: nil, expiresAt: nil, scopes: [],
                    subscriptionType: "max", rateLimitTier: "default_claude_max_5x")
            })
        XCTAssertEqual(accounts.map(\.plan), [.max20x])
    }

    func testDiscoverWithoutSecretsUsesProfiles() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-home-\(UUID().uuidString)")
        let work = home.appendingPathComponent(".claude-work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"oauthAccount":{"emailAddress":"me@work.com","accountUuid":"w","organizationType":"claude_max","organizationRateLimitTier":"default_claude_max_20x"}}"#
            .write(to: work.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try #"{"oauthAccount":{"emailAddress":"me@home.com","accountUuid":"h","organizationType":"claude_pro"}}"#
            .write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let workHash = AccountDiscovery.suffix(forConfigDir: work.standardizedFileURL.path)
        let dump = """
            "svce"<blob>="Claude Code-credentials"
            "svce"<blob>="Claude Code-credentials-\(workHash)"
            "svce"<blob>="Claude Code-credentials-0badf00d"
            """
        let accounts = AccountDiscovery.discover(
            home: home, keychainDump: { dump },
            loadCredentials: { _ in XCTFail("no secret may be read"); throw CredentialError.malformed("x") },
            readSecrets: false)
        // The MCP-only item (no folder, no profile) drops out without a secret read.
        XCTAssertEqual(accounts.map(\.id), [ClaudeAccount.defaultID, workHash])
        XCTAssertEqual(accounts.map(\.plan), [.pro, .max20x])
        XCTAssertNil(accounts[1].tokenExpiresAt)
    }

    func testDormantAfterAWeekExpired() {
        let now = Date()
        func account(expired: TimeInterval?) -> ClaudeAccount {
            ClaudeAccount(
                id: "x", service: "s", configDir: nil, email: nil, organization: nil, accountUUID: nil,
                plan: .pro, tokenExpiresAt: expired.map { now.addingTimeInterval(-$0) }, suggestedName: "X")
        }
        XCTAssertFalse(account(expired: nil).isDormant(now: now))
        XCTAssertFalse(account(expired: 3600).isDormant(now: now))
        XCTAssertTrue(account(expired: 8 * 24 * 3600).isDormant(now: now))
    }

    func testDuplicateNamesGetNumbered() {
        let base = ClaudeAccount(
            id: "a", service: "s", configDir: nil, email: nil, organization: nil, accountUUID: nil,
            plan: .pro, tokenExpiresAt: nil, suggestedName: "matyas")
        var other = base
        other.suggestedName = "Matyas"
        XCTAssertEqual(
            AccountDiscovery.deduplicateNames([base, other]).map(\.suggestedName), ["matyas", "Matyas 2"])
    }
}

final class PlanTierTests: XCTestCase {
    func testParsesTiers() {
        XCTAssertEqual(PlanTier(subscriptionType: "max", rateLimitTier: "default_claude_max_20x"), .max20x)
        XCTAssertEqual(PlanTier(subscriptionType: "max", rateLimitTier: "default_claude_max_5x"), .max5x)
        XCTAssertEqual(PlanTier(subscriptionType: "max", rateLimitTier: nil), .max5x)
        XCTAssertEqual(PlanTier(subscriptionType: "pro", rateLimitTier: nil), .pro)
        XCTAssertEqual(PlanTier(subscriptionType: nil, rateLimitTier: nil), .unknown)
        XCTAssertEqual(PlanTier.max20x.weight, 20)
        XCTAssertEqual(PlanTier.max20x.label, "Ultra")
        XCTAssertEqual(PlanTier(subscriptionType: "ultra", rateLimitTier: nil), .max20x)
    }

    func testCredentialJSONCarriesPlan() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"t","subscriptionType":"pro","rateLimitTier":"default_claude_pro"}}"#
        let creds = try CredentialJSON.parse(Data(json.utf8))
        XCTAssertEqual(creds.plan, .pro)
    }
}

final class AccountPoolTests: XCTestCase {
    private let early = Date(timeIntervalSince1970: 1_000)
    private let late = Date(timeIntervalSince1970: 2_000)

    func testWeightsByPlanAndTakesEarliestReset() throws {
        let big = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: late),
            sevenDay: UsageWindow(utilization: 50, resetsAt: late))
        let small = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 90, resetsAt: early),
            sevenDay: UsageWindow(utilization: nil, resetsAt: early))
        let pooled = try XCTUnwrap(AccountPool.combine([
            .init(snapshot: big, weight: 4), .init(snapshot: small, weight: 1),
        ]))
        XCTAssertEqual(try XCTUnwrap(pooled.fiveHour?.utilization), 26, accuracy: 0.001)
        XCTAssertEqual(pooled.fiveHour?.resetsAt, early)
        // An account without a reading does not drag the pool toward zero.
        XCTAssertEqual(try XCTUnwrap(pooled.sevenDay?.utilization), 50, accuracy: 0.001)
        XCTAssertEqual(pooled.sevenDay?.resetsAt, early)
    }

    func testPoolsModelWindowsOnlyOverAccountsThatHaveThem() throws {
        func fable(_ percent: Double, active: Bool) -> Limit {
            Limit(
                kind: "weekly_scoped", group: "weekly", percent: percent, resetsAt: late,
                isActive: active, severity: nil, scope: .init(model: .init(displayName: "Fable")))
        }
        let a = UsageSnapshot(fiveHour: nil, sevenDay: nil, limits: [fable(60, active: true)])
        let b = UsageSnapshot(fiveHour: nil, sevenDay: nil, limits: [fable(20, active: false)])
        let c = UsageSnapshot(fiveHour: UsageWindow(utilization: 5, resetsAt: nil), sevenDay: nil)
        let pooled = try XCTUnwrap(AccountPool.combine([
            .init(snapshot: a, weight: 1), .init(snapshot: b, weight: 1), .init(snapshot: c, weight: 1),
        ]))
        let model = try XCTUnwrap(pooled.perModelWindows.first)
        XCTAssertEqual(model.name, "Fable")
        XCTAssertEqual(try XCTUnwrap(model.window.utilization), 40, accuracy: 0.001)
        XCTAssertTrue(model.isActive)
    }

    func testSingleMemberPassesThrough() {
        let snap = UsageSnapshot(fiveHour: UsageWindow(utilization: 1, resetsAt: nil), sevenDay: nil)
        XCTAssertEqual(AccountPool.combine([.init(snapshot: snap, weight: 5)]), snap)
        XCTAssertNil(AccountPool.combine([]))
    }
}

final class AccountSetupTests: XCTestCase {
    private func tempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    func testSlug() {
        XCTAssertEqual(AccountSetup.slug(for: "Work"), "work")
        XCTAssertEqual(AccountSetup.slug(for: "  Client A/B  "), "client-a-b")
        XCTAssertEqual(AccountSetup.slug(for: "Práce"), "prace")
        XCTAssertEqual(AccountSetup.slug(for: "--x__y--"), "x-y")
        XCTAssertEqual(AccountSetup.slug(for: "!!!"), "")
    }

    func testValidation() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        func check(_ name: String, ids: Set<String> = []) -> AccountSetup.Validation {
            AccountSetup.validate(name: name, home: home, takenNames: ["Personal"], loginIDs: ids)
        }
        let work = AccountSetup.folder(forSlug: "work", home: home)
        XCTAssertEqual(check("Work"), .valid(slug: "work", folder: work))
        XCTAssertEqual(check("   "), .empty)
        XCTAssertEqual(check("???"), .noLettersOrDigits)
        XCTAssertEqual(check("personal "), .duplicateName)

        // An empty existing folder is fine. A Keychain item for its hash is not.
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        XCTAssertTrue(check("Work").isValid)
        let hash = AccountDiscovery.suffix(forConfigDir: work.path)
        XCTAssertEqual(check("Work", ids: [hash]), .folderHasLogin(work))

        // Neither is a folder whose .claude.json names an account.
        try #"{"oauthAccount":{"emailAddress":"a@b.c","accountUuid":"u"}}"#
            .write(to: work.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(check("Work"), .folderHasLogin(work))
    }

    func testShellFromPath() {
        XCTAssertEqual(AccountSetup.Shell(shellPath: "/bin/zsh"), .zsh)
        XCTAssertEqual(AccountSetup.Shell(shellPath: "/opt/homebrew/bin/bash"), .bash)
        XCTAssertEqual(AccountSetup.Shell(shellPath: "/opt/homebrew/bin/fish"), .fish)
        XCTAssertEqual(AccountSetup.Shell(shellPath: nil), .zsh)
        let home = URL(fileURLWithPath: "/Users/t")
        XCTAssertEqual(AccountSetup.Shell.bash.rcFile(home: home).path, "/Users/t/.bash_profile")
        XCTAssertEqual(AccountSetup.Shell.fish.rcFile(home: home).path, "/Users/t/.config/fish/config.fish")
    }

    func testAliasLines() {
        let folder = URL(fileURLWithPath: "/Users/t/.claude-work")
        XCTAssertEqual(
            AccountSetup.aliasLine(slug: "work", folder: folder, shell: .zsh),
            #"alias claude-work='CLAUDE_CONFIG_DIR="/Users/t/.claude-work" claude'"#)
        XCTAssertEqual(
            AccountSetup.aliasLine(slug: "work", folder: folder, shell: .bash),
            #"alias claude-work='CLAUDE_CONFIG_DIR="/Users/t/.claude-work" claude'"#)
        XCTAssertEqual(
            AccountSetup.aliasLine(slug: "work", folder: folder, shell: .fish),
            #"alias claude-work 'env CLAUDE_CONFIG_DIR="/Users/t/.claude-work" claude'"#)
        // Odd home folders stay quoted.
        let odd = URL(fileURLWithPath: "/Users/o'b $x/.claude-work")
        XCTAssertEqual(
            AccountSetup.aliasLine(slug: "work", folder: odd, shell: .zsh),
            #"alias claude-work='CLAUDE_CONFIG_DIR="/Users/o'\''b \$x/.claude-work" claude'"#)
        XCTAssertEqual(
            AccountSetup.aliasLine(slug: "work", folder: odd, shell: .fish),
            #"alias claude-work 'env CLAUDE_CONFIG_DIR="/Users/o\'b \\$x/.claude-work" claude'"#)
    }

    func testAliasLineIsFoundByDiscovery() {
        let line = AccountSetup.aliasLine(
            slug: "work", folder: URL(fileURLWithPath: "/Users/t/.claude-work"), shell: .zsh)
        XCTAssertEqual(AccountDiscovery.configDirAssignments(in: line, home: "/Users/t"), ["/Users/t/.claude-work"])
    }

    func testAppendingAliasDedups() {
        let line = "alias claude-work='x'"
        XCTAssertEqual(AccountSetup.appending(aliasLine: line, to: ""), "\n# Added by cclimit\n\(line)\n")
        XCTAssertEqual(
            AccountSetup.appending(aliasLine: line, to: "export A=1"),
            "export A=1\n\n# Added by cclimit\n\(line)\n")
        XCTAssertNil(AccountSetup.appending(aliasLine: line, to: "export A=1\n  \(line)\n"))
    }

    func testInstallAliasWritesOnce() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = AccountSetup.folder(forSlug: "work", home: home)
        for shell in [AccountSetup.Shell.zsh, .bash, .fish] {
            XCTAssertEqual(try AccountSetup.installAlias(slug: "work", folder: folder, shell: shell, home: home), .added)
            XCTAssertEqual(
                try AccountSetup.installAlias(slug: "work", folder: folder, shell: shell, home: home), .alreadyPresent)
            let text = try String(contentsOf: shell.rcFile(home: home), encoding: .utf8)
            XCTAssertEqual(text.components(separatedBy: "alias claude-work").count, 2)
        }
    }

    func testLoginScriptQuotesFolder() {
        let script = AccountSetup.loginScript(folder: URL(fileURLWithPath: "/Users/o'b/.claude-work"))
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains(#"CLAUDE_CONFIG_DIR='/Users/o'\''b/.claude-work' "$CLAUDE_BIN" auth login"#))
        XCTAssertTrue(script.contains("return to cclimit"))
    }

    /// `sh -n` parses the script without running a line of it.
    func testLoginScriptParses() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        stdin.fileHandleForWriting.write(Data(
            AccountSetup.loginScript(folder: URL(fileURLWithPath: "/Users/o'b $x/.claude-work")).utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testExpectedServicesCoverPlainPath() {
        let folder = URL(fileURLWithPath: "/Users/t/.claude-work")
        XCTAssertTrue(AccountSetup.expectedServices(forConfigDir: folder).contains(
            "Claude Code-credentials-" + AccountDiscovery.suffix(forConfigDir: "/Users/t/.claude-work")))
    }

    func testNameFromEmail() {
        XCTAssertEqual(AccountSetup.name(fromEmail: "matyas@mailnail.com"), "matyas")
        XCTAssertEqual(AccountSetup.name(fromEmail: nil), "")
    }

    func testDiscoverIncludesExtraFolders() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let odd = home.appendingPathComponent("accounts/team", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let hash = AccountDiscovery.suffix(forConfigDir: odd.standardizedFileURL.path)
        let accounts = AccountDiscovery.discover(
            home: home, extraConfigDirs: [odd],
            keychainDump: { "\"svce\"<blob>=\"Claude Code-credentials-\(hash)\"" },
            loadCredentials: { service in
                if service == AccountDiscovery.baseService { throw CredentialError.malformed("none") }
                return OAuthCredentials(accessToken: "t", refreshToken: nil, expiresAt: nil, scopes: [])
            })
        XCTAssertEqual(accounts.first?.configDir?.standardizedFileURL, odd.standardizedFileURL)
    }
}

final class IdentityTrackerTests: XCTestCase {
    private func account(_ id: String, uuid: String?, email: String?, plan: PlanTier = .max20x) -> ClaudeAccount {
        ClaudeAccount(
            id: id, service: "s", configDir: URL(fileURLWithPath: "/Users/t/.claude"), email: email,
            organization: nil, accountUUID: uuid, plan: plan, tokenExpiresAt: nil, suggestedName: "x")
    }

    func testReplacedLoginIsRecorded() {
        let now = Date(timeIntervalSince1970: 5_000)
        let first = IdentityTracker.reconcile(
            known: [:], replaced: [],
            discovered: [account("default", uuid: "old", email: "matyas@mailnail.com", plan: .max5x)])
        XCTAssertEqual(first.known["default"]?.accountUUID, "old")
        XCTAssertTrue(first.replaced.isEmpty)

        let second = IdentityTracker.reconcile(
            known: first.known, replaced: first.replaced,
            discovered: [account("default", uuid: "new", email: "cernymatyas@email.cz")], now: now)
        XCTAssertEqual(second.known["default"]?.email, "cernymatyas@email.cz")
        XCTAssertEqual(second.replaced, [ReplacedLogin(
            accountID: "default", accountUUID: "old", email: "matyas@mailnail.com", planLabel: "Max 5x",
            configDirPath: "/Users/t/.claude", replacedAt: now)])

        // The same discovery again adds nothing.
        let third = IdentityTracker.reconcile(
            known: second.known, replaced: second.replaced,
            discovered: [account("default", uuid: "new", email: "cernymatyas@email.cz")])
        XCTAssertEqual(third.replaced.count, 1)
    }

    func testMissingProfileKeepsIdentity() {
        let known = ["a": AccountIdentity(accountUUID: "u", email: "e", planLabel: nil)]
        let result = IdentityTracker.reconcile(
            known: known, replaced: [], discovered: [account("a", uuid: nil, email: nil)])
        XCTAssertEqual(result.known, known)
        XCTAssertTrue(result.replaced.isEmpty)
    }

    func testReplacedEntryClearsWhenAccountReturns() {
        let entry = ReplacedLogin(
            accountID: "default", accountUUID: "old", email: "matyas@mailnail.com", planLabel: nil,
            configDirPath: nil, replacedAt: Date())
        let result = IdentityTracker.reconcile(
            known: ["default": AccountIdentity(accountUUID: "new", email: nil, planLabel: nil)],
            replaced: [entry],
            discovered: [account("default", uuid: "new", email: nil),
                         account("abcd1234", uuid: "old", email: "matyas@mailnail.com")])
        XCTAssertTrue(result.replaced.isEmpty)
    }
}
