import Foundation

struct LaidOutEvent: Identifiable {
    let event: CalendarEvent
    let startMin: Double
    let endMin: Double
    var column = 0
    var columns = 1
    var id: String { event.id }
}

/// Side-by-side layout for overlapping events, as Google Calendar does.
enum DayLayout {
    static func layout(_ events: [CalendarEvent], day: Date, calendar cal: Calendar = .current) -> [LaidOutEvent] {
        let dayStart = cal.startOfDay(for: day)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!

        var items = events.map { e in
            LaidOutEvent(event: e,
                         startMin: e.start <= dayStart ? 0 : cal.minutesIntoDay(e.start),
                         endMin: e.end >= dayEnd ? 1440 : cal.minutesIntoDay(e.end))
        }
        items.sort { ($0.startMin, -$0.endMin, $0.id) < ($1.startMin, -$1.endMin, $1.id) }

        var result: [LaidOutEvent] = []
        var cluster: [LaidOutEvent] = []
        var columnEnds: [Double] = []
        var clusterEnd = -1.0

        func flush() {
            for var c in cluster {
                c.columns = columnEnds.count
                result.append(c)
            }
            cluster = []
            columnEnds = []
        }

        for var item in items {
            let visualEnd = max(item.endMin, item.startMin + 20)
            if !cluster.isEmpty && item.startMin >= clusterEnd { flush() }
            if let idx = columnEnds.firstIndex(where: { $0 <= item.startMin }) {
                item.column = idx
                columnEnds[idx] = visualEnd
            } else {
                item.column = columnEnds.count
                columnEnds.append(visualEnd)
            }
            cluster.append(item)
            clusterEnd = max(clusterEnd, visualEnd)
        }
        flush()
        return result
    }
}
