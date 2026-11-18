import ReplayKit
import Vision
import CoreMedia
import CoreImage
import UserNotifications
import GigCore

/// The screen reader. iOS hands this extension the live screen while a broadcast is running
/// (started from the button in the app or Control Center → Screen Recording → GigGrade).
/// About once a second it runs Apple's on-device text recognition and grades any offer it sees.
/// When a new offer appears it saves one smaller screenshot of it to the Offers log.
///
/// Note: iOS caps broadcast extensions at ~50 MB of memory, so we work one frame at a time.
class SampleHandler: RPBroadcastSampleHandler {

    private var lastScan = Date.distantPast
    private var lastHeartbeat = Date.distantPast
    private let scanInterval: TimeInterval = 1.0
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let store = SharedStore.shared

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        OfferAlert.registerCategories()
        OfferPipeline.shared.reset()
        store.broadcastStartedAt = Date()
        store.broadcastHeartbeat = Date()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = Date()
        if now.timeIntervalSince(lastHeartbeat) >= 5 {
            lastHeartbeat = now
            store.broadcastHeartbeat = now // lets the app's timer know we're still recording
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
                guard let text = Self.offerText(from: request.results ?? []) else { return } // GigGrade's own screen
                let ctx = ciContext
                OfferPipeline.shared.handle(text: text, screenshot: {
                    Self.jpeg(pixelBuffer, orientation: orientation, context: ctx)
                })
            } catch {
                // Skip this frame.
            }
        }
    }

    /// Turns what Vision read into text for the parser, minus anything GigGrade drew itself:
    /// - returns nil when the screen is GigGrade's own app (so it never grades its own numbers)
    /// - drops the text inside GigGrade's notification banner sitting on top of a gig app
    static func offerText(from observations: [VNRecognizedTextObservation]) -> String? {
        let lines = observations
            .sorted { $0.boundingBox.minY > $1.boundingBox.minY } // top of screen first
            .compactMap { o in o.topCandidates(1).first.map { (box: o.boundingBox, text: $0.string) } }
        let all = lines.map { $0.text.lowercased() }.joined(separator: "\n")

        // GigGrade's own screens: its tab bar, offer details, or banner settings.
        let ownScreen = (all.contains("insights") && all.contains("earnings"))
            || all.contains("delete this offer")
            || all.contains("banner and sounds")
            || all.contains("today's offers")
        if ownScreen { return nil }

        // GigGrade banner: from its "GIGGRADE" header down ~18% of the screen.
        var bannerBands: [ClosedRange<CGFloat>] = []
        for l in lines where l.text.lowercased().contains("giggrade") {
            bannerBands.append((l.box.minY - 0.18)...(l.box.maxY + 0.01))
        }
        let ownWording = ["/hr", "/mi", "% of $", "after costs", "on the way", "off route", "ends near",
                          "per extra mile", "couldn't locate", "route already has", "accepted + add",
                          "🟢", "🟡", "🔴", "good ·", "fair ·", "bad ·"]
        let kept = lines.filter { l in
            if bannerBands.contains(where: { $0.contains(l.box.midY) }) { return false }
            let t = l.text.lowercased()
            return !ownWording.contains { t.contains($0) }
        }
        return kept.map { $0.text }.joined(separator: "\n")
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
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [OfferAlert.requestId])
    }
}
