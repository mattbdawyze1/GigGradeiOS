import SwiftUI
import MapKit
import GigCore

/// Your current route: you -> up to 9 pickups/dropoffs, drawn on real roads with Apple Maps.
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

    // MARK: Optimize (fastest order, pickups before their linked dropoffs)

    @Published var optimizing = false
    @Published var undoOrder: [Stop]?

    func optimize() async -> String {
        let current = store.stops
        guard current.count >= 2 else { return "Add at least 2 stops to optimize." }
        optimizing = true
        defer { optimizing = false }
        let times = await TravelTimes.matrix(start: store.currentLocation, points: current.map(\.location))
        guard let r = RouteOptimizer.optimize(stops: current, cost: times.cost, fromStart: times.fromStart,
                                              keepIfWithin: 30) else {
            return "Couldn't optimize this route."
        }
        let minutes = Int((r.improvement / 60).rounded())
        if r.order == Array(current.indices) {
            return "Already the fastest order (≈ \(Int((r.cost / 60).rounded())) min driving)."
        }
        guard store.stops == current else { return "The route changed while optimizing. Tap Optimize again." }
        var planner = TripPlanner(stops: current)
        guard planner.reorder(r.order.map { current[$0] }) else { return "Couldn't optimize this route." }
        undoOrder = current
        store.stops = planner.stops
        reload(force: true)
        Task { await Cloud.shared.schedulePushState() }
        let saved = minutes >= 1 ? "saves about \(minutes) min" : "saves under a minute"
        return "Optimized: \(saved) (≈ \(Int((r.cost / 60).rounded())) min driving)."
    }

    func undoOptimize() {
        guard let old = undoOrder else { return }
        undoOrder = nil
        var planner = TripPlanner(stops: store.stops)
        // Only if the same stops are still there (none finished or added since).
        guard planner.reorder(old.compactMap { o in store.stops.first { $0.id == o.id } }) else { return }
        store.stops = planner.stops
        reload(force: true)
        Task { await Cloud.shared.schedulePushState() }
    }

    // MARK: Linking (a linked dropoff always stays after its pickup)

    /// Letter for each pickup that has at least one dropoff linked to it: A, B, C…
    var linkLetters: [String: String] {
        var letters: [String: String] = [:]
        let alphabet = Array("ABCDEFGHIJ")
        for p in stops where p.type == .pickup && letters[p.orderId] == nil {
            guard stops.contains(where: { $0.type == .dropoff && $0.orderIds.contains(p.orderId) }) else { continue }
            letters[p.orderId] = String(alphabet[min(letters.count, alphabet.count - 1)])
        }
        return letters
    }

    /// The letters to show on a stop: a pickup's own, or every pickup a dropoff is linked to ("A", "A B").
    func letters(for s: Stop) -> [String] {
        let all = linkLetters
        return s.orderIds.compactMap { all[$0] }
    }

    /// The pickups a dropoff is linked to right now.
    private func linkedPickupIds(_ d: Stop, in list: [Stop]) -> [String] {
        d.orderIds.filter { id in list.contains { $0.type == .pickup && $0.orderId == id } }
    }

    /// Tick / untick a pickup for a dropoff. A dropoff can be linked to several pickups (two orders going to
    /// one address); it always stays after every one of them, and moves down below them if needed.
    func toggleLink(_ dropoff: Stop, _ pickup: Stop) {
        var newStops = store.stops
        guard let di = newStops.firstIndex(where: { $0.id == dropoff.id }) else { return }
        var ids = linkedPickupIds(newStops[di], in: newStops)
        if ids.contains(pickup.orderId) { ids.removeAll { $0 == pickup.orderId } } else { ids.append(pickup.orderId) }
        newStops[di].setOrders(ids)
        save(placeAfterPickups(newStops, dropoffId: dropoff.id))
    }

    /// Remove every link from a dropoff.
    func unlinkAll(_ dropoff: Stop) {
        var newStops = store.stops
        guard let di = newStops.firstIndex(where: { $0.id == dropoff.id }) else { return }
        newStops[di].setOrders([])
        save(newStops)
    }

    /// If a dropoff sits above one of its pickups, move it just below the last one.
    private func placeAfterPickups(_ list: [Stop], dropoffId: UUID) -> [Stop] {
        var out = list
        guard !TripPlanner.isValidOrder(out), let di = out.firstIndex(where: { $0.id == dropoffId }) else { return out }
        let moved = out.remove(at: di)
        let last = out.lastIndex { $0.type == .pickup && moved.orderIds.contains($0.orderId) }
        out.insert(moved, at: last.map { $0 + 1 } ?? out.count)
        return out
    }

    private func save(_ newStops: [Stop]) {
        guard TripPlanner.isValidOrder(newStops) else { return }
        store.stops = newStops
        undoOrder = nil
        reload(force: true)
        Task { await Cloud.shared.schedulePushState() }
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

    func add(name: String, address: String, location: Coord, type: StopType) -> String? {
        guard stops.count < TripPlanner.maxStops else { return "Max \(TripPlanner.maxStops) stops — finish one first." }
        var planner = TripPlanner(stops: store.stops)
        planner.add(Stop(type: type, label: name, location: location, orderId: UUID().uuidString, address: address))
        store.stops = planner.stops
        reload(force: true)
        Task { await Cloud.shared.schedulePushState() }
        return nil
    }

    /// Edit a stop's name and address (from the ✏️ swipe). A new address moves the stop to that spot.
    func update(_ id: UUID, name: String, address: String, location: Coord?) {
        var list = store.stops
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].label = name
        list[i].address = address.isEmpty ? nil : address
        if let location { list[i].location = location }
        store.stops = list
        reload(force: true)
        Task { await Cloud.shared.schedulePushState() }
    }

    func add(query: String, type: StopType) async -> String? {
        guard stops.count < TripPlanner.maxStops else { return "Max \(TripPlanner.maxStops) stops — finish one first." }
        guard let loc = await PlaceFinder.find(query, near: store.currentLocation) else { return "Couldn't find “\(query)”." }
        var planner = TripPlanner(stops: store.stops)
        planner.add(Stop(type: type, label: query, location: loc, orderId: UUID().uuidString, address: query))
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
    /// What Google Maps is sent for a stop: its address text (no name), so it finds the exact address
    /// instead of snapping a map point to the building next door. Stops with no saved address use the pin.
    private func target(_ s: Stop) -> String {
        if let a = s.nameAndAddress.address?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            return a.replacingOccurrences(of: "|", with: " ")
        }
        return "\(s.location.lat),\(s.location.lng)"
    }

    func navigate() -> Bool {
        guard !stops.isEmpty else { return false }
        let batch = Array(stops.prefix(Self.googleMapsMaxStops))
        let waypoints = batch.dropLast().map { target($0) }.joined(separator: "|")
        var comps = URLComponents(string: "https://www.google.com/maps/dir/")!
        comps.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "travelmode", value: "driving"),
            URLQueryItem(name: "destination", value: target(batch.last!)),
        ] + (waypoints.isEmpty ? [] : [URLQueryItem(name: "waypoints", value: waypoints)])
        if let url = comps.url { UIApplication.shared.open(url) }
        return stops.count > batch.count
    }
}

/// Driving times between stops from Apple Maps (its routing engine finds the fastest road path for each pair).
/// Apple limits how many requests an app can make per minute, so the closest pairs are measured
/// and the rest are estimated from those measurements.
enum TravelTimes {
    struct Matrix {
        var cost: [[Double]]        // seconds, stop i -> stop j
        var fromStart: [Double]?    // seconds, you -> stop j (nil without a location)
        var measured: Int
    }

    static let maxRequests = 36

    static func matrix(start: Coord?, points: [Coord]) async -> Matrix {
        let nodes = (start.map { [$0] } ?? []) + points
        let off = start == nil ? 0 : 1
        let m = nodes.count
        func straight(_ i: Int, _ j: Int) -> Double { Geo.straightMiles(nodes[i], nodes[j]) }

        // Closest pairs first (they decide most of the order). Nobody drives back to the start.
        var pairs: [(Int, Int)] = []
        for i in 0..<m {
            for j in 0..<m where j != i && !(off == 1 && j == 0) { pairs.append((i, j)) }
        }
        pairs.sort { straight($0.0, $0.1) < straight($1.0, $1.1) }
        // Measure one direction per pair first; the reverse is usually about the same.
        var chosen: [(Int, Int)] = []
        var seen = Set<String>()
        for (i, j) in pairs where chosen.count < maxRequests {
            let k = "\(min(i, j))-\(max(i, j))"
            if seen.insert(k).inserted { chosen.append((i, j)) }
        }

        var secs = [[Double?]](repeating: [Double?](repeating: nil, count: m), count: m)
        var index = 0
        while index < chosen.count {
            let batch = Array(chosen[index..<min(index + 6, chosen.count)])
            index += batch.count
            await withTaskGroup(of: (Int, Int, Double?).self) { group in
                for (i, j) in batch {
                    let a = nodes[i], b = nodes[j]
                    group.addTask { (i, j, await eta(a, b)) }
                }
                for await (i, j, t) in group { secs[i][j] = t }
            }
        }

        // Seconds per straight-line mile, learned from the measured pairs (for the ones not measured).
        var rates: [Double] = []
        for i in 0..<m { for j in 0..<m { if let t = secs[i][j], straight(i, j) > 0.05 { rates.append(t / straight(i, j)) } } }
        rates.sort()
        let rate = rates.isEmpty ? 150 : rates[rates.count / 2]
        let measured = rates.count

        func time(_ i: Int, _ j: Int) -> Double {
            if i == j { return 0 }
            return secs[i][j] ?? secs[j][i] ?? straight(i, j) * rate
        }
        let n = points.count
        let cost = (0..<n).map { i in (0..<n).map { j in time(i + off, j + off) } }
        let fromStart = off == 1 ? (0..<n).map { time(0, $0 + 1) } : nil
        return Matrix(cost: cost, fromStart: fromStart, measured: measured)
    }

    static func eta(_ a: Coord, _ b: Coord) async -> Double? {
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: a.cl))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b.cl))
        req.transportType = .automobile
        return try? await MKDirections(request: req).calculateETA().expectedTravelTime
    }
}

struct RouteView: View {
    @StateObject private var model = RouteModel()
    @State private var camera: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var message: String?
    @State private var picked: (label: String, title: String, coord: Coord)?
    @State private var expanded = Set<UUID>()
    @State private var editing: Stop?
    @StateObject private var completer = AddressCompleter()
    @State private var editMode: EditMode = .inactive
    @State private var showBatchNote = false
    @State private var optimizeNote: String?
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
                        Marker(markerTitle(i, s), coordinate: s.location.cl)
                            .tint(s.type == .pickup ? .blue : .green)
                    }
                    ForEach(model.legs, id: \.self) { leg in
                        MapPolyline(leg).stroke(.blue, lineWidth: 6)
                    }
                }
                .frame(maxHeight: .infinity)

                List {
                    if model.stops.count >= 2 && editMode == .inactive {
                        Section {
                            HStack(spacing: 10) {
                                Button {
                                    Task { optimizeNote = await model.optimize() }
                                } label: {
                                    HStack {
                                        if model.optimizing { ProgressView() } else { Image(systemName: "wand.and.stars") }
                                        Text(model.optimizing ? "Finding the fastest order…" : "Optimize route")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.optimizing)
                                if model.undoOrder != nil {
                                    Button("Undo") { model.undoOptimize(); optimizeNote = nil }
                                        .buttonStyle(.bordered)
                                }
                            }
                            if let optimizeNote {
                                Text(optimizeNote).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        let pickups = model.stops.enumerated().filter { $0.element.type == .pickup }
                        ForEach(Array(model.stops.enumerated()), id: \.element.id) { i, s in
                            HStack {
                                Image(systemName: s.type == .pickup ? "bag.fill" : "house.fill")
                                    .foregroundStyle(s.type == .pickup ? .blue : .green)
                                stopText(i, s)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.snappy) {
                                            if expanded.contains(s.id) { expanded.remove(s.id) } else { expanded.insert(s.id) }
                                        }
                                    }
                                ForEach(model.letters(for: s), id: \.self) { letter in
                                    Text(letter)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(.orange))
                                }
                                Spacer()
                                if editMode == .inactive {
                                    if s.type == .dropoff && !pickups.isEmpty {
                                        let linked = !model.letters(for: s).isEmpty
                                        Menu {
                                            Section("Linked to (tick one or more)") {
                                                ForEach(pickups, id: \.element.id) { pi, p in
                                                    Button {
                                                        model.toggleLink(s, p)
                                                    } label: {
                                                        if s.orderIds.contains(p.orderId) {
                                                            Label("\(pi + 1). \(p.label)", systemImage: "checkmark")
                                                        } else {
                                                            Text("\(pi + 1). \(p.label)")
                                                        }
                                                    }
                                                }
                                            }
                                            if linked {
                                                Button(role: .destructive) { model.unlinkAll(s) } label: {
                                                    Label("Unlink all", systemImage: "link.badge.minus")
                                                }
                                            }
                                        } label: {
                                            Image(systemName: linked ? "link.circle.fill" : "link")
                                                .font(.title3)
                                        }
                                        .menuStyle(.button)
                                        .buttonStyle(.borderless)
                                    }
                                    Button("Done") { model.complete(s) }.buttonStyle(.bordered)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { model.complete(s) } label: { Label("Delete", systemImage: "trash") }
                                Button { editing = s } label: { Label("Edit", systemImage: "pencil") }.tint(.orange)
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
                        } else if model.stops.contains(where: { $0.type == .dropoff }) {
                            Text("Tap 🔗 on a dropoff to link it to its pickup. Tick two pickups when two orders go to one address. Linked stops share a letter, and a dropoff always stays after every pickup it's linked to, including when you optimize. Offers you accept are linked automatically.")
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
                .frame(height: 420)
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
        .sheet(item: $editing) { stop in
            StopEditView(stop: stop) { name, address, location in
                model.update(stop.id, name: name, address: address, location: location)
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
            message = model.add(name: picked.title, address: picked.label, location: picked.coord, type: type)
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

    /// Collapsed: "3. Mike R · 15 France St" on one line. Expanded (tap): the name, then the full address.
    @ViewBuilder
    private func stopText(_ i: Int, _ s: Stop) -> some View {
        let parts = s.nameAndAddress
        if expanded.contains(s.id) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(i + 1). \(parts.name)").fixedSize(horizontal: false, vertical: true)
                Text(parts.address ?? "No address saved — swipe left and tap ✏️ to add one.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } else {
            let suffix = (parts.address == nil || parts.address == parts.name) ? "" : (s.street.map { " · " + $0 } ?? "")
            Text("\(i + 1). " + parts.name + suffix).lineLimit(1)
        }
    }

    private func markerTitle(_ i: Int, _ s: Stop) -> String {
        let kind = s.type == .pickup ? "Pickup" : "Dropoff"
        let letters = model.letters(for: s)
        return letters.isEmpty ? "\(i + 1). \(kind)" : "\(i + 1). \(kind) \(letters.joined(separator: " "))"
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
    /// label = the full text ("Chipotle, 1675 Sunrise Hwy, Bay Shore"), title = just the first part ("Chipotle").
    func resolve(_ item: MKLocalSearchCompletion) async -> (label: String, title: String, coord: Coord)? {
        let request = MKLocalSearch.Request(completion: item)
        guard let mapItem = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let label = item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)"
        return (label, item.title, Coord(mapItem.placemark.coordinate))
    }
}
