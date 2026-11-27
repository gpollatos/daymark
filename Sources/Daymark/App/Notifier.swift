import AppKit
import Observation
import SwiftUI
import UserNotifications

struct PlannedReminder: Equatable, Sendable {
    let id: String
    let eventId: String
    let fire: Date
    let minutes: Int
    let title: String
    let body: String
    var start: Date = .distantPast
    var meetLink: String?
}

/// Delivers event reminders ("popup" reminders in Google Calendar) as desktop notifications.
///
/// macOS only lets apps signed with an Apple developer certificate use Notification Center.
/// When it refuses (e.g. a locally built app with an ad-hoc signature), Daymark shows its own
/// reminder window instead, so reminders always appear while the app is running.
@MainActor
@Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate, ReminderScheduling {
    static let shared = Notifier()
    nonisolated static let limit = 60
    /// Reminders missed by more than this (e.g. the Mac was asleep) are dropped rather than shown late.
    nonisolated static let staleAfter: TimeInterval = 10 * 60

    enum Delivery: Equatable {
        case unknown
        /// Notification Center accepted Daymark.
        case system
        /// The user turned Daymark's notifications off in System Settings.
        case systemDenied
        /// macOS doesn't allow notifications for this build; Daymark's own reminder window is used.
        case inApp(reason: String)
    }

    private(set) var delivery: Delivery = .unknown
    /// Called when a reminder is clicked: event id and start.
    @ObservationIgnored var onOpen: ((String, Date) -> Void)?

    @ObservationIgnored private var plan: [PlannedReminder] = []
    @ObservationIgnored private var shown = Set<String>()
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var timer: Timer?

    /// UNUserNotificationCenter crashes outside an .app bundle (e.g. under `swift test`).
    private var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func setup() {
        guard isAppBundle else { return }
        UNUserNotificationCenter.current().delegate = self
        requestPermission()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    func requestPermission() {
        guard isAppBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                if let error {
                    self.delivery = .inApp(reason: error.localizedDescription)
                } else {
                    self.delivery = granted ? .system : .systemDenied
                }
                self.reschedule(self.plan, now: Date())
            }
        }
    }

    /// Picks up changes the user made in System Settings.
    func refreshStatus() {
        guard isAppBundle else { return }
        if case .inApp = delivery { return }   // macOS won't allow this build at all; nothing to pick up
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let status = s.authorizationStatus
            Task { @MainActor in
                let was = self.delivery
                switch status {
                case .authorized, .provisional: self.delivery = .system
                case .denied: self.delivery = .systemDenied
                default: break
                }
                if self.delivery != was { self.reschedule(self.plan, now: Date()) }
            }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Scheduling

    func reschedule(_ events: [CalendarEvent], now: Date) {
        reschedule(Self.plan(events, now: now), now: now)
    }

    private func reschedule(_ newPlan: [PlannedReminder], now: Date) {
        plan = newPlan
        guard isAppBundle else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard delivery == .system else { return }   // the in-app window is driven by tick()
        for r in plan {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.userInfo = ["eventId": r.eventId, "start": r.start.timeIntervalSince1970]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, r.fire.timeIntervalSince(now)), repeats: false)
            center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: trigger))
        }
    }

    /// Shows in-app reminders that have come due since the last check.
    private func tick() {
        let now = Date()
        defer { lastTick = now }
        guard delivery != .system else { return }
        for r in Self.due(plan, after: lastTick, upTo: now, shown: shown) {
            shown.insert(r.id)
            ReminderWindows.shared.show(r, onOpen: { [weak self] in self?.open(r) })
        }
    }

    func sendTest() {
        let r = PlannedReminder(id: "test-\(UUID().uuidString)", eventId: "", fire: Date(), minutes: 0,
                                title: "Daymark reminders work",
                                body: "This is what a reminder looks like.", start: Date())
        if delivery == .system {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: r.id, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        } else {
            ReminderWindows.shared.show(r, onOpen: nil)
        }
    }

    private func open(_ r: PlannedReminder) {
        NSApp.activate(ignoringOtherApps: true)
        if !r.eventId.isEmpty { onOpen?(r.eventId, r.start) }
    }

    // MARK: Pure logic (tested)

    /// Which reminders to schedule. The same meeting can appear in several of your accounts
    /// (same iCalUID and start): it is notified once, at every reminder time any of its
    /// non-declined copies asks for.
    nonisolated static func plan(_ events: [CalendarEvent], now: Date, limit: Int = Notifier.limit,
                                 calendar: Calendar = .current, locale: Locale = .current) -> [PlannedReminder] {
        var groups: [String: [CalendarEvent]] = [:]
        for e in events where !e.isDeclined {
            groups["\(e.iCalUID)|\(e.start.timeIntervalSince1970)", default: []].append(e)
        }
        var out: [PlannedReminder] = []
        for copies in groups.values {
            let lead = copies.min { $0.id < $1.id }!
            let body = [Fmt.when(lead, calendar: calendar, locale: locale), lead.location ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            let meet = copies.lazy.compactMap(\.meetLink).first
            for m in Set(copies.flatMap(\.reminderMinutes)) {
                let fire = lead.start.addingTimeInterval(-Double(m) * 60)
                guard fire > now.addingTimeInterval(5) else { continue }
                out.append(PlannedReminder(id: "\(lead.id)#\(m)", eventId: lead.id, fire: fire,
                                           minutes: m, title: lead.title, body: body,
                                           start: lead.start, meetLink: meet))
            }
        }
        return Array(out.sorted { ($0.fire, $0.id) < ($1.fire, $1.id) }.prefix(limit))
    }

    /// In-app reminders due in (after, upTo], not already shown, and not hopelessly late.
    nonisolated static func due(_ plan: [PlannedReminder], after last: Date, upTo now: Date,
                                shown: Set<String>) -> [PlannedReminder] {
        plan.filter { $0.fire > last && $0.fire <= now && now.timeIntervalSince($0.fire) <= staleAfter && !shown.contains($0.id) }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let id = info["eventId"] as? String, let t = info["start"] as? Double else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            self.onOpen?(id, Date(timeIntervalSince1970: t))
        }
    }
}

/// Daymark's own reminder windows: small floating cards in the top-right corner, over all apps and Spaces.
@MainActor
final class ReminderWindows {
    static let shared = ReminderWindows()
    private var panels: [NSPanel] = []

    func show(_ r: PlannedReminder, onOpen: (() -> Void)?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        let close = { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.orderOut(nil)
            self.panels.removeAll { $0 === panel }
            self.layout()
        }
        let view = ReminderCard(reminder: r,
                                onOpen: onOpen.map { open in { open(); close() } },
                                onSnooze: { [weak self] in
                                    close()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 300) { self?.show(r, onOpen: onOpen) }
                                },
                                onDismiss: close)
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(panel.contentView!.fittingSize)
        panels.append(panel)
        layout()
        panel.orderFrontRegardless()
        NSSound(named: "Glass")?.play()
    }

    /// Stacks the cards down from the top-right corner of the main screen.
    private func layout() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        var top = screen.maxY - 12
        for p in panels {
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 12, y: top - size.height))
            top -= size.height + 8
        }
    }
}

private struct ReminderCard: View {
    let reminder: PlannedReminder
    let onOpen: (() -> Void)?
    let onSnooze: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(reminder.title).font(.headline).lineLimit(2)
                    Text(reminder.body).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if let url = SafeLink.url(reminder.meetLink) {
                    Button("Join") { NSWorkspace.shared.open(url); onDismiss() }
                        .buttonStyle(.borderedProminent)
                }
                if let onOpen { Button("Open", action: onOpen) }
                Spacer()
                Button("Snooze 5 min", action: onSnooze)
                Button("Dismiss", action: onDismiss).keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }
}
