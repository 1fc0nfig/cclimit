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
