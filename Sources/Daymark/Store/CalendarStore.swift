import AppKit
import Observation
import SwiftUI

/// All app state. Calendars and events live only in memory and are re-fetched from Google.
@MainActor
@Observable
final class CalendarStore {
    // MARK: Credentials (vault)
    private(set) var client: OAuthClient?
    private(set) var accounts: [Account] = []

    // MARK: Google data (memory only)
    private(set) var calendars: [GCalendar] = []
    private(set) var events: [CalendarEvent] = []
    private(set) var loadedWindow: DateInterval?
    private(set) var accountIssues: [String: AccountIssue] = [:]
    /// Calendars whose last event fetch failed (their previous events are still shown).
    private(set) var failedCalendarKeys: Set<String> = []

    // MARK: UI state
    var selectedDate: Date { didSet { rangeDidChange() } }
    var viewMode: ViewMode {
        didSet {
            env.defaults.set(viewMode.rawValue, forKey: Keys.viewMode)
            rangeDidChange()
        }
    }
    private var visibility: [String: Bool]
    var isLoading = false
    var isSigningIn = false
    var errorMessage: String?
    var showSetup = false
    var editorDraft: EventDraft?
    var pendingDelete: CalendarEvent?
    /// Emptying the search box ends the search, including one still in flight.
    var searchText = "" { didSet { if searchText.isEmpty && !oldValue.isEmpty { endSearch() } } }
    var searchResults: [CalendarEvent]?
    /// Calendars that couldn't be searched, so "no results" isn't mistaken for a complete answer.
    private(set) var searchFailedCalendarKeys: Set<String> = []
    private(set) var isSearching = false
    private(set) var now: Date

    @ObservationIgnored let env: AppEnvironment
    @ObservationIgnored private var tokens: [String: AccessToken] = [:]
    @ObservationIgnored private var tokenTasks: [String: Task<(AccessToken, String?), Error>] = [:]
    @ObservationIgnored private var bootstrapped = false
    /// Set if the vault couldn't be read; nothing is written back so saved accounts aren't lost.
    private(set) var vaultUnreadable = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The window the in-flight load is fetching, if any.
    @ObservationIgnored private var pendingWindow: DateInterval?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var signInID = UUID()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchGeneration = 0
    @ObservationIgnored private var notificationGeneration = 0
    /// What was last handed to the notifier per calendar, reused while that calendar can't be fetched.
    @ObservationIgnored private var lastNotified: [String: [CalendarEvent]] = [:]
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var timers: [Timer] = []
    @ObservationIgnored private var background: [UUID: Task<Void, Never>] = [:]

    enum Keys {
        static let viewMode = "viewMode"
        static let visibility = "calendarVisibility"
        static let lastCalendar = "lastCalendarKey"
    }

    /// Google allows bursts, but dozens of parallel requests trip per-user rate limits.
    static let maxConcurrentRequests = 6
    /// Reminders are scheduled for events starting within this window.
    static let notificationHorizon: TimeInterval = 8 * 86_400

    var cal: Calendar { env.calendar() }

    init(env: AppEnvironment? = nil) {
        let env = env ?? .live
        self.env = env
        let c = env.calendar()
        now = env.now()
        selectedDate = c.startOfDay(for: env.now())
        viewMode = ViewMode(rawValue: env.defaults.string(forKey: Keys.viewMode) ?? "") ?? .week
        visibility = (env.defaults.dictionary(forKey: Keys.visibility) as? [String: Bool]) ?? [:]
    }

    // MARK: - Background work

    /// Runs `op` as tracked background work, so tests can wait for it with `settle()`.
    @discardableResult
    private func spawn(_ op: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            await op()
            self?.background[id] = nil
        }
        background[id] = task
        return task
    }

    /// Waits until all background work (including work it starts) has finished.
    func settle() async {
        while let t = background.values.first { await t.value }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        do {
            let vault = try Vault.load(from: env.vault)
            client = vault.client
            accounts = vault.accounts
            if client == nil { showSetup = true }
        } catch {
            vaultUnreadable = true
            errorMessage = "Daymark couldn't read its saved accounts from the Keychain (\(error.localizedDescription)). Nothing has been changed. Quit and reopen Daymark, and choose Always Allow if macOS asks for Keychain access."
            return
        }

        if env.startBackgroundWork {
            timers = [
                Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                    Task { @MainActor in await self?.refresh() }
                },
                Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                    Task { @MainActor in guard let self else { return }; self.now = self.env.now() }
                },
            ]
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.appDidBecomeActive() }
            }
        }
        await refresh()
    }

    func appDidBecomeActive() async {
        guard env.now().timeIntervalSince(lastRefresh) > 60 else { return }
        await refresh()
    }

    func refresh() async {
        guard !vaultUnreadable else { return }
        lastRefresh = env.now()
        now = env.now()
        guard client != nil, !accounts.isEmpty else {
            resetData()
            return
        }
        await loadCalendars()
        await loadEvents()
        await rescheduleNotifications()
    }

    // MARK: - Ranges & navigation

    var visibleRange: DateInterval { Self.visibleRange(mode: viewMode, selected: selectedDate, calendar: cal) }

    static func visibleRange(mode: ViewMode, selected: Date, calendar cal: Calendar) -> DateInterval {
        let d = cal.startOfDay(for: selected)
        switch mode {
        case .day:
            return cal.dayInterval(d)
        case .threeDay:
            return DateInterval(start: d, end: cal.date(byAdding: .day, value: 3, to: d)!)
        case .week:
            let s = cal.startOfWeek(d)
            return DateInterval(start: s, end: cal.date(byAdding: .day, value: 7, to: s)!)
        case .workWeek:
            // Monday to Friday of the selected week, whichever day the locale starts weeks on.
            let s = cal.startOfWeek(d)
            let monday = (0..<7).lazy.compactMap { cal.date(byAdding: .day, value: $0, to: s) }
                .first { cal.component(.weekday, from: $0) == 2 } ?? s
            return DateInterval(start: monday, end: cal.date(byAdding: .day, value: 5, to: monday)!)
        case .month:
            return monthGridRange(selected: d, calendar: cal)
        case .schedule:
            let s = cal.startOfMonth(d)
            return DateInterval(start: s, end: cal.date(byAdding: .month, value: 2, to: s)!)
        }
    }

    var monthGridRange: DateInterval { Self.monthGridRange(selected: selectedDate, calendar: cal) }

    static func monthGridRange(selected: Date, calendar cal: Calendar) -> DateInterval {
        let m = cal.startOfMonth(selected)
        let s = cal.startOfWeek(m)
        let monthEnd = cal.date(byAdding: .month, value: 1, to: m)!
        let days = cal.dateComponents([.day], from: s, to: monthEnd).day ?? 35
        let weeks = Int((Double(days) / 7).rounded(.up))
        return DateInterval(start: s, end: cal.date(byAdding: .day, value: weeks * 7, to: s)!)
    }

    var visibleDays: [Date] { cal.days(in: visibleRange) }

    var title: String { Self.title(mode: viewMode, selected: selectedDate, calendar: cal) }

    static func title(mode: ViewMode, selected: Date, calendar cal: Calendar, locale: Locale = .current) -> String {
        let r = visibleRange(mode: mode, selected: selected, calendar: cal)
        let monthYear = Fmt.style(.dateTime.month(.wide).year(), cal, locale)
        let month = Fmt.style(.dateTime.month(.abbreviated), cal, locale)
        let monthAndYear = Fmt.style(.dateTime.month(.abbreviated).year(), cal, locale)
        switch mode {
        case .day, .month, .schedule:
            return selected.formatted(monthYear)
        case .threeDay, .workWeek, .week:
            let last = r.end.addingTimeInterval(-1)
            if cal.isDate(r.start, equalTo: last, toGranularity: .month) { return r.start.formatted(monthYear) }
            if cal.isDate(r.start, equalTo: last, toGranularity: .year) {
                return "\(r.start.formatted(month)) – \(last.formatted(monthAndYear))"
            }
            return "\(r.start.formatted(monthAndYear)) – \(last.formatted(monthAndYear))"
        }
    }

    func goToToday() { selectedDate = cal.startOfDay(for: env.now()) }

    func step(_ dir: Int) {
        let c = cal
        switch viewMode {
        case .day: selectedDate = c.date(byAdding: .day, value: dir, to: selectedDate) ?? selectedDate
        case .threeDay: selectedDate = c.date(byAdding: .day, value: 3 * dir, to: selectedDate) ?? selectedDate
        case .week, .workWeek: selectedDate = c.date(byAdding: .day, value: 7 * dir, to: selectedDate) ?? selectedDate
        case .month, .schedule:
            // Step from the 1st so the day of month never drifts (Jan 31 → Feb 28 → Mar 28);
            // landing on the current month selects today.
            let target = c.date(byAdding: .month, value: dir, to: c.startOfMonth(selectedDate)) ?? selectedDate
            let today = c.startOfDay(for: env.now())
            selectedDate = c.isDate(target, equalTo: today, toGranularity: .month) ? today : target
        }
    }

    func show(day: Date, mode: ViewMode? = nil) {
        if let mode { viewMode = mode }
        selectedDate = cal.startOfDay(for: day)
    }

    /// Fetch three months around the selected date so navigation is usually instant.
    static func fetchWindow(around d: Date, calendar cal: Calendar) -> DateInterval {
        let m = cal.startOfMonth(d)
        let s = cal.startOfWeek(cal.date(byAdding: .month, value: -1, to: m)!)
        let e = cal.date(byAdding: .day, value: 14, to: cal.date(byAdding: .month, value: 2, to: m)!)!
        return DateInterval(start: s, end: e)
    }

    private func rangeDidChange() {
        let r = visibleRange
        if let w = pendingWindow, w.covers(r) { return }   // the load in flight will cover it
        if pendingWindow == nil, let w = loadedWindow, w.covers(r) { return }
        reloadEventsSoon()
    }

    private func reloadEventsSoon() {
        guard !accounts.isEmpty else { return }
        loadTask?.cancel()
        // Fix the window now, so further navigation can tell whether this load will cover it.
        let window = Self.fetchWindow(around: selectedDate, calendar: cal)
        pendingWindow = window
        loadTask = spawn { [weak self] in await self?.loadEvents(window: window) }
    }

    // MARK: - Calendars

    func calendars(for email: String) -> [GCalendar] { calendars.filter { $0.accountEmail == email } }
    func calendar(key: String) -> GCalendar? { calendars.first { $0.id == key } }
    func isVisible(_ c: GCalendar) -> Bool { visibility[c.id] ?? c.selectedInGoogle }

    func setVisible(_ c: GCalendar, _ on: Bool) {
        visibility[c.id] = on
        env.defaults.set(visibility, forKey: Keys.visibility)
        spawn { [weak self] in await self?.rescheduleNotifications() }
    }

    var writableCalendars: [GCalendar] { calendars.filter(\.canWrite) }
    private var visibleCalendars: [GCalendar] { calendars.filter { isVisible($0) } }

    var visibleEvents: [CalendarEvent] {
        let keys = Set(visibleCalendars.map(\.id))
        return events.filter { keys.contains($0.calendarKey) }
    }

    /// A user-facing reason for a failed Google request. The usual first-run mistake (Calendar API
    /// not enabled for the OAuth client's project) gets an explanation of how to fix it.
    static func describe(_ e: Error) -> String {
        if case APIError.http(403, let msg) = e,
           msg.localizedCaseInsensitiveContains("has not been used") || msg.localizedCaseInsensitiveContains("is disabled") {
            return "The Google Calendar API isn't enabled for your OAuth client's project. Enable it in Google Cloud Console (README, setup step 2), then refresh."
        }
        return "Couldn't reach Google: \(e.localizedDescription)"
    }

    private func hasAccount(_ email: String) -> Bool { accounts.contains { $0.email == email } }

    private func loadCalendars() async {
        let snapshot = accounts
        var result: [String: [GCalendar]] = [:]
        await withTaskGroup(of: (String, Result<[GCalendar], Error>).self) { group in
            for acc in snapshot {
                let api = api(for: acc.email)
                group.addTask {
                    do {
                        let list = try await api.calendarList()
                        return (acc.email, .success(list.map { GCalendar(accountEmail: acc.email, dto: $0) }))
                    } catch {
                        return (acc.email, .failure(error))
                    }
                }
            }
            for await (email, r) in group {
                guard hasAccount(email) else { continue }
                switch r {
                case .success(let cals):
                    result[email] = cals.sorted(by: GCalendar.order)
                    accountIssues[email] = nil
                case .failure(let e):
                    if !(e is CancellationError), accountIssues[email]?.needsReconnect != true {
                        accountIssues[email] = AccountIssue(message: Self.describe(e), needsReconnect: false)
                    }
                }
            }
        }
        // Use the current account list: an account removed while this was loading stays removed,
        // and one added meanwhile keeps its calendars.
        calendars = accounts.flatMap { result[$0.email] ?? calendars(for: $0.email) }
    }

    // MARK: - Events

    func loadEvents(window requested: DateInterval? = nil) async {
        guard !Task.isCancelled else { return }
        let window = requested ?? Self.fetchWindow(around: selectedDate, calendar: cal)
        generation += 1
        let gen = generation
        isLoading = true
        pendingWindow = window
        let (fetched, failed) = await fetchEvents(calendars: calendars, window: window)
        guard gen == generation else { return }
        isLoading = false
        pendingWindow = nil
        guard !Task.isCancelled else { return }
        let liveKeys = Set(calendars.map(\.id))
        // Keep what we had for calendars whose fetch failed (e.g. a transient network error).
        let kept = events.filter { failed.contains($0.calendarKey) && $0.overlaps(window) }
        events = (fetched + kept)
            .filter { liveKeys.contains($0.calendarKey) }
            .sorted(by: CalendarEvent.chronological)
        failedCalendarKeys = failed.intersection(liveKeys)
        loadedWindow = window
        // The user may have navigated elsewhere while this was loading.
        if !window.covers(visibleRange) { reloadEventsSoon() }
    }

    private func fetchEvents(calendars cals: [GCalendar], window: DateInterval,
                             query: String? = nil) async -> ([CalendarEvent], Set<String>) {
        var all: [CalendarEvent] = []
        var failed = Set<String>()
        var queue = cals[...]
        let c = cal
        let job = { [unowned self] (gc: GCalendar) -> @Sendable () async -> (String, [CalendarEvent]?) in
            let api = self.api(for: gc.accountEmail)
            return {
                do {
                    let dtos = try await api.events(calendarId: gc.calendarId, from: window.start,
                                                    to: window.end, query: query)
                    return (gc.id, dtos.compactMap { CalendarEvent(dto: $0, calendar: gc, using: c) })
                } catch {
                    return (gc.id, nil)
                }
            }
        }
        await withTaskGroup(of: (String, [CalendarEvent]?).self) { group in
            for _ in 0..<Self.maxConcurrentRequests {
                guard let gc = queue.popFirst() else { break }
                group.addTask(operation: job(gc))
            }
            for await (key, evs) in group {
                if let evs { all += evs } else { failed.insert(key) }
                if let gc = queue.popFirst() { group.addTask(operation: job(gc)) }
            }
        }
        return (all, failed)
    }

    /// Opens the editor for a new event. With no `start`, the next half hour today (or 9:00 on
    /// another selected day); with no `end`, one hour long. All-day events start and end on the start day.
    func beginCreate(at start: Date? = nil, end: Date? = nil, allDay: Bool = false) {
        guard let key = defaultCalendarKey else {
            if accounts.isEmpty {
                addAccount()
            } else {
                errorMessage = "None of your calendars can be edited. Ask the calendar's owner for edit access, or add an account you own."
            }
            return
        }
        let s = start ?? Self.defaultStart(now: env.now(), selected: selectedDate, calendar: cal)
        let c = cal
        editorDraft = EventDraft(existing: nil, calendarKey: key, isAllDay: allDay,
                                 start: allDay ? c.startOfDay(for: s) : s,
                                 end: allDay ? c.startOfDay(for: s) : (end ?? s.addingTimeInterval(3600)))
    }

    /// The next half hour today, or 9:00 on another selected day.
    static func defaultStart(now: Date, selected: Date, calendar cal: Calendar) -> Date {
        guard cal.isDate(selected, inSameDayAs: now) else {
            return cal.date(bySettingHour: 9, minute: 0, second: 0, of: selected) ?? selected
        }
        let minuteStart = cal.dateInterval(of: .minute, for: now)?.start ?? now
        let pastHalfHour = cal.component(.minute, from: minuteStart) % 30
        if pastHalfHour == 0 && minuteStart == now { return minuteStart }
        return minuteStart.addingTimeInterval(Double(30 - pastHalfHour) * 60)
    }

    func beginEdit(_ e: CalendarEvent) {
        editorDraft = EventDraft(existing: e, calendarKey: e.calendarKey,
                                 title: e.title == CalendarEvent.untitled ? "" : e.title,
                                 isAllDay: e.isAllDay, start: e.start, end: draftEnd(of: e),
                                 location: e.location ?? "", notes: e.plainNotes,
                                 guests: guestList(of: e))
    }

    /// The end shown in the editor: all-day ends are stored exclusive but shown inclusive.
    private func draftEnd(of e: CalendarEvent) -> Date {
        e.isAllDay ? (cal.date(byAdding: .day, value: -1, to: e.end) ?? e.end) : e.end
    }

    private func guestList(of e: CalendarEvent) -> String {
        e.attendees.filter { $0.isSelf != true && $0.resource != true }
            .compactMap(\.email).joined(separator: ", ")
    }

    var defaultCalendarKey: String? {
        let w = writableCalendars
        if let k = env.defaults.string(forKey: Keys.lastCalendar), w.contains(where: { $0.id == k }) {
            return k
        }
        return (w.first { $0.isPrimary } ?? w.first)?.id
    }

    /// Guest emails from free text: commas, semicolons, spaces or new lines; "Name <a@b.c>" works.
    nonisolated static func parseEmails(_ s: String) -> [String] {
        var seen = Set<String>()
        let strip = CharacterSet(charactersIn: "<>\"'()").union(.whitespaces)
        // `isNewline` also catches "\r\n", which Swift treats as a single Character.
        return s.split(whereSeparator: { $0.isNewline || $0.isWhitespace || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: strip).lowercased() }
            .filter { $0.contains("@") && seen.insert($0).inserted }
    }

    func save(_ d: EventDraft) async throws {
        guard let c = calendar(key: d.calendarKey) else { throw AppError.message("Choose a calendar.") }
        let k = cal
        let start: EventTimeWrite, end: EventTimeWrite
        if d.isAllDay {
            let s = k.startOfDay(for: d.start)
            let e = k.date(byAdding: .day, value: 1, to: k.startOfDay(for: d.end))!
            guard e > s else { throw AppError.message("The event must end on or after the day it starts.") }
            start = .allDay(s, calendar: k); end = .allDay(e, calendar: k)
        } else {
            guard d.end >= d.start else { throw AppError.message("The event must end after it starts.") }
            start = .timed(d.start, timeZone: k.timeZone); end = .timed(d.end, timeZone: k.timeZone)
        }
        let guests = Self.parseEmails(d.guests)
        let api = api(for: c.accountEmail)

        if let ex = d.existing {
            // PATCH only what changed, so untouched fields (e.g. the event's own time zone) survive.
            var p = EventWriteDTO()
            let oldTitle = ex.title == CalendarEvent.untitled ? "" : ex.title
            if d.title.trimmed != oldTitle { p.summary = d.title.trimmed }
            if d.location.trimmed != (ex.location ?? "").trimmed { p.location = d.location.trimmed }
            if d.notes != ex.plainNotes { p.description = d.notes }
            if d.isAllDay != ex.isAllDay || d.start != ex.start || d.end != draftEnd(of: ex) {
                p.start = start; p.end = end
            }
            if ex.isOrganizer && guests != Self.parseEmails(guestList(of: ex)) {
                // Keep existing attendee records (and their responses) for guests that remain.
                let kept = ex.attendees.filter { a in
                    a.isSelf == true || a.resource == true || guests.contains((a.email ?? "").lowercased())
                }
                let keptEmails = Set(kept.compactMap { $0.email?.lowercased() })
                p.attendees = kept + guests.filter { !keptEmails.contains($0) }.map { AttendeeDTO(email: $0) }
            }
            if d.addMeet && ex.meetLink == nil { p.conferenceData = .meet() }
            guard !p.isEmpty else { return }
            try await api.patchEvent(calendarId: ex.calendarId, eventId: ex.eventId, body: p,
                                     sendUpdates: d.savingNotifiesGuests ? .all : .none)
        } else {
            var body = EventWriteDTO(summary: d.title.trimmed, location: d.location.trimmed,
                                     description: d.notes, start: start, end: end)
            if !guests.isEmpty { body.attendees = guests.map { AttendeeDTO(email: $0) } }
            body.recurrence = d.repeatRule.rrule
            if d.addMeet { body.conferenceData = .meet() }
            try await api.insertEvent(calendarId: c.calendarId, body: body,
                                      sendUpdates: d.savingNotifiesGuests ? .all : .none)
            env.defaults.set(c.id, forKey: Keys.lastCalendar)
        }
        if !visibleRange.containsHalfOpen(d.start) { selectedDate = k.startOfDay(for: d.start) }
        if !isVisible(c) { setVisible(c, true) }
        await afterMutation()
    }

    /// Drag-to-move/resize on the grid: shows the new times at once, then saves them to Google.
    /// If Google refuses, the error is shown and the reload puts the event back.
    func move(_ e: CalendarEvent, start: Date, end: Date) {
        guard e.canEdit, !e.isAllDay, start != e.start || end != e.end else { return }
        if let i = events.firstIndex(where: { $0.id == e.id }) {
            events[i].start = start
            events[i].end = end
            events.sort(by: CalendarEvent.chronological)
        }
        let draft = EventDraft(existing: e, calendarKey: e.calendarKey,
                               title: e.title == CalendarEvent.untitled ? "" : e.title,
                               isAllDay: false, start: start, end: end,
                               location: e.location ?? "", notes: e.plainNotes, guests: guestList(of: e))
        spawn { [weak self] in
            guard let self else { return }
            do {
                try await self.save(draft)
            } catch {
                self.errorMessage = error.localizedDescription
                await self.loadEvents()
            }
        }
    }

    func delete(_ e: CalendarEvent, allOccurrences: Bool) async {
        let target = allOccurrences ? (e.recurringEventId ?? e.eventId) : e.eventId
        // An organiser deleting a meeting cancels it for the guests, so tell them.
        let notify = e.deletionNotifiesGuests
        do {
            try await api(for: e.accountEmail).deleteEvent(calendarId: e.calendarId, eventId: target,
                                                           sendUpdates: notify ? .all : .none)
            events.removeAll {
                $0.id == e.id || (allOccurrences && e.recurringEventId != nil
                    && $0.recurringEventId == e.recurringEventId && $0.calendarKey == e.calendarKey)
            }
            searchResults?.removeAll { $0.id == e.id }
        } catch {
            errorMessage = error.localizedDescription
        }
        await afterMutation()
    }

    func respond(_ e: CalendarEvent, _ status: String) async {
        guard let me = e.selfAttendee, let email = me.email else { return }
        // Send only our own response; attendeesOmitted tells Google to leave the other guests alone.
        let body = EventWriteDTO(attendees: [AttendeeDTO(email: email, responseStatus: status)],
                                 attendeesOmitted: true)
        do {
            try await api(for: e.accountEmail).patchEvent(calendarId: e.calendarId, eventId: e.eventId,
                                                          body: body, sendUpdates: .all)
        } catch {
            errorMessage = error.localizedDescription
        }
        await afterMutation()
    }

    private func afterMutation() async {
        await loadEvents()
        await rescheduleNotifications()
        if searchResults != nil { await performSearch() }
    }

    // MARK: - Search

    func performSearch() async {
        let q = searchText.trimmed
        searchGeneration += 1
        let gen = searchGeneration
        guard !q.isEmpty else {
            searchResults = nil
            searchFailedCalendarKeys = []
            isSearching = false
            return
        }
        isSearching = true
        let now = env.now()
        let window = DateInterval(start: cal.date(byAdding: .year, value: -1, to: now)!,
                                  end: cal.date(byAdding: .year, value: 2, to: now)!)
        let (r, failed) = await fetchEvents(calendars: visibleCalendars, window: window, query: q)
        guard gen == searchGeneration else { return }
        isSearching = false
        let live = Set(accounts.map(\.email))
        searchResults = r.filter { live.contains($0.accountEmail) }
            .sorted(by: CalendarEvent.chronological)
        searchFailedCalendarKeys = failed.intersection(Set(calendars.map(\.id)))
    }

    func clearSearch() {
        searchText = ""
        endSearch()
    }

    private func endSearch() {
        searchGeneration += 1
        searchResults = nil
        searchFailedCalendarKeys = []
        isSearching = false
    }

    // MARK: - Notifications

    private func rescheduleNotifications() async {
        notificationGeneration += 1
        let gen = notificationGeneration
        let now = env.now()
        let horizon = DateInterval(start: now, duration: Self.notificationHorizon)
        let visible = visibleCalendars
        let keys = Set(visible.map(\.id))
        let fresh: [CalendarEvent]
        let failed: Set<String>
        if let w = loadedWindow, w.covers(horizon) {
            fresh = events.filter { keys.contains($0.calendarKey) && !failedCalendarKeys.contains($0.calendarKey) }
            failed = failedCalendarKeys.intersection(keys)
        } else {
            (fresh, failed) = await fetchEvents(calendars: visible, window: horizon)
        }
        guard gen == notificationGeneration else { return }
        let liveKeys = Set(calendars.filter { isVisible($0) }.map(\.id))
        // Calendars that loaded give fresh reminders; a calendar that failed keeps the reminders it
        // had, so one broken account neither wipes nor freezes the others' reminders.
        var byCalendar: [String: [CalendarEvent]] = [:]
        for e in fresh where e.overlaps(horizon) { byCalendar[e.calendarKey, default: []].append(e) }
        var next: [String: [CalendarEvent]] = [:]
        for key in keys where liveKeys.contains(key) {
            next[key] = failed.contains(key) ? (lastNotified[key] ?? []) : (byCalendar[key] ?? [])
        }
        lastNotified = next
        env.notifier.reschedule(next.values.flatMap { $0 }.sorted { $0.id < $1.id }, now: now)
    }

    // MARK: - Accounts & auth

    /// Forgets all Google data (not the accounts themselves) and invalidates every load, search and
    /// reminder update still in flight, so none of them can bring the old data back.
    private func resetData() {
        generation += 1
        searchGeneration += 1
        notificationGeneration += 1
        loadTask?.cancel()
        pendingWindow = nil
        isLoading = false
        isSearching = false
        calendars = []
        events = []
        loadedWindow = nil
        failedCalendarKeys = []
        searchResults = nil
        searchFailedCalendarKeys = []
        lastNotified = [:]
        env.notifier.reschedule([], now: env.now())
    }

    static let vaultLockedMessage = "Daymark can't read its saved accounts from the Keychain, so it won't change them. Quit and reopen Daymark, and choose Always Allow if macOS asks for Keychain access."

    func saveClient(_ c: OAuthClient) {
        guard !vaultUnreadable else { errorMessage = Self.vaultLockedMessage; return }
        if let old = client, old != c {
            // A sign-in started with the old client would produce a token the new client can't use.
            signInTask?.cancel()
            signInID = UUID()
            isSigningIn = false
            if !accounts.isEmpty {
                // Refresh tokens belong to the client that issued them, so every account must sign in again.
                let revoke = env.oauth.revoke
                for acc in accounts {
                    let token = acc.refreshToken
                    spawn { await revoke(token) }
                }
                accounts = []
                tokens = [:]
                accountIssues = [:]
                resetData()
            }
        }
        client = c
        persist()
        showSetup = false
    }

    func addAccount() {
        guard !vaultUnreadable else { errorMessage = Self.vaultLockedMessage; return }
        guard let client else { showSetup = true; return }
        signInTask?.cancel()
        let id = UUID()
        signInID = id
        isSigningIn = true
        let signIn = env.oauth.signIn
        signInTask = spawn { [weak self] in
            do {
                let r = try await signIn(client)
                guard let self, !Task.isCancelled, self.signInID == id else { return }
                // The client may have changed while the browser was open; that token is useless now.
                guard self.client == client else {
                    let revoke = self.env.oauth.revoke
                    self.spawn { await revoke(r.refreshToken) }
                    return
                }
                // Google may return a different capitalisation on a later sign-in; it's the same account.
                let email: String
                if let i = self.accounts.firstIndex(where: { $0.email.lowercased() == r.email.lowercased() }) {
                    email = self.accounts[i].email
                    // The old token stays valid at Google until revoked; don't leave it lying around.
                    let old = self.accounts[i].refreshToken
                    if old != r.refreshToken {
                        let revoke = self.env.oauth.revoke
                        self.spawn { await revoke(old) }
                    }
                    self.accounts[i].refreshToken = r.refreshToken
                } else {
                    email = r.email
                    self.accounts.append(Account(email: r.email, refreshToken: r.refreshToken))
                }
                self.tokens[email] = r.token
                self.accountIssues[email] = nil
                self.persist()
                self.isSigningIn = false
                self.env.activateApp()
                await self.refresh()
            } catch {
                guard let self, self.signInID == id else { return }
                self.isSigningIn = false
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                if let u = error as? URLError, u.code == .cancelled { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInID = UUID()
        isSigningIn = false
    }

    func removeAccount(_ email: String) {
        guard !vaultUnreadable else { errorMessage = Self.vaultLockedMessage; return }
        guard let acc = accounts.first(where: { $0.email == email }) else { return }
        accounts.removeAll { $0.email == email }
        tokens[email] = nil
        accountIssues[email] = nil
        calendars.removeAll { $0.accountEmail == email }
        events.removeAll { $0.accountEmail == email }
        failedCalendarKeys = failedCalendarKeys.filter { !$0.hasPrefix(email + "|") }
        searchResults?.removeAll { $0.accountEmail == email }
        searchFailedCalendarKeys = searchFailedCalendarKeys.filter { !$0.hasPrefix(email + "|") }
        persist()
        let revoke = env.oauth.revoke
        spawn { await revoke(acc.refreshToken) }
        if accounts.isEmpty {
            resetData()
        } else {
            spawn { [weak self] in await self?.rescheduleNotifications() }
        }
    }

    private func persist() {
        guard !vaultUnreadable else { return }
        do {
            try Vault(client: client, accounts: accounts).save(to: env.vault)
        } catch {
            errorMessage = "Couldn't save to the Keychain: \(error.localizedDescription)"
        }
    }

    func api(for email: String) -> GoogleCalendarAPI {
        GoogleCalendarAPI(tokenProvider: { [weak self] rejected in
            guard let self else { throw CancellationError() }
            return try await self.accessToken(for: email, rejecting: rejected)
        }, transport: env.transport, sleep: env.sleep, jitterMs: env.jitterMs)
    }

    private func accessToken(for email: String, rejecting rejected: String?) async throws -> String {
        if let t = tokens[email], t.isValid(at: env.now()), t.value != rejected { return t.value }
        if let task = tokenTasks[email] { return try await task.value.0.value }
        guard let client, let account = accounts.first(where: { $0.email == email }) else {
            throw OAuthError.notSignedIn
        }
        let refreshToken = account.refreshToken
        let refresh = env.oauth.refresh
        let task = Task { try await refresh(client, refreshToken) }
        tokenTasks[email] = task
        defer { tokenTasks[email] = nil }
        do {
            let (t, rotated) = try await task.value
            guard hasAccount(email), self.client == client else { throw OAuthError.notSignedIn }
            tokens[email] = t
            if let rotated, rotated != refreshToken,
               let i = accounts.firstIndex(where: { $0.email == email }) {
                accounts[i].refreshToken = rotated
                persist()
            }
            return t.value
        } catch let error as OAuthError {
            if hasAccount(email), self.client == client, error != .notSignedIn {
                accountIssues[email] = error.needsReconnect
                    ? AccountIssue(message: error.localizedDescription, needsReconnect: true)
                    : AccountIssue(message: "Couldn't reach Google: \(error.localizedDescription)", needsReconnect: false)
            }
            throw error
        }
    }
}
