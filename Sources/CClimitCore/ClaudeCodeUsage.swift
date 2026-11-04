import Foundation

/// Usage read through Claude Code itself, the way T3 Code does it: start `claude` in its
/// stream-JSON mode, send the `initialize` and `get_usage` control requests, and read the
/// answer. Claude Code signs in with its own credentials, so cclimit never reads, holds, or
/// sends a token. The answer is the same payload as the usage endpoint, so the existing
/// `UsageSnapshot` decoder reads it.
///
/// `get_usage` calls the usage endpoint, whose budget is small and shared with Claude Code's
/// own `/usage`. Call it about as often as the per-model supplement (minutes, not seconds).
public struct ClaudeCodeUsageSource: Sendable {
    public struct Reading: Sendable {
        public let snapshot: UsageSnapshot
        public let email: String?
        /// "Claude Max", "Claude Pro", …, as Claude Code reports it.
        public let subscription: String?
    }

    /// nil for the default login, else the account's `CLAUDE_CONFIG_DIR`.
    public let configDir: URL?
    public let timeout: TimeInterval

    public init(configDir: URL?, timeout: TimeInterval = 30) {
        self.configDir = configDir
        self.timeout = timeout
    }

    /// The flags keep the call side-effect free: no hooks (a user's SessionStart hooks would
    /// run on every poll), no MCP servers, no IDE connection, no saved session.
    static let arguments = [
        "-p",
        "--settings", #"{"disableAllHooks":true}"#,
        "--no-session-persistence",
        "--strict-mcp-config",
        "--output-format", "stream-json",
        "--input-format", "stream-json",
        "--verbose",
    ]

    public func fetch() async throws -> Reading {
        let configDir = configDir
        let timeout = timeout
        // `locate()` can ask a login shell: keep it off the caller's thread too.
        return try await Task.detached(priority: .utility) {
            guard let executable = ClaudeCodeCLI.locate() else { throw UsageError.claudeCodeNotFound }
            return try Self.run(executable: executable, configDir: configDir, timeout: timeout)
        }.value
    }

    public static func environment(configDir: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeCodeCLI.searchPath
        env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        env["CLAUDE_CODE_AUTO_CONNECT_IDE"] = "0"
        env["CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL"] = "1"
        // A parent Claude Code session (cclimit started from a terminal running `claude`)
        // must not leak its own config dir or nesting markers into the child.
        env["CLAUDECODE"] = nil
        env["CLAUDE_CODE_ENTRYPOINT"] = nil
        if let configDir {
            env["CLAUDE_CONFIG_DIR"] = configDir.path
        } else {
            env["CLAUDE_CONFIG_DIR"] = nil
        }
        return env
    }

    private static func run(executable: URL, configDir: URL?, timeout: TimeInterval) throws -> Reading {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(configDir: configDir)
        // A neutral working directory: no project CLAUDE.md or settings get picked up.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        // The answer arrives on the pipe's reader thread. The first result, an error, or EOF
        // ends the wait. The wait itself has a deadline, so a hung child cannot hold it.
        let outcome = LockedBox<Result<Reading, Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        func finish(_ result: Result<Reading, Error>) {
            var first = false
            outcome.mutate { if $0 == nil { $0 = result; first = true } }
            if first { done.signal() }
        }
        let parser = LockedBox(ControlStreamParser())
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                finish(.failure(UsageError.claudeCodeFailed("Claude Code exited without an answer")))
                return
            }
            do {
                var reading: Reading?
                try parser.mutate { reading = try $0.feed(chunk) }
                if let reading { finish(.success(reading)) }
            } catch {
                finish(.failure(error))
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw UsageError.claudeCodeNotFound
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            ChildProcess.stop(process, exited: exited)
        }

        let requests = [
            #"{"type":"control_request","request_id":"init","request":{"subtype":"initialize"}}"#,
            #"{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage"}}"#,
        ].joined(separator: "\n") + "\n"
        do {
            // A child that died at start closes the pipe: the write fails with EPIPE, which
            // `write(contentsOf:)` throws (SIGPIPE is ignored app-wide) instead of crashing.
            try input.fileHandleForWriting.write(contentsOf: Data(requests.utf8))
        } catch {
            throw UsageError.claudeCodeFailed("Claude Code closed its input")
        }

        if done.wait(timeout: .now() + timeout) == .timedOut {
            throw UsageError.claudeCodeFailed("Claude Code did not answer in \(Int(timeout)) s")
        }
        switch outcome.value {
        case .success(let reading): return reading
        case .failure(let error): throw error
        case nil: throw UsageError.claudeCodeFailed("Claude Code did not answer")
        }
    }
}

/// Splits Claude Code's stream-JSON output into lines and picks out the control responses.
/// Separate from the process so tests can feed it recorded output.
struct ControlStreamParser {
    private var buffer = Data()
    private var email: String?
    private var subscription: String?

    /// Returns the reading once the usage answer is in, nil while more output is needed.
    mutating func feed(_ chunk: Data) throws -> ClaudeCodeUsageSource.Reading? {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let reading = try handle(line: Data(line)) { return reading }
        }
        return nil
    }

    private mutating func handle(line: Data) throws -> ClaudeCodeUsageSource.Reading? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any]
        else { return nil }
        let body = response["response"] as? [String: Any] ?? [:]
        switch response["request_id"] as? String {
        case "init":
            let account = body["account"] as? [String: Any] ?? [:]
            if account["tokenSource"] as? String == "none", account["email"] == nil {
                throw UsageError.noCredentials
            }
            email = account["email"] as? String
            subscription = account["subscriptionType"] as? String
            return nil
        case "usage":
            if response["subtype"] as? String == "error" {
                let message = (response["error"] as? String ?? "").lowercased()
                if message.contains("429") || message.contains("rate limit") || message.contains("rate_limit") {
                    throw UsageError.rateLimited(retryAfter: nil)
                }
                if message.contains("401") || message.contains("authentication") || message.contains("unauthorized")
                    || message.contains("log in") || message.contains("login") {
                    throw UsageError.unauthorized
                }
                throw UsageError.schemaChanged("get_usage error: \(message.prefix(120))")
            }
            guard body["rate_limits_available"] as? Bool == true else {
                // An API-key or signed-out login has no subscription windows.
                throw email == nil ? UsageError.noCredentials : UsageError.forbidden
            }
            guard let limits = body["rate_limits"], !(limits is NSNull) else {
                // Available but empty: the usage endpoint refused Claude Code, most likely
                // its rate limit. Treat it as one so the poll backs off.
                throw UsageError.rateLimited(retryAfter: nil)
            }
            let data = try JSONSerialization.data(withJSONObject: limits)
            do {
                let snapshot = try UsageJSON.decoder().decode(UsageSnapshot.self, from: data)
                return .init(snapshot: snapshot, email: email, subscription: subscription)
            } catch {
                throw UsageError.schemaChanged("get_usage decode failed: \(error)")
            }
        default:
            return nil
        }
    }
}

/// Finds the `claude` executable. A menu bar app does not inherit the login shell's PATH,
/// so it looks in the usual install places first and asks the login shell only once.
public enum ClaudeCodeCLI {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static var candidates: [String] {
        [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.volta/bin/claude",
        ]
    }

    /// PATH for the child: Node-based installs need `node` next to `claude`.
    static var searchPath: String {
        let base = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let inherited = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var seen = Set<String>()
        return (base + inherited).filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    /// A hit is kept for good. A miss is kept for 10 minutes, so a fresh install is found
    /// without a login shell on every poll.
    private static let cache = LockedBox<(url: URL?, checked: Date)?>(nil)

    public static func locate(now: Date = Date()) -> URL? {
        if let cached = cache.value,
           cached.url != nil || now.timeIntervalSince(cached.checked) < 600 {
            return cached.url
        }
        let fm = FileManager.default
        let found = candidates.first { fm.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
            ?? loginShellLookup()
        cache.value = (found, now)
        return found
    }

    private static func loginShellLookup() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // A stalled rc file must not hold discovery or a poll: five seconds, then give up.
        guard let result = try? ChildProcess.run(
            URL(fileURLWithPath: shell), arguments: ["-lc", "command -v claude"], timeout: 5),
            !result.timedOut
        else { return nil }
        let path = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").last.map(String.init) ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// A tiny lock-guarded value, for caches shared across threads.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func mutate<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&stored)
    }
}
