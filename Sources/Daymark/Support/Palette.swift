import SwiftUI

enum Palette {
    static let accent = Color(hex: "#1A73E8")

    /// Event colour IDs 1–11, in the modern Google Calendar palette.
    static let eventColors: [String: String] = [
        "1": "#7986CB", "2": "#33B679", "3": "#8E24AA", "4": "#E67C73",
        "5": "#F6BF26", "6": "#F4511E", "7": "#039BE5", "8": "#616161",
        "9": "#3F51B5", "10": "#0B8043", "11": "#D50000",
    ]

    /// The calendar list API still returns the classic pastel palette; the apps show these modern equivalents.
    static let legacyCalendarColors: [String: String] = [
        "#ac725e": "#795548", "#d06b64": "#E67C73", "#f83a22": "#D50000", "#fa573c": "#F4511E",
        "#ff7537": "#EF6C00", "#ffad46": "#F09300", "#42d692": "#009688", "#16a765": "#0B8043",
        "#7bd148": "#7CB342", "#b3dc6c": "#C0CA33", "#fbe983": "#E4C441", "#fad165": "#F6BF26",
        "#92e1c0": "#33B679", "#9fe1e7": "#039BE5", "#9fc6e7": "#4285F4", "#4986e7": "#3F51B5",
        "#9a9cff": "#7986CB", "#b99aff": "#B39DDB", "#c2c2c2": "#616161", "#cabdbf": "#A79B8E",
        "#cca6ac": "#AD1457", "#f691b2": "#D81B60", "#cd74e6": "#8E24AA", "#a47ae2": "#9E69AF",
    ]

    static func calendarColor(_ hex: String?) -> String {
        guard let hex else { return "#039BE5" }
        return legacyCalendarColors[hex.lowercased()] ?? hex
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        guard s.count == 6 else { self = .gray; return }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255,
                  opacity: 1)
    }
}
