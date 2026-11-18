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
                    numberRow("On the way if it ends within (mi) of your final stop", $s.onTheWayRadiusMi)
                    numberRow("Close by if it adds no more than (mi)", $s.maxDetourMi)
                } header: {
                    Text("Stacking another offer")
                } footer: {
                    Text("ON THE WAY: ends near your final stop (or near you when your route is empty). CLOSE BY: only a small detour. Otherwise OFF ROUTE.")
                }

                Section {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Banner content and sounds", systemImage: "bell.badge")
                    }
                }

                Section {
                    ConnectionStatus()
                } header: {
                    Text("Connection to screen reader")
                } footer: {
                    Text("The screen reader gets your targets and banner settings, and sends offers to the Offers tab, through shared storage or cloud sync. Either one is enough.")
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
            .onChange(of: s) { _, newValue in
                SharedStore.shared.settings = newValue
                Task { await Cloud.shared.schedulePushState() } // so the screen reader uses your targets
            }
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

/// Arrange what the offer banner shows on each line, and which sound plays for good / fair / bad.
struct NotificationSettingsView: View {
    @State private var p = SharedStore.shared.notificationPrefs
    @State private var layout = SharedStore.shared.notificationPrefs.effectiveLayout
    private let settings = SharedStore.shared.settings

    private var sample: (title: String, subtitle: String, body: String) {
        var prefs = p
        prefs.layout = layout
        let o = Offer(app: .uber, pay: 10.06, miles: 9.0, minutes: 33, pickupText: nil, dropoffText: nil, rawText: "")
        return OfferAlert.content(o, OfferScorer.score(o, settings), settings, prefs,
                                  TripPlanner.OnTheWay(verdict: .nearFinal, addedMiles: 3.1, dropoffToFinalMi: 1.3),
                                  dropoff: DropoffInfo(place: "Smithtown Byp, Smithtown", estimated: false, milesFromYou: 6.2))
    }

    var body: some View {
        Form {
            Section {
                bannerPreview(collapsed: true)
                bannerPreview(collapsed: false)
            } header: {
                Text("Preview")
            } footer: {
                Text("Top: how the banner pops up (iOS cuts it off after a few lines). Bottom: pulled down.")
            }

            Section {
                ForEach(layout.fullOrder) { item in
                    Picker(item.label, selection: Binding(
                        get: { layout.slot(item) },
                        set: { layout.set(item, $0) }
                    )) {
                        ForEach(BannerSlot.allCases) { Text($0.label).tag($0) }
                    }
                }
                NavigationLink("Change the order within a line") { BannerOrderView(layout: $layout) }
                Toggle("Add % of your target to $/hr and $/mi", isOn: $p.showPctOfTarget)
                Button("Reset to standard layout") { layout = .standard }
            } header: {
                Text("Arrange the banner")
            } footer: {
                Text("Items on the same line appear side by side, separated by “ · ”. Keep the most important ones on lines 1–2 so they're never cut off.")
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
        .onChange(of: layout) { _, _ in save() }
        .onChange(of: p) { _, _ in save() }
    }

    private func save() {
        var prefs = p
        prefs.layout = layout
        SharedStore.shared.notificationPrefs = prefs
        Task { await Cloud.shared.schedulePushState() } // so real-offer banners follow your layout
    }

    /// Looks like an iOS banner; collapsed shows ~4 lines like iOS does.
    private func bannerPreview(collapsed: Bool) -> some View {
        let t = sample
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 7).fill(Color.green.opacity(0.8)).frame(width: 30, height: 30)
                .overlay(Text("A+").font(.caption2.weight(.bold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !t.subtitle.isEmpty {
                    Text(t.subtitle).font(.subheadline.weight(.semibold)).lineLimit(collapsed ? 1 : nil)
                }
                if !t.body.isEmpty {
                    Text(t.body).font(.subheadline).lineLimit(collapsed ? (t.subtitle.isEmpty ? 3 : 2) : nil)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.secondary.opacity(0.15)))
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

/// Drag items to set their order within each line.
struct BannerOrderView: View {
    @Binding var layout: BannerLayout

    var body: some View {
        List {
            Section {
                ForEach(layout.fullOrder) { item in
                    HStack {
                        Text(item.label)
                        Spacer()
                        Text(layout.slot(item).label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onMove { from, to in
                    var o = layout.fullOrder
                    o.move(fromOffsets: from, toOffset: to)
                    layout.order = o
                }
            } footer: {
                Text("Drag the handles. Items show left-to-right in this order on whichever line they're on.")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Order")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shows whether the app and the screen reader can share data, and when the reader last checked in.
struct ConnectionStatus: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { ctx in
            let store = SharedStore.shared
            VStack(alignment: .leading, spacing: 6) {
                if SharedStore.sharedStorageAvailable {
                    Label("Shared storage ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Shared storage not available", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(Cloud.isConfigured
                         ? "No problem — cloud sync (Supabase) passes your settings and offers between the app and the screen reader."
                         : "iOS didn't give this install an App Group. Set up cloud sync (Supabase) or install through TestFlight.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let beat = store.broadcastHeartbeat {
                    let ago = Int(ctx.date.timeIntervalSince(beat))
                    if ago < 20 {
                        Label("Screen reader connected (checked in \(ago)s ago)", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                    } else {
                        Label("Screen reader last seen \(beat.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Screen reader not seen yet — start a broadcast to test", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                let cloud = Cloud.status()
                Label(cloud.message, systemImage: cloud.ok ? "icloud.fill" : "icloud.slash")
                    .foregroundStyle(cloud.ok ? Color.green : (Cloud.isConfigured ? Color.orange : Color.secondary))
                    .textSelection(.enabled)
                if let at = cloud.at {
                    Text("Last cloud check \(at.formatted(date: .omitted, time: .standard)) · \(Cloud.projectHost)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(SharedStore.appGroup).font(.caption2).foregroundStyle(.tertiary)
            }
            .font(.subheadline)
        }
    }
}
