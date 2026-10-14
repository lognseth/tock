import Foundation

enum Dates {
    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let shortDay: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f
    }()
    private static let dayMonth: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM"); return f
    }()
    private static let dayMonthYear: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("d MMM yyyy"); return f
    }()
    private static let longDay: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE d MMM"); return f
    }()

    static var calendar: Calendar { Calendar.current }

    static func format(_ d: Date) -> String { iso.string(from: d) }
    static func parseISO(_ s: String) -> Date? { iso.date(from: s) }
    static func startOfDay(_ d: Date) -> Date { calendar.startOfDay(for: d) }
    static func addDays(_ d: Date, _ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: d) ?? d }
    static func dayDiff(from a: Date, to b: Date) -> Int {
        calendar.dateComponents([.day], from: startOfDay(a), to: startOfDay(b)).day ?? 0
    }

    /// Short label for chips: Today, Tomorrow, Wed, 21 Oct.
    static func label(_ d: Date, now: Date) -> String {
        switch dayDiff(from: now, to: d) {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return shortDay.string(from: d)
        default:
            let sameYear = calendar.component(.year, from: d) == calendar.component(.year, from: now)
            return (sameYear ? dayMonth : dayMonthYear).string(from: d)
        }
    }

    /// Section title in the Upcoming view.
    static func heading(_ d: Date, now: Date) -> String {
        switch dayDiff(from: now, to: d) {
        case 1: return "Tomorrow"
        default: return longDay.string(from: d)
        }
    }

    private static func captures(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map {
            Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? ""
        }
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// today, tomorrow, mon, +3d, +2w, +1m, nextweek, 2026-10-20, 24.12, 24.12.2026
    static func parse(_ raw: String, now: Date = Date()) -> Date? {
        let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let today = startOfDay(now)
        let wd = calendar.component(.weekday, from: today)  // Sunday = 1

        switch s {
        case "today", "tod", "t", "now": return today
        case "tomorrow", "tom", "tmr", "tmrw": return addDays(today, 1)
        case "nextweek", "nw":
            let delta = (2 - wd + 7) % 7
            return addDays(today, delta == 0 ? 7 : delta)
        default: break
        }

        if let c = captures(#"^\+(\d+)([dwm])$"#, in: s), let n = Int(c[1]) {
            switch c[2] {
            case "d": return addDays(today, n)
            case "w": return addDays(today, 7 * n)
            default: return calendar.date(byAdding: .month, value: n, to: today)
            }
        }

        if s.count >= 3, let idx = weekdays.firstIndex(where: { $0.hasPrefix(s) }) {
            let delta = (idx + 1 - wd + 7) % 7
            return addDays(today, delta == 0 ? 7 : delta)
        }

        if captures(#"^\d{4}-\d{2}-\d{2}$"#, in: s) != nil { return parseISO(s) }

        if let c = captures(#"^(\d{1,2})\.(\d{1,2})(?:\.(\d{2,4}))?$"#, in: s),
           let day = Int(c[1]), let month = Int(c[2]) {
            var comps = DateComponents(month: month, day: day)
            if let y = Int(c[3]) {
                comps.year = y < 100 ? 2000 + y : y
                return validated(comps)
            }
            comps.year = calendar.component(.year, from: today)
            guard let d = validated(comps) else { return nil }
            if d < today { comps.year! += 1; return validated(comps) }
            return d
        }
        return nil
    }

    /// Rejects overflowing dates like 31.02 that Calendar would silently roll over.
    private static func validated(_ comps: DateComponents) -> Date? {
        guard let d = calendar.date(from: comps) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: d)
        guard back.year == comps.year, back.month == comps.month, back.day == comps.day else { return nil }
        return d
    }
}

struct Recurrence {
    var n: Int
    var unit: Calendar.Component
    var weekdaysOnly: Bool
    var whenDone: Bool

    /// Parses "every week", "every 2 days", "every weekday", "every month when done".
    init?(_ text: String) {
        var s = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("every") else { return nil }
        s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        whenDone = s.hasSuffix("when done")
        if whenDone { s = String(s.dropLast(9)).trimmingCharacters(in: .whitespaces) }

        if s == "weekday" || s == "weekdays" {
            n = 1; unit = .day; weekdaysOnly = true
            return
        }
        guard let re = try? NSRegularExpression(pattern: #"^(\d+)?\s*(day|week|month|year)s?$"#),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let ur = Range(m.range(at: 2), in: s) else { return nil }
        n = Range(m.range(at: 1), in: s).flatMap { Int(s[$0]) } ?? 1
        guard n > 0 else { return nil }
        switch s[ur] {
        case "day": unit = .day
        case "week": unit = .weekOfYear
        case "month": unit = .month
        default: unit = .year
        }
        weekdaysOnly = false
    }

    /// Token after `~` in the quick-entry field: ~weekly, ~2w, ~weekday.
    static func canonical(token: String) -> String? {
        let t = token.lowercased()
        switch t {
        case "daily", "day": return "every day"
        case "weekly", "week": return "every week"
        case "monthly", "month": return "every month"
        case "yearly", "year": return "every year"
        case "weekday", "weekdays": return "every weekday"
        default: break
        }
        guard let re = try? NSRegularExpression(pattern: #"^(\d*)([dwmy])$"#),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let ur = Range(m.range(at: 2), in: t) else { return nil }
        let n = Range(m.range(at: 1), in: t).flatMap { Int(t[$0]) } ?? 1
        guard n > 0 else { return nil }
        let name = ["d": "day", "w": "week", "m": "month", "y": "year"][String(t[ur])]!
        return n == 1 ? "every \(name)" : "every \(n) \(name)s"
    }

    func next(from base: Date, today: Date) -> Date {
        let cal = Dates.calendar
        var d = cal.date(byAdding: unit, value: n, to: whenDone ? today : base) ?? base
        if weekdaysOnly { while cal.isDateInWeekend(d) { d = Dates.addDays(d, 1) } }
        return d
    }
}
