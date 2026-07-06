import Foundation

/// Formats a past instant as a coarse "… ago" string for low-frequency UI like the
/// "Last checked" line. Granularity widens as the interval grows — minutes up to an
/// hour, then hours up to a day, then days, weeks, months, years — so the reading
/// stays at a single, sensible unit instead of spurious precision ("3 hours ago",
/// never "3 hours 12 minutes ago"). Sub-minute intervals read as "just now"; a
/// "Last checked" line has no use for second-level precision.
enum RelativeTime {
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 60 * minute
    private static let day: TimeInterval = 24 * hour
    private static let week: TimeInterval = 7 * day
    private static let month: TimeInterval = 30 * day      // approximate; fine for this use
    private static let year: TimeInterval = 365 * day

    /// `date` formatted relative to `now` (defaults to the current moment). A `date`
    /// in the future, or now, reads as "just now".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<minute: return "just now"
        case ..<hour:   return count(seconds / minute, "minute")
        case ..<day:    return count(seconds / hour, "hour")
        case ..<week:   return count(seconds / day, "day")
        case ..<month:  return count(seconds / week, "week")
        case ..<year:   return count(seconds / month, "month")
        default:        return count(seconds / year, "year")
        }
    }

    /// "1 minute ago" / "3 minutes ago" — floors the count (it's been *at least* this long).
    private static func count(_ value: Double, _ unit: String) -> String {
        let n = Int(value)
        return "\(n) \(unit)\(n == 1 ? "" : "s") ago"
    }
}
