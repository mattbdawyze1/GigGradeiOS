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
        rescue = nil
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
                rescue = nil
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
        if shouldAlert { lastKey = key; activePay = offer.pay; episodeAlerted = true; rescue = nil }
        let needShot = !shouldAlert && episodeShot == nil
        lock.unlock()
        if needShot, let jpeg = screenshot?() { lock.lock(); episodeShot = jpeg; lock.unlock() }
        if !shouldAlert {
            if sameOfferStillUp, let up = currentKey { retryIfNeeded(key: up, lines: lines, mapPins: mapPins, now: now) }
            return
        }

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
            var pickupCoord = await PlaceFinder.find(offer.pickupText, near: near)
            if pickupCoord == nil, let name = offer.pickupText, let town = PlaceFinder.town(in: offer.dropoffText) {
                pickupCoord = await PlaceFinder.find("\(name), \(town)", near: near) // name-only stores
            }
            var dropoffCoord = await PlaceFinder.find(offer.dropoffText, near: near)
            var estimated = false
            var streets: String?

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
                if dropoffCoord == nil, let s = await self.streetEstimate(lines: lines, pins: pins, pickup: pickupCoord, offer: offer) {
                    dropoffCoord = s.coord; estimated = true; streets = s.names
                }
            }

            let found = await self.finish(key: key, offer: offer, saved: saved, score: score, settings: settings,
                                          prefs: prefs, pickup: pickupCoord, dropoff: dropoffCoord,
                                          estimated: estimated, streets: streets, gate: gate)
            if !found {
                // Couldn't place the customer yet: keep re-reading the map while this offer stays on screen
                // (zoom in on the customer pin to help), and send an updated banner when it works.
                self.lock.lock()
                if self.lastKey == key {
                    self.rescue = Rescue(key: key, offer: offer, saved: saved, score: score, settings: settings,
                                         prefs: prefs, pickup: pickupCoord, until: Date().addingTimeInterval(90))
                }
                self.lock.unlock()
            }
        }
    }

    // MARK: Retry the map while the offer stays up (zoomed-in map, map that was still loading)

    private struct Rescue {
        let key: String
        let offer: Offer
        let saved: OfferRecord
        let score: Score
        let settings: DriverSettings
        let prefs: NotificationPrefs
        let pickup: Coord?
        let until: Date
        var lastTry = Date.distantPast
        var busy = false
    }
    private var rescue: Rescue?

    /// Called for every scan of an offer that already has its banner. Returns quickly unless a retry is due.
    private func retryIfNeeded(key: String, lines: [OCRLine], mapPins: ((GigApp) -> MapPins?)?, now: Date) {
        lock.lock()
        guard var r = rescue, r.key == key, !r.busy, now.timeIntervalSince(r.lastTry) >= 2 else { lock.unlock(); return }
        if now > r.until { rescue = nil; lock.unlock(); return }
        r.busy = true; r.lastTry = now
        rescue = r
        lock.unlock()

        let pins = mapPins?(r.offer.app) // must run now, while this frame is still here
        Task {
            var dropoff: Coord?
            var streets: String?
            if let pins, !pins.customers.isEmpty {
                if let me = store.currentLocation, let pc = r.pickup,
                   let est = MapLocator.locate(pins: pins, me: me, store: pc, statedMiles: r.offer.miles) {
                    dropoff = est.finalDropoff
                } else if let s = await streetEstimate(lines: lines, pins: pins, pickup: r.pickup, offer: r.offer) {
                    dropoff = s.coord; streets = s.names
                }
            }
            var found = false
            if let dropoff {
                found = await finish(key: key, offer: r.offer, saved: r.saved, score: r.score, settings: r.settings,
                                     prefs: r.prefs, pickup: r.pickup, dropoff: dropoff, estimated: true,
                                     streets: streets, gate: nil)
            }
            lock.lock()
            if found { rescue = nil } else if rescue?.key == key { rescue?.busy = false }
            lock.unlock()
        }
    }

    /// Places the customer pin at the two nearest street names printed on the map (e.g. after zooming in).
    private func streetEstimate(lines: [OCRLine], pins: MapPins, pickup: Coord?, offer: Offer) async -> (coord: Coord, names: String)? {
        guard let pin = StreetLabels.finalCustomer(pins) else { return nil }
        let names = StreetLabels.nearest(lines: lines, to: pin)
        guard names.count == 2 else { return nil }
        let near = pickup ?? store.currentLocation
        var town: String?
        if let near, let place = await PlaceFinder.describe(near) { town = PlaceFinder.town(in: place) }
        guard let c = await PlaceFinder.intersection(names[0], names[1], town: town, near: near),
              StreetLabels.plausible(dropoff: c, pickup: pickup, me: store.currentLocation, statedMiles: offer.miles)
        else { return nil }
        return (c, "\(names[0]) & \(names[1])")
    }

    /// Saves the locations, runs the on-the-way check and posts the banner.
    /// `gate` = first banner for this offer; nil = an update after the map was re-read.
    /// Returns true when the customer was located.
    @discardableResult
    private func finish(key: String, offer: Offer, saved: OfferRecord, score: Score, settings: DriverSettings,
                        prefs: NotificationPrefs, pickup: Coord?, dropoff: Coord?, estimated: Bool,
                        streets: String?, gate: PostOnce?) async -> Bool {
        let orderId = saved.id.uuidString
        let dayKey = OfferLog.dayKey(saved.date)
        let p = pickup.map { Stop(type: .pickup, label: offer.pickupText ?? "Pickup", location: $0, orderId: orderId) }
        let d = dropoff.map {
            Stop(type: .dropoff, label: estimated ? MapEstimate.label : (offer.dropoffText ?? "Dropoff"),
                 location: $0, orderId: orderId)
        }
        guard currentKey == key else { return d != nil } // a newer offer replaced this one

        let foundPickup = p?.location, foundDropoff = d?.location
        log.update(id: saved.id, dayKey: dayKey) {
            $0.pickupLocation = foundPickup
            $0.dropoffLocation = foundDropoff
            $0.dropoffEstimated = foundDropoff == nil ? nil : estimated
        }

        let planner = TripPlanner(stops: store.stops)
        let otw = planner.checkOnTheWay(origin: store.currentLocation ?? pickup, pickup: p, dropoff: d,
                                        pay: offer.pay, settings: settings)
        let note = otw.message
        log.update(id: saved.id, dayKey: dayKey) { $0.routeNote = note }
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
                var named = streets
                if named == nil { named = await PlaceFinder.describe(d.location) }
                place = named ?? "customer pin"
                let shown = place
                log.update(id: saved.id, dayKey: dayKey) { $0.dropoffText = "≈ \(shown) (from map)" }
            }
            dropoffInfo = DropoffInfo(place: place, estimated: estimated, milesFromYou: miles)
        }
        guard currentKey == key else { return d != nil }

        await Cloud.shared.queueOffer(id: saved.id, dayKey: dayKey) // route note + stops
        let firstBanner = gate?.claim() ?? false
        // Post the first banner, or an updated one (replaces the earlier banner) once the customer is found.
        if firstBanner || d != nil {
            OfferAlert.post(record: saved, offer: offer, score: score, settings: settings, prefs: prefs,
                            otw: otw, canAddToRoute: canAdd, silent: false, dropoff: dropoffInfo)
        }
        return d != nil
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
