import Foundation

/// Finds the Claude Code setups on this Mac that send their traffic through a proxy. Claude
/// Code reaches a proxy only through `ANTHROPIC_BASE_URL`, set in a config dir's
/// `settings.json` (`env`) or exported by a shell startup file, so those are the places to
/// look. No key and no request: the address alone is not a secret.
public struct ProxyRoute: Equatable, Sendable {
    /// The config dir whose Claude Code uses the proxy. Its `projects` folder holds the
    /// transcripts of that traffic.
    public let configDir: URL
    public let baseURL: URL

    public init(configDir: URL, baseURL: URL) {
        self.configDir = configDir.standardizedFileURL
        self.baseURL = baseURL
    }

    public var projectsDir: URL { configDir.appendingPathComponent("projects", isDirectory: true) }
}

public enum ProxyDetection {
    /// Every config dir routed away from Anthropic. A dir with its own `ANTHROPIC_BASE_URL`
    /// wins over a shell-wide one. A shell-wide one applies to ~/.claude and to every dir
    /// that sets none itself.
    public static func routes(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, extraConfigDirs: [URL] = []
    ) -> [ProxyRoute] {
        let defaultDir = home.appendingPathComponent(".claude", isDirectory: true).standardizedFileURL
        var dirs = [defaultDir]
        for dir in AccountDiscovery.candidateConfigDirs(home: home, extra: extraConfigDirs) where !dirs.contains(dir) {
            dirs.append(dir)
        }
        let shell = shellBaseURL(home: home)
        var out: [ProxyRoute] = []
        for dir in dirs {
            let own = settingsBaseURL(configDir: dir)
            // A shell-wide URL reaches only dirs Claude Code actually uses: ones with transcripts.
            let inherited = FileManager.default.fileExists(atPath: dir.appendingPathComponent("projects").path)
                ? shell : nil
            guard let url = own ?? inherited, !isAnthropic(url) else { continue }
            out.append(ProxyRoute(configDir: dir, baseURL: url))
        }
        return out
    }

    /// `env.ANTHROPIC_BASE_URL` in `<dir>/settings.json`.
    public static func settingsBaseURL(configDir: URL) -> URL? {
        guard
            let data = try? Data(contentsOf: configDir.appendingPathComponent("settings.json")),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let env = root["env"] as? [String: Any],
            let raw = env["ANTHROPIC_BASE_URL"] as? String
        else { return nil }
        return ProxyConfig.normalizedURL(raw)
    }

    /// The last `ANTHROPIC_BASE_URL=` export in the usual shell startup files. Lines that also
    /// set `CLAUDE_CONFIG_DIR` belong to an alias for one dir, so they do not count as shell-wide.
    static func shellBaseURL(home: URL) -> URL? {
        let files = [".zshenv", ".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile",
                     ".config/fish/config.fish"]
        var found: URL?
        for file in files {
            guard let text = try? String(contentsOf: home.appendingPathComponent(file), encoding: .utf8)
            else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), !trimmed.contains("CLAUDE_CONFIG_DIR"),
                      let url = assignedURL(in: trimmed) else { continue }
                found = url
            }
        }
        return found
    }

    /// `export ANTHROPIC_BASE_URL="http://pi:8317"` or fish's `set -gx ANTHROPIC_BASE_URL …`.
    static func assignedURL(in line: String) -> URL? {
        guard let range = line.range(of: "ANTHROPIC_BASE_URL") else { return nil }
        var rest = line[range.upperBound...].drop { $0 == " " }
        if rest.first == "=" { rest = rest.dropFirst() }
        rest = rest.drop { $0 == "\"" || $0 == "'" }
        let value = rest.prefix { !$0.isWhitespace && $0 != "\"" && $0 != "'" && $0 != ";" }
        guard !value.isEmpty, !value.hasPrefix("$") else { return nil }
        return ProxyConfig.normalizedURL(String(value))
    }

    static func isAnthropic(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        return host == "anthropic.com" || host.hasSuffix(".anthropic.com")
    }

    /// The server's root answer: CLIProxyAPI says `"message": "CLI Proxy API Server"` there and
    /// needs no key for it, so asking can never trip its ban on wrong keys.
    public static func isCLIProxy(rootResponse data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = root["message"] as? String else { return false }
        return message.localizedCaseInsensitiveContains("CLI Proxy API")
    }

    /// One keyless GET of the server root. False for anything else, or no answer in 5 s.
    public static func isCLIProxy(baseURL: URL, session: URLSession = .shared) async -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return isCLIProxy(rootResponse: data)
    }
}
