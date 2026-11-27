import Foundation
import Testing
@testable import Daymark

private func cal(_ email: String = Fx.alice, role: String = "owner", reminders: [Int] = []) -> GCalendar {
    let dto = try! JSONDecoder().decode(CalendarListEntryDTO.self,
                                        from: try! JSONSerialization.data(withJSONObject: Fx.calendar(email, role: role, reminders: reminders).dict))
    return GCalendar(accountEmail: email, dto: dto)
}

private func parse(_ json: [String: Any], role: String = "owner", reminders: [Int] = [10], calendar: Calendar = NY) -> CalendarEvent? {
    let dto = try! JSONDecoder().decode(EventDTO.self, from: try! JSONSerialization.data(withJSONObject: json))
    return CalendarEvent(dto: dto, calendar: cal(role: role, reminders: reminders), using: calendar)
}

@Suite("Dates and time zones", .timeLimit(.minutes(1)))
struct DateTests {
    @Test("RFC 3339 timestamps parse to exact instants", arguments: [
        ("2026-11-26T10:00:00Z", 1_795_687_200.0),
        ("2026-11-26T12:00:00+02:00", 1_795_687_200.0),
        ("2026-11-26T02:00:00-08:00", 1_795_687_200.0),
        ("2026-11-26T10:00:00.123Z", 1_795_687_200.123),
        ("2026-11-26T15:30:00+05:30", 1_795_687_200.0),
        ("2028-02-29T00:00:00Z", 1_835_395_200.0),
    ])
    func rfc3339(s: String, epoch: Double) throws {
        let d = try #require(RFC3339.parse(s))
        #expect(abs(d.timeIntervalSince1970 - epoch) < 0.001)
    }

    @Test("Malformed timestamps are rejected; written timestamps are always UTC with no '+'")
    func rfc3339Rejects() {
        for bad in ["2026-11-26", "garbage", "", "2026-13-01T00:00:00Z"] { #expect(RFC3339.parse(bad) == nil) }
        #expect(RFC3339.string(at(2026, 7, 1, 9)) == "2026-07-01T13:00:00Z")
        #expect(RFC3339.string(at(2026, 12, 1, 9)) == "2026-12-01T14:00:00Z")
    }

    @Test("All-day dates round-trip on every day of 2018–2028 in zones with odd DST rules",
          arguments: ["America/New_York", "Europe/Berlin", "America/Sao_Paulo", "Pacific/Auckland", "Pacific/Apia",
                      "Pacific/Kiritimati", "Asia/Kolkata", "Pacific/Honolulu", "America/Havana", "Asia/Tehran"])
    func allDayRoundTrip(tz: String) {
        let c = makeCalendar(tz)
        var d = at(2018, 1, 1, 12, 0, 0, c)
        let end = at(2029, 1, 1, 0, 0, 0, c)
        var failures = 0
        while d < end {
            let s = RFC3339.dayString(d, calendar: c)
            let parsed = RFC3339.parseDay(s, calendar: c)
            if parsed != c.startOfDay(for: d) || parsed.map({ RFC3339.dayString($0, calendar: c) }) != s { failures += 1 }
            d = c.date(byAdding: .day, value: 1, to: d)!
        }
        #expect(failures == 0)
        #expect(RFC3339.parseDay("2026-02-30", calendar: c) == nil)
        #expect(RFC3339.parseDay("26-02-01", calendar: c) == nil)
    }

    @Test("All-day events land on exactly their days, across DST changes")
    func allDayOverlap() throws {
        let spring = try #require(parse(["id": "s", "start": ["date": "2026-03-07"], "end": ["date": "2026-03-10"]]))
        #expect(spring.start == at(2026, 3, 7) && spring.end == at(2026, 3, 10))
        let days = NY.days(in: DateInterval(start: at(2026, 3, 5), end: at(2026, 3, 12)))
        #expect(days.map { spring.overlaps(day: $0, calendar: NY) } == [false, false, true, true, true, false, false])
        #expect(spring.spansFullDays)

        let fall = try #require(parse(["id": "f", "start": ["date": "2026-11-01"], "end": ["date": "2026-11-02"]]))
        #expect([at(2026, 10, 31), at(2026, 11, 1), at(2026, 11, 2)].map { fall.overlaps(day: $0, calendar: NY) } == [false, true, false])
        #expect(fall.end.timeIntervalSince(fall.start) == 25 * 3600)

        // The same date string means a different instant in Auckland, but the same calendar day there.
        let akl = makeCalendar("Pacific/Auckland")
        let nz = try #require(parse(["id": "n", "start": ["date": "2026-11-26"], "end": ["date": "2026-11-27"]], calendar: akl))
        #expect(nz.start == at(2026, 11, 26, 0, 0, 0, akl))
        #expect(nz.overlaps(day: at(2026, 11, 26, 0, 0, 0, akl), calendar: akl))
    }

    @Test("Timed events are bucketed into the right days at midnight edges", arguments: [
        ("spans midnight", at(2026, 11, 26, 23, 30), at(2026, 11, 27, 0, 30), [true, true, false], false),
        ("ends at midnight", at(2026, 11, 26, 22), at(2026, 11, 27), [true, false, false], false),
        ("starts at midnight", at(2026, 11, 27), at(2026, 11, 27, 1), [false, true, false], false),
        ("zero length at midnight", at(2026, 11, 27), at(2026, 11, 27), [false, true, false], false),
        ("exactly 24 h", at(2026, 11, 26, 9), at(2026, 11, 27, 9), [true, true, false], true),
    ])
    func timedBucketing(name: String, start: Date, end: Date, expected: [Bool], fullDay: Bool) throws {
        let e = try #require(parse(["id": "e", "start": ["dateTime": RFC3339.string(start)], "end": ["dateTime": RFC3339.string(end)]]))
        let days = [at(2026, 11, 26), at(2026, 11, 27), at(2026, 11, 28)]
        #expect(days.map { e.overlaps(day: $0, calendar: NY) } == expected)
        #expect(e.spansFullDays == fullDay)
        let buckets = [e].bucketed(by: days, calendar: NY)
        #expect(buckets.map { !$0.isEmpty } == expected)
    }

    @Test("A wall-clock day on the 23-hour DST day is shorter than 24 h, so it stays in the timed grid")
    func dstDayTimedEvent() throws {
        let e = try #require(parse(["id": "e", "start": ["dateTime": RFC3339.string(at(2026, 3, 8))],
                                    "end": ["dateTime": RFC3339.string(at(2026, 3, 9))]]))
        #expect(e.end.timeIntervalSince(e.start) == 82_800)
        #expect(!e.spansFullDays)
    }

    @Test("Timed writes carry the instant in UTC and the user's zone name")
    func timedWriteZone() throws {
        for tz in ["America/New_York", "Asia/Tokyo"] {
            let w = EventTimeWrite.timed(at(2026, 12, 3, 12), timeZone: TimeZone(identifier: tz)!)
            #expect(w.dateTime == "2026-12-03T17:00:00Z")
            #expect(w.timeZone == tz)
            #expect(w.date == nil)
        }
        // An event stored with its own zone still shows the right instant.
        let tokyo = try #require(parse(["id": "t", "start": ["dateTime": "2026-12-04T09:00:00+09:00", "timeZone": "Asia/Tokyo"],
                                        "end": ["dateTime": "2026-12-04T10:00:00+09:00", "timeZone": "Asia/Tokyo"]]))
        #expect(tokyo.start == at(2026, 12, 3, 19))
    }
}

@Suite("Editor draft logic")
struct EditorTests {
    @Test("Moving the start keeps the duration; all-day events move by whole days across DST", arguments: [
        (at(2026, 3, 6), at(2026, 3, 8), at(2026, 3, 11), true, at(2026, 3, 13)),
        (at(2026, 11, 3), at(2026, 11, 4), at(2026, 10, 30), true, at(2026, 10, 31)),
        (at(2026, 5, 1, 10), at(2026, 5, 1, 11), at(2026, 5, 2, 14), false, at(2026, 5, 2, 15)),
        // Timed across DST keeps the absolute duration (1 h), so the wall-clock end follows.
        (at(2026, 3, 7, 10), at(2026, 3, 7, 11), at(2026, 3, 8, 10), false, at(2026, 3, 8, 11)),
        // A new start past the end clamps the end to the start.
        (at(2026, 5, 1, 10), at(2026, 5, 1, 9), at(2026, 5, 1, 12), false, at(2026, 5, 1, 12)),
    ])
    func shiftedEnd(start: Date, end: Date, newStart: Date, allDay: Bool, expected: Date) {
        #expect(EventDraft.shiftedEnd(end: end, oldStart: start, newStart: newStart, allDay: allDay, calendar: NY) == expected)
    }

    @Test("All-day toggle", arguments: [
        ("timed → all-day keeps the days", at(2026, 11, 26, 10), at(2026, 11, 28, 15), true, at(2026, 11, 26), at(2026, 11, 28)),
        ("ending exactly at midnight is one day", at(2026, 11, 26, 23), at(2026, 11, 27), true, at(2026, 11, 26), at(2026, 11, 26)),
        ("all-day → timed is 9–10 on the first day", at(2026, 11, 26), at(2026, 11, 28), false, at(2026, 11, 26, 9), at(2026, 11, 26, 10)),
    ])
    func allDayToggle(name: String, start: Date, end: Date, toAllDay: Bool, newStart: Date, newEnd: Date) {
        var d = EventDraft(existing: nil, calendarKey: "k", isAllDay: !toAllDay, start: start, end: end)
        d.setAllDay(toAllDay, calendar: NY)
        #expect(d.isAllDay == toAllDay)
        #expect(d.start == newStart && d.end == newEnd)
        d.setAllDay(toAllDay, calendar: NY)
        #expect(d.start == newStart && d.end == newEnd, "setting the same value again changes nothing")
    }

    @Test("setStart on a draft uses the duration rule")
    func setStart() {
        var d = EventDraft(existing: nil, calendarKey: "k", isAllDay: true, start: at(2026, 3, 6), end: at(2026, 3, 8))
        d.setStart(at(2026, 3, 11), calendar: NY)
        #expect(d.start == at(2026, 3, 11) && d.end == at(2026, 3, 13))
    }
}

@Suite("Day layout")
struct LayoutTests {
    private func ev(_ id: String, _ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int, day: Int = 26) -> CalendarEvent {
        parse(["id": id, "start": ["dateTime": RFC3339.string(at(2026, 11, day, h1, m1))],
               "end": ["dateTime": RFC3339.string(at(2026, 11, day, h2, m2))]])!
    }

    private func layout(_ events: [CalendarEvent], day: Date = at(2026, 11, 26)) -> [String: LaidOutEvent] {
        Dictionary(uniqueKeysWithValues: DayLayout.layout(events, day: day, calendar: NY).map { ($0.event.eventId, $0) })
    }

    @Test("Overlap columns")
    func basics() {
        var l = layout([ev("a", 9, 0, 10, 0), ev("b", 11, 0, 12, 0)])
        #expect(l["a"]?.columns == 1 && l["b"]?.columns == 1)

        l = layout([ev("a", 9, 0, 11, 0), ev("b", 10, 0, 12, 0)])
        #expect(l["a"]?.columns == 2 && l["b"]?.columns == 2 && l["a"]?.column != l["b"]?.column)

        l = layout([ev("a", 9, 0, 10, 0), ev("b", 10, 0, 11, 0)])
        #expect(l["a"]?.columns == 1 && l["b"]?.columns == 1, "touching events don't overlap")

        l = layout([ev("a", 9, 0, 12, 0), ev("b", 9, 0, 12, 0), ev("c", 9, 0, 12, 0)])
        #expect(Set(l.values.map(\.column)) == [0, 1, 2] && l.values.allSatisfy { $0.columns == 3 })
    }

    @Test("A chain reuses a freed column and shares the cluster's width")
    func chain() {
        let l = layout([ev("a", 9, 0, 10, 0), ev("b", 9, 30, 12, 0), ev("c", 11, 0, 11, 30)])
        #expect(l["a"]?.column == 0 && l["b"]?.column == 1 && l["c"]?.column == 0)
        #expect(l.values.allSatisfy { $0.columns == 2 })
    }

    @Test("Very short events reserve 20 minutes of space so they stay readable")
    func minimumSlot() {
        var l = layout([ev("a", 10, 0, 10, 5), ev("b", 10, 10, 10, 15)])
        #expect(l["a"]?.columns == 2)
        l = layout([ev("a", 10, 0, 10, 5), ev("b", 10, 20, 10, 25)])
        #expect(l["a"]?.columns == 1 && l["b"]?.columns == 1)
    }

    @Test("Events crossing midnight are clipped to each day")
    func midnightClamp() {
        let e = parse(["id": "n", "start": ["dateTime": RFC3339.string(at(2026, 11, 26, 22))],
                       "end": ["dateTime": RFC3339.string(at(2026, 11, 27, 2))]])!
        let d1 = layout([e])["n"]!, d2 = layout([e], day: at(2026, 11, 27))["n"]!
        #expect(d1.startMin == 1320 && d1.endMin == 1440)
        #expect(d2.startMin == 0 && d2.endMin == 120)
        let toMidnight = parse(["id": "t", "start": ["dateTime": RFC3339.string(at(2026, 11, 26, 23))],
                                "end": ["dateTime": RFC3339.string(at(2026, 11, 27))]])!
        #expect(layout([toMidnight])["t"]?.endMin == 1440)
    }

    @Test("Spring-forward day uses wall-clock minutes")
    func dstLayout() {
        let e = parse(["id": "d", "start": ["dateTime": RFC3339.string(at(2026, 3, 8, 1, 30))],
                       "end": ["dateTime": RFC3339.string(at(2026, 3, 8, 3, 30))]])!
        let l = layout([e], day: at(2026, 3, 8))["d"]!
        #expect(l.startMin == 90 && l.endMin == 210)
    }

    @Test("Layout invariants hold for random days, whatever the input order")
    func invariants() {
        let seed = UInt64.random(in: 1...UInt64.max)
        var rng = SplitMix64(seed: seed)
        for round in 0..<30 {
            let events = (0..<40).map { i -> CalendarEvent in
                let s = Int.random(in: 0..<(24 * 60 - 15), using: &rng)
                let len = [0, 5, 15, 30, 45, 60, 90, 180].randomElement(using: &rng)!
                let e = min(s + len, 24 * 60 - 1)
                return ev("r\(round)-\(i)", s / 60, s % 60, e / 60, e % 60)
            }
            let laid = DayLayout.layout(events, day: at(2026, 11, 26), calendar: NY)
            #expect(laid.count == events.count)
            for a in laid {
                #expect(a.column < a.columns)
                for b in laid where a.id < b.id && a.column == b.column {
                    let aEnd = max(a.endMin, a.startMin + 20), bEnd = max(b.endMin, b.startMin + 20)
                    #expect(a.startMin >= bEnd || b.startMin >= aEnd, "\(a.id) and \(b.id) overlap in column \(a.column) (seed \(seed))")
                }
            }
            let again = DayLayout.layout(events.shuffled(using: &rng), day: at(2026, 11, 26), calendar: NY)
            #expect(Dictionary(uniqueKeysWithValues: again.map { ($0.id, [$0.column, $0.columns]) })
                    == Dictionary(uniqueKeysWithValues: laid.map { ($0.id, [$0.column, $0.columns]) }))
        }
    }

    @Test("Agenda sections: all-day first, stable order, empty days hidden except today")
    func agendaSections() {
        let a = parse(["id": "a", "summary": "B", "start": ["dateTime": RFC3339.string(at(2026, 11, 26, 9))],
                       "end": ["dateTime": RFC3339.string(at(2026, 11, 26, 10))]])!
        let b = parse(["id": "b", "summary": "A", "start": ["dateTime": RFC3339.string(at(2026, 11, 26, 9))],
                       "end": ["dateTime": RFC3339.string(at(2026, 11, 26, 10))]])!
        let trip = parse(["id": "t", "start": ["date": "2026-11-26"], "end": ["date": "2026-11-29"]])!
        let days = NY.days(in: DateInterval(start: at(2026, 11, 25), end: at(2026, 12, 1)))
        let s = DayAgenda.sections(events: [a, b, trip], days: days, today: at(2026, 11, 30, 8), calendar: NY)
        #expect(s.map(\.day) == [at(2026, 11, 26), at(2026, 11, 27), at(2026, 11, 28), at(2026, 11, 30)])
        #expect(s[0].events.map(\.eventId) == ["t", "b", "a"])
        #expect(s[1].events.map(\.eventId) == ["t"])
        #expect(s[3].events.isEmpty)
    }
}

@Suite("Event parsing")
struct EventParsingTests {
    struct RoleCase: Sendable, CustomTestStringConvertible {
        let role: String, organizer: String, guestsCanModify: Bool
        let canEdit: Bool, canDelete: Bool, title: String
        var testDescription: String { "\(role) / organizer:\(organizer) / modify:\(guestsCanModify)" }
    }

    @Test("Permissions and titles from calendar role and organiser", arguments: [
        RoleCase(role: "owner", organizer: "absent", guestsCanModify: false, canEdit: true, canDelete: true, title: "Event"),
        RoleCase(role: "owner", organizer: "self", guestsCanModify: false, canEdit: true, canDelete: true, title: "Event"),
        RoleCase(role: "owner", organizer: "other", guestsCanModify: false, canEdit: false, canDelete: true, title: "Event"),
        RoleCase(role: "owner", organizer: "other", guestsCanModify: true, canEdit: true, canDelete: true, title: "Event"),
        RoleCase(role: "writer", organizer: "self", guestsCanModify: false, canEdit: true, canDelete: true, title: "Event"),
        RoleCase(role: "reader", organizer: "self", guestsCanModify: true, canEdit: false, canDelete: false, title: "Event"),
        RoleCase(role: "freeBusyReader", organizer: "absent", guestsCanModify: false, canEdit: false, canDelete: false, title: "Busy"),
    ])
    func permissions(c: RoleCase) throws {
        var j: [String: Any] = ["id": "e", "start": ["dateTime": "2026-11-26T15:00:00Z"], "end": ["dateTime": "2026-11-26T16:00:00Z"],
                                "guestsCanModify": c.guestsCanModify]
        if c.role != "freeBusyReader" { j["summary"] = "Event" }
        switch c.organizer {
        case "self": j["organizer"] = ["email": Fx.alice, "self": true]
        case "other": j["organizer"] = ["email": "host@x.com"]   // Google omits "self": false
        default: break
        }
        let e = try #require(parse(j, role: c.role))
        #expect(e.canEdit == c.canEdit)
        #expect(e.canDelete == c.canDelete)
        #expect(e.title == c.title)
    }

    @Test("Reminders: calendar defaults, overrides, and non-popup methods ignored", arguments: [
        (nil as [String: Any]?, [10]),
        (["useDefault": true], [10]),
        (["useDefault": false], []),
        (["useDefault": false, "overrides": [["method": "popup", "minutes": 5], ["method": "email", "minutes": 60]]], [5]),
        (["useDefault": false, "overrides": [["method": "email", "minutes": 60]]], []),
    ] as [([String: Any]?, [Int])])
    func reminders(r: [String: Any]?, expected: [Int]) throws {
        var j: [String: Any] = ["id": "e", "start": ["dateTime": "2026-11-26T15:00:00Z"], "end": ["dateTime": "2026-11-26T16:00:00Z"]]
        if let r { j["reminders"] = r }
        #expect(try #require(parse(j, reminders: [10])).reminderMinutes == expected)
    }

    @Test("Meet link, colour and title fallbacks")
    func fields() throws {
        let base: [String: Any] = ["id": "e", "start": ["dateTime": "2026-11-26T15:00:00Z"], "end": ["dateTime": "2026-11-26T16:00:00Z"]]
        var j = base
        j["hangoutLink"] = "https://meet.google.com/abc"
        #expect(try #require(parse(j)).meetLink == "https://meet.google.com/abc")
        j = base
        j["conferenceData"] = ["entryPoints": [["entryPointType": "phone", "uri": "tel:+1"], ["entryPointType": "video", "uri": "https://zoom.us/j/1"]]]
        #expect(try #require(parse(j)).meetLink == "https://zoom.us/j/1")
        j = base
        j["colorId"] = "11"
        #expect(try #require(parse(j)).colorHex == "#D50000")
        j = base
        j["colorId"] = "99"
        #expect(try #require(parse(j)).colorHex == "#039BE5", "unknown colour falls back to the calendar's")
        for summary in ["", "   "] {
            j = base
            j["summary"] = summary
            #expect(try #require(parse(j)).title == CalendarEvent.untitled)
        }
    }

    @Test("Cancelled, working-location and time-less events are dropped")
    func dropped() {
        let t: [String: Any] = ["start": ["dateTime": "2026-11-26T15:00:00Z"], "end": ["dateTime": "2026-11-26T16:00:00Z"]]
        #expect(parse(t.merging(["id": "a", "status": "cancelled"]) { $1 }) == nil)
        #expect(parse(t.merging(["id": "b", "eventType": "workingLocation"]) { $1 }) == nil)
        #expect(parse(["id": "c"]) == nil)
        #expect(parse(["id": "d", "start": ["date": "2026-11-26"], "end": ["dateTime": "2026-11-26T16:00:00Z"]]) == nil)
        #expect(parse(t.merging(["id": "e", "eventType": "outOfOffice"]) { $1 }) != nil)
    }

    @Test("Calendar list entries: names, colours, roles and default reminders")
    func calendarMapping() throws {
        func g(_ j: [String: Any]) throws -> GCalendar {
            GCalendar(accountEmail: "a@b.c", dto: try JSONDecoder().decode(CalendarListEntryDTO.self, from: try JSONSerialization.data(withJSONObject: j)))
        }
        var c = try g(["id": "x", "summary": "Work", "summaryOverride": "My work", "backgroundColor": "#9FE1E7"])
        #expect(c.name == "My work" && c.colorHex == "#039BE5" && c.accessRole == "reader" && !c.selectedInGoogle && !c.canWrite)
        c = try g(["id": "x", "backgroundColor": "#123456", "accessRole": "writer", "selected": true,
                   "defaultReminders": [["method": "popup", "minutes": 15], ["method": "email", "minutes": 30], ["minutes": 5]]])
        #expect(c.name == "x" && c.colorHex == "#123456" && c.canWrite && c.selectedInGoogle)
        #expect(c.defaultReminderMinutes == [15, 5])
        c = try g(["id": "x"])
        #expect(c.colorHex == "#039BE5")
    }
}

@Suite("Text helpers")
struct TextTests {
    @Test("HTML descriptions become readable text; plain text is left alone", arguments: [
        ("if x < 5 and y > 3 then go", "if x < 5 and y > 3 then go"),
        ("<p>if x < 5 and y > 3</p><p>then go</p>", "if x < 5 and y > 3\nthen go"),
        ("<p>Hello</p><p>World</p>", "Hello\nWorld"),
        ("a<br>b<br/>c<BR />d", "a\nb\nc\nd"),
        ("Fish &amp; chips&nbsp;tonight", "Fish & chips tonight"),
        ("&amp;lt;tag&amp;gt;", "&lt;tag&gt;"),
        (#"Join <a href="https://meet.example/x">here</a>"#, "Join here (https://meet.example/x)"),
        (#"<a href="https://x.io">https://x.io</a>"#, "https://x.io"),
        ("<ul><li>one</li><li>two</li></ul>", "one\ntwo"),
        ("<b>bold <i>nested</i></b>", "bold nested"),
        ("a\n\n\n\nb", "a\n\n\n\nb"),
        ("<p>a</p>\n\n\n<p>b</p>", "a\n\nb"),
    ])
    func stripHTML(input: String, expected: String) {
        #expect(Fmt.stripHTML(input) == expected)
    }

    @Test("Guest lists accept commas, semicolons, new lines and 'Name <email>'", arguments: [
        ("A@x.com, b@y.com;a@x.com\nnot-an-email", ["a@x.com", "b@y.com"]),
        ("Bob <bob@x.com>, \"Eve\" <eve@y.com>", ["bob@x.com", "eve@y.com"]),
        ("c@z.com\r\nd@z.com\te@z.com", ["c@z.com", "d@z.com", "e@z.com"]),
        ("", []),
        ("   ,  ; ", []),
    ])
    func parseEmails(input: String, expected: [String]) {
        #expect(CalendarStore.parseEmails(input) == expected)
    }

    @Test("Links in descriptions become clickable")
    func linkify() {
        let a = Fmt.linkified("See https://x.io/a?b=1 and mail me")
        let links = a.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://x.io/a?b=1")!])
    }

    @Test("Legacy calendar colours map to the modern palette", arguments: [
        ("#9fe1e7", "#039BE5"), ("#9FE1E7", "#039BE5"), ("#ac725e", "#795548"), ("#a47ae2", "#9E69AF"),
        ("#abcdef", "#abcdef"),
    ])
    func palette(legacy: String, modern: String) {
        #expect(Palette.calendarColor(legacy) == modern)
    }

    @Test("Client JSON from Google Cloud Console")
    func clientJSON() {
        let installed = #"{"installed":{"client_id":" 1-a.apps.googleusercontent.com ","client_secret":"GOCSPX-x","redirect_uris":["http://localhost"]}}"#
        #expect(OAuthClient.fromGoogleJSON(Data(installed.utf8)) == OAuthClient(clientId: "1-a.apps.googleusercontent.com", clientSecret: "GOCSPX-x"))
        #expect(OAuthClient.fromGoogleJSON(Data(#"{"web":{"client_id":"w.apps.googleusercontent.com","client_secret":"s"}}"#.utf8)) != nil)
        #expect(OAuthClient.fromGoogleJSON(Data(#"{"installed":{"client_id":"x"}}"#.utf8)) == nil)
        #expect(OAuthClient.fromGoogleJSON(Data(#"{"installed":{"client_id":1,"client_secret":"s"}}"#.utf8)) == nil)
        #expect(OAuthClient.fromGoogleJSON(Data("not json".utf8)) == nil)
        #expect(OAuthClient.isPlausibleId("123-abc.apps.googleusercontent.com"))
        #expect(!OAuthClient.isPlausibleId(".apps.googleusercontent.com"))
        #expect(!OAuthClient.isPlausibleId("123-abc.example.com"))
    }

    @Test("Interval edges")
    func intervals() {
        let i = DateInterval(start: T0, duration: 100)
        #expect(i.containsHalfOpen(T0) && !i.containsHalfOpen(T0.addingTimeInterval(100)))
        #expect(i.covers(i))
        #expect(i.covers(DateInterval(start: T0.addingTimeInterval(10), duration: 90)))
        #expect(!i.covers(DateInterval(start: T0.addingTimeInterval(-1), duration: 50)))
        #expect(!i.covers(DateInterval(start: T0.addingTimeInterval(10), duration: 91)))
    }
}

@MainActor @Suite("Vault persistence")
struct PersistenceTests {
    @Test("The vault round-trips and rejects corrupt data")
    func vaultRoundTrip() throws {
        let v = MemoryVault()
        let vault = Vault(client: Fx.client, accounts: [Account(email: "ü@x.com", refreshToken: "1//tök€n")])
        try vault.save(to: v.storage)
        let back = try Vault.load(from: v.storage)
        #expect(back.client == Fx.client && back.accounts == vault.accounts)
        #expect(try Vault.load(from: MemoryVault().storage).accounts.isEmpty, "nothing saved yet")
        #expect(throws: (any Error).self) { try Vault.load(from: MemoryVault(raw: Data("{nope".utf8)).storage) }
        let extra = Data(#"{"client":null,"accounts":[],"future":1}"#.utf8)
        #expect(try Vault.load(from: MemoryVault(raw: extra).storage).client == nil)
    }

    @Test("A fresh install asks for setup and touches nothing")
    func freshInstall() async throws {
        let w = await World(vault: MemoryVault())
        let s = await w.start()
        #expect(s.showSetup)
        #expect(s.accounts.isEmpty)
        #expect(await w.requests().isEmpty)
        #expect(w.vault.writes.isEmpty)
    }

    @Test("An unreadable vault is never overwritten, whatever the user does",
          arguments: ["keychain denied", "corrupt"])
    func unreadableVaultNeverOverwritten(kind: String) async throws {
        let v: MemoryVault
        if kind == "corrupt" {
            v = MemoryVault(raw: Data("{\"client\":".utf8))
        } else {
            v = MemoryVault(Vault(client: Fx.client, accounts: [Account(email: Fx.alice, refreshToken: "rt-A")]))
            v.readError = AppError.message("User interaction is not allowed.")
        }
        let w = await World(vault: v)
        let s = await w.start()
        #expect(s.errorMessage?.contains("Keychain") == true)
        #expect(!s.showSetup)
        s.errorMessage = nil
        s.saveClient(Fx.otherClient)
        #expect(s.errorMessage == CalendarStore.vaultLockedMessage)
        s.addAccount()
        s.removeAccount(Fx.alice)
        await s.refresh()
        await w.settle()
        #expect(w.vault.writes.isEmpty)
        #expect(await w.requests().isEmpty)
        #expect(await w.oauth.signInClients.isEmpty)
    }

    @Test("Every account change is saved once, with the complete state")
    func persistOnMutation() async throws {
        let w = await World(accounts: [Fx.alice])
        let s = await w.start()
        #expect(w.vault.writes.isEmpty)
        await w.oauth.queueSignIn(email: Fx.bob, refreshToken: "rt-B")
        s.addAccount()
        await w.settle()
        #expect(w.vault.writes.count == 1)
        #expect(w.vault.current?.accounts.map(\.email) == [Fx.alice, Fx.bob])
        s.removeAccount(Fx.alice)
        #expect(w.vault.writes.count == 2)
        #expect(w.vault.current?.accounts.map(\.email) == [Fx.bob])
        #expect(w.vault.current?.client == Fx.client)
    }

    @Test("A failed save is reported, and the next successful save writes everything")
    func writeFailure() async throws {
        let w = await World(accounts: [Fx.alice])
        let s = await w.start()
        w.vault.writeError = AppError.message("disk full")
        await w.oauth.queueSignIn(email: Fx.bob, refreshToken: "rt-B")
        s.addAccount()
        await w.settle()
        #expect(s.errorMessage?.hasPrefix("Couldn't save to the Keychain") == true)
        #expect(s.accounts.count == 2, "the session keeps working")
        w.vault.writeError = nil
        await w.oauth.queueSignIn(email: Fx.carol, refreshToken: "rt-C")
        s.addAccount()
        await w.settle()
        #expect(w.vault.current?.accounts.map(\.email) == [Fx.alice, Fx.bob, Fx.carol])
    }

    @Test("Bootstrap runs once; a client with no accounts makes no requests")
    func bootstrapIdempotent() async throws {
        let w = await World(accounts: [])
        let s = await w.start()
        await s.bootstrap()
        await w.settle()
        #expect(w.vault.reads == 1)
        #expect(await w.requests().isEmpty)
        #expect(!s.showSetup)
        #expect(w.notifier.last?.isEmpty == true)
    }
}

/// Small seedable generator so a failing random layout can be reproduced from its seed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
