import CClimitCore
import Foundation
import UserNotifications

/// Threshold + predictive notifications. Dedup rule from product.md §4: never more than
/// once per window per threshold — keyed on the window's resets_at, persisted so an app
/// restart can't re-fire.
final class Notifier {
    private let defaults = UserDefaults.standard
    // UNUserNotificationCenter aborts without a bundle (bare `swift run`); guard it.
    private let available = Bundle.main.bundleIdentifier != nil
    private var authorizationRequested = false

    private var thresholds: [Int] {
        [
            defaults.object(forKey: "notifyThresholdLow") as? Int ?? 75,
            defaults.object(forKey: "notifyThresholdHigh") as? Int ?? 90,
        ].filter { (1...100).contains($0) }
    }

    func evaluate(snapshot: UsageSnapshot, fiveHourVerdict: FiveHourVerdict, now: Date) {
        guard available else { return }

        check(window: snapshot.fiveHour, name: "5-hour window", key: "5h")
        check(window: snapshot.sevenDay, name: "weekly cap", key: "7d")

        if case .willHitWall(let eta, _, _) = fiveHourVerdict {
            let minutes = Int(eta.timeIntervalSince(now) / 60)
            // Predictive value is the lead time; under 15 min the threshold alerts own it.
            if minutes >= 15, let resetKey = snapshot.fiveHour?.resetsAt?.timeIntervalSince1970 {
                fireOnce(
                    key: "predict.5h.\(Int(resetKey))",
                    title: "Heads up: 5-hour limit ahead",
                    body: "At the current pace you'll hit the 5-hour limit in ~\(minutes) min — before it resets."
                )
            }
        }
    }

    private func check(window: UsageWindow?, name: String, key: String) {
        guard
            let window,
            let utilization = window.utilization,
            let reset = window.resetsAt
        else { return }
        let resetKey = Int(reset.timeIntervalSince1970)
        for threshold in thresholds where utilization >= Double(threshold) {
            fireOnce(
                key: "threshold.\(key).\(threshold).\(resetKey)",
                title: "\(Int(utilization.rounded()))% of your \(name) used",
                body: "Resets \(Format.resetStamp(reset)) (in \(Format.countdown(to: reset)))."
            )
        }
    }

    private func fireOnce(key: String, title: String, body: String) {
        let defaultsKey = "notified.\(key)"
        guard !defaults.bool(forKey: defaultsKey) else { return }
        defaults.set(true, forKey: defaultsKey)

        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
