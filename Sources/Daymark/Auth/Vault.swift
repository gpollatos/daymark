import Foundation

/// Where the vault (OAuth client + refresh tokens) is stored. Production: the Keychain.
struct VaultStorage: Sendable {
    /// Returns nil when nothing has been saved yet; throws when the store can't be read.
    var read: @Sendable () throws -> Data?
    var write: @Sendable (Data) throws -> Void

    static let keychain = VaultStorage(read: { try Keychain.read("vault") },
                                       write: { try Keychain.write($0, "vault") })
}

/// Everything Daymark persists: the OAuth client and the accounts' refresh tokens.
/// Stored as one Keychain item; there is no other storage.
struct Vault: Codable {
    var client: OAuthClient?
    var accounts: [Account] = []

    /// An empty vault means a fresh install. A read or decode failure throws.
    static func load(from storage: VaultStorage = .keychain) throws -> Vault {
        guard let d = try storage.read() else { return Vault() }
        return try JSONDecoder().decode(Vault.self, from: d)
    }

    func save(to storage: VaultStorage = .keychain) throws {
        try storage.write(JSONEncoder().encode(self))
    }
}
