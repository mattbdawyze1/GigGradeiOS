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

    /// Every store and customer placed for an offer (card addresses first, then map pins), for the pickup
    /// check and batch offers. Keyed by the offer.
    private struct Batch {
        var stores: [(coord: Coord, estimated: Bool)]
        var customers: [Coord]
        var unchecked: Int
    }
    private var batches: [String: Batch] = [:]
    private var trails: [String: Trail] = [:]
    private func batch(_ key: String) -> Batch? { lock.lock(); defer { lock.unlock() }; return batches[key] }

    /// Last time an offer (readable or not) was on screen. 👓 ends its reading when an offer shows up after the press.
    var lastOfferSeen: Date { lock.lock(); defer { lock.unlock() }; return max(lastSeen, lastOfferishAt) }

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
        // DoorDash: the banner goes out right away, and the route check waits until you tap the customer pin.
        let saved = record
        startTrail(key: key, record: saved, text: text)
        let gate = PostOnce()
        let holdVerdict = offer.app == .doordash
        DispatchQueue.global().asyncAfter(deadline: .now() + (holdVerdict ? 0 : 3.5)) { [weak self] in
            guard let self, self.currentKey == key, gate.claim() else { return }
            if !holdVerdict {
                self.noteIssue(key, .noVerdictInTime, "the route check wasn't done after 3.5 s, so the banner went out without it")
            }
            OfferAlert.post(record: saved, offer: offer, score: score, settings: settings, prefs: prefs,
                            otw: nil, canAddToRoute: false, silent: false,
                            hint: holdVerdict ? OfferAlert.tapPinHint : nil)
        }

        // 2) Locate pickup/dropoff (text first, map as backup and cross-check), run the check, post.
        Task {
            let near = store.currentLocation
            var pickupCoord: Coord?
            if offer.app == .uber {
                // Uber: every search result is checked (name, distance vs. the trip's miles, house number + street).
                let found = await PlaceFinder.findStore(offer.pickupText, near: near, tripMiles: offer.miles,
                                                        town: PlaceFinder.town(in: offer.dropoffText))
                pickupCoord = found.coord
                if found.notable {
                    self.noteIssue(key, .storeLookup, "“\(offer.pickupText ?? "")”: " + found.notes.joined(separator: "; "))
                }
            } else {
                pickupCoord = await PlaceFinder.find(offer.pickupText, near: near)
                if pickupCoord == nil, let name = offer.pickupText, let town = PlaceFinder.town(in: offer.dropoffText) {
                    pickupCoord = await PlaceFinder.find("\(name), \(town)", near: near) // name-only stores
                }
            }
            var dropoffCoord: Coord?
            if offer.app == .uber {
                // Uber: every result must be on the card's street(s) and within the trip's miles (5.9.6.4).
                let found = await PlaceFinder.findCustomer(offer.dropoffText, near: near, store: pickupCoord,
                                                           tripMiles: offer.miles)
                dropoffCoord = found.coord
                if found.notable {
                    self.noteIssue(key, .customerLookup, "“\(offer.dropoffText ?? "")”: " + found.notes.joined(separator: "; "))
                }
            } else {
                dropoffCoord = await PlaceFinder.find(offer.dropoffText, near: near)
            }
            var estimated = false
            var streets: String?

            // Every store on the card (batches list two), looked up at the same time.
            var knownStores: [Coord] = pickupCoord.map { [$0] } ?? []
            if offer.pickupTexts.count > 1 {
                let others = Array(offer.pickupTexts.dropFirst())
                await withTaskGroup(of: Coord?.self) { group in
                    for text in others { group.addTask { await PlaceFinder.find(text, near: near) } }
                    for await c in group { if let c { knownStores.append(c) } }
                }
            }
            var batch = Batch(stores: knownStores.map { (coord: $0, estimated: false) }, customers: [], unchecked: 0)

            if offer.app == .uber || offer.app == .doordash {
                var missing: [String] = []
                if pins == nil { missing = ["no pins found"] } else if let pins {
                    if pins.me == nil { missing.append(offer.app == .uber ? "your arrow" : "your blue dot") }
                    if pins.stores.isEmpty { missing.append("store pin") }
                    if pins.customers.isEmpty { missing.append("customer pin") }
                }
                if !missing.isEmpty {
                    self.noteIssue(key, .mapUnreadable, "missing " + missing.joined(separator: ", ") + " on the offer map")
                }
            }
            let pickupFromText = pickupCoord != nil
            if let pins {
                await Cloud.shared.pullSettingsIntoStore(force: true) // freshest GPS: the map's arrow/dot is "now"
                // Every pin: the card's stores confirm the map; stores and customers not on the card are
                // estimated from their pins (≈).
                if let me = store.currentLocation,
                   let placed = MapLocator.placeAll(pins: pins, me: me, known: knownStores, statedMiles: offer.miles) {
                    batch.stores = placed.stores
                    batch.customers = placed.customers
                }
                if let me = store.currentLocation {
                    if let pc = pickupCoord,
                       let est = MapLocator.locate(pins: pins, me: me, store: pc, statedMiles: offer.miles) {
                        // Use the map when there's no dropoff address, or when the address lookup landed
                        // far from where the map's pin actually is (wrong match).
                        if let dc = dropoffCoord, Geo.straightMiles(dc, est.finalDropoff) > 1.0 {
                            self.noteIssue(key, .textMapDisagree, String(format:
                                "Apple Maps put the customer (“%@”) %.1f mi from the map's customer pin; used the pin",
                                offer.dropoffText ?? "?", Geo.straightMiles(dc, est.finalDropoff)))
                        }
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
                if dropoffCoord == nil, offer.app != .doordash, // DoorDash: the tapped address replaces this guess
                   let s = await self.streetEstimate(lines: lines, pins: pins, pickup: pickupCoord, offer: offer) {
                    dropoffCoord = s.coord; estimated = true; streets = s.names
                }
            }

            if !pickupFromText {
                self.noteIssue(key, .storeNotFound, pickupCoord == nil
                    ? "Apple Maps couldn't find “\(offer.pickupText ?? "no store text")”, and the map couldn't place it"
                    : "Apple Maps couldn't find “\(offer.pickupText ?? "no store text")”; placed from the store pin (≈)")
            }
            if dropoffCoord == nil, offer.app != .doordash { // DoorDash: the customer comes from your tap
                self.noteIssue(key, .customerNotFound,
                               "couldn't place the customer from “\(offer.dropoffText ?? "no customer text")” or the map")
            }

            // Stores the card or the map showed that couldn't be placed (e.g. pins stacked on top of each other).
            if batch.stores.isEmpty, let pc = pickupCoord { batch.stores = [(coord: pc, estimated: false)] }
            let expectedStores = max(offer.pickupTexts.count, pins?.stores.count ?? 0, 1)
            batch.unchecked = max(0, expectedStores - batch.stores.count)
            self.lock.lock(); self.batches = [key: batch]; self.lock.unlock()

            let done = await self.finish(key: key, offer: offer, saved: saved, score: score, settings: settings,
                                         prefs: prefs, pickup: pickupCoord, dropoff: dropoffCoord,
                                         estimated: estimated, streets: streets, gate: gate,
                                         announce: !holdVerdict)
            // Keep watching this offer while it stays on screen (up to 90 s):
            // - customer not placed yet: re-read the map every 2 s (zoom in on the customer pin to help);
            // - DoorDash: tap a customer pin and its address bubble ("54 Elderwood Lane") is used to pin it exactly.
            // DoorDash: the verdict banner goes out when you tap the pin (exact address, or the map's
            // estimate if the address can't be found). Later: an updated banner only when the verdict changes.
            self.lock.lock()
            if self.lastKey == key {
                self.rescue = Rescue(key: key, offer: offer, saved: saved, score: score, settings: settings,
                                     prefs: prefs, pickup: pickupCoord, until: Date().addingTimeInterval(90),
                                     located: done.found, note: done.note, dropoff: dropoffCoord,
                                     dropoffEstimated: estimated, holdVerdict: holdVerdict,
                                     verdictSent: !holdVerdict)
            }
            self.lock.unlock()
        }
    }

    // MARK: Keep improving the check while the offer stays up (zoomed-in map, tapped address bubble)

    private struct Rescue {
        let key: String
        let offer: Offer
        let saved: OfferRecord
        let score: Score
        let settings: DriverSettings
        let prefs: NotificationPrefs
        let pickup: Coord?
        let until: Date
        var located: Bool
        var note: String?
        var dropoff: Coord?
        var dropoffEstimated: Bool
        let holdVerdict: Bool        // DoorDash: no verdict banner until you tap the customer pin
        var verdictSent: Bool
        var lastPopup: String?       // address bubble seen on the last scan (nil = no bubble)
        var lastPopupTry = Date.distantPast
        var ambiguous = false        // last tap matched several places; keep re-checking while the bubble is up
        var lastTry = Date.distantPast
        var busy = false
    }
    private var rescue: Rescue?

    /// Called for every scan of an offer that already has its banner. Returns quickly unless there's work to do.
    private func retryIfNeeded(key: String, lines: [OCRLine], mapPins: ((GigApp) -> MapPins?)?, now: Date) {
        lock.lock()
        guard var r = rescue, r.key == key, !r.busy else { lock.unlock(); return }
        if now > r.until { rescue = nil; lock.unlock(); return }
        let popup = r.offer.app == .doordash ? StreetLabels.popupAddress(lines) : nil
        let popupKey = popup?.text.lowercased()
        // A tap = the bubble appearing (or reappearing: tap the pin again to redo the check). While a tap was
        // ambiguous, it's re-checked every 3 s as you zoom, in case more street names come into view.
        let newPopup = popupKey != nil && (popupKey != r.lastPopup
                                           || (r.ambiguous && now.timeIntervalSince(r.lastPopupTry) >= 3))
        let mapDue = !r.located && now.timeIntervalSince(r.lastTry) >= 2
        r.lastPopup = popupKey
        guard newPopup || mapDue else { rescue = r; lock.unlock(); return }
        r.busy = true
        if mapDue { r.lastTry = now }
        if newPopup { r.lastPopupTry = now }
        rescue = r
        lock.unlock()

        let pins = mapPins?(r.offer.app) // must run now, while this frame is still here
        Task {
            var place: (coord: Coord, estimated: Bool, label: String?, streets: String?)?
            var ambiguous = false
            if newPopup, let popup {
                switch await addressEstimate(popup, pins: pins, lines: lines, r) {
                case .placed(let coord, let estimated, let label): place = (coord, estimated, label, nil)
                case .ambiguous: ambiguous = true
                case .notFound: break
                }
            }
            if ambiguous {
                noteIssue(key, .multipleMatches, "tapped “\(popup?.text ?? "?")”: several places match and nothing on screen told them apart")
                // Several places match and nothing on screen tells them apart: ask for a zoom + tap (once).
                if !r.ambiguous, currentKey == key {
                    OfferAlert.post(record: r.saved, offer: r.offer, score: r.score, settings: r.settings, prefs: r.prefs,
                                    otw: nil, canAddToRoute: false, silent: false, hint: OfferAlert.multipleMatchesHint)
                }
                lock.lock()
                if rescue?.key == key { rescue?.busy = false; rescue?.ambiguous = true; rescue?.verdictSent = true }
                lock.unlock()
                return
            }
            if place == nil, mapDue, let pins, !pins.customers.isEmpty {
                if let me = store.currentLocation, let pc = r.pickup,
                   let est = MapLocator.locate(pins: pins, me: me, store: pc, statedMiles: r.offer.miles) {
                    place = (est.finalDropoff, true, nil, nil)
                } else if r.offer.app != .doordash, // DoorDash: the tapped address replaces this guess
                          let s = await streetEstimate(lines: lines, pins: pins, pickup: r.pickup, offer: r.offer) {
                    place = (s.coord, true, nil, s.names)
                }
            }
            let tapped = newPopup
            let announce = !r.holdVerdict || tapped || r.verdictSent
            // First tap (or the tap that settles an ambiguous one): always send the verdict, changed or not.
            let force = tapped && (!r.verdictSent || r.ambiguous)
            var done: (found: Bool, note: String?)?
            if let place {
                done = await finish(key: key, offer: r.offer, saved: r.saved, score: r.score, settings: r.settings,
                                    prefs: r.prefs, pickup: r.pickup, dropoff: place.coord, estimated: place.estimated,
                                    streets: place.streets, gate: nil, dropoffLabel: place.label,
                                    previousNote: r.note, announce: announce, force: force)
            } else if force {
                // The address couldn't be used: send the best verdict there is (the map's estimate, or "couldn't locate").
                done = await finish(key: key, offer: r.offer, saved: r.saved, score: r.score, settings: r.settings,
                                    prefs: r.prefs, pickup: r.pickup, dropoff: r.dropoff, estimated: r.dropoffEstimated,
                                    streets: nil, gate: nil, previousNote: r.note, announce: true, force: true)
            }
            lock.lock()
            if rescue?.key == key {
                rescue?.busy = false
                if tapped { rescue?.ambiguous = false }
                if let done {
                    if done.note != nil { rescue?.note = done.note }
                    if force { rescue?.verdictSent = true }
                    if done.found, let place {
                        rescue?.located = true
                        rescue?.dropoff = place.coord
                        rescue?.dropoffEstimated = place.estimated
                    }
                }
            }
            lock.unlock()
        }
    }

    private enum AddressResult {
        case placed(coord: Coord, estimated: Bool, label: String?)
        case ambiguous   // several matches fit and nothing on screen could tell them apart
        case notFound
    }

    /// DoorDash's address bubble ("54 Elderwood Lane", shown after tapping a customer pin).
    /// - Tapped the last customer (or the only one): that address is the final stop, exactly.
    /// - Tapped another customer: its exact address plus the store pin place the last customer on the map.
    /// When several places match the address within the offer's miles, the street names printed around the
    /// pin (zoom in to show them) pick the right one.
    private func addressEstimate(_ popup: OCRLine, pins: MapPins?, lines: [OCRLine], _ r: Rescue) async -> AddressResult {
        let anchor = r.pickup ?? store.currentLocation
        let all = await PlaceFinder.candidates(popup.text, near: anchor)
        let fits = StreetLabels.distinctPlaces(all.filter {
            StreetLabels.plausible(dropoff: $0, pickup: r.pickup, me: store.currentLocation, statedMiles: r.offer.miles)
        })
        guard !fits.isEmpty else { return .notFound }

        let tapped = pins.flatMap { StreetLabels.pin(under: popup, in: $0) }
        let last = pins.flatMap { StreetLabels.finalCustomer($0) }
        let isLast = tapped == nil || last == nil || tapped == last || (pins?.customers.count ?? 0) <= 1

        var address: Coord?
        if fits.count == 1 {
            address = fits[0]
        } else {
            // 1) Nearby streets on the zoomed map: the match that actually has them around it wins.
            let around = tapped ?? popup.x.flatMap { x in popup.y.map { MapPins.Point(x: x, y: $0) } }
            let names = around.map { StreetLabels.neighbors(lines: lines, near: $0, excluding: popup.text) } ?? []
            if !names.isEmpty {
                var counts: [Int] = []
                for place in fits.prefix(4) {
                    var n = 0
                    for name in names {
                        if await PlaceFinder.streetNear(name, around: place) { n += 1 }
                    }
                    counts.append(n)
                }
                if let i = StreetLabels.bestByNeighbors(counts) { address = fits[i] }
            }
            // 2) Otherwise the map's first estimate, if exactly one match is close to it.
            if address == nil, isLast, let est = r.dropoff, r.dropoffEstimated {
                let close = fits.filter { Geo.straightMiles($0, est) <= 1.5 }
                if close.count == 1 { address = close[0] }
            }
            guard address != nil else { return .ambiguous }
        }
        guard let address else { return .notFound }
        if isLast { return .placed(coord: address, estimated: false, label: popup.text) }

        guard let pins, let tapped, let last else { return .notFound }
        if let storeP = pins.stores.first, let pc = r.pickup,
           let solved = MapLocator.solve(refA: tapped, worldA: address, refB: storeP, worldB: pc, targets: [last]),
           let c = solved.coords.first {
            return .placed(coord: c, estimated: true, label: nil)
        }
        if let meP = pins.me, let me = store.currentLocation,
           let solved = MapLocator.solve(refA: tapped, worldA: address, refB: meP, worldB: me, targets: [last]),
           let c = solved.coords.first {
            return .placed(coord: c, estimated: true, label: nil)
        }
        return .notFound
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
                        streets: String?, gate: PostOnce?, dropoffLabel: String? = nil,
                        previousNote: String? = nil, announce: Bool = true,
                        force: Bool = false) async -> (found: Bool, note: String?) {
        let orderId = saved.id.uuidString
        let dayKey = OfferLog.dayKey(saved.date)
        let p = pickup.map { Stop(type: .pickup, label: offer.pickupText ?? "Pickup", location: $0, orderId: orderId) }
        let d = dropoff.map {
            Stop(type: .dropoff, label: dropoffLabel ?? (estimated ? MapEstimate.label : (offer.dropoffText ?? "Dropoff")),
                 location: $0, orderId: orderId)
        }
        guard currentKey == key else { return (d != nil, nil) } // a newer offer replaced this one

        let foundPickup = p?.location, foundDropoff = d?.location
        log.update(id: saved.id, dayKey: dayKey) {
            $0.pickupLocation = foundPickup
            $0.dropoffLocation = foundDropoff
            $0.dropoffEstimated = foundDropoff == nil ? nil : estimated
        }

        let planner = TripPlanner(stops: store.stops)
        let origin = store.currentLocation ?? pickup
        var otw = planner.checkOnTheWay(origin: origin, pickup: p, dropoff: d, pay: offer.pay, settings: settings)

        // Pickup check: each of the offer's stores against every pickup in your route (worst one shown).
        let info = batch(key)
        let fallback: [(coord: Coord, estimated: Bool)] = pickup.map { [(coord: $0, estimated: false)] } ?? []
        let storesToCheck = info?.stores ?? fallback
        let pickupCheck = planner.checkPickups(stores: storesToCheck, unchecked: info?.unchecked ?? 0,
                                               origin: origin, settings: settings)
        // Batch offers (2+ stores or customers): judged by the customer farthest from your last stop;
        // the extra miles (information only) cover all of the offer's stops.
        var drops = 1
        if let info, let d, let origin, let last = planner.stops.last,
           info.stores.count > 1 || info.customers.count > 1 {
            drops = max(info.customers.count, 1)
            let customers = info.customers.count > 1 ? info.customers : [d.location]
            let added = planner.addedMiles(stores: info.stores.map { $0.coord }, customers: customers, origin: origin)
            let toFinal = customers.map { Geo.radiusMiles($0, last.location) }.max() ?? Geo.radiusMiles(d.location, last.location)
            let v = TripPlanner.dropoffVerdict(toFinal, settings)
            let wasApproximate = otw.approximate
            otw = TripPlanner.OnTheWay(verdict: v, addedMiles: added, dropoffToFinalMi: toFinal,
                                       stackedPerMile: added > 0.1 ? offer.pay / added : nil)
            otw.approximate = wasApproximate || info.stores.contains { $0.estimated }
        }
        let note = otw.message
        let fullNote = pickupCheck.message + "\n" + otw.message
        // For the Insights charts: miles from the target (store → nearest route pickup, customer → last stop).
        let pickupDetour = pickupCheck.worst?.nearestMi, dropoffDetour = otw.dropoffToFinalMi
        log.update(id: saved.id, dayKey: dayKey) {
            $0.routeNote = fullNote
            $0.pickupDetourMi = pickupDetour
            $0.dropoffDetourMi = dropoffDetour
        }
        var canAdd = false
        if let p, let d {
            store.savePending(orderId: orderId, pickup: p, dropoff: d) // also sent to the cloud with the offer
            canAdd = planner.canAdd(2)
        }

        var dropoffInfo: DropoffInfo?
        if let d {
            let miles = store.currentLocation.map { Geo.roadMiles($0, d.location) }
            var place = dropoffLabel ?? offer.dropoffText ?? d.label
            if let dropoffLabel, !estimated {
                log.update(id: saved.id, dayKey: dayKey) { $0.dropoffText = dropoffLabel } // exact address
            } else if estimated {
                var named = streets
                if named == nil { named = await PlaceFinder.describe(d.location) }
                place = named ?? "customer pin"
                let shown = place
                log.update(id: saved.id, dayKey: dayKey) { $0.dropoffText = "≈ \(shown) (from map)" }
            }
            dropoffInfo = DropoffInfo(place: place, estimated: estimated, milesFromYou: miles)
        }
        guard currentKey == key else { return (d != nil, note) }

        await Cloud.shared.queueOffer(id: saved.id, dayKey: dayKey) // route note + stops
        let post: Bool
        if !announce {
            post = false // DoorDash before you tap the customer pin: checked and saved, but no verdict banner yet
        } else if force {
            post = true
        } else if let gate {
            // First banner, or (if the 3.5 s banner already went out without a verdict) an update with it.
            post = gate.claim() || d != nil
        } else {
            // Later improvement: only bother you if the verdict itself changed (ON THE WAY → OFF ROUTE, etc.),
            // not when only the miles shift a little.
            func verdict(_ n: String?) -> String? { n?.split(separator: ":").first.map(String.init) }
            post = d != nil && verdict(note) != verdict(previousNote)
        }
        if post {
            OfferAlert.post(record: saved, offer: offer, score: score, settings: settings, prefs: prefs,
                            otw: otw, canAddToRoute: canAdd, silent: false, dropoff: dropoffInfo,
                            pickupCheck: pickupCheck, drops: drops)
            let source = d == nil ? "not found" : dropoffLabel != nil ? "tapped address" : estimated ? "map pin" : "card text"
            notePosted(key, marks: "\(pickupCheck.worst?.level.rawValue ?? -1)|\(otw.verdict)",
                       summary: [pickupCheck.compact, otw.compact(drops: drops)].filter { !$0.isEmpty }.joined(separator: " · "),
                       pickup: p?.location, dropoff: d?.location, source: source)
        }
        return (d != nil, note)
    }

    // MARK: Issues log (5.9.6.2): anything that went wrong on a read offer, one entry per offer, kept up to date

    enum IssueKind: String {
        case verdictChanged, textMapDisagree, storeNotFound, customerNotFound, mapUnreadable, multipleMatches, noVerdictInTime,
             storeLookup, customerLookup
        var title: String {
            switch self {
            case .verdictChanged: return "Verdict changed after the banner"
            case .textMapDisagree: return "Text and map disagreed"
            case .storeNotFound: return "Couldn't find the store"
            case .customerNotFound: return "Couldn't find the customer"
            case .mapUnreadable: return "Map couldn't be read"
            case .multipleMatches: return "Several matches for the tapped address"
            case .noVerdictInTime: return "Banner went out without a verdict"
            case .storeLookup: return "Store lookup"
            case .customerLookup: return "Customer lookup"
            }
        }
    }

    private struct Trail {
        let id = UUID()
        let record: OfferRecord
        let text: String
        var events: [String] = []
        var kinds: [IssueKind] = []
        var lastPosted: (marks: String, summary: String, pickup: Coord?, dropoff: Coord?, source: String)?
    }

    private func startTrail(key: String, record: OfferRecord, text: String) {
        lock.lock(); trails = [key: Trail(record: record, text: text)]; lock.unlock()
    }

    /// Adds a line to the offer's issue entry and uploads the entry (same row each time, so one per offer).
    func noteIssue(_ key: String, _ kind: IssueKind, _ detail: String) {
        lock.lock()
        guard var t = trails[key] else { lock.unlock(); return }
        let secs = Date().timeIntervalSince(t.record.date)
        t.events.append(String(format: "+%.1f s  ", secs) + kind.title + ": " + detail)
        if !t.kinds.contains(kind) { t.kinds.append(kind) }
        trails[key] = t
        lock.unlock()
        let headline = t.kinds.map(\.title).joined(separator: " · ")
        let details = t.events.joined(separator: "\n")
        Task {
            await Cloud.shared.reportIssue(id: t.id, offerId: t.record.id, date: t.record.date, headline: headline,
                                           details: details, text: t.text, screenshotFile: t.record.screenshotFile)
        }
    }

    /// Remembers what each verdict banner said; a later banner with a different verdict is logged with what moved.
    private func notePosted(_ key: String, marks: String, summary: String, pickup: Coord?, dropoff: Coord?, source: String) {
        lock.lock()
        guard var t = trails[key] else { lock.unlock(); return }
        let before = t.lastPosted
        t.lastPosted = (marks: marks, summary: summary, pickup: pickup, dropoff: dropoff, source: source)
        trails[key] = t
        lock.unlock()
        guard let before, before.marks != marks else { return }
        func moved(_ a: Coord?, _ b: Coord?) -> String? {
            guard let a, let b else { return nil }
            let d = Geo.straightMiles(a, b)
            return d >= 0.1 ? String(format: "%.1f mi", d) : nil
        }
        var parts = ["banner said \(before.summary); now \(summary)"]
        if let m = moved(before.pickup, pickup) { parts.append("store moved \(m)") }
        if let m = moved(before.dropoff, dropoff) {
            parts.append("customer moved \(m) (\(before.source) → \(source))")
        } else if before.source != source {
            parts.append("customer: \(before.source) → \(source)")
        }
        noteIssue(key, .verdictChanged, parts.joined(separator: "; "))
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
