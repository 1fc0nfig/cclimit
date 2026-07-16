import CClimitCore
import Foundation

// Debug helper: fetch the raw /api/oauth/usage payload and print it, so we can see
// exactly which per-model windows the endpoint returns for this account.
let creds = try ChainedCredentialSource().load()
let ua = ProcessInfo.processInfo.environment["CCLIMIT_UA_VERSION"]
    ?? ClaudeCodeVersion.detect()
    ?? UsageClient.defaultUserAgentVersion
var request = UsageClient.request(token: creds.accessToken, userAgentVersion: ua)
let (data, response) = try await URLSession.shared.data(for: request)
if let http = response as? HTTPURLResponse {
    FileHandle.standardError.write(
        Data("HTTP \(http.statusCode) (UA \(UsageClient.userAgent(version: ua)))\n".utf8))
    for (key, value) in http.allHeaderFields {
        let k = String(describing: key).lowercased()
        if k.contains("retry") || k.contains("ratelimit") || k.contains("request-id") {
            FileHandle.standardError.write(Data("\(key): \(value)\n".utf8))
        }
    }
}
if let obj = try? JSONSerialization.jsonObject(with: data),
   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
    print(String(decoding: pretty, as: UTF8.self))
} else {
    print(String(decoding: data, as: UTF8.self))
}
