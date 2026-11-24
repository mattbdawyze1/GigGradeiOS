import XCTest
@testable import GigCore

/// Version 5.9.6.6: Uber's map put together from several frames of the same view.
final class MapPinsMergeTests: XCTestCase {
    let view: [UInt8] = (0..<192).map { UInt8(($0 * 37) % 200) }

    func testSameViewFillsInMissingParts() {
        let a = MapPins(me: nil, stores: [.init(x: 300, y: 340)], customers: [], signature: view)
        let b = MapPins(me: .init(x: 307, y: 515), stores: [], customers: [], signature: view.map { $0 &+ 2 })
        let c = MapPins(me: nil, stores: [], customers: [.init(x: 727, y: 1058)], signature: view)
        XCTAssertTrue(MapPins.sameView(a.signature, b.signature))
        let m = a.merged(with: b).merged(with: c)
        XCTAssertEqual(m.me, .init(x: 307, y: 515))
        XCTAssertEqual(m.stores, [.init(x: 300, y: 340)])
        XCTAssertEqual(m.customers, [.init(x: 727, y: 1058)])
    }

    func testKeepsPinsButTakesTheNewestArrow() {
        let a = MapPins(me: .init(x: 1, y: 1), stores: [.init(x: 2, y: 2)], customers: [], signature: view)
        let b = MapPins(me: .init(x: 9, y: 9), stores: [.init(x: 8, y: 8)], customers: [.init(x: 7, y: 7)], signature: view)
        let m = a.merged(with: b)
        XCTAssertEqual(m.me, .init(x: 9, y: 9))          // you moved: the newer arrow wins
        let noArrow = MapPins(me: nil, stores: [], customers: [], signature: view)
        XCTAssertEqual(a.merged(with: noArrow).me, .init(x: 1, y: 1)) // no arrow in the newer frame: keep the last one
        XCTAssertEqual(m.stores, [.init(x: 2, y: 2)])
        XCTAssertEqual(m.customers, [.init(x: 7, y: 7)])
    }

    func testMovedMapIsNotTheSameView() {
        let moved = view.map { $0 &+ 40 }
        XCTAssertFalse(MapPins.sameView(view, moved))
        XCTAssertFalse(MapPins.sameView(view, nil))
    }

    func testSharedPinProvesTheMapDidNotMove() {
        let a = MapPins(me: .init(x: 307, y: 515), stores: [.init(x: 300, y: 340)], customers: [], signature: view)
        let same = MapPins(me: .init(x: 330, y: 500), stores: [.init(x: 304, y: 344)], customers: [.init(x: 727, y: 1058)],
                           signature: view)
        let moved = MapPins(me: nil, stores: [.init(x: 360, y: 400)], customers: [.init(x: 727, y: 1058)], signature: view)
        let arrowOnly = MapPins(me: .init(x: 307, y: 515), stores: [], customers: [], signature: view)
        XCTAssertTrue(a.sharesPin(with: same))        // store pin within a few pixels
        XCTAssertFalse(a.sharesPin(with: moved))      // store pin 85 px away: the map moved
        XCTAssertFalse(a.sharesPin(with: arrowOnly))  // only the arrow in common: not proof (you move)
    }
}
