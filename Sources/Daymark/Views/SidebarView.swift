import SwiftUI

struct SidebarView: View {
    @Environment(CalendarStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            MiniMonthView()
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            List {
                ForEach(store.accounts) { acc in
                    Section {
                        ForEach(store.calendars(for: acc.email)) { c in
                            Toggle(isOn: Binding(get: { store.isVisible(c) },
                                                 set: { store.setVisible(c, $0) })) {
                                HStack(spacing: 4) {
                                    Text(c.name).lineLimit(1).truncationMode(.tail)
                                    if store.failedCalendarKeys.contains(c.id) {
                                        Image(systemName: "exclamationmark.circle")
                                            .foregroundStyle(.orange)
                                            .help("Couldn't load this calendar's events. Showing the last copy; Daymark will retry.")
                                    }
                                }
                            }
                            .toggleStyle(ColorCheckboxStyle(color: Color(hex: c.colorHex)))
                        }
                    } header: {
                        AccountHeader(account: acc)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 8) {
                if store.isSigningIn {
                    ProgressView().controlSize(.small)
                    Text("Waiting for browser…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { store.cancelSignIn() }.buttonStyle(.borderless)
                } else {
                    Button { store.addAccount() } label: {
                        Label("Add account", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
            }
            .padding(10)
        }
    }
}

private struct AccountHeader: View {
    @Environment(CalendarStore.self) private var store
    let account: Account
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 4) {
            Text(account.email).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let issue = store.accountIssues[account.email] {
                Button {
                    if issue.needsReconnect { store.addAccount() } else { Task { await store.refresh() } }
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.needsReconnect ? .red : .orange)
                }
                .buttonStyle(.borderless)
                .help("\(issue.message)\nClick to \(issue.needsReconnect ? "reconnect" : "retry").")
            }
            Menu {
                Button("Reconnect…") { store.addAccount() }
                Button("Remove Account…", role: .destructive) { confirmRemove = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .confirmationDialog("Remove \(account.email)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { store.removeAccount(account.email) }
        } message: {
            Text("Daymark will sign out of this account and forget its access. Nothing in Google Calendar is changed.")
        }
    }
}

struct ColorCheckboxStyle: ToggleStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(configuration.isOn ? color : .clear)
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(color, lineWidth: 2)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 15, height: 15)
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct MiniMonthView: View {
    @Environment(CalendarStore.self) private var store
    @State private var month = Calendar.current.startOfMonth(.now)
    private let cal = Calendar.current

    var body: some View {
        let days = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: cal.startOfWeek(month)) }
        let symbols = cal.orderedWeekdaySymbols(cal.veryShortStandaloneWeekdaySymbols)
        let range = store.visibleRange
        let highlightRange = [.threeDay, .workWeek, .week].contains(store.viewMode)

        VStack(spacing: 6) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
            }
            Grid(horizontalSpacing: 0, verticalSpacing: 1) {
                GridRow {
                    ForEach(symbols.indices, id: \.self) { i in
                        Text(symbols[i])
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<6, id: \.self) { w in
                    GridRow {
                        ForEach(0..<7, id: \.self) { i in
                            let d = days[w * 7 + i]
                            dayCell(d, inRange: highlightRange && range.containsHalfOpen(d))
                        }
                    }
                }
            }
        }
        .onAppear { month = cal.startOfMonth(store.selectedDate) }
        .onChange(of: store.selectedDate) { _, d in month = cal.startOfMonth(d) }
    }

    private func dayCell(_ d: Date, inRange: Bool) -> some View {
        let isToday = cal.isDateInToday(d)
        let isSelected = cal.isDate(d, inSameDayAs: store.selectedDate)
        let inMonth = cal.isDate(d, equalTo: month, toGranularity: .month)
        return Button { store.selectedDate = d } label: {
            Text("\(cal.component(.day, from: d))")
                .font(.system(size: 11, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.6)))
                .frame(width: 26, height: 26)
                .background {
                    if isToday {
                        Circle().fill(Palette.accent)
                    } else if isSelected || inRange {
                        Circle().fill(Palette.accent.opacity(0.18))
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shift(_ n: Int) {
        month = cal.date(byAdding: .month, value: n, to: month) ?? month
    }
}
