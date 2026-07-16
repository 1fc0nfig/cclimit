import Foundation

/// The moat (v1.0): attribute burn to projects/sessions by reading Claude Code's local
/// transcripts (~/.claude/projects/**/*.jsonl). Local token counts diverge from server
/// truth for absolute limits (product.md §3 Option D) — so this computes RELATIVE shares
/// only and never feeds the gauges.
public struct ProjectBurn: Equatable, Sendable, Identifiable {
    public let name: String
    public let tokens: Int
    public let share: Double // 0...1 of the analyzed window

    public var id: String { name }

    public init(name: String, tokens: Int, share: Double) {
        self.name = name
        self.tokens = tokens
        self.share = share
    }
}

public enum AttributionEngine {
    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Relative burn per project since `since` (typically the current 5h window start).
    public static func burn(root: URL = defaultRoot(), since: Date, now: Date = Date()) -> [ProjectBurn] {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        var totals: [String: Int] = [:]
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            // Skip transcripts untouched since the window started — cheap and correct.
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate, modified < since {
                continue
            }
            let fallbackName = prettify(directoryName: url.deletingLastPathComponent().lastPathComponent)
            for (project, tokens) in tally(fileURL: url, since: since, fallbackName: fallbackName) {
                totals[project, default: 0] += tokens
            }
        }

        let grand = totals.values.reduce(0, +)
        guard grand > 0 else { return [] }
        return totals
            .map { ProjectBurn(name: $0.key, tokens: $0.value, share: Double($0.value) / Double(grand)) }
            .sorted { $0.tokens > $1.tokens }
    }

    static func tally(fileURL: URL, since: Date, fallbackName: String) -> [String: Int] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return tally(data: data, since: since, fallbackName: fallbackName)
    }

    /// Tolerant line-by-line parse: a malformed line is skipped, never fatal.
    static func tally(data: Data, since: Date, fallbackName: String) -> [String: Int] {
        var totals: [String: Int] = [:]
        let iso = ISO8601DateFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in data.split(separator: 0x0A) {
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let tsRaw = obj["timestamp"] as? String,
                let ts = isoFractional.date(from: tsRaw) ?? iso.date(from: tsRaw),
                ts >= since,
                let message = obj["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any]
            else { continue }

            // Relative weight: in + out + cache writes. Cache reads are near-free and
            // would let one cache-heavy runner dwarf everything else.
            let tokens =
                intValue(usage["input_tokens"])
                + intValue(usage["output_tokens"])
                + intValue(usage["cache_creation_input_tokens"])
            guard tokens > 0 else { continue }

            let project = (obj["cwd"] as? String).map { ($0 as NSString).lastPathComponent }
                ?? fallbackName
            totals[project, default: 0] += tokens
        }
        return totals
    }

    static func intValue(_ any: Any?) -> Int {
        (any as? Int) ?? (any as? Double).map(Int.init) ?? 0
    }

    /// Project dirs are path-munged ("-Users-matyas-dev-cclimit"); the munge is lossy,
    /// so this is only the fallback when no cwd field is present in the transcript.
    static func prettify(directoryName: String) -> String {
        directoryName.split(separator: "-").last.map(String.init) ?? directoryName
    }
}
