import Foundation
import MapKit
import GigCore

extension Coord {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
    init(_ c: CLLocationCoordinate2D) { self.init(lat: c.latitude, lng: c.longitude) }
}

/// Finds an address, cross streets, or a business name ("Chipotle") near you, using Apple Maps.
enum PlaceFinder {
    /// "Halsey St, Port Jefferson Station" for a map spot.
    static func describe(_ c: Coord) async -> String? {
        guard let p = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.lat, longitude: c.lng)).first
        else { return nil }
        let parts = [p.thoroughfare, p.subLocality ?? p.locality].compactMap { $0 }
        return parts.isEmpty ? p.name : parts.joined(separator: ", ")
    }

    // MARK: Uber store lookup (5.9.6.3)

    struct StoreResult {
        var coord: Coord?
        var notes: [String] = []
        var notable = false     // worth an entry in the Issues log
    }

    private struct Hit {
        let coord: Coord
        let name: String
        let number: String?
        let street: String?
        var locality: String? = nil
    }

    /// Finds an Uber store from its card line, checking every result instead of taking the first/closest one:
    /// - the result's name must match the store's name (no lookalikes),
    /// - it must be within the offer's total miles of you (a store can't be farther away than the whole trip),
    /// - when the card has an address ("Taco Bell (4833 Nesconset Hwy)"), the house number and street must match;
    ///   if no listing matches, the address itself is used.
    /// Returns nil when nothing passes, so the map's store pin can be tried next.
    static func findStore(_ text: String?, near me: Coord?, tripMiles: Double?, town: String?) async -> StoreResult {
        guard let text, !text.isEmpty else { return StoreResult() }
        let parts = StoreText.split(text)
        var out = StoreResult()
        let reach = min(40, (tripMiles ?? 40) + 0.5)
        func inReach(_ c: Coord) -> Bool { me.map { Geo.straightMiles($0, c) <= reach } ?? true }
        func fromYou(_ c: Coord) -> String { me.map { String(format: "%.1f mi from you", Geo.straightMiles($0, c)) } ?? "" }

        // Several searches at once, results pooled. The store's own town ("(Selden)") beats the customer's.
        let storeTown = parts.town ?? town
        var queries = [parts.name]
        if let a = parts.address { queries.insert("\(parts.name) \(a)", at: 0) }
        if let storeTown { queries.append("\(parts.name) \(storeTown)") }
        var hits: [Hit] = []
        await withTaskGroup(of: [Hit].self) { group in
            for q in queries { group.addTask { await pointsOfInterest(q, near: me) } }
            for await h in group { hits += h }
        }

        var named: [Hit] = []
        var wrongName = 0, tooFar = 0
        for h in hits {
            guard StoreText.nameMatches(card: parts.name, place: h.name) else { wrongName += 1; continue }
            guard inReach(h.coord) else { tooFar += 1; continue }
            if named.contains(where: { Geo.straightMiles($0.coord, h.coord) < 0.02 }) { continue }
            named.append(h)
        }
        if wrongName > 0 { out.notes.append("\(wrongName) search result(s) skipped: name didn't match “\(parts.name)”") }
        // The card names the store's town: keep the places in that town (if Apple lists any there).
        if let t = parts.town {
            let inTown = named.filter { StoreText.sameTown($0.locality, t) }
            if !inTown.isEmpty {
                if inTown.count < named.count { out.notes.append("\(named.count - inTown.count) “\(parts.name)” outside \(t) skipped") }
                named = inTown
            } else if !named.isEmpty {
                out.notes.append("no “\(parts.name)” listed in \(t); kept the ones in range")
                out.notable = true
            }
        }
        if tooFar > 0 {
            out.notes.append(String(format: "%d place(s) named “%@” skipped: more than %.1f mi away (farther than the whole trip)",
                                    tooFar, parts.name, reach))
            out.notable = true
        }

        if let number = parts.number, let street = parts.street {
            if let exact = named.first(where: {
                StoreText.numberMatches(card: number, place: $0.number) && StoreText.streetMatches(card: street, place: $0.street)
            }) {
                out.coord = exact.coord
                return out
            }
            if let spot = await addressSpot("\(number) \(street)", number: number, near: me, inReach: inReach) {
                if let snap = named.min(by: { Geo.straightMiles($0.coord, spot) < Geo.straightMiles($1.coord, spot) }),
                   Geo.straightMiles(snap.coord, spot) <= 0.15 {
                    out.coord = snap.coord
                    out.notes.append("“\(snap.name)” listing is at a different number; used it since it's next to \(number) \(street)")
                } else {
                    out.coord = spot
                    out.notes.append("no “\(parts.name)” listing at \(number) \(street); used the address itself")
                }
                out.notable = true
                return out
            }
            out.notes.append("couldn't find \(number) \(street); went by the name only")
            out.notable = true
        }

        if let best = named.min(by: { a, b in
            guard let me else { return false }
            return Geo.straightMiles(me, a.coord) < Geo.straightMiles(me, b.coord)
        }) {
            out.coord = best.coord
            if named.count > 1 {
                out.notes.append("\(named.count) places named “\(parts.name)” in range; used the closest to you (\(fromYou(best.coord)))")
                out.notable = true
            }
            return out
        }
        out.notes.append(String(format: "no place named “%@” within %.1f mi", parts.name, reach))
        out.notable = true
        return out
    }

    private static func pointsOfInterest(_ query: String, near: Coord?) async -> [Hit] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.resultTypes = .pointOfInterest
        if let near { req.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }
        return resp.mapItems.map {
            Hit(coord: Coord($0.placemark.coordinate), name: $0.name ?? "",
                number: $0.placemark.subThoroughfare, street: $0.placemark.thoroughfare, locality: $0.placemark.locality)
        }
    }

    // MARK: Uber customer lookup (5.9.6.4)

    /// Uber's customer is cross streets ("Barker Dr & Bucknell Ln, Stony Brook") or a street ("Bicycle Path, …").
    /// Every result must be on one of those streets and within the trip's miles of you (and of the store, when it's
    /// known); results in the card's town are preferred. The corner first, then one street + town (rough).
    static func findCustomer(_ text: String?, near me: Coord?, store: Coord?, tripMiles: Double?) async -> StoreResult {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return StoreResult() }
        var out = StoreResult()
        let town = Self.town(in: text)
        let reach = min(40, (tripMiles ?? 40) + 0.5)
        func inReach(_ c: Coord) -> Bool {
            (me.map { Geo.straightMiles($0, c) <= reach } ?? true) && (store.map { Geo.straightMiles($0, c) <= reach } ?? true)
        }
        let streetsPart = text.split(separator: ",").first.map(String.init) ?? text
        let streets = streetsPart.components(separatedBy: "&").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        var tries: [(query: String, rough: Bool)] = [(text, false)]
        if text.contains("&") {
            tries.append((text.replacingOccurrences(of: "&", with: "and"), false))
            tries.append((text.replacingOccurrences(of: "&", with: "at"), false))
            for s in streets { tries.append((s + (town.map { ", " + $0 } ?? ""), true)) } // one street + town (rough)
        }
        var offStreet = 0, tooFar = 0
        for t in tries {
            let hits = await addresses(t.query, near: me)
            var good: [Hit] = []
            for h in hits {
                // A rough try must be on the street it searched; a corner try on either street.
                let card = t.rough ? (t.query.split(separator: ",").first.map(String.init) ?? t.query) : streetsPart
                guard StoreText.onStreets(card: card, place: h.street) || StoreText.onStreets(card: card, place: h.name)
                else { offStreet += 1; continue }
                guard inReach(h.coord) else { tooFar += 1; continue }
                good.append(h)
            }
            guard !good.isEmpty else { continue }
            let inTown = good.filter { StoreText.sameTown($0.locality, town) }
            let pool = inTown.isEmpty ? good : inTown
            let anchor = store ?? me
            out.coord = anchor.map { a in pool.min { Geo.straightMiles(a, $0.coord) < Geo.straightMiles(a, $1.coord) }!.coord }
                ?? pool[0].coord
            if t.rough { out.notes.append("corner not found; used a point on \(t.query) (rough)"); out.notable = true }
            break
        }
        if offStreet > 0 { out.notes.insert("\(offStreet) result(s) skipped: not on \(streetsPart)", at: 0); out.notable = true }
        if tooFar > 0 {
            out.notes.append(String(format: "%d result(s) skipped: more than %.1f mi away (farther than the whole trip)", tooFar, reach))
            out.notable = true
        }
        if out.coord == nil { out.notes.append("no result on \(streetsPart) within \(Int(reach)) mi"); out.notable = true }
        return out
    }

    /// Address results from Apple Maps search and the geocoder, with street and town for checking.
    private static func addresses(_ query: String, near: Coord?) async -> [Hit] {
        var hits: [Hit] = []
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let near { req.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        if let resp = try? await MKLocalSearch(request: req).start() {
            hits += resp.mapItems.map {
                Hit(coord: Coord($0.placemark.coordinate), name: $0.name ?? "", number: $0.placemark.subThoroughfare,
                    street: $0.placemark.thoroughfare, locality: $0.placemark.locality)
            }
        }
        let region = near.map { CLCircularRegion(center: $0.cl, radius: 50_000, identifier: "near") }
        if let marks = try? await CLGeocoder().geocodeAddressString(query, in: region) {
            hits += marks.compactMap { m in
                m.location.map { Hit(coord: Coord($0.coordinate), name: m.name ?? "", number: m.subThoroughfare,
                                     street: m.thoroughfare, locality: m.locality) }
            }
        }
        return hits
    }

    /// The spot for a house number + street near you (must have that house number and be within reach).
    private static func addressSpot(_ query: String, number: String, near: Coord?, inReach: (Coord) -> Bool) async -> Coord? {
        var found: [Coord] = []
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.resultTypes = .address
        if let near { req.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        if let resp = try? await MKLocalSearch(request: req).start() {
            found += resp.mapItems.filter { StoreText.numberMatches(card: number, place: $0.placemark.subThoroughfare) }
                .map { Coord($0.placemark.coordinate) }
        }
        if found.isEmpty {
            let region = near.map { CLCircularRegion(center: $0.cl, radius: 50_000, identifier: "near") }
            if let marks = try? await CLGeocoder().geocodeAddressString(query, in: region) {
                found += marks.filter { StoreText.numberMatches(card: number, place: $0.subThoroughfare) }
                    .compactMap { $0.location?.coordinate }.map { Coord($0) }
            }
        }
        let ok = found.filter(inReach)
        guard let near else { return ok.first }
        return ok.min { Geo.straightMiles(near, $0) < Geo.straightMiles(near, $1) }
    }

    /// The town at the end of "Partridge Ln & Pheasant Ln, East Setauket" -> "East Setauket".
    static func town(in text: String?) -> String? {
        guard let text, let last = text.split(separator: ",").last, text.contains(",") else { return nil }
        let t = last.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 ? t : nil
    }

    static func find(_ query: String?, near: Coord?) async -> Coord? {
        guard let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else { return nil }

        // Try the text as written, then easier versions of it.
        var attempts = [query]
        if query.contains("&") {
            let town = query.split(separator: ",").dropFirst().joined(separator: ",")
            let streets = (query.split(separator: ",").first.map(String.init) ?? query)
                .components(separatedBy: "&").map { $0.trimmingCharacters(in: .whitespaces) }
            attempts.append(query.replacingOccurrences(of: "&", with: "and"))
            attempts.append(query.replacingOccurrences(of: "&", with: "at"))
            for street in streets where !street.isEmpty {
                attempts.append(street + (town.isEmpty ? "" : "," + town)) // one street + town (approximate)
            }
        }

        for attempt in attempts {
            if let c = await search(attempt, near: near) { return c }
            if let c = await geocode(attempt, near: near) { return c }
        }
        return nil
    }

    /// Where two streets cross ("Pheasant Ln" + "Partridge Ln" near the store). Only accepts a match that is
    /// actually on one of those streets, never a town center or a whole-street guess.
    static func intersection(_ a: String, _ b: String, town: String?, near: Coord?) async -> Coord? {
        let suffix = town.map { ", \($0)" } ?? ""
        let cores = [StreetLabels.core(a), StreetLabels.core(b)]
        func onStreet(_ texts: [String?]) -> Bool {
            let all = texts.compactMap { $0?.lowercased() }.joined(separator: " ")
            return cores.contains { all.contains($0) }
        }
        for q in ["\(a) & \(b)\(suffix)", "\(a) and \(b)\(suffix)", "\(a) at \(b)\(suffix)"] {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            if let near { req.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
            if let resp = try? await MKLocalSearch(request: req).start() {
                let hits = resp.mapItems.filter { onStreet([$0.placemark.thoroughfare, $0.name]) }
                    .map { Coord($0.placemark.coordinate) }
                if let c = closest(hits, to: near) { return c }
            }
            let region = near.map { CLCircularRegion(center: $0.cl, radius: 50_000, identifier: "near") }
            if let marks = try? await CLGeocoder().geocodeAddressString(q, in: region) {
                let hits = marks.filter { onStreet([$0.thoroughfare, $0.name]) }
                    .compactMap { $0.location?.coordinate }.map { Coord($0) }
                    .filter { c in near.map { Geo.straightMiles($0, c) < 40 } ?? true }
                if let c = closest(hits, to: near) { return c }
            }
        }
        return nil
    }

    /// Every match for an address without a town ("54 Elderwood Lane") within 40 mi, so the caller can pick
    /// the right one using the map.
    static func candidates(_ query: String, near: Coord?) async -> [Coord] {
        var found: [Coord] = []
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.resultTypes = .address
        if let near { req.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
        if let resp = try? await MKLocalSearch(request: req).start() {
            found += resp.mapItems.map { Coord($0.placemark.coordinate) }
        }
        let region = near.map { CLCircularRegion(center: $0.cl, radius: 50_000, identifier: "near") }
        if let marks = try? await CLGeocoder().geocodeAddressString(query, in: region) {
            found += marks.compactMap { $0.location?.coordinate }.map { Coord($0) }
        }
        guard let near else { return found }
        return found.filter { Geo.straightMiles(near, $0) < 40 }
    }

    /// Is there a street with this name within about half a mile of `spot`? (Checks a zoomed map's street names
    /// against one of several "54 Elderwood Lane" matches.)
    static func streetNear(_ name: String, around spot: Coord, miles: Double = 0.6) async -> Bool {
        let want = StreetLabels.core(name)
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = name
        req.resultTypes = .address
        req.region = MKCoordinateRegion(center: spot.cl, latitudinalMeters: 2_500, longitudinalMeters: 2_500)
        guard let resp = try? await MKLocalSearch(request: req).start() else { return false }
        return resp.mapItems.contains { item in
            let text = [item.placemark.thoroughfare, item.name].compactMap { $0?.lowercased() }.joined(separator: " ")
            return text.contains(want) && Geo.straightMiles(spot, Coord(item.placemark.coordinate)) <= miles
        }
    }

    /// Apple Maps search (good for business names and addresses).
    private static func search(_ query: String, near: Coord?) async -> Coord? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let near {
            req.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        guard let resp = try? await MKLocalSearch(request: req).start() else { return nil }
        return closest(resp.mapItems.map { Coord($0.placemark.coordinate) }, to: near)
    }

    /// Address geocoder (sometimes better at intersections).
    private static func geocode(_ query: String, near: Coord?) async -> Coord? {
        let region = near.map { CLCircularRegion(center: $0.cl, radius: 50_000, identifier: "near") }
        guard let marks = try? await CLGeocoder().geocodeAddressString(query, in: region) else { return nil }
        let coords = marks.compactMap { $0.location?.coordinate }.map { Coord($0) }
        // Ignore matches far away (e.g. the same street name in another state).
        let nearby = near.map { n in coords.filter { Geo.straightMiles(n, $0) < 40 } } ?? coords
        return closest(nearby, to: near)
    }

    private static func closest(_ coords: [Coord], to near: Coord?) -> Coord? {
        guard let near else { return coords.first }
        return coords.min { Geo.straightMiles(near, $0) < Geo.straightMiles(near, $1) }
    }
}
