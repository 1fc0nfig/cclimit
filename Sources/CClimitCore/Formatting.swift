import Foundation

public enum Format {
    /// Human-readable time-to-reset that rolls up sensibly by horizon:
    /// "<1 m" / "42 m" / "1 h 13 m" / "2 d 3 h" / "3 days". A weekly window ~2 days out
    /// should read "2 d 3 h", never "51 h 0 m".
    public static func countdown(to date: Date, from now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "now" }
        if seconds < 60 { return "<1 m" }
        let totalMinutes = Int((seconds / 60).rounded(.up))
        if totalMinutes < 60 { return "\(totalMinutes) m" }

        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            let minutes = totalMinutes % 60
            return minutes == 0 ? "\(totalHours) h" : "\(totalHours) h \(minutes) m"
        }

        let days = totalHours / 24
        let hours = totalHours % 24
        if days >= 3 { return "\(days) days" } // beyond ~3 days, hours are noise
        return hours == 0 ? "\(days) d" : "\(days) d \(hours) h"
    }

    /// Compact menu-bar variant: "42m" / "1h13m" / "2d".
    public static func compactCountdown(to date: Date, from now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "0m" }
        let totalMinutes = Int((seconds / 60).rounded(.up))
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let totalHours = totalMinutes / 60
        if totalHours < 24 { return "\(totalHours)h\(totalMinutes % 60)m" }
        return "\(totalHours / 24)d"
    }

    /// "17:00" if the reset is today, else "Fri 17:00" — so a multi-day weekly reset
    /// isn't a bare time with no day.
    public static func resetStamp(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = clockTime(date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        return "\(weekday(date)) \(time)"
    }

    /// Renders a forecast band at the precision it deserves: a tight band (≤1 h) reads
    /// "≈ today 18:00", a same-day band "today 14:00–17:00", a cross-day band
    /// "Thu 22:00 – Fri 09:00", and anything wider than two days falls back to day
    /// names ("Thu–Sat") — hour stamps on a band that wide would be false precision.
    public static func etaRange(earliest: Date, latest: Date, now: Date = Date()) -> String {
        // The band has already begun — a clock stamp would point at the past.
        if earliest <= now {
            return "within \(countdown(to: latest, from: now))"
        }
        let span = latest.timeIntervalSince(earliest)
        let dayE = relativeDay(earliest, now: now)
        let dayL = relativeDay(latest, now: now)

        if span > 48 * 3600 {
            return dayE == dayL ? dayE : "\(dayE)–\(dayL)"
        }
        if span <= 3600 {
            return "≈ \(dayE) \(clockTime(earliest))"
        }
        if Calendar.current.isDate(earliest, inSameDayAs: latest) {
            return "\(dayE) \(clockTime(earliest))–\(clockTime(latest))"
        }
        return "\(dayE) \(clockTime(earliest)) – \(dayL) \(clockTime(latest))"
    }

    /// "today" / "tomorrow" / "Thu".
    public static func relativeDay(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow"
        }
        return weekday(date)
    }

    /// "17:00" in the user's locale/timezone.
    public static func clockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// "Thu" / "Fri 18:00" style day label for weekly range endpoints.
    public static func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date)
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// "840", "12k", "1.4M", "2.1B": token counts at a glance.
    public static func tokens(_ count: Int) -> String {
        let value = Double(count)
        guard value >= 1_000 else { return "\(count)" }
        // Round first, then pick the unit: 999,600 reads "1.0M", not "1000k".
        let units: [(Double, String)] = [(1_000, "k"), (1_000_000, "M"), (1_000_000_000, "B")]
        for (index, (divisor, unit)) in units.enumerated() {
            let x = value / divisor
            let isLast = index == units.count - 1
            if x < 9.95 { return String(format: "%.1f", x) + unit }
            if x.rounded() < 1000 || isLast { return String(Int(x.rounded())) + unit }
        }
        return "\(count)"
    }

    /// API list-price value in US dollars: "$0.42", "$70", "$3,325", "$12.3k". "<$0.01" for
    /// a trace, so a real cost never reads as zero.
    public static func dollars(_ amount: Double) -> String {
        switch amount {
        case ..<0.005: return amount > 0 ? "<$0.01" : "$0"
        case ..<10: return String(format: "$%.2f", amount)
        case ..<10_000:
            let whole = Int(amount.rounded())
            return whole < 1000 ? "$\(whole)" : "$\(whole / 1000),\(String(format: "%03d", whole % 1000))"
        default:
            let k = amount / 1000
            return k < 100 ? String(format: "$%.1fk", k) : "$\(Int(k.rounded()))k"
        }
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5".
    public static func modelName(_ raw: String) -> String {
        var parts = raw.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first(where: { !$0.allSatisfy(\.isNumber) }) else { return raw }
        let version = parts.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    /// "stale · 12m ago"
    public static func staleness(since lastUpdated: Date, now: Date = Date()) -> String {
        let minutes = Int(now.timeIntervalSince(lastUpdated) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h \(minutes % 60)m ago"
    }
}
