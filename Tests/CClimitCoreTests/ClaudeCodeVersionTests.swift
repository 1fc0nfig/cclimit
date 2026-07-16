import XCTest

@testable import CClimitCore

final class ClaudeCodeVersionTests: XCTestCase {
    func testSemverValidation() {
        XCTAssertTrue(ClaudeCodeVersion.isSemver("2.1.173"))
        XCTAssertTrue(ClaudeCodeVersion.isSemver("0.2.48"))
        XCTAssertFalse(ClaudeCodeVersion.isSemver("v23.9.0"))
        XCTAssertFalse(ClaudeCodeVersion.isSemver("2.1"))
        XCTAssertFalse(ClaudeCodeVersion.isSemver("latest"))
        XCTAssertFalse(ClaudeCodeVersion.isSemver("2.1.173-beta"))
    }

    func testNewestPicksHighestSemverNotLexicographic() {
        XCTAssertEqual(
            ClaudeCodeVersion.newest(of: ["2.1.9", "2.1.173", "2.1.20"]),
            "2.1.173")
        XCTAssertNil(ClaudeCodeVersion.newest(of: []))
    }

    func testDetectFromNativeInstallerLayout() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-vtest-\(UUID().uuidString)")
        let versions = home.appendingPathComponent(".local/share/claude/versions")
        try FileManager.default.createDirectory(
            at: versions.appendingPathComponent("2.1.170"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: versions.appendingPathComponent("2.1.173"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertEqual(ClaudeCodeVersion.detect(home: home), "2.1.173")
    }

    func testDetectFromNvmPackageJSON() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-vtest-\(UUID().uuidString)")
        let pkgDir = home.appendingPathComponent(
            ".nvm/versions/node/v24.12.0/lib/node_modules/@anthropic-ai/claude-code")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        try Data(#"{"name":"@anthropic-ai/claude-code","version":"2.1.150"}"#.utf8)
            .write(to: pkgDir.appendingPathComponent("package.json"))
        defer { try? FileManager.default.removeItem(at: home) }

        XCTAssertEqual(ClaudeCodeVersion.detect(home: home), "2.1.150")
    }

    func testDetectReturnsNilOnEmptyHome() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-vtest-\(UUID().uuidString)")
        XCTAssertNil(ClaudeCodeVersion.detect(home: home))
    }
}
