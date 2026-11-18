import SwiftUI
import MapKit
import GigCore

/// Your current route: you -> up to 4 pickups/dropoffs, drawn on real roads with Apple Maps.
@MainActor
final class RouteModel: ObservableObject {
    @Published var stops: [Stop] = []
    @Published var me: Coord?
    @Published var legs: [MKPolyline] = []
    @Published var summary = ""

    private let store = SharedStore.shared

    func reload(force: Bool = false) {
        me = store.currentLocation
        let latest = store.stops
        guard force || latest != stops else { return }
        stops = latest
        Task { await buildRoad() }
    }

    func complete(_ s: Stop) {
        var planner = TripPlanner(stops: store.stops)
        planner.remove(id: s.id)
        store.stops = planner.stops
        reload(force: true)
        Task { await Cloud.shared.schedulePushState() }
    }

    /// Drag-to-reorder. Returns a message if the move isn't allowed.
    func move(from: IndexSet, to: Int) -> String? {
        var newOrder = stops
        newOrder.move(fromOffsets: from, toOffset: to)
        var planner = TripPlanner(stops: store.stops)
        guard planner.reorder(newOrder) else {
            return "A dropoff can't come before its pickup."
        }
        store.stops = planner.stops
        reload(force: true)
        Task { await Cloud.shared.schedulePushState() }
        return nil
    }

    func remove(at offsets: IndexSet) {
        let doomed = offsets.filter { $0 < stops.count }.map { stops[$0] }
        for stop in doomed { complete(stop) }
    }

    func clear() {
        store.stops = []
        reload(force: true)
        Task { await Cloud.shared.schedulePushState() }
    }

    func add(label: String, location: Coord, type: StopType) -> String? {
        guard stops.count < TripPlanner.maxStops else { return "Max \(TripPlanner.maxStops) stops — finish one first." }
        var planner = TripPlanner(stops: store.stops)
        planner.add(Stop(type: type, label: label, location: location, orderId: UUID().uuidString))
        store.stops = planner.stops
        reload(force: true)
        Task { await Cloud.shared.schedulePushState() }
        return nil
    }

    func add(query: String, type: StopType) async -> String? {
        guard stops.count < TripPlanner.maxStops else { return "Max \(TripPlanner.maxStops) stops — finish one first." }
        guard let loc = await PlaceFinder.find(query, near: store.currentLocation) else { return "Couldn't find “\(query)”." }
        var planner = TripPlanner(stops: store.stops)
        planner.add(Stop(type: type, label: query, location: loc, orderId: UUID().uuidString))
        store.stops = planner.stops
        reload(force: true)
        Task { await Cloud.shared.schedulePushState() }
        return nil
    }

    private func buildRoad() async {
        let points = [me].compactMap { $0 } + stops.map(\.location)
        guard points.count >= 2 else {
            legs = []
            summary = stops.isEmpty ? "No stops yet." : "\(stops.count)/\(TripPlanner.maxStops) stops"
            return
        }
        var newLegs: [MKPolyline] = []
        var meters = 0.0, seconds = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let req = MKDirections.Request()
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: a.cl))
            req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.cl))
            req.transportType = .automobile
            if let route = try? await MKDirections(request: req).calculate().routes.first {
                newLegs.append(route.polyline)
                meters += route.distance
                seconds += route.expectedTravelTime
            } else {
                meters += Geo.roadMiles(a, b) * 1609.34
            }
        }
        legs = newLegs
        summary = String(format: "%d/%d stops · %.1f mi · %d min driving",
                         stops.count, TripPlanner.maxStops, meters / 1609.34, Int(seconds / 60))
    }

    /// Google Maps takes up to 10 points including your start, so 9 stops per hand-off.
    static let googleMapsMaxStops = 9

    /// Route in Google Maps (first 9 stops if there are more). Returns true if some stops were left out.
    @discardableResult
    func navigate() -> Bool {
        guard !stops.isEmpty else { return false }
        let batch = Array(stops.prefix(Self.googleMapsMaxStops))
        let ll = { (c: Coord) in "\(c.lat),\(c.lng)" }
        let waypoints = batch.dropLast().map { ll($0.location) }.joined(separator: "|")
        var comps = URLComponents(string: "https://www.google.com/maps/dir/")!
        comps.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "travelmode", value: "driving"),
            URLQueryItem(name: "destination", value: ll(batch.last!.location)),
        ] + (waypoints.isEmpty ? [] : [URLQueryItem(name: "waypoints", value: waypoints)])
        if let url = comps.url { UIApplication.shared.open(url) }
        return stops.count > batch.count
    }
}

struct RouteView: View {
    @StateObject private var model = RouteModel()
    @State private var camera: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var message: String?
    @State private var picked: (label: String, coord: Coord)?
    @StateObject private var completer = AddressCompleter()
    @State private var editMode: EditMode = .inactive
    @State private var showBatchNote = false
    @FocusState private var typing: Bool
    @Environment(\.scenePhase) private var scenePhase
    private let tick = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $camera) {
                    if let me = model.me {
                        Annotation("You", coordinate: me.cl) {
                            Image(systemName: "location.circle.fill").font(.title).foregroundStyle(.blue)
                        }
                    }
                    ForEach(Array(model.stops.enumerated()), id: \.element.id) { i, s in
                        Marker("\(i + 1). \(s.type == .pickup ? "Pickup" : "Dropoff")", coordinate: s.location.cl)
                            .tint(s.type == .pickup ? .blue : .green)
                    }
                    ForEach(model.legs, id: \.self) { leg in
                        MapPolyline(leg).stroke(.blue, lineWidth: 6)
                    }
                }
                .frame(maxHeight: .infinity)

                List {
                    Section {
                        ForEach(Array(model.stops.enumerated()), id: \.element.id) { i, s in
                            HStack {
                                Image(systemName: s.type == .pickup ? "bag.fill" : "house.fill")
                                    .foregroundStyle(s.type == .pickup ? .blue : .green)
                                Text("\(i + 1). \(s.label)").lineLimit(1)
                                Spacer()
                                if editMode == .inactive {
                                    Button("Done") { model.complete(s) }.buttonStyle(.bordered)
                                }
                            }
                        }
                        .onMove { from, to in message = model.move(from: from, to: to) }
                        .onDelete { model.remove(at: $0) }
                    } header: {
                        HStack {
                            Text(model.summary)
                            Spacer()
                            if model.stops.count > 1 {
                                Button(editMode == .active ? "Done" : "Reorder") {
                                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                                }
                                .font(.subheadline.weight(.semibold))
                                .textCase(nil)
                            }
                        }
                    } footer: {
                        if editMode == .active {
                            Text("Drag ≡ to change the order. Swipe left to remove a stop. A dropoff can't go before its own pickup.")
                        }
                    }
                    Section {
                        TextField("Start typing an address or place", text: $query)
                            .focused($typing)
                            .textContentType(.fullStreetAddress)
                            .autocorrectionDisabled()
                            .onChange(of: query) { _, q in
                                if let picked, picked.label == q { return } // just filled in from a suggestion
                                picked = nil
                                completer.update(query: q, near: SharedStore.shared.currentLocation)
                            }
                        if picked == nil {
                            ForEach(completer.results, id: \.self) { item in
                                Button {
                                    choose(item)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).foregroundStyle(.primary)
                                        if !item.subtitle.isEmpty {
                                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        } else {
                            Label("Location found — choose pickup or dropoff", systemImage: "checkmark.circle.fill")
                                .font(.footnote).foregroundStyle(.green)
                        }
                        HStack(spacing: 12) {
                            Button { add(.pickup) } label: {
                                Label("Add pickup", systemImage: "bag").frame(maxWidth: .infinity)
                            }
                            Button { add(.dropoff) } label: {
                                Label("Add dropoff", systemImage: "house").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered) // separate tap areas: one tap = one stop
                        if let message { Text(message).foregroundStyle(.red).font(.footnote) }
                    } header: {
                        Text("Add a stop by hand")
                    } footer: {
                        Text("Suggestions are based on what you type and where you are.")
                    }
                }
                .environment(\.editMode, $editMode)
                .frame(height: 380)
            }
            .navigationTitle("Route")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { typing = false }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Clear") { model.clear() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Navigate") { showBatchNote = model.navigate() }
                }
            }
        }
        .alert("First 9 stops sent", isPresented: $showBatchNote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Google Maps takes up to 9 stops at a time. After you finish a few, tap Navigate again for the rest.")
        }
        .onAppear { model.reload(force: true) }
        .onReceive(tick) { _ in model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: .routeChanged)) { _ in model.reload(force: true) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.reload(force: true) } }
        .onChange(of: model.stops) { _, _ in camera = .automatic }
    }

    private func add(_ type: StopType) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        typing = false
        if let picked {
            message = model.add(label: picked.label, location: picked.coord, type: type)
            if message == nil { reset() }
            return
        }
        Task {
            message = await model.add(query: q, type: type)
            if message == nil { reset() }
        }
    }

    private func choose(_ item: MKLocalSearchCompletion) {
        Task {
            if let found = await completer.resolve(item) {
                picked = found
                query = found.label
                message = nil
            } else {
                message = "Couldn't find that place. Try another suggestion."
            }
        }
    }

    private func reset() {
        query = ""
        picked = nil
        completer.results = []
    }
}

/// Live address suggestions while typing, biased toward your current location.
@MainActor
final class AddressCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, near: Coord?) {
        if let near {
            completer.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 40_000, longitudinalMeters: 40_000)
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.count < 3 {
            completer.cancel()
            results = []
        } else {
            completer.queryFragment = q
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let found = Array(completer.results.prefix(6))
        Task { @MainActor in self.results = found }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {}

    /// Turns a tapped suggestion into an exact map location.
    func resolve(_ item: MKLocalSearchCompletion) async -> (label: String, coord: Coord)? {
        let request = MKLocalSearch.Request(completion: item)
        guard let mapItem = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let label = item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)"
        return (label, Coord(mapItem.placemark.coordinate))
    }
}
