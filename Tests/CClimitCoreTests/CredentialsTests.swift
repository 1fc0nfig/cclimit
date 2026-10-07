import XCTest

@testable import CClimitCore

final class SecurityToolCredentialSourceTests: XCTestCase {
    private let json = #"{"claudeAiOauth":{"accessToken":"tok","scopes":["user:profile"]}}"#

    /// A stand-in for /usr/bin/security that prints `output` and exits with `status`.
    private func fakeTool(output: String, status: Int32) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-security-\(UUID().uuidString).sh")
        let script = "#!/bin/sh\nprintf '%s\\n' '\(output)'\nexit \(status)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func loadError(_ source: SecurityToolCredentialSource) -> CredentialError? {
        do {
            _ = try source.load()
            return nil
        } catch {
            return error as? CredentialError
        }
    }

    func testParsesPlainOutput() throws {
        let creds = try SecurityToolCredentialSource(toolPath: fakeTool(output: json, status: 0)).load()
        XCTAssertEqual(creds.accessToken, "tok")
        XCTAssertTrue(creds.hasProfileScope)
    }

    func testDecodesHexOutput() {
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        let decoded = SecurityToolCredentialSource.decode(Data((hex + "\n").utf8))
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), json)
    }

    func testMapsExitCodes() throws {
        XCTAssertEqual(loadError(.init(toolPath: try fakeTool(output: "", status: 44))), .notFound)
        XCTAssertEqual(loadError(.init(toolPath: try fakeTool(output: "", status: 128))), .accessDenied)
        XCTAssertEqual(loadError(.init(toolPath: "/nonexistent/security")), .notFound)
    }
}
