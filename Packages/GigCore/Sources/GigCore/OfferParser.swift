import Foundation

/// Small wrapper around NSRegularExpression.
struct Rx {
    struct Match { let value: String; let groups: [String?]; let range: NSRange }
    let re: NSRegularExpression

    init(_ pattern: String, ci: Bool = true) {
        re = try! NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : [])
    }

    func all(_ s: String) -> [Match] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            Match(
                value: ns.substring(with: m.range),
                groups: (0..<m.numberOfRanges).map { i -> String? in
                    let r = m.range(at: i)
                    return r.location == NSNotFound ? nil : ns.substring(with: r)
                },
                range: m.range
            )
        }
    }

    func first(_ s: String) -> Match? { all(s).first }
    func contains(_ s: String) -> Bool { first(s) != nil }
}

/// Turns raw OCR text from the screen into an `Offer`.
///
/// Gig apps change layouts often, so this is forgiving: it looks for a dollar amount plus
/// distance/time plus an "accept/decline"-style word anywhere on screen.
/// If an app's offers stop being detected, this is the file to tweak.
public enum OfferParser {

    static let money = Rx(#"\$\s?(\d{1,4}(?:[.,]\d{2})?)"#, ci: false)
    static let milesRx = Rx(#"(\d{1,3}(?:\.\d{1,2})?)\s?(?:mi|miles?)\b"#)
    static let hrMin = Rx(#"(\d{1,2})\s?(?:hr|hrs|hour|hours)\b\s*(?:(\d{1,2})\s?(?:min|mins|minutes)\b)?"#)
    static let minsRx = Rx(#"(\d{1,3})\s?(?:min|mins|minutes)\b"#)
    static let deliverBy = Rx(#"(?:deliver|drop\s?off|due)\s+by\s+(\d{1,2}):(\d{2})\s?([AaPp])\.?[Mm]"#)
    static let street = Rx(#"\b\d{1,6}\s+(?:[NSEW]\.?\s+)?[A-Za-z0-9.'\- ]{2,40}?\s(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Boulevard|Dr|Drive|Ln|Lane|Way|Ct|Court|Pl|Place|Pkwy|Parkway|Hwy|Highway|Cir|Circle|Ter|Terrace|Trl|Trail)\b\.?(?:,\s*[A-Za-z .]{2,30})?"#)
    static let pickupCue = Rx(#"\b(pick\s?up|pickup|restaurant|store)\b"#)
    static let dropoffCue = Rx(#"\b(drop\s?off|dropoff|customer|deliver to|destination)\b"#)
    static let totalCue = Rx(#"\b(total|guaranteed|incl|includes|est\.?|estimated)\b"#)

    static let offerCues = [
        "accept", "decline", "reject", "new order", "new offer", "guaranteed",
        "includes expected tip", "incl. tips", "batch", "trip request", "match", "deliver by",
    ]

    public static func looksLikeOffer(_ text: String) -> Bool {
        let t = text.lowercased()
        return money.contains(text)
            && (milesRx.contains(text) || minsRx.contains(text))
            && offerCues.contains { t.contains($0) }
    }

    public static func detectApp(_ text: String) -> GigApp {
        let t = text.lowercased()
        if t.contains("doordash") || t.contains("dasher") || t.contains("incl. tips") || t.contains("customer dropoff")
            || t.contains("multiple dropoffs") || t.contains("high pay for") { return .doordash }
        if t.contains("grubhub") { return .grubhub }
        if t.contains("instacart") || t.contains("batch") { return .instacart }
        if t.contains("spark") || t.contains("walmart") { return .spark }
        if t.contains("lyft") { return .lyft }
        if t.contains("amazon") || t.contains("flex") { return .amazonFlex }
        if t.contains("uber") || t.contains("includes expected tip") { return .uber }
        return .unknown
    }

    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Offer? {
        guard looksLikeOffer(text) else { return nil }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let pay = pickPay(lines), pay > 0, pay <= 500 else { return nil }
        let app = detectApp(text)
        var pickup = pickAddress(lines, isPickup: true)
        var dropoff = pickAddress(lines, isPickup: false)
        if app == .doordash, let dash = doorDashPlaces(lines) {
            pickup = dash.pickup
            dropoff = dash.dropoff // usually nil: DoorDash only shows the customer on the map
        }
        return Offer(
            app: app,
            pay: pay,
            miles: pickMiles(lines),
            minutes: pickMinutes(lines, now: now, calendar: calendar),
            pickupText: pickup,
            dropoffText: dropoff,
            rawText: text
        )
    }

    // MARK: DoorDash layout
    //   $6.00 incl. tips
    //   2 stops (4.6 mi) • 17 min
    //   McDonald's                                   <- store name
    //   5136 Nesconset Highway, Port Jefferson       <- address (may wrap)
    //   Station, 11776 NY
    //   [Pick up 2 orders]
    //   Customer dropoff | Multiple dropoffs (2 stops)

    static let stopsLine = Rx(#"\b\d+\s+stops?\b"#)
    static let dashDropCue = Rx(#"(customer dropoff|multiple dropoffs|pick\s?up \d+ orders?)"#)
    static let addressEnd = Rx(#"(\b\d{5}\b|\b[A-Z]{2}$)"#, ci: false)

    static func doorDashPlaces(_ lines: [String]) -> (pickup: String?, dropoff: String?)? {
        guard let start = lines.firstIndex(where: { stopsLine.contains($0) && milesRx.contains($0) }) else { return nil }
        var name: String?
        var address: [String] = []
        var i = start + 1
        while i < lines.count {
            let line = lines[i]
            let low = line.lowercased()
            if dashDropCue.contains(low) || low == "accept" || low == "decline" || low.hasPrefix("accept ") { break }
            if name == nil, !(line.first?.isNumber ?? false) {
                name = line
            } else {
                address.append(line)
                if addressEnd.contains(line) { i += 1; break }
            }
            i += 1
        }
        var pickup: String?
        if !address.isEmpty {
            pickup = ([name].compactMap { $0 } + [address.joined(separator: " ")]).joined(separator: ", ")
        } else {
            pickup = name
        }
        // Dropoff: only if DoorDash printed a street address after the dropoff label.
        var dropoff: String?
        if let d = lines.firstIndex(where: { $0.lowercased().contains("customer dropoff") }), d + 1 < lines.count,
           let m = street.first(lines[d + 1]) {
            dropoff = m.value.trimmingCharacters(in: .whitespaces)
        }
        return (pickup, dropoff)
    }

    // MARK: pay
    static let rateLine = Rx(#"(/\s?hr|/\s?mi\b|per\s+hour|per\s+mile|an\s+hour|% of \$)"#)

    static func pickPay(_ lines: [String]) -> Double? {
        // Rates like "$21/hr" or "$1.50/mi" are never the pay.
        let lines = lines.filter { !rateLine.contains($0) }
        // Prefer a $ amount on a "guaranteed / total / incl. tips" line…
        if let line = lines.first(where: { totalCue.contains($0) && money.contains($0) }),
           let g = money.first(line)?.groups[1] {
            return toMoney(g)
        }
        // …otherwise the largest $ amount, ignoring "+$2.00" add-ons like peak pay.
        var values: [Double] = []
        for line in lines {
            let ns = line as NSString
            for m in money.all(line) {
                if m.range.location > 0,
                   ns.substring(with: NSRange(location: m.range.location - 1, length: 1)) == "+" { continue }
                if let g = m.groups[1] { values.append(toMoney(g)) }
            }
        }
        return values.max()
    }

    // MARK: miles
    static func pickMiles(_ lines: [String]) -> Double? {
        if let line = lines.first(where: { $0.lowercased().contains("total") && milesRx.contains($0) }),
           let g = milesRx.first(line)?.groups[1] {
            return Double(g)
        }
        // Uber/Lyft show pickup distance and trip distance separately -> add them.
        let all: [Double] = lines.flatMap { line in
            milesRx.all(line).compactMap { m -> Double? in m.groups[1].flatMap { Double($0) } }
        }
        return all.isEmpty ? nil : all.reduce(0, +)
    }

    // MARK: minutes
    static func pickMinutes(_ lines: [String], now: Date, calendar: Calendar) -> Int? {
        if let line = lines.first(where: { $0.lowercased().contains("total") && (minsRx.contains($0) || hrMin.contains($0)) }) {
            return minutesIn(line)
        }
        let total = lines.reduce(0) { $0 + (minutesIn($1) ?? 0) }
        if total > 0 { return total }

        // Fallback: "Deliver by 7:45 PM" -> minutes from now.
        guard let m = lines.lazy.compactMap({ deliverBy.first($0) }).first else { return nil }
        var h = (Int(m.groups[1] ?? "") ?? 0) % 12
        if m.groups[3]?.lowercased() == "p" { h += 12 }
        let mm = Int(m.groups[2] ?? "") ?? 0
        let c = calendar.dateComponents([.hour, .minute], from: now)
        var diff = (h * 60 + mm) - ((c.hour ?? 0) * 60 + (c.minute ?? 0))
        if diff < 0 { diff += 24 * 60 }
        return (1...600).contains(diff) ? diff : nil
    }

    static func minutesIn(_ line: String) -> Int? {
        var rest = line
        var total = 0
        for m in hrMin.all(line) {
            total += (Int(m.groups[1] ?? "") ?? 0) * 60 + (Int(m.groups[2] ?? "") ?? 0)
            rest = rest.replacingOccurrences(of: m.value, with: " ")
        }
        for m in minsRx.all(rest) { total += Int(m.groups[1] ?? "") ?? 0 }
        return total > 0 ? total : nil
    }

    // MARK: addresses
    static func pickAddress(_ lines: [String], isPickup: Bool) -> String? {
        let cue = isPickup ? pickupCue : dropoffCue
        // 1) Street address on the cue line, or on the line right after it.
        for (i, line) in lines.enumerated() where cue.contains(line) {
            if let m = street.first(line) { return m.value.trimmingCharacters(in: .whitespaces) }
            if i + 1 < lines.count {
                let next = lines[i + 1]
                if let m = street.first(next) { return m.value.trimmingCharacters(in: .whitespaces) }
                // Pickup is often just a business name ("Chipotle"), which map search finds nearby.
                if isPickup, !money.contains(next), !milesRx.contains(next), (3...40).contains(next.count) {
                    return next
                }
            }
        }
        // 2) Otherwise first street address = pickup, last = dropoff.
        var seen = Set<String>()
        let all = lines.compactMap { street.first($0)?.value.trimmingCharacters(in: .whitespaces) }
            .filter { seen.insert($0).inserted }
        if all.count >= 2 { return isPickup ? all.first : all.last }
        if all.count == 1 && !isPickup { return all.first }
        return nil
    }

    static func toMoney(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}
