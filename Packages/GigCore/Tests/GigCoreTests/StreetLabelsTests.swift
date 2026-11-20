import XCTest
@testable import GigCore

/// Version 4.9: placing the DoorDash customer pin from street names printed on a zoomed-in map.
final class StreetLabelsTests: XCTestCase {

    func testStreetNames() {
        for t in ["Pheasant Ln", "5th Ave", "Route 25A", "NY-347", "Tipton Rd", "Main St.", "Old Country Rd"] {
            XCTAssertTrue(StreetLabels.isStreetName(t), t)
        }
        for t in ["12 Main St", "$9.50", "Accept", "Starbucks", "Customer dropoff", "2 stops (5.1 mi)",
                  "Deliver by 7:40 PM", "Island", "Garden Ct & School Dr", "123 Main St, Smithtown"] {
            XCTAssertFalse(StreetLabels.isStreetName(t), t)
        }
    }

    func testCore() {
        XCTAssertEqual(StreetLabels.core("Pheasant Ln"), "pheasant")
        XCTAssertEqual(StreetLabels.core("5th Ave"), "5th")
        XCTAssertEqual(StreetLabels.core("N Country Rd"), "country")
    }

    func testNearestTwoDifferentStreets() {
        let pin = MapPins.Point(x: 600, y: 800)
        let lines = [
            OCRLine("$9.50", x: 600, y: 1700),
            OCRLine("Partridge Ln", x: 640, y: 760),     // closest
            OCRLine("Partridge Ln", x: 900, y: 700),     // same street again: skipped
            OCRLine("Pheasant Ln", x: 520, y: 900),      // second closest
            OCRLine("Nicolls Rd", x: 100, y: 200),       // far away
            OCRLine("Mystery Rd"),                        // no position: ignored
        ]
        XCTAssertEqual(StreetLabels.nearest(lines: lines, to: pin), ["Partridge Ln", "Pheasant Ln"])
    }

    func testFinalCustomerIsFarthestFromStore() {
        let pins = MapPins(me: nil, stores: [.init(x: 100, y: 100)],
                           customers: [.init(x: 200, y: 200), .init(x: 900, y: 900)])
        XCTAssertEqual(StreetLabels.finalCustomer(pins), MapPins.Point(x: 900, y: 900))
        let one = MapPins(me: nil, stores: [], customers: [.init(x: 5, y: 6)])
        XCTAssertEqual(StreetLabels.finalCustomer(one), MapPins.Point(x: 5, y: 6))
    }

    func testPlausibleDistance() {
        let store = Coord(lat: 40.90, lng: -73.10)
        let near = Coord(lat: 40.92, lng: -73.10)   // ≈ 1.4 mi
        let far = Coord(lat: 41.10, lng: -73.10)    // ≈ 14 mi
        XCTAssertTrue(StreetLabels.plausible(dropoff: near, pickup: store, me: nil, statedMiles: 4))
        XCTAssertFalse(StreetLabels.plausible(dropoff: far, pickup: store, me: nil, statedMiles: 4))
    }

    // Version 5.1: the address bubble from your screenshot (DoorDash, dark mode, 2 stores + 2 customers).
    func testPopupAddressFromScreenshot() {
        let lines = [
            OCRLine("East Northport", x: 700, y: 480),
            OCRLine("54 Elderwood Lane", x: 289, y: 757),
            OCRLine("South Huntington", x: 325, y: 833),
            OCRLine("$11.29 incl. tips", x: 320, y: 1460),
            OCRLine("4 stops (10.5 mi) • 32 min", x: 400, y: 1560),
            OCRLine("110 Commack Road, Commack, 11725 NY", x: 610, y: 1800),
            OCRLine("128 Commack Rd, Commack, 11725 NY", x: 590, y: 1980),
        ]
        XCTAssertEqual(StreetLabels.popupAddress(lines)?.text, "54 Elderwood Lane")

        let pins = MapPins(me: .init(x: 922, y: 730), stores: [.init(x: 860, y: 700)],
                           customers: [.init(x: 812, y: 700), .init(x: 289, y: 950)])
        let popup = StreetLabels.popupAddress(lines)!
        XCTAssertEqual(StreetLabels.pin(under: popup, in: pins), MapPins.Point(x: 289, y: 950))
    }

    func testHouseAddresses() {
        for t in ["54 Elderwood Lane", "12 Main St", "1600 Pennsylvania Ave", "7 5th Ave", "221B Baker Street"] {
            XCTAssertTrue(StreetLabels.isHouseAddress(t), t)
        }
        for t in ["110 Commack Road, Commack, 11725 NY", "4 stops (10.5 mi) • 32 min", "Pheasant Ln",
                  "$11.29 incl. tips", "32 min", "11725 NY", "0:39"] {
            XCTAssertFalse(StreetLabels.isHouseAddress(t), t)
        }
    }
}
