import XCTest
@testable import GigCore

/// Version 5.5: 👓 for DoorDash. Real OCR lines (text, x, y, height) from your DoorDash screenshots.
final class DoorDashGuideTests: XCTestCase {

    static func L(_ t: String, _ x: Double, _ y: Double, _ h: Double) -> OCRLine { OCRLine(t, x: x, y: y, h: h) }

    let list1037: [OCRLine] = [
            DoorDashGuideTests.L("10:37 1", 180, 100, 41),
            DoorDashGuideTests.L("Your route", 284, 398, 85),
            DoorDashGuideTests.L("4 stops remaining", 266, 494, 55),
            DoorDashGuideTests.L("etHwy", 680, 731, 74),
            DoorDashGuideTests.L("t Jefferson", 160, 742, 37),
            DoorDashGuideTests.L("Station", 125, 799, 46),
            DoorDashGuideTests.L("Norwood Ave", 249, 1012, 76),
            DoorDashGuideTests.L("Terryville", 550, 1338, 47),
            DoorDashGuideTests.L("mapbox", 232, 1414, 41),
            DoorDashGuideTests.L("In progress", 312, 1600, 46),
            DoorDashGuideTests.L("Wingstop - 3065", 398, 1658, 53),
            DoorDashGuideTests.L("Pickup : 10:41 PM", 402, 1720, 55),
            DoorDashGuideTests.L("Taco Bell - 002698", 418, 1835, 42),
            DoorDashGuideTests.L("Pickup : 10:45 PM", 407, 1906, 53),
            DoorDashGuideTests.L("Christina R", 326, 2020, 47),
            DoorDashGuideTests.L("Drop off . 10:53 PM", 424, 2090, 51),
            DoorDashGuideTests.L("Kathleen P", 324, 2206, 43),
            DoorDashGuideTests.L("Drop off . 10:55 PM", 424, 2275, 52),
            DoorDashGuideTests.L("Current dash", 362, 2479, 36),
            DoorDashGuideTests.L("Ends at 9:00 PM tomorrow", 510, 2536, 45),
        ]
    let popWingstop: [OCRLine] = [
            DoorDashGuideTests.L("10:38 1", 179, 98, 41),
            DoorDashGuideTests.L("Your route", 284, 398, 81),
            DoorDashGuideTests.L("4 stops remaining", 266, 494, 57),
            DoorDashGuideTests.L("etHwy", 679, 731, 74),
            DoorDashGuideTests.L("t Jefferson", 160, 741, 42),
            DoorDashGuideTests.L("Station", 124, 798, 49),
            DoorDashGuideTests.L("Norwood Ave", 248, 1012, 74),
            DoorDashGuideTests.L("In progress", 158, 1225, 44),
            DoorDashGuideTests.L("Wingstop - 3065", 335, 1304, 73),
            DoorDashGuideTests.L("Pickup : 10:41 PM", 243, 1385, 46),
            DoorDashGuideTests.L("4747 Nesconset Hwy", 546, 1560, 71),
            DoorDashGuideTests.L("# Unit7", 353, 1640, 50),
            DoorDashGuideTests.L("Port Jefferson Station, NY 11776", 608, 1712, 48),
            DoorDashGuideTests.L("Pick up in store", 467, 1930, 68),
            DoorDashGuideTests.L("1 item", 308, 1998, 51),
            DoorDashGuideTests.L("Back to task", 604, 2198, 43),
            DoorDashGuideTests.L("Copy address", 649, 2392, 55),
        ]
    let popTacoBell: [OCRLine] = [
            DoorDashGuideTests.L("10:38 1", 180, 100, 41),
            DoorDashGuideTests.L("Your route", 284, 398, 81),
            DoorDashGuideTests.L("4 stops remaining", 266, 494, 57),
            DoorDashGuideTests.L("etHwy", 679, 731, 74),
            DoorDashGuideTests.L("t Jefferson", 160, 741, 42),
            DoorDashGuideTests.L("Station", 124, 798, 49),
            DoorDashGuideTests.L("Norwood Ave", 248, 1012, 75),
            DoorDashGuideTests.L("Tac0 Bell - 002698", 365, 1382, 56),
            DoorDashGuideTests.L("Pickup .10:45 PM", 248, 1466, 46),
            DoorDashGuideTests.L("4833 Nesconset Highway", 615, 1641, 72),
            DoorDashGuideTests.L("Port Jefferson Station, NY 11776", 608, 1712, 49),
            DoorDashGuideTests.L("Pick up in store", 468, 1930, 68),
            DoorDashGuideTests.L("2 items", 325, 1998, 51),
            DoorDashGuideTests.L("Switch to this task", 604, 2197, 40),
            DoorDashGuideTests.L("Copy address", 650, 2392, 55),
        ]
    let popChristina: [OCRLine] = [
            DoorDashGuideTests.L("10:38 1", 180, 100, 41),
            DoorDashGuideTests.L("Your route", 284, 398, 85),
            DoorDashGuideTests.L("4 stops remaining", 266, 494, 57),
            DoorDashGuideTests.L("etHwy", 679, 732, 73),
            DoorDashGuideTests.L("tJefferson", 160, 741, 42),
            DoorDashGuideTests.L("Station", 124, 798, 49),
            DoorDashGuideTests.L("Norwood Ave", 248, 1012, 74),
            DoorDashGuideTests.L("Terryville", 550, 1338, 47),
            DoorDashGuideTests.L("mapbox", 232, 1413, 46),
            DoorDashGuideTests.L("Christina R", 239, 1590, 53),
            DoorDashGuideTests.L("Dropoff . 10:53 PM", 256, 1674, 47),
            DoorDashGuideTests.L("24 Kensington Way", 527, 1849, 74),
            DoorDashGuideTests.L("Port Jefferson Station, NY 11776", 608, 1920, 48),
            DoorDashGuideTests.L("Leave at door", 411, 2159, 42),
            DoorDashGuideTests.L("Copy address", 650, 2392, 59),
        ]
    let popKathleen: [OCRLine] = [
            DoorDashGuideTests.L("10:38 1", 180, 100, 41),
            DoorDashGuideTests.L("Your route", 284, 398, 85),
            DoorDashGuideTests.L("4 stops remaining", 266, 494, 57),
            DoorDashGuideTests.L("etHwy", 679, 732, 73),
            DoorDashGuideTests.L("tJefferson", 160, 741, 42),
            DoorDashGuideTests.L("Station", 124, 798, 49),
            DoorDashGuideTests.L("Norwood Ave", 248, 1012, 74),
            DoorDashGuideTests.L("Terryville", 550, 1338, 47),
            DoorDashGuideTests.L("mapbox", 232, 1413, 46),
            DoorDashGuideTests.L("Kathleen P", 232, 1590, 60),
            DoorDashGuideTests.L("Dropoff . 10:55 PM", 257, 1674, 47),
            DoorDashGuideTests.L("24 Kensington Way", 527, 1849, 74),
            DoorDashGuideTests.L("Port Jefferson Station, NY 11776", 608, 1920, 48),
            DoorDashGuideTests.L("Leave at door", 411, 2159, 42),
            DoorDashGuideTests.L("Copy address", 650, 2392, 59),
        ]
    let taskWingstop: [OCRLine] = [
            DoorDashGuideTests.L("lematisS", 76, 156, 157),
            DoorDashGuideTests.L("10:36 1", 180, 99, 40),
            DoorDashGuideTests.L("nset Hwy", 1121, 162, 147),
            DoorDashGuideTests.L("Ave", 143, 159, 58),
            DoorDashGuideTests.L("$18.10", 605, 269, 48),
            DoorDashGuideTests.L("This dash", 603, 326, 39),
            DoorDashGuideTests.L("Norwood-Ave", 170, 376, 77),
            DoorDashGuideTests.L("Broadway", 331, 544, 157),
            DoorDashGuideTests.L("Minrol St", 350, 698, 45),
            DoorDashGuideTests.L("Pick up by 10:41 PM", 333, 868, 66),
            DoorDashGuideTests.L("Wingstop - 3065", 482, 983, 132),
            DoorDashGuideTests.L("4747 Nesconset Hwy # Unit7", 564, 1176, 52),
            DoorDashGuideTests.L("Port Jefferson Station, NY 11776", 584, 1240, 43),
            DoorDashGuideTests.L("Store notes", 352, 1476, 46),
            DoorDashGuideTests.L("\"Pick up at Register\"", 334, 1668, 53),
            DoorDashGuideTests.L("Pick up at store", 401, 1874, 54),
            DoorDashGuideTests.L("1 order", 294, 1934, 53),
            DoorDashGuideTests.L("Kathleen P", 226, 2126, 46),
            DoorDashGuideTests.L("Navigate", 604, 2370, 67),
        ]
    let taskChristina: [OCRLine] = [
            DoorDashGuideTests.L("11:00 1", 180, 100, 41),
            DoorDashGuideTests.L("5Gw", 993, 100, 40),
            DoorDashGuideTests.L("$18.10", 605, 269, 48),
            DoorDashGuideTests.L("This dash", 603, 326, 37),
            DoorDashGuideTests.L("Hwy", 485, 391, 53),
            DoorDashGuideTests.L("ve", 16, 728, 29),
            DoorDashGuideTests.L("Deliver by 11:07 PM", 326, 1138, 65),
            DoorDashGuideTests.L("Christina R", 334, 1245, 108),
            DoorDashGuideTests.L(" Call", 180, 1412, 45),
            DoorDashGuideTests.L("回 Message", 464, 1414, 49),
            DoorDashGuideTests.L("24 Kensington Way", 447, 1602, 55),
            DoorDashGuideTests.L("Port Jefferson Station, NY 11776", 584, 1666, 49),
            DoorDashGuideTests.L("Leave at door", 378, 1902, 43),
            DoorDashGuideTests.L("Christina R", 342, 2088, 43),
            DoorDashGuideTests.L("Taco Bell - 002698", 423, 2158, 39),
            DoorDashGuideTests.L("Navigate", 604, 2370, 67),
        ]
    let taskTacoBell: [OCRLine] = [
            DoorDashGuideTests.L("10:48 1", 182, 99, 40),
            DoorDashGuideTests.L("esconset", 788, 196, 145),
            DoorDashGuideTests.L("$18.10", 604, 268, 47),
            DoorDashGuideTests.L("erryvilleRd", 1010, 360, 193),
            DoorDashGuideTests.L("ve", 1185, 314, 27),
            DoorDashGuideTests.L("This dash", 604, 327, 34),
            DoorDashGuideTests.L("Bell", 924, 348, 33),
            DoorDashGuideTests.L("Pick up by 10:50 PM", 344, 802, 65),
            DoorDashGuideTests.L("Taco Bell - 002698", 528, 909, 98),
            DoorDashGuideTests.L("4833 Nesconset Highway", 521, 1110, 60),
            DoorDashGuideTests.L("Port Jefferson Station, NY 11776", 584, 1173, 48),
            DoorDashGuideTests.L("Store notes", 353, 1410, 44),
            DoorDashGuideTests.L("\"Pick up in the lobby. If the lobby is closed", 583, 1600, 49),
            DoorDashGuideTests.L("then use the drive-thru lane.\"", 428, 1666, 39),
            DoorDashGuideTests.L("Pick up at store", 401, 1874, 54),
            DoorDashGuideTests.L("1 order", 295, 1934, 51),
            DoorDashGuideTests.L("Christina R", 228, 2126, 43),
            DoorDashGuideTests.L("Arrived", 501, 2364, 54),
        ]
    let popHirosaki: [OCRLine] = [
            DoorDashGuideTests.L("9:32", 158, 100, 39),
            DoorDashGuideTests.L("Your route", 284, 398, 82),
            DoorDashGuideTests.L("2 stops remaining", 265, 494, 53),
            DoorDashGuideTests.L("Nesconsetr", 713, 620, 126),
            DoorDashGuideTests.L("Nicolls Rd", 1039, 769, 128),
            DoorDashGuideTests.L("each", 782, 1130, 41),
            DoorDashGuideTests.L("Grao", 557, 1221, 22),
            DoorDashGuideTests.L("In progress", 158, 1306, 44),
            DoorDashGuideTests.L("Hirosaki Japanese", 358, 1386, 68),
            DoorDashGuideTests.L("(Stony Brook)", 884, 1386, 66),
            DoorDashGuideTests.L("Pickup : 9:38 PM", 237, 1467, 46),
            DoorDashGuideTests.L("2548 Nesconset Highway", 617, 1642, 70),
            DoorDashGuideTests.L("Stony Brook, NY 11790", 503, 1713, 50),
            DoorDashGuideTests.L("Pick up in store", 468, 1930, 68),
            DoorDashGuideTests.L("4 items", 326, 1998, 55),
            DoorDashGuideTests.L("Back to task", 604, 2198, 43),
            DoorDashGuideTests.L("Copy address", 649, 2392, 55),
        ]
    let taskSam: [OCRLine] = [
            DoorDashGuideTests.L("9:37", 160, 99, 42),
            DoorDashGuideTests.L("BettyAnn", 1002, 224, 36),
            DoorDashGuideTests.L("$0.00", 604, 270, 55),
            DoorDashGuideTests.L("ollsRd", 803, 308, 73),
            DoorDashGuideTests.L("This dash", 603, 326, 39),
            DoorDashGuideTests.L("Pond Path", 585, 457, 151),
            DoorDashGuideTests.L("Forest Rd", 883, 460, 135),
            DoorDashGuideTests.L("Tree Rd", 1017, 526, 117),
            DoorDashGuideTests.L("Eastwood Blvd", 1118, 589, 200),
            DoorDashGuideTests.L("Hammond Ln", 727, 617, 192),
            DoorDashGuideTests.L("Hallock Rd", 350, 640, 147),
            DoorDashGuideTests.L("Elliot Ave", 564, 635, 132),
            DoorDashGuideTests.L("Oxhead Rd", 851, 650, 155),
            DoorDashGuideTests.L("Wood Rd", 662, 658, 130),
            DoorDashGuideTests.L("Dawn Dr", 984, 716, 125),
            DoorDashGuideTests.L("Oak St", 792, 734, 97),
            DoorDashGuideTests.L("Lake Grove", 474, 957, 42),
            DoorDashGuideTests.L("Rustic Rd", 883, 1006, 135),
            DoorDashGuideTests.L("Olive St", 426, 1200, 113),
            DoorDashGuideTests.L("Smith St", 458, 1364, 43),
            DoorDashGuideTests.L("Deliver by 9:52 PM", 322, 1537, 60),
            DoorDashGuideTests.L("Sam C", 219, 1643, 122),
            DoorDashGuideTests.L(" Message", 466, 1814, 49),
            DoorDashGuideTests.L("Call", 182, 1812, 42),
            DoorDashGuideTests.L("9 New Jersey Ave", 426, 2002, 51),
            DoorDashGuideTests.L("Ronkonkoma, NY 11779", 488, 2064, 48),
            DoorDashGuideTests.L("Navigate", 604, 2369, 65),
        ]

    func testRouteList() {
        let s = DoorDashGuide.sections(list1037)
        XCTAssertEqual(s.map(\.name), ["Wingstop - 3065", "Taco Bell - 002698", "Christina R", "Kathleen P"])
        XCTAssertEqual(s.map(\.type), [.pickup, .pickup, .dropoff, .dropoff])
        XCTAssertTrue(s.allSatisfy { $0.address == nil })
    }

    func testPopupsGiveFullAddresses() {
        XCTAssertEqual(DoorDashGuide.sections(popWingstop),
                       [GuideSection(type: .pickup, name: "Wingstop - 3065", address: "4747 Nesconset Hwy # Unit7, Port Jefferson Station, NY 11776")])
        // The map label "Norwood Ave" above the name is not part of it.
        XCTAssertEqual(DoorDashGuide.sections(popTacoBell).first?.address, "4833 Nesconset Highway, Port Jefferson Station, NY 11776")
        XCTAssertEqual(DoorDashGuide.sections(popTacoBell).count, 1)
        // A name split in two by OCR on one row is joined.
        XCTAssertEqual(DoorDashGuide.sections(popHirosaki).first?.name, "Hirosaki Japanese (Stony Brook)")
    }

    func testBothCustomersAtOneAddressAreRead() {
        var all = DoorDashGuide.sections(list1037)
        for screen in [popWingstop, popChristina, popKathleen] { // (the Taco Bell pop-up OCR'd "Tac0" in this sample)
            all = TripGuide.merge(all, with: DoorDashGuide.sections(screen))
        }
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all[2].address, "24 Kensington Way, Port Jefferson Station, NY 11776")
        XCTAssertEqual(all[3].address, "24 Kensington Way, Port Jefferson Station, NY 11776")
        XCTAssertNotEqual(all[2].name, all[3].name)
    }

    func testTaskScreensLinkStoresAndCustomers() {
        let pick = DoorDashGuide.taskScreen(taskWingstop)!
        XCTAssertEqual(pick.name, "Wingstop - 3065")
        XCTAssertEqual(pick.link?.customers, ["Kathleen P"])
        let drop = DoorDashGuide.taskScreen(taskChristina)!
        XCTAssertEqual(drop.name, "Christina R")
        XCTAssertEqual(drop.address, "24 Kensington Way, Port Jefferson Station, NY 11776")
        XCTAssertEqual(drop.link?.store, "Taco Bell - 002698")
        XCTAssertEqual(DoorDashGuide.taskScreen(taskTacoBell)?.link?.customers, ["Christina R"])
        XCTAssertNil(DoorDashGuide.taskScreen(taskSam)?.link) // store line not on screen
        XCTAssertEqual(DoorDashGuide.taskScreen(taskSam)?.address, "9 New Jersey Ave, Ronkonkoma, NY 11779")
    }

    func testLinksUseTaskScreens() {
        let list = DoorDashGuide.sections(list1037)
        // Plain first-in-first-out would give Christina to Wingstop; the task screens say otherwise.
        let screens = [DoorDashGuide.taskScreen(taskWingstop)!.link!, DoorDashGuide.taskScreen(taskChristina)!.link!]
        XCTAssertEqual(TripGuide.links(list, pickupScreens: screens), [.pickup(0), .pickup(1), .pickup(1), .pickup(0)])
        // Only the store you're headed to seen: Kathleen -> Wingstop, so Christina -> the next store.
        XCTAssertEqual(TripGuide.links(list, pickupScreens: [screens[0]]), [.pickup(0), .pickup(1), .pickup(1), .pickup(0)])
    }

    func testSameStoreListedTwiceIsTwoOrders() {
        let a = GuideSection(type: .pickup, name: "Taco Bell - 002698")
        let merged = TripGuide.merge([], with: [a, a, GuideSection(type: .dropoff, name: "Christina R"), GuideSection(type: .dropoff, name: "Kathleen P")])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].orders, 2)
        XCTAssertEqual(TripGuide.links(merged, pickupScreens: []), [.pickup(0), .pickup(0), .pickup(0)])
    }
}
