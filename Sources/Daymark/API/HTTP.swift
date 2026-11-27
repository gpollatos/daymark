import Foundation

/// Sends an HTTP request. Production uses URLSession; tests substitute a fake Google.
typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

enum HTTP {
    /// A session that keeps nothing on disk. `URLSession.shared` would cache Google's responses
    /// (your events) and the requests' `Authorization` headers under ~/Library/Caches.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        return URLSession(configuration: c)
    }()

    static let live: HTTPTransport = { try await session.data(for: $0) }
}
