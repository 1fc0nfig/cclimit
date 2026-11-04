import Foundation

/// A persistent index of Claude Code transcripts, so project stats over 30 days do not mean
/// re-reading gigabytes. Transcripts are append-only JSONL: per file the index keeps the byte
/// offset it has read up to, and on a refresh it parses only what was appended. Responses
/// fold into 15-minute slices per project, model, session and subagent flag.
public actor TranscriptIndex {
    /// Lines older than this are not indexed. The longest range is 30 days.
    public static let retention: TimeInterval = 31 * 86400
    static let sliceSize: TimeInterval = 15 * 60

    struct Slice: Codable, Hashable {
        var start: Int          // unix seconds, multiple of sliceSize
        var project: String
        var model: String?
        var session: String?
        var sub: Bool
        var input: Int
        var output: Int
        var cache: Int
        var read: Int
        /// US dollars at list price, summed over the slice's responses.
        var cost: Double
        var last: Int

        struct Key: Hashable {
            let start: Int, project: String, model: String?, session: String?, sub: Bool
        }
        var key: Key { Key(start: start, project: project, model: model, session: session, sub: sub) }
    }

    struct FileState: Codable {
        var size: UInt64
        var offset: UInt64
        /// The last message keys seen, to drop the per-content-block repeats across a refresh.
        var recentKeys: [String]
        var slices: [Slice]
    }

    struct Store: Codable {
        /// 2: cache reads and list-price cost per slice. A bump re-indexes from scratch.
        var version = 2
        var files: [String: FileState] = [:]
    }

    /// The `projects` folders to read: one per login, or several for the CLI proxy pool.
    let roots: [URL]
    private let storeURL: URL?
    private var store = Store()
    private var loaded = false

    public init(root: URL, storeURL: URL?) {
        self.init(roots: [root], storeURL: storeURL)
    }

    public init(roots: [URL], storeURL: URL?) {
        self.roots = roots
        self.storeURL = storeURL
    }

    /// Brings every transcript changed since `since` up to date, then aggregates the range.
    /// `until` closes a past page: lines after it stay out, and the chart ends there.
    public func report(
        since: Date, until: Date? = nil, now: Date = Date(), bucketSize: TimeInterval
    ) -> UsageReport {
        loadIfNeeded()
        let changed = update(modifiedSince: since, now: now)
        if changed { save() }
        let floor = Int((since.timeIntervalSince1970 / Self.sliceSize).rounded(.down) * Self.sliceSize)
        let ceiling = until.map { Int($0.timeIntervalSince1970) } ?? Int.max
        var entries: [AttributionEngine.Entry] = []
        for state in store.files.values {
            for slice in state.slices where slice.start >= floor && slice.start < ceiling {
                entries.append(AttributionEngine.Entry(
                    ts: Date(timeIntervalSince1970: TimeInterval(slice.start)),
                    project: slice.project, input: slice.input, output: slice.output,
                    cacheWrite: slice.cache, cacheRead: slice.read, cost: slice.cost,
                    model: slice.model, session: slice.session,
                    isSubagent: slice.sub, last: Date(timeIntervalSince1970: TimeInterval(slice.last))))
            }
        }
        let end = until.map { min($0, now) } ?? now
        return AttributionEngine.report(entries: entries, since: since, now: end, bucketSize: bucketSize)
    }

    /// Loads the store and indexes the full retention, so the first range the user opens
    /// only aggregates. Call it once at launch, off the main actor.
    public func warm(now: Date = Date()) {
        loadIfNeeded()
        if update(modifiedSince: now.addingTimeInterval(-Self.retention), now: now) { save() }
    }

    /// Returns true when the index changed.
    private func update(modifiedSince since: Date, now: Date) -> Bool {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Self.retention)
        let files = roots.lazy.compactMap {
            fm.enumerator(
                at: $0, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])
        }.flatMap { $0 }

        var changed = false
        let namer = AttributionEngine.ProjectNamer()
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                let modified = values.contentModificationDate, modified >= since,
                let size = values.fileSize.map(UInt64.init)
            else { continue }
            let path = url.path
            var state = store.files[path] ?? FileState(size: 0, offset: 0, recentKeys: [], slices: [])
            if state.size == size && state.offset > 0 { continue }
            if size < state.offset {
                // Rewritten, not appended: start over.
                state = FileState(size: 0, offset: 0, recentKeys: [], slices: [])
            }
            parse(url: url, state: &state, size: size, cutoff: cutoff, namer: namer)
            store.files[path] = state
            changed = true
        }

        // Drop slices past retention, and files that are gone or fully expired.
        let oldest = Int(cutoff.timeIntervalSince1970)
        for (path, var state) in store.files {
            let before = state.slices.count
            state.slices.removeAll { $0.start < oldest }
            if state.slices.isEmpty && !fm.fileExists(atPath: path) {
                store.files[path] = nil
                changed = true
            } else if state.slices.count != before {
                store.files[path] = state
                changed = true
            }
        }
        return changed
    }

    private func parse(
        url: URL, state: inout FileState, size: UInt64, cutoff: Date, namer: AttributionEngine.ProjectNamer
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            state.size = size
            return
        }
        // Only whole lines: an active session may be mid-write on the last one.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return }
        let complete = data[data.startIndex...lastNewline]

        let isSubagent = url.deletingLastPathComponent().lastPathComponent == "subagents"
        let projectDir = isSubagent
            ? url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            : url.deletingLastPathComponent()
        var seen = Set(state.recentKeys)
        var keys: [String] = []
        let entries = AttributionEngine.parse(
            data: Data(complete), since: cutoff,
            fallbackName: AttributionEngine.prettify(directoryName: projectDir.lastPathComponent),
            isSubagentFile: isSubagent, seen: &seen, namer: namer, keys: &keys)

        var byKey: [Slice.Key: Int] = [:]
        for (index, slice) in state.slices.enumerated() { byKey[slice.key] = index }
        for entry in entries {
            let start = Int((entry.ts.timeIntervalSince1970 / Self.sliceSize).rounded(.down) * Self.sliceSize)
            let ts = Int(entry.ts.timeIntervalSince1970)
            let key = Slice.Key(
                start: start, project: entry.project, model: entry.model, session: entry.session,
                sub: entry.isSubagent)
            if let index = byKey[key] {
                state.slices[index].input += entry.input
                state.slices[index].output += entry.output
                state.slices[index].cache += entry.cacheWrite
                state.slices[index].read += entry.cacheRead
                state.slices[index].cost += entry.cost
                state.slices[index].last = max(state.slices[index].last, ts)
            } else {
                byKey[key] = state.slices.count
                state.slices.append(Slice(
                    start: start, project: entry.project, model: entry.model, session: entry.session,
                    sub: entry.isSubagent, input: entry.input, output: entry.output,
                    cache: entry.cacheWrite, read: entry.cacheRead, cost: entry.cost, last: ts))
            }
        }
        state.recentKeys = Array((state.recentKeys + keys).suffix(200))
        state.offset += UInt64(complete.count)
        state.size = size
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let decoded = try? PropertyListDecoder().decode(Store.self, from: data),
              decoded.version == Store().version
        else { return }
        store = decoded
    }

    private func save() {
        guard let storeURL else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(store) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }
}
