import Foundation
import UserNotifications
import GigCore

/// iOS doesn't allow drawing over other apps, so the grade arrives as a notification
/// banner on top of the gig app. Pull the banner down for Accepted / Declined / Add to route.
enum OfferAlert {
    static let basicCategory = "OFFER"
    static let routeCategory = "OFFER_ROUTE"
    static let acceptAction = "ACCEPTED"
    static let acceptRouteAction = "ACCEPTED_ADD_ROUTE"
    static let declineAction = "DECLINED"
    static let requestId = "giggrade.offer" // same ID = a new offer replaces the old banner

    static func registerCategories() {
        let accept = UNNotificationAction(identifier: acceptAction, title: "✓ Accepted", options: [])
        let acceptRoute = UNNotificationAction(identifier: acceptRouteAction, title: "✓ Accepted + add to route", options: [])
        let decline = UNNotificationAction(identifier: declineAction, title: "✕ Declined", options: [.destructive])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: basicCategory, actions: [accept, decline], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: routeCategory, actions: [acceptRoute, accept, decline], intentIdentifiers: [], options: []),
        ])
    }

    private static func mark(_ level: OfferCategory?) -> String {
        switch level {
        case .good: return " ✅"
        case .fair: return " ⚠️"
        case .bad: return " ❌"
        case nil: return ""
        }
    }

    static func title(_ o: Offer, _ s: Score, _ p: NotificationPrefs) -> String {
        var head: [String] = []
        if p.showCategory { head.append("\(s.category.dot) \(s.category.label)") }
        if p.showGrade { head.append(s.grade) }
        var what: [String] = []
        if p.showAppName { what.append(o.app.rawValue) }
        if p.showPay { what.append(String(format: "$%.2f", o.pay)) }
        let parts = [head.joined(separator: " "), what.joined(separator: " ")].filter { !$0.isEmpty }
        return parts.isEmpty ? "New offer" : parts.joined(separator: " · ")
    }

    static func body(_ o: Offer, _ s: Score, _ settings: DriverSettings, _ p: NotificationPrefs,
                     _ otw: TripPlanner.OnTheWay?) -> String {
        var lines: [String] = []
        if p.showHourly, let h = s.dollarsPerHour {
            var line = String(format: "$%.2f/hr", h)
            if p.showPctOfTarget, let pct = s.hourlyPctOfTarget { line += " · \(pct)% of $\(String(format: "%.0f", settings.hourlyGood))" }
            lines.append(line + mark(s.hourlyLevel))
        }
        if p.showPerMile, let m = s.dollarsPerMile {
            var line = String(format: "$%.2f/mi", m)
            if p.showPctOfTarget, let pct = s.milePctOfTarget { line += " · \(pct)% of $\(String(format: "%.2f", settings.perMileGood))" }
            lines.append(line + mark(s.mileLevel))
        }
        var trip: [String] = []
        if p.showMilesMinutes {
            if let mi = o.miles { trip.append(String(format: "%.1f mi", mi)) }
            if let mn = o.minutes { trip.append("\(mn) min") }
        }
        if p.showNet, let net = s.netPay {
            trip.append(String(format: "after costs $%.2f", net) + (s.netPerHour.map { String(format: " ($%.0f/hr)", $0) } ?? ""))
        }
        if !trip.isEmpty { lines.append(trip.joined(separator: " · ")) }
        if p.showOnTheWay, let otw { lines.append(otw.message) }
        return lines.joined(separator: "\n")
    }

    static func body(_ o: Offer, _ s: Score, _ settings: DriverSettings, _ p: NotificationPrefs,
                     _ otw: TripPlanner.OnTheWay?, dropoffEstimated: Bool) -> String {
        var text = body(o, s, settings, p, otw)
        if dropoffEstimated, p.showOnTheWay, otw != nil { text += "\n📍 Customer location estimated from the map" }
        return text
    }

    static func sound(_ choice: SoundChoice) -> UNNotificationSound? {
        switch choice {
        case .none: return nil
        case .systemDefault: return .default
        default:
            guard let file = choice.fileName else { return .default }
            return UNNotificationSound(named: UNNotificationSoundName(file))
        }
    }

    static func post(record: OfferRecord, offer: Offer, score: Score, settings: DriverSettings,
                     prefs: NotificationPrefs, otw: TripPlanner.OnTheWay?, canAddToRoute: Bool, silent: Bool,
                     dropoffEstimated: Bool = false) {
        let c = UNMutableNotificationContent()
        c.title = title(offer, score, prefs)
        c.body = body(offer, score, settings, prefs, otw, dropoffEstimated: dropoffEstimated)
        c.categoryIdentifier = canAddToRoute ? routeCategory : basicCategory
        c.interruptionLevel = .active
        c.relevanceScore = 1
        if !silent { c.sound = sound(prefs.sound(for: score.category)) }
        c.userInfo = ["recordId": record.id.uuidString, "dayKey": OfferLog.dayKey(record.date)]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: requestId, content: c, trigger: nil))
    }
}

/// Puts the custom sounds where iOS looks for notification sounds (incl. the shared App Group
/// folder, so banners posted by the screen reader can use them too).
enum SoundInstaller {
    static func install() {
        let fm = FileManager.default
        var targets: [URL] = []
        if let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first { targets.append(lib.appendingPathComponent("Sounds")) }
        targets.append(SharedStore.containerURL.appendingPathComponent("Library/Sounds"))
        for dir in targets {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for choice in SoundChoice.allCases {
                guard let name = choice.fileName,
                      let src = Bundle.main.url(forResource: name, withExtension: nil) else { continue }
                let dst = dir.appendingPathComponent(name)
                if !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: src, to: dst) }
            }
        }
    }
}
