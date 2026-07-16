import CClimitCore
import Foundation

// Debug helper: send the /v1/messages quota probe and print status + every
// anthropic-ratelimit-* header, so we can confirm the header approach works, see the raw
// utilization scale, and settle whether the Claude Code system prompt is required.
// Set CCLIMIT_NO_SYSTEM=1 to test without the system prompt.

let creds = try ChainedCredentialSource().load()
let ua = ClaudeCodeVersion.detect() ?? UsageClient.defaultUserAgentVersion
let sendSystem = ProcessInfo.processInfo.environment["CCLIMIT_NO_SYSTEM"] == nil

let request = RateLimitProbe.request(token: creds.accessToken, userAgentVersion: ua, sendSystemPrompt: sendSystem)
FileHandle.standardError.write(
    Data("POST /v1/messages · UA \(UsageClient.userAgent(version: ua)) · system=\(sendSystem)\n".utf8))

let (data, response) = try await URLSession.shared.data(for: request)
guard let http = response as? HTTPURLResponse else {
    print("non-HTTP response"); exit(1)
}
FileHandle.standardError.write(Data("HTTP \(http.statusCode)\n".utf8))

print("=== anthropic-ratelimit-* headers ===")
let headers = http.allHeaderFields
    .compactMap { key, value -> (String, Any)? in
        let k = String(describing: key)
        return k.lowercased().contains("ratelimit") || k.lowercased().contains("retry")
            ? (k, value) : nil
    }
    .sorted { $0.0 < $1.0 }
if headers.isEmpty {
    print("(none)")
} else {
    for (k, v) in headers { print("\(k): \(v)") }
}

print("\n=== decoded snapshot ===")
if let snap = RateLimitProbe.snapshot(from: http) {
    print("5h:   util=\(snap.fiveHour?.utilization.map { String($0) } ?? "nil")  reset=\(snap.fiveHour?.resetsAt.map { String(describing: $0) } ?? "nil")")
    print("7d:   util=\(snap.sevenDay?.utilization.map { String($0) } ?? "nil")  reset=\(snap.sevenDay?.resetsAt.map { String(describing: $0) } ?? "nil")")
} else {
    print("(no unified headers → snapshot nil)")
    if http.statusCode != 200 {
        print("body: \(String(data: data, encoding: .utf8)?.prefix(400) ?? "")")
    }
}
