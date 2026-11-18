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
