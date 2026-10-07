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

/// Reads the generic password Claude Code stores under service "Claude Code-credentials"
/// through the Security framework. This prompts for consent, and the consent does not survive
/// an unvalidated signature or a Claude Code token refresh. Prefer `SecurityToolCredentialSource`.
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

/// Reads the same Keychain item by running `/usr/bin/security`, the way Claude Code itself does.
/// Claude Code creates and rewrites the item with that tool, so the item's ACL always trusts it:
/// the read never shows a consent dialog. A direct `SecItemCopyMatching` from CClimit needs its
/// own ACL entry, which only holds while macOS can validate CClimit's signature, and every
/// Claude Code token refresh can reset it. That is the recurring "allow access" prompt.
public struct SecurityToolCredentialSource: CredentialSource {
    public let service: String
    let toolPath: String

    public init(service: String = "Claude Code-credentials", toolPath: String = "/usr/bin/security") {
        self.service = service
        self.toolPath = toolPath
    }

    public func load() throws -> OAuthCredentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CredentialError.notFound
        }
        // Read before waiting: a full pipe buffer would otherwise block the child forever.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        switch process.terminationStatus {
        case 0:
            return try CredentialJSON.parse(Self.decode(data))
        case 44:  // errSecItemNotFound
            throw CredentialError.notFound
        case 51, 128:  // errSecAuthFailed / errSecUserCanceled (low byte of -128)
            throw CredentialError.accessDenied
        default:
            throw CredentialError.malformed("security exited \(process.terminationStatus)")
        }
    }

    /// `security -w` prints the secret plus a newline, or hex when the bytes aren't printable.
    static func decode(_ output: Data) -> Data {
        let text = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.hasPrefix("{"), text.count % 2 == 0,
              text.allSatisfy(\.isHexDigit)
        else { return Data(text.utf8) }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return Data(text.utf8) }
            bytes.append(byte)
            index = next
        }
        return bytes
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

/// Keychain (via `/usr/bin/security`, prompt-free) first, file fallback. The direct
/// `KeychainCredentialSource` is deliberately not in the default chain: it is the path that
/// prompts. Access denial is surfaced (it needs its own UI state), everything else falls
/// through to the next source.
public struct ChainedCredentialSource: CredentialSource {
    let sources: [CredentialSource]

    public init(sources: [CredentialSource] = [SecurityToolCredentialSource(), FileCredentialSource()]) {
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
