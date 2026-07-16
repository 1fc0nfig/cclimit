import Foundation

public enum UsageError: Error, Equatable {
    case noCredentials
    case credentialAccessDenied
    case unauthorized          // 401 — token stale; re-read the store first
    case forbidden             // 403 — likely inference-only token (no user:profile scope)
    case rateLimited(retryAfter: TimeInterval?) // 429 — honor Retry-After (observed ~1300s penalties)
    case offline
    case schemaChanged(String) // decode failure or unexpected status — endpoint drifted
}

/// Client for the undocumented endpoint behind Claude Code's /usage.
/// The User-Agent header is REQUIRED — without it requests land in an
/// aggressively rate-limited bucket (anthropics/claude-code #30930).
public struct UsageClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Tracks the current Claude Code release; a stale version risks a stricter bucket.
    /// Bump alongside releases (was pinned at 2.1.0 while real installs were on 2.1.173).
    public static let defaultUserAgentVersion = "2.1.173"

    /// Claude Code's real UA, verified against the 2.1.173 binary:
    /// `claude-cli/${VERSION} (external, cli)` — NOT `claude-code/…`. The endpoint keys its
    /// rate-limit bucket on the client fingerprint (Claude Code's /usage kept working while
    /// our old UA sat in an escalating 429 penalty), so this string must match exactly.
    public static func userAgent(version: String) -> String {
        "claude-cli/\(version) (external, cli)"
    }

    let session: URLSession
    let userAgentVersion: String

    public init(session: URLSession = .shared, userAgentVersion: String = defaultUserAgentVersion) {
        self.session = session
        self.userAgentVersion = userAgentVersion
    }

    public static func request(token: String, userAgentVersion: String = defaultUserAgentVersion) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent(version: userAgentVersion), forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Axios default in Claude Code's client — matched so the fingerprint is identical.
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    public func fetch(token: String) async throws -> UsageSnapshot {
        let request = Self.request(token: token, userAgentVersion: userAgentVersion)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.offline
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.schemaChanged("non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            do {
                return try UsageJSON.decoder().decode(UsageSnapshot.self, from: data)
            } catch {
                throw UsageError.schemaChanged("decode failed: \(error)")
            }
        case 401: throw UsageError.unauthorized
        case 403: throw UsageError.forbidden
        case 429: throw UsageError.rateLimited(retryAfter: Self.retryAfter(from: http))
        default: throw UsageError.schemaChanged("HTTP \(http.statusCode)")
        }
    }

    /// Retry-After in delta-seconds form (the only form this endpoint has been seen to send).
    static func retryAfter(from http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0
        else { return nil }
        return seconds
    }
}
