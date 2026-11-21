import Foundation
import GigCore
import UserNotifications

/// Drops the planned stops into the Route tab.
@MainActor
enum GuideImporter {
    /// Returns how many stops were added.
    @discardableResult
    static func apply(_ prepared: [Stop], extraLinks: [UUID: [String]] = [:]) -> Int {
        let store = SharedStore.shared
        var stops = store.stops
        var added = 0
        // Dropoffs already in the route that now also belong to another pickup.
        for (id, orders) in extraLinks {
            guard let at = stops.firstIndex(where: { $0.id == id }) else { continue }
            var trial = stops
            trial[at].setOrders(stops[at].orderIds + orders)
            if TripPlanner.isValidOrder(trial) { stops = trial; added += 1 }
        }
        for var stop in prepared {
            // Already there (e.g. 👓 pressed twice, or you added it meanwhile)?
            if stops.contains(where: { $0.id == stop.id }) { continue }
            // Same spot already in the route: never added twice.
            if stops.contains(where: { $0.type == stop.type && Geo.straightMiles($0.location, stop.location) < 0.03 }) { continue }
            guard stops.count < TripPlanner.maxStops else { break }
            if !TripPlanner.isValidOrder(stops + [stop]) { stop.orderId = UUID().uuidString } // its pickup went missing
            stops.append(stop)
            added += 1
        }
        if added > 0 {
            store.stops = stops
            NotificationCenter.default.post(name: .routeChanged, object: nil)
            Task { await Cloud.shared.schedulePushState() }
        }
        return added
    }
}

/// The 👓 button's on/off state. On = the screen reader is reading Uber's Trip Guide for this offer.
/// When the screen reader finishes (5 s after you leave the Trip Guide), the app adds the stops,
/// sends a "Route updated" notification and turns the button off.
@MainActor
final class GuideSession: ObservableObject {
    static let shared = GuideSession()

    @Published private(set) var armedRecordId: UUID?
    private var requestId: String?
    private var armedAt: Date?
    private var lastPoll = Date.distantPast
    private var applying = false

    private let defaults = UserDefaults.standard
    static let timeout: TimeInterval = 16 * 60

    private init() {
        if let id = defaults.string(forKey: "guide.request"), let rec = defaults.string(forKey: "guide.record"),
           let at = defaults.object(forKey: "guide.armedAt") as? Date, Date().timeIntervalSince(at) < Self.timeout {
            requestId = id; armedRecordId = UUID(uuidString: rec); armedAt = at
            startTimer()
        }
    }

    func isOn(_ record: OfferRecord) -> Bool { armedRecordId == record.id }

    /// Tap 👓: turn on (or off, if it's already on for this offer).
    func toggle(_ record: OfferRecord) async -> String? {
        if isOn(record) { await cancel(); return nil }
        let req = GuideRequest(recordId: record.id.uuidString)
        guard let data = try? GuideStore.encoder.encode(req),
              await Cloud.shared.uploadGuideRequest(data) else {
            return "Couldn't reach the cloud, so the screen reader can't be told to read the Trip Guide. Check the connection on Home."
        }
        requestId = req.id; armedRecordId = record.id; armedAt = req.armedAt
        startTimer()
        defaults.set(req.id, forKey: "guide.request")
        defaults.set(record.id.uuidString, forKey: "guide.record")
        defaults.set(req.armedAt, forKey: "guide.armedAt")
        return nil
    }

    func cancel() async {
        let cancel = GuideRequest(recordId: "") // tells the screen reader to stop
        if let data = try? GuideStore.encoder.encode(cancel) { _ = await Cloud.shared.uploadGuideRequest(data) }
        turnOff()
    }

    private func turnOff() {
        timer?.invalidate(); timer = nil
        requestId = nil; armedRecordId = nil; armedAt = nil
        defaults.removeObject(forKey: "guide.request")
        defaults.removeObject(forKey: "guide.record")
        defaults.removeObject(forKey: "guide.armedAt")
    }

    /// Called every second while 👓 is on (and on location updates in the background):
    /// when the screen reader has finished, update the route and notify.
    func pollIfDue() async {
        guard let id = requestId, !applying, Date().timeIntervalSince(lastPoll) >= 1 else { return }
        lastPoll = Date()
        if let at = armedAt, Date().timeIntervalSince(at) > Self.timeout {
            turnOff()
            notify(title: "👓 Stop list not read", body: "GigGrade didn't see Uber's Trip Guide or DoorDash's Your route in time. Tap 👓 again and open it.")
            return
        }
        guard let snap = await GuideStore.finished(for: id), requestId == id else { return }
        applying = true
        let plan = await GuidePlanner.plan(snap, existing: SharedStore.shared.stops, near: SharedStore.shared.currentLocation)
        GuideImporter.apply(plan.added, extraLinks: plan.extraLinks)
        turnOff()
        applying = false
        await GuidePlanner.notify(plan.result)
    }

    // While 👓 is on and GigGrade is open, check the cloud every second (in the background, location updates do it).
    private var timer: Timer?
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in await GuideSession.shared.pollIfDue() }
        }
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.interruptionLevel = .active
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "giggrade.route", content: c, trigger: nil))
    }
}
