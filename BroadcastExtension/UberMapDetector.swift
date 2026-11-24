import CoreVideo
import GigCore

/// Finds the pins on an Uber offer map (light and dark map styles). Port of the prototype tuned on
/// your real Uber screenshots:
///  - pickup  = green pin; its real spot is the small dot at the bottom of the stem
///  - dropoff = black pin (light map) or light-gray pin (dark map); real spot = the square at the bottom
///  - you     = the arrow puck (white ring-shaped on light maps, solid black on dark maps)
/// Runs only when a new Uber offer is confirmed.
enum UberMapDetector {

    private struct Blob { var n = 0; var x0 = Int.max; var x1 = Int.min; var y0 = Int.max; var y1 = Int.min
        var w: Int { x1 - x0 + 1 }; var h: Int { y1 - y0 + 1 } }

    /// - Parameters:
    ///   - bannerBottom: 0–1 from the top; GigGrade's banner covers the screen above this (ignored).
    ///   - cardTop: 0–1 from the top; where Uber's offer card starts (the map is above it).
    static func detect(_ buffer: CVPixelBuffer, bannerBottom: Double, cardTop: Double?) -> MapPins? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let px = Pixels(buffer) else { return nil }
        let W = px.width, H = px.height
        guard H > W, W > 300 else { return nil }

        let step = max(2, Int((3 * Double(W) / 1206).rounded()))
        let gw = W / step
        let gy0 = Int(Double(H) * 0.065) / step
        let gy1 = max(gy0 + 1, Int(Double(H) * (cardTop ?? 0.53)) / step)
        let gh = gy1 - gy0
        let bannerCell = Double(H) * bannerBottom / Double(step) - Double(gy0)

        // Sample once; decide light vs dark map from the median brightness.
        var rgb = [(Int, Int, Int)](repeating: (0, 0, 0), count: gw * gh)
        var hist = [Int](repeating: 0, count: 256)
        for gy in 0..<gh {
            let py = (gy0 + gy) * step
            for gx in 0..<gw {
                let c = px.rgb(gx * step, py)
                rgb[gy * gw + gx] = c
                hist[min(255, (2126 * c.0 + 7152 * c.1 + 722 * c.2) / 10000)] += 1
            }
        }
        var acc = 0, median = 0
        for v in 0..<256 { acc += hist[v]; if acc * 2 >= rgb.count { median = v; break } }
        let light = median > 150

        func mask(_ test: ((Int, Int, Int)) -> Bool) -> [Bool] { rgb.map(test) }
        let green = mask { $0.1 > $0.0 + 50 && $0.1 > $0.2 + 25 && $0.1 > 100 }
        let black = mask { $0.0 < 50 && $0.1 < 50 && $0.2 < 50 }
        // Dark map: dropoff pin is (224,224,224); the route line is brighter (236), so use a narrow band.
        let pale = mask { $0.0 >= 212 && $0.0 <= 231 && abs($0.0 - $0.1) < 8 && abs($0.0 - $0.2) < 8 }
        let veryBlack = mask { $0.0 < 40 && $0.1 < 40 && $0.2 < 40 }

        let pinW = 0.087 * Double(W) / Double(step) // pin bubble width in grid cells
        func isPin(_ b: Blob) -> Bool {
            let w = Double(b.w), h = Double(b.h)
            return w > 0.7 * pinW && w < 1.4 * pinW && h > 1.3 * w && Double(b.n) > 0.45 * w * w * 0.785
        }
        func isPuck(_ b: Blob, solid: Bool) -> Bool {
            let w = Double(b.w), h = Double(b.h), area = w * h
            guard w > 0.75 * pinW, w < 1.4 * pinW, h / w > 0.8, h / w < 1.25 else { return false }
            return solid ? (Double(b.n) > 0.5 * area && Double(b.n) < 0.8 * area) : Double(b.n) < 0.45 * area
        }
        func notUnderBanner(_ b: Blob) -> Bool { Double(b.y0 + b.y1) / 2 > bannerCell }
        func anchor(_ b: Blob) -> MapPins.Point {
            MapPins.Point(x: Double(b.x0 + b.x1) / 2 * Double(step),
                          y: (Double(gy0 + b.y1) - 0.12 * Double(b.w)) * Double(step))
        }
        func center(_ b: Blob) -> MapPins.Point {
            MapPins.Point(x: Double(b.x0 + b.x1) / 2 * Double(step), y: (Double(gy0) + Double(b.y0 + b.y1) / 2) * Double(step))
        }

        let pickups = blobs(green, gw, gh).filter { isPin($0) && notUnderBanner($0) }.map(anchor)
        let dropoffs = blobs(light ? black : pale, gw, gh).filter { isPin($0) && notUnderBanner($0) }.map(anchor)
        // You. Light map (5.9.6.5): find the small black arrowhead inside a white circle ringed in black. Looking for
        // the ring itself failed when Uber's route line touched it (the route's black outline merged with the ring,
        // and a bend in the route was taken for you). Dark map: unchanged.
        func lum(_ gx: Int, _ gy: Int) -> Int? {
            guard gx >= 0, gy >= 0, gx < gw, gy < gh else { return nil }
            let c = rgb[gy * gw + gx]
            return (2126 * c.0 + 7152 * c.1 + 722 * c.2) / 10000
        }
        func arrowScore(_ b: Blob) -> Int? {
            let w = Double(b.w), h = Double(b.h)
            guard w > 0.25 * pinW, w < 0.75 * pinW, h > 0.25 * pinW, h < 0.75 * pinW,
                  Double(b.n) > 0.25 * w * h, Double(b.n) < 0.75 * w * h else { return nil }
            let cx = Double(b.x0 + b.x1) / 2, cy = Double(b.y0 + b.y1) / 2, size = max(w, h)
            var white = 0, ring = 0
            for k in 0..<36 {
                let t = 2 * Double.pi * Double(k) / 36
                var seenWhite = false, seenRing = false
                var r = 0.55 * size
                while r < 1.45 * size {
                    guard let v = lum(Int((cx + r * cos(t)).rounded()), Int((cy + r * sin(t)).rounded())) else { break }
                    if !seenWhite { if r < size && v > 200 { seenWhite = true } }
                    else if v < 70 { seenRing = true; break }
                    r += 0.5
                }
                if seenWhite { white += 1 }
                if seenRing { ring += 1 }
            }
            guard Double(white) / 36 > 0.75, Double(ring) / 36 > 0.6 else { return nil }
            return white + ring
        }
        let pucks: [MapPins.Point]
        if light {
            pucks = blobs(black, gw, gh)
                .filter(notUnderBanner)
                .compactMap { b in arrowScore(b).map { (b, $0) } }
                .sorted { $0.1 > $1.1 }
                .map { center($0.0) }
        } else {
            pucks = blobs(veryBlack, gw, gh)
                .filter { isPuck($0, solid: true) && notUnderBanner($0) }
                .sorted { $0.n > $1.n }
                .map(center)
        }

        // 5.9.6.6: a frame with only some of the three is still returned; frames of the same view are combined.
        guard !pickups.isEmpty || !dropoffs.isEmpty || !pucks.isEmpty else { return nil }

        // The map view's picture: average brightness in 12 x 16 cells, below where banners show (top 24%).
        let sy0 = max(0, Int(Double(H) * 0.24) / step - gy0)
        let sx = 12, sy = 16
        var signature: [UInt8] = []
        signature.reserveCapacity(sx * sy)
        if gh > sy0 + sy {
            for j in 0..<sy {
                let ya = sy0 + j * (gh - sy0) / sy, yb = sy0 + (j + 1) * (gh - sy0) / sy
                for i in 0..<sx {
                    let xa = i * gw / sx, xb = (i + 1) * gw / sx
                    var sum = 0, n = 0
                    var yy = ya
                    while yy < yb {
                        var xx = xa
                        while xx < xb {
                            let c = rgb[yy * gw + xx]
                            sum += (2126 * c.0 + 7152 * c.1 + 722 * c.2) / 10000
                            n += 1
                            xx += 2
                        }
                        yy += 2
                    }
                    signature.append(UInt8(max(0, min(255, n > 0 ? sum / n : 0))))
                }
            }
        }
        return MapPins(me: pucks.first, stores: pickups, customers: dropoffs,
                       signature: signature.isEmpty ? nil : signature)
    }

    /// 8-connected groups of true cells, as bounding boxes + counts.
    private static func blobs(_ grid: [Bool], _ gw: Int, _ gh: Int) -> [Blob] {
        var seen = [Bool](repeating: false, count: grid.count)
        var out: [Blob] = []
        for start in 0..<grid.count where grid[start] && !seen[start] {
            var b = Blob()
            var stack = [start]
            seen[start] = true
            while let i = stack.popLast() {
                let x = i % gw, y = i / gw
                b.n += 1
                b.x0 = min(b.x0, x); b.x1 = max(b.x1, x); b.y0 = min(b.y0, y); b.y1 = max(b.y1, y)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                        let j = ny * gw + nx
                        if grid[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            if b.n >= 20 { out.append(b) }
        }
        return out
    }
}
