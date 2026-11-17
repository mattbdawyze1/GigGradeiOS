import SwiftUI
import ReplayKit
import GigCore

struct ContentView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            OffersView()
                .tabItem { Label("Offers", systemImage: "dollarsign.circle") }
                .tag(0)
            RouteView()
                .tabItem { Label("Route", systemImage: "map") }
                .tag(1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMap)) { _ in tab = 1 }
    }
}

struct OffersView: View {
    @State private var s = SharedStore.shared.settings

    var body: some View {
        NavigationStack {
            Form {
                Section("Your targets") {
                    numberRow("Target $ per hour", $s.targetHourly)
                    numberRow("Target $ per mile", $s.targetPerMile)
                    numberRow("Your cost per mile (gas + wear)", $s.costPerMile)
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
                    HStack {
                        Spacer()
                        BroadcastPicker().frame(width: 72, height: 72)
                        Spacer()
                    }
                    Button("Test with a sample offer") { testSample() }
                } header: {
                    Text("Start reading offers")
                } footer: {
                    Text("Tap the record button → pick “GigGrade Offer Reader” → Start Broadcast. Then open your gig app. Grades arrive as banners; pull a banner down for “Add to route”. Stop anytime from the red indicator at the top of the screen.")
                }
            }
            .navigationTitle("GigGrade")
            .onChange(of: s) { _, newValue in SharedStore.shared.settings = newValue }
        }
    }

    private func numberRow(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
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
        """)
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
