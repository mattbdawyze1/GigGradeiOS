import SwiftUI
import GigCore

/// Income, average hourly rate and average mileage rate from offers marked Accepted.
struct EarningsView: View {
    @StateObject private var model = LogModel(period: .week)

    var body: some View {
        NavigationStack {
            List {
                Section { PeriodHeader(model: model) }

                let cost = model.settings.costPerMile
                let sum = Stats.summary(model.records, costPerMile: cost)
                let prev = Stats.summary(model.previous, costPerMile: cost)

                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        MetricCard(title: "Income", value: money(sum.income), detail: change(sum.income, prev.income))
                        MetricCard(title: "Orders accepted", value: "\(sum.accepted)",
                                   detail: sum.offers > 0 ? "of \(sum.offers) offers seen" : nil)
                        MetricCard(title: "Avg hourly rate", value: sum.avgHourly.map { String(format: "$%.2f/hr", $0) } ?? "—",
                                   detail: rateDetail(sum.avgHourly, fair: model.settings.hourlyFair, good: model.settings.hourlyGood))
                        MetricCard(title: "Avg mileage rate", value: sum.avgPerMile.map { String(format: "$%.2f/mi", $0) } ?? "—",
                                   detail: rateDetail(sum.avgPerMile, fair: model.settings.perMileFair, good: model.settings.perMileGood))
                        MetricCard(title: "Miles", value: String(format: "%.1f", sum.miles),
                                   detail: String(format: "%.1f hrs on orders", sum.hours))
                        MetricCard(title: "After costs", value: money(sum.net),
                                   detail: String(format: "at $%.2f/mi", cost))
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    .listRowBackground(Color.clear)
                }

                let apps = Stats.byApp(model.records, costPerMile: cost).filter { $0.summary.accepted > 0 }
                if !apps.isEmpty {
                    Section("By app") {
                        ForEach(apps) { a in
                            HStack {
                                AppBadge(app: a.app)
                                Text("\(a.summary.accepted) order\(a.summary.accepted == 1 ? "" : "s")")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(money(a.summary.income)).font(.subheadline.weight(.semibold))
                                    Text([a.summary.avgHourly.map { String(format: "$%.0f/hr", $0) },
                                          a.summary.avgPerMile.map { String(format: "$%.2f/mi", $0) }]
                                        .compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("Earnings count only offers you marked Accepted (✓) on the Offers tab or banner. Hourly rate uses each offer's estimated time; pay is the offer amount shown when it arrived.")
                }
            }
            .navigationTitle("Earnings")
        }
        .autoReload(model)
    }

    private func change(_ now: Double, _ before: Double) -> String? {
        guard before > 0 else { return nil }
        let pct = (now - before) / before * 100
        return "\(pct >= 0 ? "+" : "−")\(String(format: "%.0f", abs(pct)))% vs \(model.period.previousName)"
    }

    private func rateDetail(_ v: Double?, fair: Double, good: Double) -> String? {
        guard let v else { return nil }
        if v >= good { return "🟢 at or above your good level" }
        if v >= fair { return "🟡 between fair and good" }
        return "🔴 below your fair level"
    }
}
