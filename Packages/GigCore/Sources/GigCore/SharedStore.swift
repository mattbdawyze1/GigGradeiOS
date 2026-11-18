import Foundation

/// Data shared between the app and the screen-reading extension through an App Group.
/// The group ID must match the App Group set in both targets' entitlements (project.yml).
public final class SharedStore {
    /// Read from Info.plist (set once in project.yml via APP_GROUP), so app + extension always agree.
    public static let appGroup: String =
        (Bundle.main.object(forInfoDictionaryKey: "GigGradeAppGroup") as? String) ?? "group.com.giggrade.app"
    public static let shared = SharedStore()

    private let d: UserDefaults
    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    public init(defaults: UserDefaults? = nil) {
        d = defaults ?? UserDefaults(suiteName: SharedStore.appGroup) ?? .standard
    }

    private func load<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? dec.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ key: String, _ value: T?) {
        if let value, let data = try? enc.encode(value) { d.set(data, forKey: key) } else { d.removeObject(forKey: key) }
    }

    public var settings: DriverSettings {
        get { load("settings", DriverSettings.self) ?? DriverSettings() }
        set { save("settings", newValue) }
    }

    public var stops: [Stop] {
        get { load("stops", [Stop].self) ?? [] }
        set { save("stops", Array(newValue.prefix(TripPlanner.maxStops))) }
    }

    public var notificationPrefs: NotificationPrefs {
        get { load("notificationPrefs", NotificationPrefs.self) ?? NotificationPrefs() }
        set { save("notificationPrefs", newValue) }
    }

    // MARK: Screen-recording timer (written by the screen-reader extension)

    public var broadcastStartedAt: Date? {
        get { load("broadcastStartedAt", Date.self) }
        set { save("broadcastStartedAt", newValue) }
    }

    /// Last time the reader checked in. If it stops checking in, it was ended or killed by iOS.
    public var broadcastHeartbeat: Date? {
        get { load("broadcastHeartbeat", Date.self) }
        set { save("broadcastHeartbeat", newValue) }
    }

    public func isBroadcasting(now: Date = Date()) -> Bool {
        guard broadcastStartedAt != nil, let beat = broadcastHeartbeat else { return false }
        return now.timeIntervalSince(beat) < 20
    }

    /// Shared folder both the app and the screen reader can write to.
    public static var containerURL: URL {
        #if os(iOS) || os(macOS)
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return url }
        #endif
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    public var currentLocation: Coord? {
        get { load("location", Coord.self) }
        set { save("location", newValue) }
    }

    // Offers the extension located, waiting for you to tap "Add to route".
    private struct Pending: Codable { var pickup: Stop; var dropoff: Stop; var at: Date }

    public func savePending(orderId: String, pickup: Stop, dropoff: Stop) {
        var all = load("pending", [String: Pending].self) ?? [:]
        all = all.filter { $0.value.at.timeIntervalSinceNow > -3600 } // keep the last hour
        all[orderId] = Pending(pickup: pickup, dropoff: dropoff, at: Date())
        save("pending", all)
    }

    /// Moves a pending offer into the route (cheapest order). Returns false if it can't fit.
    @discardableResult
    public func addPendingToRoute(orderId: String) -> Bool {
        guard let p = (load("pending", [String: Pending].self) ?? [:])[orderId] else { return false }
        var planner = TripPlanner(stops: stops)
        guard planner.addOrder(origin: currentLocation, pickup: p.pickup, dropoff: p.dropoff) else { return false }
        stops = planner.stops
        return true
    }
}
