import SwiftUI

struct MonthView: View {
    @Environment(CalendarStore.self) private var store
    private let cal = Calendar.current

    var body: some View {
        let days = cal.days(in: store.monthGridRange)
        let weeks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        let symbols = cal.orderedWeekdaySymbols(cal.shortStandaloneWeekdaySymbols)
        let perDay = store.visibleEvents.bucketed(by: days).map { $0.sorted(by: DayAgenda.order) }
        let month = store.selectedDate

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(symbols.indices, id: \.self) { i in
                    Text(symbols[i].uppercased())
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            Divider()
            ForEach(weeks.indices, id: \.self) { w in
                HStack(spacing: 0) {
                    ForEach(0..<weeks[w].count, id: \.self) { i in
                        let d = weeks[w][i]
                        MonthCell(day: d,
                                  events: perDay[w * 7 + i],
                                  inMonth: cal.isDate(d, equalTo: month, toGranularity: .month))
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                            }
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
            }
        }
    }
}

private struct MonthCell: View {
    @Environment(CalendarStore.self) private var store
    let day: Date
    let events: [CalendarEvent]
    let inMonth: Bool
    private let cal = Calendar.current

    var body: some View {
        GeometryReader { geo in
            let rowHeight: CGFloat = 19
            let capacity = max(0, Int((geo.size.height - 30) / rowHeight))
            let shown = events.count > capacity ? max(0, capacity - 1) : events.count
            let isToday = cal.isDateInToday(day)

            VStack(alignment: .leading, spacing: 2) {
                Button { store.show(day: day, mode: .day) } label: {
                    Text(cal.component(.day, from: day) == 1
                         ? day.formatted(.dateTime.month(.abbreviated).day())
                         : "\(cal.component(.day, from: day))")
                        .font(.system(size: 12, weight: isToday ? .bold : .medium))
                        .foregroundStyle(isToday ? .white : (inMonth ? .primary : .secondary))
                        .padding(.horizontal, 7)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Capsule().fill(isToday ? Palette.accent : .clear))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                ForEach(events.prefix(shown)) { EventChip(event: $0, showTime: true) }
                if events.count > shown {
                    Button("\(events.count - shown) more") { store.show(day: day, mode: .day) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)
            .padding(.top, 3)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .background(inMonth ? Color.clear : Color.secondary.opacity(0.04))
            .contentShape(Rectangle())
            // Click an empty part of the day to add an all-day event, like Google Calendar.
            .onTapGesture { store.beginCreate(at: day, allDay: true) }
        }
    }
}
