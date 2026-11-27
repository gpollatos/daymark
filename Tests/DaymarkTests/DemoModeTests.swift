import Foundation
import Testing
@testable import Daymark

@MainActor @Suite("Demo mode", .timeLimit(.minutes(1)))
struct DemoModeTests {
    private func demoStore() async -> CalendarStore {
        var env = AppEnvironment.demo
        env.startBackgroundWork = false
        let s = CalendarStore(env: env)
        await s.bootstrap()
        await s.settle()
        return s
    }

    @Test("Demo mode shows fictional accounts and this week's events, with no Keychain or network")
    func loadsFictionalData() async throws {
        let s = await demoStore()
        #expect(s.accounts.map(\.email) == DemoMode.accounts)
        #expect(s.accounts.allSatisfy { $0.email.hasSuffix(".example") || $0.email.hasSuffix("@example.com") },
                "only reserved example domains")
        #expect(s.calendars.count == 6)
        #expect(s.accountIssues.isEmpty && s.failedCalendarKeys.isEmpty)
        let week = s.visibleRange
        #expect(s.visibleEvents.filter { $0.overlaps(week) }.count >= 15)
        #expect(!s.showSetup && !s.vaultUnreadable)
    }

    @Test("Creating, searching and deleting work against the demo data")
    func writesWork() async throws {
        let s = await demoStore()
        let key = try #require(s.defaultCalendarKey)
        let start = s.cal.date(bySettingHour: 14, minute: 0, second: 0, of: s.selectedDate)!
        try await s.save(EventDraft(existing: nil, calendarKey: key, title: "Try Daymark", start: start, end: start.addingTimeInterval(3600)))
        let created = try #require(s.events.first { $0.title == "Try Daymark" })
        s.searchText = "daymark"
        await s.performSearch()
        #expect(s.searchResults?.map(\.id) == [created.id])
        await s.delete(created, allOccurrences: false)
        #expect(!s.events.contains { $0.title == "Try Daymark" })
        #expect(s.errorMessage == nil)
    }
}
