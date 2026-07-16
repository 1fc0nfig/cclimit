import Foundation

/// Persists the last successful per-model reading from `/api/oauth/usage` so per-model rows
/// (e.g. Fable weekly) survive across launches and stay visible — clearly stamped as stale —
/// while that scarce, aggressively rate-limited endpoint is unavailable. Non-sensitive by
/// design: utilization numbers and reset timestamps only, never the token.
public final class PerModelStore: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let ts: Date
        public let snapshot: UsageSnapshot

        public init(ts: Date, snapshot: UsageSnapshot) {
            self.ts = ts
            self.snapshot = snapshot
        }
    }

    public let fileURL: URL
    private let queue = DispatchQueue(label: "cclimit.permodelstore")

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CClimit", isDirectory: true)
            self.fileURL = dir.appendingPathComponent("per-model.json")
        }
    }

    public func save(_ snapshot: UsageSnapshot, at ts: Date) {
        queue.sync {
            guard let data = try? UsageJSON.encoder().encode(Entry(ts: ts, snapshot: snapshot))
            else { return }
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    public func load() -> Entry? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? UsageJSON.decoder().decode(Entry.self, from: data)
        }
    }
}
