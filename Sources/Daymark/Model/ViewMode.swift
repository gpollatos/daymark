import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case schedule, day, threeDay, workWeek, week, month
    var id: String { rawValue }

    var title: String {
        switch self {
        case .schedule: "Schedule"
        case .day: "Day"
        case .threeDay: "3 Days"
        case .workWeek: "Work Week"
        case .week: "Week"
        case .month: "Month"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .schedule: "1"
        case .day: "2"
        case .threeDay: "3"
        case .workWeek: "4"
        case .week: "5"
        case .month: "6"
        }
    }
}
