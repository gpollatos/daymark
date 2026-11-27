import AppKit
import CryptoKit
import Foundation

struct AccessToken: Sendable {
    let value: String
    let expiry: Date
    func isValid(at now: Date) -> Bool { expiry.timeIntervalSince(now) > 60 }
}

struct SignInResult: Sendable {
    let email: String
    let refreshToken: String
    let token: AccessToken
}

enum OAuthError: LocalizedError, Equatable {
    case denied(String)
    case invalidGrant
    case server(String)
    case stateMismatch
    case noRefreshToken
    case timedOut
    case notSignedIn
    case clientRejected(String)

    var errorDescription: String? {
        switch self {
        case .denied(let e): "Google sign-in was not completed (\(e))."
        case .invalidGrant: "Google sign-in expired or was revoked. Reconnect this account."
        case .server(let m): "Google sign-in failed: \(m)"
        case .stateMismatch: "Sign-in response didn't match the request. Please try again."
        case .noRefreshToken: "Google didn't return a refresh token. Remove Daymark at myaccount.google.com/permissions and try again."
        case .timedOut: "Sign-in timed out."
        case .notSignedIn: "This account is not signed in."
        case .clientRejected(let m): "Google rejected Daymark's OAuth client (\(m)). Check the client ID and secret in Settings."
        }
    }
}

extension OAuthError {
    /// True when the stored sign-in can never work again and the user must sign in afresh.
    var needsReconnect: Bool {
        switch self {
        case .invalidGrant, .clientRejected: true
        default: false
        }
    }
}

/// OAuth 2.0 authorization-code flow with PKCE and a loopback redirect, as Google documents for desktop apps.
enum OAuthService {
    /// The narrowest scopes that cover what Daymark does: list your calendars, and read, create,
    /// edit and delete events (including Google Meet links). Daymark can't change sharing settings
    /// or create/delete calendars.
    static let scopes = ["openid", "email",
                         "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
                         "https://www.googleapis.com/auth/calendar.events"]

    static func signIn(client: OAuthClient, transport: @escaping HTTPTransport = HTTP.live,
                       openURL: @escaping @Sendable (URL) async -> Void = { url in
                           await MainActor.run { _ = NSWorkspace.shared.open(url) }
                       }) async throws -> SignInResult {
        let verifier = randomURLSafe(48)
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomURLSafe(16)

        let server = LoopbackServer(expectedState: state)
        let port = try await server.start()
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(port)"

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: client.clientId),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
        ]
        let authURL = c.url!
        await openURL(authURL)

        let cb = try await server.waitForCallback(timeout: 600)
        if let e = cb.error { throw OAuthError.denied(e) }
        guard cb.state == state else { throw OAuthError.stateMismatch }
        guard let code = cb.code else { throw OAuthError.denied("no code") }

        // The ID token comes straight from Google's token endpoint over TLS (authenticated with the
        // client secret), so its email claim is trusted without verifying the signature. Don't reuse
        // `emailFromIDToken` for tokens from anywhere else.
        let r = try await tokenRequest([
            "code": code,
            "client_id": client.clientId,
            "client_secret": client.clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ], transport: transport)
        guard let refresh = r.refresh_token else { throw OAuthError.noRefreshToken }
        guard let email = r.id_token.flatMap(emailFromIDToken) else { throw OAuthError.server("no email in ID token") }
        return SignInResult(email: email, refreshToken: refresh, token: r.accessToken(now: Date()))
    }

    /// Returns a new access token, plus a new refresh token if Google rotated it.
    static func refresh(client: OAuthClient, refreshToken: String,
                        transport: HTTPTransport = HTTP.live, now: Date = Date()) async throws -> (AccessToken, String?) {
        let r = try await tokenRequest([
            "client_id": client.clientId,
            "client_secret": client.clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ], transport: transport)
        return (r.accessToken(now: now), r.refresh_token)
    }

    static func revoke(token: String, transport: HTTPTransport = HTTP.live) async {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(["token": token])
        _ = try? await transport(req)
    }

    // MARK: - Private

    private struct TokenResponse: Decodable {
        let access_token: String?
        let expires_in: Int?
        let refresh_token: String?
        let id_token: String?
        let error: String?
        let error_description: String?

        func accessToken(now: Date) -> AccessToken {
            AccessToken(value: access_token ?? "", expiry: now.addingTimeInterval(Double(expires_in ?? 3600)))
        }
    }

    private static func tokenRequest(_ params: [String: String], transport: HTTPTransport) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode(params)
        let (data, resp) = try await transport(req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let r = try? JSONDecoder().decode(TokenResponse.self, from: data)
        if let err = r?.error {
            if err == "invalid_grant" { throw OAuthError.invalidGrant }
            if err == "invalid_client" || err == "unauthorized_client" {
                throw OAuthError.clientRejected(r?.error_description ?? err)
            }
            throw OAuthError.server(r?.error_description ?? err)
        }
        guard (200..<300).contains(status), let r, r.access_token != nil else {
            throw OAuthError.server("HTTP \(status)")
        }
        return r
    }

    static func formEncode(_ params: [String: String]) -> Data {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        let s = params.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    static func emailFromIDToken(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["email"] as? String
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return base64url(Data(b))
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
