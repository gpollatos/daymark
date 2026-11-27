import AppKit
import SwiftUI

@main
struct DaymarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = CalendarStore(env: DemoMode.isEnabled ? .demo : nil)

    var body: some Scene {
        WindowGroup("Daymark", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 960, minHeight: 620)
                .task {
                    // Clicking a reminder jumps to that event's day.
                    Notifier.shared.onOpen = { _, start in store.show(day: start) }
                    await store.bootstrap()
                }
        }
        .defaultSize(width: 1320, height: 860)
        .commands { DaymarkCommands(store: store) }

        Settings {
            TabView {
                SetupView(inSettings: true)
                    .tabItem { Label("Google", systemImage: "person.crop.circle") }
                NotificationSettingsView()
                    .tabItem { Label("Notifications", systemImage: "bell") }
            }
            .environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Notifier.shared.setup()
    }
}

struct DaymarkCommands: Commands {
    let store: CalendarStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Event") { store.beginCreate() }
                .keyboardShortcut("n")
        }
        CommandMenu("Go") {
            Button("Today") { store.goToToday() }
                .keyboardShortcut("t")
            Button("Previous") { store.step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Next") { store.step(1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Divider()
            ForEach(ViewMode.allCases) { mode in
                Button(mode.title) { store.viewMode = mode }
                    .keyboardShortcut(mode.key, modifiers: .command)
            }
            Divider()
            Button("Refresh") { Task { await store.refresh() } }
                .keyboardShortcut("r")
        }
        CommandGroup(after: .appSettings) {
            Button("Add Google Account…") { store.addAccount() }
        }
    }
}
