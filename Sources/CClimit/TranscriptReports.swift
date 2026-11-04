import CClimitCore
import Foundation

/// Project stats from one transcript index, one report per range page, loaded lazily and
/// throttled. Each account has one for its own folder. The CLI proxy pool has one for the
/// config dirs that send their traffic through the proxy.
@MainActor
final class TranscriptReports: ObservableObject {
    /// One page of one range. The start is rounded to the minute: reset times jitter by a
    /// few seconds between polls and must not miss the cache.
    struct Key: Hashable {
        let range: AttributionRange
        let start: Date
    }

    @Published private(set) var reports: [Key: UsageReport] = [:]
    private(set) var index: TranscriptIndex
    private var updated: [Key: Date] = [:]
    private var inFlight: Set<Key> = []
    private var warmed = false

    init(index: TranscriptIndex) {
        self.index = index
    }

    static var dataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CClimit", isDirectory: true)
    }

    private static func key(range: AttributionRange, span: DateInterval) -> Key {
        let minute = (span.start.timeIntervalSince1970 / 60).rounded() * 60
        return Key(range: range, start: Date(timeIntervalSince1970: minute))
    }

    /// The finished report for a page, or nil while it loads.
    func report(range: AttributionRange, span: DateInterval) -> UsageReport? {
        reports[Self.key(range: range, span: span)]
    }

    /// Loads the page when it has no report yet, or when the current page is five minutes
    /// old. A past page never changes, so it loads once.
    func refreshIfStale(range: AttributionRange, span: DateInterval) {
        let now = Date()
        let key = Self.key(range: range, span: span)
        guard !inFlight.contains(key) else { return }
        if let last = updated[key], span.end <= last || now.timeIntervalSince(last) < 300 { return }
        inFlight.insert(key)
        let index = index
        Task(priority: .utility) { [weak self] in
            let result = await index.report(
                since: span.start, until: span.end, now: now, bucketSize: range.bucketSize)
            guard let self else { return }
            self.inFlight.remove(key)
            // The folder changed while this one read: its numbers belong to the old one.
            guard index === self.index else { return }
            self.reports[key] = result
            self.updated[key] = now
            self.trim()
        }
    }

    /// Indexes the last 31 days once, in the background, so the first page the user opens
    /// only adds up slices. Without it the first long range reads every transcript.
    func warm() {
        guard !warmed else { return }
        warmed = true
        let index = index
        Task(priority: .utility) { await index.warm() }
    }

    /// The folder changed: forget every report and read the new one.
    func replace(index: TranscriptIndex) {
        self.index = index
        reports = [:]
        updated = [:]
        inFlight = []
        warmed = false
        warm()
    }

    #if DEBUG
    func setDemoReport(_ report: UsageReport, range: AttributionRange, span: DateInterval) {
        let key = Self.key(range: range, span: span)
        reports[key] = report
        updated[key] = .distantFuture
    }
    #endif

    /// Keeps the 24 most recent pages: enough to step back through a month of days.
    private func trim() {
        guard reports.count > 24 else { return }
        let keep = Set(updated.sorted { $0.value > $1.value }.prefix(24).map(\.key))
        reports = reports.filter { keep.contains($0.key) }
        updated = updated.filter { keep.contains($0.key) }
    }
}
