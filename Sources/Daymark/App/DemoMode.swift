import Foundation

/// Demo mode: `open Daymark.app --args --demo`.
///
/// Runs the real app against fictional accounts and an in-memory fake Google Calendar, so you
/// can try Daymark (or take screenshots) without a Google account. Nothing touches the Keychain,
/// the network, your preferences or Notification Center, and nothing is saved.
enum DemoMode {
    static var isEnabled: Bool {
        CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["DAYMARK_DEMO"] == "1"
    }

    static let client = OAuthClient(clientId: "demo.apps.googleusercontent.com", clientSecret: "demo")
    static let accounts = ["alex.rivera@example.com", "alex@northwind.example", "alex.rivera@fernhill.example"]
}

extension AppEnvironment {
    @MainActor
    static var demo: AppEnvironment {
        let google = DemoGoogle(now: Date(), calendar: .current)
        let vault = Vault(client: DemoMode.client,
                          accounts: DemoMode.accounts.map { Account(email: $0, refreshToken: "demo-refresh|\($0)") })
        let vaultData = (try? JSONEncoder().encode(vault)) ?? Data()
        return AppEnvironment(
            defaults: DemoPreferences(),
            vault: VaultStorage(read: { vaultData }, write: { _ in }),
            oauth: OAuthBackend(
                signIn: { _ in throw AppError.message("Adding accounts is turned off in demo mode.") },
                refresh: { _, refreshToken in
                    let email = refreshToken.replacingOccurrences(of: "demo-refresh|", with: "")
                    return (AccessToken(value: "demo-access|\(email)", expiry: Date().addingTimeInterval(86_400)), nil)
                },
                revoke: { _ in }),
            transport: google.transport,
            notifier: DemoNotifier(),
            startBackgroundWork: true)
    }
}

/// Preferences that live only for this run.
private final class DemoPreferences: Preferences, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] as? String } }
    func dictionary(forKey key: String) -> [String: Any]? { lock.withLock { values[key] as? [String: Any] } }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
}

@MainActor
private final class DemoNotifier: ReminderScheduling {
    func reschedule(_ events: [CalendarEvent], now: Date) {}
}

/// A small in-memory stand-in for the Google Calendar API, seeded with fictional calendars and
/// events around today. Supports the requests Daymark makes: calendar list, event list (with
/// time window and search), insert, patch and delete.
private actor DemoGoogle {
    private struct Cal {
        var entry: [String: Any]
        var events: [String: [String: Any]] = [:]
    }

    private var data: [String: [(id: String, cal: Cal)]] = [:]
    private var nextId = 1
    private let calendar: Calendar
    private let now: Date
    private var seeded = false

    init(now: Date, calendar: Calendar) {
        self.calendar = calendar
        self.now = now
    }

    /// Builds the fictional calendars and events on first use.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        let (personal, work, school) = (DemoMode.accounts[0], DemoMode.accounts[1], DemoMode.accounts[2])
        func entry(_ id: String, _ name: String, _ color: String, role: String = "owner", primary: Bool = false,
                   selected: Bool = true, reminder: Int? = 10) -> [String: Any] {
            var e: [String: Any] = ["id": id, "summary": name, "backgroundColor": color, "accessRole": role,
                                    "selected": selected, "primary": primary]
            if let reminder { e["defaultReminders"] = [["method": "popup", "minutes": reminder]] }
            return e
        }
        data[personal] = [
            (personal, Cal(entry: entry(personal, "Alex Rivera", "#9fc6e7", primary: true))),
            ("family-demo@group.calendar.google.com", Cal(entry: entry("family-demo@group.calendar.google.com", "Family", "#7bd148", role: "writer"))),
            ("en.usa#holiday@group.v.calendar.google.com", Cal(entry: entry("en.usa#holiday@group.v.calendar.google.com", "Holidays", "#16a765", role: "reader", reminder: nil))),
        ]
        data[work] = [
            (work, Cal(entry: entry(work, "Northwind", "#4986e7", primary: true))),
            ("design-team@group.calendar.google.com", Cal(entry: entry("design-team@group.calendar.google.com", "Design team", "#cd74e6", role: "reader"))),
        ]
        data[school] = [
            (school, Cal(entry: entry(school, "Fernhill evening classes", "#ffad46", primary: true))),
        ]
        seed(now: now, personal: personal, work: work, school: school)
    }

    // MARK: Seed data (all fictional)

    private func seed(now: Date, personal: String, work: String, school: String) {
        let cal = calendar
        let monday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)).flatMap { start in
            (0..<7).lazy.compactMap { cal.date(byAdding: .day, value: $0, to: start) }.first { cal.component(.weekday, from: $0) == 2 }
        } ?? cal.startOfDay(for: now)

        func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
            let d = cal.date(byAdding: .day, value: day, to: monday)!
            return cal.date(bySettingHour: h, minute: m, second: 0, of: d)!
        }
        func dayString(_ day: Int) -> String { RFC3339.dayString(cal.date(byAdding: .day, value: day, to: monday)!, calendar: cal) }

        let team = ["sam.okafor@northwind.example", "priya.nair@northwind.example", "jonas.weber@northwind.example"]
        func guests(_ others: [String], me: String, organizer: String? = nil, myResponse: String = "accepted") -> [[String: Any]] {
            [["email": me, "self": true, "responseStatus": myResponse, "organizer": organizer == nil]]
                + others.map { ["email": $0, "responseStatus": "accepted", "organizer": $0 == organizer] }
        }

        for day in 0..<5 {
            add(work, work, "Team standup", at(day, 9, 30), at(day, 9, 45),
                ["recurringEventId": "standup", "hangoutLink": "https://meet.google.com/abc-defg-hij",
                 "attendees": guests(team, me: work)])
        }
        add(work, work, "Sprint planning", at(0, 10), at(0, 11, 30), ["attendees": guests(team, me: work), "location": "Room Atlas"])
        add(work, work, "Design review", at(1, 11), at(1, 12),
            ["hangoutLink": "https://meet.google.com/xyz-uvwx-rst", "attendees": guests(team, me: work)])
        add(work, "design-team@group.calendar.google.com", "Prototype critique", at(1, 14), at(1, 15, 30), [:])
        add(work, work, "1:1 with Priya", at(3, 15), at(3, 15, 30),
            ["organizer": ["email": "priya.nair@northwind.example"],
             "attendees": guests(["priya.nair@northwind.example"], me: work, organizer: "priya.nair@northwind.example")])
        add(work, work, "Quarterly all-hands", at(4, 16), at(4, 17),
            ["organizer": ["email": "ceo@northwind.example"],
             "attendees": guests(["ceo@northwind.example"] + team, me: work, organizer: "ceo@northwind.example", myResponse: "needsAction")])
        add(work, work, "Focus time", at(2, 13), at(2, 16), ["colorId": "8"])
        addAllDay(work, work, "Team offsite", dayString(3), dayString(5), ["location": "Lakeside Lodge"])

        for day in [0, 2, 4] { add(personal, personal, "Gym", at(day, 7), at(day, 8), ["colorId": "2"]) }
        add(personal, personal, "Lunch with Sam", at(2, 12, 30), at(2, 13, 30), ["location": "Café Lumen"])
        add(personal, personal, "Dentist", at(4, 8, 30), at(4, 9, 15), ["colorId": "6", "location": "Smile Dental"])
        add(personal, "family-demo@group.calendar.google.com", "Family dinner", at(5, 19), at(5, 21), [:])
        add(personal, "family-demo@group.calendar.google.com", "Kids' swim lesson", at(1, 17, 30), at(1, 18, 30), [:])
        addAllDay(personal, "family-demo@group.calendar.google.com", "Mia's birthday", dayString(6), dayString(7), [:])

        add(school, school, "Spanish B1", at(1, 19), at(1, 20, 30), ["location": "Room 12"])
        add(school, school, "Spanish B1", at(3, 19), at(3, 20, 30), ["location": "Room 12"])
    }

    private func add(_ account: String, _ calId: String, _ title: String, _ start: Date, _ end: Date, _ extra: [String: Any]) {
        var e: [String: Any] = ["summary": title,
                                "start": ["dateTime": RFC3339.string(start)], "end": ["dateTime": RFC3339.string(end)]]
        for (k, v) in extra { e[k] = v }
        insert(account, calId, e)
    }

    private func addAllDay(_ account: String, _ calId: String, _ title: String, _ first: String, _ endExclusive: String, _ extra: [String: Any]) {
        var e: [String: Any] = ["summary": title, "start": ["date": first], "end": ["date": endExclusive]]
        for (k, v) in extra { e[k] = v }
        insert(account, calId, e)
    }

    @discardableResult
    private func insert(_ account: String, _ calId: String, _ event: [String: Any]) -> [String: Any] {
        var e = event
        let id = "demo\(nextId)"
        nextId += 1
        e["id"] = id
        e["iCalUID"] = e["iCalUID"] ?? "\(id)@demo"
        e["status"] = "confirmed"
        if e["organizer"] == nil { e["organizer"] = ["email": calId, "self": true] }
        update(account, calId) { $0.events[id] = e }
        return e
    }

    private func update(_ account: String, _ calId: String, _ change: (inout Cal) -> Void) {
        guard let i = data[account]?.firstIndex(where: { $0.id == calId }) else { return }
        change(&data[account]![i].cal)
    }

    // MARK: Requests

    nonisolated var transport: HTTPTransport { { [self] req in try await self.handle(req) } }

    private func handle(_ req: URLRequest) async throws -> (Data, URLResponse) {
        seedIfNeeded()
        let url = req.url!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let segments = comps.percentEncodedPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let query = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let token = (req.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "Bearer demo-access|", with: "")
        guard let cals = data[token] else { return reply(url, 401, ["error": ["message": "Invalid Credentials"]]) }

        // .../calendar/v3/users/me/calendarList
        if segments.last == "calendarList" { return reply(url, 200, ["items": cals.map(\.cal.entry)]) }
        guard let ci = segments.firstIndex(of: "calendars"), ci + 1 < segments.count,
              let cal = cals.first(where: { $0.id == segments[ci + 1] }) else {
            return reply(url, 404, ["error": ["message": "Not Found"]])
        }
        let calId = cal.id
        let eventId = segments.count > ci + 3 ? segments[ci + 3] : nil
        let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]

        switch req.httpMethod ?? "GET" {
        case "GET":
            let tmin = query["timeMin"].flatMap(RFC3339.parse) ?? .distantPast
            let tmax = query["timeMax"].flatMap(RFC3339.parse) ?? .distantFuture
            let q = query["q"]?.lowercased()
            let items = cal.cal.events.values.filter { e in
                guard let (s, en) = times(e), s < tmax, en > tmin else { return false }
                guard let q else { return true }
                return [e["summary"], e["location"], e["description"]].compactMap { $0 as? String }
                    .contains { $0.lowercased().contains(q) }
            }
            return reply(url, 200, ["items": items])
        case "POST":
            var e = body
            if e["conferenceData"] != nil { e["hangoutLink"] = "https://meet.google.com/new-demo-call"; e["conferenceData"] = nil }
            return reply(url, 200, insert(token, calId, e))
        case "PATCH":
            guard let eventId, var e = cal.cal.events[eventId] else { return reply(url, 404, ["error": ["message": "Not Found"]]) }
            for (k, v) in body where k != "attendeesOmitted" && k != "conferenceData" {
                if k == "attendees", body["attendeesOmitted"] as? Bool == true, var current = e["attendees"] as? [[String: Any]] {
                    for a in v as? [[String: Any]] ?? [] {
                        if let i = current.firstIndex(where: { ($0["email"] as? String) == (a["email"] as? String) }) {
                            current[i]["responseStatus"] = a["responseStatus"]
                        }
                    }
                    e["attendees"] = current
                } else if v is NSNull {
                    e[k] = nil
                } else {
                    e[k] = v
                }
            }
            if body["conferenceData"] != nil { e["hangoutLink"] = "https://meet.google.com/new-demo-call" }
            let updated = e
            update(token, calId) { $0.events[eventId] = updated }
            return reply(url, 200, updated)
        case "DELETE":
            guard let eventId else { return reply(url, 404, ["error": ["message": "Not Found"]]) }
            update(token, calId) { cal in
                if cal.events[eventId] != nil { cal.events[eventId] = nil }
                else { cal.events = cal.events.filter { ($0.value["recurringEventId"] as? String) != eventId } }
            }
            return (Data(), HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        default:
            return reply(url, 405, ["error": ["message": "Method not allowed"]])
        }
    }

    private func times(_ e: [String: Any]) -> (Date, Date)? {
        func parse(_ any: Any?) -> Date? {
            guard let o = any as? [String: Any] else { return nil }
            if let dt = o["dateTime"] as? String { return RFC3339.parse(dt) }
            if let d = o["date"] as? String { return RFC3339.parseDay(d, calendar: calendar) }
            return nil
        }
        guard let s = parse(e["start"]), let en = parse(e["end"]) else { return nil }
        return (s, en)
    }

    private func reply(_ url: URL, _ code: Int, _ obj: Any) -> (Data, URLResponse) {
        ((try? JSONSerialization.data(withJSONObject: obj)) ?? Data(),
         HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}
