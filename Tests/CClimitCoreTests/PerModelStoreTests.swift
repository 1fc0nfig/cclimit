import XCTest

@testable import CClimitCore

final class PerModelStoreTests: XCTestCase {
    private func tempStore() -> PerModelStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-permodel-\(UUID().uuidString).json")
        return PerModelStore(fileURL: url)
    }

    private func snapshot(fable: Double) -> UsageSnapshot {
        UsageSnapshot(
            fiveHour: UsageWindow(utilization: 40, resetsAt: nil),
            sevenDay: UsageWindow(utilization: 30, resetsAt: nil),
            limits: [
                Limit(
                    kind: "weekly_scoped", group: "weekly", percent: fable,
                    resetsAt: Date(timeIntervalSince1970: 1_784_278_800), isActive: true,
                    severity: nil, scope: .init(model: .init(displayName: "Fable")))
            ])
    }

    func testRoundTripsSnapshotAndTimestamp() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }

        let ts = Date(timeIntervalSince1970: 1_784_200_000)
        store.save(snapshot(fable: 66), at: ts)

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.ts, ts)
        XCTAssertEqual(loaded.snapshot.perModelWindows.first?.name, "Fable")
        XCTAssertEqual(loaded.snapshot.perModelWindows.first?.window.utilization, 66)
    }

    func testLoadReturnsNilWhenAbsent() {
        let store = tempStore()
        XCTAssertNil(store.load())
    }

    func testSaveOverwritesPrevious() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }

        store.save(snapshot(fable: 50), at: Date(timeIntervalSince1970: 1))
        store.save(snapshot(fable: 80), at: Date(timeIntervalSince1970: 2))

        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.snapshot.perModelWindows.first?.window.utilization, 80)
        XCTAssertEqual(loaded.ts, Date(timeIntervalSince1970: 2))
    }
}
