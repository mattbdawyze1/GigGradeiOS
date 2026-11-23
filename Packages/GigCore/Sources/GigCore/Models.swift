import Foundation

public enum GigApp: String, Codable {
    case doordash = "DoorDash", uber = "Uber", grubhub = "Grubhub", instacart = "Instacart"
    case spark = "Spark", lyft = "Lyft", amazonFlex = "Amazon Flex", unknown = "Offer"
}

/// What we could read off an offer screen. Any field may be nil if the OCR didn't see it.
public struct Offer: Equatable {
    public var app: GigApp
    public var pay: Double
    public var miles: Double?
    public var minutes: Int?
    public var pickupText: String?
    public var dropoffText: String?
    public var rawText: String
    /// Every store listed on the card (DoorDash batches can list two). `pickupText` is the first.
    public var pickupTexts: [String] = []
    /// "4 stops (10.5 mi)" -> 4 (DoorDash), for spotting stops the map can't show.
    public var stopCount: Int?

    public init(app: GigApp, pay: Double, miles: Double?, minutes: Int?,
                pickupText: String?, dropoffText: String?, rawText: String) {
        self.app = app; self.pay = pay; self.miles = miles; self.minutes = minutes
        self.pickupText = pickupText; self.dropoffText = dropoffText; self.rawText = rawText
    }

    /// Used so the same offer doesn't alert again on every frame.
    public var key: String { "\(app.rawValue)|\(pay)|\(miles ?? -1)|\(minutes ?? -1)" }
}

/// Your targets. Each rate has two levels set by the double sliders:
/// below `…Fair` = bad (red), between = fair (yellow), at/above `…Good` = good (green).
public struct DriverSettings: Codable, Equatable {
    public var hourlyFair: Double
    public var hourlyGood: Double
    public var perMileFair: Double
    public var perMileGood: Double
    public var costPerMile: Double       // gas + wear, for "after costs" numbers
    // Route checks are radii from a target (5.9.6). Names kept from older versions so saved settings carry over.
    public var onTheWayRadiusMi: Double  // 🏠 CLOSE BY: customer within this of your last stop
    public var maxDetourMi: Double       // 🏠 ON THE WAY: customer within this of your last stop
    public var pickupNearMi: Double      // 🛍 CLOSE BY: store within this of a pickup in your route
    public var pickupMaxDetourMi: Double // 🛍 ON THE WAY: store within this of a pickup in your route

    /// The radii as the checks use them: ON THE WAY is never smaller than CLOSE BY.
    public var pickupCloseByMi: Double { pickupNearMi }
    public var pickupOnTheWayMi: Double { max(pickupMaxDetourMi, pickupNearMi) }
    public var dropoffCloseByMi: Double { onTheWayRadiusMi }
    public var dropoffOnTheWayMi: Double { max(maxDetourMi, onTheWayRadiusMi) }

    /// The letter grade and "% of target" compare against the upper (good) level.
    public var targetHourly: Double { hourlyGood }
    public var targetPerMile: Double { perMileGood }

    public init(hourlyFair: Double = 18, hourlyGood: Double = 25,
                perMileFair: Double = 1.0, perMileGood: Double = 1.5,
                costPerMile: Double = 0.30, onTheWayRadiusMi: Double = 1.5, maxDetourMi: Double = 3,
                pickupNearMi: Double = 1.0, pickupMaxDetourMi: Double = 1.5) {
        self.hourlyFair = hourlyFair; self.hourlyGood = hourlyGood
        self.perMileFair = perMileFair; self.perMileGood = perMileGood
        self.costPerMile = costPerMile; self.onTheWayRadiusMi = onTheWayRadiusMi; self.maxDetourMi = maxDetourMi
        self.pickupNearMi = pickupNearMi; self.pickupMaxDetourMi = pickupMaxDetourMi
    }

    private enum CodingKeys: String, CodingKey {
        case hourlyFair, hourlyGood, perMileFair, perMileGood, costPerMile, onTheWayRadiusMi, maxDetourMi
        case pickupNearMi, pickupMaxDetourMi
        case targetHourly, targetPerMile // version 1 names
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = DriverSettings()
        let oldHourly = try c.decodeIfPresent(Double.self, forKey: .targetHourly)
        let oldMile = try c.decodeIfPresent(Double.self, forKey: .targetPerMile)
        hourlyGood = try c.decodeIfPresent(Double.self, forKey: .hourlyGood) ?? oldHourly ?? d.hourlyGood
        hourlyFair = try c.decodeIfPresent(Double.self, forKey: .hourlyFair) ?? (oldHourly.map { ($0 * 0.75).rounded() } ?? d.hourlyFair)
        perMileGood = try c.decodeIfPresent(Double.self, forKey: .perMileGood) ?? oldMile ?? d.perMileGood
        perMileFair = try c.decodeIfPresent(Double.self, forKey: .perMileFair) ?? (oldMile.map { $0 * 0.67 } ?? d.perMileFair)
        costPerMile = try c.decodeIfPresent(Double.self, forKey: .costPerMile) ?? d.costPerMile
        onTheWayRadiusMi = try c.decodeIfPresent(Double.self, forKey: .onTheWayRadiusMi) ?? d.onTheWayRadiusMi
        maxDetourMi = try c.decodeIfPresent(Double.self, forKey: .maxDetourMi) ?? d.maxDetourMi
        pickupNearMi = try c.decodeIfPresent(Double.self, forKey: .pickupNearMi) ?? d.pickupNearMi
        pickupMaxDetourMi = try c.decodeIfPresent(Double.self, forKey: .pickupMaxDetourMi) ?? d.pickupMaxDetourMi
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hourlyFair, forKey: .hourlyFair); try c.encode(hourlyGood, forKey: .hourlyGood)
        try c.encode(perMileFair, forKey: .perMileFair); try c.encode(perMileGood, forKey: .perMileGood)
        try c.encode(costPerMile, forKey: .costPerMile); try c.encode(onTheWayRadiusMi, forKey: .onTheWayRadiusMi)
        try c.encode(maxDetourMi, forKey: .maxDetourMi)
        try c.encode(pickupNearMi, forKey: .pickupNearMi); try c.encode(pickupMaxDetourMi, forKey: .pickupMaxDetourMi)
    }
}

/// Green / yellow / red.
public enum OfferCategory: String, Codable, CaseIterable, Identifiable {
    case good, fair, bad
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .good: return "Good"
        case .fair: return "Fair"
        case .bad: return "Bad"
        }
    }
    public var dot: String {
        switch self {
        case .good: return "🟢"
        case .fair: return "🟡"
        case .bad: return "🔴"
        }
    }
}

public enum Decision: String, Codable, CaseIterable {
    case pending, accepted, declined
}

/// One offer GigGrade saw, as stored in the Offers log.
public struct OfferRecord: Codable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var date: Date
    public var app: GigApp
    public var pay: Double
    public var miles: Double?
    public var minutes: Int?
    public var pickupText: String?
    public var dropoffText: String?
    public var grade: String
    public var category: OfferCategory
    public var dollarsPerHour: Double?
    public var dollarsPerMile: Double?
    public var routeNote: String?        // on-the-way result shown in the banner
    public var screenshotFile: String?   // file name inside the log's Screenshots folder
    public var decision: Decision
    /// Last time this record changed (used to merge with the cloud copy).
    public var updatedAt: Date?
    /// Where the pickup and dropoff are, when they could be located.
    public var pickupLocation: Coord?
    public var dropoffLocation: Coord?
    /// True when the dropoff was worked out from the DoorDash map (approximate).
    public var dropoffEstimated: Bool?
    /// Miles from the target, for the Insights charts: the store from the nearest pickup in your route
    /// (farthest store for batches), and the customer from your last stop (farthest customer for batches).
    public var pickupDetourMi: Double?
    public var dropoffDetourMi: Double?

    public init(id: UUID = UUID(), date: Date = Date(), app: GigApp, pay: Double, miles: Double?, minutes: Int?,
                pickupText: String?, dropoffText: String?, grade: String, category: OfferCategory,
                dollarsPerHour: Double?, dollarsPerMile: Double?, routeNote: String? = nil,
                screenshotFile: String? = nil, decision: Decision = .pending, updatedAt: Date? = nil) {
        self.id = id; self.date = date; self.app = app; self.pay = pay; self.miles = miles; self.minutes = minutes
        self.pickupText = pickupText; self.dropoffText = dropoffText; self.grade = grade; self.category = category
        self.dollarsPerHour = dollarsPerHour; self.dollarsPerMile = dollarsPerMile; self.routeNote = routeNote
        self.screenshotFile = screenshotFile; self.decision = decision; self.updatedAt = updatedAt ?? date
    }

    public func netPay(costPerMile: Double) -> Double? { miles.map { pay - $0 * costPerMile } }
}

/// Notification sounds. The four custom ones ship inside the app.
public enum SoundChoice: String, Codable, CaseIterable, Identifiable {
    case chime, ding, alert, buzz, systemDefault, none
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .chime: return "Chime (rising)"
        case .ding: return "Ding"
        case .alert: return "Two-tone alert"
        case .buzz: return "Low buzz"
        case .systemDefault: return "iPhone default"
        case .none: return "Silent"
        }
    }
    public var fileName: String? {
        switch self {
        case .chime, .ding, .alert, .buzz: return "giggrade_\(rawValue).wav"
        case .systemDefault, .none: return nil
        }
    }
}

/// What the offer banner shows, and which sound plays for each color.
public struct NotificationPrefs: Codable, Equatable {
    public var showGrade = true
    public var showCategory = true
    public var showAppName = true
    public var showPay = true
    public var showHourly = true
    public var showPerMile = true
    public var showPctOfTarget = true
    public var showMilesMinutes = true
    public var showNet = true
    public var showOnTheWay = true
    public var showDropoff = false
    /// Custom banner arrangement; nil = the standard layout, minus anything switched off above.
    public var layout: BannerLayout?
    public var goodSound: SoundChoice = .chime
    public var fairSound: SoundChoice = .ding
    public var badSound: SoundChoice = .buzz

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case showGrade, showCategory, showAppName, showPay, showHourly, showPerMile, showPctOfTarget
        case showMilesMinutes, showNet, showOnTheWay, showDropoff, layout, goodSound, fairSound, badSound
    }

    /// Tolerates missing keys, so adding options later never wipes your choices.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func b(_ k: CodingKeys, _ def: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? def }
        func s(_ k: CodingKeys, _ def: SoundChoice) -> SoundChoice { ((try? c.decodeIfPresent(SoundChoice.self, forKey: k)) ?? nil) ?? def }
        let d = NotificationPrefs()
        showGrade = b(.showGrade, d.showGrade); showCategory = b(.showCategory, d.showCategory)
        showAppName = b(.showAppName, d.showAppName); showPay = b(.showPay, d.showPay)
        showHourly = b(.showHourly, d.showHourly); showPerMile = b(.showPerMile, d.showPerMile)
        showPctOfTarget = b(.showPctOfTarget, d.showPctOfTarget); showMilesMinutes = b(.showMilesMinutes, d.showMilesMinutes)
        showNet = b(.showNet, d.showNet); showOnTheWay = b(.showOnTheWay, d.showOnTheWay)
        showDropoff = b(.showDropoff, d.showDropoff)
        layout = (try? c.decodeIfPresent(BannerLayout.self, forKey: .layout)) ?? nil
        goodSound = s(.goodSound, d.goodSound); fairSound = s(.fairSound, d.fairSound); badSound = s(.badSound, d.badSound)
    }

    /// The layout actually used: your custom one, or the standard one respecting the old on/off switches.
    public var effectiveLayout: BannerLayout {
        if let layout { return layout }
        var l = BannerLayout.standard
        if !showCategory { l.set(.color, .off) }
        if !showGrade { l.set(.grade, .off) }
        if !showAppName { l.set(.app, .off) }
        if !showPay { l.set(.pay, .off) }
        if !showHourly { l.set(.hourly, .off) }
        if !showPerMile { l.set(.perMile, .off) }
        if !showMilesMinutes { l.set(.miles, .off); l.set(.minutes, .off) }
        if !showNet { l.set(.net, .off) }
        if !showOnTheWay { l.set(.verdict, .off) }
        if showDropoff { l.set(.dropoff, .more) }
        return l
    }

    public func sound(for c: OfferCategory) -> SoundChoice {
        switch c {
        case .good: return goodSound
        case .fair: return fairSound
        case .bad: return badSound
        }
    }
}

public struct Coord: Codable, Equatable, Hashable {
    public var lat: Double
    public var lng: Double
    public init(lat: Double, lng: Double) { self.lat = lat; self.lng = lng }
}

public enum StopType: String, Codable { case pickup, dropoff }

public struct Stop: Codable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var type: StopType
    public var label: String
    public var location: Coord
    public var orderId: String
    /// A dropoff can belong to more than one pickup (two orders going to one address).
    public var extraOrderIds: [String]?
    /// The full address ("24 Kensington Way, Port Jefferson Station, NY 11776"). `label` is the name.
    public var address: String?

    public init(id: UUID = UUID(), type: StopType, label: String, location: Coord, orderId: String,
                extraOrderIds: [String]? = nil, address: String? = nil) {
        self.id = id; self.type = type; self.label = label; self.location = location; self.orderId = orderId
        self.extraOrderIds = extraOrderIds; self.address = address
    }

    /// Name and address as two fields. Older stops kept both in the label ("Mike R · 15 France St").
    public var nameAndAddress: (name: String, address: String?) {
        if let address, !address.isEmpty { return (label, address) }
        let parts = label.components(separatedBy: " · ")
        if parts.count >= 2 { return (parts[0], parts.dropFirst().joined(separator: " · ")) }
        return (label, nil)
    }

    /// The street part of the address ("24 Kensington Way").
    public var street: String? {
        nameAndAddress.address.map { a in
            a.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? a
        }
    }

    /// Every order this stop is part of.
    public var orderIds: [String] { [orderId] + (extraOrderIds ?? []) }

    /// Sets the orders this stop is part of (first one is the main one).
    public mutating func setOrders(_ ids: [String]) {
        var unique: [String] = []
        for id in ids where !unique.contains(id) { unique.append(id) }
        orderId = unique.first ?? UUID().uuidString
        extraOrderIds = unique.count > 1 ? Array(unique.dropFirst()) : nil
    }
}

