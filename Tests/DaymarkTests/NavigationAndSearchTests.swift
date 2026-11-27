import Foundation
import Testing
@testable import Daymark

@MainActor @Suite("Navigation and loading windows", .timeLimit(.minutes(1)))
struct NavigationTests {
    @Test("The first load fetches one three-month window from every calendar")
    func goldenFetchWindow() async throws {
        let w = await World()
        let s = await w.start()
        let lists = await w.requests { $0.isEventsList }
        #expect(lists.count == 7)
        #expect(lists.allSatisfy { $0.query["timeMin"] == "2026-09-27T04:00:00Z" && $0.query["timeMax"] == "2027-01-15T05:00:00Z" })
        #expect(s.loadedWindow == DateInterval(start: RFC3339.parse("2026-09-27T04:00:00Z")!, end: RFC3339.parse("2027-01-15T05:00:00Z")!))
    }

    @Test("The fetch window covers every view, for every day, week start and time zone")
    func fetchWindowCoversEveryView() {
        for tz in ["America/New_York", "Pacific/Auckland", "Europe/Berlin", "America/Sao_Paulo"] {
            for first in [1, 2, 7] {
                let c = makeCalendar(tz, firstWeekday: first)
                var d = at(2026, 1, 1, 0, 0, 0, c)
                let end = at(2028, 1, 1, 0, 0, 0, c)
                while d < end {
                    let window = CalendarStore.fetchWindow(around: d, calendar: c)
                    for mode in ViewMode.allCases {
                        let r = CalendarStore.visibleRange(mode: mode, selected: d, calendar: c)
                        if !window.covers(r) {
                            Issue.record("\(tz) first=\(first) \(mode) \(d): \(r) not in \(window)")
                            return
                        }
                    }
                    d = c.date(byAdding: .day, value: 1, to: d)!
                }
            }
        }
    }

    @Test("Moving around inside the loaded window makes no requests; leaving it loads once")
    func navigationInsideWindow() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("dec", "December", at(2026, 12, 10, 9), at(2026, 12, 10, 10)))
        let s = await w.start()
        await w.google.clearRequests()
        for _ in 0..<2 { s.step(1) }
        s.step(-1); s.step(-1)
        s.viewMode = .month
        s.step(1); s.step(-1)
        s.viewMode = .day
        s.show(day: at(2026, 12, 10))
        await w.settle()
        #expect(await w.requests().isEmpty)
        #expect(s.visibleEvents.contains { $0.eventId == "dec" })

        s.viewMode = .month
        let jan = CalendarStore.fetchWindow(around: at(2027, 1, 1), calendar: NY)
        let gate = Gate()
        await w.google.on({ $0.isEventsList && $0.query["timeMin"] == RFC3339.string(jan.start) }, always: .gate(gate))
        s.step(1)  // January: outside the window, starts a load
        await w.google.waitFor(6, where: { $0.isEventsList })
        s.step(1)  // February: covered by the load already in flight, so no second load
        await gate.open()
        await w.settle()
        let lists = await w.requests { $0.isEventsList }
        #expect(lists.count == 7, "\(lists.map { $0.query["timeMin"]! + " " + $0.query["timeMax"]! })")
        #expect(Set(lists.map { $0.query["timeMin"]! }).count == 1)
        #expect(s.loadedWindow?.covers(s.visibleRange) == true)
    }

    @Test("Navigating away and straight back while loading still ends with the right data")
    func navigateAwayAndBack() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("nov", "November", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()
        let far = CalendarStore.fetchWindow(around: at(2027, 4, 15), calendar: NY)
        let gate = Gate()
        await w.google.on({ $0.isEventsList && $0.query["timeMin"] == RFC3339.string(far.start) }, always: .gate(gate))

        s.selectedDate = at(2027, 4, 15)
        await w.google.waitFor(where: { $0.isEventsList && $0.query["timeMin"] == RFC3339.string(far.start) })
        s.selectedDate = T0   // still inside the old loaded window: no new load is started here
        await gate.open()
        await w.settle()

        #expect(s.loadedWindow?.covers(s.visibleRange) == true)
        #expect(s.visibleEvents.contains { $0.eventId == "nov" })
        #expect(!s.isLoading)
    }

    @Test("A slower, older load never replaces a newer one")
    func supersededLoad() async throws {
        let w = await World()
        let s = await w.start()
        let gate = Gate()
        await w.google.on({ $0.isEventsList }, Array(repeating: .gate(gate), count: 6))
        await w.google.clearRequests()   // count only this load's requests
        let older = Task { await s.loadEvents() }
        await w.google.waitFor(6, where: { $0.isEventsList && $0.token != nil })
        await w.put(Fx.bob, Fx.bob, Fx.timed("fresh", "Fresh", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        await s.loadEvents()
        #expect(w.eventIds.contains(Fx.id(Fx.bob, Fx.bob, "fresh")))
        await w.google.removeEvent(Fx.bob, Fx.bob, "fresh")
        await gate.open()
        await older.value
        #expect(w.eventIds.contains(Fx.id(Fx.bob, Fx.bob, "fresh")), "the older result was discarded")
        #expect(!s.isLoading)
    }

    @Test("Visible ranges per view, including DST weeks", arguments: [
        (ViewMode.day, at(2026, 3, 8, 15), at(2026, 3, 8), at(2026, 3, 9), 1),
        (.threeDay, at(2026, 11, 1, 1), at(2026, 11, 1), at(2026, 11, 4), 3),
        (.week, at(2026, 3, 11), at(2026, 3, 8), at(2026, 3, 15), 7),
        (.week, at(2026, 11, 4), at(2026, 11, 1), at(2026, 11, 8), 7),
        (.month, at(2026, 2, 14), at(2026, 2, 1), at(2026, 3, 1), 28),
        (.month, at(2026, 8, 14), at(2026, 7, 26), at(2026, 9, 6), 42),
        (.schedule, at(2026, 11, 26), at(2026, 11, 1), at(2027, 1, 1), 61),
        (.workWeek, at(2026, 11, 26), at(2026, 11, 23), at(2026, 11, 28), 5),
        (.workWeek, at(2026, 11, 28), at(2026, 11, 23), at(2026, 11, 28), 5),
        (.workWeek, at(2026, 11, 29), at(2026, 11, 30), at(2026, 12, 5), 5),
        (.workWeek, at(2026, 3, 10), at(2026, 3, 9), at(2026, 3, 14), 5),
    ])
    func visibleRanges(mode: ViewMode, selected: Date, start: Date, end: Date, days: Int) {
        let r = CalendarStore.visibleRange(mode: mode, selected: selected, calendar: NY)
        #expect(r.start == start && r.end == end)
        let ds = NY.days(in: r)
        #expect(ds.count == days)
        #expect(ds.allSatisfy { NY.startOfDay(for: $0) == $0 })
    }

    @Test("Work Week is Monday–Friday of the selected week, whatever day weeks start on")
    func workWeekDays() {
        for first in [1, 2, 7] {
            let c = makeCalendar(firstWeekday: first)
            for day in 22...30 {
                let selected = at(2026, 11, day, 15, 0, 0, c)
                let days = c.days(in: CalendarStore.visibleRange(mode: .workWeek, selected: selected, calendar: c))
                #expect(days.map { c.component(.weekday, from: $0) } == [2, 3, 4, 5, 6], "first=\(first) day=\(day)")
                let week = CalendarStore.visibleRange(mode: .week, selected: selected, calendar: c)
                #expect(days.allSatisfy { week.containsHalfOpen($0) }, "the work week is inside the selected week")
            }
        }
    }

    @Test("DST days are 23 and 25 hours long")
    func dstDayLength() {
        #expect(NY.dayInterval(at(2026, 3, 8)).duration == 23 * 3600)
        #expect(NY.dayInterval(at(2026, 11, 1)).duration == 25 * 3600)
    }

    @Test("Month grid rows depend on the week start", arguments: [
        (2026, 2, 1, 4), (2026, 2, 2, 5), (2026, 8, 1, 6), (2026, 8, 2, 6), (2026, 10, 1, 5), (2026, 10, 2, 5), (2026, 11, 1, 5),
    ])
    func monthGridRows(year: Int, month: Int, firstWeekday: Int, rows: Int) {
        let c = makeCalendar(firstWeekday: firstWeekday)
        let r = CalendarStore.monthGridRange(selected: at(year, month, 15, 0, 0, 0, c), calendar: c)
        #expect(c.dateComponents([.day], from: r.start, to: r.end).day == rows * 7)
        #expect(c.component(.weekday, from: r.start) == firstWeekday)
        let monthInterval = c.dateInterval(of: .month, for: at(year, month, 15, 0, 0, 0, c))!
        #expect(r.covers(monthInterval))
        #expect(c.date(byAdding: .day, value: 7, to: r.start)! > monthInterval.start, "no empty leading week")
        #expect(c.date(byAdding: .day, value: -7, to: r.end)! < monthInterval.end, "no empty trailing week")
    }

    @Test("Stepping: months never drift; weeks and days stay on midnight across DST")
    func stepping() async throws {
        let w = await World()
        let s = await w.start()
        s.viewMode = .month
        s.selectedDate = at(2027, 1, 31)
        s.step(1)
        #expect(s.selectedDate == at(2027, 2, 1))
        s.step(-1)
        #expect(s.selectedDate == at(2027, 1, 1))
        s.selectedDate = at(2026, 10, 31)
        s.step(1)
        #expect(s.selectedDate == at(2026, 11, 26), "landing on the current month selects today")

        s.viewMode = .week
        s.selectedDate = at(2027, 3, 10)
        s.step(1)
        #expect(s.selectedDate == at(2027, 3, 17))
        s.viewMode = .day
        s.selectedDate = at(2027, 3, 14)
        s.step(1)
        #expect(s.selectedDate == at(2027, 3, 15))
        s.viewMode = .threeDay
        s.step(-1)
        #expect(s.selectedDate == at(2027, 3, 12))
        s.viewMode = .workWeek
        s.selectedDate = at(2027, 3, 10)
        s.step(1)
        #expect(s.selectedDate == at(2027, 3, 17))
        #expect(s.visibleDays == [15, 16, 17, 18, 19].map { at(2027, 3, $0) })
        s.viewMode = .schedule
        s.selectedDate = at(2027, 5, 20)
        s.step(1)
        #expect(s.selectedDate == at(2027, 6, 1))
        s.step(-2)
        #expect(s.selectedDate == at(2027, 4, 1))
    }

    @Test("Today, show(day:) and the remembered view mode")
    func showAndPersistence() async throws {
        let w = await World()
        let s = await w.start()
        s.show(day: at(2027, 2, 3, 17), mode: .day)
        #expect(s.viewMode == .day && s.selectedDate == at(2027, 2, 3))
        await w.settle()
        #expect(s.loadedWindow?.covers(s.visibleRange) == true)
        w.clock.now = at(2026, 12, 25, 8)
        s.goToToday()
        #expect(s.selectedDate == at(2026, 12, 25))

        w.makeStore()
        #expect(w.store.viewMode == .day)
        w.defaults.set("bogus", forKey: CalendarStore.Keys.viewMode)
        w.makeStore()
        #expect(w.store.viewMode == .week)
    }

    @Test("Becoming active refreshes only if the last refresh is over a minute old")
    func activationRefresh() async throws {
        let w = await World()
        let s = await w.start()
        await w.google.clearRequests()
        w.clock.advance(30)
        await s.appDidBecomeActive()
        #expect(await w.requests().isEmpty)
        w.clock.advance(31)
        await s.appDidBecomeActive()
        #expect(await w.requests { $0.segments.first == "users" }.count == 3)
    }

    @Test("Default start: the next half hour today, 9:00 on other days", arguments: [
        (at(2026, 11, 26, 10, 0, 0), at(2026, 11, 26, 10, 0)),
        (at(2026, 11, 26, 10, 0, 1), at(2026, 11, 26, 10, 30)),
        (at(2026, 11, 26, 10, 29), at(2026, 11, 26, 10, 30)),
        (at(2026, 11, 26, 10, 30), at(2026, 11, 26, 10, 30)),
        (at(2026, 11, 26, 10, 31), at(2026, 11, 26, 11, 0)),
        (at(2026, 11, 26, 23, 31), at(2026, 11, 27, 0, 0)),
        (at(2026, 11, 26, 23, 59, 59), at(2026, 11, 27, 0, 0)),
        (at(2027, 3, 14, 1, 45), at(2027, 3, 14, 3, 0)),
    ])
    func defaultStart(now: Date, expected: Date) {
        #expect(CalendarStore.defaultStart(now: now, selected: NY.startOfDay(for: now), calendar: NY) == expected)
        #expect(CalendarStore.defaultStart(now: now, selected: at(2027, 1, 5), calendar: NY) == at(2027, 1, 5, 9))
    }
}

@MainActor @Suite("Search", .timeLimit(.minutes(1)))
struct SearchTests {
    @Test("Search covers every visible calendar in every account and merges the results")
    func mergedAcrossAccounts() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("a", "Design sync", at(2026, 12, 2, 9), at(2026, 12, 2, 10)))
        await w.put(Fx.bob, Fx.team, Fx.timed("t", "Team sync", at(2026, 6, 1, 9), at(2026, 6, 1, 10)))
        await w.put(Fx.carol, Fx.carol, Fx.timed("c", "Lunch", at(2027, 5, 1, 9), at(2027, 5, 1, 10), ["location": "Sync café"]))
        await w.put(Fx.alice, Fx.holiday, Fx.allDay("h", "Sync day", "2026-12-01", "2026-12-02"))
        await w.put(Fx.bob, Fx.bob, Fx.timed("old", "Ancient sync", at(2024, 1, 1, 9), at(2024, 1, 1, 10)))
        let s = await w.start()
        await w.google.clearRequests()
        s.searchText = "  sync "
        await s.performSearch()

        let reqs = await w.requests { $0.isEventsList }
        #expect(reqs.count == 6)
        #expect(!reqs.contains { $0.calendarId == Fx.holiday })
        #expect(reqs.allSatisfy { $0.query["q"] == "sync" && $0.query["timeMin"] == "2025-11-26T17:00:00Z" && $0.query["timeMax"] == "2028-11-26T17:00:00Z" })
        #expect(s.searchResults?.map(\.eventId) == ["t", "a", "c"])
        #expect(!s.isSearching)
        #expect(s.searchFailedCalendarKeys.isEmpty)
    }

    @Test("A slow earlier search never overwrites a newer one")
    func staleSearchDiscarded() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("a", "alpha", at(2026, 12, 2, 9), at(2026, 12, 2, 10)))
        await w.put(Fx.alice, Fx.alice, Fx.timed("b", "beta", at(2026, 12, 3, 9), at(2026, 12, 3, 10)))
        let s = await w.start()
        let gate = Gate()
        await w.google.on({ $0.query["q"] == "a" }, always: .gate(gate))
        s.searchText = "a"
        let first = Task { await s.performSearch() }
        await w.google.waitFor(6, where: { $0.query["q"] == "a" })
        #expect(s.isSearching)
        s.searchText = "beta"
        await s.performSearch()
        #expect(s.searchResults?.map(\.eventId) == ["b"])
        await gate.open()
        await first.value
        #expect(s.searchResults?.map(\.eventId) == ["b"])
        #expect(!s.isSearching)
    }

    @Test("Blank searches send nothing; clearing resets")
    func blankAndClear() async throws {
        let w = await World()
        let s = await w.start()
        await w.google.clearRequests()
        s.searchText = "   "
        await s.performSearch()
        #expect(s.searchResults == nil)
        #expect(await w.requests().isEmpty)
        s.searchText = "x"
        await s.performSearch()
        #expect(s.searchResults == [])
        s.clearSearch()
        #expect(s.searchResults == nil && s.searchText.isEmpty && !s.isSearching)
    }

    @Test("Results follow deletions and account removal, even mid-search")
    func resultsFollowMutations() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("a", "Review", at(2026, 12, 2, 9), at(2026, 12, 2, 10)))
        await w.put(Fx.bob, Fx.bob, Fx.timed("b", "Review", at(2026, 12, 3, 9), at(2026, 12, 3, 10)))
        let s = await w.start()
        s.searchText = "review"
        await s.performSearch()
        #expect(s.searchResults?.count == 2)

        await w.google.clearRequests()
        await s.delete(try #require(s.searchResults?.first { $0.accountEmail == Fx.alice }), allOccurrences: false)
        #expect(s.searchResults?.map(\.accountEmail) == [Fx.bob])
        #expect(await w.requests { $0.query["q"] == "review" }.count == 6, "the search is re-run after a change")

        let gate = Gate()
        await w.google.on({ $0.query["q"] == "review" && $0.account == Fx.bob }, always: .gate(gate))
        await w.google.clearRequests()   // the re-search above already asked Bob; wait for the new one
        await w.put(Fx.alice, Fx.alice, Fx.timed("a2", "Review 2", at(2026, 12, 4, 9), at(2026, 12, 4, 10)))
        let search = Task { await s.performSearch() }
        await w.google.waitFor(where: { $0.query["q"] == "review" && $0.account == Fx.bob })
        s.removeAccount(Fx.bob)
        await gate.open()
        await search.value
        #expect(s.searchResults?.map(\.eventId) == ["a2"])
    }

    @Test("A calendar that can't be searched is reported, not silently missing")
    func partialSearchFailure() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("a", "Offsite", at(2026, 12, 2, 9), at(2026, 12, 2, 10)))
        let s = await w.start()
        await w.google.on({ $0.query["q"] != nil && $0.calendarId == Fx.team }, always: .status(500, googleError(500, "backendError")))
        s.searchText = "offsite"
        await s.performSearch()
        #expect(s.searchResults?.map(\.eventId) == ["a"])
        #expect(s.searchFailedCalendarKeys == [Fx.key(Fx.bob, Fx.team)])
    }

    @Test("Special characters reach Google and match location and guests", arguments: [
        ("r&d", "loc"), ("a+b", "title"), ("café", "title"), ("dave@x.com", "guest"),
    ])
    func specialCharacters(q: String, field: String) async throws {
        let w = await World()
        var extra: [String: Any] = [:]
        var title = "Meeting"
        switch field {
        case "loc": extra["location"] = "R&D lab"
        case "guest": extra["attendees"] = [["email": "dave@x.com"]]
        default: title = "Plan \(q)"
        }
        await w.put(Fx.alice, Fx.alice, Fx.timed("m", title, at(2026, 12, 2, 9), at(2026, 12, 2, 10), extra))
        let s = await w.start()
        s.searchText = q
        await s.performSearch()
        #expect(s.searchResults?.map(\.eventId) == ["m"])
        #expect(await w.requests { $0.query["q"] != nil }.allSatisfy { $0.query["q"] == q })
    }
}
