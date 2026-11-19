import SwiftUI
import GigCore

/// Manually log an order the screen reader didn't catch (or one taken with the reader off).
/// It's graded against your targets like any other offer and counts toward Earnings and Insights.
struct AddOfferView: View {
    @Environment(\.dismiss) private var dismiss

    private static let apps: [GigApp] = [.doordash, .uber, .grubhub, .instacart, .spark, .lyft, .amazonFlex]

    @State private var app: GigApp = .doordash
    @State private var pay = ""
    @State private var miles = ""
    @State private var minutes = ""
    @State private var date: Date
    @State private var pickup = ""
    @State private var dropoff = ""
    @State private var decision: Decision = .accepted
    @FocusState private var focused: Bool

    /// `day` is the day being viewed in the Offers tab; today uses the current time.
    init(day: Date = Date()) {
        let cal = Calendar.current
        if cal.isDateInToday(day) {
            _date = State(initialValue: Date())
        } else {
            _date = State(initialValue: cal.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day)
        }
    }

    private func number(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces))
    }
    private var payValue: Double? { number(pay).flatMap { $0 > 0 ? $0 : nil } }
    private var milesValue: Double? { number(miles).flatMap { $0 > 0 ? $0 : nil } }
    private var minutesValue: Int? { number(minutes).flatMap { $0 > 0 ? Int($0.rounded()) : nil } }
    private func text(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var offer: Offer? {
        guard let p = payValue else { return nil }
        return Offer(app: app, pay: p, miles: milesValue, minutes: minutesValue,
                     pickupText: text(pickup), dropoffText: text(dropoff), rawText: "Added by hand")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Order") {
                    Picker("App", selection: $app) {
                        ForEach(Self.apps, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    field("Pay ($)", $pay, .decimalPad)
                    field("Miles", $miles, .decimalPad)
                    field("Minutes", $minutes, .numberPad)
                    DatePicker("When", selection: $date, in: ...Date())
                }

                Section {
                    Picker("Decision", selection: $decision) {
                        Text("Accepted").tag(Decision.accepted)
                        Text("Declined").tag(Decision.declined)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Accepted orders count toward Earnings and Insights.")
                }

                Section("Places (optional)") {
                    TextField("Pickup", text: $pickup).focused($focused)
                    TextField("Dropoff", text: $dropoff).focused($focused)
                }

                Section("Grade") {
                    if let o = offer {
                        let s = OfferScorer.score(o, SharedStore.shared.settings)
                        HStack(spacing: 10) {
                            Circle().fill(s.category.color).frame(width: 12, height: 12)
                            Text(s.grade).font(.headline)
                            Text(s.category.label).foregroundStyle(s.category.color)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if let h = s.dollarsPerHour { Text("\(money(h))/hr").monospacedDigit() }
                                if let m = s.dollarsPerMile { Text("\(money(m))/mi").monospacedDigit() }
                            }
                            .font(.subheadline)
                        }
                    } else {
                        Text("Enter the pay to see the grade.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add an order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(offer == nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
        }
    }

    private func field(_ title: String, _ value: Binding<String>, _ kb: UIKeyboardType) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("—", text: value)
                .keyboardType(kb)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140)
                .focused($focused)
        }
    }

    private func save() {
        guard let o = offer else { return }
        let s = OfferScorer.score(o, SharedStore.shared.settings)
        let record = OfferRecord(date: date, app: o.app, pay: o.pay, miles: o.miles, minutes: o.minutes,
                                 pickupText: o.pickupText, dropoffText: o.dropoffText, grade: s.grade,
                                 category: s.category, dollarsPerHour: s.dollarsPerHour,
                                 dollarsPerMile: s.dollarsPerMile, routeNote: "Added by hand",
                                 decision: decision, updatedAt: Date())
        OfferLog.shared.append(record)
        let dayKey = OfferLog.dayKey(record.date)
        let chosen = decision
        Task {
            await Cloud.shared.queueOffer(id: record.id, dayKey: dayKey)
            await Cloud.shared.queueDecision(chosen, id: record.id)
        }
        NotificationCenter.default.post(name: .logChanged, object: nil)
        dismiss()
    }
}
