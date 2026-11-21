import Foundation

// Reads Uber's "Trip Guide" (the list of stops in the order Uber wants you to make them) and Uber's
// pickup screen ("Pick up 1 order" + who you're picking up for), so the 👓 button can put every stop
// into the Route tab with pickups linked to their dropoffs.

/// One stop in the Trip Guide.
public struct GuideSection: Codable, Equatable {
    public var type: StopType
    public var name: String          // "Chipotle Mexican Grill" / "Kevin D."
    public var orders: Int           // "Pickup • 2 orders" -> 2
    public var address: String?      // only when the section was expanded: "27 Virgil Dr, Brentwood, NY"

    public init(type: StopType, name: String, orders: Int = 1, address: String? = nil) {
        self.type = type; self.name = name; self.orders = orders; self.address = address
    }

    public var key: String { "\(type == .pickup ? "P" : "D")|\(TripGuide.norm(name))" }
}

/// Uber's pickup screen: the store you're headed to and who the orders are for.
public struct PickupScreen: Codable, Equatable {
    public var store: String
    public var address: String?
    public var customers: [String]
    public var seenAt: Date

    public init(store: String, address: String?, customers: [String], seenAt: Date) {
        self.store = store; self.address = address; self.customers = customers; self.seenAt = seenAt
    }
}

/// Everything collected while you looked at Uber's screens (sent from the screen reader to the app).
public struct GuideSnapshot: Codable, Equatable {
    public var seenAt: Date
    public var sections: [GuideSection]
    public var pickupScreens: [PickupScreen]
    public var requestId: String?    // the 👓 press this reading answers
    public var complete: Bool?       // true once you left the Trip Guide (or the request timed out)

    public init(seenAt: Date, sections: [GuideSection], pickupScreens: [PickupScreen],
                requestId: String? = nil, complete: Bool? = nil) {
        self.seenAt = seenAt; self.sections = sections; self.pickupScreens = pickupScreens
        self.requestId = requestId; self.complete = complete
    }
}

/// A 👓 press: "read the Trip Guide now" (sent from the app to the screen reader).
public struct GuideRequest: Codable, Equatable {
    public var id: String
    public var armedAt: Date
    public var recordId: String

    public init(id: String = UUID().uuidString, armedAt: Date = Date(), recordId: String) {
        self.id = id; self.armedAt = armedAt; self.recordId = recordId
    }
}

public enum TripGuide {

    // OCR often reads the "1" in "· 1 order" as "l" or "I", and the dot as "·", ":" or nothing.
    private static let header = Rx(#"^(pickup|dropoff)\b[^0-9a-z]{0,4}([0-9li]+)\s*orders?\b"#)
    private static let pickUpN = Rx(#"^pick\s*up\s+([0-9li]+)\s+orders?$"#)
    private static let customer = Rx(#"^[A-Z][A-Za-z'\-]+(?:\s[A-Z][A-Za-z'\-]+)*\s[A-Z]\.$"#, ci: false)
    private static let zip = Rx(#"\b\d{5}\b"#)
    private static let minutesOrMiles = Rx(#"^\d+(\.\d+)?\s*(min|mi)\b"#)
    private static let clock = Rx(#"^\d{1,2}:\d{2}"#)
    /// Buttons and labels (compared without spaces/punctuation: OCR reads "STOP NEWREQUESTS" too).
    private static let noiseWords: Set<String> = ["viewdetails", "waybill", "stopnewrequests", "address",
                                                  "verify", "helpandsupport", "completepickup", "tripguide"]
    static func isNoise(_ s: String) -> Bool { noiseWords.contains(norm(s)) }

    /// Lowercase letters and digits only, for comparing names ("Chick-fil-A" == "chickfila").
    public static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Stray glyphs (chevrons, the side tab, icons) read as text: fewer than 2 letters/digits.
    static func isJunk(_ s: String) -> Bool { norm(s).count < 2 }

    public static func isTripGuide(_ lines: [OCRLine]) -> Bool {
        lines.contains { norm($0.text) == "tripguide" }
    }

    // MARK: Trip Guide screen

    /// The sections visible on one Trip Guide screen, top to bottom.
    /// Lines above the first "Pickup • / Dropoff •" header (the tail of a section scrolled off the top) are skipped.
    /// An address only counts when it's complete (followed by "View details").
    public static func sections(_ lines: [OCRLine]) -> [GuideSection] {
        let texts = lines.map { clean($0.text) }.filter { !isJunk($0) }
        var out: [GuideSection] = []
        var i = 0
        while i < texts.count {
            guard let m = header.first(texts[i]) else { i += 1; continue }
            let type: StopType = (m.groups[1] ?? "").lowercased().hasPrefix("p") ? .pickup : .dropoff
            let orders = Int(digits(m.groups[2] ?? "1")) ?? 1
            i += 1

            // Name: one or more lines until "Expected by", "Address", the next header or a button.
            var nameParts: [String] = []
            while i < texts.count {
                let t = texts[i], low = t.lowercased()
                if low.hasPrefix("expected by") || low == "address" || header.first(t) != nil
                    || isNoise(t) || low.hasSuffix("stop left") || low.hasSuffix("stops left") { break }
                nameParts.append(t); i += 1
            }
            if i < texts.count, texts[i].lowercased().hasPrefix("expected by") { i += 1 }

            // Address (expanded sections only): lines between "Address" and "View details".
            var address: String?
            if i < texts.count, texts[i].lowercased() == "address" {
                i += 1
                var parts: [String] = []
                var complete = false
                while i < texts.count {
                    let t = texts[i], low = t.lowercased()
                    if low == "view details" { complete = true; i += 1; break }
                    if header.first(t) != nil || isNoise(t) { break }
                    parts.append(t); i += 1
                }
                if complete, !parts.isEmpty { address = fixHouseNumber(joinAddress(parts)) }
            }

            let name = nameParts.joined(separator: " ")
            if !name.isEmpty { out.append(GuideSection(type: type, name: name, orders: orders, address: address)) }
        }
        return out
    }

    /// OCR mix-ups in numbers: "l40l" -> "1401", "17Ol" -> "1701".
    static func digits(_ s: String) -> String {
        String(s.map { c -> Character in
            switch c {
            case "l", "I", "i", "|": return "1"
            case "O", "o": return "0"
            default: return c
            }
        })
    }

    /// Fixes the house number at the start of an address ("l40l Brook Ave" -> "1401 Brook Ave").
    static func fixHouseNumber(_ address: String) -> String {
        guard let first = address.split(separator: " ").first else { return address }
        let token = String(first)
        guard token.contains(where: { $0.isNumber }),
              token.allSatisfy({ $0.isNumber || "lIiOo|".contains($0) || $0.isUppercase }) else { return address }
        // Keep a trailing unit letter ("221B"), fix the rest.
        var fixed = digits(token)
        if let last = token.last, last.isUppercase, !"IO".contains(last) { fixed = digits(String(token.dropLast())) + String(last) }
        return fixed + address.dropFirst(token.count)
    }

    /// "294 Cass St" + "Dix Hills, NY" -> "294 Cass St, Dix Hills, NY"; "…, Bay Shore," + "NY 11706" -> "…, Bay Shore, NY 11706".
    static func joinAddress(_ parts: [String]) -> String {
        var s = ""
        for p in parts {
            if s.isEmpty { s = p }
            else if s.hasSuffix(",") { s += " " + p }
            else { s += ", " + p }
        }
        return s
    }

    /// Adds one screen's sections to everything seen so far in this viewing session, keeping Uber's order.
    /// Sections already known get their address filled in when this screen shows it expanded.
    public static func merge(_ known: [GuideSection], with screen: [GuideSection]) -> [GuideSection] {
        var all = known
        // Where does this screen sit in the full list? Anchor on the first section we already know.
        var cursor: Int? = nil
        if let firstKnown = screen.firstIndex(where: { s in all.contains { $0.key == s.key } }) {
            let anchor = all.firstIndex { $0.key == screen[firstKnown].key }!
            // Sections above the anchor on this screen go just above it.
            for s in screen[..<firstKnown].reversed() where !all.contains(where: { $0.key == s.key }) {
                all.insert(s, at: anchor)
            }
            cursor = (all.firstIndex { $0.key == screen[firstKnown].key }!) - 1
        }
        for s in screen {
            if let at = all.firstIndex(where: { $0.key == s.key }) {
                if all[at].address == nil, let a = s.address { all[at].address = a }
                if s.orders > all[at].orders { all[at].orders = s.orders }
                cursor = at
            } else if let c = cursor {
                all.insert(s, at: c + 1)
                cursor = c + 1
            } else {
                all.append(s)
                cursor = all.count - 1
            }
        }
        return all
    }

    // MARK: Pickup screen ("Pick up 1 order")

    public static func pickupScreen(_ lines: [OCRLine], at date: Date = Date()) -> PickupScreen? {
        let texts = lines.map { clean($0.text) }.filter { !isJunk($0) }
        guard let p = texts.firstIndex(where: { pickUpN.first($0) != nil }) else { return nil }

        // Above "Pick up N order": the time/miles bar ("14 min", "6.0 mi"), the store name, then the
        // address (ends with the zip). Start after the bar so the clock and map labels up top are skipped.
        let barEnd = texts[..<p].lastIndex(where: { minutesOrMiles.first($0) != nil }).map { $0 + 1 } ?? 0
        var nameParts: [String] = []
        var addrParts: [String] = []
        var inAddress = false
        for t in texts[barEnd..<p] {
            if clock.first(t) != nil { continue }
            let low = t.lowercased()
            if low.hasPrefix("merchant note") || low.hasPrefix("note:") { break }
            if minutesOrMiles.first(t) != nil || norm(t) == "tripguide" { continue }
            if !inAddress, t.first?.isNumber == true { inAddress = true }
            if inAddress {
                addrParts.append(t)
                if zip.first(t) != nil { break }
            } else {
                nameParts.append(t)
            }
        }
        let store = nameParts.joined(separator: " ")
        guard !store.isEmpty else { return nil }

        // Below: one card per order, each starting with the customer's name ("Kevin D.").
        let customers = texts[(p + 1)...].filter { customer.first($0) != nil }
        return PickupScreen(store: store, address: addrParts.isEmpty ? nil : fixHouseNumber(joinAddress(addrParts)),
                            customers: customers, seenAt: date)
    }

    // MARK: Linking

    public enum Link: Equatable {
        case pickup(Int)        // index of the pickup section in the Trip Guide
        case store(String)      // a store already picked up / not in the guide (from the pickup screen)
    }

    /// Which pickup each dropoff belongs to.
    /// 1) Uber's pickup screen says so ("Pick up 1 order · Kevin D." at Chipotle).
    /// 2) Otherwise the earliest pickup above it that still has an order left (Uber lists them first-in, first-out).
    /// Dropoffs with no pickup above them are left unlinked (food already in your car).
    public static func links(_ sections: [GuideSection], pickupScreens: [PickupScreen]) -> [Link?] {
        var result = [Link?](repeating: nil, count: sections.count)
        var left = sections.map { $0.type == .pickup ? max(1, $0.orders) : 0 }
        var settled = Set<Int>()

        func sameName(_ a: String, _ b: String) -> Bool {
            let x = norm(a), y = norm(b)
            return !x.isEmpty && !y.isEmpty && (x == y || x.contains(y) || y.contains(x))
        }

        for (d, s) in sections.enumerated() where s.type == .dropoff {
            guard let screen = pickupScreens.last(where: { ps in ps.customers.contains { sameName($0, s.name) } })
            else { continue }
            if let p = sections.indices.first(where: { $0 < d && sections[$0].type == .pickup && sameName(sections[$0].name, screen.store) }) {
                result[d] = .pickup(p)
                left[p] -= max(1, s.orders)
            } else {
                result[d] = .store(screen.store) // its pickup isn't waiting in the guide
            }
            settled.insert(d)
        }

        for (d, s) in sections.enumerated() where s.type == .dropoff && !settled.contains(d) {
            if let p = sections.indices.first(where: { $0 < d && sections[$0].type == .pickup && left[$0] > 0 }) {
                result[d] = .pickup(p)
                left[p] -= max(1, s.orders)
            }
        }
        for (p, s) in sections.enumerated() where s.type == .pickup { result[p] = .pickup(p) }
        return result
    }

    /// "27 Virgil Dr, Brentwood, NY" -> "27 virgil" (house number + first street word), for spotting a stop
    /// that's already in your route even when it was typed a little differently.
    public static func addressKey(_ text: String) -> String? {
        let words = text.lowercased().replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").map(String.init)
        guard let i = words.firstIndex(where: { $0.first?.isNumber == true }), i + 1 < words.count else { return nil }
        return "\(words[i]) \(words[i + 1])"
    }
}
