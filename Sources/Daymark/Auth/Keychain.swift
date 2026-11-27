import Foundation
import Security

enum Keychain {
    private static let service = "Daymark"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Returns nil only when the item doesn't exist. Any other failure (access denied,
    /// keychain locked…) throws, so callers never mistake it for "nothing saved".
    static func read(_ account: String) throws -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status) }
        return out as? Data
    }

    static func write(_ data: Data, _ account: String) throws {
        let status = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = base(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "Daymark Google accounts"
            let add = SecItemAdd(q as CFDictionary, nil)
            guard add == errSecSuccess else { throw keychainError(add) }
        } else if status != errSecSuccess {
            throw keychainError(status)
        }
    }

    private static func keychainError(_ status: OSStatus) -> Error {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return AppError.message(msg)
    }
}
