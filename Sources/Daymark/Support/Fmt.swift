import Foundation

enum Fmt {
    /// Format styles in a given calendar (time zone, week rules) and locale; defaults to the user's.
    static func style(_ base: Date.FormatStyle, _ cal: Calendar, _ locale: Locale) -> Date.FormatStyle {
        var f = base
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = locale
        return f
    }

    static func time(_ d: Date, calendar cal: Calendar = .current, locale: Locale = .current) -> String {
        d.formatted(style(.dateTime.hour().minute(), cal, locale))
    }

    static func timeRange(_ e: CalendarEvent, calendar cal: Calendar = .current, locale: Locale = .current) -> String {
        if e.isAllDay { return "All day" }
        if cal.isDate(e.start, inSameDayAs: e.end.addingTimeInterval(-1)) || e.start == e.end {
            return "\(time(e.start, calendar: cal, locale: locale)) – \(time(e.end, calendar: cal, locale: locale))"
        }
        let f = style(.dateTime.month(.abbreviated).day().hour().minute(), cal, locale)
        return "\(e.start.formatted(f)) – \(e.end.formatted(f))"
    }

    static func when(_ e: CalendarEvent, calendar cal: Calendar = .current, locale: Locale = .current) -> String {
        let dayStyle = style(.dateTime.weekday(.wide).month(.wide).day(), cal, locale)
        if e.isAllDay {
            let last = cal.date(byAdding: .day, value: -1, to: e.end) ?? e.end
            if cal.isDate(e.start, inSameDayAs: last) { return e.start.formatted(dayStyle) }
            return "\(e.start.formatted(style(.dateTime.month(.abbreviated).day(), cal, locale))) – \(last.formatted(style(.dateTime.month(.abbreviated).day().year(), cal, locale)))"
        }
        if e.start == e.end || cal.isDate(e.start, inSameDayAs: e.end.addingTimeInterval(-1)) {
            return "\(e.start.formatted(dayStyle)) · \(time(e.start, calendar: cal, locale: locale)) – \(time(e.end, calendar: cal, locale: locale))"
        }
        return timeRange(e, calendar: cal, locale: locale)
    }

    static func stripHTML(_ s: String) -> String {
        // Only treat it as HTML if it contains something tag-like; "x < 5 and y > 3" is plain text.
        guard s.range(of: "</?[A-Za-z][^<>]*>", options: .regularExpression) != nil
                || s.range(of: "&(nbsp|amp|lt|gt|quot|#39);", options: .regularExpression) != nil else { return s }
        // Keep link targets: <a href="X">Y</a> becomes "Y (X)", or just "X" when Y is the URL.
        var t = s.replacingOccurrences(of: "(?is)<a\\s[^>]*href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>",
                                       with: "$2 ($1)", options: .regularExpression)
        t = t.replacingOccurrences(of: "(\\S+) \\(\\1\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?i)<br\\s*/?>|</p>|</div>|</li>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "</?[A-Za-z][^<>]*>", with: "", options: .regularExpression)
        // &amp; last, so "&amp;lt;" becomes "&lt;" rather than "<".
        let entities = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")]
        for (k, v) in entities { t = t.replacingOccurrences(of: k, with: v) }
        t = t.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain text with URLs turned into clickable links.
    static func linkified(_ s: String) -> AttributedString {
        var out = AttributedString(s)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return out }
        let ns = s as NSString
        for m in detector.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            // Only web links become clickable: descriptions can be written by anyone who invites you.
            guard let url = m.url, SafeLink.url(url.absoluteString) != nil, let r = Range(m.range, in: s),
                  let lo = AttributedString.Index(r.lowerBound, within: out),
                  let hi = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lo..<hi].link = url
        }
        return out
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
