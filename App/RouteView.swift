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
    }

    func clear() { store.stops = []; reload(force: true) }

    func add(query: String, type: StopType) async -> String? {
        guard stops.count < TripPlanner.maxStops else { return "Max \(TripPlanner.maxStops) stops — finish one first." }
        guard let loc = await PlaceFinder.find(query, near: store.currentLocation) else { return "Couldn't find “\(query)”." }
        var planner = TripPlanner(stops: store.stops)
        planner.add(Stop(type: type, label: query, location: loc, orderId: UUID().uuidString))
        store.stops = planner.stops
        reload(force: true)
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

    /// Whole route in Google Maps (supports multiple stops); falls back to Apple Maps.
    func navigate() {
        guard let last = stops.last else { return }
        let ll = { (c: Coord) in "\(c.lat),\(c.lng)" }
        let waypoints = stops.dropLast().map { ll($0.location) }.joined(separator: "|")
        var comps = URLComponents(string: "https://www.google.com/maps/dir/")!
        comps.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "travelmode", value: "driving"),
            URLQueryItem(name: "destination", value: ll(last.location)),
        ] + (waypoints.isEmpty ? [] : [URLQueryItem(name: "waypoints", value: waypoints)])
        if let url = comps.url { UIApplication.shared.open(url) }
    }
}

struct RouteView: View {
    @StateObject private var model = RouteModel()
    @State private var camera: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var message: String?
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
                        Text(model.summary).font(.subheadline)
                        ForEach(Array(model.stops.enumerated()), id: \.element.id) { i, s in
                            HStack {
                                Image(systemName: s.type == .pickup ? "bag.fill" : "house.fill")
                                    .foregroundStyle(s.type == .pickup ? .blue : .green)
                                Text("\(i + 1). \(s.label)").lineLimit(1)
                                Spacer()
                                Button("Done") { model.complete(s) }.buttonStyle(.bordered)
                            }
                        }
                    }
                    Section("Add a stop by hand") {
                        TextField("Address or place name", text: $query)
                        HStack {
                            Button("Add pickup") { add(.pickup) }
                            Spacer()
                            Button("Add dropoff") { add(.dropoff) }
                        }
                        if let message { Text(message).foregroundStyle(.red).font(.footnote) }
                    }
                }
                .frame(height: 320)
            }
            .navigationTitle("Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Clear") { model.clear() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Navigate") { model.navigate() } }
            }
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
        Task {
            message = await model.add(query: q, type: type)
            if message == nil { query = "" }
        }
    }
}
