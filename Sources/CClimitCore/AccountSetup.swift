import Foundation

/// Pure helpers behind Settings > Accounts > "Add Account…": the folder name, the check
/// that refuses a bad name, the shell alias, and the Terminal script that runs the login.
public enum AccountSetup {
    /// "Work" -> "work", "Client A/B" -> "client-a-b", "Práce" -> "prace". Letters lose
    /// their accents, everything that is not a-z or 0-9 becomes one "-", and the ends are trimmed.
    public static func slug(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var out = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, out.last != "-" {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// `~/.claude-<slug>`.
    public static func folder(forSlug slug: String, home: URL) -> URL {
        home.appendingPathComponent(".claude-\(slug)", isDirectory: true).standardizedFileURL
    }

    public enum Validation: Equatable, Sendable {
        case valid(slug: String, folder: URL)
        case empty
        case noLettersOrDigits
        case duplicateName
        case folderHasLogin(URL)

        public var isValid: Bool {
            if case .valid = self { return true }
            return false
        }
    }

    /// Refuses an empty name, a name already in use, and a folder that already holds a
    /// login: either a Keychain item for its hash (`loginIDs`, the discovered account ids) or
    /// an `oauthAccount` in its `.claude.json`. An existing empty folder is fine.
    public static func validate(
        name: String, home: URL, takenNames: [String], loginIDs: Set<String>,
        fileManager fm: FileManager = .default
    ) -> Validation {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        let slug = slug(for: trimmed)
        guard !slug.isEmpty else { return .noLettersOrDigits }
        if takenNames.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == trimmed.lowercased() }) {
            return .duplicateName
        }
        let dir = folder(forSlug: slug, home: home)
        let hashes = AccountDiscovery.spellings(of: dir).map { AccountDiscovery.suffix(forConfigDir: $0) }
        if hashes.contains(where: loginIDs.contains) || hasProfile(dir, fileManager: fm) {
            return .folderHasLogin(dir)
        }
        return .valid(slug: slug, folder: dir)
    }

    static func hasProfile(_ dir: URL, fileManager fm: FileManager) -> Bool {
        let file = dir.appendingPathComponent(".claude.json")
        guard fm.fileExists(atPath: file.path) else { return false }
        return AccountDiscovery.profile(configDir: dir, home: dir)?.accountUUID != nil
    }

    /// The Keychain item names Claude Code would use for this folder, for every spelling a
    /// shell could pass. Lets a waiting sheet poll `dump-keychain` without reading a secret.
    public static func expectedServices(forConfigDir dir: URL) -> Set<String> {
        Set(AccountDiscovery.spellings(of: dir).map {
            AccountDiscovery.baseService + "-" + AccountDiscovery.suffix(forConfigDir: $0)
        })
    }

    /// "matyas@mailnail.com" -> "matyas". The name an "Add Back…" sheet starts with.
    public static func name(fromEmail email: String?) -> String {
        guard let local = email?.split(separator: "@").first, !local.isEmpty else { return "" }
        return String(local)
    }

    // MARK: - Shell alias

    public enum Shell: String, Equatable, Sendable {
        case zsh, bash, fish

        /// From `$SHELL`. Anything unknown gets zsh, the macOS default.
        public init(shellPath: String?) {
            let name = shellPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            switch name {
            case "bash": self = .bash
            case "fish": self = .fish
            default: self = .zsh
            }
        }

        public func rcFile(home: URL) -> URL {
            switch self {
            case .zsh: return home.appendingPathComponent(".zshrc")
            case .bash: return home.appendingPathComponent(".bash_profile")
            case .fish: return home.appendingPathComponent(".config/fish/config.fish")
            }
        }

        /// `~/.zshrc`, for the checkbox label.
        public var rcDisplayPath: String {
            switch self {
            case .zsh: return "~/.zshrc"
            case .bash: return "~/.bash_profile"
            case .fish: return "~/.config/fish/config.fish"
            }
        }
    }

    public static func commandName(slug: String) -> String { "claude-\(slug)" }

    /// zsh and bash: `alias claude-work='CLAUDE_CONFIG_DIR="/Users/me/.claude-work" claude'`.
    /// fish: `alias claude-work 'env CLAUDE_CONFIG_DIR="/Users/me/.claude-work" claude'`
    /// (`env`, because fish before 3.1 has no `VAR=value cmd`).
    public static func aliasLine(slug: String, folder: URL, shell: Shell) -> String {
        let path = doubleQuoted(folder.standardizedFileURL.path)
        switch shell {
        case .zsh, .bash:
            return "alias \(commandName(slug: slug))=" + posixSingleQuoted("CLAUDE_CONFIG_DIR=\(path) claude")
        case .fish:
            return "alias \(commandName(slug: slug)) " + fishSingleQuoted("env CLAUDE_CONFIG_DIR=\(path) claude")
        }
    }

    public enum AliasResult: Equatable, Sendable {
        case added
        case alreadyPresent
    }

    /// The rc text with the alias appended, or nil when the exact line is already there.
    public static func appending(aliasLine line: String, to text: String) -> String? {
        let present = text.split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespaces) == line }
        if present { return nil }
        var out = text
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        out += "\n# Added by cclimit\n\(line)\n"
        return out
    }

    /// Appends the alias to the shell's rc file, creating the file (and fish's config dir)
    /// when missing. Leaves the file alone when the line is already there.
    @discardableResult
    public static func installAlias(
        slug: String, folder: URL, shell: Shell, home: URL, fileManager fm: FileManager = .default
    ) throws -> AliasResult {
        let rc = shell.rcFile(home: home)
        let line = aliasLine(slug: slug, folder: folder, shell: shell)
        let existing = (try? String(contentsOf: rc, encoding: .utf8)) ?? ""
        guard let next = appending(aliasLine: line, to: existing) else { return .alreadyPresent }
        try fm.createDirectory(at: rc.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Not atomic: an rc file is often a symlink into a dotfiles repo, and an atomic write
        // would replace the link with a plain file.
        try Data(next.utf8).write(to: rc)
        return .added
    }

    // MARK: - Terminal script

    /// A `/bin/sh` script for a `.command` file. Terminal runs it in a new window: it finds
    /// `claude` (the app's PATH is not the user's), runs `claude auth login` with the new
    /// config dir, and tells the user to come back. Holds no secret: the login happens in
    /// Claude Code and the browser.
    public static func loginScript(folder: URL) -> String {
        let dir = posixSingleQuoted(folder.standardizedFileURL.path)
        return """
            #!/bin/sh
            # Written by cclimit to add a Claude Code account. Safe to delete.
            CLAUDE_BIN="$(command -v claude 2>/dev/null)"
            if [ -z "$CLAUDE_BIN" ]; then
              for candidate in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \\
                "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
                if [ -x "$candidate" ]; then CLAUDE_BIN="$candidate"; break; fi
              done
            fi
            if [ -z "$CLAUDE_BIN" ] && [ -n "$SHELL" ]; then
              CLAUDE_BIN="$("$SHELL" -lic 'command -v claude' 2>/dev/null | tail -n 1)"
            fi
            if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
              echo "cclimit could not find Claude Code. Install it, then try again."
              exit 1
            fi
            echo "Log in with the account you want to add. When the browser login is done, return to cclimit."
            echo
            CLAUDE_CONFIG_DIR=\(dir) "$CLAUDE_BIN" auth login
            echo
            echo "You can close this window and return to cclimit."

            """
    }

    // MARK: - Quoting

    /// `'...'` for sh, zsh, and bash: a single quote inside becomes `'\''`.
    public static func posixSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `'...'` for fish: backslash and single quote get a backslash.
    static func fishSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// `"..."` for any of the three shells: `\`, `"`, `$`, and backtick get a backslash.
    static func doubleQuoted(_ s: String) -> String {
        var out = "\""
        for char in s {
            if char == "\\" || char == "\"" || char == "$" || char == "`" { out.append("\\") }
            out.append(char)
        }
        return out + "\""
    }
}

// MARK: - Replaced logins

/// Who a Keychain item last belonged to. Running `/login` inside a config dir overwrites
/// that dir's item, so the id stays and the account behind it changes.
public struct AccountIdentity: Codable, Equatable, Sendable {
    public var accountUUID: String
    public var email: String?
    public var planLabel: String?

    public init(accountUUID: String, email: String?, planLabel: String?) {
        self.accountUUID = accountUUID
        self.email = email
        self.planLabel = planLabel
    }
}

/// An account that another login pushed out of its config dir. Settings shows it until the
/// user adds it back or dismisses it.
public struct ReplacedLogin: Codable, Equatable, Identifiable, Sendable {
    public var id: String { accountID + ":" + accountUUID }
    public var accountID: String
    public var accountUUID: String
    public var email: String?
    public var planLabel: String?
    public var configDirPath: String?
    public var replacedAt: Date

    public init(
        accountID: String, accountUUID: String, email: String?, planLabel: String?,
        configDirPath: String?, replacedAt: Date
    ) {
        self.accountID = accountID
        self.accountUUID = accountUUID
        self.email = email
        self.planLabel = planLabel
        self.configDirPath = configDirPath
        self.replacedAt = replacedAt
    }
}

public enum IdentityTracker {
    /// Compares a discovery against the identities seen before. An id whose account UUID
    /// changed adds a `ReplacedLogin` for the old account. An old account that shows up
    /// again anywhere (it got its own folder) drops its entry. Ids without a UUID (no
    /// readable `.claude.json`) keep their last known identity.
    public static func reconcile(
        known: [String: AccountIdentity], replaced: [ReplacedLogin], discovered: [ClaudeAccount],
        now: Date = Date()
    ) -> (known: [String: AccountIdentity], replaced: [ReplacedLogin]) {
        var nextKnown = known
        var nextReplaced = replaced
        for account in discovered {
            guard let uuid = account.accountUUID else { continue }
            if let old = known[account.id], old.accountUUID != uuid,
               !nextReplaced.contains(where: { $0.accountUUID == old.accountUUID }) {
                nextReplaced.append(ReplacedLogin(
                    accountID: account.id, accountUUID: old.accountUUID, email: old.email,
                    planLabel: old.planLabel, configDirPath: account.configDir?.path, replacedAt: now))
            }
            nextKnown[account.id] = AccountIdentity(
                accountUUID: uuid, email: account.email, planLabel: account.plan.label)
        }
        let present = Set(discovered.compactMap(\.accountUUID))
        nextReplaced.removeAll { present.contains($0.accountUUID) }
        return (nextKnown, nextReplaced)
    }
}
