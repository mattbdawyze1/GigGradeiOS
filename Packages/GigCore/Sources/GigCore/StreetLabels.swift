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

    // MARK: Address bubble (tap the customer pin on DoorDash's map: "54 Elderwood Lane")

    private static let houseAddress = Rx(#"^\d{1,6}[a-z]?\s+[a-z0-9]"#)

    /// "54 Elderwood Lane" → true. Card addresses have commas ("110 Commack Road, Commack, 11725 NY") → false.
    public static func isHouseAddress(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 6, t.count <= 40, !t.contains(","), houseAddress.first(t) != nil else { return false }
        if noise.first(t) != nil { return false }
        let rest = t.split(separator: " ").dropFirst().joined(separator: " ")
        return suffix.first(rest) != nil || numbered.first(rest) != nil
    }

    /// The address bubble on the map, if one is showing (it sits above the card, so it has a screen position).
    public static func popupAddress(_ lines: [OCRLine]) -> OCRLine? {
        lines.first { $0.x != nil && $0.y != nil && isHouseAddress($0.text) }
    }

    /// The customer pin the bubble belongs to: the closest one just below it.
    public static func pin(under popup: OCRLine, in pins: MapPins) -> MapPins.Point? {
        guard let px = popup.x, let py = popup.y else { return nil }
        return pins.customers
            .filter { $0.y > py }
            .min { abs($0.x - px) + ($0.y - py) < abs($1.x - px) + ($1.y - py) }
    }

    // MARK: Several matches for the same address

    /// Matches closer than this are the same place (Apple Maps and the geocoder often both return it).
    public static func distinctPlaces(_ coords: [Coord], within miles: Double = 0.3) -> [Coord] {
        var out: [Coord] = []
        for c in coords where !out.contains(where: { Geo.straightMiles($0, c) < miles }) { out.append(c) }
        return out
    }

    /// Street names printed near the tapped pin, minus the customer's own street (every match has that one).
    public static func neighbors(lines: [OCRLine], near point: MapPins.Point, excluding address: String,
                                 limit: Int = 4) -> [String] {
        let own = core(address.split(separator: " ").dropFirst().joined(separator: " "))
        return nearest(lines: lines, to: point, limit: limit + 1).filter { core($0) != own }.prefix(limit).map { $0 }
    }

    /// Index of the match with the most nearby streets in common; nil when no match clearly wins.
    public static func bestByNeighbors(_ counts: [Int]) -> Int? {
        guard let top = counts.max(), top > 0, counts.filter({ $0 == top }).count == 1 else { return nil }
        return counts.firstIndex(of: top)
    }

    /// Is a dropoff this far away believable for an offer with these miles? (Offer miles include the drive to the store.)
    public static func plausible(dropoff: Coord, pickup: Coord?, me: Coord?, statedMiles: Double?) -> Bool {
        guard let miles = statedMiles, miles > 0 else { return true }
        if let pickup { return Geo.straightMiles(pickup, dropoff) <= miles + 0.5 }
        if let me { return Geo.straightMiles(me, dropoff) <= miles + 1.0 }
        return true
    }
}
