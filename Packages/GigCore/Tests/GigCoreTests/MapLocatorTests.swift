import XCTest
@testable import GigCore

final class MapLocatorTests: XCTestCase {
    let me = Coord(lat: 40.9150, lng: -73.0450)
    let store = Coord(lat: 40.9460, lng: -73.0690)
    let cust = Coord(lat: 40.9330, lng: -73.0790)

    /// Draws a north-up map at `mpp` meters per pixel with "me" at `origin`.
    func screen(_ c: Coord, mpp: Double, origin: (Double, Double) = (600, 1200)) -> MapPins.Point {
        let p = MapLocator.project(c), o = MapLocator.project(me)
        let s = mpp / cos(40.93 * .pi / 180)
        return MapPins.Point(x: origin.0 + (p.x - o.x) / s, y: origin.1 - (p.y - o.y) / s)
    }

    func testRecoversCustomerOnNorthUpMap() throws {
        for mpp in [1.5, 2.5, 6.0] {
            let pins = MapPins(me: screen(me, mpp: mpp), stores: [screen(store, mpp: mpp)], customers: [screen(cust, mpp: mpp)])
            let e = try XCTUnwrap(MapLocator.locate(pins: pins, me: me, store: store, statedMiles: 4.0))
            XCTAssertLessThan(Geo.straightMiles(e.finalDropoff, cust) * 1609, 5) // within 5 meters
            XCTAssertEqual(e.rotationDegrees, 0, accuracy: 0.5)
            XCTAssertEqual(e.metersPerPixel, mpp, accuracy: 0.05)
        }
    }

    /// Two real DoorDash screenshots of the same offer area at different zooms (pixel positions
    /// measured from the screenshots) must put the customer in the same place.
    func testRealScreenshotsAgreeAcrossZoom() throws {
        let a = MapPins(me: .init(x: 868, y: 1189), stores: [.init(x: 448, y: 527)], customers: [.init(x: 302, y: 928)])
        let b = MapPins(me: .init(x: 908, y: 1281), stores: [.init(x: 460, y: 576)], customers: [.init(x: 304, y: 1004)])
        let ea = try XCTUnwrap(MapLocator.locate(pins: a, me: me, store: store, statedMiles: nil))
        let eb = try XCTUnwrap(MapLocator.locate(pins: b, me: me, store: store, statedMiles: nil))
        XCTAssertLessThan(Geo.straightMiles(ea.finalDropoff, eb.finalDropoff) * 1609, 15)
    }

    func testRejectsRotatedOrBadData() {
        // Same screen, but "me" GPS is somewhere else entirely -> implied rotation is large -> reject.
        let pins = MapPins(me: screen(me, mpp: 2.5), stores: [screen(store, mpp: 2.5)], customers: [screen(cust, mpp: 2.5)])
        let wrongMe = Coord(lat: 40.9460, lng: -73.1200) // due west of the store
        XCTAssertNil(MapLocator.locate(pins: pins, me: wrongMe, store: store, statedMiles: nil))
        // Missing blue dot -> nothing to measure against.
        XCTAssertNil(MapLocator.locate(pins: MapPins(me: nil, stores: pins.stores, customers: pins.customers),
                                       me: me, store: store, statedMiles: nil))
    }

    func testFinalDropoffIsFarthestCustomerFromStore() throws {
        let near = Coord(lat: 40.9420, lng: -73.0700)
        let pins = MapPins(me: screen(me, mpp: 3), stores: [screen(store, mpp: 3)],
                           customers: [screen(cust, mpp: 3), screen(near, mpp: 3)])
        let e = try XCTUnwrap(MapLocator.locate(pins: pins, me: me, store: store, statedMiles: 4.4))
        XCTAssertEqual(e.customers.count, 2)
        XCTAssertLessThan(Geo.straightMiles(e.finalDropoff, cust) * 1609, 5)
    }
}
