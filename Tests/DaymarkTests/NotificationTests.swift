import Foundation
import Testing
@testable import Daymark

private func gcal(_ email: String = Fx.alice, _ id: String = Fx.alice, role: String = "owner", reminders: [Int] = []) -> GCalendar {
    let dto = try! JSONDecoder().decode(CalendarListEntryDTO.self, from: try! JSONSerialization.data(
        withJSONObject: Fx.calendar(id, role: role, reminders: reminders).dict))
    return GCalendar(accountEmail: email, dto: dto)
}

func event(_ json: JSON, _ cal: GCalendar? = nil, calendar: Calendar = NY) -> CalendarEvent {
    let dto = try! JSONDecoder().decode(EventDTO.self, from: try! JSONSerialization.data(withJSONObject: json.dict))
    return CalendarEvent(dto: dto, calendar: cal ?? gcal(), using: calendar)!
}

private func reminders(_ m: [Int]) -> [String: Any] {
    ["reminders": ["useDefault": false, "overrides": m.map { ["method": "popup", "minutes": $0] }]]
}

@Suite("Reminder planning", .timeLimit(.minutes(1)))
struct ReminderPlanTests {
    @Test("Each distinct reminder fires at start minus its minutes; ones less than 5 s away are skipped")
    func basics() {
        let e = event(Fx.timed("e", "Standup", T0.addingTimeInterval(3600), T0.addingTimeInterval(4500), reminders([10, 10, 5])))
        let plan = Notifier.plan([e], now: T0)
        #expect(plan.map(\.id) == ["\(e.id)#10", "\(e.id)#5"])
        #expect(plan.map(\.fire) == [T0.addingTimeInterval(3000), T0.addingTimeInterval(3300)])
        #expect(plan.allSatisfy { $0.title == "Standup" })

        let edge = event(Fx.timed("x", "Edge", T0.addingTimeInterval(605), T0.addingTimeInterval(900), reminders([10])))
        #expect(Notifier.plan([edge], now: T0).isEmpty, "fires exactly 5 s from now: too late")
        let justIn = event(Fx.timed("y", "In", T0.addingTimeInterval(606), T0.addingTimeInterval(900), reminders([10])))
        #expect(Notifier.plan([justIn], now: T0).count == 1)
        let started = event(Fx.timed("z", "Started", T0.addingTimeInterval(-60), T0.addingTimeInterval(900), reminders([0, 10])))
        #expect(Notifier.plan([started], now: T0).isEmpty)
    }

    @Test("Declined events get no reminders; all-day events use explicit overrides only")
    func declinedAndAllDay() {
        let declined = event(Fx.timed("d", "Nope", T0.addingTimeInterval(7200), T0.addingTimeInterval(9000), [
            "attendees": [["email": Fx.alice, "self": true, "responseStatus": "declined"]],
            "reminders": ["useDefault": true],
        ]), gcal(reminders: [10]))
        #expect(Notifier.plan([declined], now: T0).isEmpty)

        let allDayOverride = event(Fx.allDay("a", "Birthday", "2026-11-28", "2026-11-29", reminders([1440])))
        #expect(Notifier.plan([allDayOverride], now: T0).map(\.fire) == [at(2026, 11, 27)])
        let allDayDefaults = event(Fx.allDay("b", "Trip", "2026-11-28", "2026-11-29"), gcal(reminders: [10]))
        #expect(allDayDefaults.reminderMinutes.isEmpty)
    }

    @Test("A meeting in two accounts is notified once, at every time either copy asks for")
    func crossAccountDedupe() {
        let start = T0.addingTimeInterval(7200)
        func copy(_ email: String, _ m: [Int], response: String = "accepted", uid: String = "m@x.com", at s: Date? = nil) -> CalendarEvent {
            let begin: Date = s ?? start
            var extra: [String: Any] = reminders(m)
            extra["iCalUID"] = uid
            let me: [String: Any] = ["email": email, "self": true, "responseStatus": response]
            extra["attendees"] = [me]
            return event(Fx.timed("m-\(email.prefix(1))", "Sync", begin, begin.addingTimeInterval(1800), extra), gcal(email, email))
        }
        let a = copy(Fx.alice, [10]), b = copy(Fx.bob, [30])
        var plan = Notifier.plan([b, a], now: T0)
        #expect(plan.map(\.minutes) == [30, 10])
        #expect(Set(plan.map(\.eventId)) == [a.id], "one deterministic lead copy")
        #expect(Notifier.plan([a, b], now: T0) == plan, "independent of input order")

        plan = Notifier.plan([copy(Fx.alice, [10], response: "declined"), b], now: T0)
        #expect(plan.map(\.eventId) == [b.id] && plan.map(\.minutes) == [30])

        let later = copy(Fx.bob, [10], at: start.addingTimeInterval(86400))
        #expect(Notifier.plan([a, later], now: T0).count == 2, "another occurrence of the series")
        #expect(Notifier.plan([a, copy(Fx.bob, [10], uid: "other@x.com")], now: T0).count == 2)
    }

    @Test("At most 60 reminders, the soonest ones, in a stable order")
    func cap() {
        var events: [CalendarEvent] = []
        for i in (0..<100).reversed() {
            let start: Date = T0.addingTimeInterval(Double(3600 + i * 60))
            events.append(event(Fx.timed("e\(i)", "E\(i)", start, start.addingTimeInterval(3600), reminders([10]))))
        }
        let plan = Notifier.plan(events, now: T0)
        #expect(plan.count == 60)
        #expect(plan.map(\.title) == (0..<60).map { "E\($0)" })
        #expect(Notifier.plan(events.shuffled(), now: T0) == plan)
    }
}

@MainActor @Suite("Reminder scheduling in the store", .timeLimit(.minutes(1)))
struct ReminderStoreTests {
    @Test("Only visible calendars' events within the next 8 days are handed to the notifier")
    func horizonAndVisibility() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("in", "In", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        await w.put(Fx.alice, Fx.holiday, Fx.allDay("hol", "Hidden", "2026-11-27", "2026-11-28"))
        await w.put(Fx.bob, Fx.bob, Fx.timed("edge", "Edge", T0.addingTimeInterval(8 * 86400 - 1), T0.addingTimeInterval(8 * 86400 + 1800)))
        await w.put(Fx.bob, Fx.bob, Fx.timed("out", "Out", T0.addingTimeInterval(8 * 86400 + 1), T0.addingTimeInterval(8 * 86400 + 1800)))
        await w.put(Fx.carol, Fx.carol, Fx.timed("now", "Ongoing", T0.addingTimeInterval(-3600), T0.addingTimeInterval(3600)))
        await w.start()
        #expect(w.notifier.lastIds == [Fx.id(Fx.alice, Fx.alice, "in"), Fx.id(Fx.bob, Fx.bob, "edge"), Fx.id(Fx.carol, Fx.carol, "now")])
        // Bob's calendar default (30 min) applies to Bob's event; the ongoing one has nothing left to fire.
        let plan = Notifier.plan(w.notifier.last!, now: T0)
        #expect(plan.contains { $0.eventId == Fx.id(Fx.bob, Fx.bob, "edge") && $0.minutes == 30 })
        #expect(plan.contains { $0.eventId == Fx.id(Fx.alice, Fx.alice, "in") && $0.minutes == 10 })
        #expect(!plan.contains { $0.eventId == Fx.id(Fx.carol, Fx.carol, "now") })
    }

    @Test("One failing account keeps its reminders while the other accounts' reminders update")
    func failingAccountDoesNotFreezeOthers() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.bob, Fx.timed("b1", "Bob's", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        await w.put(Fx.alice, Fx.alice, Fx.timed("old", "Old", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()
        await w.oauth.fail(Fx.bob, .invalidGrant)
        w.clock.advance(7200)
        await w.google.removeEvent(Fx.alice, Fx.alice, "old")
        await w.put(Fx.alice, Fx.alice, Fx.timed("new", "New", at(2026, 11, 28, 9), at(2026, 11, 28, 10)))
        await s.refresh()
        #expect(w.notifier.lastIds.contains(Fx.id(Fx.alice, Fx.alice, "new")))
        #expect(!w.notifier.lastIds.contains(Fx.id(Fx.alice, Fx.alice, "old")), "deleted events stop reminding")
        #expect(w.notifier.lastIds.contains(Fx.id(Fx.bob, Fx.bob, "b1")), "the failing account keeps what it had")
    }

    @Test("When the horizon isn't loaded, reminders are fetched separately and failures keep old reminders")
    func separateFetch() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.team, Fx.timed("t1", "Team", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()
        s.selectedDate = at(2027, 11, 15)
        await w.settle()
        await w.google.clearRequests()
        await s.refresh()
        let horizon = await w.requests { $0.isEventsList && $0.query["timeMin"] == RFC3339.string(T0) }
        #expect(horizon.count == 6, "visible calendars only (holiday is hidden)")
        #expect(horizon.allSatisfy { $0.query["timeMax"] == RFC3339.string(T0.addingTimeInterval(8 * 86400)) })
        #expect(!horizon.contains { $0.calendarId == Fx.holiday })
        #expect(w.notifier.lastIds == [Fx.id(Fx.bob, Fx.team, "t1")])

        await w.google.on({ $0.isEventsList && $0.calendarId == Fx.team }, always: .status(500, googleError(500, "backendError")))
        await s.refresh()
        #expect(w.notifier.lastIds == [Fx.id(Fx.bob, Fx.team, "t1")])
    }

    @Test("Showing or hiding a calendar updates reminders without network")
    func visibilityToggle() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.team, Fx.timed("t1", "Team", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()
        #expect(w.notifier.lastIds.contains(Fx.id(Fx.bob, Fx.team, "t1")))
        await w.google.clearRequests()
        s.setVisible(try #require(s.calendar(key: Fx.key(Fx.bob, Fx.team))), false)
        await w.settle()
        #expect(!w.notifier.lastIds.contains(Fx.id(Fx.bob, Fx.team, "t1")))
        s.setVisible(try #require(s.calendar(key: Fx.key(Fx.bob, Fx.team))), true)
        await w.settle()
        #expect(w.notifier.lastIds.contains(Fx.id(Fx.bob, Fx.team, "t1")))
        #expect(await w.requests().isEmpty)
    }

    @Test("Saving, deleting and answering events update reminders")
    func mutationsReschedule() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("x", "X", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()
        try await s.save(EventDraft(existing: nil, calendarKey: Fx.key(Fx.carol, Fx.carol), title: "Fresh",
                                    start: at(2026, 11, 28, 9), end: at(2026, 11, 28, 10)))
        #expect(w.notifier.last?.contains { $0.title == "Fresh" } == true)
        await s.delete(try #require(s.events.first { $0.eventId == "x" }), allOccurrences: false)
        #expect(w.notifier.last?.contains { $0.eventId == "x" } == false)
    }

    @Test("An older reminder update finishing late never overwrites a newer one")
    func overlappingReschedules() async throws {
        let w = await World()
        let s = await w.start()
        s.selectedDate = at(2027, 11, 15) // horizon no longer loaded: reminders need their own fetch
        await w.settle()
        let gate = Gate()
        let horizonQuery = RFC3339.string(T0)
        await w.google.on({ $0.isEventsList && $0.query["timeMin"] == horizonQuery }, Array(repeating: .gate(gate), count: 6))
        let fam = try #require(s.calendar(key: Fx.key(Fx.alice, Fx.family)))
        s.setVisible(fam, true)   // reschedule #1, held at the gate
        await w.google.waitFor(6, where: { $0.isEventsList && $0.query["timeMin"] == horizonQuery })
        await w.put(Fx.alice, Fx.alice, Fx.timed("late", "Late", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let calls = w.notifier.calls.count
        s.setVisible(fam, true)   // reschedule #2 sees the new event
        try await eventually("second reschedule") { w.notifier.calls.count == calls + 1 }
        await w.google.removeEvent(Fx.alice, Fx.alice, "late")
        await gate.open()
        await w.settle()
        #expect(w.notifier.calls.count == calls + 1, "the stale result is dropped")
        #expect(w.notifier.lastIds.contains(Fx.id(Fx.alice, Fx.alice, "late")))
    }

    @Test("An unreadable vault never clears existing reminders")
    func unreadableVaultKeepsReminders() async throws {
        let v = MemoryVault()
        v.readError = AppError.message("User interaction is not allowed.")
        let w = await World(vault: v)
        let s = await w.start()
        await s.refresh()
        #expect(w.notifier.calls.isEmpty)
    }
}

@Suite("In-app reminder windows", .timeLimit(.minutes(1)))
struct InAppReminderTests {
    private func r(_ id: String, _ fire: Date) -> PlannedReminder {
        PlannedReminder(id: id, eventId: id, fire: fire, minutes: 10, title: id, body: "")
    }

    @Test("Each check shows the reminders that came due since the last one, once")
    func dueWindow() {
        let plan = [r("a", T0.addingTimeInterval(-30)), r("b", T0), r("c", T0.addingTimeInterval(5)), r("d", T0.addingTimeInterval(60))]
        #expect(Notifier.due(plan, after: T0.addingTimeInterval(-10), upTo: T0.addingTimeInterval(10), shown: []).map(\.id) == ["b", "c"])
        #expect(Notifier.due(plan, after: T0.addingTimeInterval(-10), upTo: T0.addingTimeInterval(10), shown: ["b"]).map(\.id) == ["c"])
        #expect(Notifier.due(plan, after: T0.addingTimeInterval(10), upTo: T0.addingTimeInterval(20), shown: []).isEmpty)
    }

    @Test("After the Mac sleeps, only reminders missed by under 10 minutes still appear")
    func staleAfterSleep() {
        let plan = [r("old", T0.addingTimeInterval(-3600)), r("recent", T0.addingTimeInterval(-300))]
        let shown = Notifier.due(plan, after: T0.addingTimeInterval(-7200), upTo: T0, shown: [])
        #expect(shown.map(\.id) == ["recent"])
    }

    @Test("A reminder carries the event's start and Meet link for Join and Open")
    func reminderCarriesLinks() {
        let start = T0.addingTimeInterval(3600)
        var extra: [String: Any] = ["hangoutLink": "https://meet.google.com/abc-defg-hij"]
        extra["reminders"] = ["useDefault": false, "overrides": [["method": "popup", "minutes": 10]]]
        let e = event(Fx.timed("m", "Sync", start, start.addingTimeInterval(1800), extra))
        let p = Notifier.plan([e], now: T0)
        #expect(p.count == 1)
        #expect(p.first?.start == start)
        #expect(p.first?.meetLink == "https://meet.google.com/abc-defg-hij")

        // The link comes from whichever copy has it when the meeting is in two accounts.
        var noLink = extra
        noLink["hangoutLink"] = nil
        noLink["iCalUID"] = "same@x.com"
        var withLink = extra
        withLink["iCalUID"] = "same@x.com"
        let a = event(Fx.timed("a", "Sync", start, start.addingTimeInterval(1800), noLink))
        let b = event(Fx.timed("b", "Sync", start, start.addingTimeInterval(1800), withLink))
        #expect(Notifier.plan([a, b], now: T0).first?.meetLink == "https://meet.google.com/abc-defg-hij")
    }
}
