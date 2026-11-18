import Foundation

/// One piece of information the offer banner can show.
public enum BannerItem: String, Codable, CaseIterable, Identifiable {
    case color, grade, app, pay, hourly, perMile, miles, minutes, net, verdict, dropoff
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .color: return "Color (Good / Fair / Bad)"
        case .grade: return "Letter grade"
        case .app: return "App name"
        case .pay: return "Pay"
        case .hourly: return "$ per hour"
        case .perMile: return "$ per mile"
        case .miles: return "Miles"
        case .minutes: return "Minutes"
        case .net: return "Pay after costs"
        case .verdict: return "On the way / Close by / Off route"
        case .dropoff: return "Dropoff location"
        }
    }
}

/// Which line of the banner an item goes on. iOS shows about 4 lines before cutting off with "…".
public enum BannerSlot: String, Codable, CaseIterable, Identifiable {
    case title, line2, line3, line4, more, off
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .title: return "Line 1 (title)"
        case .line2: return "Line 2"
        case .line3: return "Line 3"
        case .line4: return "Line 4"
        case .more: return "Only when pulled down"
        case .off: return "Don't show"
        }
    }
}

/// Where each item goes and in what order. Items on the same line are joined with " · ".
public struct BannerLayout: Codable, Equatable {
    public var slots: [String: BannerSlot]  // keyed by BannerItem.rawValue
    public var order: [BannerItem]

    public init(slots: [BannerItem: BannerSlot], order: [BannerItem] = BannerItem.allCases) {
        self.slots = Dictionary(uniqueKeysWithValues: slots.map { ($0.key.rawValue, $0.value) })
        self.order = order
    }

    /// Offer on line 1, rates on line 2, the on-the-way verdict on line 3 (always visible), trip details on 4.
    public static let standard = BannerLayout(slots: [
        .color: .title, .grade: .title, .app: .title, .pay: .title,
        .hourly: .line2, .perMile: .line2,
        .verdict: .line3,
        .miles: .line4, .minutes: .line4, .net: .line4,
        .dropoff: .off,
    ], order: [.color, .grade, .app, .pay, .hourly, .perMile, .verdict, .miles, .minutes, .net, .dropoff])

    public func slot(_ item: BannerItem) -> BannerSlot { slots[item.rawValue] ?? .off }

    public mutating func set(_ item: BannerItem, _ slot: BannerSlot) { slots[item.rawValue] = slot }

    /// Order with any newer items added at the end.
    public var fullOrder: [BannerItem] {
        var seen = Set<BannerItem>()
        let known = order.filter { seen.insert($0).inserted }
        return known + BannerItem.allCases.filter { !seen.contains($0) }
    }

    public func items(in slot: BannerSlot) -> [BannerItem] { fullOrder.filter { self.slot($0) == slot } }

    /// Builds the banner text from each item's text (missing/empty items are skipped).
    public func compose(_ values: [BannerItem: String]) -> (title: String, subtitle: String, body: String) {
        func line(_ s: BannerSlot) -> String {
            items(in: s).compactMap { values[$0] }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let body = [line(.line3), line(.line4), line(.more)].filter { !$0.isEmpty }.joined(separator: "\n")
        let title = line(.title)
        return (title.isEmpty ? "New offer" : title, line(.line2), body)
    }
}
