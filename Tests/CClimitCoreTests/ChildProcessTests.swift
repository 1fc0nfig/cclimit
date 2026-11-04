import XCTest

@testable import CClimitCore

final class ChildProcessTests: XCTestCase {
    func testReturnsOutputAndStatus() throws {
        let result = try ChildProcess.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo hi; exit 3"], timeout: 5)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "hi\n")
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.timedOut)
    }

    func testHungChildIsStoppedAtTheDeadline() throws {
        let start = Date()
        let result = try ChildProcess.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testGrandchildHoldingThePipeDoesNotBlock() throws {
        // The shell exits at once, but its background child keeps stdout open.
        let start = Date()
        let result = try ChildProcess.run(
            URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30 & echo hi"], timeout: 5)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "hi\n")
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }
}
