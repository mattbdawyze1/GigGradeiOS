import XCTest
@testable import GigCore

final class BannerLayoutTests: XCTestCase {
    let values: [BannerItem: String] = [
        .color: "🟡 Fair", .grade: "C", .app: "Uber", .pay: "$10.06",
        .hourly: "$18.29/hr⚠️", .perMile: "$1.12/mi⚠️", .miles: "9.0 mi", .minutes: "33 min",
        .net: "net $7.36", .verdict: "✅ ON THE WAY · ends 1.3 mi from last stop",
    ]

    func testStandardLayoutPutsVerdictOnLine2() {
        let t = BannerLayout.standard.compose(values)
        XCTAssertEqual(t.title, "🟡 Fair · C · Uber · $10.06")
        XCTAssertEqual(t.subtitle, "✅ ON THE WAY · ends 1.3 mi from last stop")
        XCTAssertEqual(t.body, "$18.29/hr⚠️ · $1.12/mi⚠️\n9.0 mi · 33 min · net $7.36")
    }

    func testCustomLinesAndOrder() {
        var l = BannerLayout.standard
        l.set(.grade, .off)
        l.set(.hourly, .title)      // put $/hr on the title line
        l.set(.net, .more)          // only when pulled down
        l.order = [.pay, .hourly, .color, .app] + l.order.filter { ![.pay, .hourly, .color, .app].contains($0) }
        let t = l.compose(values)
        XCTAssertEqual(t.title, "$10.06 · $18.29/hr⚠️ · 🟡 Fair · Uber")
        XCTAssertEqual(t.body, "$1.12/mi⚠️\n9.0 mi · 33 min\nnet $7.36")
    }

    func testMissingValuesAreSkippedAndTitleNeverEmpty() {
        var l = BannerLayout.standard
        for item in BannerItem.allCases { l.set(item, .off) }
        l.set(.verdict, .title)
        XCTAssertEqual(l.compose([:]).title, "New offer") // verdict not known yet
        XCTAssertEqual(l.compose([.verdict: "❌ OFF ROUTE · +5.6 mi extra"]).title, "❌ OFF ROUTE · +5.6 mi extra")
    }

    func testOldSwitchesCarryOverAndLayoutSurvivesSaving() throws {
        var p = NotificationPrefs()
        p.showGrade = false
        p.showNet = false
        XCTAssertEqual(p.effectiveLayout.slot(.grade), .off)
        XCTAssertEqual(p.effectiveLayout.slot(.net), .off)
        XCTAssertEqual(p.effectiveLayout.slot(.verdict), .line2)

        var custom = BannerLayout.standard
        custom.set(.miles, .title)
        p.layout = custom
        let back = try JSONDecoder().decode(NotificationPrefs.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.effectiveLayout.slot(.miles), .title)
    }

    func testShortVerdicts() {
        XCTAssertEqual(TripPlanner.OnTheWay(verdict: .onTheWay, addedMiles: 0.8).shortMessage, "✅ CLOSE BY · only +0.8 mi")
        XCTAssertEqual(TripPlanner.OnTheWay(verdict: .nearFinal, dropoffToFinalMi: 1.2, fromHere: true).shortMessage,
                       "✅ ON THE WAY · ends 1.2 mi from you")
        XCTAssertEqual(TripPlanner.OnTheWay(verdict: .offRoute, addedMiles: 5.6, dropoffToFinalMi: 7.2).shortMessage,
                       "❌ OFF ROUTE · +5.6 mi extra")
    }
}
