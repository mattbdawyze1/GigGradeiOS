import Foundation

/// Uber store line → name and (partial) address, plus the checks used to accept or reject a map search result
/// (5.9.6.3). "Wingstop (4747 Nesconset Hwy)" → name "Wingstop", number "4747", street "Nesconset Hwy".
public enum StoreText {
    public struct Parts: Equatable {
        public var name: String
        public var number: String?   // house number
        public var street: String?   // street after the number
        public var town: String? = nil // "Shahs Halal Food (Selden)" -> "Selden"
        public var hasAddress: Bool { number != nil && street != nil }
        public var address: String? { hasAddress ? "\(number!) \(street!)" : nil }
    }

    /// Removes what the screen reader picks up from Uber's little route icon (o, °, •, |, ○, □ …) before the name.
    public static func clean(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        let junk = Set(["o", "O", "0", "°", "•", "·", "|", "○", "◦", "□", "▢", "◻", "ㅇ", "8", "e", "-", "—", "‹", "<", "»"])
        // Only icon look-alikes and lone symbols go; a real one-letter word ("A Taste of Thai") stays.
        while let first = words.first, words.count > 1,
              junk.contains(first) || (first.count == 1 && !first.first!.isLetter && !first.first!.isNumber) {
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    /// Splits off a house number + street. Uber's parentheses were already turned into spaces by the parser.
    public static func split(_ raw: String) -> Parts {
        var p = splitAddress(raw)
        // 5.9.6.11, from your Issues log. "Bango - Happauge", "Ditch - Port Jefferson 140 Main Street": the part after
        // " - " is where the store is. "LOWE'S OF STONY BROOK", "MEET NOODLE OF STONYBROOK": the town follows a capital OF.
        if p.town == nil {
            for sep in [" - ", " OF "] {
                guard let r = p.name.range(of: sep) else { continue }
                let left = p.name[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                let right = p.name[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ."))
                if !left.isEmpty, right.count >= 3, right.first?.isLetter == true {
                    p.name = left; p.town = right
                    break
                }
            }
        }
        return p
    }

    static func splitAddress(_ raw: String) -> Parts {
        // ", NY" at the end is the state, not a town ("Naz's Halal Food, Brentwood, NY", "LOWE'S OF COMMACK, NY").
        var raw = raw
        if let rx = try? NSRegularExpression(pattern: #",\s*[A-Z]{2}\.?\s*$"#) {
            raw = rx.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
        }
        let text = clean(raw).replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
        let words = text.split(separator: " ").map(String.init)
        for (i, w) in words.enumerated() where i > 0 {
            let fixed = fixDigits(w)
            guard fixed.count >= 1, fixed.count <= 6, fixed.allSatisfy(\.isNumber), i + 1 < words.count,
                  words[i + 1].first?.isLetter == true else { continue }
            // Street = words after the number, up to a comma / store ID ("NY - 1330").
            var street: [String] = []
            for s in words[(i + 1)...] {
                // "Route 111", "Hwy 25A": a number right after a route word is part of the street.
                if let last = street.last?.lowercased(), ["route", "rte", "rt", "hwy", "highway", "cr"].contains(last),
                   s.first?.isNumber == true {
                    street.append(s.trimmingCharacters(in: CharacterSet(charactersIn: ",.")))
                    continue
                }
                if s == "-" || s.allSatisfy(\.isNumber) { break }
                if s.count == 2, s == s.uppercased(), s.allSatisfy(\.isLetter), !street.isEmpty,
                   !streetWords.contains(s.lowercased()) { break } // state code
                street.append(s.trimmingCharacters(in: CharacterSet(charactersIn: ",.")))
                if s.hasSuffix(",") { break }
            }
            let name = words[..<i].joined(separator: " ")
            guard !name.isEmpty, !street.isEmpty else { continue }
            // "Pizza 2 Go" is a name, not an address: a 1-digit number needs a street word (St, Rd, Hwy…).
            guard fixed.count >= 2 || street.contains(where: { streetWords.contains($0.lowercased()) }) else { continue }
            return Parts(name: name, number: fixed, street: street.joined(separator: " "))
        }
        // No address: "Shahs Halal Food, Selden" (the parser turns "(Selden)" into ", Selden").
        let plain = text.split(separator: " ").joined(separator: " ")
        if let comma = plain.firstIndex(of: ",") {
            let name = plain[..<comma].trimmingCharacters(in: .whitespaces)
            let town = plain[plain.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, town.count >= 3 { return Parts(name: name, number: nil, street: nil, town: town) }
        }
        return Parts(name: plain, number: nil, street: nil)
    }

    /// "Fireside Ln & Lodge Ln, East Setauket" yes; "Ben & Jerry's" no (no street word or town after the "&").
    public static func looksLikeCrossStreets(_ raw: String) -> Bool {
        // A store's address in parentheses doesn't count: "Tex's Chicken & Burgers (272 E Main St)".
        let line = raw.replacingOccurrences(of: #"\([^)]*\)?"#, with: " ", options: .regularExpression)
        guard let amp = line.firstIndex(of: "&") else { return false }
        let after = line[line.index(after: amp)...]
        if after.contains(",") { return true }
        return tokens(String(after)).contains { streetWords.contains(streetAbbrev[$0] ?? $0) }
    }

    /// Is a search result on one of the card's streets? ("Barker Dr & Bucknell Ln" vs "Bucknell Lane")
    public static func onStreets(card: String, place: String?) -> Bool {
        guard let place else { return false }
        let streets = (card.split(separator: ",").first.map(String.init) ?? card).components(separatedBy: "&")
        return streets.contains { streetMatches(card: $0, place: place) }
    }

    /// Same town? ("Port Jefferson Station" vs "Port Jefferson Sta.") Compares the words, ignoring case.
    public static func sameTown(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let x = tokens(a).map { $0 == "sta" ? "station" : $0 }, y = tokens(b).map { $0 == "sta" ? "station" : $0 }
        return !x.isEmpty && x == y
    }

    /// Common reading slips inside house numbers: l/I → 1, O → 0.
    public static func fixDigits(_ w: String) -> String {
        let t = w.trimmingCharacters(in: CharacterSet(charactersIn: ",.#"))
        guard t.contains(where: \.isNumber) else { return t }
        return String(t.map { c -> Character in
            switch c { case "l", "I", "|": return "1"; case "O", "o": return "0"; default: return c }
        })
    }

    // MARK: Matching search results

    static let filler: Set<String> = ["the", "and", "&", "of", "restaurant", "inc", "llc", "co", "store", "shop", "nyc", "ny"]
    static let streetWords: Set<String> = ["st", "rd", "ave", "hwy", "blvd", "dr", "ln", "ct", "pl", "pkwy", "tpke", "way", "sq",
                                            "path", "ter", "cir", "trl", "loop", "run", "xing", "aly"]

    static func tokens(_ s: String) -> [String] {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "®", with: "").replacingOccurrences(of: "™", with: "")
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && !filler.contains($0) }
    }

    /// Does a search result's name match the store's name? Every word of the card's name must be in the result's
    /// name (plurals allowed; one word may be missing for names of 3+ words). "Sizzlin' Chicken" ≠ "Chicken Shack",
    /// "Wingstop" ≠ "Wing Zone". Spacing differences are fine: "PJ Sushi" = "P J Sushi".
    public static func nameMatches(card: String, place: String) -> Bool {
        // Store numbers don't count: "IHOP 3806", "HOME DEPOT 1265" (5.9.6.11).
        let allCard = tokens(card)
        let a = allCard.filter { !$0.allSatisfy(\.isNumber) }.isEmpty ? allCard : allCard.filter { !$0.allSatisfy(\.isNumber) }
        let placeTokens = tokens(place).filter { !$0.allSatisfy(\.isNumber) }
        let b = Set(placeTokens)
        guard !a.isEmpty, !b.isEmpty else { return false }
        func same(_ x: String, _ y: String) -> Bool { x == y || x == y + "s" || y == x + "s" }
        if a.joined() == placeTokens.joined() { return true }
        let hits = a.filter { w in b.contains { same($0, w) } }.count
        if hits == a.count || (a.count >= 3 && hits >= a.count - 1) { return true }
        // Apple's listing is a shorter name that appears in the card's name: "Starbucks Stony Brook 347" = "Starbucks",
        // "Central Pizza & Italian Restaurant" = "Central Pizza". Not for a single generic word ("Sushi", "Pizza").
        let distinctive = placeTokens.count >= 2 || (placeTokens.count == 1 && placeTokens[0].count >= 5
                                                     && !genericWords.contains(placeTokens[0]))
        return distinctive && placeTokens.allSatisfy { w in a.contains { same($0, w) } }
    }

    static let genericWords: Set<String> = ["pizza", "pizzeria", "sushi", "deli", "cafe", "grill", "bagel", "bagels",
        "bakery", "chinese", "thai", "kitchen", "diner", "market", "burger", "burgers", "tacos", "taco", "wings", "halal",
        "food", "foods", "express", "coffee", "bistro", "pasta", "chicken", "steak", "seafood", "noodle", "noodles"]

    static let streetAbbrev: [String: String] = [
        "street": "st", "road": "rd", "avenue": "ave", "highway": "hwy", "boulevard": "blvd", "drive": "dr",
        "lane": "ln", "court": "ct", "place": "pl", "parkway": "pkwy", "turnpike": "tpke", "route": "rte",
        "terrace": "ter", "circle": "cir", "trail": "trl", "crossing": "xing", "alley": "aly",
        "north": "n", "south": "s", "east": "e", "west": "w",
    ]

    static func streetKey(_ s: String) -> [String] {
        tokens(s).map { streetAbbrev[$0] ?? $0 }.filter { !["n", "s", "e", "w"].contains($0) }
    }

    /// Same street? Compares the street's main name ("nesconset" in "Nesconset Hwy" / "Nesconset Highway").
    public static func streetMatches(card: String, place: String?) -> Bool {
        guard let place else { return false }
        let a = streetKey(card), b = streetKey(place)
        guard let main = a.first(where: { !streetWords.contains($0) && $0 != "rte" }) ?? a.first else { return false }
        return b.contains(main)
    }

    public static func numberMatches(card: String, place: String?) -> Bool {
        guard let place else { return false }
        return fixDigits(place) == fixDigits(card)
    }
}
