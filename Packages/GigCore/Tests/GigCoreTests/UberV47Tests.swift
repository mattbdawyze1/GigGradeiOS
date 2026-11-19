import XCTest
@testable import GigCore

/// Brightness ("emphasis") values below were measured on your real Uber screenshots:
/// store line ≈ 200–215, gray dropoff line ≈ 145–155 (light mode) / 182 (dark mode).
final class UberV47Tests: XCTestCase {

    func line(_ t: String, _ e: Double) -> OCRLine { OCRLine(t, emphasis: e) }

    func testDarkModeSplitByBrightness() throws {
        let lines = [
            OCRLine("Delivery"), OCRLine("Exclusive"), OCRLine("$5.45"), OCRLine("Guaranteed (incl. tip)"),
            line("17 min (2.9 mi) total", 208), line("Lemon Leaf Grill", 208),
            line("Partridge Ln & Pheasant Ln, East", 182), line("Setauket", 182), line("Accept", 97),
        ]
        let o = try XCTUnwrap(OfferParser.parse(lines: lines))
        XCTAssertEqual(o.app, .uber)
        XCTAssertEqual(o.pickupText, "Lemon Leaf Grill")
        XCTAssertEqual(o.dropoffText, "Partridge Ln & Pheasant Ln, East Setauket")
    }

    func testBrightnessBeatsMisleadingLineBreaks() throws {
        // The store wraps onto a line that contains a comma; without brightness this would be read as the dropoff.
        let lines = [
            OCRLine("$9.10"), OCRLine("Guaranteed (incl. tip)"),
            line("24 min (6.0 mi) total", 210), line("Bagel Boss (12 Main St,", 208),
            line("Suite 4)", 206), line("Oak Ave, Setauket", 150), OCRLine("Accept"),
        ]
        let o = try XCTUnwrap(OfferParser.parse(lines: lines))
        XCTAssertEqual(o.pickupText, "Bagel Boss 12 Main St, Suite 4")
        XCTAssertEqual(o.dropoffText, "Oak Ave, Setauket")
    }

    func testTextAfterClosingParenthesisIsDropoff() throws {
        // Store and dropoff run together on one line (no brightness info).
        let text = "$7.20\nGuaranteed (incl. tip)\n19 min (4.1 mi) total\nTaco Bell (4833 Nesconset Hwy) Smithtown Byp, Smithtown\nAccept"
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.pickupText, "Taco Bell 4833 Nesconset Hwy")
        XCTAssertEqual(o.dropoffText, "Smithtown Byp, Smithtown")
    }

    func testStoreIdAfterParenthesisStaysWithStore() throws {
        let text = "$6.52\nGuaranteed (incl. tip)\n23 min (7.0 mi) total\nFive Guys (5122 Nesconset Hwy.) NY -\n1330\nNicolls Rd, Stony Brook\nMatch"
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.pickupText, "Five Guys 5122 Nesconset Hwy. NY - 1330")
        XCTAssertEqual(o.dropoffText, "Nicolls Rd, Stony Brook")
    }

    func testDiagnoseExplainsMisses() {
        XCTAssertEqual(OfferParser.diagnose("Delivery\nGuaranteed (incl. tip)\n17 min (2.9 mi) total\nAccept"), "No price ($) was read")
        XCTAssertEqual(OfferParser.diagnose("$5.45\nGuaranteed (incl. tip)\nLemon Leaf Grill\nAccept"), "No miles or minutes were read")
        XCTAssertNil(OfferParser.diagnose("$5.45\n17 min (2.9 mi) total\nAccept"))
        XCTAssertTrue(OfferParser.looksOfferish("$5.45\nGuaranteed (incl. tip)"))
        XCTAssertFalse(OfferParser.looksOfferish("Earnings this week"))
    }

    func testPartialVerdictWhenPickupNotFound() {
        let l = Coord(lat: 40.90, lng: -73.05)
        let planner = TripPlanner(stops: [Stop(type: .dropoff, label: "final", location: Coord(lat: 40.95, lng: -73.05), orderId: "1")])
        let near = Stop(type: .dropoff, label: "d", location: Coord(lat: 40.955, lng: -73.05), orderId: "2")
        let r = planner.checkOnTheWay(origin: l, pickup: nil, dropoff: near, pay: 6, settings: DriverSettings(onTheWayRadiusMi: 3))
        XCTAssertEqual(r.verdict, .nearFinal)
        XCTAssertTrue(r.approximate)
        XCTAssertEqual(r.shortMessage, "≈ ✅ ON THE WAY · ends 0.4 mi from last stop")
        let far = Stop(type: .dropoff, label: "d", location: Coord(lat: 40.80, lng: -73.20), orderId: "2")
        let r2 = planner.checkOnTheWay(origin: l, pickup: nil, dropoff: far, pay: 6, settings: DriverSettings(onTheWayRadiusMi: 3))
        XCTAssertTrue(r2.shortMessage.hasPrefix("≈ ❌ OFF ROUTE · ends"))
    }

    func testLocatePickupFromMapWhenOnlyDropoffIsKnown() throws {
        // North-up synthetic map: me, store and customer drawn at 2.5 m/px.
        let me = Coord(lat: 40.9150, lng: -73.0450), store = Coord(lat: 40.9460, lng: -73.0690),
            cust = Coord(lat: 40.9330, lng: -73.0790)
        func screen(_ c: Coord) -> MapPins.Point {
            let p = MapLocator.project(c), o = MapLocator.project(me), s = 2.5 / cos(40.93 * .pi / 180)
            return .init(x: 600 + (p.x - o.x) / s, y: 1200 - (p.y - o.y) / s)
        }
        let pins = MapPins(me: screen(me), stores: [screen(store)], customers: [screen(cust)])
        let found = try XCTUnwrap(MapLocator.locatePickup(pins: pins, me: me, dropoff: cust))
        XCTAssertLessThan(Geo.straightMiles(found, store) * 1609, 5)
    }
}
