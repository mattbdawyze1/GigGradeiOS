import Foundation
import GigCore

/// OCR text in -> offer logged (with screenshot) -> grade banner -> banner updated with the on-the-way check.
final class OfferPipeline {
    static let shared = OfferPipeline()

    private let store = SharedStore.shared
    private let log = OfferLog.shared
    private let lock = NSLock()
    private var lastKey: String?
    private var lastSeen = Date.distantPast

    private var currentKey: String? { lock.lock(); defer { lock.unlock() }; return lastKey }

    func reset() { lock.lock(); lastKey = nil; lock.unlock() }

    /// - Parameter screenshot: called only when a NEW offer is found; returns a JPEG of the screen.
    func handle(text: String, screenshot: (() -> Data?)? = nil) {
        let now = Date()
        guard let offer = OfferParser.parse(text) else {
            // Offer screen went away -> the same numbers may alert again later.
            lock.lock(); if now.timeIntervalSince(lastSeen) > 5 { lastKey = nil }; lock.unlock()
            return
        }
        lock.lock()
        lastSeen = now
        let duplicate = offer.key == lastKey
        lastKey = offer.key
        lock.unlock()
        if duplicate { return }

        let settings = store.settings
        let prefs = store.notificationPrefs
        let score = OfferScorer.score(offer, settings)
        let route = store.stops

        // 1) Log it (with a screenshot) and show the grade immediately.
        var record = OfferRecord(date: now, app: offer.app, pay: offer.pay, miles: offer.miles, minutes: offer.minutes,
                                 pickupText: offer.pickupText, dropoffText: offer.dropoffText, grade: score.grade,
                                 category: score.category, dollarsPerHour: score.dollarsPerHour,
                                 dollarsPerMile: score.dollarsPerMile)
        if let jpeg = screenshot?() { record.screenshotFile = log.saveScreenshot(jpeg, id: record.id) }
        log.append(record)

        OfferAlert.post(record: record, offer: offer, score: score, settings: settings, prefs: prefs,
                        otw: route.isEmpty ? nil : TripPlanner.OnTheWay(verdict: .unknownLocation),
                        canAddToRoute: false, silent: false)

        // 2) Locate pickup/dropoff, then update the same banner with the on-the-way verdict.
        let saved = record
        Task {
            let near = store.currentLocation
            let orderId = saved.id.uuidString
            let p = await PlaceFinder.find(offer.pickupText, near: near)
                .map { Stop(type: .pickup, label: offer.pickupText ?? "Pickup", location: $0, orderId: orderId) }
            let d = await PlaceFinder.find(offer.dropoffText, near: near)
                .map { Stop(type: .dropoff, label: offer.dropoffText ?? "Dropoff", location: $0, orderId: orderId) }
            guard self.currentKey == offer.key else { return } // a newer offer replaced this one

            let planner = TripPlanner(stops: store.stops)
            let otw = planner.stops.isEmpty ? nil
                : planner.checkOnTheWay(origin: near, pickup: p, dropoff: d, pay: offer.pay, settings: settings)
            if let note = otw?.message {
                log.update(id: saved.id, dayKey: OfferLog.dayKey(saved.date)) { $0.routeNote = note }
            }
            var canAdd = false
            if let p, let d, planner.canAdd(2) {
                store.savePending(orderId: orderId, pickup: p, dropoff: d)
                canAdd = true
            }
            if otw != nil || canAdd {
                OfferAlert.post(record: saved, offer: offer, score: score, settings: settings, prefs: prefs,
                                otw: otw, canAddToRoute: canAdd, silent: true)
            }
        }
    }
}
