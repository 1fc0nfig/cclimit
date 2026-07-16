import Foundation

/// Reads usage from the unified rate-limit headers on a `/v1/messages` response — the
/// mechanism Claude Code itself uses (binary fn `WkO`/`$r7`). Sends a 1-token throwaway
/// message and ignores the body; the numbers ride the response headers. This endpoint
/// carries the generous *message* rate limit, not `/api/oauth/usage`'s tiny per-account
/// bucket, so it can be polled without tripping penalties.
///
/// Headers (fn `$r7`): `anthropic-ratelimit-unified-{5h,7d,overage}-{utilization,reset}`
/// where utilization is a 0–1 fraction and reset is unix seconds. Only 5h + 7d are
/// exposed here — per-model (e.g. Fable) still requires the usage endpoint.
public struct RateLimitProbe: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Small, cheap model — the response headers are identical regardless of model, so we
    /// pick the least expensive. Matches Claude Code's "small fast model" choice for probes.
    public static let probeModel = "claude-haiku-4-5-20251001"

    /// OAuth (subscription) access to /v1/messages requires this exact preamble as the first
    /// system block, or Anthropic rejects the request. Verified present in the binary.
    static let claudeCodeSystemPrompt =
        "You are Claude Code, Anthropic's official CLI for Claude."

    let session: URLSession
    let userAgentVersion: String
    /// Whether to send the Claude Code system prompt. Determined empirically by the probe
    /// target; kept configurable so we can A/B it without a rebuild.
    let sendSystemPrompt: Bool

    public init(
        session: URLSession = .shared,
        userAgentVersion: String = UsageClient.defaultUserAgentVersion,
        sendSystemPrompt: Bool = true
    ) {
        self.session = session
        self.userAgentVersion = userAgentVersion
        self.sendSystemPrompt = sendSystemPrompt
    }

    public static func request(
        token: String,
        userAgentVersion: String = UsageClient.defaultUserAgentVersion,
        sendSystemPrompt: Bool = true
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(
            UsageClient.userAgent(version: userAgentVersion), forHTTPHeaderField: "User-Agent")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        var body: [String: Any] = [
            "model": probeModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "quota"]],
        ]
        if sendSystemPrompt {
            body["system"] = [["type": "text", "text": claudeCodeSystemPrompt]]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func fetch(token: String) async throws -> UsageSnapshot {
        let request = Self.request(
            token: token, userAgentVersion: userAgentVersion, sendSystemPrompt: sendSystemPrompt)
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
            guard let snapshot = Self.snapshot(from: http) else {
                throw UsageError.schemaChanged("no unified rate-limit headers on 200 response")
            }
            return snapshot
        case 401: throw UsageError.unauthorized
        case 403: throw UsageError.forbidden
        case 429: throw UsageError.rateLimited(retryAfter: UsageClient.retryAfter(from: http))
        default:
            let detail = String(data: data, encoding: .utf8).map { String($0.prefix(200)) } ?? ""
            throw UsageError.schemaChanged("HTTP \(http.statusCode): \(detail)")
        }
    }

    /// Build a UsageSnapshot from the unified rate-limit headers. Utilization arrives as a
    /// 0–1 fraction; we normalize to the 0–100 convention the rest of cclimit uses.
    public static func snapshot(from http: HTTPURLResponse) -> UsageSnapshot? {
        func window(_ key: String) -> UsageWindow? {
            let base = "anthropic-ratelimit-unified-\(key)"
            let utilRaw = http.value(forHTTPHeaderField: "\(base)-utilization")
            let resetRaw = http.value(forHTTPHeaderField: "\(base)-reset")
            let util = utilRaw.flatMap(Double.init)
            let reset = resetRaw.flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            if util == nil && reset == nil { return nil }
            return UsageWindow(utilization: util.map { $0 * 100 }, resetsAt: reset)
        }
        let fiveHour = window("5h")
        let sevenDay = window("7d")
        guard fiveHour != nil || sevenDay != nil else { return nil }
        return UsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay)
    }
}
