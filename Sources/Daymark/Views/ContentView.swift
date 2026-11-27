import SwiftUI

struct ContentView: View {
    @Environment(CalendarStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        } detail: {
            DetailView()
        }
        // Without its own background band, the toolbar can't spill over the sidebar's edge.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .navigationTitle(store.title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Today") { store.goToToday() }
                    .help("Go to today (⌘T)")
                Button { store.step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous (⌘←)")
                Button { store.step(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next (⌘→)")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $store.viewMode) {
                    ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 440)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh (⌘R)")
                }
                Button { store.beginCreate() } label: { Image(systemName: "plus") }
                    .help("New event (⌘N)")
            }
        }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search")
        .onSubmit(of: .search) { Task { await store.performSearch() } }
        .sheet(item: $store.editorDraft) { draft in
            EventEditorView(draft: draft)
        }
        .sheet(isPresented: $store.showSetup) {
            SetupView(inSettings: false)
        }
        .confirmationDialog(deleteTitle,
                            isPresented: Binding(get: { store.pendingDelete != nil },
                                                 set: { if !$0 { store.pendingDelete = nil } }),
                            presenting: store.pendingDelete) { event in
            if event.recurringEventId != nil {
                Button("Delete This Event", role: .destructive) { delete(event, all: false) }
                Button("Delete All Events in Series", role: .destructive) { delete(event, all: true) }
            } else {
                Button("Delete", role: .destructive) { delete(event, all: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { event in
            if event.deletionNotifiesGuests {
                Text("Guests will be emailed that the event was cancelled.")
            } else if !event.isOrganizer {
                Text("This removes the invitation from your calendar.")
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { store.errorMessage != nil },
                                    set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

extension ContentView {
    private var deleteTitle: String {
        guard let e = store.pendingDelete else { return "" }
        return "Delete “\(e.title)”?"
    }

    private func delete(_ e: CalendarEvent, all: Bool) {
        store.pendingDelete = nil
        Task { await store.delete(e, allOccurrences: all) }
    }
}

private struct DetailView: View {
    @Environment(CalendarStore.self) private var store

    var body: some View {
        Group {
            if store.searchResults != nil || store.isSearching {
                SearchResultsView()
            } else if store.accounts.isEmpty {
                EmptyAccountsView()
            } else {
                switch store.viewMode {
                case .schedule: ScheduleView()
                case .day, .threeDay, .workWeek, .week: TimeGridView(days: store.visibleDays)
                case .month: MonthView()
                }
            }
        }
        // Stay below the toolbar: a background that bleeds under it shows through and overlaps the sidebar.
        .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: [])
    }
}

private struct EmptyAccountsView: View {
    @Environment(CalendarStore.self) private var store

    var body: some View {
        if store.vaultUnreadable { lockedBody } else { addAccountsBody }
    }

    /// The Keychain couldn't be read: say so (and that nothing was lost) instead of looking like a fresh install.
    private var lockedBody: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.orange)
            Text("Daymark can't read its saved accounts")
                .font(.title2.weight(.semibold))
            Text("macOS didn't allow access to Daymark's Keychain item. Nothing has been deleted or changed. Quit and reopen Daymark, and choose Always Allow if macOS asks for Keychain access.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addAccountsBody: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar.badge.plus")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Palette.accent)
            Text("Add your Google accounts")
                .font(.title2.weight(.semibold))
            Text("Sign in to each Google account you use. All their calendars appear together here, like in the Google Calendar app on iPhone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            if store.isSigningIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                    Button("Cancel") { store.cancelSignIn() }
                }
            } else {
                Button { store.addAccount() } label: {
                    Label("Add Google Account", systemImage: "person.crop.circle.badge.plus")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
