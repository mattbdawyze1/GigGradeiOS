import XCTest
@testable import GigCore

/// Version 5.0: Optimize button on the Route tab.
final class RouteOptimizerTests: XCTestCase {

    func stop(_ type: StopType, _ order: String, _ x: Double, _ y: Double) -> Stop {
        Stop(type: type, label: "\(order)-\(type)", location: Coord(lat: 40 + y / 100, lng: -73 + x / 100), orderId: order)
    }

    func dist(_ a: Stop, _ b: Stop) -> Double {
        let dx = a.location.lng - b.location.lng, dy = a.location.lat - b.location.lat
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Every valid order, checked one by one (slow, only for testing).
    func bruteForce(_ stops: [Stop], _ cost: [[Double]], _ start: [Double]) -> Double {
        var best = Double.infinity
        func go(_ order: [Int], _ left: Set<Int>) {
            if left.isEmpty {
                let s = order.map { stops[$0] }
                if TripPlanner.isValidOrder(s) {
                    best = min(best, RouteOptimizer.cost(of: order, cost: cost, fromStart: start))
                }
                return
            }
            for i in left { go(order + [i], left.subtracting([i])) }
        }
        go([], Set(stops.indices))
        return best
    }

    func testMatchesBruteForceAndKeepsPickupsFirst() {
        // Three linked orders (one with two dropoffs) plus one unlinked stop, deliberately scrambled.
        let stops = [
            stop(.dropoff, "A", 9, 1), stop(.pickup, "B", 2, 7), stop(.pickup, "A", 8, 8),
            stop(.dropoff, "B", 1, 1), stop(.dropoff, "A", 5, 9), stop(.pickup, "C", 4, 4),
            stop(.dropoff, "C", 6, 2), stop(.dropoff, "X", 3, 9),
        ]
        let me = stop(.pickup, "me", 0, 0)
        let cost = stops.map { a in stops.map { b in dist(a, b) } }
        let start = stops.map { dist(me, $0) }

        let r = RouteOptimizer.optimize(stops: stops, cost: cost, fromStart: start)!
        XCTAssertEqual(r.order.count, stops.count)
        XCTAssertEqual(Set(r.order), Set(stops.indices))
        XCTAssertTrue(TripPlanner.isValidOrder(r.order.map { stops[$0] }))
        XCTAssertEqual(r.cost, bruteForce(stops, cost, start), accuracy: 1e-9)
    }

    func testLinkedDropoffNeverGoesFirstEvenWhenClosest() {
        let pickup = stop(.pickup, "A", 10, 0)
        let dropoff = stop(.dropoff, "A", 1, 0)   // right next to you, but its food is at the store
        let stops = [dropoff, pickup]
        let me = stop(.pickup, "me", 0, 0)
        let cost = stops.map { a in stops.map { b in dist(a, b) } }
        let r = RouteOptimizer.optimize(stops: stops, cost: cost, fromStart: stops.map { dist(me, $0) })!
        XCTAssertEqual(r.order, [1, 0])
    }

    func testUnlinkedStopsCanGoInAnyOrder() {
        // Different orderIds = not linked, so the nearby dropoff can go first.
        let stops = [stop(.pickup, "A", 10, 0), stop(.dropoff, "B", 1, 0)]
        let me = stop(.pickup, "me", 0, 0)
        let cost = stops.map { a in stops.map { b in dist(a, b) } }
        let r = RouteOptimizer.optimize(stops: stops, cost: cost, fromStart: stops.map { dist(me, $0) })!
        XCTAssertEqual(r.order, [1, 0])
    }

    func testAlreadyBestKeepsYourOrder() {
        let stops = [stop(.pickup, "A", 1, 0), stop(.dropoff, "A", 2, 0), stop(.pickup, "B", 3, 0)]
        let me = stop(.pickup, "me", 0, 0)
        let cost = stops.map { a in stops.map { b in dist(a, b) } }
        let r = RouteOptimizer.optimize(stops: stops, cost: cost, fromStart: stops.map { dist(me, $0) },
                                        keepIfWithin: 0.001)!
        XCTAssertEqual(r.order, [0, 1, 2])
        XCTAssertEqual(r.improvement, 0, accuracy: 1e-9)
    }

    func testNineStopsIsQuick() {
        var stops: [Stop] = []
        for i in 0..<9 {
            let type: StopType = i % 2 == 0 ? .pickup : .dropoff
            let order = "O" + String(i / 2)
            let x = Double((i * 37) % 11)
            let y = Double((i * 53) % 7)
            stops.append(stop(type, order, x, y))
        }
        let cost = stops.map { a in stops.map { b in dist(a, b) } }
        let r = RouteOptimizer.optimize(stops: stops, cost: cost, fromStart: nil)
        XCTAssertNotNil(r)
        XCTAssertTrue(TripPlanner.isValidOrder(r!.order.map { stops[$0] }))
    }
}
