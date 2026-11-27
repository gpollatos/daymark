import CryptoKit
import Foundation
import Testing
@testable import Daymark

/// A scripted HTTP server: each call pops the next response and records the request.
actor ScriptedTransport {
    struct Reply: Sendable {
        let status: Int
        let body: String
        static func ok(_ body: String = "{}") -> Reply { Reply(status: 200, body: body) }
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    var gate: Gate?

    init(_ replies: [Reply]) { self.replies = replies }

    func handle(_ r: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(r)
        if let gate { await gate.wait() }
        let reply = replies.isEmpty ? Reply.ok() : replies.removeFirst()
        return (Data(reply.body.utf8),
                HTTPURLResponse(url: r.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
    }

    func setGate(_ g: Gate?) { gate = g }

    nonisolated var transport: HTTPTransport { { try await self.handle($0) } }
}

/// Records which token each request asked for.
final class TokenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String?] = []
    private var n = 0
    var rejections: [String?] { lock.withLock { log } }
    func next(_ rejected: String?) -> String {
        lock.withLock {
            log.append(rejected)
            if rejected != nil || n == 0 { n += 1 }
            return "tok\(n)"
        }
    }
}

private func api(_ t: ScriptedTransport, tokens: TokenLog = TokenLog(), sleeps: SleepRecorder = SleepRecorder()) -> GoogleCalendarAPI {
    GoogleCalendarAPI(tokenProvider: { tokens.next($0) }, transport: t.transport,
                      sleep: { try await sleeps.sleep($0) }, jitterMs: { 0 })
}

private func components(_ r: URLRequest) -> URLComponents { URLComponents(url: r.url!, resolvingAgainstBaseURL: false)! }
private func query(_ r: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (components(r).queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

@Suite("Google Calendar API client", .timeLimit(.minutes(1)))
struct APITests {
    @Test("List requests have the exact parameters Google expects")
    func listRequestShape() async throws {
        let t = ScriptedTransport([.ok(#"{"items":[]}"#), .ok(#"{"items":[]}"#)])
        let a = api(t)
        _ = try await a.calendarList()
        _ = try await a.events(calendarId: "primary", from: at(2026, 11, 1), to: at(2026, 12, 1), query: "standup")
        let reqs = await t.requests
        #expect(reqs[0].httpMethod == "GET")
        #expect(components(reqs[0]).percentEncodedPath == "/calendar/v3/users/me/calendarList")
        #expect(query(reqs[0]) == ["maxResults": "250"])
        #expect(query(reqs[1]) == ["timeMin": "2026-11-01T04:00:00Z", "timeMax": "2026-12-01T05:00:00Z",
                                   "singleEvents": "true", "orderBy": "startTime", "maxResults": "2500", "q": "standup"])
        #expect(reqs.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok1" })
        #expect(reqs.allSatisfy { $0.httpBody == nil && $0.value(forHTTPHeaderField: "Content-Type") == nil })
    }

    @Test("Calendar and event ids are percent-encoded as a single path segment", arguments: [
        ("en.usa#holiday@group.v.calendar.google.com", "en.usa%23holiday@group.v.calendar.google.com"),
        ("a/b", "a%2Fb"), ("x y", "x%20y"), ("50%", "50%25"), ("a+b", "a%2Bb"), ("a?b", "a%3Fb"),
        ("é", "%C3%A9"), ("primary", "primary"), ("abc_20261126T100000Z", "abc_20261126T100000Z"),
    ])
    func idEncoding(id: String, encoded: String) async throws {
        let t = ScriptedTransport([.ok(#"{"items":[]}"#), .ok(#"{"id":"e"}"#), .ok(#"{"id":"e"}"#), .ok()])
        let a = api(t)
        _ = try await a.events(calendarId: id, from: T0, to: T0.addingTimeInterval(60))
        try await a.insertEvent(calendarId: id, body: EventWriteDTO(summary: "x"), sendUpdates: .none)
        try await a.patchEvent(calendarId: id, eventId: id, body: EventWriteDTO(summary: "y"), sendUpdates: .none)
        try await a.deleteEvent(calendarId: id, eventId: id, sendUpdates: .none)
        let paths = await t.requests.map { components($0).percentEncodedPath }
        #expect(paths == ["/calendar/v3/calendars/\(encoded)/events", "/calendar/v3/calendars/\(encoded)/events",
                          "/calendar/v3/calendars/\(encoded)/events/\(encoded)", "/calendar/v3/calendars/\(encoded)/events/\(encoded)"])
        #expect(await t.requests.allSatisfy { $0.url?.host == "www.googleapis.com" && $0.url?.scheme == "https" })
        #expect(encoded.removingPercentEncoding == id)
    }

    @Test("Search text with &, +, % and accents reaches Google intact",
          arguments: ["a&b=c", "a+b", "100%", "é #x", "weekly sync?"])
    func queryEncoding(q: String) async throws {
        let t = ScriptedTransport([.ok(#"{"items":[]}"#)])
        _ = try await api(t).events(calendarId: "primary", from: T0, to: T0.addingTimeInterval(3600), query: q)
        let r = try #require(await t.requests.first)
        let items = components(r).queryItems ?? []
        #expect(items.count == 6)
        #expect(items.first { $0.name == "q" }?.value == q)
        #expect(!(components(r).percentEncodedQuery ?? "").contains("+"), "a raw + would be read as a space")
    }

    @Test("Pages are followed until the last one; deleted and hidden calendars are dropped")
    func pagination() async throws {
        let t = ScriptedTransport([
            .ok(#"{"items":[{"id":"1"},{"id":"2"}],"nextPageToken":"p2"}"#),
            .ok(#"{"items":[{"id":"3"},{"id":"4"}],"nextPageToken":"p3"}"#),
            .ok(#"{"items":[{"id":"5"}]}"#),
            .ok(#"{"items":[{"id":"a"},{"id":"gone","deleted":true}],"nextPageToken":"c2"}"#),
            .ok(#"{"items":[{"id":"hid","hidden":true},{"id":"b"}]}"#),
        ])
        let a = api(t)
        let events = try await a.events(calendarId: "primary", from: T0, to: T0.addingTimeInterval(86400))
        #expect(events.map(\.id) == ["1", "2", "3", "4", "5"])
        let cals = try await a.calendarList()
        #expect(cals.map(\.id) == ["a", "b"])
        let qs = await t.requests.map(query)
        #expect(qs[0]["pageToken"] == nil && qs[1]["pageToken"] == "p2" && qs[2]["pageToken"] == "p3")
        #expect(qs[3]["pageToken"] == nil && qs[4]["pageToken"] == "c2")
        // Everything but the page token is identical across pages.
        #expect(qs[1].filter { $0.key != "pageToken" } == qs[0])
    }

    @Test("A page that keeps failing fails the whole list (no truncated results)")
    func midPaginationFailure() async throws {
        let err = ScriptedTransport.Reply(status: 500, body: googleError(500, "backendError"))
        let t = ScriptedTransport([.ok(#"{"items":[{"id":"1"}],"nextPageToken":"p2"}"#), err, err, err, err])
        await #expect(throws: APIError.self) {
            _ = try await api(t).events(calendarId: "primary", from: T0, to: T0.addingTimeInterval(86400))
        }
    }

    struct RetryCase: Sendable, CustomTestStringConvertible {
        let method: String
        let status: Int
        let body: String
        let attempts: Int
        var testDescription: String { "\(method) \(status) \(body.prefix(60)) → \(attempts)" }
    }

    @Test("Which failures are retried", arguments: [
        RetryCase(method: "GET", status: 429, body: "{}", attempts: 4),
        RetryCase(method: "GET", status: 403, body: googleError(403, "rateLimitExceeded"), attempts: 4),
        RetryCase(method: "GET", status: 403, body: googleError(403, "userRateLimitExceeded"), attempts: 4),
        RetryCase(method: "GET", status: 403, body: googleError(403, "forbidden"), attempts: 1),
        RetryCase(method: "GET", status: 403, body: "", attempts: 1),
        RetryCase(method: "GET", status: 500, body: googleError(500, "backendError"), attempts: 4),
        RetryCase(method: "GET", status: 502, body: "<html>Bad Gateway</html>", attempts: 4),
        RetryCase(method: "GET", status: 503, body: "", attempts: 4),
        RetryCase(method: "GET", status: 400, body: googleError(400, "badRequest"), attempts: 1),
        RetryCase(method: "GET", status: 404, body: googleError(404, "notFound"), attempts: 1),
        RetryCase(method: "POST", status: 500, body: googleError(500, "backendError"), attempts: 1),
        RetryCase(method: "POST", status: 503, body: "", attempts: 1),
        RetryCase(method: "POST", status: 429, body: "{}", attempts: 4),
        RetryCase(method: "POST", status: 403, body: googleError(403, "rateLimitExceeded"), attempts: 4),
        RetryCase(method: "PATCH", status: 503, body: "", attempts: 4),
        RetryCase(method: "DELETE", status: 500, body: "", attempts: 4),
    ])
    func retryClassification(c: RetryCase) async throws {
        let t = ScriptedTransport(Array(repeating: .init(status: c.status, body: c.body), count: 10))
        let sleeps = SleepRecorder()
        let a = api(t, sleeps: sleeps)
        await #expect(throws: APIError.self) {
            switch c.method {
            case "GET": _ = try await a.calendarList()
            case "POST": try await a.insertEvent(calendarId: "c", body: EventWriteDTO(summary: "x"), sendUpdates: .none)
            case "PATCH": try await a.patchEvent(calendarId: "c", eventId: "e", body: EventWriteDTO(summary: "x"), sendUpdates: .none)
            default: try await a.deleteEvent(calendarId: "c", eventId: "e", sendUpdates: .none)
            }
        }
        #expect(await t.requests.count == c.attempts)
        #expect(await t.requests.allSatisfy { $0.httpMethod == c.method })
        #expect(sleeps.durations.count == c.attempts - 1)
    }

    @Test("Backoff doubles from 500 ms plus jitter; the final error carries Google's message")
    func backoffSchedule() async throws {
        for jitter in [0, 299] {
            let t = ScriptedTransport(Array(repeating: .init(status: 503, body: googleError(503, "backendError", "Backend Error")), count: 4))
            let sleeps = SleepRecorder()
            let a = GoogleCalendarAPI(tokenProvider: { _ in "tok" }, transport: t.transport,
                                      sleep: { try await sleeps.sleep($0) }, jitterMs: { jitter })
            do {
                _ = try await a.calendarList()
                Issue.record("should throw")
            } catch let APIError.http(code, message) {
                #expect(code == 503)
                #expect(message == "Backend Error")
            }
            #expect(sleeps.milliseconds == [500 + jitter, 1000 + jitter, 2000 + jitter])
        }
        // A non-JSON body falls back to the HTTP status text.
        let t = ScriptedTransport([.init(status: 404, body: "<html>nope</html>")])
        do {
            _ = try await api(t).calendarList()
        } catch let APIError.http(_, message) {
            #expect(message == HTTPURLResponse.localizedString(forStatusCode: 404))
        }
    }

    @Test("Cancelling during backoff stops retrying")
    func cancellationStopsRetries() async throws {
        let t = ScriptedTransport(Array(repeating: .init(status: 429, body: "{}"), count: 10))
        let sleeps = SleepRecorder()
        let gate = Gate()
        sleeps.gate = gate
        let a = api(t, sleeps: sleeps)
        let task = Task { try await a.calendarList() }
        try await eventually("first backoff") { sleeps.durations.count == 1 }
        task.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await t.requests.count == 1)
    }

    @Test("A 401 refreshes the token once; later retries don't force more refreshes")
    func unauthorizedHandling() async throws {
        // 401 → refresh → success
        var t = ScriptedTransport([.init(status: 401, body: "{}"), .ok(#"{"items":[]}"#)])
        var log = TokenLog()
        _ = try await api(t, tokens: log).calendarList()
        #expect(log.rejections == [nil, "tok1"])
        #expect(await t.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer tok1", "Bearer tok2"])

        // Two 401s in a row: give up after exactly two attempts.
        t = ScriptedTransport([.init(status: 401, body: "{}"), .init(status: 401, body: "{}"), .ok()])
        log = TokenLog()
        do {
            _ = try await api(t, tokens: log).calendarList()
            Issue.record("should throw")
        } catch let APIError.http(code, _) {
            #expect(code == 401)
        }
        #expect(await t.requests.count == 2)

        // 401 → 429 → 200: the rate-limit retry reuses the refreshed token.
        t = ScriptedTransport([.init(status: 401, body: "{}"), .init(status: 429, body: "{}"), .ok(#"{"items":[]}"#)])
        log = TokenLog()
        _ = try await api(t, tokens: log).calendarList()
        #expect(log.rejections == [nil, "tok1", nil])
    }

    @Test("A retried write sends byte-identical bodies (same Meet request id)")
    func retriesReuseBody() async throws {
        let t = ScriptedTransport([.init(status: 429, body: "{}"), .ok(#"{"id":"e"}"#)])
        var body = EventWriteDTO(summary: "Call")
        body.conferenceData = .meet()
        try await api(t).insertEvent(calendarId: "c", body: body, sendUpdates: .all)
        let bodies = await t.requests.map(\.httpBody)
        #expect(bodies.count == 2 && bodies[0] == bodies[1])
        #expect(await t.requests.allSatisfy { query($0) == ["sendUpdates": "all", "conferenceDataVersion": "1"] })
    }

    @Test("Event lists across many calendars never exceed six requests in flight")
    @MainActor func concurrencyCap() async throws {
        let w = await World()
        for i in 0..<11 {
            await w.google.addCalendar([Fx.alice, Fx.bob, Fx.carol][i % 3],
                                       Fx.calendar("extra\(i)@group.calendar.google.com", role: "reader"))
        }
        let gate = Gate()
        await w.google.on({ $0.isEventsList }, always: .gate(gate))
        let boot = Task { await w.start() }
        await w.google.waitFor(6, where: { $0.isEventsList })
        #expect(await w.google.requests { $0.isEventsList }.count == 6)
        #expect(await w.google.inFlightEventLists == 6)
        await gate.open()
        _ = await boot.value
        #expect(await w.google.maxInFlightEventLists == 6)
        let lists = await w.google.requests { $0.isEventsList }
        #expect(lists.count == 18)
        #expect(Set(lists.map { "\($0.account!)|\($0.calendarId!)" }).count == 18, "each calendar fetched once")
    }
}

@Suite("OAuth", .timeLimit(.minutes(1)))
struct OAuthTests {
    @Test("The refresh request is a form POST with exactly the documented fields")
    func refreshRequestShape() async throws {
        let t = ScriptedTransport([.ok(#"{"access_token":"ya29.x","expires_in":3599}"#)])
        let client = OAuthClient(clientId: "id+/=&%é", clientSecret: "s p&c")
        let (token, rotated) = try await OAuthService.refresh(client: client, refreshToken: "1//rt+/=", transport: t.transport, now: T0)
        #expect(token.value == "ya29.x")
        #expect(token.expiry == T0.addingTimeInterval(3599))
        #expect(rotated == nil)
        let r = try #require(await t.requests.first)
        #expect(r.httpMethod == "POST")
        #expect(r.url?.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        var form = URLComponents()
        form.percentEncodedQuery = String(data: r.httpBody!, encoding: .utf8)
        let fields = Dictionary(uniqueKeysWithValues: (form.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(fields == ["client_id": "id+/=&%é", "client_secret": "s p&c", "refresh_token": "1//rt+/=", "grant_type": "refresh_token"])
    }

    @Test("Token endpoint responses map to tokens or the right error", arguments: [
        (200, #"{"access_token":"a","expires_in":100}"#, "ok:100:nil"),
        (200, #"{"access_token":"a","refresh_token":"rt-new"}"#, "ok:3600:rt-new"),
        (400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, "invalidGrant"),
        (401, #"{"error":"invalid_client","error_description":"The OAuth client was not found."}"#, "clientRejected"),
        (400, #"{"error":"unauthorized_client"}"#, "clientRejected"),
        (500, "<html>oops</html>", "server:HTTP 500"),
        (200, #"{"token_type":"Bearer"}"#, "server:HTTP 200"),
        (400, #"{"error":"invalid_request","error_description":"Missing code verifier"}"#, "server:Missing code verifier"),
    ])
    func tokenResponseMapping(status: Int, body: String, expected: String) async throws {
        let t = ScriptedTransport([.init(status: status, body: body)])
        do {
            let (tok, rotated) = try await OAuthService.refresh(client: Fx.client, refreshToken: "rt", transport: t.transport, now: T0)
            #expect(expected == "ok:\(Int(tok.expiry.timeIntervalSince(T0))):\(rotated ?? "nil")")
        } catch let e as OAuthError {
            switch e {
            case .invalidGrant: #expect(expected == "invalidGrant")
            case .clientRejected: #expect(expected == "clientRejected")
            case .server(let m): #expect(expected == "server:\(m)")
            default: Issue.record("unexpected \(e)")
            }
            #expect(e.needsReconnect == (expected == "invalidGrant" || expected == "clientRejected"))
        }
    }

    @Test("Network errors from the token endpoint pass through unchanged")
    func refreshNetworkError() async throws {
        let failing: HTTPTransport = { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) {
            _ = try await OAuthService.refresh(client: Fx.client, refreshToken: "rt", transport: failing)
        }
    }

    @Test("ID token email extraction handles base64url and padding variants")
    func idTokenEmail() throws {
        func jwt(_ payload: String) -> String {
            let b = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJSUzI1NiJ9.\(b).sig"
        }
        for email in ["a@b.co", "ab@b.co", "abc@b.co", "Mixed.Case+tag@Example.com", "ü?>>@x.com"] {
            #expect(OAuthService.emailFromIDToken(jwt(#"{"email":"\#(email)","sub":"1"}"#)) == email)
        }
        #expect(OAuthService.emailFromIDToken(jwt(#"{"sub":"1"}"#)) == nil)
        #expect(OAuthService.emailFromIDToken("not-a-jwt") == nil)
        #expect(OAuthService.emailFromIDToken("a.!!!.c") == nil)
    }

    @Test("Full sign-in: PKCE S256, state, loopback redirect and code exchange", .timeLimit(.minutes(1)))
    func signInFlow() async throws {
        let idToken = "h." + Data(#"{"email":"alice@gmail.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "") + ".s"
        let t = ScriptedTransport([.ok(#"{"access_token":"at","expires_in":3600,"refresh_token":"rt","id_token":"\#(idToken)"}"#)])
        let captured = Captured()
        let result = try await OAuthService.signIn(client: Fx.client, transport: t.transport) { url in
            await captured.set(url)
            let c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let q = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value!) })
            var cb = URLComponents(string: q["redirect_uri"]!)!
            cb.queryItems = [URLQueryItem(name: "code", value: "4/0Ab+code"), URLQueryItem(name: "state", value: q["state"])]
            _ = try? await URLSession.shared.data(from: cb.url!)
        }
        #expect(result.email == "alice@gmail.com")
        #expect(result.refreshToken == "rt")

        let auth = try #require(await captured.url)
        let c = URLComponents(url: auth, resolvingAgainstBaseURL: false)!
        let q = Dictionary(uniqueKeysWithValues: c.queryItems!.map { ($0.name, $0.value!) })
        #expect(c.host == "accounts.google.com" && c.path == "/o/oauth2/v2/auth")
        #expect(q["client_id"] == Fx.client.clientId)
        #expect(q["response_type"] == "code")
        #expect(q["scope"] == "openid email https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/calendar.events",
                "only list calendars and manage events: no sharing, ACL or calendar deletion")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["access_type"] == "offline")
        #expect(q["prompt"] == "select_account consent")
        #expect(q["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)

        let tokenReq = try #require(await t.requests.first)
        var form = URLComponents()
        form.percentEncodedQuery = String(data: tokenReq.httpBody!, encoding: .utf8)
        let f = Dictionary(uniqueKeysWithValues: form.queryItems!.map { ($0.name, $0.value!) })
        #expect(f["code"] == "4/0Ab+code")
        #expect(f["grant_type"] == "authorization_code")
        #expect(f["redirect_uri"] == q["redirect_uri"])
        let verifier = try #require(f["code_verifier"])
        #expect((43...128).contains(verifier.count))
        #expect(OAuthService.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) == q["code_challenge"])
    }

    @Test("Callbacks without the right state are refused and the real one still completes sign-in",
          .timeLimit(.minutes(1)))
    func signInIgnoresForgedCallbacks() async throws {
        let idToken = "h." + Data(#"{"email":"alice@gmail.com"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "") + ".s"
        let t = ScriptedTransport([.ok(#"{"access_token":"at","expires_in":3600,"refresh_token":"rt","id_token":"\#(idToken)"}"#)])
        let statuses = Captured()
        let result = try await OAuthService.signIn(client: Fx.client, transport: t.transport) { url in
            let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                .queryItems!.map { ($0.name, $0.value!) })
            func hit(_ items: [URLQueryItem]) async -> Int {
                var cb = URLComponents(string: q["redirect_uri"]!)!
                cb.queryItems = items
                let r = try? await URLSession.shared.data(from: cb.url!)
                return (r?.1 as? HTTPURLResponse)?.statusCode ?? -1
            }
            // Another local process (or page) guessing the port can't end or hijack the flow.
            let forgedCode = await hit([URLQueryItem(name: "code", value: "evil"), URLQueryItem(name: "state", value: "forged")])
            let forgedError = await hit([URLQueryItem(name: "error", value: "access_denied")])
            let real = await hit([URLQueryItem(name: "code", value: "good"), URLQueryItem(name: "state", value: q["state"])])
            await statuses.set(URL(string: "s://\(forgedCode)/\(forgedError)/\(real)")!)
        }
        #expect(result.email == "alice@gmail.com")
        #expect(await statuses.url?.absoluteString == "s://400/400/200")
        var form = URLComponents()
        form.percentEncodedQuery = String(data: try #require(await t.requests.first?.httpBody), encoding: .utf8)
        #expect(form.queryItems?.first { $0.name == "code" }?.value == "good", "only the real code is exchanged")
        #expect(await t.requests.count == 1)
    }

    @Test("Sign-in reports the user cancelling at Google", .timeLimit(.minutes(1)))
    func signInDenied() async throws {
        await #expect(throws: OAuthError.denied("access_denied")) {
            _ = try await OAuthService.signIn(client: Fx.client, transport: ScriptedTransport([]).transport) { url in
                let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    .queryItems!.map { ($0.name, $0.value!) })
                var cb = URLComponents(string: q["redirect_uri"]!)!
                // A favicon request first must not end the flow.
                cb.path = "/favicon.ico"
                _ = try? await URLSession.shared.data(from: cb.url!)
                cb.path = "/"
                cb.queryItems = [URLQueryItem(name: "error", value: "access_denied"), URLQueryItem(name: "state", value: q["state"])]
                _ = try? await URLSession.shared.data(from: cb.url!)
            }
        }
    }
}

actor Captured {
    var url: URL?
    func set(_ u: URL) { url = u }
}
