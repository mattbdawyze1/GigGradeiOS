import XCTest
@testable import GigCore

/// Version 5.9.7: Uber offers that show only the store's name use the store pin on the map first.
final class MapFirstTests: XCTestCase {
    // About 0.0145° latitude = 1 mile.
    func c(_ northMi: Double, _ eastMi: Double) -> Coord {
        Coord(lat: 40.8 + northMi * 0.01449, lng: -73.1 + eastMi * 0.01908)
    }
    // A north-up map: 100 px per mile, you in the middle.
    func px(_ p: Coord) -> MapPins.Point {
        let me = c(0, 0)
        return MapPins.Point(x: 500 + (p.lng - me.lng) / 0.01908 * 100, y: 1000 - (p.lat - me.lat) / 0.01449 * 100)
    }

    func testCrossStreet() {
        XCTAssertTrue(MapLocator.isCrossStreet("Main St & Oak Ave, Smithtown"))
        XCTAssertTrue(MapLocator.isCrossStreet("Partridge Ln & Pheasant Ln"))
        XCTAssertFalse(MapLocator.isCrossStreet("Bicycle Path, Port Jefferson Station"))
        XCTAssertFalse(MapLocator.isCrossStreet(nil))
    }

    func testNameOnly() {
        XCTAssertTrue(MapLocator.isNameOnly("Halal City"))
        XCTAssertTrue(MapLocator.isNameOnly("McDonald's"))
        XCTAssertTrue(MapLocator.isNameOnly("7-Eleven"))
        XCTAssertFalse(MapLocator.isNameOnly("Wendy's, 123 Main St"))
        XCTAssertFalse(MapLocator.isNameOnly("110 Commack Road, Commack, NY"))
        XCTAssertFalse(MapLocator.isNameOnly(nil))
    }

    func testPicksTheBranchThatFitsTheMap() {
        let me = c(0, 0), store = c(2, 1), customer = c(5, 2)
        let pins = MapPins(me: px(me), stores: [px(store)], customers: [px(customer)])
        // Three places with the same name: the real one, one in the wrong direction, one twice as far out.
        let wrongWay = c(-2, 3), tooFar = c(4, 2)
        let pick = MapLocator.pickStore(pins: pins, me: me, candidates: [wrongWay, tooFar, store], statedMiles: 7)
        XCTAssertEqual(pick?.store, store)
        XCTAssertLessThan(Geo.straightMiles(pick!.customers.last!, customer), 0.1)
    }

    func testNoBranchFitsReturnsNil() {
        let me = c(0, 0), store = c(2, 1), customer = c(5, 2)
        let pins = MapPins(me: px(me), stores: [px(store)], customers: [px(customer)])
        XCTAssertNil(MapLocator.pickStore(pins: pins, me: me, candidates: [c(-2, 3)], statedMiles: 7))
        XCTAssertNil(MapLocator.pickStore(pins: pins, me: me, candidates: [], statedMiles: 7))
    }

    func testStoreStraightFromItsPin() {
        let me = c(0, 0), store = c(1, 0.5), customer = c(3, 1.5)
        let pins = MapPins(me: px(me), stores: [px(store)], customers: [px(customer)])
        // The card's total miles: you -> store -> customer, as roads (straight x 1.3).
        let miles = (Geo.straightMiles(me, store) + Geo.straightMiles(store, customer)) * Geo.roadFactor
        let placed = MapLocator.placeByMiles(pins: pins, me: me, statedMiles: miles)!
        XCTAssertLessThan(Geo.straightMiles(placed.store, store), 0.05)
        XCTAssertLessThan(Geo.straightMiles(placed.customers.last!, customer), 0.05)
        // Roads 20% longer than assumed: the spots shift a little, but stay close.
        let longer = MapLocator.placeByMiles(pins: pins, me: me, statedMiles: miles * 1.2)!
        XCTAssertLessThan(Geo.straightMiles(longer.store, store), 0.3)
        XCTAssertNil(MapLocator.placeByMiles(pins: pins, me: me, statedMiles: nil))
    }
}
