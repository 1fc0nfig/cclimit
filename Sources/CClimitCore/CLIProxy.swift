import Foundation

/// Where a CLIProxyAPI (router-for-me/CLIProxyAPI) instance runs, and the key for its
/// management API. The key is the plaintext one; the proxy keeps only its bcrypt hash.
public struct ProxyConfig: Equatable, Sendable {
    public let baseURL: URL
    public let managementKey: String

    public init(baseURL: URL, managementKey: String) {
        self.baseURL = baseURL
        self.managementKey = managementKey
    }

    /// "100.94.42.52:8317" and "http://pi:8317/" both work. Nil for text that is no URL.
    public static func normalizedURL(_ text: String) -> URL? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if !raw.contains("://") { raw = "http://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard let url = URL(string: raw), url.host != nil else { return nil }
        return url
    }
}

/// One Claude login the proxy holds. The proxy records the unified rate-limit headers of
/// the last response it relayed for each login, so `signals` costs no call to Anthropic.
/// It is only as fresh as the last request that went through this login.
public struct ProxyLogin: Equatable, Sendable, Identifiable {
    /// The proxy's own id for the login (`auth_index`). `api-call` addresses it with this.
    public let authIndex: String
    public let email: String?
    /// Active, not disabled, not cooling down. A login in a cooldown still reports usage.
    public let isActive: Bool
    public let statusMessage: String?
    public let signals: UsageSnapshot?
    public let observedAt: Date?

    public var id: String { authIndex }

    public init(
        authIndex: String, email: String?, isActive: Bool, statusMessage: String?,
        signals: UsageSnapshot?, observedAt: Date?
    ) {
        self.authIndex = authIndex
        self.email = email
        self.isActive = isActive
        self.statusMessage = statusMessage
        self.signals = signals
        self.observedAt = observedAt
    }
}

/// Reads the proxy's management API (`/v0/management`). Usage for each login comes from two
/// places: the headers the proxy saw on real traffic (free, as fresh as the last request),
/// and `api-call`, which makes the proxy call the usage endpoint with the login's own token.
/// The token never leaves the proxy, and the call leaves from the proxy's IP.
///
/// The proxy bans a client IP after a few wrong keys and extends the ban on every attempt
/// during it. Callers must stop on `proxyKeyRejected` and wait out `proxyBanned`.
public struct CLIProxyClient: Sendable {
    public let config: ProxyConfig
    let session: URLSession

    public init(config: ProxyConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("v0/management/\(path)"))
        request.setValue("Bearer \(config.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return request
    }

    /// Every Claude login on the proxy. Codex and Gemini logins are skipped.
    public func logins() async throws -> [ProxyLogin] {
        let data = try await send(request("auth-files"))
        return try Self.parseLogins(data)
    }

    /// The usage endpoint's full payload for one login, per-model windows included.
    /// Spends that login's usage-endpoint budget, the same one Claude Code's `/usage` uses.
    public func usage(authIndex: String, userAgentVersion: String) async throws -> UsageSnapshot {
        var request = request("api-call")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // `$TOKEN$` is the proxy's placeholder for the login's access token.
        let body: [String: Any] = [
            "auth_index": authIndex,
            "method": "GET",
            "url": UsageClient.endpoint.absoluteString,
            "header": [
                "Authorization": "Bearer $TOKEN$",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": UsageClient.userAgent(version: userAgentVersion),
                "Accept": "application/json, text/plain, */*",
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let data = try await send(request)
        return try Self.parseAPICall(data)
    }

    private func send(_ request: URLRequest) async throws -> Data {
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
        if let error = Self.error(status: http.statusCode, body: data) { throw error }
        return data
    }

    /// Management API failures. A ban answers 403 with "IP banned … Try again in 1m32s".
    static func error(status: Int, body: Data) -> UsageError? {
        guard status != 200 else { return nil }
        let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? String
            ?? String(decoding: body.prefix(200), as: UTF8.self)
        if message.lowercased().contains("banned") {
            return .proxyBanned(retryAfter: retryAfter(inBanMessage: message))
        }
        switch status {
        case 401, 403: return .proxyKeyRejected
        case 404: return .schemaChanged("proxy has no management API at this address (HTTP 404)")
        default: return .schemaChanged("proxy HTTP \(status): \(message)")
        }
    }

    /// "Try again in 1m32s" → 92. Go duration text: hours, minutes, seconds.
    static func retryAfter(inBanMessage message: String) -> TimeInterval? {
        guard let range = message.range(of: " in ", options: .backwards) else { return nil }
        var total: TimeInterval = 0
        var number = ""
        var matched = false
        for char in message[range.upperBound...] {
            if char.isNumber || char == "." {
                number.append(char)
                continue
            }
            guard let value = Double(number) else { break }
            switch char {
            case "h": total += value * 3600
            case "m": total += value * 60
            case "s": total += value
            default: return matched ? total : nil
            }
            matched = true
            number = ""
        }
        return matched ? total : nil
    }

    static func parseLogins(_ data: Data) throws -> [ProxyLogin] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = root["files"] as? [[String: Any]]
        else { throw UsageError.schemaChanged("proxy auth-files has no files list") }
        return files.compactMap { file in
            let provider = (file["provider"] ?? file["type"]) as? String
            guard provider == "claude", let index = file["auth_index"] as? String else { return nil }
            let quota = file["quota"] as? [String: Any]
            let signals = (quota?["signals"] as? [String: Any]).map { raw in
                raw.compactMapValues { $0 as? String }
            }
            let status = file["status"] as? String
            let message = (file["status_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ProxyLogin(
                authIndex: index,
                email: (file["email"] ?? file["account"]) as? String,
                isActive: (status ?? "active") == "active"
                    && (file["disabled"] as? Bool) != true
                    && (file["unavailable"] as? Bool) != true,
                statusMessage: message,
                signals: signals.flatMap(RateLimitProbe.snapshot(headers:)),
                observedAt: (quota?["observed_at"] as? String).flatMap(parseDate))
        }
    }

    /// `api-call` answers 200 with the upstream status and body inside.
    static func parseAPICall(_ data: Data) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.schemaChanged("proxy api-call answer is not JSON")
        }
        let status = (root["status_code"] as? Int) ?? (root["status"] as? Int) ?? 0
        let body: Data
        if let text = root["body"] as? String {
            body = Data(text.utf8)
        } else if let object = root["body"], JSONSerialization.isValidJSONObject(object) {
            body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        } else {
            body = Data()
        }
        switch status {
        case 200:
            do {
                return try UsageJSON.decoder().decode(UsageSnapshot.self, from: body)
            } catch {
                throw UsageError.schemaChanged("decode failed: \(error)")
            }
        case 401: throw UsageError.unauthorized
        case 403: throw UsageError.forbidden
        case 429:
            let headers = root["header"] as? [String: Any]
            let raw = headers?.first { $0.key.lowercased() == "retry-after" }?.value
            let value = (raw as? [String])?.first ?? (raw as? String)
            throw UsageError.rateLimited(retryAfter: value.flatMap(TimeInterval.init))
        default: throw UsageError.schemaChanged("usage endpoint via proxy: HTTP \(status)")
        }
    }

    /// Go writes RFC 3339 with nanoseconds, which ISO8601DateFormatter cannot read: cut the
    /// fraction to milliseconds first.
    static func parseDate(_ raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = text[text.index(after: dot)..<zone].prefix(3)
            text = String(text[..<dot]) + "." + fraction + String(text[zone...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// The management key lives in the login Keychain. Reads and writes go through
/// `/usr/bin/security`, like Claude Code's token: an item that tool creates trusts it, so
/// no consent dialog appears whatever signature cclimit runs under.
public enum ProxyKeyStore {
    public static let service = "CClimit CLI Proxy"

    public static func load(account: String, toolPath: String = "/usr/bin/security") -> String? {
        guard let result = try? ChildProcess.run(
            URL(fileURLWithPath: toolPath),
            arguments: ["find-generic-password", "-s", service, "-a", account, "-w"], timeout: 10),
            !result.timedOut, result.status == 0
        else { return nil }
        let key = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// `-U` replaces an existing item. The command goes to `security -i` on stdin, so the
    /// key never shows in the process list, where any local process could read it.
    @discardableResult
    public static func save(_ key: String, account: String, toolPath: String = "/usr/bin/security") -> Bool {
        guard !key.contains(where: \.isNewline), !account.contains(where: \.isNewline) else { return false }
        let command = ["add-generic-password", "-U", "-s", quoted(service), "-a", quoted(account), "-w", quoted(key)]
            .joined(separator: " ") + "\n"
        guard let result = try? ChildProcess.run(
            URL(fileURLWithPath: toolPath), arguments: ["-i"], input: Data(command.utf8), timeout: 10)
        else { return false }
        return !result.timedOut && result.status == 0
    }

    /// A double-quoted word for `security -i`: backslash and quote are escaped.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public static func delete(account: String, toolPath: String = "/usr/bin/security") {
        _ = try? ChildProcess.run(
            URL(fileURLWithPath: toolPath),
            arguments: ["delete-generic-password", "-s", service, "-a", account], timeout: 10)
    }
}
