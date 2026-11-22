import Foundation
import GigCore
import UserNotifications

/// The 👓 button's brain: turns a finished stop-list reading (Uber or DoorDash) into route stops, in the app's order,
/// with pickups linked to their dropoffs, skipping anything already in your route.
/// Runs in the app once the screen reader hands over the finished reading.
enum GuidePlanner {
    struct Result {
        var title: String
        var message: String
    }

    /// Works out which Trip Guide stops to add to `existing` (looked up on the map, linked, duplicates skipped).
    /// All addresses are looked up at the same time.
    static func plan(_ snap: GuideSnapshot, existing: [Stop], near here: Coord?) async
        -> (added: [Stop], extraLinks: [UUID: [String]], result: Result) {
        guard !snap.sections.isEmpty else {
            return ([], [:], Result(title: "Stop list not seen",
                               message: "GigGrade didn't see the stop list while 👓 was on. Accept the offer, tap 👓, then open Uber's Trip Guide (tap each stop to expand it) or DoorDash's Your route (gear icon; tap each stop for its address)."))
        }
        // Fill in addresses the list didn't show, from pickup/delivery screens read along the way.
        var sections = snap.sections
        for i in sections.indices where sections[i].address == nil {
            let key = TripGuide.norm(sections[i].name)
            if let a = snap.addresses?[key] {
                sections[i].address = a
            } else if sections[i].type == .pickup,
                      let ps = snap.pickupScreens.first(where: { sameName($0.store, sections[i].name) && $0.address != nil }) {
                sections[i].address = ps.address
            }
        }
        let links = TripGuide.links(sections, pickupScreens: snap.pickupScreens)
        var stops = existing
        let near = here ?? stops.last?.location

        // Every address that isn't already in the route.
        var lookups: [Int: String] = [:]
        for (i, section) in sections.enumerated() where match(section, in: existing) == nil {
            if let a = section.address { lookups[i] = a }
        }
        // All addresses are looked up in Apple Maps at the same time (about 1 second for the whole route).
        // Each one is still its own stop.
        var coords: [Int: Coord] = [:]
        await withTaskGroup(of: (Int, Coord?).self) { group in
            for (i, address) in lookups {
                group.addTask { (i, await PlaceFinder.find(address, near: near)) }
            }
            for await (i, c) in group { if let c { coords[i] = c } }
        }
        var newStops: [Stop] = []

        var added = 0, linked = 0, alreadyThere = 0, noAddress = 0, notFound = 0, full = 0
        var placed = [Int: Stop]()        // guide index -> stop (new or already in the route)
        var missing: [String] = []

        var addedIds = Set<UUID>()
        var extraLinks: [UUID: [String]] = [:]    // existing route stops that gain another pickup

        // The pickup order a dropoff belongs to, if it can be worked out.
        func pickupOrder(for i: Int) -> String? {
            guard sections[i].type == .dropoff, let link = links[i] else { return nil }
            switch link {
            case .pickup(let p): return placed[p]?.orderId
            case .store(let name): return stops.first { $0.type == .pickup && sameName(nameOnly($0.label), name) }?.orderId
            }
        }

        /// A second order going to a dropoff that's already there: link that stop to this order's pickup too.
        func addLink(to stop: Stop, for i: Int) {
            guard let order = pickupOrder(for: i), !stop.orderIds.contains(order),
                  let at = stops.firstIndex(where: { $0.id == stop.id }) else { return }
            var trial = stops
            trial[at].setOrders(stop.orderIds.filter { id in stops.contains { $0.type == .pickup && $0.orderId == id } } + [order])
            guard TripPlanner.isValidOrder(trial) else { return } // its pickup comes after it: leave as is
            stops = trial
            placed[i] = trial[at]
            linked += 1
            if let n = newStops.firstIndex(where: { $0.id == stop.id }) {
                newStops[n] = trial[at]
            } else {
                extraLinks[stop.id] = trial[at].orderIds
            }
        }

        for (i, section) in sections.enumerated() {
            // Already in the route? (same address, or same name) Then it isn't added again.
            if let existing = match(section, in: stops) {
                placed[i] = existing
                if !addedIds.contains(existing.id) { alreadyThere += 1 } // a store listed twice isn't "already there"
                addLink(to: existing, for: i)
                continue
            }
            guard let address = section.address else {
                noAddress += 1
                missing.append(section.name)
                continue
            }
            guard let coord = coords[i] else {
                notFound += 1
                missing.append(section.name)
                continue
            }
            // Same spot already in the route (e.g. a store listed twice under different numbers,
            // or two orders going to one address): it's only added once.
            if let dup = stops.first(where: { $0.type == section.type && Geo.straightMiles($0.location, coord) < 0.03 }) {
                placed[i] = dup
                if !addedIds.contains(dup.id) { alreadyThere += 1 }
                addLink(to: dup, for: i)
                continue
            }
            guard stops.count < TripPlanner.maxStops else { full += 1; continue }

            // Which order does it belong to? Pickups start their own; dropoffs join their pickup's.
            var orderId = UUID().uuidString
            var didLink = false
            if let order = pickupOrder(for: i) { orderId = order; didLink = true }
            // Two fields: the name (store / customer) and the full address.
            let label = section.name
            var trial = stops + [Stop(type: section.type, label: label, location: coord, orderId: orderId, address: address)]
            if didLink, !TripPlanner.isValidOrder(trial) { // never put a dropoff ahead of its pickup
                trial = stops + [Stop(type: section.type, label: label, location: coord, orderId: UUID().uuidString,
                                      address: address)]
                didLink = false
            }
            if didLink { linked += 1 }
            stops = trial
            placed[i] = trial.last!
            addedIds.insert(trial.last!.id)
            newStops.append(trial.last!)
            added += 1
        }

        var lines: [String] = []
        if added == 0 {
            lines.append(linked > 0 ? "No new stops; linked \(linked) dropoff\(linked == 1 ? "" : "s") to another pickup." : "No new stops added.")
        } else {
            lines.append("Added \(added) stop\(added == 1 ? "" : "s")" + (linked > 0 ? ", \(linked) link\(linked == 1 ? "" : "s") to pickups." : "."))
        }
        if alreadyThere > 0 { lines.append("\(alreadyThere) already in your route.") }
        if noAddress > 0 { lines.append("\(noAddress) skipped: no address seen. Tap them open in Uber's Trip Guide / DoorDash's Your route, then tap 👓 again.") }
        if notFound > 0 { lines.append("\(notFound) address\(notFound == 1 ? "" : "es") couldn't be found on the map.") }
        if full > 0 { lines.append("\(full) not added: the route is full (\(TripPlanner.maxStops) stops).") }
        if !missing.isEmpty { lines.append("Missing: " + missing.joined(separator: ", ")) }
        let changed = added > 0 || linked > 0
        return (newStops, extraLinks, Result(title: changed ? "Route updated" : "Nothing new", message: lines.joined(separator: "\n")))
    }

    // MARK: Helpers

    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = TripGuide.norm(a), y = TripGuide.norm(b)
        return !x.isEmpty && !y.isEmpty && (x == y || x.contains(y) || y.contains(x))
    }

    /// A route stop that is this Trip Guide stop: same house number + street, or (for stops without an address
    /// read yet) the same name, e.g. a pickup you added from an offer banner.
    static func match(_ section: GuideSection, in stops: [Stop]) -> Stop? {
        // Same address (house number + street) of the same kind: never added twice.
        if let address = section.address, let key = TripGuide.addressKey(address),
           let s = stops.first(where: { $0.type == section.type
                                        && TripGuide.addressKey($0.nameAndAddress.address ?? $0.label) == key }) {
            return s
        }
        // Same name (e.g. a store added from an offer banner, or a stop 👓 added before).
        return stops.first { $0.type == section.type && sameName(nameOnly($0.label), section.name) }
    }

    /// The name part of a label (older stops: "Kevin D. · 27 Virgil Dr" -> "Kevin D.").
    static func nameOnly(_ label: String) -> String {
        label.components(separatedBy: " · ").first ?? label
    }

    /// The notification for a finished reading. Offers come first: if an offer banner went out in the last
    /// 15 seconds, this waits until that banner has had its moment, and it ranks below offer banners.
    static func notify(_ result: Result) async {
        let center = UNUserNotificationCenter.current()
        if let offer = await center.deliveredNotifications().first(where: { $0.request.identifier == OfferAlert.requestId }) {
            let age = Date().timeIntervalSince(offer.date)
            if age < 15 { try? await Task.sleep(nanoseconds: UInt64((15 - age) * 1_000_000_000)) }
        }
        let c = UNMutableNotificationContent()
        c.title = result.title == "Route updated" ? "🗺️ Route updated" : "👓 \(result.title)"
        c.body = result.message
        c.sound = .default
        c.interruptionLevel = .active
        c.relevanceScore = 0.3 // offer banners are 1.0
        try? await center.add(UNNotificationRequest(identifier: "giggrade.route", content: c, trigger: nil))
    }
}
