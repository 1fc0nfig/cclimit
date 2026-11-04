import Foundation

/// The moat (v1.0): attribute burn to projects/sessions by reading Claude Code's local
/// transcripts (<config dir>/projects/**/*.jsonl). Local token counts diverge from server
/// truth for absolute limits (product.md §3 Option D) — so this computes RELATIVE shares
/// and API-price estimates, and never feeds the gauges.
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

/// How far back the project breakdown looks. The 5-hour window answers "what is eating
/// this window"; the longer ranges answer "where do my tokens go".
public enum AttributionRange: String, CaseIterable, Identifiable, Sendable {
    case window
    case today
    case week
    case month

    public var id: String { rawValue }

    /// Width of one bar in the activity chart: about 20–30 bars for every range.
    public var bucketSize: TimeInterval {
        switch self {
        case .window: return 15 * 60
        case .today: return 3600
        case .week: return 6 * 3600
        case .month: return 86400
        }
    }

    public var label: String {
        switch self {
        case .window: return "This 5-hour window"
        case .today: return "Today"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        }
    }

    /// Lowercase, for the popover header: "Projects · this window".
    public var shortLabel: String {
        switch self {
        case .window: return "this window"
        case .today: return "today"
        case .week: return "7 days"
        case .month: return "30 days"
        }
    }

    /// The start of the range. The last 7 days are calendar days that end with today, so
    /// today is the last bar of the chart. A start never moves with the clock: reports are
    /// cached by it, and a start that slid every minute would never find its report again.
    public func start(
        now: Date, fiveHourReset: Date?, weeklyReset: Date?, calendar: Calendar = .current
    ) -> Date {
        switch self {
        case .window:
            if let fiveHourReset { return fiveHourReset.addingTimeInterval(-5 * 3600) }
            // No reset known: the last five hours, on the 15-minute grid of the index.
            let quarter: TimeInterval = 15 * 60
            return Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - 5 * 3600) / quarter).rounded(.down) * quarter)
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -6, to: today) ?? today.addingTimeInterval(-6 * 86400)
        case .month:
            // 30 whole days before today, then today.
            let today = calendar.startOfDay(for: now)
            return calendar.date(byAdding: .day, value: -29, to: today) ?? today.addingTimeInterval(-29 * 86400)
        }
    }

    /// The range a view shows: the stored choice, except that "This 5-hour window" reads as
    /// Today when no shown account has the window (Ultra).
    public static func shown(stored raw: String?, hasFiveHour: Bool) -> AttributionRange {
        let stored = raw.flatMap(AttributionRange.init(rawValue:)) ?? .window
        return stored == .window && !hasFiveHour ? .today : stored
    }

    /// Today steps back by day, the last 7 days by 7 days. The 5-hour window and the
    /// rolling 30 days have no earlier page.
    public var pages: Bool { self == .today || self == .week }

    /// The span of a page: page 0 is the current range, page 1 the one before it. The end
    /// can lie in the future for page 0: the chart shows the rest of the day empty.
    public func interval(
        page: Int, now: Date, fiveHourReset: Date?, weeklyReset: Date?, calendar: Calendar = .current
    ) -> DateInterval {
        let current = start(now: now, fiveHourReset: fiveHourReset, weeklyReset: weeklyReset, calendar: calendar)
        let page = pages ? max(page, 0) : 0
        switch self {
        case .window:
            return DateInterval(start: current, end: current.addingTimeInterval(5 * 3600))
        case .today:
            let day = calendar.date(byAdding: .day, value: -page, to: current) ?? current
            let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
            return DateInterval(start: day, end: next)
        case .week:
            let begin = calendar.date(byAdding: .day, value: -7 * page, to: current) ?? current
            let end = calendar.date(byAdding: .day, value: 7, to: begin) ?? begin.addingTimeInterval(7 * 86400)
            return DateInterval(start: begin, end: end)
        case .month:
            return DateInterval(start: current, end: max(now, current))
        }
    }

    /// True when the index still holds the page: it keeps the last 31 days.
    public func hasPage(
        _ page: Int, now: Date, fiveHourReset: Date?, weeklyReset: Date?, calendar: Calendar = .current
    ) -> Bool {
        guard page >= 0, pages || page == 0 else { return false }
        let span = interval(page: page, now: now, fiveHourReset: fiveHourReset, weeklyReset: weeklyReset, calendar: calendar)
        return span.end > now.addingTimeInterval(-TranscriptIndex.retention)
    }
}

/// One project's slice of a range: how much, where it went, and how it was spent.
public struct ProjectStats: Identifiable, Equatable, Sendable {
    public struct ModelTokens: Equatable, Sendable {
        public let name: String
        public let tokens: Int

        public init(name: String, tokens: Int) {
            self.name = name
            self.tokens = tokens
        }
    }

    public let name: String
    public let tokens: Int
    public let share: Double
    public let input: Int
    public let output: Int
    public let cacheWrite: Int
    /// Not part of `tokens`: cache reads are near free, and would swamp the rest. They do
    /// count toward `cost`.
    public let cacheRead: Int
    /// US dollars at API list price (`Pricing`). The value of the work, not a bill.
    public let cost: Double
    public let sessions: Int
    /// Tokens spent by subagents (sidechain transcripts) inside this project.
    public let subagentTokens: Int
    /// Heaviest first, display names ("Opus 5.5").
    public let models: [ModelTokens]
    public let lastActive: Date?

    public var id: String { name }
    public var subagentShare: Double { tokens > 0 ? Double(subagentTokens) / Double(tokens) : 0 }

    public init(
        name: String, tokens: Int, share: Double, input: Int = 0, output: Int = 0, cacheWrite: Int = 0,
        cacheRead: Int = 0, cost: Double = 0, sessions: Int = 0, subagentTokens: Int = 0,
        models: [ModelTokens] = [], lastActive: Date? = nil
    ) {
        self.name = name
        self.tokens = tokens
        self.share = share
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.cost = cost
        self.sessions = sessions
        self.subagentTokens = subagentTokens
        self.models = models
        self.lastActive = lastActive
    }
}

/// One bar of the activity chart.
public struct ActivityBucket: Identifiable, Equatable, Sendable {
    public let start: Date
    public let tokens: Int
    public let byProject: [String: Int]
    /// US dollars at list price, in total and per project.
    public let cost: Double
    public let costByProject: [String: Double]

    public var id: Date { start }

    public init(
        start: Date, tokens: Int, byProject: [String: Int], cost: Double = 0,
        costByProject: [String: Double] = [:]
    ) {
        self.start = start
        self.tokens = tokens
        self.byProject = byProject
        self.cost = cost
        self.costByProject = costByProject
    }
}

public struct UsageReport: Equatable, Sendable {
    public let since: Date
    public let bucketSize: TimeInterval
    public let projects: [ProjectStats]
    public let buckets: [ActivityBucket]

    public init(since: Date, bucketSize: TimeInterval, projects: [ProjectStats], buckets: [ActivityBucket]) {
        self.since = since
        self.bucketSize = bucketSize
        self.projects = projects
        self.buckets = buckets
    }

    public var total: Int { projects.reduce(0) { $0 + $1.tokens } }
    public var sessions: Int { projects.reduce(0) { $0 + $1.sessions } }
    public var cost: Double { projects.reduce(0) { $0 + $1.cost } }

    public static func empty(since: Date, bucketSize: TimeInterval) -> UsageReport {
        UsageReport(since: since, bucketSize: bucketSize, projects: [], buckets: [])
    }

    /// Several accounts' reports as one, for the "All" view. A project that two accounts
    /// worked on adds up. Ranges can start at different times (each account's own 5-hour or
    /// weekly window), so the bars go onto one grid from the earliest start.
    public static func merge(_ reports: [UsageReport]) -> UsageReport? {
        guard let first = reports.first else { return nil }
        guard reports.count > 1 else { return first }
        let since = reports.map(\.since).min() ?? first.since
        let size = first.bucketSize

        var byName: [String: [ProjectStats]] = [:]
        for project in reports.flatMap(\.projects) { byName[project.name, default: []].append(project) }
        let grand = byName.values.flatMap { $0 }.reduce(0) { $0 + $1.tokens }
        let projects = byName.map { name, parts -> ProjectStats in
            let tokens = parts.reduce(0) { $0 + $1.tokens }
            var models: [String: Int] = [:]
            for model in parts.flatMap(\.models) { models[model.name, default: 0] += model.tokens }
            return ProjectStats(
                name: name, tokens: tokens,
                share: grand > 0 ? Double(tokens) / Double(grand) : 0,
                input: parts.reduce(0) { $0 + $1.input },
                output: parts.reduce(0) { $0 + $1.output },
                cacheWrite: parts.reduce(0) { $0 + $1.cacheWrite },
                cacheRead: parts.reduce(0) { $0 + $1.cacheRead },
                cost: parts.reduce(0) { $0 + $1.cost },
                sessions: parts.reduce(0) { $0 + $1.sessions },
                subagentTokens: parts.reduce(0) { $0 + $1.subagentTokens },
                models: models.map { ProjectStats.ModelTokens(name: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens },
                lastActive: parts.compactMap(\.lastActive).max())
        }
        .sorted { $0.tokens > $1.tokens }

        let end = reports.compactMap { $0.buckets.last.map { $0.start.addingTimeInterval(size) } }.max() ?? since
        let count = max(1, Int((end.timeIntervalSince(since) / size).rounded(.up)))
        var grid = Array(repeating: [String: Int](), count: count)
        var costs = Array(repeating: [String: Double](), count: count)
        for bucket in reports.flatMap(\.buckets) {
            let index = min(max(Int((bucket.start.timeIntervalSince(since) / size).rounded(.down)), 0), count - 1)
            for (project, tokens) in bucket.byProject { grid[index][project, default: 0] += tokens }
            for (project, cost) in bucket.costByProject { costs[index][project, default: 0] += cost }
        }
        let buckets = grid.enumerated().map { index, map in
            ActivityBucket(
                start: since.addingTimeInterval(Double(index) * size),
                tokens: map.values.reduce(0, +), byProject: map,
                cost: costs[index].values.reduce(0, +), costByProject: costs[index])
        }
        return UsageReport(since: since, bucketSize: size, projects: projects, buckets: buckets)
    }
}

public enum AttributionEngine {
    public static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// One counted API response.
    struct Entry: Sendable {
        let ts: Date
        let project: String
        let input: Int
        let output: Int
        let cacheWrite: Int
        var cacheRead: Int = 0
        /// US dollars at list price (`Pricing`).
        var cost: Double = 0
        let model: String?
        let session: String?
        let isSubagent: Bool
        /// Latest response folded into this entry, when it stands for several (index slices).
        var last: Date? = nil

        init(
            ts: Date, project: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int = 0,
            cost: Double = 0, model: String?, session: String?, isSubagent: Bool, last: Date? = nil
        ) {
            self.ts = ts
            self.project = project
            self.input = input
            self.output = output
            self.cacheWrite = cacheWrite
            self.cacheRead = cacheRead
            self.cost = cost
            self.model = model
            self.session = session
            self.isSubagent = isSubagent
            self.last = last
        }

        /// Relative weight: in + out + cache writes. Cache reads are near-free and would let
        /// one cache-heavy runner dwarf everything else.
        var tokens: Int { input + output + cacheWrite }
    }

    /// The full breakdown since `since`: per-project stats plus a bucketed timeline.
    public static func report(
        root: URL = defaultRoot(), since: Date, now: Date = Date(), bucketSize: TimeInterval
    ) -> UsageReport {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return .empty(since: since, bucketSize: bucketSize) }

        var entries: [Entry] = []
        let namer = ProjectNamer()
        // Claude Code writes the same response once per content block, each copy with the
        // full usage. Without this the counts run about 3x high.
        var seen = Set<String>()
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            // Skip transcripts untouched since the range started — cheap and correct.
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate, modified < since {
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            // <project>/<session>.jsonl, or <project>/<session>/subagents/agent-*.jsonl.
            let isSubagent = url.deletingLastPathComponent().lastPathComponent == "subagents"
            let projectDir = isSubagent
                ? url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                : url.deletingLastPathComponent()
            entries += parse(
                data: data, since: since, fallbackName: prettify(directoryName: projectDir.lastPathComponent),
                isSubagentFile: isSubagent, seen: &seen, namer: namer)
        }
        return report(entries: entries, since: since, now: now, bucketSize: bucketSize)
    }

    static func report(entries: [Entry], since: Date, now: Date, bucketSize: TimeInterval) -> UsageReport {
        let grand = entries.reduce(0) { $0 + $1.tokens }
        guard grand > 0 else { return .empty(since: since, bucketSize: bucketSize) }

        let projects = Dictionary(grouping: entries, by: \.project).map { name, items -> ProjectStats in
            let tokens = items.reduce(0) { $0 + $1.tokens }
            let byModel = Dictionary(grouping: items.filter { $0.model != nil }, by: { $0.model! })
                .mapValues { $0.reduce(0) { $0 + $1.tokens } }
            return ProjectStats(
                name: name,
                tokens: tokens,
                share: Double(tokens) / Double(grand),
                input: items.reduce(0) { $0 + $1.input },
                output: items.reduce(0) { $0 + $1.output },
                cacheWrite: items.reduce(0) { $0 + $1.cacheWrite },
                cacheRead: items.reduce(0) { $0 + $1.cacheRead },
                cost: items.reduce(0) { $0 + $1.cost },
                sessions: Set(items.compactMap(\.session)).count,
                subagentTokens: items.filter(\.isSubagent).reduce(0) { $0 + $1.tokens },
                models: byModel.map { ProjectStats.ModelTokens(name: $0.key, tokens: $0.value) }
                    .sorted { $0.tokens > $1.tokens },
                lastActive: items.map { $0.last ?? $0.ts }.max())
        }
        .sorted { $0.tokens > $1.tokens }

        let count = max(1, Int((now.timeIntervalSince(since) / bucketSize).rounded(.up)))
        var byBucket = Array(repeating: [String: Int](), count: count)
        var costs = Array(repeating: [String: Double](), count: count)
        for entry in entries {
            let index = min(max(Int(entry.ts.timeIntervalSince(since) / bucketSize), 0), count - 1)
            byBucket[index][entry.project, default: 0] += entry.tokens
            if entry.cost > 0 { costs[index][entry.project, default: 0] += entry.cost }
        }
        let buckets = byBucket.enumerated().map { index, map in
            ActivityBucket(
                start: since.addingTimeInterval(Double(index) * bucketSize),
                tokens: map.values.reduce(0, +),
                byProject: map,
                cost: costs[index].values.reduce(0, +),
                costByProject: costs[index])
        }
        return UsageReport(since: since, bucketSize: bucketSize, projects: projects, buckets: buckets)
    }

    /// Relative burn per project since `since` (typically the current 5h window start).
    public static func burn(root: URL = defaultRoot(), since: Date, now: Date = Date()) -> [ProjectBurn] {
        report(root: root, since: since, now: now, bucketSize: 3600).projects
            .map { ProjectBurn(name: $0.name, tokens: $0.tokens, share: $0.share) }
    }

    static func tally(fileURL: URL, since: Date, fallbackName: String) -> [String: Int] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return tally(data: data, since: since, fallbackName: fallbackName)
    }

    static func tally(data: Data, since: Date, fallbackName: String) -> [String: Int] {
        var seen = Set<String>()
        var totals: [String: Int] = [:]
        for entry in parse(
            data: data, since: since, fallbackName: fallbackName, isSubagentFile: false, seen: &seen,
            namer: ProjectNamer(checkDisk: false)) {
            totals[entry.project, default: 0] += entry.tokens
        }
        return totals
    }

    private static let usageMarker = Data("\"usage\"".utf8)

    /// Tolerant line-by-line parse: a malformed line is skipped, never fatal.
    static func parse(
        data: Data, since: Date, fallbackName: String, isSubagentFile: Bool, seen: inout Set<String>,
        namer: ProjectNamer
    ) -> [Entry] {
        var keys: [String] = []
        return parse(
            data: data, since: since, fallbackName: fallbackName, isSubagentFile: isSubagentFile,
            seen: &seen, namer: namer, keys: &keys)
    }

    /// `keys` collects the message keys counted, so an index can carry them across refreshes.
    static func parse(
        data: Data, since: Date, fallbackName: String, isSubagentFile: Bool, seen: inout Set<String>,
        namer: ProjectNamer, keys: inout [String]
    ) -> [Entry] {
        var entries: [Entry] = []
        let iso = ISO8601DateFormatter()
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in data.split(separator: 0x0A) {
            // Most lines are prompts and tool output: skip them before paying for JSON.
            guard line.range(of: usageMarker) != nil else { continue }
            guard
                let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let tsRaw = obj["timestamp"] as? String,
                let ts = isoFractional.date(from: tsRaw) ?? iso.date(from: tsRaw),
                ts >= since,
                let message = obj["message"] as? [String: Any],
                let usage = message["usage"] as? [String: Any]
            else { continue }

            let model = message["model"] as? String
            if model == "<synthetic>" { continue }
            let session = obj["sessionId"] as? String
            if let messageID = message["id"] as? String {
                let key = "\(session ?? "")|\(messageID)|\(obj["requestId"] as? String ?? "")"
                guard seen.insert(key).inserted else { continue }
                keys.append(key)
            }

            let counts = Pricing.Usage(json: usage)
            let modelName = model.map(Format.modelName)
            let entry = Entry(
                ts: ts,
                project: (obj["cwd"] as? String).map(namer.name(forCwd:)) ?? fallbackName,
                input: counts.input,
                output: counts.output,
                cacheWrite: counts.cacheWrite,
                cacheRead: counts.cacheRead,
                cost: Pricing.cost(model: modelName, usage: counts),
                model: modelName,
                session: session,
                isSubagent: isSubagentFile || (obj["isSidechain"] as? Bool ?? false))
            // A response served all from cache still costs: keep it for the price.
            guard entry.tokens > 0 || entry.cacheRead > 0 else { continue }
            entries.append(entry)
        }
        return entries
    }

    /// Names a project after its repository, not the folder Claude Code ran in. A session in
    /// `mailnail/apps/web` or in the agent worktree `mailnail/.claude/worktrees/agent-…`
    /// counts toward "mailnail". Cached, because every line of a transcript asks.
    final class ProjectNamer {
        private var cache: [String: String] = [:]
        private let checkDisk: Bool
        private let fm = FileManager.default

        init(checkDisk: Bool = true) {
            self.checkDisk = checkDisk
        }

        func name(forCwd cwd: String) -> String {
            if let hit = cache[cwd] { return hit }
            let name = resolve(cwd)
            cache[cwd] = name
            return name
        }

        private func resolve(_ cwd: String) -> String {
            for marker in ["/.claude/worktrees/", "/.worktrees/"] {
                if let range = cwd.range(of: marker) {
                    return (String(cwd[..<range.lowerBound]) as NSString).lastPathComponent
                }
            }
            var dir = URL(fileURLWithPath: cwd)
            if checkDisk {
                // Walk up to the git root, no further than the home folder.
                let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
                var probe = dir
                for _ in 0..<8 {
                    if fm.fileExists(atPath: probe.appendingPathComponent(".git").path) {
                        dir = probe
                        break
                    }
                    let parent = probe.deletingLastPathComponent()
                    if parent.path == probe.path || parent.standardizedFileURL.path == home { break }
                    probe = parent
                }
            }
            let name = dir.lastPathComponent
            return name.isEmpty ? cwd : name
        }
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
