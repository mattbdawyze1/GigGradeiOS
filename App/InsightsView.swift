import SwiftUI
import Charts
import GigCore

/// Charts + plain-English takeaways, split within the period:
/// a day by hour, a week/month by day, a quarter by week, a year by month.
struct InsightsView: View {
    @StateObject private var model = LogModel(period: .week)

    var body: some View {
        NavigationStack {
            List {
                Section { PeriodHeader(model: model) }

                let s = model.settings
                let cost = s.costPerMile
                let sum = Stats.summary(model.records, costPerMile: cost)
                let prev = Stats.summary(model.previous, costPerMile: cost)
                let buckets = Stats.buckets(model.records, period: model.period, interval: model.interval,
                                            calendar: model.calendar, costPerMile: cost)
                let apps = Stats.byApp(model.records, costPerMile: cost)
                let unit = model.period.bucketComponent

                Section("Highlights") {
                    ForEach(Array(Stats.insights(current: sum, previous: prev, buckets: buckets, apps: apps,
                                                 period: model.period, settings: s).enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "lightbulb").font(.subheadline)
                    }
                }

                if sum.offers > 0 {
                    Section {
                        Chart(buckets) { b in
                            BarMark(x: .value("When", b.start, unit: unit), y: .value("Income", b.summary.income))
                                .foregroundStyle(OfferCategory.good.color)
                        }
                        .chartYAxis {
                            AxisMarks { v in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let d = v.as(Double.self) { Text("$\(Int(d))") }
                                }
                            }
                        }
                        .frame(height: 180)
                    } header: {
                        Text("Earnings by \(model.period.bucketName)")
                    } footer: {
                        Text(peak(buckets, by: { $0.summary.income }).map { "Peak: \($0.title) (\(money($0.summary.income)))." } ?? "No accepted orders yet.")
                    }

                    Section {
                        Chart {
                            ForEach(buckets) { b in
                                ForEach(OfferCategory.allCases) { c in
                                    BarMark(x: .value("When", b.start, unit: unit), y: .value("Offers", count(b, c)))
                                        .foregroundStyle(by: .value("Rating", c.label))
                                }
                            }
                        }
                        .chartForegroundStyleScale(["Good": OfferCategory.good.color, "Fair": OfferCategory.fair.color, "Bad": OfferCategory.bad.color])
                        .frame(height: 180)
                    } header: {
                        Text("Offers by \(model.period.bucketName)")
                    } footer: {
                        Text(peak(buckets, by: { Double($0.summary.good) }).map { "Most good offers: \($0.title) (\($0.summary.good))." } ?? "No good offers yet this period.")
                    }

                    rateChart(title: "Average $ per hour", buckets: buckets, unit: unit,
                              value: { $0.summary.avgHourly }, fair: s.hourlyFair, good: s.hourlyGood, format: "$%.0f")
                    rateChart(title: "Average $ per mile", buckets: buckets, unit: unit,
                              value: { $0.summary.avgPerMile }, fair: s.perMileFair, good: s.perMileGood, format: "$%.2f")

                    DetourCharts(records: model.records, settings: s)

                    let earning = apps.filter { $0.summary.income > 0 }
                    if !earning.isEmpty {
                        Section {
                            Chart(earning) { a in
                                SectorMark(angle: .value("Income", a.summary.income), innerRadius: .ratio(0.6), angularInset: 1.5)
                                    .foregroundStyle(by: .value("App", a.app.rawValue))
                            }
                            .frame(height: 200)
                        } header: {
                            Text("Income by app")
                        } footer: {
                            Text(earning.map { "\($0.app.rawValue) \(money($0.summary.income))" }.joined(separator: " · "))
                        }
                    }

                    Section {
                        Chart {
                            ForEach(buckets) { b in
                                BarMark(x: .value("When", b.start, unit: unit), y: .value("Count", b.summary.accepted))
                                    .foregroundStyle(by: .value("Decision", "Accepted"))
                                BarMark(x: .value("When", b.start, unit: unit), y: .value("Count", b.summary.declined))
                                    .foregroundStyle(by: .value("Decision", "Declined"))
                            }
                        }
                        .chartForegroundStyleScale(["Accepted": Color.accentColor, "Declined": Color.gray.opacity(0.5)])
                        .frame(height: 160)
                    } header: {
                        Text("Accepted vs declined")
                    } footer: {
                        Text(sum.acceptanceRate.map { String(format: "Acceptance rate: %.0f%%.", $0 * 100) } ?? "Mark offers ✓ or ✕ to see this.")
                    }
                }
            }
            .navigationTitle("Insights")
        }
        .autoReload(model)
    }

    private func count(_ b: Stats.Bucket, _ c: OfferCategory) -> Int {
        switch c {
        case .good: return b.summary.good
        case .fair: return b.summary.fair
        case .bad: return b.summary.bad
        }
    }

    private func peak(_ buckets: [Stats.Bucket], by value: (Stats.Bucket) -> Double) -> Stats.Bucket? {
        guard let best = buckets.max(by: { value($0) < value($1) }), value(best) > 0 else { return nil }
        return best
    }

    /// Line of the average rate per bucket, with your fair (yellow) and good (green) levels drawn across.
    @ViewBuilder
    private func rateChart(title: String, buckets: [Stats.Bucket], unit: Calendar.Component,
                           value: @escaping (Stats.Bucket) -> Double?, fair: Double, good: Double, format: String) -> some View {
        let points = buckets.compactMap { b in value(b).map { (b, $0) } }
        if !points.isEmpty {
            Section {
                Chart {
                    ForEach(points, id: \.0.id) { p in
                        LineMark(x: .value("When", p.0.start, unit: unit), y: .value("Rate", p.1))
                        PointMark(x: .value("When", p.0.start, unit: unit), y: .value("Rate", p.1))
                    }
                    RuleMark(y: .value("Good", good))
                        .foregroundStyle(OfferCategory.good.color)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("good \(String(format: format, good))").font(.caption2).foregroundStyle(OfferCategory.good.color)
                        }
                    RuleMark(y: .value("Fair", fair))
                        .foregroundStyle(OfferCategory.fair.color)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .bottom, alignment: .leading) {
                            Text("fair \(String(format: format, fair))").font(.caption2).foregroundStyle(OfferCategory.fair.color)
                        }
                }
                .frame(height: 180)
            } header: {
                Text("\(title) by \(model.period.bucketName)")
            } footer: {
                let above = points.filter { $0.1 >= good }.count
                Text("\(above) of \(points.count) \(model.period.bucketName)\(points.count == 1 ? "" : "s") with orders were at or above your good level.")
            }
        }
    }
}


/// Miles from the target, 0 to 5+ mi: how many offers fell in each range, what they paid per mile, and how many
/// you took. 🛍 = store from the nearest pickup in your route, 🏠 = customer from your last stop.
/// Dashed lines show your Close by and On the way radii (Home settings), so they move when you change them.
struct DetourCharts: View {
    let records: [OfferRecord]
    let settings: DriverSettings

    static let pickupColor = Color.orange, dropoffColor = Color.blue
    static func color(_ k: DetourStats.Kind) -> Color { k == .pickup ? pickupColor : dropoffColor }

    var body: some View {
        let pickup = DetourStats.buckets(records, kind: .pickup)
        let dropoff = DetourStats.buckets(records, kind: .dropoff)
        let all = pickup + dropoff
        let counted = all.map(\.offers).reduce(0, +)

        Section {
            if counted == 0 {
                Text("No distance data for this period yet. Offers graded from version 5.9.6 on are counted here.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(all) { b in
                        // Side-by-side bars inside each 1-mile range: 🛍 left half, 🏠 right half.
                        let left = Double(b.index) + (b.kind == .pickup ? 0.08 : 0.5)
                        BarMark(xStart: .value("From", left), xEnd: .value("To", left + 0.42),
                                y: .value("Offers", b.offers))
                            .foregroundStyle(by: .value("Check", b.kind.rawValue))
                    }
                    limitLines
                }
                .modifier(DetourAxis())
                .frame(height: 200)
            }
        } header: {
            Text("Offers by distance from target")
        } footer: {
            if counted > 0 { Text("🛍 store from the nearest pickup in your route · 🏠 customer from your last stop. Short dashes = Close by, long dashes = On the way.") }
        }

        if counted > 0 {
            Section {
                Chart {
                    ForEach(all.filter { $0.avgPerMile != nil }) { b in
                        LineMark(x: .value("Detour", Double(b.index) + 0.5), y: .value("$/mi", b.avgPerMile ?? 0))
                            .foregroundStyle(by: .value("Check", b.kind.rawValue))
                        PointMark(x: .value("Detour", Double(b.index) + 0.5), y: .value("$/mi", b.avgPerMile ?? 0))
                            .foregroundStyle(by: .value("Check", b.kind.rawValue))
                    }
                    RuleMark(y: .value("Good", settings.perMileGood))
                        .foregroundStyle(OfferCategory.good.color)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text(String(format: "good $%.2f", settings.perMileGood)).font(.caption2).foregroundStyle(OfferCategory.good.color)
                        }
                    RuleMark(y: .value("Fair", settings.perMileFair))
                        .foregroundStyle(OfferCategory.fair.color)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .bottom, alignment: .trailing) {
                            Text(String(format: "fair $%.2f", settings.perMileFair)).font(.caption2).foregroundStyle(OfferCategory.fair.color)
                        }
                    limitLines
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "$%.2f", d)) } }
                    }
                }
                .modifier(DetourAxis())
                .frame(height: 190)
            } header: {
                Text("Pay per mile by distance from target")
            } footer: {
                Text("Green and yellow lines are your good and fair $/mi.")
            }

            Section("Accepted by distance from target") {
                Chart {
                    ForEach(all.filter { $0.offers > 0 }) { b in
                        let left = Double(b.index) + (b.kind == .pickup ? 0.08 : 0.5)
                        BarMark(xStart: .value("From", left), xEnd: .value("To", left + 0.42),
                                y: .value("Accepted %", b.acceptedPct ?? 0))
                            .foregroundStyle(by: .value("Check", b.kind.rawValue))
                    }
                    limitLines
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } }
                    }
                }
                .modifier(DetourAxis())
                .frame(height: 180)
            }

            let lines = DetourStats.insights(records, settings: settings)
            if !lines.isEmpty {
                Section("Distance takeaways") {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "arrow.triangle.branch").font(.subheadline)
                    }
                }
            }
        }
    }

    /// Dashed vertical lines at your radii: short dashes = Close by ✅, long dashes = On the way ⚠️.
    private var radiusLines: [(kind: DetourStats.Kind, onTheWay: Bool, miles: Double)] {
        DetourStats.Kind.allCases.flatMap { k -> [(kind: DetourStats.Kind, onTheWay: Bool, miles: Double)] in
            let r = DetourStats.radii(k, settings)
            return [(kind: k, onTheWay: false, miles: r.closeBy), (kind: k, onTheWay: true, miles: r.onTheWay)]
        }
    }

    @ChartContentBuilder
    private var limitLines: some ChartContent {
        ForEach(Array(radiusLines.enumerated()), id: \.offset) { _, line in
            RuleMark(x: .value("Radius", min(line.miles, 6)))
                .foregroundStyle(Self.color(line.kind))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: line.onTheWay ? [6, 3] : [2, 2]))
                .annotation(position: line.kind == .pickup ? .top : .bottom, alignment: .center, spacing: 2) {
                    Text((line.kind == .pickup ? "🛍" : "🏠") + (line.onTheWay ? "⚠️" : "✅") + String(format: "%.1f", line.miles))
                        .font(.caption2.weight(.semibold)).foregroundStyle(Self.color(line.kind))
                }
        }
    }
}

/// Shared 0 to 5+ mi x-axis for the detour charts.
private struct DetourAxis: ViewModifier {
    func body(content: Content) -> some View {
        content
            .chartXScale(domain: 0...6)
            .chartXAxis {
                AxisMarks(values: [0, 1, 2, 3, 4, 5]) { v in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text(d >= 5 ? "5+" : "\(Int(d))") }
                    }
                }
            }
            .chartXAxisLabel("miles from target")
            .chartForegroundStyleScale([DetourStats.Kind.pickup.rawValue: DetourCharts.pickupColor,
                                        DetourStats.Kind.dropoff.rawValue: DetourCharts.dropoffColor])
    }
}
