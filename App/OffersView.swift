import SwiftUI
import MapKit
import GigCore

/// Every offer GigGrade saw, organized by day / week / month / quarter / year,
/// color coded, with the app it came from, a saved screenshot, and Accepted / Declined buttons.
struct OffersView: View {
    @StateObject private var model = LogModel(period: .day)
    @State private var selected: OfferRecord?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PeriodHeader(model: model)
                    let sum = Stats.summary(model.records, costPerMile: model.settings.costPerMile)
                    HStack(spacing: 14) {
                        tally(.good, sum.good)
                        tally(.fair, sum.fair)
                        tally(.bad, sum.bad)
                        Spacer()
                        Text("\(sum.accepted) accepted · \(sum.declined) declined")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if model.records.isEmpty {
                    Section {
                        Text("No offers logged for this \(model.period.label.lowercased()). Start the screen reader on Home and they'll appear here automatically, or tap Add order to log one by hand.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }

                ForEach(model.days) { day in
                    Section(day.title) {
                        ForEach(day.records) { r in
                            OfferRow(record: r, model: model, onOpen: { selected = r })
                                .swipeActions {
                                    Button(role: .destructive) { model.delete(r) } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Offers")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { adding = true } label: {
                        Label("Add order", systemImage: "plus.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    NavigationLink {
                        MissedOffersView()
                    } label: {
                        Label("Missed", systemImage: "exclamationmark.bubble")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                    }
                }
            }
            .sheet(isPresented: $adding) {
                AddOfferView(day: model.period == .day ? model.anchor : Date())
            }
            .sheet(item: $selected) { r in
                OfferDetailView(recordId: r.id, model: model)
            }
        }
        .autoReload(model)
    }

    private func tally(_ c: OfferCategory, _ n: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c.color).frame(width: 10, height: 10)
            Text("\(n)").font(.subheadline.weight(.semibold)).monospacedDigit()
        }
    }
}

struct OfferRow: View {
    let record: OfferRecord
    @ObservedObject var model: LogModel
    let onOpen: () -> Void
    @ObservedObject private var guide = GuideSession.shared
    @State private var working = false
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(record.category.color).frame(width: 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    AppBadge(app: record.app)
                    Text(record.category.label).font(.caption.weight(.semibold)).foregroundStyle(record.category.color)
                    Text(record.grade).font(.caption.weight(.semibold))
                    Text(record.date, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                Text(line).font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            Spacer(minLength: 4)
            decisionButton(.accepted, icon: "checkmark", tint: OfferCategory.good.color)
            decisionButton(.declined, icon: "xmark", tint: OfferCategory.bad.color)
            if record.app == .uber { readGuideButton }
        }
        .padding(.vertical, 2)
        .listRowBackground(record.category.color.opacity(0.08))
        .alert("👓", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    /// 👓 After you mark the offer accepted: turns on, the screen reader reads Uber's Trip Guide, then GigGrade
    /// adds every stop to your route (linked), notifies you and turns the button off. Tap again to cancel.
    private var readGuideButton: some View {
        let accepted = record.decision == .accepted
        let on = guide.isOn(record)
        return Button {
            working = true
            Task {
                problem = await guide.toggle(record)
                working = false
            }
        } label: {
            ZStack {
                Circle().fill(on ? Color.orange : Color.orange.opacity(accepted ? 0.15 : 0.06))
                if working {
                    ProgressView().tint(on ? .white : .orange)
                } else {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(on ? Color.white : Color.orange.opacity(accepted ? 1 : 0.35))
                        .symbolEffect(.pulse, isActive: on)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.borderless)
        .disabled(working || (!accepted && !on))
        .accessibilityLabel(on ? "Reading Uber's Trip Guide. Tap to cancel" : "Read Uber's Trip Guide into the route")
    }

    private var line: String {
        var parts = [String(format: "$%.2f", record.pay)]
        if let h = record.dollarsPerHour { parts.append(String(format: "$%.0f/hr", h)) }
        if let m = record.dollarsPerMile { parts.append(String(format: "$%.2f/mi", m)) }
        if let mi = record.miles { parts.append(String(format: "%.1f mi", mi)) }
        return parts.joined(separator: " · ")
    }

    private func decisionButton(_ d: Decision, icon: String, tint: Color) -> some View {
        let on = record.decision == d
        return Button { model.setDecision(d, for: record) } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34)
                .foregroundStyle(on ? Color.white : tint)
                .background(Circle().fill(on ? tint : tint.opacity(0.12)))
        }
        .buttonStyle(.borderless) // keeps the two buttons from triggering each other in a list row
        .accessibilityLabel(d == .accepted ? "Mark accepted" : "Mark declined")
    }
}

struct OfferDetailView: View {
    let recordId: UUID
    @ObservedObject var model: LogModel
    @Environment(\.dismiss) private var dismiss
    @State private var zoom = false
    @State private var cloudShot: UIImage?

    private var record: OfferRecord? { model.records.first { $0.id == recordId } }

    var body: some View {
        NavigationStack {
            if let r = record {
                List {
                    if let file = r.screenshotFile, cloudShot == nil,
                       UIImage(contentsOfFile: OfferLog.shared.screenshotURL(file).path) == nil {
                        Section("Screenshot") {
                            HStack { ProgressView(); Text("Loading screenshot…").foregroundStyle(.secondary) }
                                .task {
                                    if let url = await Cloud.shared.downloadScreenshot(file: file) {
                                        cloudShot = UIImage(contentsOfFile: url.path)
                                    }
                                }
                        }
                    }
                    if let file = r.screenshotFile,
                       let img = cloudShot ?? UIImage(contentsOfFile: OfferLog.shared.screenshotURL(file).path) {
                        Section("Screenshot") {
                            Image(uiImage: img)
                                .resizable().scaledToFit()
                                .frame(maxHeight: zoom ? 700 : 360)
                                .frame(maxWidth: .infinity)
                                .onTapGesture { withAnimation { zoom.toggle() } }
                        }
                    }
                    Section {
                        HStack(spacing: 12) {
                            bigButton("Accepted", .accepted, "checkmark.circle.fill", OfferCategory.good.color, r)
                            bigButton("Declined", .declined, "xmark.circle.fill", OfferCategory.bad.color, r)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                    Section("Offer") {
                        row("App", r.app.rawValue)
                        row("Rating", "\(r.category.label) · \(r.grade)", color: r.category.color)
                        row("Time", r.date.formatted(date: .abbreviated, time: .shortened))
                        row("Pay", money(r.pay))
                        row("$ per hour", r.dollarsPerHour.map { String(format: "$%.2f", $0) } ?? "—")
                        row("$ per mile", r.dollarsPerMile.map { String(format: "$%.2f", $0) } ?? "—")
                        row("Miles", r.miles.map { String(format: "%.1f", $0) } ?? "—")
                        row("Minutes", r.minutes.map { "\($0)" } ?? "—")
                        row("After costs", money(r.netPay(costPerMile: model.settings.costPerMile)))
                    }
                    if r.pickupLocation != nil || r.dropoffLocation != nil {
                        Section {
                            Map(initialPosition: .automatic) {
                                if let pl = r.pickupLocation {
                                    Marker("Pickup", systemImage: "bag.fill", coordinate: pl.cl).tint(.blue)
                                }
                                if let dl = r.dropoffLocation {
                                    Marker(r.dropoffEstimated == true ? "Customer (approx.)" : "Dropoff",
                                           systemImage: "person.fill", coordinate: dl.cl).tint(.green)
                                }
                            }
                            .frame(height: 220)
                            .listRowInsets(EdgeInsets())
                        } header: {
                            Text("Map")
                        } footer: {
                            if r.dropoffEstimated == true {
                                Text("The customer pin was worked out from the DoorDash map using your GPS position and the store's address — usually within a few blocks. Compare with the screenshot above.")
                            }
                        }
                    }
                    if r.pickupText != nil || r.dropoffText != nil || r.routeNote != nil {
                        Section("Trip") {
                            if let p = r.pickupText { row("Pickup", p) }
                            if let d = r.dropoffText { row("Dropoff", d) }
                            if let n = r.routeNote { Text(n).font(.footnote) }
                        }
                    }
                    Section {
                        Button("Delete this offer", role: .destructive) { model.delete(r); dismiss() }
                    }
                }
                .navigationTitle("\(r.app.rawValue) \(money(r.pay))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            } else {
                Text("This offer was deleted.").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ k: String, _ v: String, color: Color? = nil) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).foregroundStyle(color ?? .primary).multilineTextAlignment(.trailing)
        }
    }

    private func bigButton(_ title: String, _ d: Decision, _ icon: String, _ tint: Color, _ r: OfferRecord) -> some View {
        let on = r.decision == d
        return Button { model.setDecision(d, for: r) } label: {
            Label(title, systemImage: icon)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(on ? Color.white : tint)
                .background(RoundedRectangle(cornerRadius: 12).fill(on ? tint : tint.opacity(0.12)))
        }
        .buttonStyle(.borderless)
    }
}
