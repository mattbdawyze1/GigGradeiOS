import Foundation
import UserNotifications
import GigCore

/// iOS doesn't allow drawing over other apps, so the grade arrives as a notification
/// banner on top of the gig app. Pull the banner down for Accepted / Declined / Add to route.
/// The "📍 Dropoff" line on the banner.
struct DropoffInfo {
    var place: String          // "Garden Ct & School Dr, Port Jefferson Station"
    var estimated: Bool        // true = worked out from the DoorDash map
    var milesFromYou: Double?

    var line: String {
        var s = estimated ? "📍 Dropoff ≈ \(place) (from map)" : "📍 Dropoff: \(place)"
        if let m = milesFromYou { s += String(format: " · %.1f mi from you", m) }
        return s
    }
}

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
        case .good: return "✅"
        case .fair: return "⚠️"
        case .bad: return "❌"
        case nil: return ""
        }
    }

    /// Text for each banner item (empty when it doesn't apply to this offer).
    static func values(_ o: Offer, _ s: Score, _ settings: DriverSettings, _ p: NotificationPrefs,
                       _ otw: TripPlanner.OnTheWay?, _ dropoff: DropoffInfo?) -> [BannerItem: String] {
        var v: [BannerItem: String] = [:]
        v[.color] = "\(s.category.dot) \(s.category.label)"
        v[.grade] = s.grade
        v[.app] = o.app == .unknown ? "" : o.app.rawValue
        v[.pay] = String(format: "$%.2f", o.pay)
        if let h = s.dollarsPerHour {
            var t = String(format: "$%.2f/hr", h) + mark(s.hourlyLevel)
            if p.showPctOfTarget, let pct = s.hourlyPctOfTarget { t += " \(pct)%" }
            v[.hourly] = t
        }
        if let m = s.dollarsPerMile {
            var t = String(format: "$%.2f/mi", m) + mark(s.mileLevel)
            if p.showPctOfTarget, let pct = s.milePctOfTarget { t += " \(pct)%" }
            v[.perMile] = t
        }
        if let mi = o.miles { v[.miles] = String(format: "%.1f mi", mi) }
        if let mn = o.minutes { v[.minutes] = "\(mn) min" }
        if let net = s.netPay { v[.net] = String(format: "net $%.2f", net) }
        if let otw { v[.verdict] = otw.shortMessage }
        if let dropoff { v[.dropoff] = dropoff.line }
        return v
    }

    static func content(_ o: Offer, _ s: Score, _ settings: DriverSettings, _ p: NotificationPrefs,
                        _ otw: TripPlanner.OnTheWay?, dropoff: DropoffInfo? = nil) -> (title: String, subtitle: String, body: String) {
        p.effectiveLayout.compose(values(o, s, settings, p, otw, dropoff))
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
                     dropoff: DropoffInfo? = nil) {
        let c = UNMutableNotificationContent()
        let text = content(offer, score, settings, prefs, otw, dropoff: dropoff)
        c.title = text.title
        c.subtitle = text.subtitle   // its own line, so line 2 is always visible
        c.body = text.body
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
