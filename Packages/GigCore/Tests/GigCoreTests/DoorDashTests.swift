import XCTest
@testable import GigCore

/// Text as Vision reads it from real DoorDash offer screens (map labels included, top to bottom).
final class DoorDashTests: XCTestCase {

    func testSingleDropoffOffer() throws {
        let text = """
        Instagram
        Port Jefferson
        Decline
        Port Jefferson
        Station
        East Setauket
        Terryville
        $6.00 incl. tips
        2 stops (4.6 mi) • 17 min
        McDonald's
        5136 Nesconset Highway, Port Jefferson
        Station, 11776 NY
        Customer dropoff
        Accept
        0:38
        """
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.app, .doordash)
        XCTAssertEqual(o.pay, 6.00, accuracy: 0.001)
        XCTAssertEqual(o.miles ?? 0, 4.6, accuracy: 0.001)
        XCTAssertEqual(o.minutes, 17)
        XCTAssertEqual(o.pickupText, "McDonald's, 5136 Nesconset Highway, Port Jefferson Station, 11776 NY")
        XCTAssertNil(o.dropoffText) // DoorDash only shows the customer on the map
    }

    func testHighPayAndRouteNumberAddress() throws {
        let text = """
        N Country Rd
        Decline
        High pay for Silver
        $6.25
        incl. tips
        2 stops (2.4 mi) • 12 min
        Bagelicious Cafe
        1031 New York 112, Port Jefferson Station,
        11776 NY
        Customer dropoff
        Accept 0:37
        """
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.app, .doordash)
        XCTAssertEqual(o.pay, 6.25, accuracy: 0.001)
        XCTAssertEqual(o.pickupText, "Bagelicious Cafe, 1031 New York 112, Port Jefferson Station, 11776 NY")
        XCTAssertNil(o.dropoffText)
    }

    func testMultipleDropoffs() throws {
        let text = """
        Port Jefferson
        Decline
        High pay for Silver
        $10.35 incl. tips
        3 stops (4.4 mi) • 17 min
        Starbucks
        201 Main Street, Port Jefferson, 11777 NY
        Pick up 2 orders
        Multiple dropoffs (2 stops)
        Accept
        0:21
        """
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.pay, 10.35, accuracy: 0.001)
        XCTAssertEqual(o.miles ?? 0, 4.4, accuracy: 0.001)
        XCTAssertEqual(o.pickupText, "Starbucks, 201 Main Street, Port Jefferson, 11777 NY")
        XCTAssertNil(o.dropoffText)
    }

    func testStoreNameStartingWithNumber() throws {
        let text = "$3.00 incl. tips\n2 stops (2.2 mi) • 8 min\n7-Eleven\n120 New York 25A, Mount Sinai, 11766 NY\nCustomer dropoff\nAccept"
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.pickupText, "7-Eleven 120 New York 25A, Mount Sinai, 11766 NY")
        XCTAssertNil(o.dropoffText)
    }
}
