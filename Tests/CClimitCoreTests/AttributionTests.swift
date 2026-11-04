import XCTest

@testable import CClimitCore

final class AttributionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_770_000_000)

    func transcriptLine(minutesAgo: Double, cwd: String?, input: Int, output: Int, cacheCreate: Int = 0) -> String {
        let formatter = ISO8601DateFormatter()
        let ts = formatter.string(from: now.addingTimeInterval(-minutesAgo * 60))
        let cwdField = cwd.map { "\"cwd\": \"\($0)\"," } ?? ""
        return """
            {"timestamp": "\(ts)", \(cwdField) "message": {"usage": {"input_tokens": \(input), "output_tokens": \(output), "cache_creation_input_tokens": \(cacheCreate), "cache_read_input_tokens": 999999}}}
            """
    }

    func testTallyGroupsByCwdAndFiltersByTime() {
        let lines = [
            transcriptLine(minutesAgo: 10, cwd: "/Users/m/dev/alpha", input: 100, output: 50),
            transcriptLine(minutesAgo: 5, cwd: "/Users/m/dev/beta", input: 10, output: 5),
            transcriptLine(minutesAgo: 500, cwd: "/Users/m/dev/alpha", input: 9999, output: 9999),
        ].joined(separator: "\n")

        let totals = AttributionEngine.tally(
            data: Data(lines.utf8),
            since: now.addingTimeInterval(-3600),
            fallbackName: "fallback")

        XCTAssertEqual(totals["alpha"], 150)
        XCTAssertEqual(totals["beta"], 15)
    }

    func testCacheReadsAreNotCounted() {
        let line = transcriptLine(minutesAgo: 1, cwd: "/x/proj", input: 10, output: 10, cacheCreate: 5)
        let totals = AttributionEngine.tally(
            data: Data(line.utf8), since: now.addingTimeInterval(-3600), fallbackName: "f")
        XCTAssertEqual(totals["proj"], 25)
    }

    func testMalformedLinesAreSkipped() {
        let lines = [
            "not json at all",
            "{\"timestamp\": \"garbage\"}",
            transcriptLine(minutesAgo: 1, cwd: "/x/ok", input: 1, output: 1),
        ].joined(separator: "\n")
        let totals = AttributionEngine.tally(
            data: Data(lines.utf8), since: now.addingTimeInterval(-3600), fallbackName: "f")
        XCTAssertEqual(totals, ["ok": 2])
    }

    func testFallbackNameUsedWithoutCwd() {
        let line = transcriptLine(minutesAgo: 1, cwd: nil, input: 3, output: 4)
        let totals = AttributionEngine.tally(
            data: Data(line.utf8), since: now.addingTimeInterval(-3600), fallbackName: "cclimit")
        XCTAssertEqual(totals, ["cclimit": 7])
    }

    func testSharesSumToOneAndSortDescending() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-attr-\(UUID().uuidString)/-Users-m-dev-alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let lines = [
            transcriptLine(minutesAgo: 2, cwd: "/Users/m/dev/alpha", input: 300, output: 0),
            transcriptLine(minutesAgo: 1, cwd: "/Users/m/dev/beta", input: 100, output: 0),
        ].joined(separator: "\n")
        try Data(lines.utf8).write(to: dir.appendingPathComponent("session.jsonl"))

        let burns = AttributionEngine.burn(
            root: dir.deletingLastPathComponent(),
            since: now.addingTimeInterval(-3600),
            now: now)

        XCTAssertEqual(burns.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(burns.reduce(0) { $0 + $1.share }, 1.0, accuracy: 0.001)
        XCTAssertEqual(burns[0].share, 0.75, accuracy: 0.001)
    }
}

final class ProjectStatsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_770_000_000)

    func line(minutesAgo: Double, cwd: String, session: String = "s1", message: String, request: String = "r",
              model: String = "claude-opus-5-5", input: Int = 10, output: Int = 5, sidechain: Bool = false) -> String {
        let ts = ISO8601DateFormatter().string(from: now.addingTimeInterval(-minutesAgo * 60))
        return """
            {"type":"assistant","timestamp":"\(ts)","cwd":"\(cwd)","sessionId":"\(session)","requestId":"\(request)","isSidechain":\(sidechain),"message":{"id":"\(message)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output),"cache_creation_input_tokens":0}}}
            """
    }

    func testRepeatedContentBlocksCountOnce() {
        let data = Data([
            line(minutesAgo: 3, cwd: "/x/alpha", message: "m1"),
            line(minutesAgo: 3, cwd: "/x/alpha", message: "m1"),
            line(minutesAgo: 3, cwd: "/x/alpha", message: "m1"),
            line(minutesAgo: 2, cwd: "/x/alpha", message: "m2"),
        ].joined(separator: "\n").utf8)
        let totals = AttributionEngine.tally(data: data, since: now.addingTimeInterval(-3600), fallbackName: "f")
        XCTAssertEqual(totals["alpha"], 30)
    }

    func testWorktreeCountsTowardItsRepository() {
        let namer = AttributionEngine.ProjectNamer(checkDisk: false)
        XCTAssertEqual(namer.name(forCwd: "/Users/m/dev/mailnail/.claude/worktrees/agent-a1/apps/web"), "mailnail")
        XCTAssertEqual(namer.name(forCwd: "/Users/m/dev/cclimit"), "cclimit")
    }

    func testModelDisplayNames() {
        XCTAssertEqual(Format.modelName("claude-opus-5-5"), "Opus 5.5")
        XCTAssertEqual(Format.modelName("claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(Format.modelName("claude-fable-5-1"), "Fable 5.1")
    }

    func testReportBuildsSessionsModelsAndBuckets() throws {
        var seen = Set<String>()
        let data = Data([
            line(minutesAgo: 50, cwd: "/x/alpha", session: "a", message: "1"),
            line(minutesAgo: 10, cwd: "/x/alpha", session: "b", message: "2", model: "claude-haiku-4-5"),
            line(minutesAgo: 10, cwd: "/x/alpha", session: "b", message: "3", sidechain: true),
            line(minutesAgo: 5, cwd: "/x/beta", session: "c", message: "4"),
        ].joined(separator: "\n").utf8)
        let entries = AttributionEngine.parse(
            data: data, since: now.addingTimeInterval(-3600), fallbackName: "f", isSubagentFile: false,
            seen: &seen, namer: .init(checkDisk: false))
        let report = AttributionEngine.report(
            entries: entries, since: now.addingTimeInterval(-3600), now: now, bucketSize: 15 * 60)
        let alpha = try XCTUnwrap(report.projects.first)
        XCTAssertEqual(alpha.name, "alpha")
        XCTAssertEqual(alpha.tokens, 45)
        XCTAssertEqual(alpha.sessions, 2)
        XCTAssertEqual(alpha.subagentTokens, 15)
        XCTAssertEqual(alpha.models.first?.name, "Opus 5.5")
        XCTAssertEqual(report.buckets.count, 4)
        XCTAssertEqual(report.buckets.map(\.tokens).reduce(0, +), 60)
        XCTAssertEqual(report.buckets.last?.byProject["beta"], 15)
    }

    func testIndexReadsOnlyAppendedLines() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-index-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-x-alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = project.appendingPathComponent("s.jsonl")
        let realNow = Date()
        func entry(_ id: String) -> String {
            let ts = ISO8601DateFormatter().string(from: realNow.addingTimeInterval(-60))
            return """
                {"timestamp":"\(ts)","cwd":"/x/alpha","sessionId":"s","requestId":"r","message":{"id":"\(id)","usage":{"input_tokens":10,"output_tokens":0}}}
                """ + "\n"
        }
        try (entry("m1") + entry("m1")).write(to: file, atomically: true, encoding: .utf8)
        let index = TranscriptIndex(root: root, storeURL: root.appendingPathComponent("index.plist"))
        let since = realNow.addingTimeInterval(-3600)
        var report = await index.report(since: since, bucketSize: 3600)
        XCTAssertEqual(report.total, 10)

        // An appended repeat of m1 still counts once, and the new message counts.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((entry("m1") + entry("m2")).utf8))
        try handle.close()
        report = await index.report(since: since, bucketSize: 3600)
        XCTAssertEqual(report.total, 20)

        // A fresh index reads the saved state instead of starting from zero.
        let reloaded = TranscriptIndex(root: root, storeURL: root.appendingPathComponent("index.plist"))
        report = await reloaded.report(since: since, bucketSize: 3600)
        XCTAssertEqual(report.total, 20)
    }

    func testPastPageKeepsLaterLinesOut() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-index-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("-x-alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func entry(_ id: String, hoursAgo: Double) -> String {
            let ts = ISO8601DateFormatter().string(from: now.addingTimeInterval(-hoursAgo * 3600))
            return """
                {"timestamp":"\(ts)","cwd":"/x/alpha","sessionId":"s","requestId":"\(id)","message":{"id":"\(id)","usage":{"input_tokens":10,"output_tokens":0}}}
                """ + "\n"
        }
        try (entry("old", hoursAgo: 30) + entry("new", hoursAgo: 1))
            .write(to: project.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let index = TranscriptIndex(root: root, storeURL: nil)
        await index.warm(now: now)
        let since = now.addingTimeInterval(-48 * 3600)
        let until = now.addingTimeInterval(-24 * 3600)
        let report = await index.report(since: since, until: until, now: now, bucketSize: 3600)
        XCTAssertEqual(report.total, 10)
        XCTAssertEqual(report.buckets.count, 24, "a past page charts its whole span, not up to now")
    }
}

final class AttributionRangePageTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        return calendar
    }()

    func testTodayStepsBackByCalendarDay() {
        // 2026-10-26 10:00 in Prague; 25 Oct is the 25-hour DST day.
        let now = Date(timeIntervalSince1970: 1_793_005_200)
        let today = AttributionRange.today.interval(
            page: 0, now: now, fiveHourReset: nil, weeklyReset: nil, calendar: calendar)
        let yesterday = AttributionRange.today.interval(
            page: 1, now: now, fiveHourReset: nil, weeklyReset: nil, calendar: calendar)
        XCTAssertEqual(today.start, calendar.startOfDay(for: now))
        XCTAssertEqual(yesterday.end, today.start)
        XCTAssertEqual(yesterday.duration, 25 * 3600)
    }

    func testWeekEndsWithTodayAndStopsAtRetention() {
        let now = Date(timeIntervalSince1970: 1_793_005_200)
        let reset = now.addingTimeInterval(3 * 86400)
        let current = AttributionRange.week.interval(
            page: 0, now: now, fiveHourReset: nil, weeklyReset: reset, calendar: calendar)
        let previous = AttributionRange.week.interval(
            page: 1, now: now, fiveHourReset: nil, weeklyReset: reset, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        XCTAssertEqual(current.end, calendar.date(byAdding: .day, value: 1, to: today))
        XCTAssertEqual(current.start, calendar.date(byAdding: .day, value: -6, to: today))
        XCTAssertEqual(previous.end, current.start)
        XCTAssertTrue(AttributionRange.week.hasPage(3, now: now, fiveHourReset: nil, weeklyReset: reset))
        XCTAssertFalse(AttributionRange.week.hasPage(5, now: now, fiveHourReset: nil, weeklyReset: reset))
        XCTAssertTrue(AttributionRange.today.hasPage(30, now: now, fiveHourReset: nil, weeklyReset: nil))
        XCTAssertFalse(AttributionRange.today.hasPage(32, now: now, fiveHourReset: nil, weeklyReset: nil))
        XCTAssertFalse(AttributionRange.month.hasPage(1, now: now, fiveHourReset: nil, weeklyReset: nil))
    }
}

final class UsageReportMergeTests: XCTestCase {
    func testAddsSharedProjectsAndAlignsBars() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let a = UsageReport(
            since: t0, bucketSize: 3600,
            projects: [ProjectStats(name: "web", tokens: 300, share: 1, sessions: 2,
                                    models: [.init(name: "Opus", tokens: 300)])],
            buckets: [ActivityBucket(start: t0, tokens: 300, byProject: ["web": 300])])
        // Starts an hour later: its first bar must land in the second slot.
        let b = UsageReport(
            since: t0.addingTimeInterval(3600), bucketSize: 3600,
            projects: [ProjectStats(name: "web", tokens: 100, share: 0.5, sessions: 1,
                                    models: [.init(name: "Opus", tokens: 100)]),
                       ProjectStats(name: "api", tokens: 100, share: 0.5, sessions: 1)],
            buckets: [ActivityBucket(start: t0.addingTimeInterval(3600), tokens: 200,
                                     byProject: ["web": 100, "api": 100])])
        let merged = try XCTUnwrap(UsageReport.merge([a, b]))
        XCTAssertEqual(merged.since, t0)
        XCTAssertEqual(merged.projects.map(\.name), ["web", "api"])
        XCTAssertEqual(merged.projects[0].tokens, 400)
        XCTAssertEqual(merged.projects[0].sessions, 3)
        XCTAssertEqual(merged.projects[0].share, 0.8, accuracy: 0.0001)
        XCTAssertEqual(merged.projects[0].models.first?.tokens, 400)
        XCTAssertEqual(merged.total, 500)
        XCTAssertEqual(merged.buckets.map(\.tokens), [300, 200])
        XCTAssertEqual(merged.buckets[1].byProject["web"], 100)
    }

    func testSingleReportPassesThrough() {
        let r = UsageReport.empty(since: Date(), bucketSize: 60)
        XCTAssertEqual(UsageReport.merge([r]), r)
        XCTAssertNil(UsageReport.merge([]))
    }
}
