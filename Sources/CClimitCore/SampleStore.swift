import Foundation

/// A per-model window snapshot inside a Sample (e.g. Fable weekly). Recording these is
/// what lets the forecast reason about the model you're actually burning, not just the
/// aggregate windows.
public struct ModelSample: Codable, Equatable, Sendable {
    public let name: String
    public let util: Double?
    public let reset: Date?

    enum CodingKeys: String, CodingKey {
        case name = "n"
        case util = "u"
        case reset = "r"
    }

    public init(name: String, util: Double?, reset: Date?) {
        self.name = name
        self.util = util
        self.reset = reset
    }
}

/// One persisted poll result. Non-sensitive by design: utilization numbers and reset
/// timestamps only — never tokens. This history feeds the forecast and is the raw
/// material for anything statistical later.
public struct Sample: Codable, Equatable, Sendable {
    public let ts: Date
    public let fiveHourUtil: Double?
    public let fiveHourReset: Date?
    public let sevenDayUtil: Double?
    public let sevenDayReset: Date?
    public let models: [ModelSample]?

    enum CodingKeys: String, CodingKey {
        case ts
        case fiveHourUtil = "five_hour_util"
        case fiveHourReset = "five_hour_reset"
        case sevenDayUtil = "seven_day_util"
        case sevenDayReset = "seven_day_reset"
        case models
    }

    public init(
        ts: Date,
        fiveHourUtil: Double?,
        fiveHourReset: Date?,
        sevenDayUtil: Double?,
        sevenDayReset: Date?,
        models: [ModelSample]? = nil
    ) {
        self.ts = ts
        self.fiveHourUtil = fiveHourUtil
        self.fiveHourReset = fiveHourReset
        self.sevenDayUtil = sevenDayUtil
        self.sevenDayReset = sevenDayReset
        self.models = models
    }

    public init(ts: Date, snapshot: UsageSnapshot) {
        let models = snapshot.perModelWindows.map {
            ModelSample(name: $0.name, util: $0.window.utilization, reset: $0.window.resetsAt)
        }
        self.init(
            ts: ts,
            fiveHourUtil: snapshot.fiveHour?.utilization,
            fiveHourReset: snapshot.fiveHour?.resetsAt,
            sevenDayUtil: snapshot.sevenDay?.utilization,
            sevenDayReset: snapshot.sevenDay?.resetsAt,
            models: models.isEmpty ? nil : models
        )
    }

    /// Utilization for a named per-model window in this sample, if present.
    public func modelUtil(_ name: String) -> Double? {
        models?.first { $0.name == name }?.util
    }

    public func modelReset(_ name: String) -> Date? {
        models?.first { $0.name == name }?.reset
    }
}

/// Append-only JSONL store under Application Support. Tolerant on read: a corrupt
/// line is skipped, never fatal.
public final class SampleStore: @unchecked Sendable {
    public let fileURL: URL
    private let queue = DispatchQueue(label: "cclimit.samplestore")
    private let maxLoadBytes = 4 * 1024 * 1024

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CClimit", isDirectory: true)
            self.fileURL = dir.appendingPathComponent("samples.jsonl")
        }
    }

    public func append(_ sample: Sample) {
        queue.sync {
            guard let data = try? UsageJSON.encoder().encode(sample) else { return }
            var line = data
            line.append(0x0A)
            let fm = FileManager.default
            try? fm.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL)
            }
        }
    }

    /// Samples newer than `since`, oldest first. Reads only the tail of large files.
    public func load(since: Date) -> [Sample] {
        queue.sync {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size > UInt64(maxLoadBytes) {
                try? handle.seek(toOffset: size - UInt64(maxLoadBytes))
            } else {
                try? handle.seek(toOffset: 0)
            }
            guard let data = try? handle.readToEnd() else { return [] }
            let decoder = UsageJSON.decoder()
            return data.split(separator: 0x0A)
                .compactMap { try? decoder.decode(Sample.self, from: Data($0)) }
                .filter { $0.ts >= since }
                .sorted { $0.ts < $1.ts }
        }
    }
}
