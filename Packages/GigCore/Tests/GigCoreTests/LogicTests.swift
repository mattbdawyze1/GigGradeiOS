import XCTest
@testable import GigCore

final class LogicTests: XCTestCase {

    let settings = DriverSettings(hourlyFair: 18, hourlyGood: 25, perMileFair: 1.0, perMileGood: 1.5)

    func testDoorDashStyleOffer() throws {
        let text = """
        DoorDash
        $9.75
        Guaranteed (incl. tips)
        28 min  6.4 mi total
        Pickup
        Chipotle
        Customer dropoff
        123 Main St, Springfield
        Decline   Accept
        """
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.app, .doordash)
        XCTAssertEqual(o.pay, 9.75, accuracy: 0.001)
        XCTAssertEqual(o.miles ?? 0, 6.4, accuracy: 0.001)
        XCTAssertEqual(o.minutes, 28)
        XCTAssertEqual(o.pickupText, "Chipotle")
        XCTAssertEqual(o.dropoffText, "123 Main St, Springfield")
    }

    func testUberStyleOfferAddsLegs() throws {
        let text = "Delivery\n$12.40\nIncludes expected tip\n8 mins (2.1 mi) away\n25 mins (7.9 mi) trip\nAccept"
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.app, .uber)
        XCTAssertEqual(o.pay, 12.40, accuracy: 0.001)
        XCTAssertEqual(o.miles ?? 0, 10.0, accuracy: 0.001)
        XCTAssertEqual(o.minutes, 33)
    }

    func testPeakPayIgnoredAndHours() throws {
        let o = try XCTUnwrap(OfferParser.parse("Grubhub\n$24.00\n+$2.00 peak\n1 hr 10 min\n18.5 mi\nAccept"))
        XCTAssertEqual(o.pay, 24.0, accuracy: 0.001)
        XCTAssertEqual(o.minutes, 70)
    }

    func testDeliverByFallback() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 19, minute: 0))!
        let o = try XCTUnwrap(OfferParser.parse("Instacart batch\n$30.00\n9.0 mi\nDeliver by 7:45 PM\nAccept",
                                                now: now, calendar: cal))
        XCTAssertEqual(o.minutes, 45)
    }

    func testNonOfferIgnored() {
        XCTAssertNil(OfferParser.parse("Earnings this week $412.50\n38 deliveries"))
    }

    func testGrades() {
        let good = OfferScorer.score(Offer(app: .unknown, pay: 15, miles: 8, minutes: 30, pickupText: nil, dropoffText: nil, rawText: ""), settings)
        XCTAssertEqual(good.dollarsPerHour ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(good.hourlyPctOfTarget, 120)
        XCTAssertEqual(good.grade, "A")
        let bad = OfferScorer.score(Offer(app: .unknown, pay: 4, miles: 9, minutes: 25, pickupText: nil, dropoffText: nil, rawText: ""), settings)
        XCTAssertEqual(bad.grade, "F")
    }

    func testOnTheWayVsOffRoute() {
        let origin = Coord(lat: 40.70, lng: -74.0)
        let planner = TripPlanner(stops: [Stop(type: .dropoff, label: "final", location: Coord(lat: 40.76, lng: -74.0), orderId: "1")])
        let p = Stop(type: .pickup, label: "p", location: Coord(lat: 40.72, lng: -74.001), orderId: "2")
        let d = Stop(type: .dropoff, label: "d", location: Coord(lat: 40.745, lng: -74.002), orderId: "2")
        // Ends ~1.3 mi from the final stop -> ON THE WAY (radius 3)
        let good = planner.checkOnTheWay(origin: origin, pickup: p, dropoff: d, pay: 8, settings: DriverSettings(maxDetourMi: 1))
        XCTAssertEqual(good.verdict, .nearFinal)
        XCTAssertTrue(good.message.hasPrefix("✅ ON THE WAY"))
        // Same order with a tiny radius: it's still only a small detour -> CLOSE BY
        let detour = planner.checkOnTheWay(origin: origin, pickup: p, dropoff: d, pay: 8,
                                           settings: DriverSettings(onTheWayRadiusMi: 0.5, maxDetourMi: 1))
        XCTAssertEqual(detour.verdict, .onTheWay)
        XCTAssertTrue(detour.message.hasPrefix("✅ CLOSE BY"))
        XCTAssertEqual(good.insertion?.order.count, 3)

        let far = Stop(type: .dropoff, label: "far", location: Coord(lat: 40.60, lng: -74.0), orderId: "3")
        let bad = planner.checkOnTheWay(origin: origin, pickup: p, dropoff: far, pay: 8,
                                        settings: DriverSettings(onTheWayRadiusMi: 3, maxDetourMi: 1))
        XCTAssertEqual(bad.verdict, .offRoute)
    }

    func testMaxFourStops() {
        let l = Coord(lat: 0, lng: 0)
        var planner = TripPlanner()
        for i in 0..<4 { XCTAssertTrue(planner.add(Stop(type: .pickup, label: "s\(i)", location: l, orderId: "\(i)"))) }
        XCTAssertFalse(planner.add(Stop(type: .dropoff, label: "x", location: l, orderId: "9")))
        let r = planner.checkOnTheWay(origin: l, pickup: Stop(type: .pickup, label: "p", location: l, orderId: "5"),
                                      dropoff: Stop(type: .dropoff, label: "d", location: l, orderId: "5"),
                                      pay: 5, settings: settings)
        XCTAssertEqual(r.verdict, .tooManyStops)
    }
}
