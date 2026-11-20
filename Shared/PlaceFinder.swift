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
