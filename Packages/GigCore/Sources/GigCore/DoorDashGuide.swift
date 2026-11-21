import Foundation

// Reads DoorDash's screens after you accept, for the 👓 button:
// - "Your route" (gear icon): every stop in order ("Wingstop - 3065 / Pickup • 10:41 PM", "Christina R / Drop off • 10:53 PM").
//   Tapping a stop opens a pop-up on the same screen with its full address.
// - The task screen: "Pick up by 10:41 PM" + store + address + who you're picking up for ("Kathleen P"),
//   or "Deliver by 11:07 PM" + customer + address + which store it's from ("Christina R / Taco Bell - 002698").
public enum DoorDashGuide {

    private static let typeLine = Rx(#"^(pickup|drop\s?off)\b[^0-9a-z]{0,5}\d{1,2}:\d{2}"#)
    private static let zip = Rx(#"\b\d{5}\b"#)
    /// DoorDash customer names have no period: "Kathleen P", "Sam C".
    private static let customer = Rx(#"^[A-Z][A-Za-z'\-]+(?:\s[A-Z][A-Za-z'\-]+)*\s[A-Z]\.?$"#, ci: false)
    private static let stopWords: Set<String> = ["inprogress", "yourroute", "mapbox", "currentdash", "copyaddress",
                                                 "leaveatdoor", "pickupinstore", "pickupatstore", "backtotask",
                                                 "switchtothistask", "navigate", "arrived", "call", "message",
                                                 "storenotes", "thisdash"]

    private static func norm(_ s: String) -> String { TripGuide.norm(s) }
    private static func isStop(_ s: String) -> Bool {
        let n = norm(s)
        return stopWords.contains(n) || n.hasSuffix("stopsremaining") || n.hasSuffix("stopremaining")
    }

    public static func isRouteScreen(_ lines: [OCRLine]) -> Bool {
        lines.contains { norm($0.text) == "yourroute" }
    }

    // MARK: "Your route" list and the stop pop-up

    public static func sections(_ lines: [OCRLine]) -> [GuideSection] {
        let ls = lines.filter { !TripGuide.isJunk($0.text) }
        var out: [GuideSection] = []
        for (i, l) in ls.enumerated() {
            guard let m = typeLine.first(TripGuide.clean(l.text)) else { continue }
            let type: StopType = (m.groups[1] ?? "").lowercased().hasPrefix("p") ? .pickup : .dropoff

            // Name: the line right above, plus the line above that only if it's a wrapped part of the
            // same name (close together). A map label further up is never part of it.
            var parts: [OCRLine] = []
            var j = i - 1
            while j >= 0, parts.count < 3 {
                let c = ls[j]
                let t = TripGuide.clean(c.text)
                if typeLine.first(t) != nil || isStop(t) { break }
                let ref = parts.first ?? l                   // the closest line below this one
                if let y0 = ref.y, let y1 = c.y, let h = ref.h ?? c.h {
                    if abs(y0 - y1) > 1.9 * h { break }       // too far above: a different thing
                } else if !parts.isEmpty {
                    break                                    // no positions: take one line only
                }
                parts.insert(c, at: 0)
                j -= 1
            }
            let name = joinRows(parts)
            guard !name.isEmpty else { continue }

            // Address (pop-up only): lines right below, starting with a number or "#", up to the zip.
            var addr: [String] = []
            var k = i + 1
            while k < ls.count, addr.count < 4 {
                let t = TripGuide.clean(ls[k].text)
                if addr.isEmpty, t.first?.isNumber != true { break }
                if typeLine.first(t) != nil || isStop(t) { break }
                addr.append(t)
                if zip.first(t) != nil { break }
                k += 1
            }
            let address = (addr.last.map { zip.first($0) != nil } ?? false)
                ? TripGuide.fixHouseNumber(TripGuide.joinAddress(mergeUnit(addr))) : nil
            out.append(GuideSection(type: type, name: name, orders: 1, address: address))
        }
        return out
    }

    /// Lines that sit on the same row (split by OCR) are joined left to right; rows top to bottom.
    static func joinRows(_ parts: [OCRLine]) -> String {
        var rows: [[OCRLine]] = []
        for p in parts {
            if let last = rows.last?.first, let y0 = last.y, let y1 = p.y, let h = last.h ?? p.h, abs(y0 - y1) < 0.5 * h {
                rows[rows.count - 1].append(p)
            } else {
                rows.append([p])
            }
        }
        return rows.map { row in
            row.sorted { ($0.x ?? 0) < ($1.x ?? 0) }.map { TripGuide.clean($0.text) }.joined(separator: " ")
        }.joined(separator: " ")
    }

    /// "4747 Nesconset Hwy" + "# Unit7" -> "4747 Nesconset Hwy # Unit7" (a unit line belongs to the street line).
    static func mergeUnit(_ parts: [String]) -> [String] {
        var out: [String] = []
        for p in parts {
            if p.hasPrefix("#"), let last = out.popLast() { out.append(last + " " + p) } else { out.append(p) }
        }
        return out
    }

    // MARK: Task screen ("Pick up by …" / "Deliver by …")

    public struct Task: Equatable {
        public var link: PickupScreen?          // store -> customers (who's picked up where)
        public var name: String                 // the store or customer this screen is about
        public var address: String?
    }

    public static func taskScreen(_ lines: [OCRLine], at date: Date = Date()) -> Task? {
        let ls = lines.filter { !TripGuide.isJunk($0.text) }
        let texts = ls.map { TripGuide.clean($0.text) }
        if let p = texts.firstIndex(where: { $0.lowercased().hasPrefix("pick up by") }) {
            // Store name (may wrap), address up to the zip, then the customers under "Pick up at store".
            var nameParts: [OCRLine] = []
            var i = p + 1
            while i < texts.count, texts[i].first?.isNumber != true, !isStop(texts[i]), nameParts.count < 3 {
                nameParts.append(ls[i]); i += 1
            }
            let (address, next) = readAddress(texts, from: i)
            let store = joinRows(nameParts)
            guard !store.isEmpty else { return nil }
            var customers: [String] = []
            if let at = texts[next...].firstIndex(where: { norm($0) == "pickupatstore" }) {
                customers = texts[(at + 1)...].filter { customer.first($0) != nil }
            }
            return Task(link: customers.isEmpty ? nil : PickupScreen(store: store, address: address, customers: customers, seenAt: date),
                        name: store, address: address)
        }
        if let d = texts.firstIndex(where: { $0.lowercased().hasPrefix("deliver by") }), d + 1 < texts.count {
            let name = texts[d + 1]
            guard customer.first(name) != nil else { return nil } // (an offer card also says "Deliver by")
            var i = d + 2
            while i < texts.count, texts[i].first?.isNumber != true, i < d + 5 { i += 1 } // skip Call / Message
            let (address, next) = readAddress(texts, from: i)
            // Further down: the order card repeats the name, then the store it's from.
            var link: PickupScreen?
            if let again = texts[next...].firstIndex(where: { norm($0) == norm(name) }), again + 1 < texts.count {
                let store = texts[again + 1]
                if !isStop(store), customer.first(store) == nil {
                    link = PickupScreen(store: store, address: nil, customers: [name], seenAt: date)
                }
            }
            return Task(link: link, name: name, address: address)
        }
        return nil
    }

    private static func readAddress(_ texts: [String], from start: Int) -> (String?, Int) {
        var parts: [String] = []
        var i = start
        while i < texts.count, parts.count < 4 {
            let t = texts[i]
            if parts.isEmpty, t.first?.isNumber != true { break }
            parts.append(t); i += 1
            if zip.first(t) != nil {
                return (TripGuide.fixHouseNumber(TripGuide.joinAddress(mergeUnit(parts))), i)
            }
        }
        return (nil, start)
    }
}
