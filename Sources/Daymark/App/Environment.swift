import AppKit
import Foundation

/// Small app preferences (current view, calendar visibility, last-used calendar).
/// Production: `UserDefaults.standard`; tests use an in-memory store so nothing is written to disk.
protocol Preferences: AnyObject {
    func string(forKey key: String) -> String?
    func dictionary(forKey key: String) -> [String: Any]?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: Preferences {}

/// Receives the events that should have reminders scheduled.
@MainActor
protocol ReminderScheduling: AnyObject {
    func reschedule(_ events: [CalendarEvent], now: Date)
}

/// Everything CalendarStore depends on. `.live` is the real app; tests build their own.
@MainActor
struct AppEnvironment {
    var calendar: @Sendable () -> Calendar
    var now: @Sendable () -> Date
    var defaults: any Preferences
    var vault: VaultStorage
    var oauth: OAuthBackend
    var transport: HTTPTransport
    var sleep: @Sendable (Duration) async throws -> Void
    var jitterMs: @Sendable () -> Int
    var notifier: any ReminderScheduling
    var activateApp: @MainActor () -> Void
    /// Timers and app-activation observers; off in tests.
    var startBackgroundWork: Bool

    init(calendar: @escaping @Sendable () -> Calendar = { .current },
         now: @escaping @Sendable () -> Date = { Date() },
         defaults: any Preferences = UserDefaults.standard,
         vault: VaultStorage = .keychain,
         oauth: OAuthBackend = .live,
         transport: @escaping HTTPTransport = HTTP.live,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         jitterMs: @escaping @Sendable () -> Int = { Int.random(in: 0..<300) },
         notifier: (any ReminderScheduling)? = nil,
         activateApp: @escaping @MainActor () -> Void = { NSApp?.activate(ignoringOtherApps: true) },
         startBackgroundWork: Bool = true) {
        self.calendar = calendar
        self.now = now
        self.defaults = defaults
        self.vault = vault
        self.oauth = oauth
        self.transport = transport
        self.sleep = sleep
        self.jitterMs = jitterMs
        self.notifier = notifier ?? Notifier.shared
        self.activateApp = activateApp
        self.startBackgroundWork = startBackgroundWork
    }

    static var live: AppEnvironment { AppEnvironment() }
}
