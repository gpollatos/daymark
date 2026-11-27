import Foundation
@testable import Daymark

/// Fixed test calendar: Gregorian, New York, Sunday-first, POSIX locale.
func makeCalendar(_ tz: String = "America/New_York", firstWeekday: Int = 1) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    c.firstWeekday = firstWeekday
    c.minimumDaysInFirstWeek = 1
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

let NY = makeCalendar()

/// A wall-clock time in `cal`'s zone.
func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0, _ cal: Calendar = NY) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
}

/// Thursday 26 Nov 2026, 12:00 in New York.
let T0 = at(2026, 11, 26, 12)

enum Fx {
    static let client = OAuthClient(clientId: "123-abc.apps.googleusercontent.com", clientSecret: "GOCSPX-secret")
    static let otherClient = OAuthClient(clientId: "999-new.apps.googleusercontent.com", clientSecret: "GOCSPX-other")

    static let alice = "alice@gmail.com"
    static let bob = "bob@work.example"
    static let carol = "carol@school.example"

    static let holiday = "en.usa#holiday@group.v.calendar.google.com"
    static let family = "fam123@group.calendar.google.com"
    static let team = "team@group.calendar.google.com"

    static func key(_ email: String, _ cal: String) -> String { "\(email)|\(cal)" }
    static func id(_ email: String, _ cal: String, _ event: String) -> String { "\(email)|\(cal)|\(event)" }

    static func calendar(_ id: String, role: String, primary: Bool = false, selected: Bool? = true,
                         summary: String? = nil, color: String = "#9fe1e7", reminders: [Int] = []) -> JSON {
        var c: [String: Any] = ["id": id, "summary": summary ?? id, "accessRole": role, "backgroundColor": color,
                                "defaultReminders": reminders.map { ["method": "popup", "minutes": $0] }]
        if primary { c["primary"] = true }
        if let selected { c["selected"] = selected }
        return JSON(c)
    }

    static func timed(_ id: String, _ summary: String, _ start: Date, _ end: Date,
                      _ extra: [String: Any] = [:]) -> JSON {
        var e: [String: Any] = ["id": id, "iCalUID": "\(id)@google.com", "summary": summary, "status": "confirmed",
                                "start": ["dateTime": RFC3339.string(start), "timeZone": "America/New_York"],
                                "end": ["dateTime": RFC3339.string(end), "timeZone": "America/New_York"]]
        for (k, v) in extra { e[k] = v }
        return JSON(e)
    }

    static func allDay(_ id: String, _ summary: String, _ first: String, _ endExclusive: String,
                       _ extra: [String: Any] = [:]) -> JSON {
        var e: [String: Any] = ["id": id, "iCalUID": "\(id)@google.com", "summary": summary, "status": "confirmed",
                                "start": ["date": first], "end": ["date": endExclusive]]
        for (k, v) in extra { e[k] = v }
        return JSON(e)
    }

    static func refreshToken(_ email: String) -> String {
        switch email {
        case alice: "rt-A"
        case bob: "rt-B"
        case carol: "rt-C"
        default: "rt-\(email)"
        }
    }
}

@MainActor
final class World {
    let clock: TestClock
    let google: FakeGoogle
    let oauth: FakeOAuth
    let vault: MemoryVault
    let notifier = FakeNotifier()
    let sleeps = SleepRecorder()
    let defaults = MemoryPreferences()
    let calendar: Calendar
    var activations = 0
    private(set) var store: CalendarStore!

    init(calendar: Calendar = NY, now: Date = T0, vault: MemoryVault? = nil,
         accounts: [String] = [Fx.alice, Fx.bob, Fx.carol], client: OAuthClient? = Fx.client) async {
        self.calendar = calendar
        clock = TestClock(now)
        google = FakeGoogle(calendar: calendar)
        oauth = FakeOAuth(google: google, clock: clock)
        self.vault = vault ?? MemoryVault(Vault(client: client,
                                                accounts: accounts.map { Account(email: $0, refreshToken: Fx.refreshToken($0)) }))
        for a in [Fx.alice, Fx.bob, Fx.carol] { await oauth.own(Fx.refreshToken(a), by: a) }
        await Self.seedStandardCalendars(google)
        makeStore()
    }

    /// Builds a fresh store over the same fakes (e.g. to test what persists across launches).
    func makeStore() {
        let clock = self.clock, sleeps = self.sleeps, cal = calendar
        store = CalendarStore(env: AppEnvironment(
            calendar: { cal },
            now: { clock.now },
            defaults: defaults,
            vault: vault.storage,
            oauth: oauth.backend,
            transport: google.transport,
            sleep: { try await sleeps.sleep($0) },
            jitterMs: { 0 },
            notifier: notifier,
            activateApp: { [weak self] in self?.activations += 1 },
            startBackgroundWork: false))
    }

    /// Bootstraps and waits for all background work.
    @discardableResult
    func start() async -> CalendarStore {
        await store.bootstrap()
        await store.settle()
        return store
    }

    func settle() async { await store.settle() }

    static func seedStandardCalendars(_ g: FakeGoogle) async {
        await g.addCalendar(Fx.alice, Fx.calendar(Fx.alice, role: "owner", primary: true, summary: "Alice", reminders: [10]))
        await g.addCalendar(Fx.alice, Fx.calendar(Fx.holiday, role: "reader", selected: nil, summary: "Holidays in United States"))
        await g.addCalendar(Fx.alice, Fx.calendar(Fx.family, role: "writer", summary: "Family", color: "#7bd148"))
        await g.addCalendar(Fx.bob, Fx.calendar(Fx.bob, role: "owner", primary: true, summary: "Bob", reminders: [30]))
        await g.addCalendar(Fx.bob, Fx.calendar(Fx.team, role: "reader", summary: "Team"))
        await g.addCalendar(Fx.carol, Fx.calendar(Fx.carol, role: "owner", primary: true, summary: "Carol"))
        await g.addCalendar(Fx.carol, Fx.calendar(Fx.family, role: "reader", summary: "Family (shared)"))
    }

    // MARK: Conveniences

    func put(_ email: String, _ cal: String, _ e: JSON) async { await google.put(email, cal, e) }

    func requests(_ match: @escaping (RecordedRequest) -> Bool = { _ in true }) async -> [RecordedRequest] {
        await google.requests(where: match)
    }

    var eventIds: Set<String> { Set(store.events.map(\.id)) }
}

extension RecordedRequest {
    var bodyKeys: [String] { (body?.dict.keys).map { Array($0).sorted() } ?? [] }
}

/// Polls `condition` until true (for state reached by concurrent work that can't be awaited directly).
@MainActor
func eventually(_ what: String = "condition", timeout: Duration = .seconds(5),
                _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        if ContinuousClock.now > deadline { throw TestTimeout(what: what) }
        try await Task.sleep(for: .milliseconds(1))
    }
}

struct TestTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "Timed out waiting for \(what)" }
}

func googleError(_ code: Int, _ reason: String, _ message: String = "error") -> String {
    #"{"error":{"code":\#(code),"message":"\#(message)","errors":[{"domain":"global","reason":"\#(reason)","message":"\#(message)"}]}}"#
}
