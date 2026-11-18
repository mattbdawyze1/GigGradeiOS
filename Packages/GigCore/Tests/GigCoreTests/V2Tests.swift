import XCTest
@testable import GigCore

final class V2Tests: XCTestCase {
    let s = DriverSettings(hourlyFair: 18, hourlyGood: 25, perMileFair: 1.0, perMileGood: 1.5)
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1
        return c
    }
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testCategories() {
        func cat(_ pay: Double, _ mi: Double, _ min: Int) -> OfferCategory {
            OfferScorer.score(Offer(app: .unknown, pay: pay, miles: mi, minutes: min, pickupText: nil, dropoffText: nil, rawText: ""), s).category
        }
        XCTAssertEqual(cat(15, 8, 30), .good)     // $30/hr, $1.88/mi
        XCTAssertEqual(cat(9.75, 6.4, 28), .fair) // $20.9/hr fair, $1.52/mi good
        XCTAssertEqual(cat(4, 9, 25), .bad)
        XCTAssertEqual(cat(20, 25, 30), .bad)     // great hourly but $0.80/mi is bad
    }

    func testVersion1SettingsStillLoad() throws {
        let old = #"{"targetHourly":30,"targetPerMile":2,"costPerMile":0.25,"onTheWayRadiusMi":3,"maxDetourMi":2}"#
        let d = try JSONDecoder().decode(DriverSettings.self, from: Data(old.utf8))
        XCTAssertEqual(d.hourlyGood, 30)
        XCTAssertLessThan(d.hourlyFair, 30)
        XCTAssertEqual(d.perMileGood, 2)
        XCTAssertEqual(d.costPerMile, 0.25)
        let round = try JSONDecoder().decode(DriverSettings.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(round, d)
    }

    func testNotificationPrefsTolerateMissingKeys() throws {
        let p = try JSONDecoder().decode(NotificationPrefs.self, from: Data(#"{"showNet":false,"badSound":"none"}"#.utf8))
        XCTAssertFalse(p.showNet)
        XCTAssertTrue(p.showHourly)
        XCTAssertEqual(p.sound(for: .bad), SoundChoice.none)
        XCTAssertEqual(p.sound(for: .good), .chime)
    }

    func testPeriods() {
        let d = date(2026, 11, 17)
        let q = Period.quarter.interval(containing: d, calendar: utc)
        XCTAssertEqual(q.start, date(2026, 10, 1, 0))
        XCTAssertEqual(q.end, date(2027, 1, 1, 0))
        XCTAssertEqual(Period.quarter.title(for: q, calendar: utc), "Q4 2026")
        XCTAssertEqual(Period.day.buckets(for: Period.day.interval(containing: d, calendar: utc), calendar: utc).count, 24)
        XCTAssertEqual(Period.week.buckets(for: Period.week.interval(containing: d, calendar: utc), calendar: utc).count, 7)
        XCTAssertEqual(Period.month.buckets(for: Period.month.interval(containing: d, calendar: utc), calendar: utc).count, 30)
        XCTAssertEqual(Period.year.buckets(for: Period.year.interval(containing: d, calendar: utc), calendar: utc).count, 12)
        XCTAssertEqual(Period.quarter.buckets(for: q, calendar: utc).count, 14) // 92 days in 7-day chunks
        XCTAssertEqual(Period.month.shift(d, by: -1, calendar: utc), date(2026, 10, 17))
    }

    func record(_ pay: Double, _ mi: Double?, _ min: Int?, _ cat: OfferCategory, _ dec: Decision, _ app: GigApp = .uber,
                at d: Date) -> OfferRecord {
        OfferRecord(date: d, app: app, pay: pay, miles: mi, minutes: min, pickupText: nil, dropoffText: nil,
                    grade: "B", category: cat, dollarsPerHour: nil, dollarsPerMile: nil, decision: dec)
    }

    func testSummaryUsesAcceptedOnly() {
        let d = date(2026, 11, 17)
        let recs = [
            record(10, 5, 30, .good, .accepted, at: d),
            record(20, 10, 30, .good, .accepted, .doordash, at: d),
            record(6, 8, 30, .bad, .declined, at: d),
            record(15, 5, 20, .good, .declined, at: d),
            record(9, 4, 20, .fair, .pending, at: d),
        ]
        let sum = Stats.summary(recs, costPerMile: 0.5)
        XCTAssertEqual(sum.offers, 5)
        XCTAssertEqual(sum.good, 3); XCTAssertEqual(sum.fair, 1); XCTAssertEqual(sum.bad, 1)
        XCTAssertEqual(sum.income, 30)
        XCTAssertEqual(sum.avgHourly ?? 0, 30, accuracy: 0.001)   // $30 over 1 hour
        XCTAssertEqual(sum.avgPerMile ?? 0, 2, accuracy: 0.001)   // $30 over 15 mi
        XCTAssertEqual(sum.net, 22.5, accuracy: 0.001)
        XCTAssertEqual(sum.acceptanceRate ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(sum.goodDeclined, 1)

        let apps = Stats.byApp(recs, costPerMile: 0.5)
        XCTAssertEqual(apps.first?.app, .doordash)
        let buckets = Stats.buckets(recs, period: .day, interval: Period.day.interval(containing: d, calendar: utc),
                                    calendar: utc, costPerMile: 0.5)
        XCTAssertEqual(buckets[12].summary.income, 30)
        let tips = Stats.insights(current: sum, previous: PeriodSummary(), buckets: buckets, apps: apps, period: .day, settings: s)
        XCTAssertTrue(tips.contains { $0.contains("$30.00") })
    }

    func testOfferLogRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = OfferLog(directory: dir)
        let d = Date()
        let r = record(12, 4, 20, .good, .pending, at: d)
        log.append(r)
        log.append(record(5, 9, 30, .bad, .pending, at: d))
        let key = OfferLog.dayKey(d)
        XCTAssertEqual(log.records(dayKey: key).count, 2)
        log.setDecision(.accepted, id: r.id, dayKey: key)
        XCTAssertEqual(log.records(dayKey: key).first { $0.id == r.id }?.decision, .accepted)
        XCTAssertEqual(log.records(in: Period.day.interval(containing: d)).count, 2)
        log.delete(id: r.id, dayKey: key)
        XCTAssertEqual(log.records(dayKey: key).count, 1)
        try? FileManager.default.removeItem(at: dir)
    }
}
