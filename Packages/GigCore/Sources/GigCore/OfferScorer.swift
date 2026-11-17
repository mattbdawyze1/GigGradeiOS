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
            composite: composite
        )
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
