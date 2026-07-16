import Foundation

public enum UsageError: Error, Equatable {
    case noCredentials
    case credentialAccessDenied
    case unauthorized          // 401 — token stale; re-read the store first
    case forbidden             // 403 — likely inference-only token (no user:profile scope)
    case rateLimited           // 429 — back off hard, endpoint sends no Retry-After
    case offline
    case schemaChanged(String) // decode failure or unexpected status — endpoint drifted
}

/// Client for the undocumented endpoint behind Claude Code's /usage.
/// The User-Agent header is REQUIRED — without it requests land in an
/// aggressively rate-limited bucket (anthropics/claude-code #30930).
public struct UsageClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    let session: URLSession
    let userAgentVersion: String

    public init(session: URLSession = .shared, userAgentVersion: String = "2.1.0") {
        self.session = session
        self.userAgentVersion = userAgentVersion
    }

    public static func request(token: String, userAgentVersion: String = "2.1.0") -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(userAgentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        case 429: throw UsageError.rateLimited
        default: throw UsageError.schemaChanged("HTTP \(http.statusCode)")
        }
    }
}
