import Foundation

/// The pickup half of the route check: is the offer's store (or each of its stores) near a pickup
/// already in your route? Every route pickup is compared, not just the last stop.
public struct PickupCheck: Equatable {
    public enum Level: Int, Comparable {
        case near = 0, close = 1, off = 2
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        var mark: String { self == .near ? "✅" : self == .close ? "⚠️" : "❌" }
    }

    public struct Store: Equatable {
        public var level: Level
        public var nearestMi: Double?       // to the closest pickup in your route (or to you)
        public var nearestName: String?     // that pickup's name (nil = you)
        public var detourMi: Double?        // extra miles to fit this store into your route (information only)
        public var estimated: Bool          // placed from the map, not from an address

        public init(level: Level, nearestMi: Double?, nearestName: String?, detourMi: Double?, estimated: Bool) {
            self.level = level; self.nearestMi = nearestMi; self.nearestName = nearestName
            self.detourMi = detourMi; self.estimated = estimated
        }
    }

    public var stores: [Store]
    public var unchecked: Int               // stores/stops the card or map hinted at but couldn't be placed

    public init(stores: [Store], unchecked: Int) { self.stores = stores; self.unchecked = unchecked }

    /// The worst store: the one farthest from a pickup in your route.
    public var worst: Store? {
        stores.max { a, b in
            if a.level != b.level { return a.level < b.level }
            return (a.nearestMi ?? 0) < (b.nearestMi ?? 0)
        }
    }

    /// Banner text, e.g. "🛍 ✅ 0.3 mi from Chipotle", "🛍 ⚠️ 2 stores, farthest 1.3 mi from Chipotle".
    public var compact: String {
        guard let w = worst else { return "🛍 ?" + (unchecked > 0 ? " (\(unchecked) not checked)" : "") }
        let approx = w.estimated ? "≈" : ""
        let f = { (x: Double?) in String(format: "%.1f", x ?? 0) }
        let many = stores.count > 1 ? "\(stores.count) stores, farthest " : ""
        let from = w.nearestName.map { PickupCheck.shortName($0) } ?? "you"
        var text = "🛍 \(w.level.mark) \(many)\(approx)\(f(w.nearestMi)) mi from \(from)"
        if unchecked > 0 { text += " (+\(unchecked) not checked)" }
        return text
    }

    /// Longer wording for the offer's Trip notes.
    public var message: String {
        guard let w = worst else { return "Pickup: couldn't locate the store." }
        // Pickups: radius from the nearest pickup in your route. CLOSE BY = inner radius, ON THE WAY = outer.
        let word = w.level == .near ? "CLOSE BY" : w.level == .close ? "ON THE WAY" : "OFF ROUTE"
        let extra = w.detourMi.map { String(format: " (+%.1f mi extra)", $0) } ?? ""
        return "Pickup \(w.level.mark) \(word): " + compact.replacingOccurrences(of: "🛍 \(w.level.mark) ", with: "") + extra
    }

    static func shortName(_ s: String) -> String {
        let name = s.components(separatedBy: " · ").first ?? s
        return name.count > 18 ? String(name.prefix(17)) + "…" : name
    }
}

extension TripPlanner {
    /// Checks each of the offer's stores against every pickup in the route.
    /// Radius from the nearest pickup in your route (or from you, when the route has no pickups):
    /// - CLOSE BY ✅: within the Close by radius.
    /// - ON THE WAY ⚠️: within the On the way radius.
    /// - OFF ROUTE ❌: farther than that.
    public func checkPickups(stores: [(coord: Coord, estimated: Bool)], unchecked: Int = 0,
                             origin: Coord?, settings s: DriverSettings) -> PickupCheck {
        let routePickups = stops.filter { $0.type == .pickup }
        let path = [origin].compactMap { $0 } + stops.map(\.location)
        var result: [PickupCheck.Store] = []
        for store in stores {
            // Closest pickup in the route (or you).
            var nearest: (mi: Double, name: String?)?
            for p in routePickups {
                let d = Geo.radiusMiles(store.coord, p.location)
                if nearest == nil || d < nearest!.mi { nearest = (d, p.label) }
            }
            if nearest == nil, let origin { nearest = (Geo.radiusMiles(store.coord, origin), nil) }
            let detour = Self.cheapestDetour(store.coord, path: path)
            let level: PickupCheck.Level
            if let n = nearest, n.mi <= s.pickupCloseByMi { level = .near }
            else if let n = nearest, n.mi <= s.pickupOnTheWayMi { level = .close }
            else { level = .off }
            result.append(PickupCheck.Store(level: level, nearestMi: nearest?.mi, nearestName: nearest?.name,
                                            detourMi: detour, estimated: store.estimated))
        }
        return PickupCheck(stores: result, unchecked: unchecked)
    }

    /// Extra miles to visit `p` somewhere along `path` (between two stops, or after the last one).
    static func cheapestDetour(_ p: Coord, path: [Coord]) -> Double? {
        guard let last = path.last else { return nil }
        var best = Geo.roadMiles(last, p)                       // after the last stop
        for (a, b) in zip(path, path.dropFirst()) {
            let extra = Geo.roadMiles(a, p) + Geo.roadMiles(p, b) - Geo.roadMiles(a, b)
            best = min(best, max(0, extra))
        }
        return best
    }

    /// Extra miles to fit several stores and several customers into the route: each store goes in its cheapest
    /// spot, then each customer in its cheapest spot after the stores (a quick estimate, not every ordering).
    public func addedMiles(stores: [Coord], customers: [Coord], origin: Coord) -> Double {
        var path = [origin] + stops.map(\.location)
        let base = Geo.routeMiles(path)
        var lastStoreIndex = 0
        func insert(_ p: Coord, after minIndex: Int) -> Int {
            var bestAt = path.count, bestCost = Geo.roadMiles(path[path.count - 1], p)
            if minIndex + 1 < path.count {
                for at in (minIndex + 1)..<path.count {
                    let a = path[at - 1], b = path[at]
                    let cost = Geo.roadMiles(a, p) + Geo.roadMiles(p, b) - Geo.roadMiles(a, b)
                    if cost < bestCost { bestCost = cost; bestAt = at }
                }
            }
            path.insert(p, at: bestAt)
            return bestAt
        }
        for s in stores {
            let at = insert(s, after: 0)
            if lastStoreIndex > 0, at <= lastStoreIndex { lastStoreIndex += 1 } // an earlier store moved down one
            lastStoreIndex = max(lastStoreIndex, at)
        }
        for c in customers { _ = insert(c, after: lastStoreIndex) }
        return max(0, Geo.routeMiles(path) - base)
    }
}

extension TripPlanner.OnTheWay {
    /// Dropoff half of the banner, e.g. "🏠 ✅ ends 0.9 mi from last stop", "🏠 ⚠️ 2 drops, farthest ends 2.4 mi from last stop".
    public func compact(drops: Int = 1) -> String {
        let f = { (x: Double?) in String(format: "%.1f", x ?? 0) }
        let approx = approximate ? "≈" : ""
        let many = drops > 1 ? "\(drops) drops, farthest " : ""
        switch verdict {
        case .noActiveTrip: return ""
        case .unknownLocation: return "🏠 ?"
        case .tooManyStops: return "🏠 route full (\(TripPlanner.maxStops) stops)"
        case .nearFinal, .onTheWay, .offRoute:
            return "🏠 \(mark) \(many)\(approx)ends \(f(dropoffToFinalMi)) mi from \(fromHere ? "you" : "last stop")"
        }
    }
}
