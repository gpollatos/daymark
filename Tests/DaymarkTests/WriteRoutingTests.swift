import Foundation
import Testing
@testable import Daymark

@MainActor @Suite("Write routing and who gets emailed", .timeLimit(.minutes(1)))
struct WriteRoutingTests {
    private func writes(_ w: World) async -> [RecordedRequest] { await w.requests { $0.method != "GET" } }

    private func edit(_ s: CalendarStore, _ id: String) throws -> EventDraft {
        let e = try #require(s.events.first { $0.id == id })
        s.beginEdit(e)
        return try #require(s.editorDraft)
    }

    // Kills: PATCH/DELETE/RSVP routed to the first (or last) account.
    @Test("PATCH, DELETE and RSVP go to the owning account, for every account",
          arguments: [Fx.alice, Fx.bob, Fx.carol])
    func writesRouteToOwner(email: String) async throws {
        let w = await World()
        let invite: [String: Any] = ["organizer": ["email": "host@x.com"],
                                     "attendees": [["email": "host@x.com", "organizer": true, "responseStatus": "accepted"],
                                                   ["email": email, "self": true, "responseStatus": "needsAction"]]]
        await w.put(email, email, Fx.timed("own", "Mine", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        await w.put(email, email, Fx.timed("inv", "Invite", at(2026, 11, 27, 11), at(2026, 11, 27, 12), invite))
        await w.put(email, email, Fx.timed("del", "Delete me", at(2026, 11, 27, 13), at(2026, 11, 27, 14)))
        let s = await w.start()

        var d = try edit(s, Fx.id(email, email, "own"))
        d.title = "Renamed"
        await w.google.clearRequests()
        try await s.save(d)
        var r = try #require(await writes(w).first)
        #expect(r.method == "PATCH" && r.account == email)
        #expect(await w.google.event(email, email, "own")?["summary"] as? String == "Renamed")

        await w.google.clearRequests()
        await s.respond(try #require(s.events.first { $0.eventId == "inv" }), "accepted")
        r = try #require(await writes(w).first)
        #expect(r.account == email)
        #expect(s.events.first { $0.eventId == "inv" }?.selfResponse == "accepted")

        await w.google.clearRequests()
        await s.delete(try #require(s.events.first { $0.eventId == "del" }), allOccurrences: false)
        r = try #require(await writes(w).first)
        #expect(r.method == "DELETE" && r.account == email)
        #expect(await w.google.event(email, email, "del") == nil)
        #expect(s.errorMessage == nil)
    }

    // Kills: PATCH notify drops hasOtherGuests.
    @Test("An organiser removing every guest still tells them")
    func removeLastGuestNotifies() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("e", "E", at(2026, 12, 1, 9), at(2026, 12, 1, 10), [
            "organizer": ["email": Fx.alice, "self": true],
            "attendees": [["email": Fx.alice, "self": true, "organizer": true], ["email": "dave@x.com"]]]))
        let s = await w.start()
        var d = try edit(s, Fx.id(Fx.alice, Fx.alice, "e"))
        d.guests = ""
        await w.google.clearRequests()
        try await s.save(d)
        let r = try #require(await writes(w).first)
        #expect(r.bodyKeys == ["attendees"])
        #expect(r.query["sendUpdates"] == "all")
        let sent = try #require(r.body?["attendees"] as? [[String: Any]])
        #expect(sent.compactMap { $0["email"] as? String } == [Fx.alice])
    }

    // Kills: PATCH drops location / notes / Meet.
    @Test("Each editable field is sent on its own when it is the only change")
    func patchSingleFields() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("e", "E", at(2026, 12, 1, 9), at(2026, 12, 1, 10), ["location": "Old", "description": "old"]))
        let s = await w.start()
        let id = Fx.id(Fx.alice, Fx.alice, "e")
        for (field, expectedKeys) in [("location", ["location"]), ("notes", ["description"]), ("meet", ["conferenceData"])] {
            var d = try edit(s, id)
            switch field {
            case "location": d.location = "New room"
            case "notes": d.notes = "new notes"
            default: d.addMeet = true
            }
            await w.google.clearRequests()
            try await s.save(d)
            let r = try #require(await writes(w).first, "\(field)")
            #expect(r.bodyKeys == expectedKeys, "\(field)")
            if field == "meet" { #expect(r.query["conferenceDataVersion"] == "1") }
        }
        let server = try #require(await w.google.event(Fx.alice, Fx.alice, "e"))
        #expect(server["location"] as? String == "New room")
        #expect(server["description"] as? String == "new notes")
    }

    // Kills: RSVP failure swallowed.
    @Test("A failed RSVP is reported and the response doesn't change locally")
    func rsvpFailure() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.bob, Fx.timed("inv", "Invite", at(2026, 11, 27, 11), at(2026, 11, 27, 12), [
            "organizer": ["email": "host@x.com"],
            "attendees": [["email": "host@x.com", "organizer": true], ["email": Fx.bob, "self": true, "responseStatus": "needsAction"]]]))
        let s = await w.start()
        await w.google.on({ $0.method == "PATCH" }, always: .status(403, googleError(403, "forbidden", "Not allowed")))
        await s.respond(try #require(s.events.first { $0.eventId == "inv" }), "accepted")
        #expect(s.errorMessage?.contains("Not allowed") == true)
        #expect(s.events.first { $0.eventId == "inv" }?.selfResponse == "needsAction")
    }

    @Test("Hosting a meeting with only a room booked doesn't email anyone")
    func roomOnlyIsNotGuests() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("e", "Focus", at(2026, 12, 1, 9), at(2026, 12, 1, 10), [
            "organizer": ["email": Fx.alice, "self": true],
            "attendees": [["email": Fx.alice, "self": true, "organizer": true],
                          ["email": "room4@resource.calendar.google.com", "resource": true]]]))
        let s = await w.start()
        var d = try edit(s, Fx.id(Fx.alice, Fx.alice, "e"))
        d.title = "Focus time"
        await w.google.clearRequests()
        try await s.save(d)
        #expect(try #require(await writes(w).first).query["sendUpdates"] == "none")
        await w.google.clearRequests()
        await s.delete(try #require(s.events.first { $0.eventId == "e" }), allOccurrences: false)
        #expect(try #require(await writes(w).first).query["sendUpdates"] == "none")
    }

    @Test("The 'guests will be emailed' rule is the same for the editor label and what's sent", arguments: [
        ("new, no guests", "none", false, false, "", false),
        ("new, with guests", "none", false, false, "a@x.com", true),
        ("organiser, has guests", "organizer", true, false, "dave@x.com", true),
        ("organiser removes every guest", "organizer", true, false, "", true),
        ("organiser, no guests", "organizer", false, false, "", false),
        ("organiser adds a first guest", "organizer", false, false, "new@x.com", true),
        ("guest of someone else's meeting", "guest", true, true, "host@x.com", false),
    ] as [(String, String, Bool, Bool, String, Bool)])
    func guestEmailPolicy(name: String, role: String, hadGuests: Bool, canModify: Bool, guests: String, notifies: Bool) {
        var existing: CalendarEvent?
        if role != "none" {
            let organizer: [String: Any] = role == "organizer" ? ["email": Fx.alice, "self": true] : ["email": "host@x.com"]
            var extra: [String: Any] = ["organizer": organizer, "guestsCanModify": canModify]
            if hadGuests {
                let me: [String: Any] = ["email": Fx.alice, "self": true, "organizer": role == "organizer"]
                let other: [String: Any] = ["email": role == "organizer" ? "dave@x.com" : "host@x.com", "organizer": role != "organizer"]
                extra["attendees"] = [me, other]
            }
            existing = event(Fx.timed("e", "E", at(2026, 12, 1, 9), at(2026, 12, 1, 10), extra))
        }
        let d = EventDraft(existing: existing, calendarKey: "k", start: at(2026, 12, 1, 9), end: at(2026, 12, 1, 10), guests: guests)
        #expect(d.savingNotifiesGuests == notifies, "\(name)")
    }

    // Kills: canRespond negatives.
    @Test("RSVP buttons only for invitees on calendars you can change")
    func canRespondNegatives() throws {
        func ev(role: String, selfOrganizer: Bool, invited: Bool) -> CalendarEvent {
            var att: [[String: Any]] = [["email": "host@x.com", "organizer": !selfOrganizer]]
            if invited { att.append(["email": Fx.alice, "self": true, "organizer": selfOrganizer]) }
            return event(Fx.timed("e", "E", at(2026, 12, 1, 9), at(2026, 12, 1, 10), ["attendees": att]),
                         { let dto = try! JSONDecoder().decode(CalendarListEntryDTO.self, from: try! JSONSerialization.data(withJSONObject: Fx.calendar(Fx.alice, role: role).dict)); return GCalendar(accountEmail: Fx.alice, dto: dto) }())
        }
        #expect(ev(role: "owner", selfOrganizer: false, invited: true).canRespond)
        #expect(!ev(role: "reader", selfOrganizer: false, invited: true).canRespond, "read-only calendar")
        #expect(!ev(role: "owner", selfOrganizer: true, invited: true).canRespond, "you organised it")
        #expect(!ev(role: "owner", selfOrganizer: false, invited: false).canRespond, "not invited")
    }

    @Test("Events tied on start and end are always listed in the same order")
    func chronologicalTieBreak() {
        let mk = { (id: String, cal: String) -> CalendarEvent in
            event(Fx.timed(id, id, at(2026, 12, 1, 9), at(2026, 12, 1, 10)),
                  { let dto = try! JSONDecoder().decode(CalendarListEntryDTO.self, from: try! JSONSerialization.data(withJSONObject: Fx.calendar(cal, role: "owner").dict)); return GCalendar(accountEmail: cal, dto: dto) }())
        }
        let a = mk("z", Fx.alice), b = mk("a", Fx.bob), longer = event(Fx.timed("y", "y", at(2026, 12, 1, 9), at(2026, 12, 1, 11)))
        let early = event(Fx.timed("x", "x", at(2026, 12, 1, 8), at(2026, 12, 1, 12)))
        for input in [[a, b, longer, early], [longer, b, early, a], [b, a, early, longer]] {
            #expect(input.sorted(by: CalendarEvent.chronological).map(\.id) == [early.id, a.id, b.id, longer.id])
        }
    }
}
