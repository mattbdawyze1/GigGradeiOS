import Foundation
import MapKit
import GigCore

extension Coord {
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lng) }
    init(_ c: CLLocationCoordinate2D) { self.init(lat: c.latitude, lng: c.longitude) }
}

/// Finds an address OR a business name ("Chipotle") near you, using Apple Maps search.
enum PlaceFinder {
    static func find(_ query: String?, near: Coord?) async -> Coord? {
        guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let near {
            req.region = MKCoordinateRegion(center: near.cl, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        guard let resp = try? await MKLocalSearch(request: req).start() else { return nil }
        let coords = resp.mapItems.map { Coord($0.placemark.coordinate) }
        if let near {
            return coords.min { Geo.straightMiles(near, $0) < Geo.straightMiles(near, $1) }
        }
        return coords.first
    }
}
