import Foundation
import MapKit
import GigCore

extension Coord {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
    init(_ c: CLLocationCoordinate2D) { self.init(lat: c.latitude, lng: c.longitude) }
}

/// Finds an address OR a business name ("Chipotle") near you, using Apple Maps search.
enum PlaceFinder {
    /// "Halsey St, Port Jefferson Station" for a map spot.
    static func describe(_ c: Coord) async -> String? {
        guard let p = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.lat, longitude: c.lng)).first
        else { return nil }
        let parts = [p.thoroughfare, p.subLocality ?? p.locality].compactMap { $0 }
        return parts.isEmpty ? p.name : parts.joined(separator: ", ")
    }

    static func find(_ query: String?, near: Coord?) async -> Coord? {
        guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let near {
            req.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        var found = try? await MKLocalSearch(request: req).start()
        if found == nil, query.contains("&") {
            // Cross streets ("Garden Ct & School Dr, Town"): try "and", then the first street + town.
            req.naturalLanguageQuery = query.replacingOccurrences(of: "&", with: "and")
            found = try? await MKLocalSearch(request: req).start()
            if found == nil {
                let town = query.split(separator: ",").dropFirst().joined(separator: ",")
                let firstStreet = query.split(separator: "&").first.map(String.init) ?? query
                req.naturalLanguageQuery = firstStreet + (town.isEmpty ? "" : "," + town)
                found = try? await MKLocalSearch(request: req).start()
            }
        }
        guard let resp = found else { return nil }
        let coords = resp.mapItems.map { Coord($0.placemark.coordinate) }
        if let near {
            return coords.min { Geo.straightMiles(near, $0) < Geo.straightMiles(near, $1) }
        }
        return coords.first
    }
}
