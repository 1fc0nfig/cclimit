import CClimitCore
import Foundation

signal(SIGPIPE, SIG_IGN)

// Debug helper: fetch the raw /api/oauth/usage payload and print it, so we can see
// exactly which per-model windows the endpoint returns for this account.
// `--accounts` lists the Claude Code logins cclimit discovers (no tokens) and makes no request.
if CommandLine.arguments.contains("--accounts") {
    for account in AccountDiscovery.discover() {
        let fields = [
            account.id, account.suggestedName, account.email ?? "-", account.plan.label ?? "-",
            account.configDir?.path ?? "-",
            account.tokenExpiresAt.map { "token expires \($0)" } ?? "-",
            account.isDormant() ? "dormant" : "active",
        ]
        print(fields.joined(separator: "  "))
    }
    exit(0)
}
// `--via-claude [config dir]` asks Claude Code for usage (`get_usage`), the way the app does
// with Settings > Usage source > Claude Code. cclimit reads no token. One usage call.
if let flag = CommandLine.arguments.firstIndex(of: "--via-claude") {
    let dir = CommandLine.arguments.indices.contains(flag + 1)
        ? URL(fileURLWithPath: (CommandLine.arguments[flag + 1] as NSString).expandingTildeInPath) : nil
    let started = Date()
    do {
        let reading = try await ClaudeCodeUsageSource(configDir: dir).fetch()
        let snap = reading.snapshot
        print("account: \(reading.email ?? "-") · \(reading.subscription ?? "-") · \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        print("5h: \(snap.fiveHour?.utilization ?? -1)%  resets \(snap.fiveHour?.resetsAt.map { "\($0)" } ?? "-")")
        print("weekly: \(snap.sevenDay?.utilization ?? -1)%  resets \(snap.sevenDay?.resetsAt.map { "\($0)" } ?? "-")")
        for model in snap.perModelWindows {
            print("\(model.name): \(model.window.utilization ?? -1)%")
        }
    } catch {
        print("failed: \(error)")
        exit(1)
    }
    exit(0)
}
// `--proxy <url>` lists the CLI proxy's Claude logins with the usage it saw on their
// traffic. The management key comes from CCLIMIT_PROXY_KEY. `--full` also asks the proxy
// for each login's usage payload: one usage-endpoint call per login.
if let flag = CommandLine.arguments.firstIndex(of: "--proxy"),
   CommandLine.arguments.indices.contains(flag + 1),
   let url = ProxyConfig.normalizedURL(CommandLine.arguments[flag + 1]),
   let key = ProcessInfo.processInfo.environment["CCLIMIT_PROXY_KEY"] {
    let client = CLIProxyClient(config: ProxyConfig(baseURL: url, managementKey: key))
    do {
        for login in try await client.logins() {
            let s = login.signals
            print("\(login.authIndex)  \(login.email ?? "-")  active=\(login.isActive)  5h=\(s?.fiveHour?.utilization.map { "\($0)%" } ?? "none")  weekly=\(s?.sevenDay?.utilization.map { "\($0)%" } ?? "-")  observed \(login.observedAt.map { "\($0)" } ?? "-")")
            if CommandLine.arguments.contains("--full") {
                let ua = ClaudeCodeVersion.detect() ?? UsageClient.defaultUserAgentVersion
                let full = try await client.usage(authIndex: login.authIndex, userAgentVersion: ua)
                let models = full.perModelWindows.map { "\($0.name) \($0.window.utilization ?? -1)%" }
                print("    payload: 5h=\(full.fiveHour?.utilization.map { "\($0)%" } ?? "none")  weekly=\(full.sevenDay?.utilization ?? -1)%  models=[\(models.joined(separator: ", "))]")
            }
        }
    } catch {
        print("failed: \(error)")
        exit(1)
    }
    exit(0)
}
// `--projects [window|today|week|month] [--root <projects dir>]` prints the local project
// stats and makes no request. `--proxy-routes` lists config dirs routed through a proxy.
if CommandLine.arguments.contains("--proxy-routes") {
    for route in ProxyDetection.routes() {
        let cli = await ProxyDetection.isCLIProxy(baseURL: route.baseURL)
        print("\(route.configDir.path) → \(route.baseURL.absoluteString)\(cli ? " · CLIProxyAPI" : "")")
    }
    exit(0)
}
if let flag = CommandLine.arguments.firstIndex(of: "--projects") {
    let arg = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "today"
    let range = AttributionRange(rawValue: arg) ?? .today
    let now = Date()
    let started = Date()
    let root = CommandLine.arguments.firstIndex(of: "--root")
        .flatMap { CommandLine.arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil }
    let index = TranscriptIndex(
        root: root ?? AttributionEngine.defaultRoot(),
        storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("cclimit-index-dump.plist"))
    let report = await index.report(
        since: range.start(now: now, fiveHourReset: nil, weeklyReset: nil), now: now,
        bucketSize: range.bucketSize)
    print("\(range.label): \(Format.tokens(report.total)) tokens · ≈ \(Format.dollars(report.cost)) · \(report.sessions) sessions · \(report.buckets.count) buckets · scanned in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
    for p in report.projects.prefix(8) {
        let models = p.models.prefix(3).map { "\($0.name) \(Format.tokens($0.tokens))" }.joined(separator: ", ")
        print("  \(p.name)  \(Format.tokens(p.tokens))  \(Format.dollars(p.cost))  \(Int(p.share * 100))%  sessions=\(p.sessions)  sub=\(Int(p.subagentShare * 100))%  [\(models)]")
    }
    exit(0)
}
// `--account <id>` dumps the payload for one discovered login (ids from `--accounts`).
let creds: OAuthCredentials
if let flag = CommandLine.arguments.firstIndex(of: "--account"),
   CommandLine.arguments.indices.contains(flag + 1) {
    let id = CommandLine.arguments[flag + 1]
    guard let account = AccountDiscovery.discover().first(where: { $0.id == id }) else {
        print("no login with id \(id), see --accounts")
        exit(1)
    }
    creds = try SecurityToolCredentialSource(service: account.service).load()
} else {
    creds = try ChainedCredentialSource().load()
}
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
