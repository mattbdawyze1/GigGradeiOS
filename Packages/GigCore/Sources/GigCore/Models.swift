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

    public init(app: GigApp, pay: Double, miles: Double?, minutes: Int?,
                pickupText: String?, dropoffText: String?, rawText: String) {
        self.app = app; self.pay = pay; self.miles = miles; self.minutes = minutes
        self.pickupText = pickupText; self.dropoffText = dropoffText; self.rawText = rawText
    }

    /// Used so the same offer doesn't alert again on every frame.
    public var key: String { "\(app.rawValue)|\(pay)|\(miles ?? -1)|\(minutes ?? -1)" }
}

public struct DriverSettings: Codable, Equatable {
    public var targetHourly: Double      // $ per hour you want
    public var targetPerMile: Double     // $ per mile you want
    public var costPerMile: Double       // gas + wear, for "after costs" numbers
    public var onTheWayRadiusMi: Double  // new dropoff within this of your final stop = OK
    public var maxDetourMi: Double       // extra miles you'll accept to stack an order

    public init(targetHourly: Double = 25, targetPerMile: Double = 1.5, costPerMile: Double = 0.30,
                onTheWayRadiusMi: Double = 3, maxDetourMi: Double = 2) {
        self.targetHourly = targetHourly; self.targetPerMile = targetPerMile; self.costPerMile = costPerMile
        self.onTheWayRadiusMi = onTheWayRadiusMi; self.maxDetourMi = maxDetourMi
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

    public init(id: UUID = UUID(), type: StopType, label: String, location: Coord, orderId: String) {
        self.id = id; self.type = type; self.label = label; self.location = location; self.orderId = orderId
    }
}
