import Foundation

/// Detects the Claude Code version installed on this machine, so the User-Agent we send
/// tracks reality instead of a pinned constant that rots between cclimit releases.
/// Purely file-based (no subprocess): covers the native installer and npm/nvm layouts.
public enum ClaudeCodeVersion {
    /// Best-effort detection; falls back to `UsageClient.defaultUserAgentVersion` upstream.
    public static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        var candidates: [String] = []

        // Native installer: ~/.local/bin/claude -> ~/.local/share/claude/versions/<semver>
        let nativeBin = home.appendingPathComponent(".local/bin/claude")
        if let resolved = try? FileManager.default.destinationOfSymbolicLink(atPath: nativeBin.path) {
            let leaf = URL(fileURLWithPath: resolved).lastPathComponent
            if isSemver(leaf) { candidates.append(leaf) }
        }
        // Native installer versions dir (in case the symlink is absent).
        let versionsDir = home.appendingPathComponent(".local/share/claude/versions")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: versionsDir.path) {
            candidates.append(contentsOf: entries.filter(isSemver))
        }
        // npm global installs: nvm (any node version), Homebrew node, system node,
        // and Claude Code's own migrate-installer location.
        var packageJSONs: [URL] = [
            home.appendingPathComponent(".claude/local/node_modules/@anthropic-ai/claude-code/package.json"),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/package.json"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@anthropic-ai/claude-code/package.json"),
        ]
        let nvmNode = home.appendingPathComponent(".nvm/versions/node")
        if let nodes = try? FileManager.default.contentsOfDirectory(atPath: nvmNode.path) {
            for node in nodes {
                packageJSONs.append(
                    nvmNode.appendingPathComponent(
                        "\(node)/lib/node_modules/@anthropic-ai/claude-code/package.json"))
            }
        }
        for url in packageJSONs {
            guard
                let data = try? Data(contentsOf: url),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let version = obj["version"] as? String,
                isSemver(version)
            else { continue }
            candidates.append(version)
        }

        return newest(of: candidates)
    }

    static func isSemver(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// Highest semver wins — multiple installs (nvm node versions, native + npm) are common.
    static func newest(of versions: [String]) -> String? {
        versions.max { a, b in
            let av = a.split(separator: ".").compactMap { Int($0) }
            let bv = b.split(separator: ".").compactMap { Int($0) }
            return av.lexicographicallyPrecedes(bv)
        }
    }
}
