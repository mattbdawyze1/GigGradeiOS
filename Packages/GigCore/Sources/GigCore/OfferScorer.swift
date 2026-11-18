import Foundation

public struct Score: Equatable {
    public var dollarsPerHour: Double?
    public var dollarsPerMile: Double?
    public var netPay: Double?
    public var netPerHour: Double?
    public var hourlyPctOfTarget: Int?
    public var milePctOfTarget: Int?
    public var grade: String
    public var composite: Double?
    /// Green / yellow / red from your double-slider ranges.
    public var category: OfferCategory
    public var hourlyLevel: OfferCategory?
    public var mileLevel: OfferCategory?
}

public enum OfferScorer {

    public static func score(_ o: Offer, _ s: DriverSettings) -> Score {
        let hours = o.minutes.flatMap { $0 > 0 ? Double($0) / 60 : nil }
        let dph = hours.map { o.pay / $0 }
        let dpm = o.miles.flatMap { $0 > 0 ? o.pay / $0 : nil }
        let net = o.miles.map { o.pay - $0 * s.costPerMile }
        let nph: Double? = (net != nil && hours != nil) ? net! / hours! : nil

        let hrRatio = dph.map { $0 / s.targetHourly }
        let miRatio = dpm.map { $0 / s.targetPerMile }
        let ratios = [hrRatio, miRatio].compactMap { $0 }.map { min($0, 1.6) }

        // Average of the two, pulled down by the weaker one, so a great $/hr
        // can't hide a terrible $/mi (or vice versa).
        let composite: Double? = ratios.isEmpty ? nil
            : 0.6 * (ratios.reduce(0, +) / Double(ratios.count)) + 0.4 * ratios.min()!

        return Score(
            dollarsPerHour: dph,
            dollarsPerMile: dpm,
            netPay: net,
            netPerHour: nph,
            hourlyPctOfTarget: hrRatio.map { Int(($0 * 100).rounded()) },
            milePctOfTarget: miRatio.map { Int(($0 * 100).rounded()) },
            grade: grade(for: composite),
            composite: composite,
            category: category(dph: dph, dpm: dpm, s),
            hourlyLevel: level(dph, fair: s.hourlyFair, good: s.hourlyGood),
            mileLevel: level(dpm, fair: s.perMileFair, good: s.perMileGood)
        )
    }

    public static func level(_ v: Double?, fair: Double, good: Double) -> OfferCategory? {
        guard let v else { return nil }
        if v >= good { return .good }
        if v >= fair { return .fair }
        return .bad
    }

    /// Green only if every rate we could read is good; red if any is bad; otherwise yellow.
    public static func category(dph: Double?, dpm: Double?, _ s: DriverSettings) -> OfferCategory {
        let levels = [level(dph, fair: s.hourlyFair, good: s.hourlyGood),
                      level(dpm, fair: s.perMileFair, good: s.perMileGood)].compactMap { $0 }
        if levels.isEmpty { return .fair }
        if levels.contains(.bad) { return .bad }
        if levels.allSatisfy({ $0 == .good }) { return .good }
        return .fair
    }

    public static func grade(for c: Double?) -> String {
        guard let c else { return "?" }
        switch c {
        case 1.30...: return "A+"
        case 1.10...: return "A"
        case 0.95...: return "B"
        case 0.80...: return "C"
        case 0.65...: return "D"
        default: return "F"
        }
    }
}
