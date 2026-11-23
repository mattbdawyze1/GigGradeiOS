import ReplayKit
import Vision
import CoreMedia
import CoreImage
import UserNotifications
import GigCore

enum ScreenPatterns {
    /// A line that looks like GigGrade's own banner content (money, rates, miles, minutes).
    static let banner = try! NSRegularExpression(pattern: #"(\$\s?\d|\d\s?mi\b|\d\s?min\b)"#)
}

/// The screen reader. iOS hands this extension the live screen while a broadcast is running
/// (started from the button in the app or Control Center → Screen Recording → GigGrade).
/// About once a second it runs Apple's on-device text recognition and grades any offer it sees.
/// When a new offer appears it saves one smaller screenshot of it to the Offers log.
///
/// Note: iOS caps broadcast extensions at ~50 MB of memory, so we work one frame at a time.
class SampleHandler: RPBroadcastSampleHandler {

    private var lastScan = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private var lastCloudBeat = Date.distantPast
    private let scanInterval: TimeInterval = 1.0
    private var lastGuideTick = Date.distantPast
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let store = SharedStore.shared

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        OfferAlert.registerCategories()
        OfferPipeline.shared.reset()
        let start = Date()
        store.broadcastStartedAt = start
        store.broadcastHeartbeat = start
        Task {
            await Cloud.shared.pullSettingsIntoStore(force: true) // your targets + banner choices
            await Cloud.shared.broadcastStarted(at: start)
            await Cloud.shared.flush()
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = Date()
        if now.timeIntervalSince(lastHeartbeat) >= 5 {
            lastHeartbeat = now
            store.broadcastHeartbeat = now // lets the app's timer know we're still recording
        }
        if now.timeIntervalSince(lastGuideTick) >= 1 {
            lastGuideTick = now
            GuideCollector.shared.tick(now: now) // 👓: watch for a press, finish when you leave the Trip Guide
        }
        if now.timeIntervalSince(lastCloudBeat) >= 15 {
            lastCloudBeat = now
            Task {
                await Cloud.shared.heartbeat()               // timer + retry queued uploads
                await Cloud.shared.pullSettingsIntoStore()   // picks up setting changes (every ~60 s)
            }
        }
        guard now.timeIntervalSince(lastScan) >= scanInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastScan = now

        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }

        autoreleasepool {
            let request = VNRecognizeTextRequest()
            // .accurate reads small offer text best. If the broadcast keeps stopping by itself
            // on an older iPhone (memory limit), change this to .fast.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.012
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
                guard let screen = Self.readScreen(request.results ?? [], pixelBuffer: pixelBuffer) else { return } // GigGrade's own screen
                let ctx = ciContext
                let upright = orientation == .up
                GuideCollector.shared.observe(screen.lines) // Uber Trip Guide / pickup screen, only after a 👓 press
                OfferPipeline.shared.handle(lines: screen.lines, screenshot: {
                    Self.jpeg(pixelBuffer, orientation: orientation, context: ctx)
                }, mapPins: { app in
                    guard upright else { return nil }
                    switch app {
                    case .doordash: return MapPinDetector.detect(pixelBuffer)
                    case .uber: return UberMapDetector.detect(pixelBuffer, bannerBottom: screen.bannerBottom,
                                                              cardTop: screen.cardTop)
                    default: return nil
                    }
                })
            } catch {
                // Skip this frame.
            }
        }
    }

    struct Screen {
        var lines: [OCRLine]
        var bannerBottom: Double   // 0–1 from the top: GigGrade's banner covers the screen above this
        var cardTop: Double?       // 0–1 from the top: where the offer card starts (map is above it)
    }

    /// Turns what Vision read into lines for the parser, minus anything GigGrade drew itself:
    /// - returns nil when the screen is GigGrade's own app (so it never grades its own numbers)
    /// - drops GigGrade's notification banner sitting on top of a gig app
    /// - on Uber cards, measures how bright/bold each line is (store = bright, dropoff = gray)
    static func readScreen(_ observations: [VNRecognizedTextObservation], pixelBuffer: CVPixelBuffer) -> Screen? {
        struct Line { var box: CGRect; var text: String; var top: Double } // top: 0–1 from the top of the screen
        let lines = observations
            .compactMap { o in o.topCandidates(1).first.map { Line(box: o.boundingBox, text: $0.string, top: Double(1 - o.boundingBox.maxY)) } }
            .sorted { $0.top < $1.top }
        let all = lines.map { $0.text.lowercased() }.joined(separator: "\n")

        // GigGrade's own screens: its tab bar, offer details, or banner settings.
        let ownScreen = (all.contains("insights") && all.contains("earnings"))
            || all.contains("delete this offer")
            || all.contains("banner and sounds")
            || all.contains("today's offers")
            || all.contains("missed offers")
            || all.contains("why no banner")
            || all.contains("what the screen reader read")
            || all.contains("add an order")
        if ownScreen { return nil }

        // GigGrade's banner: lines near the top with its kind of content ($, /hr, /mi, miles, minutes,
        // verdict words or color dots). Offer cards are never up there.
        let ownWording = ["/hr", "/mi", "% of $", "after costs", "on the way", "off route", "close by", "ends near",
                          "per extra mile", "couldn't locate", "route check", "route already has", "accepted + add", "multiple matches", "tap the customer pin", "🛍", "🏠", "not checked",
                          "🟢", "🟡", "🔴", "good ·", "fair ·", "bad ·", "giggrade"]
        let bannerish = ScreenPatterns.banner
        // Only treat "$ / mi / min" lines up top as our banner when the real offer card is further down.
        let cardBelow = lines.contains { $0.top > 0.3 && $0.text.contains("$") }
        var bannerBottom = 0.0
        for l in lines where l.top < 0.24 {
            let t = l.text.lowercased()
            let looksOurs = ownWording.contains(where: { t.contains($0) })
                || (cardBelow && bannerish.firstMatch(in: l.text, range: NSRange(l.text.startIndex..., in: l.text)) != nil)
            if looksOurs { bannerBottom = max(bannerBottom, Double(1 - l.box.minY) + 0.015) }
        }
        let kept = lines.filter { l in
            if l.top < bannerBottom { return false }
            let t = l.text.lowercased()
            return !ownWording.contains { t.contains($0) }
        }

        // Where the offer card starts: the price line in the lower part of the screen.
        let priceTop = kept.first(where: { $0.top > 0.3 && $0.text.contains("$") })?.top
        let cardTop = priceTop.map { max(0.3, $0 - 0.06) }

        // Brightness per line, only needed for Uber's "total" layout.
        var emphasis: [Double?] = Array(repeating: nil, count: kept.count)
        if all.contains("total") {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            if let px = Pixels(pixelBuffer) {
                for (i, l) in kept.enumerated() { emphasis[i] = Self.emphasis(px, l.box) }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        // Line centers in pixels (same space as the map pins), so map street names can be matched to a pin.
        let w = Double(CVPixelBufferGetWidth(pixelBuffer)), h = Double(CVPixelBufferGetHeight(pixelBuffer))
        let out = kept.enumerated().map { i, l in
            OCRLine(l.text, emphasis: emphasis[i], x: Double(l.box.midX) * w, y: (1 - Double(l.box.midY)) * h,
                    h: Double(l.box.height) * h)
        }
        return Screen(lines: out, bannerBottom: bannerBottom, cardTop: cardTop)
    }

    /// How strongly a line's text stands out from its background (bold white/black ≈ 200+, gray ≈ 140–185).
    /// Measured on your Uber screenshots: store line 200–215, dropoff line 145–155 (light) / 182 (dark).
    static func emphasis(_ px: Pixels, _ box: CGRect) -> Double? {
        let x0 = max(0, Int(box.minX * CGFloat(px.width))), x1 = min(px.width - 1, Int(box.maxX * CGFloat(px.width)))
        let y0 = max(0, Int((1 - box.maxY) * CGFloat(px.height))), y1 = min(px.height - 1, Int((1 - box.minY) * CGFloat(px.height)))
        guard x1 > x0 + 4, y1 > y0 + 4 else { return nil }
        var lum = [Int](repeating: 0, count: 256)
        var samples: [Int] = []
        samples.reserveCapacity(((x1 - x0) / 2 + 1) * ((y1 - y0) / 2 + 1))
        var y = y0
        while y <= y1 {
            var x = x0
            while x <= x1 {
                let c = px.rgb(x, y)
                let l = min(255, max(0, Int(0.2126 * Double(c.0) + 0.7152 * Double(c.1) + 0.0722 * Double(c.2))))
                lum[l] += 1
                samples.append(l)
                x += 2
            }
            y += 2
        }
        // Background = median brightness of the box.
        var acc = 0, bg = 0
        for v in 0..<256 { acc += lum[v]; if acc * 2 >= samples.count { bg = v; break } }
        // Text = pixels clearly different from the background; average the strongest 30% (stroke centers).
        var diffs = [Int](repeating: 0, count: 256)
        var textCount = 0
        for l in samples { let d = abs(l - bg); if d > 40 { diffs[d] += 1; textCount += 1 } }
        guard textCount > 0 else { return 0 }
        let want = max(1, textCount * 3 / 10)
        var taken = 0, sum = 0
        var d = 255
        while d > 40, taken < want {
            let n = min(diffs[d], want - taken)
            taken += n; sum += n * d
            d -= 1
        }
        return Double(sum) / Double(max(taken, 1))
    }

    /// Half-size JPEG of the current frame (~100–200 KB) for the Offers log.
    static func jpeg(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, context: CIContext) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
            .oriented(orientation)
            .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.jpegRepresentation(of: image, colorSpace: space, options: [:])
    }

    override func broadcastFinished() {
        store.broadcastStartedAt = nil
        store.broadcastHeartbeat = nil
        // Give the cloud a few seconds to hear that recording stopped, and to send anything queued.
        let done = DispatchSemaphore(value: 0)
        Task {
            await Cloud.shared.broadcastEnded()
            await Cloud.shared.flush()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 4)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [OfferAlert.requestId])
    }
}
