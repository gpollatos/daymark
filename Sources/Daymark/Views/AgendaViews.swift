import SwiftUI

/// The iOS app's "Schedule" view: a scrolling agenda grouped by day, with month banners.
struct ScheduleView: View {
    @Environment(CalendarStore.self) private var store
    private let cal = Calendar.current

    var body: some View {
        let sections = DayAgenda.sections(events: store.visibleEvents, days: store.visibleDays, today: store.now)
            .map { ($0.day, $0.events) }
        let anchor = sections.first { $0.0 >= cal.startOfDay(for: store.selectedDate) }?.0

        AgendaList(sections: sections, anchor: anchor, monthBanners: true,
                   scrollKey: "\(anchor?.timeIntervalSince1970 ?? 0)|\(store.loadedWindow?.start.timeIntervalSince1970 ?? 0)|\(sections.count)")
    }
}

struct SearchResultsView: View {
    @Environment(CalendarStore.self) private var store
    private let cal = Calendar.current

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if store.isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching…").foregroundStyle(.secondary)
                } else {
                    let n = store.searchResults?.count ?? 0
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(n) result\(n == 1 ? "" : "s") for “\(store.searchText.trimmed)”")
                            .font(.headline)
                        if !store.searchFailedCalendarKeys.isEmpty {
                            let names = store.searchFailedCalendarKeys.compactMap { store.calendar(key: $0)?.name }.sorted()
                            Label("Couldn't search: \(names.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                Spacer()
                Button("Done") { store.clearSearch() }
            }
            .padding(12)
            Divider()

            let results = store.searchResults ?? []
            let grouped = Dictionary(grouping: results) { cal.startOfDay(for: $0.start) }
            let sections = grouped.keys.sorted().map { ($0, grouped[$0]!) }
            let anchor = sections.first { $0.0 >= cal.startOfDay(for: .now) }?.0
            if results.isEmpty && !store.isSearching {
                ContentUnavailableView.search(text: store.searchText)
            } else {
                AgendaList(sections: sections, anchor: anchor, monthBanners: true,
                           scrollKey: "\(anchor?.timeIntervalSince1970 ?? 0)|\(sections.count)")
            }
        }
    }
}

private struct AgendaList: View {
    let sections: [(Date, [CalendarEvent])]
    let anchor: Date?
    let monthBanners: Bool
    /// Changes whenever the content or anchor changes, so we re-scroll after data arrives.
    let scrollKey: String
    private let cal = Calendar.current

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain VStack (≤ ~2 months of rows) so scrollTo lands exactly.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections.indices, id: \.self) { i in
                        let (day, list) = sections[i]
                        if monthBanners && (i == 0 || !cal.isDate(day, equalTo: sections[i - 1].0, toGranularity: .month)) {
                            Text(day.formatted(.dateTime.month(.wide).year()))
                                .font(.title2.weight(.semibold))
                                .padding(.top, i == 0 ? 8 : 28)
                                .padding(.bottom, 10)
                                .padding(.leading, 78)
                        }
                        AgendaDayRow(day: day, events: list)
                            .id(day)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { scroll(proxy) }
            .onChange(of: scrollKey) { scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let anchor else { return }
        DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
    }
}

private struct AgendaDayRow: View {
    @Environment(CalendarStore.self) private var store
    let day: Date
    let events: [CalendarEvent]
    private let cal = Calendar.current

    var body: some View {
        let isToday = cal.isDateInToday(day)
        HStack(alignment: .top, spacing: 16) {
            Button { store.show(day: day, mode: .day) } label: {
                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isToday ? Palette.accent : .secondary)
                    Text("\(cal.component(.day, from: day))")
                        .font(.system(size: 20, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? .white : .primary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(isToday ? Palette.accent : .clear))
                }
                .frame(width: 56)
            }
            .buttonStyle(.plain)

            VStack(spacing: 6) {
                if events.isEmpty {
                    Text("Nothing planned")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                } else {
                    ForEach(events) { AgendaEventCard(event: $0) }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct AgendaEventCard: View {
    let event: CalendarEvent
    @State private var showDetail = false

    var body: some View {
        let color = Color(hex: event.colorHex)
        let outlined = event.isDeclined || event.isUnconfirmed
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 13, weight: .semibold))
                    .strikethrough(event.isDeclined)
                Text(Fmt.timeRange(event)).font(.system(size: 12))
                if let loc = event.location, !loc.isEmpty {
                    Text(loc).font(.system(size: 12)).lineLimit(1)
                }
            }
            Spacer()
            if event.meetLink != nil {
                Image(systemName: "video.fill").font(.system(size: 12))
            }
        }
        .foregroundStyle(outlined ? color : .white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(outlined ? Color.clear : color))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: outlined ? 1.5 : 0))
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .popover(isPresented: $showDetail, arrowEdge: .trailing) {
            EventDetailView(event: event) { showDetail = false }
        }
    }
}
