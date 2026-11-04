import XCTest
@testable import CClimitCore

final class PricingTests: XCTestCase {
    /// A real Opus 5.5 usage block from a proxy transcript (2026-11-04).
    let usage: [String: Any] = [
        "input_tokens": 2, "output_tokens": 776, "cache_read_input_tokens": 12466,
        "cache_creation_input_tokens": 12725,
        "cache_creation": ["ephemeral_1h_input_tokens": 12725, "ephemeral_5m_input_tokens": 0],
        "speed": "standard",
    ]

    func testReadsTheTTLSplit() {
        let counts = Pricing.Usage(json: usage)
        XCTAssertEqual(counts.cacheWrite1h, 12725)
        XCTAssertEqual(counts.cacheWrite5m, 0)
        XCTAssertEqual(counts.cacheRead, 12466)
        XCTAssertFalse(counts.fast)
    }

    func testOpusCostAtListPrice() {
        // 2×$4 + 776×$20 + 12466×$0.20 + 12725×$4×2, per million.
        let dollars: Double = 2.0 * 4 + 776.0 * 20 + 12466.0 * 0.2 + 12725.0 * 8
        let expected = dollars / 1_000_000
        XCTAssertEqual(Pricing.cost(model: "Opus 5.5", usage: Pricing.Usage(json: usage)), expected, accuracy: 1e-9)
    }

    func testWritesWithoutSplitCountAsFiveMinute() {
        let counts = Pricing.Usage(json: ["cache_creation_input_tokens": 1_000_000])
        XCTAssertEqual(Pricing.cost(model: "Sonnet 5.5", usage: counts), 2.5, accuracy: 1e-9)
    }

    func testUnknownModelCostsNothing() {
        XCTAssertEqual(Pricing.cost(model: "Gpt 5.6", usage: Pricing.Usage(input: 1_000_000)), 0)
        XCTAssertEqual(Pricing.cost(model: nil, usage: Pricing.Usage(input: 1_000_000)), 0)
    }

    func testFastModeDoublesOpus() {
        let fast = Pricing.Usage(output: 1_000_000, fast: true)
        XCTAssertEqual(Pricing.cost(model: "Opus 5.5", usage: fast), 40, accuracy: 1e-9)
    }

    func testHaikuLongPromptRate() {
        let short = Pricing.Usage(input: 100_000)
        let long = Pricing.Usage(input: 100_001)
        XCTAssertEqual(Pricing.cost(model: "Haiku 5.5", usage: short), 0.01, accuracy: 1e-9)
        XCTAssertEqual(Pricing.cost(model: "Haiku 5.5", usage: long), 100_001 * 0.5 / 1_000_000, accuracy: 1e-9)
    }

    func testEveryModelInTranscriptsHasAPrice() {
        for raw in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1", "claude-opus-4-8", "claude-opus-5"] {
            XCTAssertNotNil(Pricing.price(forModel: Format.modelName(raw)), raw)
        }
    }

    func testDollarFormat() {
        XCTAssertEqual(Format.dollars(0), "$0")
        XCTAssertEqual(Format.dollars(0.001), "<$0.01")
        XCTAssertEqual(Format.dollars(3.456), "$3.46")
        XCTAssertEqual(Format.dollars(69.69), "$70")
        XCTAssertEqual(Format.dollars(218.4), "$218")
        XCTAssertEqual(Format.dollars(3325.2), "$3,325")
        XCTAssertEqual(Format.dollars(12_345), "$12.3k")
    }

    func testCostFlowsIntoProjectsBucketsAndMerge() {
        let line = """
        {"timestamp":"2026-11-04T10:00:00Z","sessionId":"s","requestId":"r","cwd":"/tmp/demo","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":1000000}}}

        """
        var seen = Set<String>()
        let entries = AttributionEngine.parse(
            data: Data(line.utf8), since: .distantPast, fallbackName: "demo", isSubagentFile: false,
            seen: &seen, namer: AttributionEngine.ProjectNamer(checkDisk: false))
        // All from cache: no counted tokens, but it still costs $0.20.
        XCTAssertEqual(entries.count, 1)
        let since = ISO8601DateFormatter().date(from: "2026-11-04T09:00:00Z")!
        let report = AttributionEngine.report(
            entries: entries + [AttributionEngine.Entry(
                ts: since, project: "demo", input: 10, output: 0, cacheWrite: 0, cost: 1,
                model: "Opus 5.5", session: "s", isSubagent: false)],
            since: since, now: since.addingTimeInterval(7200), bucketSize: 3600)
        XCTAssertEqual(report.cost, 1.2, accuracy: 1e-9)
        XCTAssertEqual(report.projects.first?.cacheRead, 1_000_000)
        XCTAssertEqual(report.buckets.map(\.cost).reduce(0, +), 1.2, accuracy: 1e-9)
        let merged = UsageReport.merge([report, report])!
        XCTAssertEqual(merged.cost, 2.4, accuracy: 1e-9)
        XCTAssertEqual(merged.buckets.map(\.cost).reduce(0, +), 2.4, accuracy: 1e-9)
    }
}

final class ProxyDetectionTests: XCTestCase {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testFindsDirRoutedBySettings() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let dir = home.appendingPathComponent(".claude-cliproxy", isDirectory: true)
        try write(#"{"env":{"ANTHROPIC_BASE_URL":"http://100.94.42.52:8317","ANTHROPIC_AUTH_TOKEN":"x"}}"#,
                  to: dir.appendingPathComponent("settings.json"))
        try write(#"{"env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com"}}"#,
                  to: home.appendingPathComponent(".claude-work/settings.json"))
        let routes = ProxyDetection.routes(home: home)
        XCTAssertEqual(routes.map(\.configDir.lastPathComponent), [".claude-cliproxy"])
        XCTAssertEqual(routes.first?.baseURL.absoluteString, "http://100.94.42.52:8317")
        XCTAssertEqual(routes.first?.projectsDir.lastPathComponent, "projects")
    }

    func testShellExportReachesDirsWithTranscripts() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("export ANTHROPIC_BASE_URL=\"http://pi:8317\"\nalias w='CLAUDE_CONFIG_DIR=~/.claude-w ANTHROPIC_BASE_URL=http://other:1 claude'\n",
                  to: home.appendingPathComponent(".zshrc"))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        let routes = ProxyDetection.routes(home: home)
        XCTAssertEqual(routes.map(\.configDir.lastPathComponent), [".claude"])
        XCTAssertEqual(routes.first?.baseURL.host, "pi")
    }

    func testRecognizesCLIProxyRoot() {
        let root = Data(#"{"endpoints":["POST /v1/chat/completions"],"message":"CLI Proxy API Server"}"#.utf8)
        XCTAssertTrue(ProxyDetection.isCLIProxy(rootResponse: root))
        XCTAssertFalse(ProxyDetection.isCLIProxy(rootResponse: Data(#"{"message":"LiteLLM"}"#.utf8)))
        XCTAssertFalse(ProxyDetection.isCLIProxy(rootResponse: Data("<html>".utf8)))
    }
}

final class ReviewFixTests: XCTestCase {
    func testTokensRoundBeforePickingUnit() {
        XCTAssertEqual(Format.tokens(999), "999")
        XCTAssertEqual(Format.tokens(9_940), "9.9k")
        XCTAssertEqual(Format.tokens(9_960), "10k")
        XCTAssertEqual(Format.tokens(999_600), "1.0M")
        XCTAssertEqual(Format.tokens(173_000_000), "173M")
        XCTAssertEqual(Format.tokens(2_400_000_000), "2.4B")
    }

    func testRollingRangesKeepTheirStartWithinAMinute() {
        let now = Date()
        for range in [AttributionRange.month, .window] {
            let a = range.start(now: now, fiveHourReset: nil, weeklyReset: nil)
            let b = range.start(now: now.addingTimeInterval(61), fiveHourReset: nil, weeklyReset: nil)
            // A start that moves every minute would never find its cached report again.
            if Int(now.timeIntervalSince1970) % 900 < 800 { XCTAssertEqual(a, b, "\(range)") }
        }
        let month = AttributionRange.month.start(now: now, fiveHourReset: nil, weeklyReset: nil)
        XCTAssertGreaterThan(month, now.addingTimeInterval(-TranscriptIndex.retention))
    }

    func testShownRangeFallsBackToToday() {
        XCTAssertEqual(AttributionRange.shown(stored: "window", hasFiveHour: false), .today)
        XCTAssertEqual(AttributionRange.shown(stored: "window", hasFiveHour: true), .window)
        XCTAssertEqual(AttributionRange.shown(stored: nil, hasFiveHour: true), .window)
        XCTAssertEqual(AttributionRange.shown(stored: "week", hasFiveHour: false), .week)
    }

    func testKeyQuotingForSecurityStdin() {
        XCTAssertEqual(ProxyKeyStore.quoted(#"a b"c\d'e"#), #""a b\"c\\d'e""#)
    }

    func testChildProcessFeedsStdin() throws {
        let result = try ChildProcess.run(
            URL(fileURLWithPath: "/bin/cat"), arguments: [], input: Data("hello\n".utf8), timeout: 5)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "hello\n")
    }
}
