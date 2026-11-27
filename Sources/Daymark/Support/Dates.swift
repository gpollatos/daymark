import Foundation

enum RFC3339 {
    nonisolated(unsafe) private static let internet: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func parse(_ s: String) -> Date? { internet.date(from: s) ?? fractional.date(from: s) }
    /// UTC "Z" form: no "+" sign that would need escaping in query strings.
    static func string(_ d: Date) -> String { internet.string(from: d) }
    /// "yyyy-MM-dd" to the start of that day in `calendar`'s time zone. Where DST begins at
    /// midnight (local midnight doesn't exist) this is the first instant of the day.
    static func parseDay(_ s: String, calendar: Calendar = .current) -> Date? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d),
              let date = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)),
              calendar.component(.day, from: date) == d else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func dayString(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

extension Calendar {
    func startOfWeek(_ d: Date) -> Date { dateInterval(of: .weekOfYear, for: d)?.start ?? startOfDay(for: d) }
    func startOfMonth(_ d: Date) -> Date { dateInterval(of: .month, for: d)?.start ?? startOfDay(for: d) }

    func dayInterval(_ d: Date) -> DateInterval {
        let s = startOfDay(for: d)
        return DateInterval(start: s, end: date(byAdding: .day, value: 1, to: s) ?? s.addingTimeInterval(86_400))
    }

    func days(in interval: DateInterval) -> [Date] {
        var out: [Date] = []
        var d = startOfDay(for: interval.start)
        while d < interval.end {
            out.append(d)
            guard let n = date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        return out
    }

    /// Weekday symbols ordered from the locale's first weekday.
    func orderedWeekdaySymbols(_ symbols: [String]) -> [String] {
        let f = firstWeekday - 1
        return Array(symbols[f...] + symbols[..<f])
    }

    func minutesIntoDay(_ d: Date) -> Double {
        let c = dateComponents([.hour, .minute], from: d)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0))
    }
}

extension DateInterval {
    /// Half-open membership: [start, end). `DateInterval.contains` includes `end`.
    func containsHalfOpen(_ d: Date) -> Bool { d >= start && d < end }
    func covers(_ other: DateInterval) -> Bool { start <= other.start && end >= other.end }
}
