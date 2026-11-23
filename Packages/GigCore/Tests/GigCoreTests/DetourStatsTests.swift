import XCTest
@testable import GigCore

/// Version 5.9: Insights detour charts (0 to 5+ mi).
final class DetourStatsTests: XCTestCase {
    func rec(_ pickup: Double?, _ drop: Double?, pay: Double, perMile: Double, _ d: Decision = .pending) -> OfferRecord {
        var r = OfferRecord(app: .uber, pay: pay, miles: pay / perMile, minutes: 20, pickupText: nil, dropoffText: nil,
                            grade: "B", category: .fair, dollarsPerHour: 20, dollarsPerMile: perMile, decision: d)
        r.pickupDetourMi = pickup
        r.dropoffDetourMi = drop
        return r
    }

    func testBucketsRunZeroToFivePlus() {
        let rs = [rec(0.2, 0.5, pay: 8, perMile: 2, .accepted), rec(1.4, 2.5, pay: 6, perMile: 1),
                  rec(7.0, nil, pay: 4, perMile: 0.5), rec(nil, 5.0, pay: 9, perMile: 1.5)]
        let p = DetourStats.buckets(rs, kind: .pickup)
        XCTAssertEqual(p.map(\.label), ["0–1", "1–2", "2–3", "3–4", "4–5", "5+"])
        XCTAssertEqual(p.map(\.offers), [1, 1, 0, 0, 0, 1])
        XCTAssertEqual(p[0].acceptedPct, 100)
        XCTAssertNil(p[2].avgPerMile)
        let d = DetourStats.buckets(rs, kind: .dropoff)
        XCTAssertEqual(d.map(\.offers), [1, 0, 1, 0, 0, 1])   // 5.0 mi goes in 5+
    }

    func testInsights() {
        let rs = [rec(0.1, 0.2, pay: 8, perMile: 2), rec(0.5, 0.4, pay: 8, perMile: 2),
                  rec(2.5, 3.0, pay: 5, perMile: 1), rec(3.5, 4.0, pay: 5, perMile: 1)]
        var settings = DriverSettings()
        settings.pickupMaxDetourMi = 3.0
        let lines = DetourStats.insights(rs, settings: settings)
        XCTAssertTrue(lines.contains("75% of pickup detours were within your 3.0 mi limit (3 of 4)."), "\(lines)")
        XCTAssertTrue(lines.contains("50% of offers added under 1 mi at the pickup (2 of 4)."), "\(lines)")
        XCTAssertTrue(lines.contains("Pickup detours of 2+ mi paid $1.00/mi on average vs $2.00/mi under 1 mi."), "\(lines)")
    }
}
