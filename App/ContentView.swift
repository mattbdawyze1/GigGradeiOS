import SwiftUI
import ReplayKit
import GigCore

struct ContentView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }.tag(0)
            OffersView()
                .tabItem { Label("Offers", systemImage: "list.bullet.rectangle") }.tag(1)
            EarningsView()
                .tabItem { Label("Earnings", systemImage: "dollarsign.circle") }.tag(2)
            InsightsView()
                .tabItem { Label("Insights", systemImage: "chart.bar.xaxis") }.tag(3)
            RouteView()
                .tabItem { Label("Route", systemImage: "map") }.tag(4)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openOffers)) { _ in tab = 1 }
    }
}

struct HomeView: View {
    @State private var s = SharedStore.shared.settings
    @StateObject private var today = LogModel(period: .day)
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            Form {
                // GigGrade ………… recording timer
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text("GigGrade").font(.largeTitle.weight(.bold))
                        Spacer()
                        BroadcastTimer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                }

                Section("Today's offers") {
                    let sum = Stats.summary(today.records, costPerMile: s.costPerMile)
                    HStack(spacing: 10) {
                        countTile(.good, sum.good)
                        countTile(.fair, sum.fair)
                        countTile(.bad, sum.bad)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }

                Section {
                    RangeRow(title: "$ per hour", low: $s.hourlyFair, high: $s.hourlyGood,
                             bounds: 5...60, step: 1, format: "$%.0f")
                    RangeRow(title: "$ per mile", low: $s.perMileFair, high: $s.perMileGood,
                             bounds: 0.25...4, step: 0.05, format: "$%.2f")
                    numberRow("Your cost per mile (gas + wear)", $s.costPerMile)
                } header: {
                    Text("Your targets")
                } footer: {
                    Text("Green only if both rates are good; red if either is bad; otherwise yellow.")
                }

                Section {
                    numberRow("Max extra miles to add an order", $s.maxDetourMi)
                    numberRow("OK if it ends within (mi) of final stop", $s.onTheWayRadiusMi)
                } header: {
                    Text("Stacking another offer")
                } footer: {
                    Text("When you already have stops on your route, new offers from any app are checked against it.")
                }

                Section {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Banner content and sounds", systemImage: "bell.badge")
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        BroadcastPicker().frame(width: 72, height: 72)
                        Spacer()
                    }
                    Button("Test with a sample offer") { testSample() }
                } header: {
                    Text("Start reading offers")
                } footer: {
                    Text("Tap the record button → pick “GigGrade Offer Reader” → Start Broadcast. Then open your gig app. Grades arrive as banners; pull a banner down to mark Accepted or Declined.")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { typing = false }.fontWeight(.semibold)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: s) { _, newValue in SharedStore.shared.settings = newValue }
        }
        .autoReload(today)
    }

    private func countTile(_ c: OfferCategory, _ n: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.title2.weight(.bold)).monospacedDigit()
            Text(c.label).font(.caption.weight(.medium))
        }
        .foregroundStyle(c == .fair ? Color.black.opacity(0.8) : Color.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(c.color))
    }

    private func numberRow(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .focused($typing)
        }
    }

    private func testSample() {
        OfferPipeline.shared.reset()
        OfferPipeline.shared.handle(text: """
        DoorDash
        $9.75
        Guaranteed (incl. tips)
        28 min  6.4 mi total
        Pickup
        Chipotle
        Customer dropoff
        Deliver by 7:45 PM
        Decline   Accept
        """, immediate: true)
        NotificationCenter.default.post(name: .logChanged, object: nil)
    }
}

/// Apple's system "start broadcast" button, pre-set to our screen-reader extension.
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        v.preferredExtension = (Bundle.main.bundleIdentifier ?? "com.giggrade.app") + ".broadcast"
        v.showsMicrophoneButton = false
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// Choose what the offer banner shows and which sound plays for good / fair / bad.
struct NotificationSettingsView: View {
    @State private var p = SharedStore.shared.notificationPrefs
    private let settings = SharedStore.shared.settings

    var body: some View {
        Form {
            Section("Preview") {
                let o = Offer(app: .doordash, pay: 9.75, miles: 6.4, minutes: 28, pickupText: nil, dropoffText: nil, rawText: "")
                let sc = OfferScorer.score(o, settings)
                VStack(alignment: .leading, spacing: 4) {
                    Text(OfferAlert.title(o, sc, p)).font(.subheadline.weight(.semibold))
                    Text(OfferAlert.body(o, sc, settings, p, TripPlanner.OnTheWay(verdict: .onTheWay, addedMiles: 0.8, stackedPerMile: 12.19)))
                        .font(.footnote)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.12)))
            }

            Section("Banner title") {
                Toggle("Color (Good / Fair / Bad)", isOn: $p.showCategory)
                Toggle("Letter grade", isOn: $p.showGrade)
                Toggle("App name", isOn: $p.showAppName)
                Toggle("Pay", isOn: $p.showPay)
            }
            Section("Banner details") {
                Toggle("$ per hour", isOn: $p.showHourly)
                Toggle("$ per mile", isOn: $p.showPerMile)
                Toggle("% of your target", isOn: $p.showPctOfTarget)
                Toggle("Miles and minutes", isOn: $p.showMilesMinutes)
                Toggle("Pay after costs", isOn: $p.showNet)
                Toggle("On-the-way check", isOn: $p.showOnTheWay)
            }
            Section {
                soundRow("Good offers", .good, $p.goodSound)
                soundRow("Fair offers", .fair, $p.fairSound)
                soundRow("Bad offers", .bad, $p.badSound)
            } header: {
                Text("Sounds")
            } footer: {
                Text("Sounds follow your ringer switch and Focus settings. Tap ▶︎ to hear one.")
            }
        }
        .navigationTitle("Banner and sounds")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: p) { _, newValue in SharedStore.shared.notificationPrefs = newValue }
    }

    private func soundRow(_ title: String, _ c: OfferCategory, _ value: Binding<SoundChoice>) -> some View {
        HStack {
            Circle().fill(c.color).frame(width: 10, height: 10)
            Picker(title, selection: value) {
                ForEach(SoundChoice.allCases) { Text($0.label).tag($0) }
            }
            Button { SoundPreview.play(value.wrappedValue) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
        }
    }
}
