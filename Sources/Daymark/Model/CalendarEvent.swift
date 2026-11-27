import Foundation

struct GCalendar: Identifiable, Hashable, Sendable {
    let accountEmail: String
    let calendarId: String
    let name: String
    let colorHex: String
    let accessRole: String
    let isPrimary: Bool
    let selectedInGoogle: Bool
    let defaultReminderMinutes: [Int]

    var id: String { "\(accountEmail)|\(calendarId)" }
    var canWrite: Bool { accessRole == "owner" || accessRole == "writer" }

    init(accountEmail: String, dto: CalendarListEntryDTO) {
        self.accountEmail = accountEmail
        self.calendarId = dto.id
        self.name = dto.summaryOverride ?? dto.summary ?? dto.id
        self.colorHex = Palette.calendarColor(dto.backgroundColor)
        self.accessRole = dto.accessRole ?? "reader"
        self.isPrimary = dto.primary ?? false
        self.selectedInGoogle = dto.selected ?? false
        self.defaultReminderMinutes = (dto.defaultReminders ?? [])
            .filter { $0.method == nil || $0.method == "popup" }
            .compactMap(\.minutes)
    }

    static func order(_ a: GCalendar, _ b: GCalendar) -> Bool {
        if a.isPrimary != b.isPrimary { return a.isPrimary }
        let ra = a.accessRole == "owner", rb = b.accessRole == "owner"
        if ra != rb { return ra }
        let byName = a.name.localizedCaseInsensitiveCompare(b.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.calendarId < b.calendarId
    }
}

struct CalendarEvent: Identifiable, Hashable, Sendable {
    static let untitled = "(No title)"

    let id: String
    let eventId: String
    let iCalUID: String
    let calendarKey: String
    let calendarId: String
    let accountEmail: String
    let calendarName: String
    let title: String
    let location: String?
    let notes: String?
    var start: Date
    var end: Date
    let isAllDay: Bool
    let colorHex: String
    let htmlLink: String?
    let meetLink: String?
    let attendees: [AttendeeDTO]
    let recurringEventId: String?
    /// The calendar this copy lives on organised the event (true for events with no guests).
    let isOrganizer: Bool
    /// Title, time, etc. can be changed: requires write access and being the organiser
    /// (or the organiser allowing guests to modify).
    let canEdit: Bool
    /// Removing it from this calendar only needs write access to the calendar.
    let canDelete: Bool
    let selfResponse: String?
    let reminderMinutes: [Int]

    var isDeclined: Bool { selfResponse == "declined" }

    /// The order events are listed in everywhere: by start, then end, then id, so ties never
    /// depend on which account's response arrived first.
    static func chronological(_ a: CalendarEvent, _ b: CalendarEvent) -> Bool {
        (a.start, a.end, a.id) < (b.start, b.end, b.id)
    }
    var isUnconfirmed: Bool { selfResponse == "needsAction" || selfResponse == "tentative" }
    var selfAttendee: AttendeeDTO? { attendees.first { $0.isSelf == true } }
    var canRespond: Bool { canDelete && selfAttendee != nil && selfAttendee?.organizer != true }
    var hasOtherGuests: Bool { attendees.contains { $0.isSelf != true && $0.resource != true } }
    /// Deleting cancels the meeting for its guests only when you organised it and it has guests.
    var deletionNotifiesGuests: Bool { isOrganizer && hasOtherGuests }
    var plainNotes: String { notes.map(Fmt.stripHTML) ?? "" }
    /// All-day events and anything lasting a full day or more go in the all-day lane.
    var spansFullDays: Bool { isAllDay || end.timeIntervalSince(start) >= 86_400 }

    func overlaps(_ i: DateInterval) -> Bool {
        if start == end { return start >= i.start && start < i.end }
        return start < i.end && end > i.start
    }

    func overlaps(day: Date, calendar cal: Calendar = .current) -> Bool { overlaps(cal.dayInterval(day)) }

    init?(dto: EventDTO, calendar: GCalendar, using cal: Calendar = .current) {
        guard dto.status != "cancelled",
              dto.eventType != "workingLocation",
              let s = dto.start, let e = dto.end else { return nil }

        if let d = s.date, let ed = e.date, let sd = RFC3339.parseDay(d, calendar: cal), let edd = RFC3339.parseDay(ed, calendar: cal) {
            start = sd; end = edd; isAllDay = true
        } else if let st = s.dateTime.flatMap(RFC3339.parse), let et = e.dateTime.flatMap(RFC3339.parse) {
            start = st; end = et; isAllDay = false
        } else {
            return nil
        }

        eventId = dto.id
        iCalUID = dto.iCalUID ?? dto.id
        calendarKey = calendar.id
        calendarId = calendar.calendarId
        accountEmail = calendar.accountEmail
        calendarName = calendar.name
        id = "\(calendar.id)|\(dto.id)"
        let t = dto.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = t.isEmpty ? (calendar.accessRole == "freeBusyReader" ? "Busy" : Self.untitled) : t
        location = dto.location
        notes = dto.description
        colorHex = dto.colorId.flatMap { Palette.eventColors[$0] } ?? calendar.colorHex
        htmlLink = dto.htmlLink
        meetLink = dto.hangoutLink
            ?? dto.conferenceData?.entryPoints?.first(where: { $0.entryPointType == "video" })?.uri
        attendees = dto.attendees ?? []
        recurringEventId = dto.recurringEventId
        // Google omits "self": false, so an organizer without self == true is someone else.
        isOrganizer = dto.organizer.map { $0.isSelf == true } ?? true
        canEdit = calendar.canWrite && (isOrganizer || dto.guestsCanModify == true)
        canDelete = calendar.canWrite
        selfResponse = dto.attendees?.first(where: { $0.isSelf == true })?.responseStatus

        if dto.reminders?.useDefault ?? true {
            // The calendar's default reminders apply to timed events only; the API doesn't expose
            // the separate all-day defaults, so all-day events using defaults get none.
            reminderMinutes = isAllDay ? [] : calendar.defaultReminderMinutes
        } else {
            reminderMinutes = (dto.reminders?.overrides ?? [])
                .filter { $0.method == nil || $0.method == "popup" }
                .compactMap(\.minutes)
        }
    }
}
