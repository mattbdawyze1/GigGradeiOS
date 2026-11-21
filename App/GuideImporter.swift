import Foundation
import GigCore
import UserNotifications

/// The 👓 button: puts every stop from Uber's Trip Guide into the Route tab, in Uber's order,
/// with pickups linked to their dropoffs, skipping anything already in your route.
@MainActor
enum GuideImporter {
    struct Result {
        var title: String
        var message: String
    }

    /// Adds the stops from a finished Trip Guide reading to the route.
    static func apply(_ snap: GuideSnapshot) async -> Result {
        guard !snap.sections.isEmpty else {
            return Result(title: "Trip Guide not seen",
                          message: "GigGrade didn't see Uber's Trip Guide while 👓 was on. Accept the offer, tap 👓, then open the Trip Guide in Uber and tap each stop to expand it.")
        }
        let store = SharedStore.shared
        let links = TripGuide.links(snap.sections, pickupScreens: snap.pickupScreens)
        var stops = store.stops
        let near = store.currentLocation ?? stops.last?.location

        var added = 0, linked = 0, alreadyThere = 0, noAddress = 0, notFound = 0, full = 0
        var placed = [Int: Stop]()        // guide index -> stop (new or already in the route)
        var missing: [String] = []

        for (i, section) in snap.sections.enumerated() {
            // Already in the route? (same address, or same place with the same name)
            if let existing = match(section, in: stops) {
                placed[i] = existing
                alreadyThere += 1
                continue
            }
            guard let address = section.address else {
                noAddress += 1
                missing.append(section.name)
                continue
            }
            guard let coord = await PlaceFinder.find(address, near: near) else {
                notFound += 1
                missing.append(section.name)
                continue
            }
            if let dup = stops.first(where: { Geo.straightMiles($0.location, coord) < 0.03 && sameType($0, section) }) {
                placed[i] = dup // same spot already in the route under another name
                alreadyThere += 1
                continue
            }
            guard stops.count < TripPlanner.maxStops else { full += 1; continue }

            // Which order does it belong to? Pickups start their own; dropoffs join their pickup's.
            var orderId = UUID().uuidString
            var didLink = false
            if section.type == .dropoff, let link = links[i] {
                switch link {
                case .pickup(let p):
                    if let pickup = placed[p] { orderId = pickup.orderId; didLink = true }
                case .store(let name):
                    if let pickup = stops.first(where: { $0.type == .pickup && sameName(nameOnly($0.label), name) }) {
                        orderId = pickup.orderId; didLink = true
                    }
                }
            }
            let label = section.type == .pickup ? section.name : "\(section.name) · \(street(address))"
            var trial = stops + [Stop(type: section.type, label: label, location: coord, orderId: orderId)]
            if didLink, !TripPlanner.isValidOrder(trial) { // never put a dropoff ahead of its pickup
                trial = stops + [Stop(type: section.type, label: label, location: coord, orderId: UUID().uuidString)]
                didLink = false
            }
            if didLink { linked += 1 }
            stops = trial
            placed[i] = trial.last!
            added += 1
        }

        if added > 0 {
            store.stops = stops
            NotificationCenter.default.post(name: .routeChanged, object: nil)
            Task { await Cloud.shared.schedulePushState() }
        }

        var lines: [String] = []
        lines.append(added == 0 ? "No new stops added." : "Added \(added) stop\(added == 1 ? "" : "s")" + (linked > 0 ? ", linked \(linked) dropoff\(linked == 1 ? "" : "s") to its pickup." : "."))
        if alreadyThere > 0 { lines.append("\(alreadyThere) already in your route.") }
        if noAddress > 0 { lines.append("\(noAddress) skipped: expand them in the Trip Guide so their address shows, then tap 👓 again.") }
        if notFound > 0 { lines.append("\(notFound) address\(notFound == 1 ? "" : "es") couldn't be found on the map.") }
        if full > 0 { lines.append("\(full) not added: the route is full (\(TripPlanner.maxStops) stops).") }
        if !missing.isEmpty { lines.append("Missing: " + missing.joined(separator: ", ")) }
        return Result(title: added > 0 ? "Route updated" : "Nothing new", message: lines.joined(separator: "\n"))
    }

    // MARK: Helpers

    private static func sameType(_ s: Stop, _ g: GuideSection) -> Bool { s.type == g.type }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        let x = TripGuide.norm(a), y = TripGuide.norm(b)
        return !x.isEmpty && !y.isEmpty && (x == y || x.contains(y) || y.contains(x))
    }

    /// "27 Virgil Dr, Brentwood, NY" -> "27 Virgil Dr"
    private static func street(_ address: String) -> String {
        address.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? address
    }

    /// A route stop that is this Trip Guide stop: same house number + street, or (for stops without an address
    /// read yet) the same name, e.g. a pickup you added from an offer banner.
    private static func match(_ section: GuideSection, in stops: [Stop]) -> Stop? {
        if let address = section.address, let key = TripGuide.addressKey(address) {
            if let s = stops.first(where: { TripGuide.addressKey($0.label) == key }) { return s }
        }
        return stops.first { $0.type == section.type && sameName(nameOnly($0.label), section.name) }
    }

    /// The name part of a label ("Kevin D. · 27 Virgil Dr" -> "Kevin D.").
    private static func nameOnly(_ label: String) -> String {
        label.components(separatedBy: " · ").first ?? label
    }
}

/// The 👓 button's on/off state. On = the screen reader is reading Uber's Trip Guide for this offer.
/// When it finishes (you leave the Trip Guide), the app adds the stops, sends a "Route updated"
/// notification and turns the button off.
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
        requestId = nil; armedRecordId = nil; armedAt = nil
        defaults.removeObject(forKey: "guide.request")
        defaults.removeObject(forKey: "guide.record")
        defaults.removeObject(forKey: "guide.armedAt")
    }

    /// Called every few seconds (Offers screen) and on location updates (app in the background):
    /// when the screen reader has finished, update the route and notify.
    func pollIfDue() async {
        guard let id = requestId, !applying, Date().timeIntervalSince(lastPoll) >= 4 else { return }
        lastPoll = Date()
        if let at = armedAt, Date().timeIntervalSince(at) > Self.timeout {
            turnOff()
            notify(title: "👓 Trip Guide not read", body: "GigGrade didn't see Uber's Trip Guide in time. Tap 👓 again and open the Trip Guide in Uber.")
            return
        }
        guard let snap = await GuideStore.finished(for: id), requestId == id else { return }
        applying = true
        let result = await GuideImporter.apply(snap)
        turnOff()
        applying = false
        notify(title: result.title == "Route updated" ? "🗺️ Route updated" : "👓 \(result.title)", body: result.message)
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
