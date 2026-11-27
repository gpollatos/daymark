import Foundation

/// Editable copy of an event used by the editor sheet.
/// For all-day events `end` holds the last day (inclusive), as people expect to see it.
struct EventDraft: Identifiable, Equatable {
    let id = UUID()
    var existing: CalendarEvent?
    var calendarKey: String
    var title = ""
    var isAllDay = false
    var start: Date
    var end: Date
    var location = ""
    var notes = ""
    /// Comma- or space-separated guest emails (excluding you).
    var guests = ""
    var addMeet = false
    var repeatRule: RepeatRule = .none

    /// New end after the start moves from `old` to `new`, keeping the duration, like Google Calendar.
    /// All-day events move by whole calendar days, so a DST change in between can't drop or add a day.
    static func shiftedEnd(end: Date, oldStart old: Date, newStart new: Date, allDay: Bool,
                           calendar cal: Calendar = .current) -> Date {
        let shifted: Date
        if allDay {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: old), to: cal.startOfDay(for: new)).day ?? 0
            shifted = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: end)) ?? end
        } else {
            shifted = end.addingTimeInterval(new.timeIntervalSince(old))
        }
        return max(shifted, allDay ? cal.startOfDay(for: new) : new)
    }
}

enum RepeatRule: String, CaseIterable, Identifiable {
    case none, daily, weekdays, weekly, monthly, yearly
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Does not repeat"
        case .daily: "Every day"
        case .weekdays: "Every weekday (Mon–Fri)"
        case .weekly: "Every week"
        case .monthly: "Every month"
        case .yearly: "Every year"
        }
    }

    var rrule: [String]? {
        switch self {
        case .none: nil
        case .daily: ["RRULE:FREQ=DAILY"]
        case .weekdays: ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"]
        case .weekly: ["RRULE:FREQ=WEEKLY"]
        case .monthly: ["RRULE:FREQ=MONTHLY"]
        case .yearly: ["RRULE:FREQ=YEARLY"]
        }
    }
}

extension EventDraft {
    /// The guests listed in the editor (comma, semicolon, space or line separated; "Name <a@b.c>" works).
    var guestEmails: [String] { CalendarStore.parseEmails(guests) }

    /// Whether saving this draft emails guests, the rule `CalendarStore.save` follows and the
    /// editor shows: new events with guests; and changes to meetings you organise that have,
    /// or had, guests. Guests of someone else's meeting are never emailed by your edits.
    var savingNotifiesGuests: Bool {
        guard let ex = existing else { return !guestEmails.isEmpty }
        return ex.isOrganizer && (ex.hasOtherGuests || !guestEmails.isEmpty)
    }

    /// Where a new timed event being created sits on `day`'s grid, in wall-clock minutes
    /// (clipped to the day), so it stays highlighted while the editor is open. nil if it isn't on that day.
    func placeholderMinutes(on day: Date, calendar cal: Calendar = .current) -> (start: Double, end: Double)? {
        guard existing == nil, !isAllDay else { return nil }
        return cal.slotMinutes(start: start, end: end, on: day)
    }

    /// Whether a new all-day event being created covers `day` (`end` is the inclusive last day).
    func placeholderCovers(day: Date, calendar cal: Calendar = .current) -> Bool {
        guard existing == nil, isAllDay else { return false }
        let d = cal.startOfDay(for: day)
        return d >= cal.startOfDay(for: start) && d <= cal.startOfDay(for: max(end, start))
    }

    /// The Starts picker: moving the start keeps the duration (see `shiftedEnd`).
    mutating func setStart(_ new: Date, calendar cal: Calendar = .current) {
        end = Self.shiftedEnd(end: end, oldStart: start, newStart: new, allDay: isAllDay, calendar: cal)
        start = new
    }

    /// The All-day toggle.
    mutating func setAllDay(_ allDay: Bool, calendar cal: Calendar = .current) {
        guard allDay != isAllDay else { return }
        if allDay {
            let s = cal.startOfDay(for: start)
            // A timed event ending exactly at midnight ends on the previous day (23:00–00:00 is one day).
            let endDay = (end > start && end == cal.startOfDay(for: end))
                ? cal.date(byAdding: .day, value: -1, to: end) ?? end
                : cal.startOfDay(for: end)
            start = s
            end = max(endDay, s)
        } else {
            let s = cal.date(bySettingHour: 9, minute: 0, second: 0, of: start) ?? start
            start = s
            end = s.addingTimeInterval(3600)
        }
        isAllDay = allDay
    }
}
