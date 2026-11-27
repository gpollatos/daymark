import Foundation
import Testing
@testable import Daymark

@MainActor @Suite("Clicking, dragging and moving on the day grid", .timeLimit(.minutes(1)))
struct GridInteractionTests {
    private func writes(_ w: World) async -> [RecordedRequest] { await w.requests { $0.method != "GET" } }

    private func edit(_ s: CalendarStore, _ id: String) throws -> EventDraft {
        let e = try #require(s.events.first { $0.id == id })
        s.beginEdit(e)
        return try #require(s.editorDraft)
    }

    private static let perMinute = 52.0 / 60   // the grid's hour height is 52 pt
    private static let column = 200.0

    // Kills: beginCreate wiring.
    @Test("New-event draft: default calendar, next half hour, one hour; all-day starts at midnight")
    func beginCreateDraft() async throws {
        let w = await World()
        let s = await w.start()
        // Bob's calendar is neither first nor last among the writable ones.
        w.defaults.set(Fx.key(Fx.bob, Fx.bob), forKey: CalendarStore.Keys.lastCalendar)
        s.beginCreate()
        var d = try #require(s.editorDraft)
        #expect(d.calendarKey == Fx.key(Fx.bob, Fx.bob))
        #expect(d.start == at(2026, 11, 26, 12) && d.end == at(2026, 11, 26, 13) && !d.isAllDay && d.existing == nil)
        s.beginCreate(at: at(2026, 12, 2, 15, 30), allDay: true)
        d = try #require(s.editorDraft)
        #expect(d.isAllDay && d.start == at(2026, 12, 2) && d.end == at(2026, 12, 2))
    }

    @Test("Clicking or dragging on the day grid picks the event's times", arguments: [
        ("click mid-slot", 580.0, 582.0, at(2026, 11, 26, 9, 30), at(2026, 11, 26, 10, 30)),
        ("click on the hour", 841.0, 841.0, at(2026, 11, 26, 14), at(2026, 11, 26, 15)),
        ("click in the last half hour", 1430.0, 1430.0, at(2026, 11, 26, 23, 30), at(2026, 11, 27, 0, 30)),
        ("drag down", 545.0, 650.0, at(2026, 11, 26, 9), at(2026, 11, 26, 11)),
        ("drag up", 980.0, 910.0, at(2026, 11, 26, 15), at(2026, 11, 26, 16, 30)),
        ("short drag is at least 15 min", 720.0, 729.0, at(2026, 11, 26, 12), at(2026, 11, 26, 12, 15)),
        ("drag past the bottom stops at midnight", 1320.0, 1500.0, at(2026, 11, 26, 22), at(2026, 11, 27)),
        ("drag above the top starts at midnight", 30.0, -40.0, at(2026, 11, 26), at(2026, 11, 26, 0, 30)),
    ] as [(String, Double, Double, Date, Date)])
    func slotPicking(name: String, from: Double, to: Double, start: Date, end: Date) {
        let r = SlotPicker.range(from: from, to: to, day: at(2026, 11, 26), calendar: NY)
        #expect(r.start == start, "\(name)")
        #expect(r.end == end, "\(name)")
    }

    @Test("Grid times are wall-clock times on daylight-saving days")
    func slotPickingDST() {
        // 8 March 2026: 2:00–3:00 doesn't exist in New York. Dragging 3:00–4:00 on the grid is 3:00–4:00.
        let r = SlotPicker.range(from: 180, to: 240, day: at(2026, 3, 8), calendar: NY)
        #expect(r.start == at(2026, 3, 8, 3) && r.end == at(2026, 3, 8, 4))
        #expect(r.end.timeIntervalSince(r.start) == 3600)
    }

    @Test("A dragged range opens the editor with exactly those times")
    func beginCreateFromDrag() async throws {
        let w = await World()
        let s = await w.start()
        s.beginCreate(at: at(2026, 11, 30, 9), end: at(2026, 11, 30, 11, 15))
        let d = try #require(s.editorDraft)
        #expect(d.start == at(2026, 11, 30, 9) && d.end == at(2026, 11, 30, 11, 15))
        #expect(!d.isAllDay && d.existing == nil)
        #expect(d.calendarKey == Fx.key(Fx.alice, Fx.alice))

        s.beginCreate(at: at(2026, 12, 2), allDay: true)
        let a = try #require(s.editorDraft)
        #expect(a.isAllDay && a.start == at(2026, 12, 2) && a.end == at(2026, 12, 2))
    }

    @Test("The event being created is highlighted on exactly the days and times it covers")
    func placeholder() {
        var d = EventDraft(existing: nil, calendarKey: "k", start: at(2026, 11, 26, 9, 30), end: at(2026, 11, 26, 11))
        #expect(d.placeholderMinutes(on: at(2026, 11, 26), calendar: NY)! == (570, 660))
        #expect(d.placeholderMinutes(on: at(2026, 11, 27), calendar: NY) == nil)

        d.start = at(2026, 11, 26, 23); d.end = at(2026, 11, 27, 1)
        #expect(d.placeholderMinutes(on: at(2026, 11, 26), calendar: NY)! == (1380, 1440))
        #expect(d.placeholderMinutes(on: at(2026, 11, 27), calendar: NY)! == (0, 60))

        d.start = at(2026, 11, 26, 10); d.end = d.start
        #expect(d.placeholderMinutes(on: at(2026, 11, 26), calendar: NY)! == (600, 600))

        d.setAllDay(true, calendar: NY)
        #expect(d.placeholderMinutes(on: at(2026, 11, 26), calendar: NY) == nil)
        d.end = at(2026, 11, 28)
        #expect([25, 26, 27, 28, 29].map { d.placeholderCovers(day: at(2026, 11, $0), calendar: NY) } == [false, true, true, true, false])

        // Editing an existing event shows the real event, not a placeholder.
        let w = event(Fx.timed("e", "E", at(2026, 11, 26, 9), at(2026, 11, 26, 10)))
        let edit = EventDraft(existing: w, calendarKey: "k", start: w.start, end: w.end)
        #expect(edit.placeholderMinutes(on: at(2026, 11, 26), calendar: NY) == nil)
    }

    @Test("Dragging an event moves it by whole days and 15-minute steps, keeping its length", arguments: [
        ("down 1 h", 0.0, 52.0, 2, at(2026, 11, 26, 10), at(2026, 11, 26, 11, 30)),
        ("up 20 min snaps to 15", 0.0, -20.0 * 52 / 60, 2, at(2026, 11, 26, 8, 45), at(2026, 11, 26, 10, 15)),
        ("next day", 210.0, 0.0, 2, at(2026, 11, 27, 9), at(2026, 11, 27, 10, 30)),
        ("two days back and 30 min down", -390.0, 26.0, 2, at(2026, 11, 24, 9, 30), at(2026, 11, 24, 11)),
        ("past the last column stays on the last day", 900.0, 0.0, 2, at(2026, 11, 28, 9), at(2026, 11, 28, 10, 30)),
        ("above midnight stops at 00:00", 0.0, -9999.0, 2, at(2026, 11, 26, 0), at(2026, 11, 26, 1, 30)),
        ("below midnight stops at 23:45", 0.0, 9999.0, 2, at(2026, 11, 26, 23, 45), at(2026, 11, 27, 1, 15)),
    ] as [(String, Double, Double, Int, Date, Date)])
    func moving(name: String, dx: Double, dy: Double, fromDay: Int, start: Date, end: Date) {
        // A 9:00–10:30 event in the 3rd of 5 columns (Thursday 26 Nov).
        let r = EventMover.moved(start: at(2026, 11, 26, 9), end: at(2026, 11, 26, 10, 30), fromDay: fromDay, dayCount: 5,
                                 dx: dx, dy: dy, columnWidth: Self.column, perMinute: Self.perMinute, calendar: NY)
        #expect(r.start == start, "\(name)")
        #expect(r.end == end, "\(name)")
    }

    @Test("Moving across a daylight-saving change keeps wall-clock time and length")
    func movingAcrossDST() {
        // Saturday 7 March 10:00 → Sunday 8 March (clocks go forward that night) stays 10:00.
        let r = EventMover.moved(start: at(2026, 3, 7, 10), end: at(2026, 3, 7, 11), fromDay: 0, dayCount: 7,
                                 dx: Self.column, dy: 0, columnWidth: Self.column, perMinute: Self.perMinute, calendar: NY)
        #expect(r.start == at(2026, 3, 8, 10) && r.end == at(2026, 3, 8, 11))
    }

    @Test("Dragging the bottom edge changes the end in 15-minute steps, never shorter than 15 min", arguments: [
        (52.0, at(2026, 11, 26, 11)),
        (5.0, at(2026, 11, 26, 10)),          // ~6 min rounds back to the same end
        (10.0, at(2026, 11, 26, 10, 15)),     // ~11.5 min rounds up to the next step
        (-26.0, at(2026, 11, 26, 9, 30)),
        (-9999.0, at(2026, 11, 26, 9, 15)),
    ] as [(Double, Date)])
    func resizing(dy: Double, end: Date) {
        #expect(EventMover.resizedEnd(start: at(2026, 11, 26, 9), end: at(2026, 11, 26, 10), dy: dy,
                                      perMinute: Self.perMinute, calendar: NY) == end)
    }

    @Test("Moving an event updates it at once and saves only its times, to the owning account")
    func moveSaves() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.bob, Fx.timed("m", "Standup", at(2026, 11, 26, 9), at(2026, 11, 26, 9, 30), ["location": "Room 1"]))
        let s = await w.start()
        let e = try #require(s.events.first { $0.eventId == "m" })
        await w.google.clearRequests()
        s.move(e, start: at(2026, 11, 27, 14), end: at(2026, 11, 27, 14, 30))
        // Shown at the new time straight away, before Google answers.
        #expect(s.events.first { $0.eventId == "m" }?.start == at(2026, 11, 27, 14))
        await w.settle()
        let r = try #require(await writes(w).first)
        #expect(r.method == "PATCH" && r.account == Fx.bob)
        #expect(r.rawPath == "/calendar/v3/calendars/bob@work.example/events/m")
        #expect(r.bodyKeys == ["end", "start"])
        #expect((r.body?["start"] as? [String: Any])?["dateTime"] as? String == "2026-11-27T19:00:00Z")
        let server = try #require(await w.google.event(Fx.bob, Fx.bob, "m"))
        #expect(server["location"] as? String == "Room 1")
        #expect(s.events.first { $0.eventId == "m" }?.start == at(2026, 11, 27, 14))
    }

    @Test("Events you can't edit don't move; a refused move snaps back with a message")
    func moveRefused() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.team, Fx.timed("t", "Team", at(2026, 11, 26, 9), at(2026, 11, 26, 10)))
        await w.put(Fx.alice, Fx.alice, Fx.timed("a", "Mine", at(2026, 11, 26, 11), at(2026, 11, 26, 12)))
        let s = await w.start()
        await w.google.clearRequests()
        s.move(try #require(s.events.first { $0.eventId == "t" }), start: at(2026, 11, 26, 15), end: at(2026, 11, 26, 16))
        await w.settle()
        #expect(await writes(w).isEmpty, "read-only calendar")
        #expect(s.events.first { $0.eventId == "t" }?.start == at(2026, 11, 26, 9))

        await w.google.on({ $0.method == "PATCH" }, always: .status(403, googleError(403, "forbidden", "Not allowed")))
        s.move(try #require(s.events.first { $0.eventId == "a" }), start: at(2026, 11, 26, 15), end: at(2026, 11, 26, 16))
        await w.settle()
        #expect(s.errorMessage?.contains("Not allowed") == true)
        #expect(s.events.first { $0.eventId == "a" }?.start == at(2026, 11, 26, 11), "back where it was")
    }
}
