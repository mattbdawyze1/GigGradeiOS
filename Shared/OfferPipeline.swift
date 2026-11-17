import Foundation
import GigCore

/// OCR text in -> grade notification out (then updated with the on-the-way check).
final class OfferPipeline {
    static let shared = OfferPipeline()

    private let store = SharedStore.shared
    private let lock = NSLock()
    private var lastKey: String?
    private var lastSeen = Date.distantPast

    private var currentKey: String? { lock.lock(); defer { lock.unlock() }; return lastKey }

    func reset() { lock.lock(); lastKey = nil; lock.unlock() }

    func handle(text: String) {
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
        let score = OfferScorer.score(offer, settings)
        let route = store.stops

        // 1) Grade immediately.
        OfferAlert.post(offer: offer, score: score, settings: settings,
                        otw: route.isEmpty ? nil : TripPlanner.OnTheWay(verdict: .unknownLocation),
                        orderId: nil, silent: false)

        // 2) Locate pickup/dropoff, then update the same banner with the on-the-way verdict.
        Task {
            let near = store.currentLocation
            let orderId = UUID().uuidString
            let p = await PlaceFinder.find(offer.pickupText, near: near)
                .map { Stop(type: .pickup, label: offer.pickupText ?? "Pickup", location: $0, orderId: orderId) }
            let d = await PlaceFinder.find(offer.dropoffText, near: near)
                .map { Stop(type: .dropoff, label: offer.dropoffText ?? "Dropoff", location: $0, orderId: orderId) }
            guard self.currentKey == offer.key else { return } // a newer offer replaced this one

            let planner = TripPlanner(stops: store.stops)
            let otw = planner.stops.isEmpty ? nil
                : planner.checkOnTheWay(origin: near, pickup: p, dropoff: d, pay: offer.pay, settings: settings)
            var addableId: String?
            if let p, let d, planner.canAdd(2) {
                store.savePending(orderId: orderId, pickup: p, dropoff: d)
                addableId = orderId
            }
            if otw != nil || addableId != nil {
                OfferAlert.post(offer: offer, score: score, settings: settings, otw: otw, orderId: addableId, silent: true)
            }
        }
    }
}
