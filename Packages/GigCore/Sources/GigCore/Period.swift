import Foundation

/// Day / Week / Month / Quarter / Year views used by the Offers, Earnings and Insights tabs.
public enum Period: String, CaseIterable, Identifiable, Codable {
    case day, week, month, quarter, year

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        case .quarter: return "Quarter"
        case .year: return "Year"
        }
    }

    /// The whole day/week/month/quarter/year that contains `date`.
    public func interval(containing date: Date, calendar cal: Calendar = .current) -> DateInterval {
        switch self {
        case .day: return cal.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 86_400)
        case .week: return cal.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
        case .month: return cal.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 30 * 86_400)
        case .year: return cal.dateInterval(of: .year, for: date) ?? DateInterval(start: date, duration: 365 * 86_400)
        case .quarter:
            let month = cal.component(.month, from: date)
            var c = DateComponents()
            c.year = cal.component(.year, from: date)
            c.month = ((month - 1) / 3) * 3 + 1
            c.day = 1
            let start = cal.date(from: c) ?? date
            let end = cal.date(byAdding: .month, value: 3, to: start) ?? start.addingTimeInterval(91 * 86_400)
            return DateInterval(start: start, end: end)
        }
    }

    /// Moves a date forward/back by whole periods (for the ‹ › arrows).
    public func shift(_ date: Date, by n: Int, calendar cal: Calendar = .current) -> Date {
        switch self {
        case .day: return cal.date(byAdding: .day, value: n, to: date) ?? date
        case .week: return cal.date(byAdding: .weekOfYear, value: n, to: date) ?? date
        case .month: return cal.date(byAdding: .month, value: n, to: date) ?? date
        case .quarter: return cal.date(byAdding: .month, value: 3 * n, to: date) ?? date
        case .year: return cal.date(byAdding: .year, value: n, to: date) ?? date
        }
    }

    public func title(for interval: DateInterval, calendar cal: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US")
        switch self {
        case .day:
            f.dateFormat = "EEE, MMM d, yyyy"
            return f.string(from: interval.start)
        case .week:
            f.dateFormat = "MMM d"
            let last = interval.end.addingTimeInterval(-1)
            let y = DateFormatter(); y.calendar = cal; y.timeZone = cal.timeZone; y.dateFormat = "yyyy"
            return "\(f.string(from: interval.start)) – \(f.string(from: last)), \(y.string(from: last))"
        case .month:
            f.dateFormat = "MMMM yyyy"
            return f.string(from: interval.start)
        case .quarter:
            let q = (cal.component(.month, from: interval.start) - 1) / 3 + 1
            return "Q\(q) \(cal.component(.year, from: interval.start))"
        case .year:
            return "\(cal.component(.year, from: interval.start))"
        }
    }

    /// How the period is split for charts: hours of a day, days of a week/month,
    /// weeks of a quarter, months of a year.
    public var bucketComponent: Calendar.Component {
        switch self {
        case .day: return .hour
        case .week, .month: return .day
        case .quarter: return .weekOfYear
        case .year: return .month
        }
    }

    public var bucketName: String {
        switch self {
        case .day: return "hour"
        case .week, .month: return "day"
        case .quarter: return "week"
        case .year: return "month"
        }
    }

    public var previousName: String {
        switch self {
        case .day: return "the day before"
        case .week: return "last week"
        case .month: return "last month"
        case .quarter: return "last quarter"
        case .year: return "last year"
        }
    }

    public func buckets(for interval: DateInterval, calendar cal: Calendar = .current) -> [DateInterval] {
        var out: [DateInterval] = []
        var t = interval.start
        let step: (Date) -> Date? = { d in
            switch self {
            case .quarter: return cal.date(byAdding: .day, value: 7, to: d)
            default: return cal.date(byAdding: self.bucketComponent, value: 1, to: d)
            }
        }
        while t < interval.end, out.count < 400 {
            guard let next = step(t), next > t else { break }
            out.append(DateInterval(start: t, end: min(next, interval.end)))
            t = next
        }
        return out
    }

    public func bucketTitle(_ b: DateInterval, calendar cal: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.locale = Locale(identifier: "en_US")
        switch self {
        case .day:
            let h = cal.component(.hour, from: b.start)
            let h12 = h % 12 == 0 ? 12 : h % 12
            return "\(h12)\(h < 12 ? "am" : "pm")"
        case .week: f.dateFormat = "EEEE"
        case .month: f.dateFormat = "MMM d"
        case .quarter: f.dateFormat = "'week of' MMM d"
        case .year: f.dateFormat = "MMMM"
        }
        return f.string(from: b.start)
    }
}
