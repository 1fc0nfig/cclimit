import XCTest

@testable import CClimitCore

final class SecurityCLICredentialSourceTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cclimit-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A stand-in for /usr/bin/security that ignores its arguments.
    private func fakeSecurity(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("security")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testParsesPasswordFromStdout() throws {
        let exe = try fakeSecurity(
            #"echo '{"claudeAiOauth":{"accessToken":"tok","expiresAt":1700000000000,"scopes":["user:profile"]}}'"#)
        let creds = try SecurityCLICredentialSource(executable: exe).load()
        XCTAssertEqual(creds.accessToken, "tok")
        XCTAssertTrue(creds.hasProfileScope)
        XCTAssertEqual(creds.expiresAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testExit44IsNotFound() throws {
        let exe = try fakeSecurity("exit 44")
        XCTAssertThrowsError(try SecurityCLICredentialSource(executable: exe).load()) {
            XCTAssertEqual($0 as? CredentialError, .notFound)
        }
    }

    func testOtherFailureFallsThroughChain() throws {
        let failing = SecurityCLICredentialSource(executable: try fakeSecurity("exit 1"))
        let missing = SecurityCLICredentialSource(executable: dir.appendingPathComponent("nope"))
        let file = dir.appendingPathComponent("creds.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"from-file"}}"#.utf8).write(to: file)

        let chain = ChainedCredentialSource(sources: [failing, missing, FileCredentialSource(url: file)])
        XCTAssertEqual(try chain.load().accessToken, "from-file")
    }
}
