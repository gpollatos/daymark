import SwiftUI

/// Day, 3-day and week views: an all-day lane on top and a scrollable 24-hour grid.
struct TimeGridView: View {
    @Environment(CalendarStore.self) private var store
    let days: [Date]

    private let hourHeight: CGFloat = 52
    private let gutter: CGFloat = 64
    private let cal = Calendar.current
    /// Where an event being dragged would land.
    @State private var moving: MovePreview?
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        let events = store.visibleEvents
        let timed = events.bucketed(by: days) { !$0.spansFullDays }
        let allDay = events.bucketed(by: days) { $0.spansFullDays }
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                allDayLane(allDay)
            }
            .background(Color(nsColor: .textBackgroundColor), ignoresSafeAreaEdges: [])
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        hourLabels
                        ForEach(days.indices, id: \.self) { i in
                            DayColumn(day: days[i], dayIndex: i, events: timed[i], hourHeight: hourHeight,
                                      moving: moving, onMove: handleMove, onResize: handleResize)
                                .overlay(alignment: .leading) { gridLine.frame(width: 1) }
                        }
                    }
                    .frame(height: hourHeight * 24)
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { gridWidth = g.size.width }
                            .onChange(of: g.size.width) { _, w in gridWidth = w }
                    })
                    .padding(.vertical, 10)
                }
                .onAppear { scrollToWorkingHours(proxy) }
            }
        }
    }

    private var gridLine: Color { Color(nsColor: .separatorColor) }

    private func handleMove(_ e: CalendarEvent, from dayIndex: Int, _ t: CGSize, ended: Bool) {
        guard e.canEdit, !e.isAllDay, !days.isEmpty else { return }
        let column = Double(gridWidth - gutter) / Double(days.count)
        let r = EventMover.moved(start: e.start, end: e.end, fromDay: dayIndex, dayCount: days.count,
                                 dx: Double(t.width), dy: Double(t.height), columnWidth: column,
                                 perMinute: Double(hourHeight / 60))
        if ended {
            moving = nil
            store.move(e, start: r.start, end: r.end)
        } else {
            moving = MovePreview(event: e, start: r.start, end: r.end)
        }
    }

    private func handleResize(_ e: CalendarEvent, _ dy: CGFloat, ended: Bool) {
        guard e.canEdit, !e.isAllDay else { return }
        let end = EventMover.resizedEnd(start: e.start, end: e.end, dy: Double(dy), perMinute: Double(hourHeight / 60))
        if ended {
            moving = nil
            store.move(e, start: e.start, end: end)
        } else {
            moving = MovePreview(event: e, start: e.start, end: end)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 0) {
            // Lined up with the weekday names, like Google Calendar.
            Text(TimeZone.current.abbreviation() ?? "")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .frame(width: gutter)
            ForEach(days, id: \.self) { d in
                let isToday = cal.isDateInToday(d)
                Button { store.show(day: d, mode: .day) } label: {
                    VStack(spacing: 2) {
                        Text(d.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isToday ? Palette.accent : .secondary)
                        Text("\(cal.component(.day, from: d))")
                            .font(.system(size: 22, weight: isToday ? .semibold : .regular))
                            .foregroundStyle(isToday ? .white : .primary)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(isToday ? Palette.accent : .clear))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    /// All-day events on top. Clicking an empty part of a day here creates an all-day event.
    private func allDayLane(_ perDay: [[CalendarEvent]]) -> some View {
        let maxShown = 3
        return HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days.indices, id: \.self) { i in
                VStack(spacing: 2) {
                    let list = perDay[i]
                    let shown = list.count > maxShown ? maxShown - 1 : list.count
                    if let draft = store.editorDraft, draft.placeholderCovers(day: days[i]) {
                        Text(draft.title.trimmed.isEmpty ? CalendarEvent.untitled : draft.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.accent))
                    }
                    ForEach(list.prefix(shown)) { EventChip(event: $0) }
                    if list.count > shown {
                        Button("\(list.count - shown) more") { store.show(day: days[i], mode: .day) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 4)
                    }
                }
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture { store.beginCreate(at: days[i], allDay: true) }
                .help("Click to add an all-day event")
            }
        }
        .padding(.bottom, 4)
    }

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { h in
                Text(h == 0 ? "" : hourLabel(h))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
                    .frame(width: gutter, height: hourHeight, alignment: .topTrailing)
                    .offset(y: -7)
                    .id(h)
            }
        }
    }

    private func hourLabel(_ h: Int) -> String {
        // A fixed reference day, so a missing hour on a DST-change day can't mislabel the row.
        (cal.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: h)) ?? Date()).formatted(.dateTime.hour())
    }

    private func scrollToWorkingHours(_ proxy: ScrollViewProxy) {
        let hour = days.contains(where: cal.isDateInToday)
            ? max(0, cal.component(.hour, from: Date()) - 2)
            : 7
        DispatchQueue.main.async { proxy.scrollTo(hour, anchor: .top) }
    }
}

struct MovePreview {
    let event: CalendarEvent
    var start: Date
    var end: Date
}

private struct DayColumn: View {
    @Environment(CalendarStore.self) private var store
    let day: Date
    let dayIndex: Int
    let events: [CalendarEvent]
    let hourHeight: CGFloat
    let moving: MovePreview?
    let onMove: (CalendarEvent, Int, CGSize, Bool) -> Void
    let onResize: (CalendarEvent, CGFloat, Bool) -> Void
    private let cal = Calendar.current
    /// Grid minutes where the current click or drag started and where it is now.
    @State private var drag: (from: Double, to: Double)?

    var body: some View {
        GeometryReader { geo in
            let laid = DayLayout.layout(events, day: day)
            let perMinute = hourHeight / 60
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        VStack(spacing: 0) {
                            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                            Spacer(minLength: 0)
                        }
                        .frame(height: hourHeight)
                    }
                }

                // Click an empty slot to create a one-hour event there, or drag to pick the times.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { v in
                            drag = (Double(v.startLocation.y / perMinute), Double(v.location.y / perMinute))
                        }
                        .onEnded { v in
                            let r = SlotPicker.range(from: Double(v.startLocation.y / perMinute),
                                                     to: Double(v.location.y / perMinute), day: day)
                            drag = nil
                            store.beginCreate(at: r.start, end: r.end)
                        })

                if let drag, abs(drag.to - drag.from) >= SlotPicker.clickTolerance {
                    let r = SlotPicker.range(from: drag.from, to: drag.to, day: day)
                    let top = CGFloat(cal.minutesIntoDay(r.start)) * perMinute
                    let bottom = cal.isDate(r.end, inSameDayAs: day) ? CGFloat(cal.minutesIntoDay(r.end)) * perMinute : hourHeight * 24
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Palette.accent.opacity(0.25))
                        .overlay(alignment: .topLeading) {
                            Text("\(Fmt.time(r.start)) – \(Fmt.time(r.end))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Palette.accent)
                                .padding(4)
                        }
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.accent, lineWidth: 1))
                        .frame(width: geo.size.width - 4, height: max(bottom - top, 12))
                        .offset(x: 2, y: top)
                        .allowsHitTesting(false)
                }

                // The event being created stays highlighted while its editor is open.
                if let draft = store.editorDraft, let slot = draft.placeholderMinutes(on: day) {
                    let height = max(CGFloat(slot.end - slot.start) * perMinute, 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(draft.title.trimmed.isEmpty ? CalendarEvent.untitled : draft.title).fontWeight(.semibold)
                        Text("\(Fmt.time(draft.start)) – \(Fmt.time(draft.end))").opacity(0.9)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .frame(width: geo.size.width - 4, height: height - 1, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Palette.accent))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .offset(x: 2, y: CGFloat(slot.start) * perMinute)
                    .allowsHitTesting(false)
                    .zIndex(1)
                }

                ForEach(laid) { item in
                    let colWidth = (geo.size.width - 6) / CGFloat(item.columns)
                    let height = max(CGFloat(item.endMin - item.startMin) * perMinute, 18)
                    let e = item.event
                    EventBlock(event: e, height: height)
                        .overlay(alignment: .bottom) {
                            // Drag the bottom edge to change when the event ends.
                            if e.canEdit {
                                Color.clear
                                    .frame(height: 6)
                                    .contentShape(Rectangle())
                                    .onHover { inside in
                                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                                    }
                                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                        .onChanged { onResize(e, $0.translation.height, false) }
                                        .onEnded { onResize(e, $0.translation.height, true) })
                            }
                        }
                        .opacity(moving?.event.id == e.id ? 0.35 : 1)
                        .frame(width: max(colWidth - 2, 12), height: height - 1)
                        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                            .onChanged { onMove(e, dayIndex, $0.translation, false) }
                            .onEnded { onMove(e, dayIndex, $0.translation, true) })
                        .offset(x: CGFloat(item.column) * colWidth + 1, y: CGFloat(item.startMin) * perMinute)
                }

                // Where a dragged event will land.
                if let moving, let slot = cal.slotMinutes(start: moving.start, end: moving.end, on: day) {
                    let height = max(CGFloat(slot.end - slot.start) * perMinute, 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(moving.event.title).fontWeight(.semibold)
                        Text("\(Fmt.time(moving.start)) – \(Fmt.time(moving.end))").opacity(0.9)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .frame(width: geo.size.width - 4, height: height - 1, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: moving.event.colorHex)))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    .offset(x: 2, y: CGFloat(slot.start) * perMinute)
                    .allowsHitTesting(false)
                    .zIndex(2)
                }

                if cal.isDateInToday(day) {
                    let y = CGFloat(cal.minutesIntoDay(store.now)) * perMinute
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.red).frame(height: 2)
                        Circle().fill(Color.red).frame(width: 10, height: 10).offset(x: -5)
                    }
                    .offset(y: y - 1)
                    .allowsHitTesting(false)
                }
            }
        }
    }
}
