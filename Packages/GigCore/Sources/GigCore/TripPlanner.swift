import Foundation

public enum Geo {
    /// Straight-line distance is shorter than real roads; typical city fudge factor.
    public static let roadFactor = 1.3

    public static func straightMiles(_ a: Coord, _ b: Coord) -> Double {
        let r = 3958.8
        let dLat = (b.lat - a.lat) * .pi / 180
        let dLng = (b.lng - a.lng) * .pi / 180
        let h = pow(sin(dLat / 2), 2) + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * pow(sin(dLng / 2), 2)
        return 2 * r * asin(sqrt(h))
    }

    public static func roadMiles(_ a: Coord, _ b: Coord) -> Double { straightMiles(a, b) * roadFactor }

    public static func routeMiles(_ pts: [Coord]) -> Double {
        guard pts.count > 1 else { return 0 }
        return zip(pts, pts.dropFirst()).reduce(0) { $0 + roadMiles($1.0, $1.1) }
    }
}

/// The active route (pickups + dropoffs from ANY app), max 4 stops,
/// and the "does this new offer fit on my way?" logic.
public struct TripPlanner {
    public static let maxStops = 9

    public private(set) var stops: [Stop]

    public init(stops: [Stop] = []) { self.stops = Array(stops.prefix(Self.maxStops)) }

    public func canAdd(_ n: Int) -> Bool { stops.count + n <= Self.maxStops }

    @discardableResult
    public mutating func add(_ s: Stop) -> Bool {
        guard canAdd(1) else { return false }
        stops.append(s); return true
    }

    public mutating func remove(id: UUID) { stops.removeAll { $0.id == id } }

    /// Every order's pickup must come before its dropoff.
    public static func isValidOrder(_ stops: [Stop]) -> Bool {
        var picked = Set<String>()
        let ordersWithPickup = Set(stops.filter { $0.type == .pickup }.map(\.orderId))
        for s in stops {
            switch s.type {
            case .pickup: picked.insert(s.orderId)
            case .dropoff:
                if ordersWithPickup.contains(s.orderId) && !picked.contains(s.orderId) { return false }
            }
        }
        return true
    }

    /// Your own order (drag to reorder). Rejected if a dropoff would come before its pickup.
    @discardableResult
    public mutating func reorder(_ newOrder: [Stop]) -> Bool {
        guard newOrder.count == stops.count, Set(newOrder.map(\.id)) == Set(stops.map(\.id)),
              Self.isValidOrder(newOrder) else { return false }
        stops = newOrder
        return true
    }

    public struct Insertion: Equatable {
        public var order: [Stop]
        public var baseMiles: Double
        public var newMiles: Double
        public var addedMiles: Double { newMiles - baseMiles }
    }

    /// Tries every legal spot for pickup P and dropoff D (P before D, existing stops keep
    /// their order) and returns the one that adds the fewest miles.
    public func bestInsertion(origin: Coord, pickup: Stop, dropoff: Stop) -> Insertion? {
        guard canAdd(2) else { return nil }
        let base = Geo.routeMiles([origin] + stops.map(\.location))
        var best: Insertion?
        let n = stops.count
        for i in 0...n {
            for j in (i + 1)...(n + 1) {
                var order = stops
                order.insert(pickup, at: i)
                order.insert(dropoff, at: j)
                let miles = Geo.routeMiles([origin] + order.map(\.location))
                if best == nil || miles < best!.newMiles { best = Insertion(order: order, baseMiles: base, newMiles: miles) }
            }
        }
        return best
    }

    /// Adds an order in the cheapest position (falls back to appending).
    @discardableResult
    public mutating func addOrder(origin: Coord?, pickup: Stop, dropoff: Stop) -> Bool {
        guard canAdd(2) else { return false }
        if let ins = bestInsertion(origin: origin ?? pickup.location, pickup: pickup, dropoff: dropoff) {
            stops = ins.order
        } else {
            stops.append(pickup); stops.append(dropoff)
        }
        return true
    }

    public enum Verdict { case noActiveTrip, onTheWay, nearFinal, offRoute, tooManyStops, unknownLocation }

    public struct OnTheWay {
        public var verdict: Verdict
        public var addedMiles: Double?
        public var dropoffToFinalMi: Double?
        public var stackedPerMile: Double?   // offer pay ÷ the EXTRA miles it costs you
        public var insertion: Insertion?
        /// True when there was no route, so distances are measured from where you are.
        public var fromHere: Bool

        public init(verdict: Verdict, addedMiles: Double? = nil, dropoffToFinalMi: Double? = nil,
                    stackedPerMile: Double? = nil, insertion: Insertion? = nil, fromHere: Bool = false) {
            self.verdict = verdict; self.addedMiles = addedMiles; self.dropoffToFinalMi = dropoffToFinalMi
            self.stackedPerMile = stackedPerMile; self.insertion = insertion; self.fromHere = fromHere
        }

        public var good: Bool { verdict == .onTheWay || verdict == .nearFinal }

        /// Short form for the banner (fits on one line).
        public var shortMessage: String {
            let f = { (x: Double?) in String(format: "%.1f", x ?? 0) }
            switch verdict {
            case .noActiveTrip: return ""
            case .unknownLocation: return "Route check: couldn't locate"
            case .tooManyStops: return "Route full (\(TripPlanner.maxStops) stops)"
            case .nearFinal where fromHere: return "✅ ON THE WAY · ends \(f(dropoffToFinalMi)) mi from you"
            case .nearFinal: return "✅ ON THE WAY · ends \(f(dropoffToFinalMi)) mi from last stop"
            case .onTheWay: return "✅ CLOSE BY · only +\(f(addedMiles)) mi"
            case .offRoute where fromHere: return "❌ OFF ROUTE · ends \(f(dropoffToFinalMi)) mi from you"
            case .offRoute: return "❌ OFF ROUTE · +\(f(addedMiles)) mi extra"
            }
        }

        public var message: String {
            let f = { (x: Double?) in String(format: "%.1f", x ?? 0) }
            let perMile = stackedPerMile.map { String(format: " → $%.2f per extra mile", $0) } ?? ""
            switch verdict {
            case .noActiveTrip: return "No active route — graded on its own."
            case .unknownLocation: return "Couldn't locate pickup/dropoff — on-the-way check skipped."
            case .tooManyStops: return "Route already has \(TripPlanner.maxStops) stops — finish one first."
            // .nearFinal = ends near your final stop (or near you) -> ON THE WAY
            // .onTheWay  = only a small detour                      -> CLOSE BY
            case .nearFinal where fromHere: return "✅ ON THE WAY: ends \(f(dropoffToFinalMi)) mi from you"
            case .nearFinal: return "✅ ON THE WAY: ends \(f(dropoffToFinalMi)) mi from your final stop (+\(f(addedMiles)) mi)\(perMile)"
            case .onTheWay: return "✅ CLOSE BY: only +\(f(addedMiles)) mi extra\(perMile)"
            case .offRoute where fromHere: return "❌ OFF ROUTE: ends \(f(dropoffToFinalMi)) mi from you"
            case .offRoute: return "❌ OFF ROUTE: +\(f(addedMiles)) mi extra, ends \(f(dropoffToFinalMi)) mi from your final stop"
            }
        }
    }

    public func checkOnTheWay(origin: Coord?, pickup: Stop?, dropoff: Stop?, pay: Double,
                              settings s: DriverSettings) -> OnTheWay {
        guard let lastStop = stops.last else {
            // No route: is the dropoff close to where you are now?
            guard let origin, let dropoff else { return OnTheWay(verdict: .unknownLocation) }
            let away = Geo.roadMiles(origin, dropoff.location)
            return OnTheWay(verdict: away <= s.onTheWayRadiusMi ? .nearFinal : .offRoute,
                            dropoffToFinalMi: away, fromHere: true)
        }
        guard let origin, let pickup, let dropoff else { return OnTheWay(verdict: .unknownLocation) }
        guard canAdd(2), let ins = bestInsertion(origin: origin, pickup: pickup, dropoff: dropoff) else {
            return OnTheWay(verdict: .tooManyStops)
        }
        let added = max(ins.addedMiles, 0)
        let toFinal = Geo.roadMiles(dropoff.location, lastStop.location)
        let perMile = added > 0.1 ? pay / added : nil
        let v: Verdict
        if toFinal <= s.onTheWayRadiusMi { v = .nearFinal }   // ON THE WAY (checked first)
        else if added <= s.maxDetourMi { v = .onTheWay }     // CLOSE BY
        else { v = .offRoute }
        return OnTheWay(verdict: v, addedMiles: added, dropoffToFinalMi: toFinal, stackedPerMile: perMile, insertion: ins)
    }
}
