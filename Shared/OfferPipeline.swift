import Foundation
import GigCore

/// Screen text in -> offer logged (with screenshot) -> one banner with the on-the-way verdict.
/// Also notes offers it couldn't read (Missed offers log) so they can be diagnosed.
final class OfferPipeline {
    static let shared = OfferPipeline()

    private let store = SharedStore.shared
    private let log = OfferLog.shared
    private let lock = NSLock()
    private var lastKey: String?          // offer whose banner is currently up (confirm key)
    private var activePay: Double?        // pay of that offer
    private var lastSeen = Date.distantPast
    private var candidateKey: String?     // a new reading waiting to be confirmed
    private var candidateCount = 0

    // Missed-offer tracking for the current "offer on screen" episode.
    private var episodeActive = false
    private var episodeAlerted = false
    private var episodeLogged = false
    private var episodeUnreadable = 0
    private var episodeKeys: [String] = []
    private var episodeText = ""
    private var episodeShot: Data?
    private var lastOfferishAt = Date.distantPast
    private var lastMissLoggedAt = Date.distantPast

    private var currentKey: String? { lock.lock(); defer { lock.unlock() }; return lastKey }

    func reset() {
        lock.lock()
        lastKey = nil; activePay = nil; candidateKey = nil; candidateCount = 0
        resetEpisode()
        lock.unlock()
    }

    private func resetEpisode() {
        episodeActive = false; episodeAlerted = false; episodeLogged = false
        episodeUnreadable = 0; episodeKeys = []; episodeText = ""; episodeShot = nil
    }

    /// Readings must match on pay + miles (minutes and map labels can flicker between scans).
    private func confirmKey(_ o: Offer) -> String { "\(o.app.rawValue)|\(o.pay)|\(o.miles ?? -1)" }

    /// Old entry point (sample offer, tests).
    func handle(text: String, screenshot: (() -> Data?)? = nil, mapPins: ((GigApp) -> MapPins?)? = nil,
                immediate: Bool = false) {
        handle(lines: text.components(separatedBy: .newlines).map { OCRLine($0) },
               screenshot: screenshot, mapPins: mapPins, immediate: immediate)
    }

    /// Rules so one offer = one banner:
    /// - an offer must read the same pay + miles on 2 scans in a row before it alerts;
    /// - while an offer stays on screen, nothing new alerts unless the pay itself changes;
    /// - once no offer has been seen for 3 seconds, the screen counts as cleared.
    ///
    /// - Parameters:
    ///   - screenshot: returns a JPEG of this frame (called only when needed).
    ///   - mapPins: finds the pins on this frame's offer map for the given app (called only for new offers).
    ///   - immediate: skip the 2-scan check (used by "Test with a sample offer").
    func handle(lines: [OCRLine], screenshot: (() -> Data?)? = nil, mapPins: ((GigApp) -> MapPins?)? = nil,
                immediate: Bool = false) {
        let now = Date()
        let text = lines.map(\.text).joined(separator: "\n")

        guard let offer = OfferParser.parse(lines: lines) else {
            var miss: (reason: String, text: String, shot: Data?)?
            lock.lock()
            if OfferParser.looksOfferish(text) {
                // An offer seems to be on screen but can't be read.
                lastOfferishAt = now
                episodeActive = true
                episodeUnreadable += 1
                episodeText = text
                if episodeUnreadable == 3, !episodeAlerted, !episodeLogged, now.timeIntervalSince(lastMissLoggedAt) > 20 {
                    episodeLogged = true
                    lastMissLoggedAt = now
                    miss = (OfferParser.diagnose(text) ?? "Offer couldn't be read", text, nil)
                }
            } else if now.timeIntervalSince(max(lastSeen, lastOfferishAt)) > 3 {
                // Screen cleared. If an offer was readable but never confirmed, log why.
                if episodeActive, !episodeAlerted, !episodeLogged, !episodeKeys.isEmpty,
                   now.timeIntervalSince(lastMissLoggedAt) > 20 {
                    lastMissLoggedAt = now
                    let reason = episodeKeys.count > 1
                        ? "Numbers changed between reads: " + episodeKeys.prefix(4).joined(separator: " → ")
                        : "Offer disappeared before it was read twice"
                    miss = (reason, episodeText, episodeShot)
                }
                lastKey = nil; activePay = nil; candidateKey = nil; candidateCount = 0
                resetEpisode()
            }
            lock.unlock()
            if let miss {
                let shot = miss.shot ?? (miss.text == text ? screenshot?() : nil)
                Task { await Cloud.shared.reportMissed(reason: miss.reason, text: miss.text, jpeg: shot) }
            }
            return
        }

        let key = confirmKey(offer)
        lock.lock()
        lastSeen = now
        lastOfferishAt = now
        episodeActive = true
        episodeText = text
        if episodeKeys.last != key { episodeKeys.append(key) }
        if key == candidateKey { candidateCount += 1 } else { candidateKey = key; candidateCount = 1 }
        let confirmed = immediate || candidateCount >= 2
        let sameOfferStillUp = activePay.map { abs($0 - offer.pay) < 0.01 } ?? false
        let shouldAlert = confirmed && !sameOfferStillUp && key != lastKey
        if shouldAlert { lastKey = key; activePay = offer.pay; episodeAlerted = true }
        let needShot = !shouldAlert && episodeShot == nil
        lock.unlock()
        if needShot, let jpeg = screenshot?() { lock.lock(); episodeShot = jpeg; lock.unlock() }
        if !shouldAlert { return }

        let settings = store.settings
        let prefs = store.notificationPrefs
        let score = OfferScorer.score(offer, settings)

        // 1) Log it (with a screenshot). Find the map pins while this frame is still here.
        var record = OfferRecord(date: now, app: offer.app, pay: offer.pay, miles: offer.miles, minutes: offer.minutes,
                                 pickupText: offer.pickupText, dropoffText: offer.dropoffText, grade: score.grade,
                                 category: score.category, dollarsPerHour: score.dollarsPerHour,
                                 dollarsPerMile: score.dollarsPerMile)
        if let jpeg = screenshot?() { record.screenshotFile = log.saveScreenshot(jpeg, id: record.id) }
        let pins: MapPins? = mapPins?(offer.app)
        log.append(record)
        let dayKey = OfferLog.dayKey(record.date)
        Task { await Cloud.shared.queueOffer(id: record.id, dayKey: dayKey) }

        // ONE banner per offer: wait for the on-the-way check, but never more than 3.5 s.
        let saved = record
        let gate = PostOnce()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.currentKey == key, gate.claim() else { return }
            OfferAlert.post(record: saved, offer: offer, score: score, settings: settings, prefs: prefs,
                            otw: nil, canAddToRoute: false, silent: false)
        }

        // 2) Locate pickup/dropoff (text first, map as backup and cross-check), run the check, post.
        Task {
            let near = store.currentLocation
            let orderId = saved.id.uuidString
            var pickupCoord = await PlaceFinder.find(offer.pickupText, near: near)
            if pickupCoord == nil, let name = offer.pickupText, let town = PlaceFinder.town(in: offer.dropoffText) {
                pickupCoord = await PlaceFinder.find("\(name), \(town)", near: near) // name-only stores
            }
            var dropoffCoord = await PlaceFinder.find(offer.dropoffText, near: near)
            var estimated = false

            if let pins {
                await Cloud.shared.pullSettingsIntoStore(force: true) // freshest GPS: the map's arrow/dot is "now"
                if let me = store.currentLocation {
                    if let pc = pickupCoord,
                       let est = MapLocator.locate(pins: pins, me: me, store: pc, statedMiles: offer.miles) {
                        // Use the map when there's no dropoff address, or when the address lookup landed
                        // far from where the map's pin actually is (wrong match).
                        if dropoffCoord == nil || Geo.straightMiles(dropoffCoord!, est.finalDropoff) > 1.0 {
                            dropoffCoord = est.finalDropoff
                            estimated = true
                        }
                    }
                    if pickupCoord == nil, let dc = dropoffCoord,
                       let pc = MapLocator.locatePickup(pins: pins, me: me, dropoff: dc) {
                        pickupCoord = pc // store name Apple Maps couldn't find
                    }
                }
            }

            let p = pickupCoord.map { Stop(type: .pickup, label: offer.pickupText ?? "Pickup", location: $0, orderId: orderId) }
            let d = dropoffCoord.map {
                Stop(type: .dropoff, label: estimated ? MapEstimate.label : (offer.dropoffText ?? "Dropoff"),
                     location: $0, orderId: orderId)
            }
            guard self.currentKey == key else { return } // a newer offer replaced this one

            let foundPickup = p?.location, foundDropoff = d?.location, wasEstimated = estimated
            log.update(id: saved.id, dayKey: OfferLog.dayKey(saved.date)) {
                $0.pickupLocation = foundPickup
                $0.dropoffLocation = foundDropoff
                $0.dropoffEstimated = foundDropoff == nil ? nil : wasEstimated
            }

            let planner = TripPlanner(stops: store.stops)
            let otw = planner.checkOnTheWay(origin: store.currentLocation ?? near, pickup: p, dropoff: d,
                                            pay: offer.pay, settings: settings)
            let note = otw.message
            log.update(id: saved.id, dayKey: OfferLog.dayKey(saved.date)) { $0.routeNote = note }
            var canAdd = false
            if let p, let d {
                store.savePending(orderId: orderId, pickup: p, dropoff: d) // also sent to the cloud with the offer
                canAdd = planner.canAdd(2)
            }

            var dropoffInfo: DropoffInfo?
            if let d {
                let miles = store.currentLocation.map { Geo.roadMiles($0, d.location) }
                var place = offer.dropoffText ?? d.label
                if estimated {
                    let named = await PlaceFinder.describe(d.location)
                    place = named ?? "customer pin"
                    let shown = place
                    log.update(id: saved.id, dayKey: OfferLog.dayKey(saved.date)) { $0.dropoffText = "≈ \(shown) (from map)" }
                }
                dropoffInfo = DropoffInfo(place: place, estimated: estimated, milesFromYou: miles)
            }
            guard self.currentKey == key else { return }

            await Cloud.shared.queueOffer(id: saved.id, dayKey: OfferLog.dayKey(saved.date)) // route note + stops
            if gate.claim() {
                OfferAlert.post(record: saved, offer: offer, score: score, settings: settings, prefs: prefs,
                                otw: otw, canAddToRoute: canAdd, silent: false, dropoff: dropoffInfo)
            }
        }
    }
}

/// Lets exactly one of two racing paths (result ready / deadline reached) post the banner.
final class PostOnce {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
