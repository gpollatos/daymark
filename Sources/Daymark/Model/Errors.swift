import Foundation

/// A problem reaching one account.
struct AccountIssue: Equatable {
    let message: String
    /// True when Google rejected the sign-in and the account must be reconnected.
    let needsReconnect: Bool
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): m }
    }
}
