import Foundation

/// Finds the fastest order to visit your stops.
///
/// Road travel times between stops come from Apple Maps (its routing engine finds the fastest road path
/// for each pair). This file then picks the visiting order. With 9 stops or fewer it checks every possible
/// order (dynamic programming over subsets, Held–Karp style), so the answer is the true best order, not a guess.
/// Linked stops (same `orderId`) keep every pickup ahead of its dropoffs.
public enum RouteOptimizer {

    public struct Result: Equatable {
        public var order: [Int]          // indices into the stops you passed in
        public var cost: Double          // total travel cost of `order` (e.g. seconds)
        public var currentCost: Double   // travel cost of the order you had
        public var improvement: Double { max(0, currentCost - cost) }
    }

    /// Bit masks of the pickups each stop must wait for (dropoffs wait for their order's pickups).
    public static func requirements(_ stops: [Stop]) -> [Int] {
        stops.map { s in
            guard s.type == .dropoff else { return 0 }
            var need = 0
            for (i, o) in stops.enumerated() where o.type == .pickup && o.orderId == s.orderId { need |= 1 << i }
            return need
        }
    }

    /// Cost of driving the stops in this order.
    public static func cost(of order: [Int], cost: [[Double]], fromStart: [Double]?) -> Double {
        guard let first = order.first else { return 0 }
        var total = fromStart?[first] ?? 0
        for (a, b) in zip(order, order.dropFirst()) { total += cost[a][b] }
        return total
    }

    /// - Parameters:
    ///   - stops: your stops, in their current order.
    ///   - cost: `cost[i][j]` = travel from stop i to stop j.
    ///   - fromStart: travel from where you are to each stop (nil = start at whichever stop is best).
    ///   - keepIfWithin: if the best order beats the current one by less than this, keep the current order.
    public static func optimize(stops: [Stop], cost: [[Double]], fromStart: [Double]?,
                                keepIfWithin: Double = 0) -> Result? {
        let n = stops.count
        guard n > 0, n <= 14, cost.count == n, cost.allSatisfy({ $0.count == n }),
              fromStart.map({ $0.count == n }) ?? true else { return nil }

        let current = Array(0..<n)
        let currentCost = Self.cost(of: current, cost: cost, fromStart: fromStart)
        let need = requirements(stops)

        let full = (1 << n) - 1
        let inf = Double.infinity
        var best = [[Double]](repeating: [Double](repeating: inf, count: n), count: 1 << n)
        var from = [[Int]](repeating: [Int](repeating: -1, count: n), count: 1 << n)

        for j in 0..<n where need[j] == 0 {
            best[1 << j][j] = fromStart?[j] ?? 0
        }
        for mask in 1...full {
            for last in 0..<n where mask & (1 << last) != 0 {
                let here = best[mask][last]
                if here == inf { continue }
                for next in 0..<n where mask & (1 << next) == 0 && need[next] & mask == need[next] {
                    let m2 = mask | (1 << next)
                    let c = here + cost[last][next]
                    if c < best[m2][next] { best[m2][next] = c; from[m2][next] = last }
                }
            }
        }

        var end = -1
        var bestCost = inf
        for last in 0..<n where best[full][last] < bestCost { bestCost = best[full][last]; end = last }
        guard end >= 0 else { return nil } // impossible (shouldn't happen: pickups can always go first)

        var order: [Int] = []
        var mask = full, at = end
        while at >= 0 {
            order.append(at)
            let prev = from[mask][at]
            mask &= ~(1 << at)
            at = prev
        }
        order.reverse()

        // Don't shuffle your stops for a negligible gain (or if your order is already the best).
        let currentValid = TripPlanner.isValidOrder(stops)
        if currentValid && currentCost - bestCost <= keepIfWithin {
            return Result(order: current, cost: currentCost, currentCost: currentCost)
        }
        return Result(order: order, cost: bestCost, currentCost: currentCost)
    }

    /// Straight-line fallback when no road times are known: road miles between every pair.
    public static func milesMatrix(_ stops: [Stop]) -> [[Double]] {
        stops.map { a in stops.map { b in a.id == b.id ? 0 : Geo.roadMiles(a.location, b.location) } }
    }
}
