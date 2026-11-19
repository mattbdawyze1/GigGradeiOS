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
}
