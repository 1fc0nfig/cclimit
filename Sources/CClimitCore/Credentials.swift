import Foundation
import Security

/// Claude Code's stored OAuth credentials. CClimit is strictly read-only:
/// it must never write to the Keychain item or the credentials file (see product.md §5).
public struct OAuthCredentials: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, scopes: [String]) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    /// The usage endpoint needs user:profile; setup-tokens (inference only) get 403.
    public var hasProfileScope: Bool { scopes.contains("user:profile") }

    /// True once the token is past (or within two minutes of) its expiry — time to re-read
    /// the store. Tokens without an expiry are trusted until the API says 401.
    public func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(120) >= expiresAt
    }
}

public enum CredentialError: Error, Equatable {
    case notFound
    case accessDenied
    case malformed(String)
}

public protocol CredentialSource: Sendable {
    func load() throws -> OAuthCredentials
}

enum CredentialJSON {
    /// Shape: {"claudeAiOauth": {"accessToken": "...", "refreshToken": "...", "expiresAt": ms, "scopes": [...]}}
    static func parse(_ data: Data) throws -> OAuthCredentials {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any]
        else {
            throw CredentialError.malformed("missing claudeAiOauth object")
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw CredentialError.malformed("missing accessToken")
        }
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        }
        return OAuthCredentials(
            accessToken: token,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expires,
            scopes: oauth["scopes"] as? [String] ?? []
        )
    }
}

/// Reads the generic password Claude Code stores under service "Claude Code-credentials".
/// First read triggers a one-time macOS consent dialog — expected, explained in onboarding.
public struct KeychainCredentialSource: CredentialSource {
    public let service: String

    public init(service: String = "Claude Code-credentials") {
        self.service = service
    }

    public func load() throws -> OAuthCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw CredentialError.malformed("keychain item is not data")
            }
            return try CredentialJSON.parse(data)
        case errSecItemNotFound:
            throw CredentialError.notFound
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
            throw CredentialError.accessDenied
        default:
            throw CredentialError.malformed("keychain error \(status)")
        }
    }
}

/// Reads the same Keychain item by shelling out to /usr/bin/security.
/// Claude Code writes the item through the `security` CLI, so that binary is the item's trusted
/// application — reading through it needs no consent. Reading via SecItemCopyMatching instead
/// re-prompts after every token refresh, because Claude Code's rewrite resets the item's ACL
/// and drops cclimit's "Always Allow". Still strictly read-only (`find-generic-password`).
public struct SecurityCLICredentialSource: CredentialSource {
    public let service: String
    let executable: URL

    public init(
        service: String = "Claude Code-credentials",
        executable: URL = URL(fileURLWithPath: "/usr/bin/security")
    ) {
        self.service = service
        self.executable = executable
    }

    public func load() throws -> OAuthCredentials {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CredentialError.malformed("cannot run security: \(error)")
        }
        // Drain before waiting so a large payload can't fill the pipe and deadlock.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0:
            return try CredentialJSON.parse(data)
        case 44:  // errSecItemNotFound
            throw CredentialError.notFound
        default:
            throw CredentialError.malformed("security exited \(process.terminationStatus)")
        }
    }
}

/// Fallback used on Linux/headless setups: ~/.claude/.credentials.json (same JSON shape).
public struct FileCredentialSource: CredentialSource {
    public let url: URL

    public init(url: URL? = nil) {
        self.url = url
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
    }

    public func load() throws -> OAuthCredentials {
        guard let data = try? Data(contentsOf: url) else {
            throw CredentialError.notFound
        }
        return try CredentialJSON.parse(data)
    }
}

/// Keychain via the `security` CLI first (no consent prompt), then the Keychain API directly,
/// then the file. Access denial is surfaced (it needs its own UI state), everything else falls
/// through to the next source.
public struct ChainedCredentialSource: CredentialSource {
    let sources: [CredentialSource]

    public init(sources: [CredentialSource] = [
        SecurityCLICredentialSource(), KeychainCredentialSource(), FileCredentialSource(),
    ]) {
        self.sources = sources
    }

    public func load() throws -> OAuthCredentials {
        var denied = false
        for source in sources {
            do {
                return try source.load()
            } catch CredentialError.accessDenied {
                denied = true
            } catch {
                continue
            }
        }
        throw denied ? CredentialError.accessDenied : CredentialError.notFound
    }
}
