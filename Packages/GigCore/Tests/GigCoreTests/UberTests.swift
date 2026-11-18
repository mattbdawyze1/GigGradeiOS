import XCTest
@testable import GigCore

/// Text as Vision reads it from real Uber Eats offer cards (Nov 2026 layout).
final class UberTests: XCTestCase {

    func testCrossStreetsWrapped() throws {
        let text = """
        Port Jefferson
        N COUNTRY RD
        Delivery
        Exclusive
        $5.04
        Guaranteed (incl. tip)
        20 min (3.9 mi) total
        Slurp Ramen
        Garden Ct & School Dr, Port Jefferson
        Station
        Accept
        """
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.app, .uber)
        XCTAssertEqual(o.pay, 5.04, accuracy: 0.001)
        XCTAssertEqual(o.minutes, 20)
        XCTAssertEqual(o.miles ?? 0, 3.9, accuracy: 0.001)
        XCTAssertEqual(o.pickupText, "Slurp Ramen")
        XCTAssertEqual(o.dropoffText, "Garden Ct & School Dr, Port Jefferson Station")
    }

    func testStoreAddressInParenthesesIsPickupNotDropoff() throws {
        let text = """
        Delivery
        Exclusive
        $6.02
        Guaranteed (incl. tip)
        22 min (5.3 mi) total
        Panera (4959 Nesconset Hwy )
        N Belle Mead Ave, East Setauket
        Accept
        """
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.app, .uber)
        XCTAssertEqual(o.pickupText, "Panera 4959 Nesconset Hwy")
        XCTAssertEqual(o.dropoffText, "N Belle Mead Ave, East Setauket")
    }

    func testWrappedStoreNameAndTripRadar() throws {
        let text = """
        Delivery
        Trip Radar
        $6.52
        Guaranteed (incl. tip)
        23 min (7.0 mi) total
        Five Guys (5122 Nesconset Hwy.) NY -
        1330
        Nicolls Rd, Stony Brook
        Match
        """
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.app, .uber)
        XCTAssertEqual(o.pay, 6.52, accuracy: 0.001)
        XCTAssertEqual(o.pickupText, "Five Guys 5122 Nesconset Hwy. NY - 1330")
        XCTAssertEqual(o.dropoffText, "Nicolls Rd, Stony Brook")
    }

    func testPickupWrapsBeforeCrossStreets() throws {
        let text = """
        Delivery
        Exclusive
        $13.64
        Guaranteed (incl. tip)
        30 min (8.1 mi) total
        Jersey Mike's Subs (4600 Nesconset
        Hwy)
        5th St & Shenandoah Blvd, Nesconset
        Accept
        """
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.pickupText, "Jersey Mike's Subs 4600 Nesconset Hwy")
        XCTAssertEqual(o.dropoffText, "5th St & Shenandoah Blvd, Nesconset")
        XCTAssertEqual(o.minutes, 30)
        XCTAssertEqual(o.miles ?? 0, 8.1, accuracy: 0.001)
    }
}

final class NoRouteVerdictTests: XCTestCase {
    func testWithoutRouteMeasuresFromYou() {
        let me = Coord(lat: 40.9150, lng: -73.0450)
        let p = Stop(type: .pickup, label: "p", location: Coord(lat: 40.9200, lng: -73.0500), orderId: "1")
        let near = Stop(type: .dropoff, label: "d", location: Coord(lat: 40.9250, lng: -73.0550), orderId: "1")   // ~1 mi
        let far = Stop(type: .dropoff, label: "d", location: Coord(lat: 40.8600, lng: -73.1900), orderId: "1")    // ~9 mi
        let s = DriverSettings(onTheWayRadiusMi: 3)
        let a = TripPlanner().checkOnTheWay(origin: me, pickup: p, dropoff: near, pay: 6, settings: s)
        XCTAssertEqual(a.verdict, .nearFinal)
        XCTAssertTrue(a.message.hasPrefix("✅ ON THE WAY"))
        let b = TripPlanner().checkOnTheWay(origin: me, pickup: p, dropoff: far, pay: 6, settings: s)
        XCTAssertEqual(b.verdict, .offRoute)
        XCTAssertTrue(b.message.hasPrefix("❌ OFF ROUTE: ends"))
    }
}
