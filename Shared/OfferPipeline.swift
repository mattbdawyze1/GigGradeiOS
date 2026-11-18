import Foundation
import GigCore

/// OCR text in -> offer logged (with screenshot) -> grade banner -> banner updated with the on-the-way check.
final class OfferPipeline {
    static let shared = OfferPipeline()

    private let store = SharedStore.shared
    private let log = OfferLog.shared
    private let lock = NSLock()
    private var lastKey: String?          // offer whose banner is currently up
    private var activePay: Double?        // pay of that offer
    private var lastSeen = Date.distantPast
    private var candidateKey: String?     // a new reading waiting to be confirmed
    private var candidateCount = 0

    private var currentKey: String? { lock.lock(); defer { lock.unlock() }; return lastKey }

    func reset() {
        lock.lock()
        lastKey = nil; activePay = nil; candidateKey = nil; candidateCount = 0
        lock.unlock()
    }

    /// Rules so one offer = one banner:
    /// - an offer must read the same on 2 scans in a row before it alerts (filters one-frame misreads);
    /// - while an offer stays on screen, nothing new alerts unless the pay itself changes;
    /// - once no offer has been seen for 3 seconds, the screen counts as cleared.
    ///
    /// - Parameters:
    ///   - screenshot: called only when a NEW offer is confirmed; returns a JPEG of the screen.
    ///   - immediate: skip the 2-scan check (used by "Test with a sample offer").
    func handle(text: String, screenshot: (() -> Data?)? = nil, immediate: Bool = false) {
        let now = Date()
        guard let offer = OfferParser.parse(text) else {
            lock.lock()
            if now.timeIntervalSince(lastSeen) > 3 {
                lastKey = nil; activePay = nil; candidateKey = nil; candidateCount = 0
            }
            lock.unlock()
            return
        }

        lock.lock()
        lastSeen = now
        if offer.key == candidateKey { candidateCount += 1 } else { candidateKey = offer.key; candidateCount = 1 }
        let confirmed = immediate || candidateCount >= 2
        let sameOfferStillUp = activePay.map { abs($0 - offer.pay) < 0.01 } ?? false
        let shouldAlert = confirmed && !sameOfferStillUp && offer.key != lastKey
        if shouldAlert { lastKey = offer.key; activePay = offer.pay }
        lock.unlock()
        if !shouldAlert { return }

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
        let dayKey = OfferLog.dayKey(record.date)
        Task { await Cloud.shared.queueOffer(id: record.id, dayKey: dayKey) }

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
            if otw?.message != nil || canAdd {
                await Cloud.shared.queueOffer(id: saved.id, dayKey: OfferLog.dayKey(saved.date)) // route note + stops
            }
            if otw != nil || canAdd {
                OfferAlert.post(record: saved, offer: offer, score: score, settings: settings, prefs: prefs,
                                otw: otw, canAddToRoute: canAdd, silent: true)
            }
        }
    }
}
