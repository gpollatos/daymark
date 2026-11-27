import Foundation

enum APIError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg): "Google Calendar error \(code): \(msg)"
        }
    }
}

/// Who Google emails about a change: "all" guests, or "none".
enum SendUpdates: String, Sendable {
    case all, none
}

/// Thin client for one Google account.
struct GoogleCalendarAPI: Sendable {
    /// Supplies an access token. `rejected` is a token Google just answered 401 to; the provider
    /// must return a different (refreshed) one. nil means any valid token will do.
    let tokenProvider: @Sendable (_ rejected: String?) async throws -> String
    var transport: HTTPTransport = HTTP.live
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var jitterMs: @Sendable () -> Int = { Int.random(in: 0..<300) }

    private static let base = "https://www.googleapis.com/calendar/v3/"

    func calendarList() async throws -> [CalendarListEntryDTO] {
        var all: [CalendarListEntryDTO] = []
        var page: String?
        repeat {
            var q = [URLQueryItem(name: "maxResults", value: "250")]
            if let page { q.append(URLQueryItem(name: "pageToken", value: page)) }
            let r: CalendarListDTO = try await get("users/me/calendarList", q)
            all += r.items ?? []
            page = r.nextPageToken
        } while page != nil
        return all.filter { $0.deleted != true && $0.hidden != true }
    }

    func events(calendarId: String, from: Date, to: Date, query: String? = nil) async throws -> [EventDTO] {
        var all: [EventDTO] = []
        var page: String?
        repeat {
            var q = [
                URLQueryItem(name: "timeMin", value: RFC3339.string(from)),
                URLQueryItem(name: "timeMax", value: RFC3339.string(to)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime"),
                URLQueryItem(name: "maxResults", value: "2500"),
            ]
            if let query { q.append(URLQueryItem(name: "q", value: query)) }
            if let page { q.append(URLQueryItem(name: "pageToken", value: page)) }
            let r: EventsDTO = try await get("calendars/\(Self.segment(calendarId))/events", q)
            all += r.items ?? []
            page = r.nextPageToken
        } while page != nil
        return all
    }

    @discardableResult
    func insertEvent(calendarId: String, body: EventWriteDTO, sendUpdates: SendUpdates) async throws -> EventDTO {
        let data = try await send("POST", url("calendars/\(Self.segment(calendarId))/events",
                                              writeQuery(body, sendUpdates)),
                                  body: JSONEncoder().encode(body))
        return try JSONDecoder().decode(EventDTO.self, from: data)
    }

    @discardableResult
    func patchEvent(calendarId: String, eventId: String, body: EventWriteDTO,
                    sendUpdates: SendUpdates) async throws -> EventDTO {
        let path = "calendars/\(Self.segment(calendarId))/events/\(Self.segment(eventId))"
        let data = try await send("PATCH", url(path, writeQuery(body, sendUpdates)), body: JSONEncoder().encode(body))
        return try JSONDecoder().decode(EventDTO.self, from: data)
    }

    func deleteEvent(calendarId: String, eventId: String, sendUpdates: SendUpdates) async throws {
        let path = "calendars/\(Self.segment(calendarId))/events/\(Self.segment(eventId))"
        do {
            _ = try await send("DELETE", url(path, [URLQueryItem(name: "sendUpdates", value: sendUpdates.rawValue)]),
                               body: nil)
        } catch APIError.http(410, _) {
            // Already deleted.
        }
    }

    // MARK: - Plumbing

    private func writeQuery(_ body: EventWriteDTO, _ sendUpdates: SendUpdates) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "sendUpdates", value: sendUpdates.rawValue)]
        if body.conferenceData != nil { q.append(URLQueryItem(name: "conferenceDataVersion", value: "1")) }
        return q
    }

    private static func segment(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~@")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(string: Self.base + path)!
        if !query.isEmpty {
            c.queryItems = query
            // URLComponents leaves "+" alone, which servers read as a space.
            c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        return c.url!
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        let data = try await send("GET", url(path, query), body: nil)
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct GoogleErrorBody: Decodable {
        struct Reason: Decodable { let reason: String? }
        struct Inner: Decodable {
            let message: String?
            let errors: [Reason]?
        }
        let error: Inner?
    }

    /// Rate limits and server errors are worth retrying. A POST is only retried on rate limits,
    /// where Google guarantees nothing was created.
    static func isRetryable(method: String, code: Int, body: GoogleErrorBody?) -> Bool {
        let reasons = body?.error?.errors?.compactMap(\.reason) ?? []
        let rateLimited = code == 429
            || (code == 403 && reasons.contains { $0 == "rateLimitExceeded" || $0 == "userRateLimitExceeded" })
        if rateLimited { return true }
        return code >= 500 && method != "POST"
    }

    private func send(_ method: String, _ url: URL, body: Data?) async throws -> Data {
        var rejected: String?
        var refreshedAfter401 = false
        var retries = 0
        while true {
            let token = try await tokenProvider(rejected)
            rejected = nil
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, resp) = try await transport(req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { return data }

            if code == 401 && !refreshedAfter401 {
                refreshedAfter401 = true
                rejected = token
                continue
            }
            let err = try? JSONDecoder().decode(GoogleErrorBody.self, from: data)
            if retries < 3 && Self.isRetryable(method: method, code: code, body: err) {
                let ms = 500 * (1 << retries) + jitterMs()
                retries += 1
                try await sleep(.milliseconds(ms))
                continue
            }
            throw APIError.http(code, err?.error?.message ?? HTTPURLResponse.localizedString(forStatusCode: code))
        }
    }
}
