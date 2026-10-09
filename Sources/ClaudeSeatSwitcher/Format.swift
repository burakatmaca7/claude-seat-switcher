import Foundation

enum Format {
    /// Localized "13:40" / "1:40 PM", honouring the user's 12/24-hour setting.
    private static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
    private static let dayAndTime: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE jmm")
        return f
    }()

    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? timeOnly.string(from: date) : dayAndTime.string(from: date)
    }

    /// "2h 15m", "45m", "3d 4h" — time left until `date`.
    static func remaining(until date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(m, 1))m"
    }

    /// Short reset label for the menu: countdown within a day, otherwise weekday and time.
    static func reset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        if date <= now { return "↻ now" }
        return date.timeIntervalSince(now) < 86_400 ? "↻ " + remaining(until: date, now: now) : "↻ " + time(date)
    }

    /// Full sentence for the tooltip.
    static func resetSentence(_ label: String, _ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "\(label) limit" }
        let when = Calendar.current.isDateInToday(date) ? "today \(time(date))" : time(date)
        return "\(label) limit · resets \(when) (in \(remaining(until: date, now: now)))"
    }
}
