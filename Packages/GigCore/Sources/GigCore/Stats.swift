import Foundation

/// Totals for a set of offers. Money/miles/time come only from offers you marked Accepted.
public struct PeriodSummary: Equatable {
    public var offers = 0
    public var good = 0
    public var fair = 0
    public var bad = 0
    public var accepted = 0
    public var declined = 0
    public var goodDeclined = 0
    public var income = 0.0
    public var miles = 0.0
    public var minutes = 0
    public var net = 0.0
    // Only orders that showed time / miles count toward the averages.
    var payWithTime = 0.0
    var payWithMiles = 0.0

    public init() {}

    public var avgHourly: Double? { minutes > 0 ? payWithTime / (Double(minutes) / 60) : nil }
    public var avgPerMile: Double? { miles > 0 ? payWithMiles / miles : nil }
    public var acceptanceRate: Double? { accepted + declined > 0 ? Double(accepted) / Double(accepted + declined) : nil }
    public var hours: Double { Double(minutes) / 60 }
}

public enum Stats {

    public static func summary(_ records: [OfferRecord], costPerMile: Double) -> PeriodSummary {
        var s = PeriodSummary()
        for r in records {
            s.offers += 1
            switch r.category {
            case .good: s.good += 1
            case .fair: s.fair += 1
            case .bad: s.bad += 1
            }
            switch r.decision {
            case .accepted:
                s.accepted += 1
                s.income += r.pay
                s.net += r.netPay(costPerMile: costPerMile) ?? r.pay
                if let m = r.minutes, m > 0 { s.minutes += m; s.payWithTime += r.pay }
                if let mi = r.miles, mi > 0 { s.miles += mi; s.payWithMiles += r.pay }
            case .declined:
                s.declined += 1
                if r.category == .good { s.goodDeclined += 1 }
            case .pending:
                break
            }
        }
        return s
    }

    public struct Bucket: Identifiable, Equatable {
        public var id: Date { start }
        public var start: Date
        public var end: Date
        public var title: String
        public var summary: PeriodSummary
    }

    public static func buckets(_ records: [OfferRecord], period: Period, interval: DateInterval,
                               calendar: Calendar = .current, costPerMile: Double) -> [Bucket] {
        period.buckets(for: interval, calendar: calendar).map { b in
            let inB = records.filter { $0.date >= b.start && $0.date < b.end }
            return Bucket(start: b.start, end: b.end, title: period.bucketTitle(b, calendar: calendar),
                          summary: summary(inB, costPerMile: costPerMile))
        }
    }

    public struct AppShare: Identifiable, Equatable {
        public var id: String { app.rawValue }
        public var app: GigApp
        public var summary: PeriodSummary
    }

    /// Per-app totals (accepted orders), biggest earner first. Apps with no offers are left out.
    public static func byApp(_ records: [OfferRecord], costPerMile: Double) -> [AppShare] {
        Dictionary(grouping: records, by: \.app)
            .map { AppShare(app: $0.key, summary: summary($0.value, costPerMile: costPerMile)) }
            .sorted { ($0.summary.income, $0.summary.offers) > ($1.summary.income, $1.summary.offers) }
    }

    /// Plain-English takeaways for the Insights tab.
    public static func insights(current c: PeriodSummary, previous p: PeriodSummary, buckets: [Bucket],
                                apps: [AppShare], period: Period, settings: DriverSettings) -> [String] {
        var out: [String] = []
        let money = { (x: Double) in String(format: "$%.2f", x) }

        if c.offers == 0 { return ["No offers logged for this \(period.label.lowercased()) yet."] }

        if c.accepted > 0 {
            var line = "You earned \(money(c.income)) from \(c.accepted) accepted order\(c.accepted == 1 ? "" : "s")"
            if let h = c.avgHourly { line += String(format: ", averaging $%.2f/hr", h) }
            if let m = c.avgPerMile { line += String(format: " and $%.2f/mi", m) }
            out.append(line + ".")
            if p.income > 0 {
                let change = (c.income - p.income) / p.income * 100
                out.append("Earnings are \(change >= 0 ? "up" : "down") \(String(format: "%.0f", abs(change)))% vs \(period.previousName) (\(money(p.income))).")
            }
            if let h = c.avgHourly {
                if h >= settings.hourlyGood { out.append(String(format: "Your average hourly rate beat your $%.0f good level.", settings.hourlyGood)) }
                else if h < settings.hourlyFair { out.append(String(format: "Your average hourly rate is below your $%.0f fair level — consider being pickier.", settings.hourlyFair)) }
            }
        } else {
            out.append("No orders marked Accepted yet — tap ✓ on the orders you took to see earnings.")
        }

        let goodPct = Double(c.good) / Double(c.offers) * 100
        out.append(String(format: "%d offers seen: %.0f%% good, %.0f%% fair, %.0f%% bad.",
                          c.offers, goodPct, Double(c.fair) / Double(c.offers) * 100, Double(c.bad) / Double(c.offers) * 100))

        if let rate = c.acceptanceRate {
            out.append(String(format: "You accepted %.0f%% of the offers you marked.", rate * 100))
        }
        if c.goodDeclined > 0 {
            out.append("You declined \(c.goodDeclined) good (green) offer\(c.goodDeclined == 1 ? "" : "s").")
        }

        if let best = buckets.filter({ $0.summary.income > 0 }).max(by: { $0.summary.income < $1.summary.income }) {
            out.append("Best \(period.bucketName): \(best.title) with \(money(best.summary.income)) earned.")
        }
        if let bestRate = buckets.compactMap({ b in b.summary.avgHourly.map { (b, $0) } }).max(by: { $0.1 < $1.1 }),
           buckets.filter({ $0.summary.avgHourly != nil }).count > 1 {
            out.append("Highest-paying \(period.bucketName): \(bestRate.0.title) at \(String(format: "$%.2f", bestRate.1))/hr.")
        }
        if let busiest = buckets.max(by: { $0.summary.offers < $1.summary.offers }), busiest.summary.offers > 0 {
            out.append("Most offers came in during \(busiest.title) (\(busiest.summary.offers)).")
        }

        let paying = apps.filter { $0.summary.accepted > 0 && $0.summary.avgHourly != nil }
        if paying.count > 1, let top = paying.max(by: { ($0.summary.avgHourly ?? 0) < ($1.summary.avgHourly ?? 0) }) {
            out.append("\(top.app.rawValue) paid best per hour: \(String(format: "$%.2f", top.summary.avgHourly ?? 0))/hr across \(top.summary.accepted) order\(top.summary.accepted == 1 ? "" : "s").")
        }
        if let mostGood = apps.filter({ $0.summary.offers >= 3 }).max(by: {
            Double($0.summary.good) / Double($0.summary.offers) < Double($1.summary.good) / Double($1.summary.offers)
        }), mostGood.summary.good > 0 {
            let share = Double(mostGood.summary.good) / Double(mostGood.summary.offers) * 100
            out.append("\(mostGood.app.rawValue) sent the highest share of good offers (\(String(format: "%.0f", share))%).")
        }
        return out
    }
}
