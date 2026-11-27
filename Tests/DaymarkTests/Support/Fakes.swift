import Foundation
import Testing
@testable import Daymark

// MARK: - Small primitives

/// A JSON object that can cross actor boundaries.
struct JSON: @unchecked Sendable {
    var dict: [String: Any]
    init(_ dict: [String: Any]) { self.dict = dict }
    subscript(_ key: String) -> Any? {
        get { dict[key] }
        set { dict[key] = newValue }
    }
}

/// Blocks callers until opened. Used to hold a request or sign-in mid-flight. If a test never
/// opens it (because the app under test misbehaved), it opens itself after `timeout` and records
/// a failure, so a bug shows up as a failed test rather than a hung run.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var armed = false
    private let timeout: Duration
    private(set) var waiting = 0

    init(timeout: Duration = .seconds(10)) { self.timeout = timeout }

    func wait() async {
        if isOpen { return }
        waiting += 1
        if !armed {
            armed = true
            Task { [weak self, timeout] in
                try? await Task.sleep(for: timeout)
                await self?.expire()
            }
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func expire() {
        guard !isOpen else { return }
        Issue.record("A gate was never opened; the code under test is probably stuck or sent unexpected requests")
        open()
    }

    func open() {
        isOpen = true
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ d: Date) { value = d }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Duration] = []
    var gate: Gate?
    var durations: [Duration] { lock.withLock { recorded } }
    var milliseconds: [Int] { durations.map { Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000) } }

    func sleep(_ d: Duration) async throws {
        lock.withLock { recorded.append(d) }
        if let gate { await gate.wait() }
        try Task.checkCancellation()
    }
}

final class MemoryVault: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var allWrites: [Data] = []
    var readError: Error?
    var writeError: Error?
    private(set) var reads = 0

    init(_ vault: Vault? = nil) {
        stored = vault.flatMap { try? JSONEncoder().encode($0) }
    }

    init(raw: Data?) { stored = raw }

    var writes: [Data] { lock.withLock { allWrites } }
    var current: Vault? { lock.withLock { stored }.flatMap { try? JSONDecoder().decode(Vault.self, from: $0) } }

    var storage: VaultStorage {
        VaultStorage(read: { [self] in
            try lock.withLock {
                reads += 1
                if let readError { throw readError }
                return stored
            }
        }, write: { [self] data in
            try lock.withLock {
                if let writeError { throw writeError }
                stored = data
                allWrites.append(data)
            }
        })
    }
}

/// In-memory app preferences, so tests never write a preferences file to disk.
final class MemoryPreferences: Preferences, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { lock.withLock { values[key] as? String } }
    func dictionary(forKey key: String) -> [String: Any]? { lock.withLock { values[key] as? [String: Any] } }
    func set(_ value: Any?, forKey key: String) { lock.withLock { values[key] = value } }
}

@MainActor
final class FakeNotifier: ReminderScheduling {
    private(set) var calls: [[CalendarEvent]] = []
    var last: [CalendarEvent]? { calls.last }
    var lastIds: Set<String> { Set((calls.last ?? []).map(\.id)) }
    func reschedule(_ events: [CalendarEvent], now: Date) { calls.append(events) }
}

// MARK: - Fake Google Calendar API

struct RecordedRequest: Sendable {
    let method: String
    /// Percent-encoded path, exactly as sent (so encoding bugs are visible).
    let rawPath: String
    /// Decoded path segments after /calendar/v3/.
    let segments: [String]
    let query: [String: String]
    let queryNames: [String]
    let headers: [String: String]
    let body: JSON?
    let token: String?
    let account: String?

    var isEventsList: Bool { method == "GET" && segments.count == 3 && segments[0] == "calendars" && segments[2] == "events" }
    var calendarId: String? { segments.count >= 2 && segments[0] == "calendars" ? segments[1] : nil }
    var eventId: String? { segments.count == 4 ? segments[3] : nil }
}

actor FakeGoogle {
    enum Action: Sendable {
        case status(Int, String)
        case transportError(URLError.Code)
        case gate(Gate)
    }

    private struct Rule {
        let match: @Sendable (RecordedRequest) -> Bool
        var queue: [Action]
        let always: Action?
    }

    private struct Cal {
        var entry: JSON
        var events: [String: JSON] = [:]
    }

    let calendar: Calendar
    private var accounts: [String: [String: Cal]] = [:]     // email → calendarId → calendar
    private var calendarOrder: [String: [String]] = [:]
    private var tokens: [String: String] = [:]               // access token → email
    private var rules: [Rule] = []
    private var waiters: [(id: UUID, count: Int, match: @Sendable (RecordedRequest) -> Bool, cont: CheckedContinuation<Void, Never>)] = []
    private(set) var requests: [RecordedRequest] = []
    private(set) var inFlightEventLists = 0
    private(set) var maxInFlightEventLists = 0
    private(set) var inserts = 0
    private var nextId = 1
    var pageSize = 1000

    init(calendar: Calendar) { self.calendar = calendar }

    // MARK: Setup

    func addCalendar(_ email: String, _ entry: JSON) {
        let id = entry["id"] as! String
        accounts[email, default: [:]][id] = Cal(entry: entry)
        calendarOrder[email, default: []].append(id)
    }

    func put(_ email: String, _ calendarId: String, _ event: JSON) {
        let id = event["id"] as! String
        accounts[email]![calendarId]!.events[id] = event
    }

    func removeEvent(_ email: String, _ calendarId: String, _ eventId: String) {
        accounts[email]?[calendarId]?.events[eventId] = nil
    }

    func event(_ email: String, _ calendarId: String, _ eventId: String) -> JSON? {
        accounts[email]?[calendarId]?.events[eventId]
    }

    func eventCount(_ email: String, _ calendarId: String) -> Int {
        accounts[email]?[calendarId]?.events.count ?? 0
    }

    func register(token: String, for email: String) { tokens[token] = email }
    func revokeAccessTokens(of email: String) { tokens = tokens.filter { $0.value != email } }

    /// Every matching request performs the next queued action; once the queue is empty the
    /// rule stops applying (or applies `always` forever).
    func on(_ match: @escaping @Sendable (RecordedRequest) -> Bool, _ actions: [Action] = [], always: Action? = nil) {
        rules.append(Rule(match: match, queue: actions, always: always))
    }

    func clearRules() { rules = [] }
    func clearRequests() { requests = [] }

    func requests(where match: (RecordedRequest) -> Bool) -> [RecordedRequest] { requests.filter(match) }

    /// Returns once `count` matching requests have arrived (including earlier ones). Gives up after
    /// `timeout` and records a test failure, so a broken app fails fast instead of hanging the run.
    func waitFor(_ count: Int = 1, timeout: Duration = .seconds(10),
                 where match: @escaping @Sendable (RecordedRequest) -> Bool) async {
        if requests.filter(match).count >= count { return }
        let id = UUID()
        await withCheckedContinuation { cont in
            waiters.append((id, count, match, cont))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(id, count)
            }
        }
    }

    private func expire(_ id: UUID, _ count: Int) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).cont.resume()
        Issue.record("Timed out waiting for \(count) matching request(s)")
    }

    // MARK: Transport

    nonisolated var transport: HTTPTransport {
        { [self] req in try await self.handle(req) }
    }

    func handle(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let url = req.url!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let rawPath = comps.percentEncodedPath
        let prefix = "/calendar/v3/"
        let segments = rawPath.hasPrefix(prefix)
            ? rawPath.dropFirst(prefix.count).split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
            : []
        var query: [String: String] = [:]
        for item in comps.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
        let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : nil
        let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.map(JSON.init)
        let recorded = RecordedRequest(method: req.httpMethod ?? "GET", rawPath: rawPath, segments: segments,
                                       query: query, queryNames: (comps.queryItems ?? []).map(\.name),
                                       headers: req.allHTTPHeaderFields ?? [:], body: body,
                                       token: token, account: token.flatMap { tokens[$0] })
        requests.append(recorded)
        resumeWaiters()

        let isList = recorded.isEventsList
        if isList {
            inFlightEventLists += 1
            maxInFlightEventLists = max(maxInFlightEventLists, inFlightEventLists)
        }
        defer { if isList { inFlightEventLists -= 1 } }

        // Rules apply in order; a gate holds the request, then later rules (e.g. a failure) may still apply.
        var from = 0
        while let i = rules.indices.dropFirst(from).first(where: { rules[$0].match(recorded) && (!rules[$0].queue.isEmpty || rules[$0].always != nil) }) {
            let action: Action
            if !rules[i].queue.isEmpty { action = rules[i].queue.removeFirst() } else { action = rules[i].always! }
            switch action {
            case .status(let code, let body):
                return (Data(body.utf8), response(url, code))
            case .transportError(let code):
                throw URLError(code)
            case .gate(let g):
                await g.wait()
                try Task.checkCancellation()
                from = i + 1
            }
        }
        return route(recorded, url)
    }

    private func resumeWaiters() {
        var remaining: [(id: UUID, count: Int, match: @Sendable (RecordedRequest) -> Bool, cont: CheckedContinuation<Void, Never>)] = []
        for w in waiters {
            if requests.filter(w.match).count >= w.count { w.cont.resume() } else { remaining.append(w) }
        }
        waiters = remaining
    }

    private func response(_ url: URL, _ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }

    private func json(_ url: URL, _ code: Int, _ obj: Any) -> (Data, URLResponse) {
        (try! JSONSerialization.data(withJSONObject: obj), response(url, code))
    }

    private func error(_ url: URL, _ code: Int, _ message: String, reason: String = "invalid") -> (Data, URLResponse) {
        json(url, code, ["error": ["code": code, "message": message, "errors": [["reason": reason, "message": message]]]])
    }

    private static let allowed: [String: Set<String>] = [
        "calendarList": ["maxResults", "pageToken"],
        "list": ["timeMin", "timeMax", "singleEvents", "orderBy", "maxResults", "q", "pageToken"],
        "write": ["sendUpdates", "conferenceDataVersion"],
        "delete": ["sendUpdates"],
    ]

    private func route(_ r: RecordedRequest, _ url: URL) -> (Data, URLResponse) {
        guard let email = r.account else { return error(url, 401, "Invalid Credentials", reason: "authError") }
        let s = r.segments
        let kind: String
        switch (r.method, s.count) {
        case ("GET", 3) where s[0] == "users": kind = "calendarList"
        case ("GET", 3): kind = "list"
        case ("POST", 3), ("PATCH", 4): kind = "write"
        case ("DELETE", 4): kind = "delete"
        default: return error(url, 404, "Not Found", reason: "notFound")
        }
        if let bad = r.queryNames.first(where: { !Self.allowed[kind]!.contains($0) }) {
            return error(url, 400, "Unknown parameter \(bad)")
        }
        if kind == "calendarList" {
            let ids = calendarOrder[email] ?? []
            let entries = ids.compactMap { accounts[email]?[$0]?.entry.dict }
            return page(url, entries, r.query["pageToken"])
        }
        guard let cid = r.calendarId, accounts[email]?[cid] != nil else {
            return error(url, 404, "Not Found", reason: "notFound")
        }
        switch r.method {
        case "GET":
            let tmin = r.query["timeMin"].flatMap(RFC3339.parse) ?? .distantPast
            let tmax = r.query["timeMax"].flatMap(RFC3339.parse) ?? .distantFuture
            let q = r.query["q"]?.lowercased()
            let items = accounts[email]![cid]!.events.values
                .filter { e in
                    guard let (st, en) = times(e) else { return false }
                    return st < tmax && en > tmin
                }
                .filter { e in
                    guard let q else { return true }
                    let hay = [e["summary"], e["description"], e["location"]].compactMap { $0 as? String }
                        + ((e["attendees"] as? [[String: Any]]) ?? []).compactMap { $0["email"] as? String }
                    return hay.contains { $0.lowercased().contains(q) }
                }
                .sorted { (times($0)!.0, $0["id"] as! String) < (times($1)!.0, $1["id"] as! String) }
                .map(\.dict)
            return page(url, items, r.query["pageToken"])
        case "POST":
            inserts += 1
            var e = r.body ?? JSON([:])
            let id = "new\(nextId)"
            nextId += 1
            e["id"] = id
            e["iCalUID"] = "\(id)@google.com"
            e["organizer"] = ["email": cid, "self": true]
            if e["conferenceData"] != nil { e["hangoutLink"] = "https://meet.google.com/\(id)" }
            e["conferenceData"] = nil
            accounts[email]![cid]!.events[id] = e
            return json(url, 200, e.dict)
        case "PATCH":
            guard let eid = r.eventId, var e = accounts[email]![cid]!.events[eid] else {
                return error(url, 404, "Not Found", reason: "notFound")
            }
            let patch = r.body ?? JSON([:])
            for (k, v) in patch.dict where k != "attendeesOmitted" && k != "conferenceData" {
                if k == "attendees", patch["attendeesOmitted"] as? Bool == true {
                    var current = (e["attendees"] as? [[String: Any]]) ?? []
                    for a in v as? [[String: Any]] ?? [] {
                        if let i = current.firstIndex(where: { ($0["email"] as? String) == (a["email"] as? String) }) {
                            for (ak, av) in a { current[i][ak] = av }
                        }
                    }
                    e["attendees"] = current
                } else if v is NSNull {
                    e[k] = nil
                } else {
                    e[k] = v
                }
            }
            if patch["conferenceData"] != nil { e["hangoutLink"] = "https://meet.google.com/\(eid)" }
            accounts[email]![cid]!.events[eid] = e
            return json(url, 200, e.dict)
        case "DELETE":
            guard let eid = r.eventId else { return error(url, 404, "Not Found") }
            var cal = accounts[email]![cid]!
            if cal.events[eid] != nil {
                cal.events[eid] = nil
            } else {
                // Deleting a recurring series by its parent id removes its instances.
                let instances = cal.events.filter { ($0.value["recurringEventId"] as? String) == eid }
                guard !instances.isEmpty else { return error(url, 404, "Not Found", reason: "notFound") }
                for k in instances.keys { cal.events[k] = nil }
            }
            accounts[email]![cid] = cal
            return (Data(), response(url, 204))
        default:
            return error(url, 405, "Method not allowed")
        }
    }

    private func page(_ url: URL, _ items: [[String: Any]], _ token: String?) -> (Data, URLResponse) {
        let offset = token.flatMap { Int($0.dropFirst()) } ?? 0
        let slice = Array(items.dropFirst(offset).prefix(pageSize))
        var obj: [String: Any] = ["items": slice]
        if offset + slice.count < items.count { obj["nextPageToken"] = "p\(offset + slice.count)" }
        return json(url, 200, obj)
    }

    private func times(_ e: JSON) -> (Date, Date)? {
        func parse(_ any: Any?) -> Date? {
            guard let o = any as? [String: Any] else { return nil }
            if let dt = o["dateTime"] as? String { return RFC3339.parse(dt) }
            if let d = o["date"] as? String { return RFC3339.parseDay(d, calendar: calendar) }
            return nil
        }
        guard let s = parse(e["start"]), let en = parse(e["end"]) else { return nil }
        return (s, en)
    }
}

// MARK: - Fake OAuth

actor FakeOAuth {
    enum Failure: Sendable {
        case invalidGrant
        case clientRejected
        case server(String)
        case network
    }

    struct RefreshCall: Sendable, Equatable {
        let clientId: String
        let clientSecret: String
        let refreshToken: String
    }

    let google: FakeGoogle
    let clock: TestClock
    private var owners: [String: String] = [:]      // refresh token → email
    private var failures: [String: Failure] = [:]   // email → persistent failure
    private var gates: [String: Gate] = [:]
    private var rotations: [String: String] = [:]   // email → new refresh token (once)
    private var counter = 0
    var expiresIn: TimeInterval = 3600
    private(set) var refreshCalls: [RefreshCall] = []
    private(set) var revoked: [String] = []
    private var signIns: [Result<(email: String, refreshToken: String), Error>] = []
    var signInGate: Gate?
    private(set) var signInClients: [String] = []

    init(google: FakeGoogle, clock: TestClock) {
        self.google = google
        self.clock = clock
    }

    func own(_ refreshToken: String, by email: String) { owners[refreshToken] = email }
    func fail(_ email: String, _ f: Failure?) { failures[email] = f }
    func gate(_ email: String, _ g: Gate?) { gates[email] = g }
    func rotate(_ email: String, to newToken: String) { rotations[email] = newToken }
    func setExpiresIn(_ s: TimeInterval) { expiresIn = s }
    func queueSignIn(email: String, refreshToken: String) {
        owners[refreshToken] = email
        signIns.append(.success((email, refreshToken)))
    }
    func queueSignInFailure(_ e: Error) { signIns.append(.failure(e)) }
    func setSignInGate(_ g: Gate?) { signInGate = g }
    func refreshCount(for refreshToken: String) -> Int { refreshCalls.filter { $0.refreshToken == refreshToken }.count }

    func refresh(_ client: OAuthClient, _ refreshToken: String) async throws -> (AccessToken, String?) {
        refreshCalls.append(RefreshCall(clientId: client.clientId, clientSecret: client.clientSecret, refreshToken: refreshToken))
        guard let email = owners[refreshToken] else { throw OAuthError.invalidGrant }
        if let g = gates[email] { await g.wait() }
        switch failures[email] {
        case .invalidGrant?: throw OAuthError.invalidGrant
        case .clientRejected?: throw OAuthError.clientRejected("invalid_client")
        case .server(let m)?: throw OAuthError.server(m)
        case .network?: throw URLError(.notConnectedToInternet)
        case nil: break
        }
        counter += 1
        let token = "at-\(email)-\(counter)"
        await google.register(token: token, for: email)
        var rotated: String?
        if let r = rotations.removeValue(forKey: email) {
            owners[r] = email
            rotated = r
        }
        return (AccessToken(value: token, expiry: clock.now.addingTimeInterval(expiresIn)), rotated)
    }

    func signIn(_ client: OAuthClient) async throws -> SignInResult {
        signInClients.append(client.clientId)
        if let g = signInGate { await g.wait() }
        try Task.checkCancellation()
        guard !signIns.isEmpty else { throw OAuthError.denied("no queued sign-in") }
        let r = signIns.removeFirst()
        let (email, rt) = try r.get()
        counter += 1
        let token = "at-\(email)-\(counter)"
        await google.register(token: token, for: email)
        return SignInResult(email: email, refreshToken: rt,
                            token: AccessToken(value: token, expiry: clock.now.addingTimeInterval(expiresIn)))
    }

    func revoke(_ token: String) { revoked.append(token) }

    nonisolated var backend: OAuthBackend {
        OAuthBackend(signIn: { try await self.signIn($0) },
                     refresh: { try await self.refresh($0, $1) },
                     revoke: { await self.revoke($0) })
    }
}
