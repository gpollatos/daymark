import Foundation

// Google Calendar API v3 wire types.

struct CalendarListDTO: Decodable {
    let items: [CalendarListEntryDTO]?
    let nextPageToken: String?
}

struct CalendarListEntryDTO: Decodable, Sendable {
    let id: String
    let summary: String?
    let summaryOverride: String?
    let backgroundColor: String?
    let accessRole: String?
    let primary: Bool?
    let selected: Bool?
    let hidden: Bool?
    let deleted: Bool?
    let defaultReminders: [ReminderDTO]?
}

struct ReminderDTO: Codable, Sendable, Hashable {
    let method: String?
    let minutes: Int?
}

struct RemindersDTO: Decodable, Sendable {
    let useDefault: Bool?
    let overrides: [ReminderDTO]?
}

struct EventsDTO: Decodable {
    let items: [EventDTO]?
    let nextPageToken: String?
}

struct EventTimeDTO: Decodable, Sendable {
    let date: String?
    let dateTime: String?
    let timeZone: String?
}

struct PersonDTO: Decodable, Sendable {
    let email: String?
    let displayName: String?
    let isSelf: Bool?

    enum CodingKeys: String, CodingKey {
        case email, displayName
        case isSelf = "self"
    }
}

struct AttendeeDTO: Codable, Sendable, Hashable {
    var email: String?
    var displayName: String?
    var responseStatus: String?
    var isSelf: Bool?
    var organizer: Bool?
    var optional: Bool?
    var resource: Bool?
    var comment: String?
    var additionalGuests: Int?

    enum CodingKeys: String, CodingKey {
        case email, displayName, responseStatus, organizer, optional, resource, comment, additionalGuests
        case isSelf = "self"
    }
}

struct EntryPointDTO: Decodable, Sendable {
    let entryPointType: String?
    let uri: String?
}

struct ConferenceDTO: Decodable, Sendable {
    let entryPoints: [EntryPointDTO]?
}

struct EventDTO: Decodable, Sendable {
    let id: String
    let iCalUID: String?
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let colorId: String?
    let start: EventTimeDTO?
    let end: EventTimeDTO?
    let htmlLink: String?
    let hangoutLink: String?
    let attendees: [AttendeeDTO]?
    let attendeesOmitted: Bool?
    let organizer: PersonDTO?
    let guestsCanModify: Bool?
    let recurringEventId: String?
    let conferenceData: ConferenceDTO?
    let eventType: String?
    let reminders: RemindersDTO?
}

/// Start/end for writes. Both `date` and `dateTime` are always sent (one as null),
/// so a PATCH can switch an event between all-day and timed.
struct EventTimeWrite: Encodable, Sendable {
    let date: String?
    let dateTime: String?
    let timeZone: String?

    enum CodingKeys: String, CodingKey { case date, dateTime, timeZone }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(dateTime, forKey: .dateTime)
        try c.encodeIfPresent(timeZone, forKey: .timeZone)
    }

    static func allDay(_ d: Date, calendar: Calendar = .current) -> EventTimeWrite {
        EventTimeWrite(date: RFC3339.dayString(d, calendar: calendar), dateTime: nil, timeZone: nil)
    }

    static func timed(_ d: Date, timeZone: TimeZone = .current) -> EventTimeWrite {
        EventTimeWrite(date: nil, dateTime: RFC3339.string(d), timeZone: timeZone.identifier)
    }
}

struct ConferenceCreateDTO: Encodable, Sendable {
    struct Key: Encodable, Sendable { let type: String }
    struct Request: Encodable, Sendable {
        let requestId: String
        let conferenceSolutionKey: Key
    }
    let createRequest: Request

    static func meet() -> ConferenceCreateDTO {
        ConferenceCreateDTO(createRequest: Request(requestId: UUID().uuidString,
                                                   conferenceSolutionKey: Key(type: "hangoutsMeet")))
    }
}

/// Body for insert and PATCH. Fields left nil are omitted, so a PATCH only touches what changed.
struct EventWriteDTO: Encodable, Sendable {
    var summary: String?
    var location: String?
    var description: String?
    var start: EventTimeWrite?
    var end: EventTimeWrite?
    var attendees: [AttendeeDTO]?
    var attendeesOmitted: Bool?
    var recurrence: [String]?
    var conferenceData: ConferenceCreateDTO?

    var isEmpty: Bool {
        summary == nil && location == nil && description == nil && start == nil && end == nil
            && attendees == nil && recurrence == nil && conferenceData == nil
    }
}
