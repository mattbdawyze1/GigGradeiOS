import Foundation

/// Reads street names printed on an offer map (e.g. after you zoom in on the customer pin)
/// and picks the ones closest to that pin, so the pin can be placed at their intersection.
public enum StreetLabels {

    private static let suffix = Rx(#"\b(st|street|ave|avenue|av|rd|road|dr|drive|ln|lane|blvd|boulevard|way|ct|court|pl|place|pkwy|parkway|hwy|highway|ter|terrace|cir|circle|trl|trail|pike|tpke|turnpike|sq|square|expy|expressway|fwy|freeway|loop|row|walk|crossing|path|run|plz|plaza|blvd\.)\.?$"#)
    private static let numbered = Rx(#"^(\d+(st|nd|rd|th)\b|(route|rte|county road|cr|us|i|sr|nj|ny|ca|tx|fl|pa)[ -]?\d+[a-z]?\b)"#)
    private static let houseNumber = Rx(#"^\d+[a-z]?\s+[a-z]"#)
    private static let noise = Rx(#"\$|\d\s?(mi|min|mins)\b|\baccept|\bdecline|\bdeliver|\bpickup\b|\bdropoff\b|\bstops?\b|guaranteed|\bincl\b|\btips?\b|%"#)
    private static let endings: Set<String> = [
        "st", "street", "ave", "avenue", "av", "rd", "road", "dr", "drive", "ln", "lane", "blvd", "boulevard",
        "way", "ct", "court", "pl", "place", "pkwy", "parkway", "hwy", "highway", "ter", "terrace", "cir",
        "circle", "trl", "trail", "pike", "tpke", "turnpike", "sq", "square", "expy", "expressway", "fwy",
        "freeway", "loop", "row", "walk", "crossing", "path", "run", "plz", "plaza",
        "n", "s", "e", "w", "north", "south", "east", "west"
    ]

    /// "Pheasant Ln", "5th Ave", "Route 25A", "NY-347" → true. Addresses ("12 Main St"), prices, buttons → false.
    public static func isStreetName(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4, t.count <= 32, !t.contains(","), !t.contains("&") else { return false }
        if noise.first(t) != nil { return false }
        if numbered.first(t) != nil { return true }
        if houseNumber.first(t) != nil { return false } // a street address, not a map label
        return suffix.first(t) != nil && t.split(separator: " ").count >= 2
    }

    /// The distinctive part of a street name, for matching ("Pheasant Ln" → "pheasant", "5th Ave" → "5th").
    public static func core(_ name: String) -> String {
        let words = name.lowercased().replacingOccurrences(of: ".", with: "")
            .split(separator: " ").map(String.init)
        let kept = words.filter { !endings.contains($0) }
        return (kept.first ?? words.first ?? name.lowercased())
    }

    /// Up to `limit` different street names, closest to `point` first.
    public static func nearest(lines: [OCRLine], to point: MapPins.Point, limit: Int = 2) -> [String] {
        let found = lines.compactMap { l -> (name: String, d: Double)? in
            guard let x = l.x, let y = l.y, isStreetName(l.text) else { return nil }
            return (l.text.trimmingCharacters(in: .whitespaces), ((x - point.x) * (x - point.x) + (y - point.y) * (y - point.y)).squareRoot())
        }
        .sorted { $0.d < $1.d }

        var names: [String] = []
        var cores = Set<String>()
        for f in found where !cores.contains(core(f.name)) {
            cores.insert(core(f.name))
            names.append(f.name)
            if names.count == limit { break }
        }
        return names
    }

    /// The customer pin to place: the only one, or (with several) the one farthest from the store pin.
    public static func finalCustomer(_ pins: MapPins) -> MapPins.Point? {
        guard pins.customers.count > 1, let store = pins.stores.first else { return pins.customers.first }
        return pins.customers.max { dist2($0, store) < dist2($1, store) }
    }

    private static func dist2(_ a: MapPins.Point, _ b: MapPins.Point) -> Double {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }

    /// Is a dropoff this far away believable for an offer with these miles? (Offer miles include the drive to the store.)
    public static func plausible(dropoff: Coord, pickup: Coord?, me: Coord?, statedMiles: Double?) -> Bool {
        guard let miles = statedMiles, miles > 0 else { return true }
        if let pickup { return Geo.straightMiles(pickup, dropoff) <= miles + 0.5 }
        if let me { return Geo.straightMiles(me, dropoff) <= miles + 1.0 }
        return true
    }
}
