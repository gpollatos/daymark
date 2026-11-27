import Foundation
import Testing
@testable import Daymark

/// Creating, editing, deleting and answering events: the exact request Google receives.
@MainActor @Suite("Writes", .timeLimit(.minutes(1)))
struct WriteTests {
    private func writes(_ w: World) async -> [RecordedRequest] { await w.requests { $0.method != "GET" } }

    private func draft(_ key: String, _ start: Date, _ end: Date, title: String = "Lunch",
                       allDay: Bool = false, guests: String = "") -> EventDraft {
        EventDraft(existing: nil, calendarKey: key, title: title, isAllDay: allDay, start: start, end: end, guests: guests)
    }

    // MARK: Insert

    @Test("A new timed event goes to the chosen account and calendar with an exact payload")
    func insertTimed() async throws {
        let w = await World()
        let s = await w.start()
        await w.google.clearRequests()
        var d = draft(Fx.key(Fx.bob, Fx.bob), at(2026, 12, 3, 12), at(2026, 12, 3, 13), title: "  Lunch  ",
                      guests: "Dave@X.com, dave@x.com; Eve <eve@y.com>")
        d.location = " Cafe "
        d.notes = "Bring slides"
        try await s.save(d)

        let ws = await writes(w)
        #expect(ws.count == 1)
        let r = try #require(ws.first)
        #expect(r.method == "POST")
        #expect(r.rawPath == "/calendar/v3/calendars/bob@work.example/events")
        #expect(r.query == ["sendUpdates": "all"])
        #expect(r.account == Fx.bob)
        #expect(r.headers["Content-Type"] == "application/json")
        #expect(r.bodyKeys == ["attendees", "description", "end", "location", "start", "summary"])
        #expect(r.body?["summary"] as? String == "Lunch")
        #expect(r.body?["location"] as? String == "Cafe")
        let start = try #require(r.body?["start"] as? [String: Any])
        #expect(start["dateTime"] as? String == "2026-12-03T17:00:00Z")
        #expect(start["timeZone"] as? String == "America/New_York")
        #expect(start["date"] is NSNull)
        #expect((r.body?["end"] as? [String: Any])?["dateTime"] as? String == "2026-12-03T18:00:00Z")
        let attendees = try #require(r.body?["attendees"] as? [[String: Any]])
        #expect(attendees.map { $0["email"] as? String } == ["dave@x.com", "eve@y.com"])
        #expect(attendees.allSatisfy { $0.keys.sorted() == ["email"] })

        #expect(w.defaults.string(forKey: CalendarStore.Keys.lastCalendar) == Fx.key(Fx.bob, Fx.bob))
        #expect(s.events.contains { $0.accountEmail == Fx.bob && $0.title == "Lunch" })
    }

    @Test("All-day events send dates with an exclusive end, across DST too",
          arguments: [(at(2026, 12, 24), at(2026, 12, 26), "2026-12-24", "2026-12-27"),
                      (at(2026, 12, 24), at(2026, 12, 24), "2026-12-24", "2026-12-25"),
                      (at(2027, 3, 13), at(2027, 3, 15), "2027-03-13", "2027-03-16"),
                      (at(2026, 10, 31), at(2026, 11, 1), "2026-10-31", "2026-11-02")])
    func insertAllDay(first: Date, last: Date, startDate: String, endDate: String) async throws {
        let w = await World()
        let s = await w.start()
        await w.google.clearRequests()
        try await s.save(draft(Fx.key(Fx.alice, Fx.alice), first, last, allDay: true))
        let r = try #require(await writes(w).first)
        let start = try #require(r.body?["start"] as? [String: Any])
        let end = try #require(r.body?["end"] as? [String: Any])
        #expect(start["date"] as? String == startDate)
        #expect(end["date"] as? String == endDate)
        #expect(start["dateTime"] is NSNull && end["dateTime"] is NSNull)
        #expect(start["timeZone"] == nil)
    }

    @Test("Without guests nobody is emailed and no attendee list is sent")
    func insertWithoutGuests() async throws {
        let w = await World()
        let s = await w.start()
        await w.google.clearRequests()
        try await s.save(draft(Fx.key(Fx.alice, Fx.alice), at(2026, 12, 3, 12), at(2026, 12, 3, 13)))
        let r = try #require(await writes(w).first)
        #expect(r.query == ["sendUpdates": "none"])
        #expect(r.body?["attendees"] == nil)
        #expect(r.body?["recurrence"] == nil)
        #expect(r.body?["conferenceData"] == nil)
    }

    @Test("Repeat choices become the matching RRULE", arguments: RepeatRule.allCases)
    func insertRepeat(rule: RepeatRule) async throws {
        let w = await World()
        let s = await w.start()
        await w.google.clearRequests()
        var d = draft(Fx.key(Fx.alice, Fx.alice), at(2026, 12, 3, 12), at(2026, 12, 3, 13))
        d.repeatRule = rule
        try await s.save(d)
        let r = try #require(await writes(w).first)
        let expected: [String]? = switch rule {
        case .none: nil
        case .daily: ["RRULE:FREQ=DAILY"]
        case .weekdays: ["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"]
        case .weekly: ["RRULE:FREQ=WEEKLY"]
        case .monthly: ["RRULE:FREQ=MONTHLY"]
        case .yearly: ["RRULE:FREQ=YEARLY"]
        }
        #expect(r.body?["recurrence"] as? [String] == expected)
    }

    @Test("Adding Google Meet sends a conference request and the link shows after saving")
    func insertWithMeet() async throws {
        let w = await World()
        let s = await w.start()
        await w.google.clearRequests()
        var d = draft(Fx.key(Fx.carol, Fx.carol), at(2026, 12, 3, 12), at(2026, 12, 3, 13), title: "Call")
        d.addMeet = true
        try await s.save(d)
        let r = try #require(await writes(w).first)
        #expect(r.query == ["sendUpdates": "none", "conferenceDataVersion": "1"])
        let create = try #require((r.body?["conferenceData"] as? [String: Any])?["createRequest"] as? [String: Any])
        #expect((create["conferenceSolutionKey"] as? [String: Any])?["type"] as? String == "hangoutsMeet")
        #expect(UUID(uuidString: create["requestId"] as? String ?? "") != nil)
        #expect(s.events.first { $0.title == "Call" }?.meetLink?.hasPrefix("https://meet.google.com/") == true)
    }

    @Test("Invalid drafts are rejected before anything is sent")
    func validation() async throws {
        let w = await World()
        let s = await w.start()
        await w.google.clearRequests()
        await #expect(throws: AppError.self) {
            try await s.save(draft(Fx.key(Fx.alice, Fx.alice), at(2026, 12, 3, 13), at(2026, 12, 3, 12)))
        }
        await #expect(throws: AppError.self) {
            try await s.save(draft(Fx.key(Fx.alice, Fx.alice), at(2026, 12, 3), at(2026, 12, 2), allDay: true))
        }
        await #expect(throws: AppError.self) {
            try await s.save(draft("nobody@x.com|nothing", at(2026, 12, 3, 12), at(2026, 12, 3, 13)))
        }
        #expect(await writes(w).isEmpty)
        // A zero-length event is allowed.
        try await s.save(draft(Fx.key(Fx.alice, Fx.alice), at(2026, 12, 3, 12), at(2026, 12, 3, 12)))
        #expect(await writes(w).count == 1)
    }

    // MARK: Patch

    private func organizerEvent(_ w: World) async -> JSON {
        let e = Fx.timed("ev1", "Planning", at(2026, 11, 30, 10), at(2026, 11, 30, 11), [
            "description": "<b>Agenda</b><br>1. Budget &amp; hiring",
            "location": "Room 4",
            "organizer": ["email": Fx.alice, "self": true],
            "attendees": [["email": Fx.alice, "self": true, "organizer": true, "responseStatus": "accepted"],
                          ["email": "dave@x.com", "responseStatus": "accepted", "comment": "on my way"],
                          ["email": "room4@resource.calendar.google.com", "resource": true, "responseStatus": "accepted"]],
        ])
        await w.put(Fx.alice, Fx.family, e)
        return e
    }

    private func editDraft(_ s: CalendarStore, _ id: String) throws -> EventDraft {
        let e = try #require(s.events.first { $0.id == id })
        s.beginEdit(e)
        return try #require(s.editorDraft)
    }

    @Test("Changing only the title sends only the title")
    func patchTitleOnly() async throws {
        let w = await World()
        _ = await organizerEvent(w)
        let s = await w.start()
        var d = try editDraft(s, Fx.id(Fx.alice, Fx.family, "ev1"))
        #expect(d.notes == "Agenda\n1. Budget & hiring", "the editor shows plain text")
        #expect(d.guests == "dave@x.com")
        d.title = "Planning v2"
        await w.google.clearRequests()
        try await s.save(d)
        let r = try #require(await writes(w).first)
        #expect(r.method == "PATCH")
        #expect(r.rawPath == "/calendar/v3/calendars/fam123@group.calendar.google.com/events/ev1")
        #expect(r.account == Fx.alice)
        #expect(r.bodyKeys == ["summary"])
        #expect(r.query == ["sendUpdates": "all"], "the organiser tells guests about changes")
        // The server copy keeps its HTML description and attendees.
        let server = try #require(await w.google.event(Fx.alice, Fx.family, "ev1"))
        #expect(server["description"] as? String == "<b>Agenda</b><br>1. Budget &amp; hiring")
        #expect((server["attendees"] as? [[String: Any]])?.count == 3)
    }

    @Test("Saving without changes sends nothing", arguments: ["timed", "allday", "untitled", "html"])
    func noChangeNoRequest(kind: String) async throws {
        let w = await World()
        let e: JSON = switch kind {
        case "timed": Fx.timed("x", "Timed", at(2026, 11, 30, 10, 0, 0), at(2026, 11, 30, 10, 45))
        case "allday": Fx.allDay("x", "Trip", "2026-11-30", "2026-12-03")
        case "untitled": Fx.timed("x", "", at(2026, 11, 30, 10), at(2026, 11, 30, 11))
        default: Fx.timed("x", "Notes", at(2026, 11, 30, 10), at(2026, 11, 30, 11),
                          ["description": "<p>Hello <a href=\"https://x.io\">link</a></p>"])
        }
        await w.put(Fx.alice, Fx.alice, e)
        let s = await w.start()
        let d = try editDraft(s, Fx.id(Fx.alice, Fx.alice, "x"))
        await w.google.clearRequests()
        try await s.save(d)
        #expect(await writes(w).isEmpty)
    }

    @Test("Time changes send both start and end, switching between all-day and timed correctly")
    func patchTimes() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("t", "Timed", at(2026, 11, 30, 10), at(2026, 11, 30, 11)))
        await w.put(Fx.alice, Fx.alice, Fx.allDay("a", "Trip", "2026-12-01", "2026-12-03"))
        let s = await w.start()

        // Move by an hour.
        var d = try editDraft(s, Fx.id(Fx.alice, Fx.alice, "t"))
        d.setStart(at(2026, 11, 30, 11), calendar: NY)
        await w.google.clearRequests()
        try await s.save(d)
        var r = try #require(await writes(w).first)
        #expect(r.bodyKeys == ["end", "start"])
        #expect((r.body?["start"] as? [String: Any])?["dateTime"] as? String == "2026-11-30T16:00:00Z")
        #expect((r.body?["end"] as? [String: Any])?["dateTime"] as? String == "2026-11-30T17:00:00Z")

        // Timed → all-day.
        d = try editDraft(s, Fx.id(Fx.alice, Fx.alice, "t"))
        d.setAllDay(true, calendar: NY)
        await w.google.clearRequests()
        try await s.save(d)
        r = try #require(await writes(w).first)
        #expect((r.body?["start"] as? [String: Any])?["date"] as? String == "2026-11-30")
        #expect((r.body?["start"] as? [String: Any])?["dateTime"] is NSNull)
        #expect((r.body?["end"] as? [String: Any])?["date"] as? String == "2026-12-01")

        // All-day (Dec 1–2 inclusive) → timed.
        d = try editDraft(s, Fx.id(Fx.alice, Fx.alice, "a"))
        #expect(d.end == at(2026, 12, 2), "editor shows the inclusive last day")
        d.setAllDay(false, calendar: NY)
        await w.google.clearRequests()
        try await s.save(d)
        r = try #require(await writes(w).first)
        #expect((r.body?["start"] as? [String: Any])?["date"] is NSNull)
        #expect((r.body?["start"] as? [String: Any])?["dateTime"] as? String == "2026-12-01T14:00:00Z")

        // Changing only the end still sends both.
        await w.put(Fx.alice, Fx.alice, Fx.timed("u", "U", at(2026, 11, 30, 10), at(2026, 11, 30, 11)))
        await s.refresh()
        d = try editDraft(s, Fx.id(Fx.alice, Fx.alice, "u"))
        d.end = at(2026, 11, 30, 12)
        await w.google.clearRequests()
        try await s.save(d)
        #expect(try #require(await writes(w).first).bodyKeys == ["end", "start"])
    }

    @Test("Guest edits keep existing attendee records and responses; only organisers can edit guests")
    func patchGuests() async throws {
        let w = await World()
        _ = await organizerEvent(w)
        // An invite organised by someone else who lets guests modify it.
        await w.put(Fx.alice, Fx.alice, Fx.timed("inv", "Offsite", at(2026, 12, 1, 9), at(2026, 12, 1, 17), [
            "organizer": ["email": "host@x.com"], "guestsCanModify": true,
            "attendees": [["email": "host@x.com", "organizer": true, "responseStatus": "accepted"],
                          ["email": Fx.alice, "self": true, "responseStatus": "accepted"]],
        ]))
        let s = await w.start()

        var d = try editDraft(s, Fx.id(Fx.alice, Fx.family, "ev1"))
        d.guests = "dave@x.com, Erin <erin@x.com>"
        await w.google.clearRequests()
        try await s.save(d)
        var r = try #require(await writes(w).first)
        #expect(r.bodyKeys == ["attendees"])
        var sent = try #require(r.body?["attendees"] as? [[String: Any]])
        #expect(sent.compactMap { $0["email"] as? String } == [Fx.alice, "dave@x.com", "room4@resource.calendar.google.com", "erin@x.com"])
        #expect(sent.first { $0["email"] as? String == "dave@x.com" }?["comment"] as? String == "on my way")
        #expect(sent.first { $0["email"] as? String == "dave@x.com" }?["responseStatus"] as? String == "accepted")

        d = try editDraft(s, Fx.id(Fx.alice, Fx.family, "ev1"))
        d.guests = "erin@x.com"
        await w.google.clearRequests()
        try await s.save(d)
        r = try #require(await writes(w).first)
        sent = try #require(r.body?["attendees"] as? [[String: Any]])
        #expect(sent.compactMap { $0["email"] as? String } == [Fx.alice, "room4@resource.calendar.google.com", "erin@x.com"],
                "Dave removed; self and the room stay")

        // Not the organiser: guest changes are ignored, the title still saves, nobody is emailed.
        d = try editDraft(s, Fx.id(Fx.alice, Fx.alice, "inv"))
        d.guests = "someone@x.com"
        d.title = "Offsite (Alice)"
        await w.google.clearRequests()
        try await s.save(d)
        r = try #require(await writes(w).first)
        #expect(r.bodyKeys == ["summary"])
        #expect(r.query["sendUpdates"] == "none")
    }

    struct NotifyCase: Sendable, CustomTestStringConvertible {
        let name: String
        let organizer: Bool
        let existingGuests: Bool
        let addGuest: Bool
        let expected: String
        var testDescription: String { name }
    }

    @Test("Who gets emailed about an edit", arguments: [
        NotifyCase(name: "organiser with guests", organizer: true, existingGuests: true, addGuest: false, expected: "all"),
        NotifyCase(name: "organiser, no guests", organizer: true, existingGuests: false, addGuest: false, expected: "none"),
        NotifyCase(name: "organiser adds first guest", organizer: true, existingGuests: false, addGuest: true, expected: "all"),
        NotifyCase(name: "guest who may modify", organizer: false, existingGuests: true, addGuest: false, expected: "none"),
    ])
    func sendUpdatesOnPatch(c: NotifyCase) async throws {
        let w = await World()
        let organizer: [String: Any] = c.organizer ? ["email": Fx.alice, "self": true] : ["email": "host@x.com"]
        var extra: [String: Any] = ["organizer": organizer, "guestsCanModify": true]
        if c.existingGuests {
            let me: [String: Any] = ["email": Fx.alice, "self": true, "organizer": c.organizer, "responseStatus": "accepted"]
            let other: [String: Any] = ["email": c.organizer ? "dave@x.com" : "host@x.com",
                                        "responseStatus": "accepted", "organizer": !c.organizer]
            extra["attendees"] = [me, other]
        }
        await w.put(Fx.alice, Fx.alice, Fx.timed("e", "E", at(2026, 12, 1, 9), at(2026, 12, 1, 10), extra))
        let s = await w.start()
        var d = try editDraft(s, Fx.id(Fx.alice, Fx.alice, "e"))
        d.title = "E2"
        if c.addGuest { d.guests = "new@x.com" }
        await w.google.clearRequests()
        try await s.save(d)
        #expect(try #require(await writes(w).first).query["sendUpdates"] == c.expected)
    }

    // MARK: Delete

    @Test("Deleting one occurrence or the whole series targets the right ids in the right account")
    func deleteSingleVsSeries() async throws {
        let w = await World()
        for (acct, cal) in [(Fx.alice, Fx.alice), (Fx.carol, Fx.carol)] {
            for day in [26, 27, 28] {
                await w.put(acct, cal, Fx.timed("abc_202611\(day)T150000Z", "Gym", at(2026, 11, day, 10), at(2026, 11, day, 11),
                                                ["recurringEventId": "abc"]))
            }
        }
        let s = await w.start()
        let first = try #require(s.events.first { $0.id == Fx.id(Fx.alice, Fx.alice, "abc_20261126T150000Z") })

        await w.google.clearRequests()
        await s.delete(first, allOccurrences: false)
        var r = try #require(await writes(w).first)
        #expect(r.method == "DELETE")
        #expect(r.rawPath == "/calendar/v3/calendars/alice@gmail.com/events/abc_20261126T150000Z")
        #expect(r.query == ["sendUpdates": "none"])
        #expect(s.events.filter { $0.recurringEventId == "abc" && $0.accountEmail == Fx.alice }.count == 2)

        let second = try #require(s.events.first { $0.id == Fx.id(Fx.alice, Fx.alice, "abc_20261127T150000Z") })
        // Carol's calendar can't be reloaded right now, so what's on screen for her is what we kept locally.
        await w.google.on({ $0.isEventsList && $0.account == Fx.carol }, always: .status(503, googleError(503, "backendError")))
        await w.google.clearRequests()
        await s.delete(second, allOccurrences: true)
        r = try #require(await writes(w).first)
        #expect(r.rawPath == "/calendar/v3/calendars/alice@gmail.com/events/abc")
        #expect(!s.events.contains { $0.recurringEventId == "abc" && $0.accountEmail == Fx.alice })
        #expect(s.events.filter { $0.recurringEventId == "abc" && $0.accountEmail == Fx.carol }.count == 3,
                "the same series id in another account is untouched")
    }

    @Test("Delete: an organiser cancelling a meeting emails guests; removing an invite doesn't")
    func deleteSendUpdates() async throws {
        let w = await World()
        _ = await organizerEvent(w)
        await w.put(Fx.alice, Fx.alice, Fx.timed("inv", "Invite", at(2026, 12, 1, 9), at(2026, 12, 1, 10), [
            "organizer": ["email": "host@x.com"],
            "attendees": [["email": "host@x.com", "organizer": true], ["email": Fx.alice, "self": true]],
        ]))
        let s = await w.start()
        await w.google.clearRequests()
        await s.delete(try #require(s.events.first { $0.eventId == "ev1" }), allOccurrences: false)
        await s.delete(try #require(s.events.first { $0.eventId == "inv" }), allOccurrences: false)
        let ws = await writes(w)
        #expect(ws.map { $0.query["sendUpdates"] } == ["all", "none"])
    }

    @Test("A failed delete reports the error and the event stays")
    func deleteFailure() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.bob, Fx.timed("b1", "Keep", at(2026, 12, 1, 9), at(2026, 12, 1, 10)))
        let s = await w.start()
        await w.google.on({ $0.method == "DELETE" }, always: .status(403, googleError(403, "forbidden", "You need writer access")))
        await s.delete(try #require(s.events.first { $0.eventId == "b1" }), allOccurrences: false)
        #expect(s.errorMessage?.contains("You need writer access") == true)
        #expect(w.eventIds.contains(Fx.id(Fx.bob, Fx.bob, "b1")))
        #expect(await w.requests { $0.method == "DELETE" }.count == 1, "403 forbidden isn't retried")
    }

    @Test("Deleting an event that's already gone (410) counts as success")
    func deleteGone() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.bob, Fx.timed("b1", "Gone", at(2026, 12, 1, 9), at(2026, 12, 1, 10)))
        let s = await w.start()
        await w.google.on({ $0.method == "DELETE" }, [.status(410, googleError(410, "deleted"))])
        await w.google.removeEvent(Fx.bob, Fx.bob, "b1")
        await s.delete(try #require(s.events.first { $0.eventId == "b1" }), allOccurrences: false)
        #expect(s.errorMessage == nil)
        #expect(!w.eventIds.contains(Fx.id(Fx.bob, Fx.bob, "b1")))
    }

    // MARK: RSVP

    @Test("RSVP sends only your own response, with attendeesOmitted, to the right account",
          arguments: ["accepted", "declined", "tentative"])
    func rsvpPayload(status: String) async throws {
        let w = await World()
        let me = "alice.alias@gmail.com"   // the attendee email differs from the account email
        await w.put(Fx.alice, Fx.alice, Fx.timed("inv", "All hands", at(2026, 11, 27, 15), at(2026, 11, 27, 16), [
            "organizer": ["email": "ceo@x.com"],
            "attendees": [["email": "ceo@x.com", "organizer": true, "responseStatus": "accepted"],
                          ["email": me, "self": true, "responseStatus": "needsAction"],
                          ["email": "a@x.com", "responseStatus": "accepted"],
                          ["email": "b@x.com", "responseStatus": "declined"],
                          ["email": "c@x.com", "responseStatus": "tentative"]],
        ]))
        let s = await w.start()
        let e = try #require(s.events.first { $0.eventId == "inv" })
        #expect(e.canRespond)

        await w.google.clearRequests()
        await s.respond(e, status)
        let r = try #require(await writes(w).first)
        #expect(r.method == "PATCH")
        #expect(r.rawPath == "/calendar/v3/calendars/alice@gmail.com/events/inv")
        #expect(r.query == ["sendUpdates": "all"])
        #expect(r.bodyKeys == ["attendees", "attendeesOmitted"])
        #expect(r.body?["attendeesOmitted"] as? Bool == true)
        let sent = try #require(r.body?["attendees"] as? [[String: Any]])
        #expect(sent.count == 1)
        #expect(sent[0].keys.sorted() == ["email", "responseStatus"])
        #expect(sent[0]["email"] as? String == me)
        #expect(sent[0]["responseStatus"] as? String == status)

        let after = try #require(s.events.first { $0.eventId == "inv" })
        #expect(after.selfResponse == status)
        #expect(after.attendees.count == 5, "other guests untouched")
        let planned = Notifier.plan(try #require(w.notifier.last), now: w.clock.now).map(\.eventId)
        #expect(planned.contains(after.id) == (status != "declined"), "declined meetings stop reminding")
    }

    @Test("No RSVP request for an event you're not invited to")
    func rsvpWithoutSelf() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("own", "Mine", at(2026, 11, 27, 15), at(2026, 11, 27, 16)))
        let s = await w.start()
        await w.google.clearRequests()
        await s.respond(try #require(s.events.first { $0.eventId == "own" }), "accepted")
        #expect(await writes(w).isEmpty)
    }

    // MARK: Errors and follow-up

    @Test("Insert errors: Google's message is surfaced; 500 isn't retried; 429 is retried without duplicating")
    func insertErrors() async throws {
        let w = await World()
        let s = await w.start()
        let key = Fx.key(Fx.alice, Fx.alice)

        await w.google.on({ $0.method == "POST" }, [.status(403, googleError(403, "forbidden", "Forbidden for reader"))])
        await #expect(throws: APIError.self) { try await s.save(draft(key, at(2026, 12, 3, 12), at(2026, 12, 3, 13))) }

        await w.google.clearRequests()
        await w.google.on({ $0.method == "POST" }, [.status(500, googleError(500, "backendError"))])
        await #expect(throws: APIError.self) { try await s.save(draft(key, at(2026, 12, 3, 12), at(2026, 12, 3, 13))) }
        #expect(await writes(w).count == 1, "a POST that may have succeeded is never repeated")

        await w.google.clearRequests()
        await w.google.on({ $0.method == "POST" }, [.status(429, googleError(429, "rateLimitExceeded"))])
        try await s.save(draft(key, at(2026, 12, 3, 12), at(2026, 12, 3, 13), title: "Once"))
        #expect(await writes(w).count == 2)
        #expect(await w.google.inserts == 1)
        #expect(s.events.filter { $0.title == "Once" }.count == 1)
    }

    @Test("Saving an event far away jumps there; saving to a hidden calendar shows it")
    func afterSaveNavigation() async throws {
        let w = await World()
        let s = await w.start()
        let fam = try #require(s.calendar(key: Fx.key(Fx.alice, Fx.family)))
        s.setVisible(fam, false)
        try await s.save(draft(fam.id, at(2027, 3, 18, 9), at(2027, 3, 18, 10), title: "Spring"))
        await w.settle()
        #expect(s.selectedDate == at(2027, 3, 18))
        #expect(s.loadedWindow?.covers(s.visibleRange) == true)
        #expect(s.isVisible(fam))
        #expect(s.visibleEvents.contains { $0.title == "Spring" })
    }

    @Test("Saving an edit after its account was removed fails cleanly")
    func saveAfterAccountRemoved() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.bob, Fx.timed("b1", "B", at(2026, 12, 1, 9), at(2026, 12, 1, 10)))
        let s = await w.start()
        var d = try editDraft(s, Fx.id(Fx.bob, Fx.bob, "b1"))
        s.removeAccount(Fx.bob)
        d.title = "changed"
        await w.google.clearRequests()
        await #expect(throws: AppError.self) { try await s.save(d) }
        #expect(await writes(w).isEmpty)
    }
}
