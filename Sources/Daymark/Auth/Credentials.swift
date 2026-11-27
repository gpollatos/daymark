import Foundation

/// A connected Google account. The refresh token is the only credential kept, and it lives in the Keychain.
struct Account: Codable, Identifiable, Hashable, Sendable {
    let email: String
    var refreshToken: String
    var id: String { email }
}

/// The OAuth "Desktop app" client the user created in Google Cloud Console.
struct OAuthClient: Codable, Equatable, Sendable {
    var clientId: String
    var clientSecret: String
}

extension OAuthClient {
    /// Parses the client JSON downloaded from Google Cloud Console ("installed" or "web").
    static func fromGoogleJSON(_ data: Data) -> OAuthClient? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inner = (obj["installed"] ?? obj["web"]) as? [String: Any],
              let id = inner["client_id"] as? String,
              let secret = inner["client_secret"] as? String,
              !id.trimmed.isEmpty, !secret.trimmed.isEmpty else { return nil }
        return OAuthClient(clientId: id.trimmed, clientSecret: secret.trimmed)
    }

    static func isPlausibleId(_ id: String) -> Bool {
        let t = id.trimmed
        return t.hasSuffix(".apps.googleusercontent.com") && t.count > ".apps.googleusercontent.com".count
    }
}
