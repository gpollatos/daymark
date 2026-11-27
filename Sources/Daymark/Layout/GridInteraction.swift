import Foundation

/// Turns a click or drag on the day grid into an event's start and end, like Google Calendar:
/// a click makes a one-hour event at the half hour you clicked; a drag covers the dragged span,
/// snapped to 15 minutes.
enum SlotPicker {
    /// Moves shorter than this (in minutes of grid) count as a click, not a drag.
    static let clickTolerance = 8.0

    static func range(from a: Double, to b: Double, day: Date, calendar cal: Calendar = .current) -> (start: Date, end: Date) {
        let lo = min(max(min(a, b), 0), 1439), hi = min(max(max(a, b), 0), 1440)
        let startMin: Int, endMin: Int
        if hi - lo < clickTolerance {
            startMin = min(Int(lo) / 30 * 30, 23 * 60 + 30)
            endMin = startMin + 60
        } else {
            startMin = Int(lo) / 15 * 15
            endMin = max(Int((hi / 15).rounded(.up)) * 15, startMin + 15)
        }
        return (date(startMin, day, cal), date(endMin, day, cal))
    }

    /// Wall-clock minutes into `day` (1440 and beyond roll into the next day), so DST-change
    /// days line up with the hour labels.
    private static func date(_ minutes: Int, _ day: Date, _ cal: Calendar) -> Date {
        let base = cal.startOfDay(for: day)
        let d = cal.date(byAdding: .day, value: minutes / 1440, to: base) ?? base
        let m = minutes % 1440
        return cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: d) ?? d
    }
}

extension Calendar {
    /// Where `start`–`end` sits on `day`'s grid, in wall-clock minutes clipped to the day; nil if not on it.
    func slotMinutes(start: Date, end: Date, on day: Date) -> (start: Double, end: Double)? {
        let i = dayInterval(day)
        let touches = start == end ? i.containsHalfOpen(start) : (start < i.end && end > i.start)
        guard touches else { return nil }
        let s = start <= i.start ? 0 : minutesIntoDay(start)
        let e = end >= i.end ? 1440 : minutesIntoDay(end)
        return (s, max(e, s))
    }
}

/// Dragging an event on the day grid: where it lands, snapped to 15 minutes like Google Calendar.
enum EventMover {
    static let snap = 15

    /// Moving keeps the duration. `dx` moves across day columns (clamped to the days shown);
    /// `dy` moves the start in wall-clock time within the day, snapped to 15 minutes.
    static func moved(start: Date, end: Date, fromDay: Int, dayCount: Int, dx: Double, dy: Double,
                      columnWidth: Double, perMinute: Double, calendar cal: Calendar = .current) -> (start: Date, end: Date) {
        let shift = columnWidth > 0 ? Int((dx / columnWidth).rounded()) : 0
        let dayShift = min(max(fromDay + shift, 0), max(dayCount - 1, 0)) - fromDay
        let wanted = cal.minutesIntoDay(start) + dy / perMinute
        let minutes = min(max(Int((wanted / Double(snap)).rounded()) * snap, 0), 24 * 60 - snap)
        let day = cal.date(byAdding: .day, value: dayShift, to: cal.startOfDay(for: start)) ?? start
        let newStart = cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day) ?? start
        return (newStart, newStart.addingTimeInterval(end.timeIntervalSince(start)))
    }

    /// Dragging the bottom edge: the end moves by `dy`, snapped to 15 minutes, never before start + 15 min.
    static func resizedEnd(start: Date, end: Date, dy: Double, perMinute: Double, calendar cal: Calendar = .current) -> Date {
        let endDay = cal.startOfDay(for: end.addingTimeInterval(-1))
        let endMinutes = end.timeIntervalSince(endDay) / 60 + dy / perMinute
        let snapped = Int((endMinutes / Double(snap)).rounded()) * snap
        let candidate = endDay.addingTimeInterval(Double(snapped) * 60)
        return max(candidate, start.addingTimeInterval(Double(snap) * 60))
    }
}
