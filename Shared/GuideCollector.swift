import Foundation
import GigCore

/// Runs in the screen reader. Does nothing until you press 👓 on an accepted offer in GigGrade.
/// Then it reads Uber's Trip Guide (pieced together as you scroll and expand stops) and pickup screens,
/// or DoorDash's "Your route" list (tap each stop for its address) and "Pick up by / Deliver by" screens.
/// Once you leave the list it hands the finished reading to the app, which updates your route.
final class GuideCollector {
    static let shared = GuideCollector()

    private let lock = NSLock()
    private var request: GuideRequest?                  // the 👓 press being answered (nil = not reading)
    private var handled = Set<String>()                 // presses already answered
    private var snapshot = GuideSnapshot(seenAt: .distantPast, sections: [], pickupScreens: [])
    private var lastGuideAt = Date.distantPast
    private var lastPoll = Date.distantPast
    private var polling = false
    private var finishing = false

    /// Done when the Trip Guide has been off screen this long (you went back to driving / another screen).
    static let leftGuideAfter: TimeInterval = 5
    /// A press is answered within this long, or given up on.
    static let requestTimeout: TimeInterval = 15 * 60
    /// How often to check for a new 👓 press.
    static let pollEvery: TimeInterval = 4

    // MARK: Every scanned frame

    func observe(_ lines: [OCRLine], now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard let req = request, !finishing else { return }

        let lower = lines.map { $0.text.lowercased() }
        let uberGuide = lower.contains { $0.replacingOccurrences(of: " ", with: "") == "tripguide" }
        let doorDashRoute = !uberGuide && DoorDashGuide.isRouteScreen(lines)

        // The stop list: Uber's Trip Guide, or DoorDash's "Your route" (with its pop-ups).
        if uberGuide || doorDashRoute {
            let screen = uberGuide ? TripGuide.sections(lines) : DoorDashGuide.sections(lines)
            if !screen.isEmpty {
                snapshot.sections = TripGuide.merge(snapshot.sections, with: screen)
                lastGuideAt = now
                snapshot.seenAt = now
            }
        }

        // Who's picked up where (and addresses): Uber's pickup screen, DoorDash's "Pick up by / Deliver by" screen.
        var link: PickupScreen?
        if lower.contains(where: { $0.hasPrefix("pick up") }), let ps = TripGuide.pickupScreen(lines, at: now) {
            link = ps
            if let a = ps.address { remember(ps.store, a) }
        } else if !uberGuide, !doorDashRoute,
                  lower.contains(where: { $0.hasPrefix("pick up by") || $0.hasPrefix("deliver by") }),
                  let task = DoorDashGuide.taskScreen(lines, at: now) {
            link = task.link
            if let a = task.address { remember(task.name, a) }
        }
        if let ps = link, !ps.customers.isEmpty {
            var list = snapshot.pickupScreens.filter { TripGuide.norm($0.store) != TripGuide.norm(ps.store) }
            var merged = ps
            if let old = snapshot.pickupScreens.first(where: { TripGuide.norm($0.store) == TripGuide.norm(ps.store) }) {
                merged.customers = Array(Set(old.customers + ps.customers)).sorted()
                if merged.address == nil { merged.address = old.address }
            }
            list.append(merged)
            snapshot.pickupScreens = list
        }
        snapshot.requestId = req.id
    }

    /// Addresses read off pickup/delivery screens, used when a stop in the list wasn't tapped open.
    private func remember(_ name: String, _ address: String) {
        var map = snapshot.addresses ?? [:]
        map[TripGuide.norm(name)] = address
        snapshot.addresses = map
    }

    // MARK: Every few seconds (from the screen reader's clock)

    func tick(now: Date = Date()) {
        let lastOffer = OfferPipeline.shared.lastOfferSeen
        lock.lock()
        let req = request
        // Only an offer that shows up after you pressed 👓 counts (not the one you just accepted).
        let offerUp = req.map { lastOffer > $0.armedAt } ?? false
        let seenGuide = !snapshot.sections.isEmpty
        let leftGuide = now.timeIntervalSince(lastGuideAt) >= Self.leftGuideAfter
        let timedOut = req.map { now.timeIntervalSince($0.armedAt) > Self.requestTimeout } ?? false
        // An offer popping up ends the reading right away: whatever was read goes into the route,
        // and pressing 👓 again later picks up the rest (stops already added are skipped).
        let shouldFinish = req != nil && !finishing && (offerUp || (seenGuide && leftGuide) || timedOut)
        if shouldFinish { finishing = true }
        let shouldPoll = !polling && now.timeIntervalSince(lastPoll) >= Self.pollEvery
        if shouldPoll { polling = true; lastPoll = now }
        lock.unlock()

        if shouldFinish { finish() }
        if shouldPoll { Task { await poll() } }
    }

    /// Looks for a new 👓 press (or a cancel) from the app.
    private func poll() async {
        defer { lock.lock(); polling = false; lock.unlock() }
        guard let data = await Cloud.shared.downloadGuideRequest(),
              let req = try? GuideStore.decoder.decode(GuideRequest.self, from: data) else { return }
        lock.lock()
        defer { lock.unlock() }
        let fresh = Date().timeIntervalSince(req.armedAt) < Self.requestTimeout
        if req.recordId.isEmpty {                    // cancelled in the app
            if request?.id != nil, !finishing { request = nil }
            handled.insert(req.id)
            return
        }
        guard fresh, !handled.contains(req.id), request?.id != req.id else { return }
        // New press: start a clean reading.
        request = req
        finishing = false
        let keep = snapshot.pickupScreens.filter { Date().timeIntervalSince($0.seenAt) < 3 * 3600 }
        let addresses = snapshot.addresses
        snapshot = GuideSnapshot(seenAt: .distantPast, sections: [], pickupScreens: keep, requestId: req.id)
        snapshot.addresses = addresses
        lastGuideAt = .distantPast
    }

    /// Hands the finished reading to the app.
    private func finish() {
        lock.lock()
        var finished = snapshot
        finished.complete = true
        if let id = request?.id { handled.insert(id); finished.requestId = id }
        request = nil
        lock.unlock()

        guard let data = try? GuideStore.encoder.encode(finished) else { finishDone(); return }
        GuideStore.saveLocal(data)
        Task {
            await Cloud.shared.uploadGuide(data)
            self.finishDone()
        }
    }

    private func finishDone() {
        lock.lock(); finishing = false; lock.unlock()
    }
}

/// Where the screen reader leaves the finished Trip Guide for the app.
enum GuideStore {
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private static var localURL: URL { SharedStore.containerURL.appendingPathComponent("trip_guide.json") }

    static func saveLocal(_ data: Data) {
        guard SharedStore.sharedStorageAvailable else { return }
        try? data.write(to: localURL, options: .atomic)
    }

    /// The finished reading for this 👓 press, if it's ready.
    static func finished(for requestId: String) async -> GuideSnapshot? {
        if SharedStore.sharedStorageAvailable, let data = try? Data(contentsOf: localURL),
           let snap = try? decoder.decode(GuideSnapshot.self, from: data),
           snap.requestId == requestId, snap.complete == true {
            return snap
        }
        if let data = await Cloud.shared.downloadGuide(),
           let snap = try? decoder.decode(GuideSnapshot.self, from: data),
           snap.requestId == requestId, snap.complete == true {
            return snap
        }
        return nil
    }
}
