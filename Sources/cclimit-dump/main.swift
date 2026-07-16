import CClimitCore
import Foundation

// Debug helper: fetch the raw /api/oauth/usage payload and print it, so we can see
// exactly which per-model windows the endpoint returns for this account.
let creds = try ChainedCredentialSource().load()
var request = UsageClient.request(token: creds.accessToken)
let (data, response) = try await URLSession.shared.data(for: request)
if let http = response as? HTTPURLResponse {
    FileHandle.standardError.write(Data("HTTP \(http.statusCode)\n".utf8))
}
if let obj = try? JSONSerialization.jsonObject(with: data),
   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
    print(String(decoding: pretty, as: UTF8.self))
} else {
    print(String(decoding: data, as: UTF8.self))
}
