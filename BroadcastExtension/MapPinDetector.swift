import CoreVideo
import GigCore

/// Finds the pins on a DoorDash offer map in a screen frame (dark map style).
/// Port of the prototype tuned on real DoorDash screenshots:
///  - pins are big white disks; a "store" icon has a wide awning near the top, a "person" icon a narrow head;
///  - the real location is the small dot ~1.33 pin-radii below each disk's center;
///  - the blue GPS dot is the largest bright-blue blob on the map;
///  - the map ends where the gray offer card starts.
/// Runs only when a new DoorDash offer is confirmed, never on every frame.
enum MapPinDetector {

    static func detect(_ buffer: CVPixelBuffer) -> MapPins? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let px = Pixels(buffer) else { return nil }
        let W = px.width, H = px.height
        guard H > W, W > 300 else { return nil } // portrait screen only

        let k = Double(W) / 1206.0                 // tuned on 1206-px-wide screenshots
        let step = max(2, Int((4 * k).rounded()))  // sample grid spacing in pixels

        // 1) Where the map ends: first run of offer-card gray rows below 35% of the screen.
        var mapBottom = Int(Double(H) * 0.62)
        var run = 0
        var y = Int(Double(H) * 0.35)
        while y < Int(Double(H) * 0.8) {
            var hits = 0, total = 0
            var x = 0
            while x < W { if isCard(px.rgb(x, y)) { hits += 1 }; total += 1; x += 12 }
            if Double(hits) / Double(max(total, 1)) > 0.9 {
                run += 1
                if run >= 8 { mapBottom = y - Int(16 * k); break }
            } else {
                run = 0
            }
            y += 2
        }
        let top = Int(Double(H) * 0.055) // below the status bar / Dynamic Island

        // 2) Sample the map on a grid.
        let gw = W / step
        let gy0 = top / step, gy1 = max(gy0 + 1, mapBottom / step)
        let gh = gy1 - gy0
        var white = [UInt8](repeating: 0, count: gw * gh)
        var blue: [(Int, Int)] = []
        for gy in 0..<gh {
            let py = (gy0 + gy) * step
            for gx in 0..<gw {
                let c = px.rgb(gx * step, py)
                if isWhite(c) { white[gy * gw + gx] = 1 } else if isBlue(c) { blue.append((gx, gy)) }
            }
        }

        // 3) Pin disks = cells whose surrounding square is >= 80% white (route lines and text fail this).
        //    Summed-area table makes each check O(1).
        var sat = [Int](repeating: 0, count: (gw + 1) * (gh + 1))
        for gy in 0..<gh {
            var rowSum = 0
            for gx in 0..<gw {
                rowSum += Int(white[gy * gw + gx])
                sat[(gy + 1) * (gw + 1) + gx + 1] = sat[gy * (gw + 1) + gx + 1] + rowSum
            }
        }
        func whiteCount(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int { // inclusive cell bounds
            sat[(y1 + 1) * (gw + 1) + x1 + 1] - sat[y0 * (gw + 1) + x1 + 1]
                - sat[(y1 + 1) * (gw + 1) + x0] + sat[y0 * (gw + 1) + x0]
        }
        let R = max(2, Int((16 * k / Double(step)).rounded()))
        let need = Int(0.8 * Double((2 * R + 1) * (2 * R + 1)))
        var core = [Bool](repeating: false, count: gw * gh)
        if gh > 2 * R, gw > 2 * R {
            for gy in R..<(gh - R) {
                for gx in R..<(gw - R) where white[gy * gw + gx] == 1 {
                    if whiteCount(gx - R, gy - R, gx + R, gy + R) >= need { core[gy * gw + gx] = true }
                }
            }
        }

        let cellScale = Double(4 * 4) / Double(step * step) // size thresholds were set at 4-px cells
        var stores: [MapPins.Point] = []
        var customers: [MapPins.Point] = []
        for comp in components(core, gw, gh) where Double(comp.count) >= 25 * cellScale {
            let xs = comp.map { $0.0 }, ys = comp.map { $0.1 }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
            let w = Double(maxX - minX + 1) * Double(step), h = Double(maxY - minY + 1) * Double(step)
            guard w / h > 0.6, w / h < 1.6 else { continue }
            let cx = Double(minX + maxX) / 2 * Double(step)
            let cy = Double(gy0 * step) + Double(minY + maxY) / 2 * Double(step)
            let r = (w + h) / 4 + Double(R * step)
            let anchor = MapPins.Point(x: cx, y: cy + 1.33 * r)
            if isStoreIcon(px, cx: cx, cy: cy, r: r) { stores.append(anchor) } else { customers.append(anchor) }
        }

        // 4) Blue GPS dot = biggest blue blob.
        var me: MapPins.Point?
        var blueGrid = [Bool](repeating: false, count: gw * gh)
        for (gx, gy) in blue { blueGrid[gy * gw + gx] = true }
        if let dot = components(blueGrid, gw, gh).filter({ Double($0.count) >= 6 * cellScale }).max(by: { $0.count < $1.count }) {
            let mx = Double(dot.map { $0.0 }.reduce(0, +)) / Double(dot.count) * Double(step)
            let my = Double(gy0 * step) + Double(dot.map { $0.1 }.reduce(0, +)) / Double(dot.count) * Double(step)
            me = MapPins.Point(x: mx, y: my)
        }

        guard !stores.isEmpty || !customers.isEmpty else { return nil }
        return MapPins(me: me, stores: stores, customers: customers)
    }

    // MARK: Colors (tuned on DoorDash's dark map)

    private static func isCard(_ c: (Int, Int, Int)) -> Bool {
        abs(c.0 - 36) <= 8 && abs(c.1 - 36) <= 8 && abs(c.2 - 36) <= 8
    }
    private static func isWhite(_ c: (Int, Int, Int)) -> Bool { c.0 >= 225 && c.1 >= 225 && c.2 >= 225 }
    private static func isBlue(_ c: (Int, Int, Int)) -> Bool {
        c.2 >= 200 && c.0 <= 120 && c.1 >= 100 && c.1 <= 190 && c.2 - c.0 >= 110
    }
    private static func isDark(_ c: (Int, Int, Int)) -> Bool { max(c.0, max(c.1, c.2)) < 110 }

    /// Store icon has a wide dark awning just above the middle (≈0.58 r wide); person icon's head is ≈0.29 r.
    private static func isStoreIcon(_ px: Pixels, cx: Double, cy: Double, r: Double) -> Bool {
        let y = Int(cy - 0.22 * r)
        guard y >= 0, y < px.height else { return false }
        var minX = Int.max, maxX = Int.min
        var x = Int(cx - 0.6 * r)
        while x < Int(cx + 0.6 * r) {
            if x >= 0, x < px.width, isDark(px.rgb(x, y)) { minX = min(minX, x); maxX = max(maxX, x) }
            x += 1
        }
        guard maxX > minX else { return false }
        return Double(maxX - minX) / r >= 0.45
    }

    /// 8-connected groups of true cells.
    private static func components(_ grid: [Bool], _ gw: Int, _ gh: Int) -> [[(Int, Int)]] {
        var seen = [Bool](repeating: false, count: grid.count)
        var out: [[(Int, Int)]] = []
        for start in 0..<grid.count where grid[start] && !seen[start] {
            var comp: [(Int, Int)] = []
            var stack = [start]
            seen[start] = true
            while let i = stack.popLast() {
                let x = i % gw, y = i / gw
                comp.append((x, y))
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                        let j = ny * gw + nx
                        if grid[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            out.append(comp)
        }
        return out
    }
}

/// Read-only RGB access to a screen frame (BGRA or the YUV format ReplayKit usually sends).
struct Pixels {
    let width: Int
    let height: Int
    private let base0: UnsafePointer<UInt8>
    private let stride0: Int
    private let base1: UnsafePointer<UInt8>?
    private let stride1: Int
    private let videoRange: Bool

    /// The buffer must already be locked.
    init?(_ b: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(b)
        width = CVPixelBufferGetWidth(b)
        height = CVPixelBufferGetHeight(b)
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let a = CVPixelBufferGetBaseAddress(b) else { return nil }
            base0 = UnsafePointer(a.assumingMemoryBound(to: UInt8.self))
            stride0 = CVPixelBufferGetBytesPerRow(b)
            base1 = nil; stride1 = 0; videoRange = false
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let yp = CVPixelBufferGetBaseAddressOfPlane(b, 0),
                  let cp = CVPixelBufferGetBaseAddressOfPlane(b, 1) else { return nil }
            base0 = UnsafePointer(yp.assumingMemoryBound(to: UInt8.self))
            stride0 = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
            base1 = UnsafePointer(cp.assumingMemoryBound(to: UInt8.self))
            stride1 = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
            videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        default:
            return nil
        }
    }

    @inline(__always)
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        guard let chroma = base1 else {
            let p = base0 + y * stride0 + x * 4
            return (Int(p[2]), Int(p[1]), Int(p[0]))
        }
        var lum = Double(base0[y * stride0 + x])
        let ci = (y / 2) * stride1 + (x / 2) * 2
        var cb = Double(chroma[ci]) - 128
        var cr = Double(chroma[ci + 1]) - 128
        if videoRange {
            lum = (lum - 16) * 255 / 219
            cb *= 255 / 224
            cr *= 255 / 224
        }
        // BT.709 (HD screen capture)
        let r = lum + 1.5748 * cr
        let g = lum - 0.1873 * cb - 0.4681 * cr
        let b = lum + 1.8556 * cb
        return (clamp(r), clamp(g), clamp(b))
    }

    @inline(__always)
    private func clamp(_ v: Double) -> Int { Int(max(0, min(255, v.rounded()))) }
}
