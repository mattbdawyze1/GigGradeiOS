import Foundation

/// Insights: how offers break down by miles from the target (0 to 5+ mi, in 1-mile steps):
/// 🛍 the store from the nearest pickup in your route, 🏠 the customer from your last stop.
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
    /// Your radii for each check (the dashed lines).
    public static func radii(_ kind: Kind, _ s: DriverSettings) -> (closeBy: Double, onTheWay: Double) {
        kind == .pickup ? (s.pickupCloseByMi, s.pickupOnTheWayMi) : (s.dropoffCloseByMi, s.dropoffOnTheWayMi)
    }

    public static func insights(_ records: [OfferRecord], settings s: DriverSettings) -> [String] {
        var out: [String] = []
        for kind in Kind.allCases {
            let b = buckets(records, kind: kind)
            let total = b.map(\.offers).reduce(0, +)
            guard total >= 3 else { continue }
            let name = kind == .pickup ? "pickup" : "dropoff"
            let under1 = b[0].offers
            out.append("\(Int((Double(under1) / Double(total) * 100).rounded()))% of \(name)s were under 1 mi from the target (\(under1) of \(total)).")
            let r = radii(kind, s)
            let close = records.filter { (detour($0, kind) ?? .infinity) <= r.closeBy }.count
            let onWay = records.filter { (detour($0, kind) ?? .infinity) <= r.onTheWay }.count
            out.append("\(name.capitalized)s: \(pct(close, total))% Close by (≤ " + String(format: "%.1f", r.closeBy) +
                       " mi), \(pct(onWay, total))% within On the way (≤ " + String(format: "%.1f", r.onTheWay) + " mi).")
            let far = records.filter { (detour($0, kind) ?? -1) >= 2 }.compactMap(\.dollarsPerMile)
            if let near = b[0].avgPerMile, far.count >= 2 {
                let farAvg = far.reduce(0, +) / Double(far.count)
                let who = kind == .pickup ? "Pickup" : "Dropoff"
                out.append(who + "s 2+ mi from the target paid " + String(format: "$%.2f/mi on average vs $%.2f/mi under 1 mi.", farAvg, near))
            }
        }
        return out
    }

    static func pct(_ n: Int, _ total: Int) -> Int { Int((Double(n) / Double(max(total, 1)) * 100).rounded()) }
}
