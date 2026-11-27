import Foundation

/// The Google OAuth operations the store needs.
struct OAuthBackend: Sendable {
    var signIn: @Sendable (OAuthClient) async throws -> SignInResult
    var refresh: @Sendable (OAuthClient, String) async throws -> (AccessToken, String?)
    var revoke: @Sendable (String) async -> Void

    static let live = OAuthBackend(
        signIn: { try await OAuthService.signIn(client: $0) },
        refresh: { try await OAuthService.refresh(client: $0, refreshToken: $1) },
        revoke: { await OAuthService.revoke(token: $0) })
}
