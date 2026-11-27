import SwiftUI

struct EventEditorView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EventDraft
    @State private var saving = false
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    init(draft: EventDraft) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        let existing = draft.existing
        let isNew = existing == nil
        let canEditGuests = existing?.isOrganizer ?? true
        VStack(spacing: 0) {
            Form {
                TextField("Add title", text: $draft.title)
                    .font(.title3)
                    .focused($titleFocused)

                Picker("Calendar", selection: $draft.calendarKey) {
                    ForEach(store.accounts) { acc in
                        let cals = store.calendars(for: acc.email).filter(\.canWrite)
                        if !cals.isEmpty {
                            Section(acc.email) {
                                ForEach(cals) { c in
                                    Label {
                                        Text(c.name)
                                    } icon: {
                                        Image(systemName: "circle.fill").foregroundStyle(Color(hex: c.colorHex))
                                    }
                                    .tag(c.id)
                                }
                            }
                        }
                    }
                }
                .disabled(!isNew)
                .help(isNew ? "" : "To move an event to another calendar, use Google Calendar on the web.")

                Toggle("All-day", isOn: allDayBinding)
                DatePicker("Starts", selection: startBinding,
                           displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                DatePicker("Ends", selection: $draft.end,
                           displayedComponents: draft.isAllDay ? [.date] : [.date, .hourAndMinute])
                if isNew {
                    Picker("Repeat", selection: $draft.repeatRule) {
                        ForEach(RepeatRule.allCases) { Text($0.title).tag($0) }
                    }
                } else if existing?.recurringEventId != nil {
                    Text("Changes apply to this occurrence only.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if canEditGuests {
                    TextField("Add guests", text: $draft.guests, prompt: Text("name@example.com, …"), axis: .vertical)
                        .lineLimit(1...4)
                }
                if existing?.meetLink == nil {
                    Toggle("Add Google Meet video conferencing", isOn: $draft.addMeet)
                }
                TextField("Add location", text: $draft.location)
                TextField("Add description", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...10)
            }
            .formStyle(.grouped)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal)
            }

            HStack {
                if draft.savingNotifiesGuests {
                    Label("Guests will be emailed", systemImage: "envelope")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Save" : "Save Changes") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
            }
            .padding()
        }
        .frame(width: 500)
        .onAppear { titleFocused = true }
        // Keep the placeholder on the calendar in step with what's being typed.
        .onChange(of: draft) { _, new in
            if store.editorDraft?.id == new.id { store.editorDraft = new }
        }
    }

    private var startBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { draft.setStart($0) })
    }

    private var allDayBinding: Binding<Bool> {
        Binding(get: { draft.isAllDay }, set: { draft.setAllDay($0) })
    }

    private func save() {
        saving = true
        error = nil
        Task {
            do {
                try await store.save(draft)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}
