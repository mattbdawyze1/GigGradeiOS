import XCTest
@testable import GigCore

/// Version 5.9.6.3: reading Uber's store line and checking map search results against it.
final class StoreTextTests: XCTestCase {
    func testSplitsNameAndAddress() {
        XCTAssertEqual(StoreText.split("Wingstop 4747 Nesconset Hwy"),
                       .init(name: "Wingstop", number: "4747", street: "Nesconset Hwy"))
        XCTAssertEqual(StoreText.split("Taco Bell (4833 Nesconset Hwy)"),
                       .init(name: "Taco Bell", number: "4833", street: "Nesconset Hwy"))
        // Store ID after the address, and a cut-off line with no closing parenthesis.
        XCTAssertEqual(StoreText.split("Five Guys 5122 Nesconset Hwy. NY - 1330"),
                       .init(name: "Five Guys", number: "5122", street: "Nesconset Hwy"))
        XCTAssertEqual(StoreText.split("Bagel Boss (12 Main"), .init(name: "Bagel Boss", number: "12", street: "Main"))
        // Reading slip in the house number.
        XCTAssertEqual(StoreText.split("Panera 49l9 Nesconset Hwy").number, "4919")
    }

    func testNameOnly() {
        XCTAssertEqual(StoreText.split("Mudroom Market"), .init(name: "Mudroom Market", number: nil, street: nil))
        XCTAssertEqual(StoreText.split("PJ Sushi Teriyaki").name, "PJ Sushi Teriyaki")
        XCTAssertNil(StoreText.split("7-Eleven").number)
        XCTAssertFalse(StoreText.split("Go Burger").hasAddress)
    }

    func testCleansTheRouteIconBeforeTheName() {
        XCTAssertEqual(StoreText.clean("o Wingstop (4747 Nesconset Hwy)"), "Wingstop (4747 Nesconset Hwy)")
        XCTAssertEqual(StoreText.clean("° Mudroom Market"), "Mudroom Market")
        XCTAssertEqual(StoreText.clean("| • Go Burger"), "Go Burger")
        XCTAssertEqual(StoreText.split("8 Wingstop 4747 Nesconset Hwy").name, "Wingstop")
        XCTAssertEqual(StoreText.clean("A Taste of Thai"), "A Taste of Thai")
    }

    func testNameMatching() {
        XCTAssertTrue(StoreText.nameMatches(card: "Taco Bell", place: "Taco Bell"))
        XCTAssertTrue(StoreText.nameMatches(card: "Sizzlin' Chicken", place: "Sizzlin Chicken"))
        XCTAssertTrue(StoreText.nameMatches(card: "McDonald's®", place: "McDonald's"))
        XCTAssertTrue(StoreText.nameMatches(card: "PJ Sushi Teriyaki", place: "P J Sushi & Teriyaki"))
        XCTAssertFalse(StoreText.nameMatches(card: "Sizzlin' Chicken", place: "Chicken Shack"))
        XCTAssertFalse(StoreText.nameMatches(card: "Mudroom Market", place: "Stop & Shop"))
        XCTAssertFalse(StoreText.nameMatches(card: "Wingstop", place: "Wing Zone"))
    }

    func testStreetAndNumber() {
        XCTAssertTrue(StoreText.streetMatches(card: "Nesconset Hwy", place: "Nesconset Highway"))
        XCTAssertTrue(StoreText.streetMatches(card: "Nesconset Hwy", place: "Nesconset-Port Jefferson Hwy"))
        XCTAssertFalse(StoreText.streetMatches(card: "Nesconset Hwy", place: "Main St"))
        XCTAssertTrue(StoreText.numberMatches(card: "4833", place: "4833"))
        XCTAssertFalse(StoreText.numberMatches(card: "4833", place: "4747"))
    }

    // MARK: Your Uber cards (5.9.6.4)

    func line(_ t: String, _ e: Double) -> OCRLine { OCRLine(t, emphasis: e) }

    func testGreenCircleDoesNotMixUpStoreAndCustomer() throws {
        // Shahs Halal: the pulsing green circle makes the customer lines read as bold as the store.
        let lines = [
            OCRLine("Delivery"), OCRLine("Exclusive"), OCRLine("$6.02"), OCRLine("Guaranteed (incl. tip)"),
            line("29 min (8.9 mi) total", 208), line("Shahs Halal Food (Selden)", 170),
            line("Applecross Ln E & Sturrock Way, Stony", 206), line("Brook", 206), line("Accept", 97),
        ]
        let o = try XCTUnwrap(OfferParser.parse(lines: lines))
        XCTAssertEqual(o.pickupText, "Shahs Halal Food, Selden")
        XCTAssertEqual(o.dropoffText, "Applecross Ln E & Sturrock Way, Stony Brook")
        let parts = StoreText.split(o.pickupText!)
        XCTAssertEqual(parts.name, "Shahs Halal Food")
        XCTAssertEqual(parts.town, "Selden")
        XCTAssertFalse(parts.hasAddress)
    }

    func testTacoBellWithBrightCustomerLine() throws {
        let lines = [
            OCRLine("$7.51"), OCRLine("Guaranteed (incl. tip)"), line("19 min (4.2 mi) total", 210),
            line("Taco Bell (4833 Nesconset Hwy)", 209), line("Fireside Ln & Lodge Ln, East Setauket", 207),
            OCRLine("Accept"),
        ]
        let o = try XCTUnwrap(OfferParser.parse(lines: lines))
        XCTAssertEqual(o.pickupText, "Taco Bell 4833 Nesconset Hwy")
        XCTAssertEqual(o.dropoffText, "Fireside Ln & Lodge Ln, East Setauket")
    }

    func testMcDonaldsNumberAndStreetNameOnly() throws {
        let text = "$6.31\nGuaranteed (incl. tip)\n27 min (5.0 mi) total\nMcDonald's® (2324 NESCONSET)\nBarker Dr & Bucknell Ln, Stony Brook\nAccept"
        let o = try XCTUnwrap(OfferParser.parse(text))
        XCTAssertEqual(o.dropoffText, "Barker Dr & Bucknell Ln, Stony Brook")
        let parts = StoreText.split(o.pickupText!)
        XCTAssertEqual(parts.name, "McDonald's®")
        XCTAssertEqual(parts.number, "2324")
        XCTAssertTrue(StoreText.streetMatches(card: parts.street!, place: "Nesconset Hwy"))
        XCTAssertTrue(StoreText.nameMatches(card: parts.name, place: "McDonald's"))
    }

    func testStoreNameWithAmpersandStaysTheStore() throws {
        let lines = [
            OCRLine("$5.00"), OCRLine("Guaranteed (incl. tip)"), line("15 min (3.0 mi) total", 210),
            line("Ben & Jerry's", 209), line("Main St, Port Jefferson", 150), OCRLine("Accept"),
        ]
        let o = try XCTUnwrap(OfferParser.parse(lines: lines))
        XCTAssertEqual(o.pickupText, "Ben & Jerry's")
        XCTAssertEqual(o.dropoffText, "Main St, Port Jefferson")
    }

    func testCustomerStreetChecks() {
        XCTAssertTrue(StoreText.looksLikeCrossStreets("Fireside Ln & Lodge Ln, East Setauket"))
        XCTAssertFalse(StoreText.looksLikeCrossStreets("Ben & Jerry's"))
        XCTAssertTrue(StoreText.onStreets(card: "Barker Dr & Bucknell Ln, Stony Brook", place: "Bucknell Lane"))
        XCTAssertTrue(StoreText.onStreets(card: "Barker Dr & Bucknell Ln", place: "Barker Dr & Bucknell Ln"))
        XCTAssertFalse(StoreText.onStreets(card: "Barker Dr & Bucknell Ln", place: "Nicolls Rd"))
        XCTAssertTrue(StoreText.onStreets(card: "Bicycle Path", place: "Bicycle Path"))
        XCTAssertTrue(StoreText.sameTown("Port Jefferson Station", "Port Jefferson Sta"))
        XCTAssertFalse(StoreText.sameTown("Stony Brook", "Setauket"))
    }
}
