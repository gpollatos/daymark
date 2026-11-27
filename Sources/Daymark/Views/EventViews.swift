import SwiftUI

/// How an event is drawn: solid when going, outlined when not yet answered, struck through when declined.
private struct EventStyle {
    let fill: Color
    let text: Color
    let border: Color
    let strike: Bool

    init(_ e: CalendarEvent) {
        let c = Color(hex: e.colorHex)
        if e.isDeclined || e.isUnconfirmed {
            fill = Color(nsColor: .textBackgroundColor)
            text = c
            border = c
            strike = e.isDeclined
        } else {
            fill = c
            text = .white
            border = Color(nsColor: .textBackgroundColor)
            strike = false
        }
    }
}

/// A timed event block in the Day / 3-day / Week grid.
struct EventBlock: View {
    let event: CalendarEvent
    let height: CGFloat
    @State private var showDetail = false

    var body: some View {
        let style = EventStyle(event)
        VStack(alignment: .leading, spacing: 1) {
            if height < 34 {
                Text("\(event.title), \(Fmt.time(event.start))")
                    .fontWeight(.medium)
                    .lineLimit(1)
            } else {
                Text(event.title)
                    .fontWeight(.semibold)
                    .lineLimit(height > 64 ? 3 : 1)
                Text(Fmt.timeRange(event)).lineLimit(1).opacity(0.9)
                if height > 80, let loc = event.location, !loc.isEmpty {
                    Text(loc).lineLimit(1).opacity(0.9)
                }
            }
        }
        .font(.system(size: 11))
        .strikethrough(style.strike)
        .foregroundStyle(style.text)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 5).fill(style.fill))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(style.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .popover(isPresented: $showDetail, arrowEdge: .trailing) {
            EventDetailView(event: event) { showDetail = false }
        }
        .help(event.title)
    }
}

/// A compact one-line event used in the all-day lane and month cells.
struct EventChip: View {
    let event: CalendarEvent
    var showTime = false
    @State private var showDetail = false

    var body: some View {
        Group {
            if event.spansFullDays || !showTime {
                let style = EventStyle(event)
                Text(event.title)
                    .fontWeight(.medium)
                    .strikethrough(style.strike)
                    .foregroundStyle(style.text)
                    .padding(.horizontal, 5)
                    .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 4).fill(style.fill))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(style.border, lineWidth: 1))
            } else {
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: event.colorHex)).frame(width: 7, height: 7)
                    Text(Fmt.time(event.start)).foregroundStyle(.secondary)
                    Text(event.title).fontWeight(.medium).strikethrough(event.isDeclined)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 3)
                .frame(minHeight: 17)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .contentShape(Rectangle())
        .onTapGesture { showDetail = true }
        .popover(isPresented: $showDetail, arrowEdge: .trailing) {
            EventDetailView(event: event) { showDetail = false }
        }
        .help(event.title)
    }
}

struct EventDetailView: View {
    @Environment(CalendarStore.self) private var store
    let event: CalendarEvent
    let close: () -> Void
    /// Run once the popover has gone, so a sheet or dialog doesn't collide with it.
    @State private var afterClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: event.colorHex))
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Fmt.when(event)).foregroundStyle(.secondary)
                    if event.recurringEventId != nil {
                        Label("Repeating event", systemImage: "repeat")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let url = SafeLink.url(event.meetLink) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Join with Google Meet", systemImage: "video.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            if let loc = event.location, !loc.isEmpty {
                row("mappin.and.ellipse") {
                    if let url = URL(string: loc), url.scheme?.hasPrefix("http") == true {
                        Link(loc, destination: url)
                    } else {
                        Link(loc, destination: mapsURL(loc))
                    }
                }
            }

            row("calendar") {
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.calendarName)
                    Text(event.accountEmail).font(.caption).foregroundStyle(.secondary)
                }
            }

            if !event.attendees.isEmpty { guests }

            if let notes = event.notes, !notes.isEmpty {
                row("text.alignleft") {
                    ScrollView {
                        Text(Fmt.linkified(Fmt.stripHTML(notes)))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                }
            }

            if event.canRespond {
                HStack(spacing: 6) {
                    Text("Going?").foregroundStyle(.secondary)
                    Spacer()
                    rsvp("Yes", "accepted")
                    rsvp("No", "declined")
                    rsvp("Maybe", "tentative")
                }
            }

            Divider()
            HStack {
                if let link = SafeLink.url(event.htmlLink) {
                    Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "safari") }
                        .buttonStyle(.borderless)
                        .help("Open in Google Calendar on the web")
                }
                Spacer()
                if event.canDelete {
                    Button(event.isOrganizer ? "Delete" : "Remove", role: .destructive) {
                        afterClose = { [store, event] in store.pendingDelete = event }
                        close()
                    }
                }
                if event.canEdit {
                    Button("Edit") {
                        afterClose = { [store, event] in store.beginEdit(event) }
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
        .onDisappear {
            let action = afterClose
            afterClose = nil
            DispatchQueue.main.async { action?() }
        }
    }

    private var guests: some View {
        let yes = event.attendees.filter { $0.responseStatus == "accepted" }.count
        let sorted = event.attendees.sorted { ($0.organizer == true ? 0 : 1) < ($1.organizer == true ? 0 : 1) }
        return row("person.2") {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(event.attendees.count) guests · \(yes) yes").fontWeight(.medium)
                ForEach(sorted.prefix(12), id: \.self) { a in
                    HStack(spacing: 6) {
                        responseIcon(a.responseStatus)
                        Text(a.displayName ?? a.email ?? "Guest").lineLimit(1)
                        if a.organizer == true {
                            Text("Organizer").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
                if sorted.count > 12 {
                    Text("+\(sorted.count - 12) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func responseIcon(_ s: String?) -> some View {
        let (name, color): (String, Color) = switch s {
        case "accepted": ("checkmark.circle.fill", .green)
        case "declined": ("xmark.circle.fill", .red)
        case "tentative": ("questionmark.circle.fill", .orange)
        default: ("circle", .secondary)
        }
        return Image(systemName: name).foregroundStyle(color)
    }

    private func rsvp(_ label: String, _ status: String) -> some View {
        let selected = event.selfResponse == status
        return Button(label) {
            Task { await store.respond(event, status) }
            close()
        }
        .buttonStyle(.bordered)
        .tint(selected ? Palette.accent : nil)
        .fontWeight(selected ? .semibold : .regular)
    }

    private func row<Content: View>(_ icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 14)
            content()
        }
    }

    private func mapsURL(_ q: String) -> URL {
        var c = URLComponents(string: "https://www.google.com/maps/search/")!
        c.queryItems = [URLQueryItem(name: "api", value: "1"), URLQueryItem(name: "query", value: q)]
        return c.url!
    }
}
