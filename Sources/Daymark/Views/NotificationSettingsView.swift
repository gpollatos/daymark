import SwiftUI

struct NotificationSettingsView: View {
    @State private var notifier = Notifier.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Event reminders").font(.title2.weight(.semibold))
            Text("Daymark reminds you before events, using each event's Google Calendar reminders (or the calendar's defaults). Reminders appear while Daymark is running; closing the window keeps it running.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    switch notifier.delivery {
                    case .system:
                        Label("Using macOS notifications", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Reminders appear in Notification Center and follow your Focus settings.")
                            .font(.callout).foregroundStyle(.secondary)
                    case .systemDenied:
                        Label("Notifications are turned off for Daymark", systemImage: "bell.slash.fill")
                            .foregroundStyle(.orange)
                        Text("Turn them on in System Settings → Notifications → Daymark.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Open Notification Settings") { notifier.openSystemSettings() }
                    case .inApp(let reason):
                        Label("Using Daymark's own reminder windows", systemImage: "rectangle.stack.badge.person.crop")
                            .foregroundStyle(Palette.accent)
                        Text("macOS only allows Notification Center for apps signed with an Apple developer certificate (it said: “\(reason)”). Daymark shows its reminders in a small window in the top-right corner instead, with a sound. To use Notification Center, see “Notifications” in the README.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .unknown:
                        Label("Checking…", systemImage: "hourglass").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Button("Send Test Reminder") { notifier.sendTest() }
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 600, height: 380)
        .onAppear { notifier.refreshStatus() }
    }
}
