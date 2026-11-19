import Foundation

/// Pins found on an offer's map screenshot, in screen pixels (y grows downward).
/// Each point is the small location dot under a pin, not the pin bubble itself.
public struct MapPins: Equatable {
    public struct Point: Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    public var me: Point?          // blue GPS dot
    public var stores: [Point]     // store-icon pins
    public var customers: [Point]  // person-icon pins
    public init(me: Point?, stores: [Point], customers: [Point]) {
        self.me = me; self.stores = stores; self.customers = customers
    }
}

/// Works out where the customer is from the map: your GPS dot and the store pin are two points
/// whose real locations we know, which fixes the map's scale (and confirms it's north-up). The
/// customer pin's real location then follows. Verified on real DoorDash screenshots: the same
/// customer lands in the same place across different zoom levels.
public enum MapLocator {

    public struct Estimate: Equatable {
        public var customers: [Coord]    // in route order, closest to the store first
        public var finalDropoff: Coord   // last customer = where the trip ends
        public var rotationDegrees: Double
        public var metersPerPixel: Double
    }

    // Web maps use the Mercator projection: straight lines and angles are preserved locally.
    static let earthRadius = 6_378_137.0

    static func project(_ c: Coord) -> (x: Double, y: Double) {
        let lat = max(min(c.lat, 85), -85) * .pi / 180
        return (earthRadius * c.lng * .pi / 180, earthRadius * log(tan(.pi / 4 + lat / 2)))
    }

    static func unproject(_ x: Double, _ y: Double) -> Coord {
        let lng = x / earthRadius * 180 / .pi
        let lat = (2 * atan(exp(y / earthRadius)) - .pi / 2) * 180 / .pi
        return Coord(lat: lat, lng: lng)
    }

    /// - Parameters:
    ///   - me: your current GPS location (the blue dot).
    ///   - store: the pickup's real location (from its address).
    ///   - statedMiles: the offer's total miles, used as a sanity check.
    /// - Returns: nil when the picture and the known locations don't agree well enough to trust.
    /// General form: two map points whose real locations are known fix the scale; returns the real
    /// locations of `targets`. nil if the picture and the known locations disagree (map not north-up,
    /// stale GPS, or an address that matched the wrong place).
    public static func solve(refA: MapPins.Point, worldA: Coord, refB: MapPins.Point, worldB: Coord,
                             targets: [MapPins.Point]) -> (coords: [Coord], rotation: Double, metersPerPixel: Double)? {
        let sdx = refB.x - refA.x, sdy = -(refB.y - refA.y)
        let screenLen = (sdx * sdx + sdy * sdy).squareRoot()
        guard screenLen >= 40 else { return nil } // too close together on screen to measure scale

        let w0 = project(worldA), w1 = project(worldB)
        let wdx = w1.x - w0.x, wdy = w1.y - w0.y
        let worldLen = (wdx * wdx + wdy * wdy).squareRoot()
        guard worldLen >= 50 else { return nil } // the two places are basically the same spot

        // Similarity transform world = a * screen + b, with a = scale·e^(iθ) as a complex number.
        let denom = sdx * sdx + sdy * sdy
        let aRe = (wdx * sdx + wdy * sdy) / denom
        let aIm = (wdy * sdx - wdx * sdy) / denom
        let rotation = atan2(aIm, aRe) * 180 / .pi
        let groundScale = (aRe * aRe + aIm * aIm).squareRoot() * cos(worldA.lat * .pi / 180)
        guard abs(rotation) <= 20 else { return nil }           // offer maps are north-up
        guard groundScale > 0.3, groundScale < 250 else { return nil } // meters per pixel

        let coords = targets.map { p -> Coord in
            let dx = p.x - refA.x, dy = -(p.y - refA.y)
            return unproject(w0.x + aRe * dx - aIm * dy, w0.y + aIm * dx + aRe * dy)
        }
        return (coords, rotation, groundScale)
    }

    /// - Parameters:
    ///   - me: your current GPS location (the blue dot / arrow).
    ///   - store: the pickup's real location (from its address).
    ///   - statedMiles: the offer's total miles, used as a sanity check.
    /// - Returns: nil when the picture and the known locations don't agree well enough to trust.
    public static func locate(pins: MapPins, me: Coord, store: Coord, statedMiles: Double?) -> Estimate? {
        guard let meP = pins.me, let storeP = pins.stores.first, !pins.customers.isEmpty,
              let solved = solve(refA: meP, worldA: me, refB: storeP, worldB: store, targets: pins.customers)
        else { return nil }
        let customers = solved.coords.sorted { Geo.straightMiles(store, $0) < Geo.straightMiles(store, $1) }
        guard let last = customers.last else { return nil }

        // Sanity check against the offer's own mileage (generous: roads wind, miles may differ).
        if let miles = statedMiles, miles > 0 {
            let path = Geo.routeMiles([store] + customers)
            let withDriveToStore = path + Geo.roadMiles(me, store)
            guard withDriveToStore / miles >= 0.3, path / miles <= 3.0 else { return nil }
        }
        return Estimate(customers: customers, finalDropoff: last, rotationDegrees: solved.rotation,
                        metersPerPixel: solved.metersPerPixel)
    }

    /// The reverse: dropoff known (from its address), pickup unknown (e.g. a store name Apple Maps can't find).
    public static func locatePickup(pins: MapPins, me: Coord, dropoff: Coord) -> Coord? {
        guard let meP = pins.me, let dropP = pins.customers.last, let storeP = pins.stores.first,
              let solved = solve(refA: meP, worldA: me, refB: dropP, worldB: dropoff, targets: [storeP])
        else { return nil }
        return solved.coords.first
    }
}
