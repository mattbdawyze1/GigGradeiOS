import Foundation

/// Insights: how offers break down by detour (0 to 5+ mi, in 1-mile steps), for the pickup and the dropoff.
public enum DetourStats {
    public enum Kind: String, CaseIterable, Identifiable {
        case pickup = "🛍 Pickup", dropoff = "🏠 Dropoff"
        public var id: String { rawValue }
    }

    public struct Bucket: Identifiable, Equatable {
        public var kind: Kind
        public var index: Int              // 0 = 0–1 mi … 5 = 5+ mi
        public var offers: Int
        public var accepted: Int
        public var avgPay: Double?
        public var avgPerMile: Double?
        public var id: String { "\(kind.rawValue)|\(index)" }
        public var label: String { DetourStats.labels[index] }
        public var acceptedPct: Double? { offers > 0 ? Double(accepted) / Double(offers) * 100 : nil }
    }

    public static let labels = ["0–1", "1–2", "2–3", "3–4", "4–5", "5+"]

    public static func index(_ miles: Double) -> Int { min(max(Int(miles.rounded(.down)), 0), 5) }

    static func detour(_ r: OfferRecord, _ kind: Kind) -> Double? {
        kind == .pickup ? r.pickupDetourMi : r.dropoffDetourMi
    }

    /// Six buckets per kind (empty buckets included, so the chart always runs 0 to 5+).
    public static func buckets(_ records: [OfferRecord], kind: Kind) -> [Bucket] {
        (0...5).map { i in
            let rs = records.filter { detour($0, kind).map(index) == i }
            let perMile = rs.compactMap(\.dollarsPerMile)
            return Bucket(kind: kind, index: i, offers: rs.count,
                          accepted: rs.filter { $0.decision == .accepted }.count,
                          avgPay: rs.isEmpty ? nil : rs.map(\.pay).reduce(0, +) / Double(rs.count),
                          avgPerMile: perMile.isEmpty ? nil : perMile.reduce(0, +) / Double(perMile.count))
        }
    }

    /// Plain-English takeaways.
    /// Your limit for each check (the dashed lines): pickup = ON THE WAY limit, dropoff = max extra miles.
    public static func limit(_ kind: Kind, _ s: DriverSettings) -> Double {
        kind == .pickup ? s.pickupMaxDetourMi : s.maxDetourMi
    }

    public static func insights(_ records: [OfferRecord], settings s: DriverSettings) -> [String] {
        var out: [String] = []
        for kind in Kind.allCases {
            let b = buckets(records, kind: kind)
            let total = b.map(\.offers).reduce(0, +)
            guard total >= 3 else { continue }
            let name = kind == .pickup ? "pickup" : "dropoff"
            let under1 = b[0].offers
            out.append("\(Int((Double(under1) / Double(total) * 100).rounded()))% of offers added under 1 mi at the \(name) (\(under1) of \(total)).")
            let lim = limit(kind, s)
            let within = records.filter { (detour($0, kind) ?? .infinity) <= lim }.count
            out.append("\(Int((Double(within) / Double(total) * 100).rounded()))% of \(name) detours were within your " +
                       String(format: "%.1f mi limit", lim) + " (\(within) of \(total)).")
            let far = records.filter { (detour($0, kind) ?? -1) >= 2 }.compactMap(\.dollarsPerMile)
            if let near = b[0].avgPerMile, far.count >= 2 {
                let farAvg = far.reduce(0, +) / Double(far.count)
                let who = kind == .pickup ? "Pickup" : "Dropoff"
                out.append(who + " detours of 2+ mi paid " + String(format: "$%.2f/mi on average vs $%.2f/mi under 1 mi.", farAvg, near))
            }
        }
        return out
    }
}
