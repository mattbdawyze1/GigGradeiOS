import Foundation
import UserNotifications
import GigCore

/// iOS doesn't allow drawing over other apps, so the grade arrives as a notification
/// banner on top of the gig app. Long-press / pull down the banner for "Add to route".
enum OfferAlert {
    static let category = "OFFER"
    static let addAction = "ADD_TO_ROUTE"
    static let mapAction = "OPEN_MAP"
    static let requestId = "giggrade.offer" // same ID = new offers replace the old banner

    static func registerCategories() {
        let add = UNNotificationAction(identifier: addAction, title: "Add to route", options: [])
        let map = UNNotificationAction(identifier: mapAction, title: "Open route map", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [add, map], intentIdentifiers: [], options: [])
        ])
    }

    static func title(_ o: Offer, _ s: Score) -> String {
        var parts = ["\(s.grade)  \(o.app.rawValue) $\(String(format: "%.2f", o.pay))"]
        if let h = s.dollarsPerHour { parts.append(String(format: "$%.0f/hr", h)) }
        if let m = s.dollarsPerMile { parts.append(String(format: "$%.2f/mi", m)) }
        return parts.joined(separator: " · ")
    }

    static func body(_ o: Offer, _ s: Score, _ settings: DriverSettings, _ otw: TripPlanner.OnTheWay?) -> String {
        var lines: [String] = []
        if let p = s.hourlyPctOfTarget {
            lines.append("Hourly \(p)% of $\(String(format: "%.0f", settings.targetHourly)) target \(p >= 100 ? "✅" : p >= 80 ? "⚠️" : "❌")")
        }
        if let p = s.milePctOfTarget {
            lines.append("Per mile \(p)% of $\(String(format: "%.2f", settings.targetPerMile)) target \(p >= 100 ? "✅" : p >= 80 ? "⚠️" : "❌")")
        }
        var trip: [String] = []
        if let mi = o.miles { trip.append(String(format: "%.1f mi", mi)) }
        if let mn = o.minutes { trip.append("\(mn) min") }
        if let net = s.netPay {
            trip.append(String(format: "after costs $%.2f", net) + (s.netPerHour.map { String(format: " ($%.0f/hr)", $0) } ?? ""))
        }
        if !trip.isEmpty { lines.append(trip.joined(separator: " · ")) }
        if let otw { lines.append(otw.message) }
        return lines.joined(separator: "\n")
    }

    static func post(offer: Offer, score: Score, settings: DriverSettings,
                     otw: TripPlanner.OnTheWay?, orderId: String?, silent: Bool) {
        let c = UNMutableNotificationContent()
        c.title = title(offer, score)
        c.body = body(offer, score, settings, otw)
        c.categoryIdentifier = category
        c.interruptionLevel = .active
        c.relevanceScore = 1
        if !silent { c.sound = .default }
        if let orderId { c.userInfo = ["orderId": orderId] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: requestId, content: c, trigger: nil))
    }
}
