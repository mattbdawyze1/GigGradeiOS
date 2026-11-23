import XCTest
@testable import GigCore

/// Version 5.8: the pickup half of the route check, batch stores, and every map pin.
final class PickupCheckTests: XCTestCase {

    // About 0.0145° latitude = 1 mile.
    func c(_ northMi: Double, _ eastMi: Double) -> Coord {
        Coord(lat: 40.8 + northMi * 0.01449, lng: -73.1 + eastMi * 0.01908)
    }
    func stop(_ t: StopType, _ name: String, _ at: Coord) -> Stop {
        Stop(type: t, label: name, location: at, orderId: name)
    }
    let s = DriverSettings(onTheWayRadiusMi: 1.5, maxDetourMi: 3, pickupNearMi: 1.0, pickupMaxDetourMi: 1.5)

    func testNearAnyPickupNotJustTheLast() {
        // Route: Chipotle (first), then a far-away dropoff. The offer's store is next to Chipotle.
        let planner = TripPlanner(stops: [stop(.pickup, "Chipotle", c(0, 0)), stop(.dropoff, "Kevin D.", c(8, 0))])
        let r = planner.checkPickups(stores: [(c(0.2, 0.1), false)], origin: c(-1, 0), settings: s)
        XCTAssertEqual(r.worst?.level, .near)
        XCTAssertEqual(r.worst?.nearestName, "Chipotle")
        XCTAssertTrue(r.compact.hasPrefix("🛍 ✅ "))
        XCTAssertTrue(r.compact.hasSuffix("mi from Chipotle"))
    }

    func testCloseByAndOffRoute() {
        let planner = TripPlanner(stops: [stop(.pickup, "A", c(0, 0)), stop(.dropoff, "B", c(4, 0))])
        // ~1.3 road mi from pickup A: past the 1.0 Close by radius, inside the 1.5 On the way radius.
        let close = planner.checkPickups(stores: [(c(1.0, 0), false)], origin: c(-1, 0), settings: s)
        XCTAssertEqual(close.worst?.level, .close)
        XCTAssertEqual(close.compact, "🛍 ⚠️ 1.3 mi from A")
        // ~2.6 road mi from A, even though it's along the way to B: radius only, so off route.
        let off = planner.checkPickups(stores: [(c(2, 0), false)], origin: c(-1, 0), settings: s)
        XCTAssertEqual(off.worst?.level, .off)
        XCTAssertTrue(off.compact.hasPrefix("🛍 ❌ "))
        XCTAssertTrue(off.compact.hasSuffix("mi from A"))
        XCTAssertTrue(off.message.contains("mi extra)"), off.message)   // extra miles shown as info
    }

    func testNoPickupsInRouteMeasuresFromYou() {
        let planner = TripPlanner(stops: [])
        let r = planner.checkPickups(stores: [(c(0.3, 0), false)], origin: c(0, 0), settings: s)
        XCTAssertEqual(r.worst?.level, .near)
        XCTAssertTrue(r.compact.hasSuffix("mi from you"))
    }

    func testTwoStoresShowsTheWorstAndEstimates() {
        let planner = TripPlanner(stops: [stop(.pickup, "A", c(0, 0)), stop(.dropoff, "B", c(4, 0))])
        let r = planner.checkPickups(stores: [(c(0.1, 0), false), (c(2, 6), true)], unchecked: 1, origin: c(-1, 0), settings: s)
        XCTAssertEqual(r.worst?.level, .off)
        XCTAssertTrue(r.compact.contains("2 stores, farthest ≈"), r.compact)
        XCTAssertTrue(r.compact.hasSuffix("(+1 not checked)"), r.compact)
    }

    func testNothingLocated() {
        let r = TripPlanner(stops: []).checkPickups(stores: [], origin: c(0, 0), settings: s)
        XCTAssertEqual(r.compact, "🛍 ?")
    }

    func testDropoffCompact() {
        var near = TripPlanner.OnTheWay(verdict: .nearFinal, addedMiles: 0.5, dropoffToFinalMi: 0.9)
        XCTAssertEqual(near.compact(), "🏠 ✅ ends 0.9 mi from last stop")
        near.approximate = true
        XCTAssertEqual(near.compact(drops: 2), "🏠 ✅ 2 drops, farthest ≈ends 0.9 mi from last stop")
        XCTAssertEqual(TripPlanner.OnTheWay(verdict: .onTheWay, addedMiles: 1.2, dropoffToFinalMi: 2.4).compact(),
                       "🏠 ⚠️ ends 2.4 mi from last stop")
        XCTAssertEqual(TripPlanner.OnTheWay(verdict: .unknownLocation).compact(), "🏠 ?")
    }

    func testAddedMilesForBatchKeepsCustomersAfterStores() {
        let planner = TripPlanner(stops: [])
        let extra = planner.addedMiles(stores: [c(1, 0), c(2, 0)], customers: [c(3, 0)], origin: c(0, 0))
        XCTAssertEqual(extra, Geo.routeMiles([c(0, 0), c(1, 0), c(2, 0), c(3, 0)]), accuracy: 0.01)
    }

    func testRadiusRules() {
        // Dropoffs: radius from your last stop.
        let s = DriverSettings(onTheWayRadiusMi: 1.5, maxDetourMi: 3)
        XCTAssertEqual(TripPlanner.dropoffVerdict(1.2, s), .nearFinal)
        XCTAssertEqual(TripPlanner.dropoffVerdict(2.5, s), .onTheWay)
        XCTAssertEqual(TripPlanner.dropoffVerdict(3.4, s), .offRoute)
        // On the way is never smaller than Close by (old saves had Close by 3, On the way 2).
        let old = DriverSettings(onTheWayRadiusMi: 3, maxDetourMi: 2, pickupNearMi: 2, pickupMaxDetourMi: 1)
        XCTAssertEqual(old.dropoffOnTheWayMi, 3)
        XCTAssertEqual(old.pickupOnTheWayMi, 2)
        XCTAssertEqual(TripPlanner.dropoffVerdict(2.5, old), .nearFinal)
    }

    func testSettingsDecodeOldSaves() throws {
        let old = #"{"hourlyFair":18,"hourlyGood":25,"perMileFair":1,"perMileGood":1.5,"costPerMile":0.3,"onTheWayRadiusMi":3,"maxDetourMi":2}"#
        let d = try JSONDecoder().decode(DriverSettings.self, from: Data(old.utf8))
        XCTAssertEqual(d.pickupNearMi, 1.0)
        XCTAssertEqual(d.pickupMaxDetourMi, 1.5)
    }

    // MARK: Batch offers

    func testDoorDashListsBothStores() {
        let text = """
        $11.29 incl. tips
        4 stops (10.5 mi) • 32 min
        Carvel Ice Cream
        110 Commack Road, Commack, 11725 NY
        Chico's Tex Mex
        128 Commack Rd, Commack, 11725 NY
        Multiple dropoffs (2 stops)
        Accept
        """
        let o = OfferParser.parse(text)!
        XCTAssertEqual(o.app, .doordash)
        XCTAssertEqual(o.pickupTexts, ["Carvel Ice Cream, 110 Commack Road, Commack, 11725 NY",
                                       "Chico's Tex Mex, 128 Commack Rd, Commack, 11725 NY"])
        XCTAssertEqual(o.stopCount, 4)
    }

    func testPlaceAllConfirmsTheCardAndEstimatesTheRest() {
        // Build a north-up map: 100 px per mile east, 100 px per mile south.
        let me = c(0, 0)
        func px(_ p: Coord) -> MapPins.Point {
            MapPins.Point(x: 500 + (p.lng - me.lng) / 0.01908 * 100, y: 1000 - (p.lat - me.lat) / 0.01449 * 100)
        }
        let storeA = c(2, 1), storeB = c(2.2, 3), customer = c(5, 2)
        let pins = MapPins(me: px(me), stores: [px(storeA), px(storeB)], customers: [px(customer)])
        // Only store A is on the card; B is found from its pin.
        let placed = MapLocator.placeAll(pins: pins, me: me, known: [storeA], statedMiles: nil)!
        XCTAssertEqual(placed.stores.count, 2)
        XCTAssertEqual(placed.stores.filter { !$0.estimated }.map { $0.coord }, [storeA])
        let b = placed.stores.first { $0.estimated }!.coord
        XCTAssertLessThan(Geo.straightMiles(b, storeB), 0.1)
        XCTAssertLessThan(Geo.straightMiles(placed.customers[0], customer), 0.1)
    }
}
