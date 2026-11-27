import Foundation
import Testing
@testable import Daymark

@MainActor @Suite("Text shown in the app", .timeLimit(.minutes(1)))
struct FormattingTests {
    // Kills: weekday header order.
    @Test("Weekday header starts on the calendar's first weekday", arguments: [1, 2, 7])
    func weekdayOrder(first: Int) {
        let c = makeCalendar(firstWeekday: first)
        let sym = c.orderedWeekdaySymbols(["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"])
        #expect(sym.first == ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"][first - 1])
        #expect(sym.count == 7 && Set(sym).count == 7)
    }

    // Kills: Notifier body content.
    @Test("Reminder text carries the title, the time line and the location")
    func notificationBody() {
        let e = event(Fx.timed("e", "Standup", T0.addingTimeInterval(3600), T0.addingTimeInterval(4500),
                               ["location": "Room 4", "reminders": ["useDefault": false, "overrides": [["method": "popup", "minutes": 10]]]]))
        let p = Notifier.plan([e], now: T0, calendar: NY, locale: Locale(identifier: "en_US"))
        #expect(p.first?.title == "Standup")
        let body = p.first?.body.replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(body == "Thursday, November 26 · 1:00 PM – 1:15 PM\nRoom 4")
    }

    @Test("Date and time text, as shown in the app", arguments: [
        ("timed", "Thursday, November 26 · 1:00 PM – 2:30 PM", "1:00 PM – 2:30 PM"),
        ("overnight", "Nov 26 at 10:00 PM – Nov 27 at 1:00 AM", "Nov 26 at 10:00 PM – Nov 27 at 1:00 AM"),
        ("allday", "Thursday, November 26", "All day"),
        ("trip", "Dec 30 – Jan 2, 2027", "All day"),
    ])
    func formatting(kind: String, when: String, range: String) {
        let j: [String: Any] = switch kind {
        case "timed": ["id": "t", "start": ["dateTime": RFC3339.string(at(2026, 11, 26, 13))], "end": ["dateTime": RFC3339.string(at(2026, 11, 26, 14, 30))]]
        case "overnight": ["id": "m", "start": ["dateTime": RFC3339.string(at(2026, 11, 26, 22))], "end": ["dateTime": RFC3339.string(at(2026, 11, 27, 1))]]
        case "allday": ["id": "a", "start": ["date": "2026-11-26"], "end": ["date": "2026-11-27"]]
        default: ["id": "b", "start": ["date": "2026-12-30"], "end": ["date": "2027-01-03"]]
        }
        let e = event(JSON(j))
        let en = Locale(identifier: "en_US")
        func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }
        #expect(plain(Fmt.when(e, calendar: NY, locale: en)) == when)
        #expect(plain(Fmt.timeRange(e, calendar: NY, locale: en)) == range)
    }

    @Test("Toolbar title for each view", arguments: [
        (ViewMode.week, at(2026, 11, 26), "November 2026"),
        (.week, at(2026, 12, 1), "Nov – Dec 2026"),
        (.week, at(2026, 12, 29), "Dec 2026 – Jan 2027"),
        (.threeDay, at(2026, 11, 30), "Nov – Dec 2026"),
        (.threeDay, at(2026, 11, 26), "November 2026"),
        (.workWeek, at(2026, 11, 26), "November 2026"),
        (.workWeek, at(2026, 12, 1), "Nov – Dec 2026"),
        (.workWeek, at(2026, 12, 29), "Dec 2026 – Jan 2027"),
        (.month, at(2026, 11, 26), "November 2026"),
        (.schedule, at(2027, 1, 5), "January 2027"),
    ])
    func titles(mode: ViewMode, date: Date, expected: String) {
        #expect(CalendarStore.title(mode: mode, selected: date, calendar: NY, locale: Locale(identifier: "en_US")) == expected)
    }

    @Test("The title uses the calendar's own time zone, not the Mac's")
    func titleTimeZone() {
        // Midnight on 1 Dec in Auckland is still 30 Nov in most of the world.
        let akl = makeCalendar("Pacific/Auckland")
        let en = Locale(identifier: "en_US")
        #expect(CalendarStore.title(mode: .month, selected: at(2026, 12, 1, 0, 0, 0, akl), calendar: akl, locale: en) == "December 2026")
        let hnl = makeCalendar("Pacific/Honolulu")
        #expect(CalendarStore.title(mode: .day, selected: at(2026, 11, 30, 23, 0, 0, hnl), calendar: hnl, locale: en) == "November 2026")
    }
}
