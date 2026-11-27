import Foundation

/// Grouping used by the Schedule and Month views.
enum DayAgenda {
    /// All-day / multi-day first, then by start, with a total tie-break so rows never jump around.
    static func order(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        if a.spansFullDays != b.spansFullDays { return a.spansFullDays }
        return (a.start, a.end, a.title, a.id) < (b.start, b.end, b.title, b.id)
    }

    /// One section per day that has events, plus today even when empty.
    static func sections(events: [CalendarEvent], days: [Date], today: Date,
                         calendar cal: Calendar = .current) -> [(day: Date, events: [CalendarEvent])] {
        let buckets = events.bucketed(by: days, calendar: cal)
        return days.indices.compactMap { i in
            let list = buckets[i].sorted(by: order)
            return (list.isEmpty && !cal.isDate(days[i], inSameDayAs: today)) ? nil : (days[i], list)
        }
    }
}

extension Array where Element == CalendarEvent {
    /// Events overlapping each day, computed with one interval per day (cheap date comparisons only).
    func bucketed(by days: [Date], calendar cal: Calendar = .current,
                  _ include: (CalendarEvent) -> Bool = { _ in true }) -> [[CalendarEvent]] {
        let candidates = filter(include)
        return days.map { d in
            let interval = cal.dayInterval(d)
            return candidates.filter { $0.overlaps(interval) }
        }
    }
}
