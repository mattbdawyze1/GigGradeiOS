import XCTest
@testable import GigCore

/// Version 5.4: the 👓 button. Lines below are real OCR output from your Uber screenshots (OCR reads "1" as "l").
final class TripGuideTests: XCTestCase {

    let s716a: [String] = [
            "NGTON",
            "LVD",
            "7:16",
            "Trip Guide",
            "Pickup·l order",
            "Chipotle Mexican Grill",
            "Expected by 7:22 PM",
            "Address",
            "1675 Sunrise Hwy, Bay Shore, NY 11706",
            "View details",
            "Pickup·l order",
            "Sarku Japan",
            "Expected by 7:25 PM",
            "Dropoff ·l order",
            "Kevin D.",
            "Expected by 7:47 PM",
            "Dropoff ·l order",
            "Joshua B.",
            "Expected by 7:48 PM",
            "Waybill",
            "STOP NEWREQUESTS",
        ]
    let s716b: [String] = [
            "NGTON",
            "LVD",
            "SST",
            "7:16",
            "Trip Guide",
            "Pickup·l order",
            "Chipotle Mexican Grill",
            "Expected by 7:22 PM",
            "Address",
            "1675 Sunrise Hwy, Bay Shore, NY 11706",
            "View details",
            "Pickup·l order",
            "Sarku Japan",
            "Expected by 7:25 PM",
            "Address",
            "17Ol Sunrise Highway FC-l, Bay Shore",
            "NY 11706",
            "View details",
            "Dropoff ·l order",
            "Kevin D.",
            "Expected by 7:47 PM",
            "Dropoff l order",
            "STOP NEWREQUESTS",
        ]
    let s717a: [String] = [
            "NGTON",
            "LVD",
            "7:17 ST",
            "Trip Guide",
            "Address",
            "1675 Sunrise Hwy, Bay Shore, NY 11706",
            "View details",
            "Pickup·l order",
            "Sarku Japan",
            "Expected by 7:25 PM",
            "Address",
            "17Ol Sunrise Highway FC-l, Bay Shore,",
            "NY 11706",
            "View details",
            "Dropoff ·l order",
            "Kevin D.",
            "Expected by 7:47 PM",
            "Address",
            "27 Virgil Dr",
            "Brentwood, NY",
            "View details",
            "STOP NEWREQUESTS",
        ]
    let s717b: [String] = [
            "NGTON",
            "LVD",
            "7:17 ST",
            "Trip Guide",
            "Sarku Japan",
            "Expected by 7:25 PM",
            "Address",
            "17Ol Sunrise Highway FC-l, Bay Shore,",
            "NY 11706",
            "View details",
            "Dropoff ·l order",
            "Kevin D.",
            "Expected by 7:47 PM",
            "Address",
            "27 Virgil Dr",
            "Brentwood, NY",
            "View details",
            "Dropoff l order",
            "Joshua B.",
            "Expected by 7:48 PM",
            "Waybill",
            "STOP NEWREQUESTS",
        ]
    let s717c: [String] = [
            "NGTON",
            "LVD",
            "7:17 4ST",
            "Trip Guide",
            "View details",
            "Dropoff ·l order",
            "Kevin D.",
            "Expected by 7:47 PM",
            "Address",
            "27 Virgil Dr",
            "Brentwood, NY",
            "View details",
            "Dropoff ·l order",
            "Joshua B.",
            "Expected by 7:48 PM",
            "Address",
            "638 Wilson Blvd",
            "Central Islip, NY",
            "View details",
            "Waybill",
            "STOP NEW REQUESTS",
        ]
    let s635: [String] = [
            "6:35 1",
            "Trip Guide",
            "Dropoff ·l order",
            "Kaitlyn R.",
            "Expected by 6:42 PM",
            "Address",
            "294 Cass St",
            "Dix Hills, NY",
            "View details",
            "Pickup·l order",
            "Chick-fil-A",
            "Expected by 6:56 PM",
            "Dropoff ·l order",
            "Stephanie O.",
            "Expected by 7:16 PM",
            "Waybill",
            "STOP NEW REQUESTS",
        ]
    let s526: [String] = [
            "5:261",
            "Trip Guide",
            "Hoibrook,IvY",
            "View details",
            "Pickup·l order",
            "McDonald's",
            "Expected by 5:48 PM",
            "Address",
            "4498 SUNRISE HWY,OAKDALE,NY,US",
            "NY 11769",
            "View details",
            "Dropoff ·l order",
            "Mike V.",
            "Address",
            "182 Connetquot Ave",
            "East Islip, NY",
            "View details",
            "Waybill",
            "STOP NEWREQUESTS",
        ]
    let pChanging: [String] = [
            "BELN",
            "6:011",
            "6.0 mi",
            "14 min",
            "Changing Times",
            "American Sports Bar",
            "& Grille",
            "29 East Main Street, Bay Shore,",
            "NY 11706",
            "Merchant Note: Enter the store and pick",
            "up at counter.",
            "Pick up l order",
            "Kaitlyn R.",
            "Verify",
            "52830:4 items ×",
            "Expected by 6:45 PM",
            "Help and support",
            "Complete pickup",
        ]
    let pChick: [String] = [
            "7 min",
            "2.9 mi",
            "Chick-fil-A",
            "656 Commack Rd, Commack",
            "NY 11725",
            "Merchant Note: Locate Mobile Pick-Up",
            "Area inside. Team Member will announce",
            "when order is ready, and will askyou to '.",
            "Pick up l order",
            "Stephanie O.",
            "Verify",
            "3 items >",
            "Expected by 7:19 PM",
            "Help and support",
            "Complete pickup",
        ]

    func lines(_ t: [String]) -> [OCRLine] { t.map { OCRLine($0) } }

    func testReadsOneScreen() {
        let s = TripGuide.sections(lines(s716b))
        XCTAssertEqual(s.map(\.name), ["Chipotle Mexican Grill", "Sarku Japan", "Kevin D."]) // cut-off section at the bottom skipped
        XCTAssertEqual(s[0].type, .pickup)
        XCTAssertEqual(s[0].address, "1675 Sunrise Hwy, Bay Shore, NY 11706")
        XCTAssertEqual(s[1].address, "1701 Sunrise Highway FC-l, Bay Shore, NY 11706") // "17Ol" fixed
        XCTAssertNil(s[2].address) // collapsed
    }

    func testScrollingPiecesTheGuideTogether() {
        var all: [GuideSection] = []
        for screen in [s716a, s716b, s717a, s717b, s717c] { all = TripGuide.merge(all, with: TripGuide.sections(lines(screen))) }
        XCTAssertEqual(all.map(\.name), ["Chipotle Mexican Grill", "Sarku Japan", "Kevin D.", "Joshua B."])
        XCTAssertEqual(all.map(\.type), [.pickup, .pickup, .dropoff, .dropoff])
        XCTAssertEqual(all[2].address, "27 Virgil Dr, Brentwood, NY")
        XCTAssertEqual(all[3].address, "638 Wilson Blvd, Central Islip, NY")
    }

    func testLinksFirstInFirstOut() {
        var all: [GuideSection] = []
        for screen in [s716a, s717c] { all = TripGuide.merge(all, with: TripGuide.sections(lines(screen))) }
        XCTAssertEqual(TripGuide.links(all, pickupScreens: []), [.pickup(0), .pickup(1), .pickup(0), .pickup(1)])
    }

    func testPickupScreenDecidesTheLink() {
        // Without the screen, first-in-first-out would give Kevin to Chipotle; the screen says Sarku instead.
        let guide = [GuideSection(type: .pickup, name: "Chipotle Mexican Grill"), GuideSection(type: .pickup, name: "Sarku Japan"),
                     GuideSection(type: .dropoff, name: "Kevin D."), GuideSection(type: .dropoff, name: "Joshua B.")]
        let screen = PickupScreen(store: "Sarku Japan", address: nil, customers: ["Kevin D."], seenAt: Date())
        XCTAssertEqual(TripGuide.links(guide, pickupScreens: [screen]), [.pickup(0), .pickup(1), .pickup(1), .pickup(0)])
    }

    func testPickupScreens() {
        let a = TripGuide.pickupScreen(lines(pChanging))!
        XCTAssertEqual(a.store, "Changing Times American Sports Bar & Grille")
        XCTAssertEqual(a.address, "29 East Main Street, Bay Shore, NY 11706")
        XCTAssertEqual(a.customers, ["Kaitlyn R."])
        let b = TripGuide.pickupScreen(lines(pChick))!
        XCTAssertEqual(b.store, "Chick-fil-A")
        XCTAssertEqual(b.customers, ["Stephanie O."])
    }

    func testAlreadyCollectedOrderStaysUnlinked() {
        // 6:35: Kaitlyn's food came from Changing Times (already picked up), Stephanie's from Chick-fil-A.
        let s = TripGuide.sections(lines(s635))
        XCTAssertEqual(s.map(\.name), ["Kaitlyn R.", "Chick-fil-A", "Stephanie O."])
        XCTAssertEqual(s[0].address, "294 Cass St, Dix Hills, NY")
        let screens = [TripGuide.pickupScreen(lines(pChanging))!, TripGuide.pickupScreen(lines(pChick))!]
        XCTAssertEqual(TripGuide.links(s, pickupScreens: screens),
                       [.store("Changing Times American Sports Bar & Grille"), .pickup(1), .pickup(1)])
        XCTAssertEqual(TripGuide.links(s, pickupScreens: []), [nil, .pickup(1), .pickup(1)]) // nothing above Kaitlyn
    }

    func testTopOfScrolledScreenAndBlackNumberedDropoff() {
        let s = TripGuide.sections(lines(s526)) // "Holbrook, NY" tail at the top is skipped
        XCTAssertEqual(s.map(\.name), ["McDonald's", "Mike V."])
        XCTAssertEqual(s[1].address, "182 Connetquot Ave, East Islip, NY")
        XCTAssertEqual(s[0].address, "4498 SUNRISE HWY,OAKDALE,NY,US, NY 11769")
    }

    func testFixesHouseNumbersAndKeys() {
        XCTAssertEqual(TripGuide.fixHouseNumber("l40l Brook Ave, Bay Shore, NY"), "1401 Brook Ave, Bay Shore, NY")
        XCTAssertEqual(TripGuide.fixHouseNumber("221B Baker Street"), "221B Baker Street")
        XCTAssertEqual(TripGuide.addressKey("27 Virgil Dr, Brentwood, NY"), "27 virgil")
        XCTAssertEqual(TripGuide.addressKey("4498 SUNRISE HWY,OAKDALE,NY"), "4498 sunrise")
    }
}
