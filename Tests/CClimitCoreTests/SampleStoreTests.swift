import XCTest

@testable import CClimitCore

final class SampleStoreTests: XCTestCase {
    var fileURL: URL!

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-samples-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testAppendAndLoadRoundtrip() {
        let store = SampleStore(fileURL: fileURL)
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        for i in 0..<5 {
            store.append(
                Sample(
                    ts: base.addingTimeInterval(Double(i) * 60),
                    fiveHourUtil: Double(i) * 10,
                    fiveHourReset: base.addingTimeInterval(3600),
                    sevenDayUtil: 5,
                    sevenDayReset: nil))
        }
        let all = store.load(since: .distantPast)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all.first?.fiveHourUtil, 0)
        XCTAssertEqual(all.last?.fiveHourUtil, 40)

        let recent = store.load(since: base.addingTimeInterval(150))
        XCTAssertEqual(recent.count, 2)
    }

    func testCorruptLinesAreSkipped() throws {
        let store = SampleStore(fileURL: fileURL)
        store.append(Sample(ts: Date(), fiveHourUtil: 1, fiveHourReset: nil, sevenDayUtil: nil, sevenDayReset: nil))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("garbage line\n".utf8))
        try handle.close()
        store.append(Sample(ts: Date(), fiveHourUtil: 2, fiveHourReset: nil, sevenDayUtil: nil, sevenDayReset: nil))

        XCTAssertEqual(store.load(since: .distantPast).count, 2)
    }

    func testMissingFileLoadsEmpty() {
        let store = SampleStore(fileURL: fileURL)
        XCTAssertEqual(store.load(since: .distantPast), [])
    }

    func testPerModelSamplesRoundtrip() {
        let store = SampleStore(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_770_000_000)
        store.append(Sample(
            ts: now, fiveHourUtil: 11, fiveHourReset: nil, sevenDayUtil: 37, sevenDayReset: nil,
            models: [ModelSample(name: "Fable", util: 66, reset: now.addingTimeInterval(3600))]))
        let loaded = store.load(since: .distantPast)
        XCTAssertEqual(loaded.first?.modelUtil("Fable"), 66)
        XCTAssertNotNil(loaded.first?.modelReset("Fable"))
        XCTAssertNil(loaded.first?.modelUtil("Opus"))
    }

    func testSnapshotInitCapturesModels() {
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 11, resetsAt: nil),
            sevenDay: UsageWindow(utilization: 37, resetsAt: nil),
            limits: [Limit(kind: "weekly_scoped", group: "weekly", percent: 66, resetsAt: nil,
                           isActive: true, severity: nil,
                           scope: Limit.Scope(model: Limit.Scope.Model(displayName: "Fable")))])
        let sample = Sample(ts: Date(), snapshot: snap)
        XCTAssertEqual(sample.modelUtil("Fable"), 66)
    }
}
