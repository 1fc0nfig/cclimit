import Foundation
import OSLog

/// Unified-logging channel. Watch it live with:
///
///   log stream --predicate 'subsystem == "com.cernymatyas.cclimit"' --level debug
///
/// or read history:
///
///   log show --predicate 'subsystem == "com.cernymatyas.cclimit"' --last 2h --info --debug
///
/// Values are marked `.public` on purpose — they're utilization numbers, HTTP statuses, and
/// retry-after seconds, never the token. Nothing sensitive is ever logged here.
enum Log {
    static let poll = Logger(subsystem: "com.cernymatyas.cclimit", category: "poll")
}
