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
